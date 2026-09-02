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

enum ChatGPTConnectionState: Equatable {
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
    let planLabel: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = PersistentState()
    @Published private(set) var isLoaded = false
    @Published var selection: AppRoute? = .overview
    @Published var refreshStates: [UUID: AccountRefreshState] = [:]
    @Published var refreshWarnings: [UUID: String] = [:]
    @Published var chatGPTIdentityWarnings: [UUID: String] = [:]
    @Published var presentedError: PresentedError?
    @Published var isShowingAddAccount = false
    @Published var editingAccount: ConnectedAccount?
    @Published var chatGPTConnectionStates: [UUID: ChatGPTConnectionState] = [:]
    @Published private(set) var automaticRefreshInterval: AutomaticRefreshInterval
    @Published private(set) var now = Date()

    let dataDirectoryURL: URL?

    private let repository: QuotaRepository?
    private let refreshService: UsageRefreshService?
    private let chatGPTProvider: ChatGPTUsageProvider?
    private var automaticRefreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var chatGPTLoginSessions: [UUID: ChatGPTManagedLoginSession] = [:]
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
            self.repository = QuotaRepository(dataStore: dataStore, credentialStore: credentialStore)
            self.refreshService = UsageRefreshService(
                registry: UsageProviderRegistry(
                    chatGPTAccountsDirectoryURL: chatGPTProvider.accountsDirectoryURL
                ),
                credentialStore: credentialStore
            )
            self.chatGPTProvider = chatGPTProvider
            self.dataDirectoryURL = dataStore.directoryURL
        } catch {
            self.repository = nil
            self.refreshService = nil
            self.chatGPTProvider = nil
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
                if account.kind == .chatGPTPro {
                    chatGPTConnectionStates[account.id] = .idle
                }
            }
            updateChatGPTIdentityWarnings()
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
            if account.kind == .chatGPTPro {
                chatGPTConnectionStates[account.id] = .idle
                Task { [weak self] in
                    await self?.connectChatGPT(accountID: account.id)
                }
            } else {
                await refresh(accountID: account.id)
            }
            return true
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
            if account.kind == .chatGPTPro {
                updateChatGPTIdentityWarnings()
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
        var cleanupWarnings: [String] = []
        var providerCredentialCleanupFailed = false
        if account.kind == .chatGPTPro, let session = chatGPTLoginSessions[account.id] {
            do {
                try await session.cancel()
            } catch {
                cleanupWarnings.append(
                    "The active ChatGPT sign-in could not be cleanly cancelled."
                )
            }
            chatGPTLoginSessions[account.id] = nil
        }

        do {
            let removal = try await repository.remove(accountID: account.id)
            state = removal.state
            if removal.credentialCleanupFailed, account.kind.requiresCredential {
                providerCredentialCleanupFailed = true
                cleanupWarnings.append(
                    "The saved Admin API key could not be removed from macOS Keychain."
                )
            }
            refreshStates[account.id] = nil
            refreshWarnings[account.id] = nil
            chatGPTConnectionStates[account.id] = nil
            providerIdentities[account.id] = nil
            updateChatGPTIdentityWarnings()
            selection = .overview
        } catch {
            if self.account(withID: account.id) != nil {
                refreshStates[account.id] = .idle
            }
            show(error: error, title: "Could not remove account")
            return
        }

        if account.kind == .chatGPTPro, let chatGPTProvider {
            do {
                let connector = try chatGPTProvider.connector(for: account.id)
                try await connector.logout()
            } catch {
                cleanupWarnings.append(
                    "Codex could not confirm that its Keychain session was signed out."
                )
            }

            let homeURL = chatGPTProvider.codexHomeURL(for: account.id)
            if FileManager.default.fileExists(atPath: homeURL.path) {
                do {
                    try FileManager.default.removeItem(at: homeURL)
                } catch {
                    cleanupWarnings.append(
                        "Some local ChatGPT connector files could not be removed."
                    )
                }
            }
        }

        if !cleanupWarnings.isEmpty {
            var message = cleanupWarnings.joined(separator: " ")
            if account.kind == .chatGPTPro {
                message += " If needed, remove the matching “Codex Auth” item in Keychain Access."
            } else if providerCredentialCleanupFailed {
                message += " If needed, remove the matching Quota provider credential in Keychain Access."
            }
            presentedError = PresentedError(
                title: "Account removed with a cleanup warning",
                message: message
            )
        }
    }

    func refreshAll() async {
        guard let refreshService, let repository else { return }
        guard !isRefreshing else { return }
        let refreshableAccounts = accounts.filter { account in
            !accountIDsPendingRemoval.contains(account.id)
                && chatGPTConnectionStates[account.id]?.isInProgress != true
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
                        let refreshedState = try await repository.record(snapshot: fetchResult.snapshot)
                        guard canAcceptRefreshResult(for: account.id) else { continue }
                        state = refreshedState
                        refreshStates[account.id] = .refreshed(fetchResult.snapshot.capturedAt)
                        if account.kind == .chatGPTPro {
                            chatGPTConnectionStates[account.id] = .connected
                            updateProviderIdentity(from: fetchResult, accountID: account.id)
                            updateChatGPTIdentityWarnings()
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
            chatGPTConnectionStates[accountID]?.isInProgress != true
        else {
            return
        }

        refreshStates[account.id] = .refreshing
        refreshWarnings[account.id] = nil
        do {
            let result = try await refreshService.refresh(account: account)
            guard canAcceptRefreshResult(for: account.id) else { return }
            let refreshedState = try await repository.record(snapshot: result.snapshot)
            guard canAcceptRefreshResult(for: account.id) else { return }
            state = refreshedState
            refreshStates[account.id] = .refreshed(result.snapshot.capturedAt)
            if account.kind == .chatGPTPro {
                chatGPTConnectionStates[account.id] = .connected
                updateProviderIdentity(from: result, accountID: account.id)
                updateChatGPTIdentityWarnings()
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
            account.kind == .chatGPTPro,
            let chatGPTProvider,
            chatGPTConnectionStates[accountID]?.isInProgress != true,
            refreshStates[accountID] != .refreshing
        else {
            return
        }

        chatGPTConnectionStates[accountID] = .starting
        do {
            let connector = try chatGPTProvider.connector(for: accountID)
            let loginSession = try await connector.startManagedLogin(mode: .browser)
            chatGPTLoginSessions[accountID] = loginSession

            switch loginSession.flow {
            case let .browser(_, authorizationURL):
                chatGPTConnectionStates[accountID] = .waitingInBrowser
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
            guard completion.succeeded else {
                throw ChatGPTLoginPresentationError.providerRejected(
                    completion.errorMessage ?? "ChatGPT sign-in did not complete."
                )
            }
            chatGPTConnectionStates[accountID] = .connected
            await refresh(accountID: accountID)
        } catch {
            chatGPTLoginSessions[accountID] = nil
            guard
                self.account(withID: accountID) != nil,
                let connectionState = chatGPTConnectionStates[accountID],
                connectionState != .idle
            else {
                return
            }
            chatGPTConnectionStates[accountID] = .failed(error.localizedDescription)
            refreshStates[accountID] = .failed(error.localizedDescription)
        }
    }

    func cancelChatGPTLogin(accountID: UUID) async {
        guard let session = chatGPTLoginSessions[accountID] else { return }
        chatGPTLoginSessions[accountID] = nil
        chatGPTConnectionStates[accountID] = .idle
        refreshStates[accountID] = .idle
        do {
            try await session.cancel()
        } catch {
            show(error: error, title: "Could not cancel ChatGPT sign-in")
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

    private func updateChatGPTIdentityWarnings() {
        let chatGPTAccounts = state.accounts.filter { $0.kind == .chatGPTPro }
        let accountsByIdentity = Dictionary(grouping: chatGPTAccounts) { account in
            providerIdentities[account.id]?
                .accountLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        var warnings: [UUID: String] = [:]
        for (identity, matchingAccounts) in accountsByIdentity {
            guard identity != nil, matchingAccounts.count > 1 else { continue }
            for account in matchingAccounts {
                let otherNames = matchingAccounts
                    .filter { $0.id != account.id }
                    .map(\.displayName)
                    .sorted()
                    .joined(separator: ", ")
                warnings[account.id] = "This ChatGPT identity is also connected as \(otherNames). Sign each Quota account into a different ChatGPT plan before relying on rotation advice."
            }
        }
        chatGPTIdentityWarnings = warnings
    }

    private func updateProviderIdentity(
        from result: ProviderFetchResult,
        accountID: UUID
    ) {
        providerIdentities[accountID] = ProviderIdentityPresentation(
            accountLabel: result.providerAccountLabel,
            planLabel: result.providerPlanLabel
        )
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
