import Foundation

public enum QuotaRepositoryError: LocalizedError, Equatable {
    case accountAlreadyExists
    case accountNotFound
    case credentialRequired

    public var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            "An account with this identifier already exists."
        case .accountNotFound:
            "The account no longer exists."
        case .credentialRequired:
            "This account needs an admin API key."
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
    private let dataStore: any PersistentStateStoring
    private let credentialStore: any CredentialStoring
    private var loadedState: PersistentState?
    private var accountIDsPendingRemoval: Set<UUID> = []
    private var accountRemovalGenerations: [UUID: UInt64] = [:]

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
        var state = try await load()
        guard !state.accounts.contains(where: { $0.id == account.id }) else {
            throw QuotaRepositoryError.accountAlreadyExists
        }
        if account.kind.requiresCredential, credential == nil {
            throw QuotaRepositoryError.credentialRequired
        }

        if let credential {
            try credentialStore.save(credential, for: account.id)
        }
        state.accounts.append(try account.validated())
        if let initialSnapshot {
            guard initialSnapshot.accountID == account.id else {
                if credential != nil {
                    try? credentialStore.deleteCredential(for: account.id)
                }
                throw QuotaRepositoryError.accountNotFound
            }
            state.snapshots.append(initialSnapshot)
        }

        do {
            try await dataStore.save(state)
            loadedState = state
            return state
        } catch {
            if credential != nil {
                try? credentialStore.deleteCredential(for: account.id)
            }
            throw error
        }
    }

    public func update(
        account: ConnectedAccount,
        replacementCredential: ProviderCredential?
    ) async throws -> PersistentState {
        var state = try await load()
        guard
            !accountIDsPendingRemoval.contains(account.id),
            let accountIndex = state.accounts.firstIndex(where: { $0.id == account.id })
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        let previousCredential = try credentialStore.credential(for: account.id)
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

    public func record(snapshot: UsageSnapshot) async throws -> PersistentState {
        var state = try await load()
        guard
            !accountIDsPendingRemoval.contains(snapshot.accountID),
            state.accounts.contains(where: { $0.id == snapshot.accountID })
        else {
            throw QuotaRepositoryError.accountNotFound
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

        if let replacementIndex = snapshotIndexToReplace(with: snapshot, in: state.snapshots) {
            state.snapshots[replacementIndex] = snapshot
        } else {
            state.snapshots.append(snapshot)
        }
        try await dataStore.save(state)
        guard
            !accountIDsPendingRemoval.contains(snapshot.accountID),
            accountRemovalGenerations[snapshot.accountID, default: 0] == removalGeneration
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        loadedState = state
        return state
    }

    public func remove(accountID: UUID) async throws -> AccountRemovalResult {
        var state = try await load()
        guard
            !accountIDsPendingRemoval.contains(accountID),
            state.accounts.contains(where: { $0.id == accountID })
        else {
            throw QuotaRepositoryError.accountNotFound
        }
        accountIDsPendingRemoval.insert(accountID)
        accountRemovalGenerations[accountID, default: 0] &+= 1
        defer { accountIDsPendingRemoval.remove(accountID) }

        state.accounts.removeAll { $0.id == accountID }
        state.snapshots.removeAll { $0.accountID == accountID }
        try await dataStore.save(state)
        loadedState = state

        let credentialCleanupFailed: Bool
        do {
            try credentialStore.deleteCredential(for: accountID)
            credentialCleanupFailed = false
        } catch {
            credentialCleanupFailed = true
        }
        return AccountRemovalResult(
            state: state,
            credentialCleanupFailed: credentialCleanupFailed
        )
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
