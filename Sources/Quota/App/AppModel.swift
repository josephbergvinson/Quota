import AppKit
import Combine
import Foundation
import QuotaCore

enum AppRoute: Hashable {
    case overview
    case resetPlanner
    case account(UUID)
}

enum AccountRefreshState: Equatable {
    case idle
    case refreshing
    case refreshed(Date)
    case failed(String)
}

enum ManagedAccountConnectionState: Equatable {
    case idle
    case starting
    case waitingInBrowser
    case connected
    case failed(String)

    var isInProgress: Bool {
        self == .starting || self == .waitingInBrowser
    }
}

enum AutomaticRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off:
            "Off"
        case .fiveMinutes:
            "Every 5 minutes"
        case .fifteenMinutes:
            "Every 15 minutes"
        case .thirtyMinutes:
            "Every 30 minutes"
        case .oneHour:
            "Every hour"
        }
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ProviderIdentityPresentation: Equatable {
    let accountLabel: String?
    let identityKey: String?
    let planLabel: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = PersistentState()
    @Published private(set) var isLoaded = false
    @Published var selection: AppRoute? = .overview
    @Published var refreshStates: [UUID: AccountRefreshState] = [:]
    @Published var refreshWarnings: [UUID: String] = [:]
    @Published var identityWarnings: [UUID: String] = [:]
    @Published var presentedError: PresentedError?
    @Published var isShowingAddAccount = false
    @Published var editingAccount: ConnectedAccount?
    @Published var connectionStates: [UUID: ManagedAccountConnectionState] = [:]
    @Published private(set) var automaticRefreshInterval: AutomaticRefreshInterval
    @Published private(set) var now = Date()

    let dataDirectoryURL: URL?

    private let repository: QuotaRepository?
    private let refreshService: UsageRefreshService?
    private let chatGPTProvider: ChatGPTUsageProvider?
    private let claudeProvider: ClaudeCodeUsageProvider?
    private var automaticRefreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var chatGPTLoginSessions: [UUID: ChatGPTManagedLoginSession] = [:]
    private var claudeLoginSessions: [UUID: ClaudeCodeManagedLoginSession] = [:]
    private var providerIdentities: [UUID: ProviderIdentityPresentation] = [:]
    private var accountIDsPendingRemoval: Set<UUID> = []
    private var didStart = false

    private static let refreshIntervalDefaultsKey = "automaticRefreshInterval"

    init() {
        if
            let savedInterval = UserDefaults.standard.object(forKey: Self.refreshIntervalDefaultsKey) as? Int,
            let interval = AutomaticRefreshInterval(rawValue: savedInterval)
        {
            self.automaticRefreshInterval = interval
        } else {
            self.automaticRefreshInterval = .fifteenMinutes
        }

        do {
            let credentialStore = KeychainCredentialStore()
            let dataStore = try LocalDataStore()
            let chatGPTProvider = ChatGPTUsageProvider(
                accountsDirectoryURL: dataStore.directoryURL
                    .appendingPathComponent("ChatGPTAccounts", isDirectory: true)
            )
            let claudeProvider = ClaudeCodeUsageProvider(
                accountsDirectoryURL: dataStore.directoryURL
                    .appendingPathComponent("ClaudeAccounts", isDirectory: true)
            )
            self.repository = QuotaRepository(dataStore: dataStore, credentialStore: credentialStore)
            self.refreshService = UsageRefreshService(
                registry: UsageProviderRegistry(
                    chatGPTAccountsDirectoryURL: chatGPTProvider.accountsDirectoryURL,
                    claudeCodeAccountsDirectoryURL: claudeProvider.accountsDirectoryURL
                ),
                credentialStore: credentialStore
            )
            self.chatGPTProvider = chatGPTProvider
            self.claudeProvider = claudeProvider
            self.dataDirectoryURL = dataStore.directoryURL
        } catch {
            self.repository = nil
            self.refreshService = nil
            self.chatGPTProvider = nil
            self.claudeProvider = nil
            self.dataDirectoryURL = nil
            self.presentedError = PresentedError(
                title: "Quota could not start",
                message: error.localizedDescription
            )
        }
    }

    deinit {
        automaticRefreshTask?.cancel()
        clockTask?.cancel()
    }

    var accounts: [ConnectedAccount] {
        state.accounts.sorted {
            if $0.kind.provider == $1.kind.provider {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.kind.provider.rawValue < $1.kind.provider.rawValue
        }
    }

    var latestSnapshots: [UUID: UsageSnapshot] {
        state.latestSnapshotsByAccount
    }

    var dashboardSummary: DashboardSummary {
        UsageAnalytics.dashboard(
            accounts: accounts,
            latestSnapshots: latestSnapshots,
            now: now
        )
    }

    var recommendedAccount: AccountCapacity? {
        dashboardSummary.capacities
            .filter {
                $0.remainingFraction != nil
                    && !$0.isStale
                    && identityWarnings[$0.account.id] == nil
            }
            .sorted { left, right in
                guard
                    let leftRemaining = left.remainingFraction,
                    let rightRemaining = right.remainingFraction
                else {
                    return left.remainingFraction != nil
                }
                if leftRemaining == rightRemaining {
                    return left.account.displayName.localizedStandardCompare(
                        right.account.displayName
                    ) == .orderedAscending
                }
                return leftRemaining > rightRemaining
            }
            .first
    }

    var isRefreshing: Bool {
        refreshStates.values.contains(.refreshing)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        scheduleClock()
        guard let repository else {
            isLoaded = true
            return
        }

        do {
            state = try await repository.load()
            for account in state.accounts {
                refreshStates[account.id] = .idle
                if account.kind.isManagedSubscription {
                    connectionStates[account.id] = .idle
                }
            }
            updateIdentityWarnings()
        } catch {
            show(error: error, title: "Could not load local data")
        }
        isLoaded = true
        scheduleAutomaticRefresh()
        Task { [weak self] in
            await self?.refreshAll()
        }
    }

    func setAutomaticRefreshInterval(_ interval: AutomaticRefreshInterval) {
        automaticRefreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: Self.refreshIntervalDefaultsKey)
        scheduleAutomaticRefresh()
    }

    @discardableResult
    func addAccount(
        _ account: ConnectedAccount,
        credential: ProviderCredential?,
        initialSnapshot: UsageSnapshot?
    ) async -> Bool {
        guard let repository else { return false }
        do {
            state = try await repository.add(
                account: account,
                credential: credential,
                initialSnapshot: initialSnapshot
            )
            refreshStates[account.id] = .idle
            selection = .account(account.id)
            if account.kind.isChatGPTSubscription {
                connectionStates[account.id] = .idle
                Task { [weak self] in
                    await self?.connectChatGPT(accountID: account.id)
                }
            } else if account.kind.isClaudeSubscription {
                connectionStates[account.id] = .idle
                Task { [weak self] in
                    await self?.connectClaude(accountID: account.id)
                }
            } else {
                await refresh(accountID: account.id)
            }
            return true
        } catch QuotaRepositoryError.credentialSaveFailedAccountRetained {
            do {
                state = try await repository.load()
                refreshStates[account.id] = .idle
                selection = .account(account.id)
                show(
                    error: QuotaRepositoryError.credentialSaveFailedAccountRetained,
                    title: "Account needs its Admin API key"
                )
                return true
            } catch {
                show(error: error, title: "Could not reload the saved account")
                return false
            }
        } catch {
            show(error: error, title: "Could not add account")
            return false
        }
    }

    @discardableResult
    func updateAccount(
        _ account: ConnectedAccount,
        replacementCredential: ProviderCredential?
    ) async -> Bool {
        guard let repository else { return false }
        do {
            state = try await repository.update(
                account: account,
                replacementCredential: replacementCredential
            )
            if account.kind.isManagedSubscription {
                updateIdentityWarnings()
            }
            return true
        } catch {
            show(error: error, title: "Could not update account")
            return false
        }
    }

    func removeAccount(_ account: ConnectedAccount) async {
        guard
            let repository,
            !accountIDsPendingRemoval.contains(account.id),
            self.account(withID: account.id) != nil
        else {
            return
        }
        accountIDsPendingRemoval.insert(account.id)
        defer { accountIDsPendingRemoval.remove(account.id) }
        var retiredChatGPTHomeURL: URL?
        var retiredClaudeConfigurationURL: URL?
        var failureContext = "Quota could not finish removing this account."

        do {
            if account.kind.isChatGPTSubscription,
               let session = chatGPTLoginSessions[account.id] {
                failureContext = "Quota could not cancel the active ChatGPT sign-in."
                chatGPTLoginSessions[account.id] = nil
                try await session.cancel()
            }
            if account.kind.isClaudeSubscription,
               let session = claudeLoginSessions[account.id] {
                await session.cancel()
                claudeLoginSessions[account.id] = nil
            }

            if account.kind.isChatGPTSubscription {
                guard let chatGPTProvider else {
                    throw AccountRemovalError.providerUnavailable
                }
                failureContext = "Codex could not confirm that the managed ChatGPT session was signed out."
                let connector = try chatGPTProvider.connector(for: account.id)
                let homeURL = connector.configuration.codexHomeURL
                retiredChatGPTHomeURL = homeURL
                try await connector.retireAndLogout()

                failureContext = "Quota could not delete the isolated ChatGPT profile."
                if FileManager.default.fileExists(atPath: homeURL.path) {
                    try FileManager.default.removeItem(at: homeURL)
                }
            } else if account.kind.isClaudeSubscription {
                guard let claudeProvider else {
                    throw AccountRemovalError.providerUnavailable
                }
                let configurationURL = claudeProvider.configurationDirectoryURL(for: account.id)
                retiredClaudeConfigurationURL = configurationURL
                failureContext = "Claude Code could not confirm that the managed session was signed out."
                let connector = try claudeProvider.connector(for: account.id)
                try await connector.retireAndLogout()

                failureContext = "Quota could not delete the isolated Claude profile."
                if FileManager.default.fileExists(atPath: configurationURL.path) {
                    try FileManager.default.removeItem(at: configurationURL)
                }
            }

            failureContext = account.kind.requiresCredential
                ? "Quota could not remove the saved Admin API key or update local account data."
                : "Quota could not update local account data after cleaning up the managed profile."
            let removal = try await repository.remove(accountID: account.id)
            state = removal.state
            refreshStates[account.id] = nil
            refreshWarnings[account.id] = nil
            connectionStates[account.id] = nil
            providerIdentities[account.id] = nil
            updateIdentityWarnings()
            selection = .overview
        } catch {
            if let retiredChatGPTHomeURL {
                await ChatGPTAppServerConnector.reactivateProfile(
                    codexHomeURL: retiredChatGPTHomeURL
                )
                connectionStates[account.id] = .idle
            }
            if let retiredClaudeConfigurationURL {
                await ClaudeCodeConnector.reactivateProfile(
                    configurationDirectoryURL: retiredClaudeConfigurationURL
                )
                connectionStates[account.id] = .idle
            }
            if self.account(withID: account.id) != nil {
                refreshStates[account.id] = .idle
                if account.kind.isManagedSubscription {
                    connectionStates[account.id] = .idle
                }
            }
            presentedError = PresentedError(
                title: "Account not removed",
                message: [
                    failureContext,
                    "Quota kept the account and its local history.",
                    "Try Remove Account again.",
                    error.localizedDescription
                ].joined(separator: " ")
            )
            return
        }
    }

    func refreshAll() async {
        guard let refreshService, let repository else { return }
        guard !isRefreshing else { return }
        let refreshableAccounts = accounts.filter { account in
            !accountIDsPendingRemoval.contains(account.id)
                && connectionStates[account.id]?.isInProgress != true
        }
        guard !refreshableAccounts.isEmpty else { return }

        for account in refreshableAccounts {
            refreshStates[account.id] = .refreshing
            refreshWarnings[account.id] = nil
        }

        await withTaskGroup(of: (ConnectedAccount, Result<ProviderFetchResult, Error>).self) { group in
            for account in refreshableAccounts {
                group.addTask {
                    do {
                        let result = try await refreshService.refresh(account: account)
                        return (account, .success(result))
                    } catch {
                        return (account, .failure(error))
                    }
                }
            }

            for await (account, result) in group {
                guard canAcceptRefreshResult(for: account.id) else { continue }
                switch result {
                case let .success(fetchResult):
                    do {
                        let refreshedState = try await repository.record(
                            snapshot: fetchResult.snapshot,
                            resolvedAccountKind: fetchResult.resolvedAccountKind
                        )
                        guard canAcceptRefreshResult(for: account.id) else { continue }
                        state = refreshedState
                        refreshStates[account.id] = .refreshed(fetchResult.snapshot.capturedAt)
                        if account.kind.isManagedSubscription {
                            connectionStates[account.id] = .connected
                            updateProviderIdentity(from: fetchResult, accountID: account.id)
                            updateIdentityWarnings()
                        }
                        refreshWarnings[account.id] = fetchResult.warnings.first
                    } catch {
                        guard canAcceptRefreshResult(for: account.id) else { continue }
                        refreshStates[account.id] = .failed(error.localizedDescription)
                    }
                case let .failure(error):
                    guard canAcceptRefreshResult(for: account.id) else { continue }
                    refreshStates[account.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func refresh(accountID: UUID) async {
        guard
            let account = state.accounts.first(where: { $0.id == accountID }),
            let refreshService,
            let repository,
            !accountIDsPendingRemoval.contains(accountID),
            refreshStates[accountID] != .refreshing,
            connectionStates[accountID]?.isInProgress != true
        else {
            return
        }

        refreshStates[account.id] = .refreshing
        refreshWarnings[account.id] = nil
        do {
            let result = try await refreshService.refresh(account: account)
            guard canAcceptRefreshResult(for: account.id) else { return }
            let refreshedState = try await repository.record(
                snapshot: result.snapshot,
                resolvedAccountKind: result.resolvedAccountKind
            )
            guard canAcceptRefreshResult(for: account.id) else { return }
            state = refreshedState
            refreshStates[account.id] = .refreshed(result.snapshot.capturedAt)
            if account.kind.isManagedSubscription {
                connectionStates[account.id] = .connected
                updateProviderIdentity(from: result, accountID: account.id)
                updateIdentityWarnings()
            }
            refreshWarnings[account.id] = result.warnings.first
        } catch {
            guard canAcceptRefreshResult(for: account.id) else { return }
            refreshStates[account.id] = .failed(error.localizedDescription)
        }
    }

    func connectChatGPT(accountID: UUID) async {
        guard
            let account = account(withID: accountID),
            account.kind.isChatGPTSubscription,
            let chatGPTProvider,
            connectionStates[accountID]?.isInProgress != true,
            refreshStates[accountID] != .refreshing
        else {
            return
        }

        connectionStates[accountID] = .starting
        providerIdentities[accountID] = nil
        updateIdentityWarnings()
        do {
            let connector = try chatGPTProvider.connector(for: accountID)
            let loginSession = try await connector.startManagedLogin(mode: .browser)
            guard
                canAcceptRefreshResult(for: accountID),
                connectionStates[accountID] == .starting
            else {
                try await loginSession.cancel()
                return
            }
            chatGPTLoginSessions[accountID] = loginSession

            switch loginSession.flow {
            case let .browser(_, authorizationURL):
                connectionStates[accountID] = .waitingInBrowser
                guard NSWorkspace.shared.open(authorizationURL) else {
                    try await loginSession.cancel()
                    throw ChatGPTLoginPresentationError.couldNotOpenBrowser
                }
            case let .deviceCode(_, verificationURL, userCode):
                try await loginSession.cancel()
                throw ChatGPTLoginPresentationError.unexpectedDeviceCode(
                    verificationURL: verificationURL,
                    userCode: userCode
                )
            }

            let completion = try await loginSession.waitForCompletion()
            chatGPTLoginSessions[accountID] = nil
            guard
                canAcceptRefreshResult(for: accountID),
                connectionStates[accountID] == .waitingInBrowser
            else {
                return
            }
            guard completion.succeeded else {
                throw ChatGPTLoginPresentationError.providerRejected(
                    completion.errorMessage ?? "ChatGPT sign-in did not complete."
                )
            }
            connectionStates[accountID] = .connected
            await refresh(accountID: accountID)
        } catch {
            chatGPTLoginSessions[accountID] = nil
            guard
                self.account(withID: accountID) != nil,
                let connectionState = connectionStates[accountID],
                connectionState != .idle
            else {
                return
            }
            connectionStates[accountID] = .failed(error.localizedDescription)
            refreshStates[accountID] = .idle
        }
    }

    func cancelChatGPTLogin(accountID: UUID) async {
        let session = chatGPTLoginSessions[accountID]
        chatGPTLoginSessions[accountID] = nil
        connectionStates[accountID] = .idle
        refreshStates[accountID] = .idle
        guard let session else { return }
        do {
            try await session.cancel()
        } catch {
            show(error: error, title: "Could not cancel ChatGPT sign-in")
        }
    }

    func connectClaude(accountID: UUID) async {
        guard
            let account = account(withID: accountID),
            account.kind.isClaudeSubscription,
            let claudeProvider,
            connectionStates[accountID]?.isInProgress != true,
            refreshStates[accountID] != .refreshing
        else {
            return
        }

        connectionStates[accountID] = .starting
        providerIdentities[accountID] = nil
        updateIdentityWarnings()
        do {
            let connector = try claudeProvider.connector(for: accountID)
            let loginSession = try await connector.startManagedLogin()
            guard
                canAcceptRefreshResult(for: accountID),
                connectionStates[accountID] == .starting
            else {
                await loginSession.cancel()
                return
            }
            claudeLoginSessions[accountID] = loginSession
            connectionStates[accountID] = .waitingInBrowser
            _ = try await loginSession.waitForCompletion()
            claudeLoginSessions[accountID] = nil
            guard
                canAcceptRefreshResult(for: accountID),
                connectionStates[accountID] == .waitingInBrowser
            else {
                return
            }
            connectionStates[accountID] = .connected
            await refresh(accountID: accountID)
        } catch {
            claudeLoginSessions[accountID] = nil
            guard
                self.account(withID: accountID) != nil,
                let connectionState = connectionStates[accountID],
                connectionState != .idle
            else {
                return
            }
            connectionStates[accountID] = .failed(error.localizedDescription)
            refreshStates[accountID] = .idle
        }
    }

    func cancelClaudeLogin(accountID: UUID) async {
        let session = claudeLoginSessions[accountID]
        claudeLoginSessions[accountID] = nil
        connectionStates[accountID] = .idle
        refreshStates[accountID] = .idle
        guard let session else { return }
        await session.cancel()
    }

    func openClaudeCodeFallback(accountID: UUID) async {
        guard
            connectionStates[accountID] == .waitingInBrowser,
            let session = claudeLoginSessions[accountID]
        else {
            return
        }
        do {
            let authorizationURL = try await session.manualAuthorizationURL()
            guard NSWorkspace.shared.open(authorizationURL) else {
                throw ClaudeLoginPresentationError.couldNotOpenBrowser
            }
        } catch {
            show(error: error, title: "Could not open code-based sign-in")
        }
    }

    @discardableResult
    func submitClaudeCodeFallback(accountID: UUID, code: String) async -> Bool {
        guard
            connectionStates[accountID] == .waitingInBrowser,
            let session = claudeLoginSessions[accountID]
        else {
            return false
        }
        do {
            try await session.submitManualAuthorizationCode(code)
            return true
        } catch {
            show(error: error, title: "Could not submit Claude sign-in code")
            return false
        }
    }

    func account(withID accountID: UUID) -> ConnectedAccount? {
        state.accounts.first { $0.id == accountID }
    }

    private func canAcceptRefreshResult(for accountID: UUID) -> Bool {
        !accountIDsPendingRemoval.contains(accountID)
            && state.accounts.contains { $0.id == accountID }
    }

    func providerIdentityDescription(for accountID: UUID) -> String? {
        guard let identity = providerIdentities[accountID] else { return nil }
        let components = [identity.accountLabel, identity.planLabel].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func scheduleAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        guard automaticRefreshInterval != .off else {
            automaticRefreshTask = nil
            return
        }

        let delayNanoseconds = UInt64(automaticRefreshInterval.rawValue) * 1_000_000_000
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    private func scheduleClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    private func show(error: Error, title: String) {
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }

    private func updateIdentityWarnings() {
        var warnings: [UUID: String] = [:]
        let identityKeys = providerIdentities.compactMapValues(\.identityKey)
        let assessment = UsageAnalytics.managedAccountIdentityAssessment(
            accounts: state.accounts,
            identityKeys: identityKeys
        )
        let accountsByID = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0) })

        for accountID in assessment.unverifiedAccountIDs {
            guard let account = accountsByID[accountID] else { continue }
            let serviceName = account.kind.isClaudeSubscription ? "Claude" : "ChatGPT"
            warnings[accountID] = "Quota could not verify which \(serviceName) subscription this session belongs to. Refresh or reconnect it before relying on rotation advice."
        }

        for (accountID, duplicateIDs) in assessment.duplicateAccountIDsByAccount {
            guard let account = accountsByID[accountID] else { continue }
            let otherNames = duplicateIDs
                .compactMap { accountsByID[$0]?.displayName }
                .sorted()
                .joined(separator: ", ")
            if !otherNames.isEmpty {
                let serviceName = account.kind.isClaudeSubscription ? "Claude" : "ChatGPT"
                warnings[accountID] = "This \(serviceName) identity is also connected as \(otherNames). Sign each Quota account into a different subscription before relying on rotation advice."
            }
        }
        identityWarnings = warnings
    }

    private func updateProviderIdentity(
        from result: ProviderFetchResult,
        accountID: UUID
    ) {
        providerIdentities[accountID] = ProviderIdentityPresentation(
            accountLabel: result.providerAccountLabel,
            identityKey: result.providerIdentityKey,
            planLabel: result.providerPlanLabel
        )
    }

}

private enum AccountRemovalError: LocalizedError {
    case providerUnavailable

    var errorDescription: String? {
        "The local provider connection is unavailable. Restart Quota and try again."
    }
}

private enum ChatGPTLoginPresentationError: LocalizedError {
    case couldNotOpenBrowser
    case unexpectedDeviceCode(verificationURL: URL, userCode: String)
    case providerRejected(String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenBrowser:
            "Quota could not open the ChatGPT sign-in page."
        case let .unexpectedDeviceCode(verificationURL, userCode):
            "Complete sign-in at \(verificationURL.absoluteString) with code \(userCode)."
        case let .providerRejected(message):
            message
        }
    }
}

private enum ClaudeLoginPresentationError: LocalizedError {
    case couldNotOpenBrowser

    var errorDescription: String? {
        "Quota could not open Claude's code-based sign-in page."
    }
}
