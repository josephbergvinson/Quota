import Foundation

public enum QuotaRepositoryError: LocalizedError, Equatable {
    case accountAlreadyExists
    case accountKindChangeNotAllowed
    case accountNotFound
    case credentialSaveFailedAccountRetained
    case credentialRequired
    case invalidResolvedAccountKind
    case snapshotSourceMismatch

    public var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            "An account with this identifier already exists."
        case .accountKindChangeNotAllowed:
            "An existing account cannot change its connection type. Remove it and add a new account instead."
        case .accountNotFound:
            "The account no longer exists."
        case .credentialSaveFailedAccountRetained:
            "The account was saved, but its admin API key was not. Add the key by editing the account, or remove it and try again."
        case .credentialRequired:
            "This account needs an admin API key."
        case .invalidResolvedAccountKind:
            "The provider returned an account plan that does not match this connection."
        case .snapshotSourceMismatch:
            "The usage reading came from a different provider connection."
        }
    }
}

public struct AccountRemovalResult: Sendable, Equatable {
    public let state: PersistentState
    public let credentialCleanupFailed: Bool

    public init(state: PersistentState, credentialCleanupFailed: Bool) {
        self.state = state
        self.credentialCleanupFailed = credentialCleanupFailed
    }
}

protocol PersistentStateStoring: Sendable {
    var directoryURL: URL { get }
    func load() async throws -> PersistentState
    func save(_ state: PersistentState) async throws
}

extension LocalDataStore: PersistentStateStoring {}

public actor QuotaRepository {
    private struct StateTransactionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let dataStore: any PersistentStateStoring
    private let credentialStore: any CredentialStoring
    private var loadedState: PersistentState?
    private var accountIDsPendingRemoval: Set<UUID> = []
    private var accountRemovalGenerations: [UUID: UInt64] = [:]
    private var stateTransactionIsActive = false
    private var stateTransactionWaiters: [StateTransactionWaiter] = []

    public nonisolated var dataDirectoryURL: URL {
        dataStore.directoryURL
    }

    public init(
        dataStore: LocalDataStore,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.dataStore = dataStore
        self.credentialStore = credentialStore
    }

    init(
        dataStore: any PersistentStateStoring,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.dataStore = dataStore
        self.credentialStore = credentialStore
    }

    public func load() async throws -> PersistentState {
        try await acquireStateTransaction()
        defer { releaseStateTransaction() }
        return try await loadState()
    }

    private func loadState() async throws -> PersistentState {
        if let loadedState {
            return loadedState
        }
        let state = try await dataStore.load()
        loadedState = state
        return state
    }

    public func add(
        account: ConnectedAccount,
        credential: ProviderCredential?,
        initialSnapshot: UsageSnapshot? = nil
    ) async throws -> PersistentState {
        try await acquireStateTransaction()
        defer { releaseStateTransaction() }

        let previousState = try await loadState()
        var state = previousState
        guard !state.accounts.contains(where: { $0.id == account.id }) else {
            throw QuotaRepositoryError.accountAlreadyExists
        }
        if account.kind.requiresCredential, credential == nil {
            throw QuotaRepositoryError.credentialRequired
        }
        if let initialSnapshot {
            guard initialSnapshot.accountID == account.id else {
                throw QuotaRepositoryError.accountNotFound
            }
            guard initialSnapshot.source.isCompatible(with: account.kind) else {
                throw QuotaRepositoryError.snapshotSourceMismatch
            }
        }

        state.accounts.append(try account.validated())
        if let initialSnapshot {
            state.snapshots.append(initialSnapshot)
        }

        // Persist the reconnectable account record before its secret. A crash can therefore leave
        // an account that asks for its key again, but can never leave an invisible Keychain item
        // with no owning account or in-app removal path.
        try await dataStore.save(state)
        loadedState = state

        guard let credential else {
            return state
        }

        do {
            try credentialStore.save(credential, for: account.id)
            return state
        } catch let credentialError {
            do {
                try await dataStore.save(previousState)
                loadedState = previousState
            } catch {
                // The durable account remains the security-safe state: it is visible, contains no
                // credential, and can be repaired or removed. Surface that outcome explicitly.
                throw QuotaRepositoryError.credentialSaveFailedAccountRetained
            }
            throw credentialError
        }
    }

    public func update(
        account: ConnectedAccount,
        replacementCredential: ProviderCredential?
    ) async throws -> PersistentState {
        guard !accountIDsPendingRemoval.contains(account.id) else {
            throw QuotaRepositoryError.accountNotFound
        }
        try await acquireStateTransaction()
        defer { releaseStateTransaction() }

        var state = try await loadState()
        guard
            !accountIDsPendingRemoval.contains(account.id),
            let accountIndex = state.accounts.firstIndex(where: { $0.id == account.id })
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        let existingAccount = state.accounts[accountIndex]
        // An account ID owns credentials and provider state for exactly one connection type.
        // Provider-discovered subscription tiers use the separate atomic `record` path below.
        guard account.kind == existingAccount.kind else {
            throw QuotaRepositoryError.accountKindChangeNotAllowed
        }
        let previousCredential: ProviderCredential? = if existingAccount.kind.requiresCredential {
            try credentialStore.credential(for: account.id)
        } else {
            nil
        }
        if let replacementCredential {
            try credentialStore.save(replacementCredential, for: account.id)
        }
        state.accounts[accountIndex] = try account.validated()

        do {
            try await dataStore.save(state)
            loadedState = state
            return state
        } catch {
            if replacementCredential != nil {
                if let previousCredential {
                    try? credentialStore.save(previousCredential, for: account.id)
                } else {
                    try? credentialStore.deleteCredential(for: account.id)
                }
            }
            throw error
        }
    }

    public func record(
        snapshot: UsageSnapshot,
        resolvedAccountKind: AccountKind? = nil
    ) async throws -> PersistentState {
        guard !accountIDsPendingRemoval.contains(snapshot.accountID) else {
            throw QuotaRepositoryError.accountNotFound
        }
        try await acquireStateTransaction()
        defer { releaseStateTransaction() }

        var state = try await loadState()
        guard
            !accountIDsPendingRemoval.contains(snapshot.accountID),
            let accountIndex = state.accounts.firstIndex(where: { $0.id == snapshot.accountID })
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        guard snapshot.source.isCompatible(with: state.accounts[accountIndex].kind) else {
            throw QuotaRepositoryError.snapshotSourceMismatch
        }
        let removalGeneration = accountRemovalGenerations[snapshot.accountID, default: 0]
        if
            snapshot.source != .manual,
            let latest = state.snapshots
                .filter({ $0.accountID == snapshot.accountID })
                .max(by: { $0.capturedAt < $1.capturedAt }),
            snapshot.capturedAt <= latest.capturedAt
        {
            return state
        }

        if let resolvedAccountKind, resolvedAccountKind != state.accounts[accountIndex].kind {
            let existingAccount = state.accounts[accountIndex]
            guard
                existingAccount.kind.isManagedSubscription,
                resolvedAccountKind.isManagedSubscription,
                existingAccount.kind.dataSource == resolvedAccountKind.dataSource
            else {
                throw QuotaRepositoryError.invalidResolvedAccountKind
            }
            state.accounts[accountIndex] = try ConnectedAccount(
                id: existingAccount.id,
                displayName: existingAccount.displayName,
                kind: resolvedAccountKind,
                organizationIdentifier: existingAccount.organizationIdentifier,
                createdAt: existingAccount.createdAt
            )
        }

        if let replacementIndex = snapshotIndexToReplace(with: snapshot, in: state.snapshots) {
            state.snapshots[replacementIndex] = snapshot
        } else {
            state.snapshots.append(snapshot)
        }
        try await dataStore.save(state)
        loadedState = state
        guard
            !accountIDsPendingRemoval.contains(snapshot.accountID),
            accountRemovalGenerations[snapshot.accountID, default: 0] == removalGeneration
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        return state
    }

    public func remove(accountID: UUID) async throws -> AccountRemovalResult {
        guard !accountIDsPendingRemoval.contains(accountID) else {
            throw QuotaRepositoryError.accountNotFound
        }
        accountIDsPendingRemoval.insert(accountID)
        accountRemovalGenerations[accountID, default: 0] &+= 1
        defer { accountIDsPendingRemoval.remove(accountID) }

        try await acquireStateTransaction()
        defer { releaseStateTransaction() }

        var state = try await loadState()
        guard state.accounts.contains(where: { $0.id == accountID }) else {
            throw QuotaRepositoryError.accountNotFound
        }

        let accountRequiresCredential = state.accounts
            .first(where: { $0.id == accountID })?
            .kind.requiresCredential ?? false
        if accountRequiresCredential {
            // Delete the secret before removing its owning account record. If Keychain refuses the
            // deletion, the account and history remain durable and the user can retry. A crash or
            // state-save failure after this point leaves a visible, reconnectable account rather
            // than an orphaned credential with no in-app removal path.
            try credentialStore.deleteCredential(for: accountID)
        }

        state.accounts.removeAll { $0.id == accountID }
        state.snapshots.removeAll { $0.accountID == accountID }
        try await dataStore.save(state)
        loadedState = state

        return AccountRemovalResult(
            state: state,
            credentialCleanupFailed: false
        )
    }

    /// Mutations copy the current value before persisting it. Actor isolation alone is insufficient
    /// because awaiting the data store makes the repository reentrant, allowing a second mutation
    /// to derive from and later publish the same old value. This FIFO transaction gate keeps the
    /// complete load-transform-save-publish sequence linear while still allowing a cancelled waiter
    /// to leave the queue promptly without blocking the operations behind it.
    private func acquireStateTransaction() async throws {
        try Task.checkCancellation()
        guard stateTransactionIsActive else {
            stateTransactionIsActive = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            if Task.isCancelled {
                return false
            }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    stateTransactionWaiters.append(
                        StateTransactionWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelStateTransactionWaiter(id: waiterID)
            }
        }

        guard acquired else {
            throw CancellationError()
        }
        if Task.isCancelled {
            releaseStateTransaction()
            throw CancellationError()
        }
    }

    private func releaseStateTransaction() {
        guard !stateTransactionWaiters.isEmpty else {
            stateTransactionIsActive = false
            return
        }
        let next = stateTransactionWaiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    private func cancelStateTransactionWaiter(id: UUID) {
        guard let index = stateTransactionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = stateTransactionWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Internal visibility gives deterministic concurrency tests a scheduling barrier without
    /// exposing transaction mechanics in Quota's public API.
    func pendingStateTransactionCount() -> Int {
        stateTransactionWaiters.count
    }

    private func snapshotIndexToReplace(
        with newSnapshot: UsageSnapshot,
        in snapshots: [UsageSnapshot]
    ) -> Int? {
        guard
            newSnapshot.source != .manual,
            let latestIndex = snapshots.indices
                .filter({ snapshots[$0].accountID == newSnapshot.accountID })
                .max(by: { snapshots[$0].capturedAt < snapshots[$1].capturedAt })
        else {
            return nil
        }

        let latest = snapshots[latestIndex]
        let oldResetSignature = resetSignature(for: latest)
        let newResetSignature = resetSignature(for: newSnapshot)
        if !oldResetSignature.isEmpty || !newResetSignature.isEmpty {
            return oldResetSignature == newResetSignature ? latestIndex : nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.isDate(latest.capturedAt, inSameDayAs: newSnapshot.capturedAt)
            ? latestIndex
            : nil
    }

    private func resetSignature(for snapshot: UsageSnapshot) -> [String] {
        (snapshot.quotaWindows.value ?? [])
            .compactMap { window in
                window.resetsAt.map {
                    "\(window.identifier)|\(Int($0.timeIntervalSince1970))"
                }
            }
            .sorted()
    }
}
