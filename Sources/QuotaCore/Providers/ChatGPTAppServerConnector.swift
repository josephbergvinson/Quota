import Foundation

/// A provider boundary for supported ChatGPT Plus and Pro telemetry exposed by `codex app-server`.
///
/// Every connector instance is scoped to one canonical `CODEX_HOME`. Callers should create a
/// distinct account directory (and connector) for every ChatGPT account they manage.
public protocol ChatGPTAppServerConnecting: Sendable {
    func readAccount(refreshToken: Bool) async throws -> ChatGPTAccountReadDTO
    func readRateLimits() async throws -> ChatGPTRateLimitsDTO
    func readTokenUsage(threadID: String?) async throws -> ChatGPTTokenUsageDTO
    func readTelemetry(refreshToken: Bool, capturedAt: Date) async throws -> ChatGPTTelemetryDTO
    func startManagedLogin(mode: ChatGPTManagedLoginMode) async throws -> ChatGPTManagedLoginSession
    func logout() async throws
}

struct ChatGPTProfileOperationLease: Equatable, Sendable {
    let profileKey: String
    let id: UUID
}

/// Serializes every Codex process that can touch one managed ChatGPT profile. Retirement is
/// sticky: it rejects queued and future work before waiting for the active operation to finish,
/// so no late process can recreate profile state after account removal deletes the directory.
actor ChatGPTProfileOperationCoordinator {
    static let shared = ChatGPTProfileOperationCoordinator()

    private struct Waiter {
        let id: UUID
        let isRetirement: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeLeaseIDs: [String: UUID] = [:]
    private var retiredProfileKeys = Set<String>()
    private var waitersByProfileKey: [String: [Waiter]] = [:]

    func acquire(profileKey: String) async -> ChatGPTProfileOperationLease? {
        guard !Task.isCancelled else { return nil }
        guard !retiredProfileKeys.contains(profileKey) else { return nil }
        guard activeLeaseIDs[profileKey] == nil else {
            return await waitForLease(profileKey: profileKey)
        }

        let lease = ChatGPTProfileOperationLease(profileKey: profileKey, id: UUID())
        activeLeaseIDs[profileKey] = lease.id
        return lease
    }

    func retireAndAcquire(profileKey: String) async -> ChatGPTProfileOperationLease {
        retiredProfileKeys.insert(profileKey)

        let existingWaiters = waitersByProfileKey.removeValue(forKey: profileKey) ?? []
        let retirementWaiters = existingWaiters.filter(\.isRetirement)
        existingWaiters
            .filter { !$0.isRetirement }
            .forEach { $0.continuation.resume(returning: false) }
        waitersByProfileKey[profileKey] = retirementWaiters.isEmpty ? nil : retirementWaiters

        if activeLeaseIDs[profileKey] == nil, retirementWaiters.isEmpty {
            let lease = ChatGPTProfileOperationLease(profileKey: profileKey, id: UUID())
            activeLeaseIDs[profileKey] = lease.id
            return lease
        }

        let waiterID = UUID()
        let acquired = await withCheckedContinuation { continuation in
            waitersByProfileKey[profileKey, default: []].append(
                Waiter(
                    id: waiterID,
                    isRetirement: true,
                    continuation: continuation
                )
            )
        }
        precondition(acquired, "A profile-retirement lease cannot be rejected")
        return ChatGPTProfileOperationLease(profileKey: profileKey, id: waiterID)
    }

    func release(_ lease: ChatGPTProfileOperationLease) {
        guard activeLeaseIDs[lease.profileKey] == lease.id else { return }

        var waiters = waitersByProfileKey[lease.profileKey] ?? []
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if retiredProfileKeys.contains(lease.profileKey), !next.isRetirement {
                next.continuation.resume(returning: false)
                continue
            }

            let nextLease = ChatGPTProfileOperationLease(
                profileKey: lease.profileKey,
                id: next.id
            )
            activeLeaseIDs[lease.profileKey] = nextLease.id
            waitersByProfileKey[lease.profileKey] = waiters.isEmpty ? nil : waiters
            next.continuation.resume(returning: true)
            return
        }

        activeLeaseIDs.removeValue(forKey: lease.profileKey)
        waitersByProfileKey[lease.profileKey] = nil
    }

    func reactivate(profileKey: String) {
        retiredProfileKeys.remove(profileKey)
    }

    func isRetired(profileKey: String) -> Bool {
        retiredProfileKeys.contains(profileKey)
    }

    func queuedOperationCount(profileKey: String) -> Int {
        waitersByProfileKey[profileKey]?.count ?? 0
    }

    private func waitForLease(profileKey: String) async -> ChatGPTProfileOperationLease? {
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            if Task.isCancelled {
                return false
            }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled || retiredProfileKeys.contains(profileKey) {
                    continuation.resume(returning: false)
                } else {
                    waitersByProfileKey[profileKey, default: []].append(
                        Waiter(
                            id: waiterID,
                            isRetirement: false,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID, profileKey: profileKey)
            }
        }

        let lease = ChatGPTProfileOperationLease(profileKey: profileKey, id: waiterID)
        if Task.isCancelled, acquired {
            release(lease)
            return nil
        }
        return acquired ? lease : nil
    }

    private func cancelWaiter(id: UUID, profileKey: String) {
        guard
            var waiters = waitersByProfileKey[profileKey],
            let index = waiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        waitersByProfileKey[profileKey] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: false)
    }
}

public actor ChatGPTAppServerConnector: ChatGPTAppServerConnecting {
    private static let maximumReadAttempts = 2
    private static let readRetryDelay: Duration = .milliseconds(500)
    private static let retryableRPCFailureCodes: Set<Int> = [-32_603]

    public nonisolated let configuration: ChatGPTAppServerConfiguration

    private nonisolated var profileKey: String {
        chatGPTProfileCoordinationKey(configuration.codexHomeURL)
    }

    public init(configuration: ChatGPTAppServerConfiguration) {
        self.configuration = configuration
    }

    public init(
        codexHomeURL: URL,
        codexExecutableURL: URL? = nil,
        requestTimeoutSeconds: TimeInterval = 30,
        loginTimeoutSeconds: TimeInterval = 600
    ) throws {
        self.configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: codexHomeURL,
            codexExecutableURL: codexExecutableURL,
            requestTimeoutSeconds: requestTimeoutSeconds,
            loginTimeoutSeconds: loginTimeoutSeconds
        )
    }

    public func readAccount(refreshToken: Bool = false) async throws -> ChatGPTAccountReadDTO {
        try await withProfileAccess { [self] in
            try await withInitializedSession { session in
                let raw: ChatGPTRawAccountReadResponse = try await session.request(
                    method: "account/read",
                    params: ChatGPTAccountReadParams(refreshToken: refreshToken)
                )
                return try raw.validatedDTO()
            }
        }
    }

    private func readTelemetryWithoutCoordination(
        refreshToken: Bool,
        capturedAt: Date
    ) async throws -> ChatGPTTelemetryDTO {
        try await withInitializedSession { session in
            let raw: ChatGPTRawAccountReadResponse = try await session.request(
                method: "account/read",
                params: ChatGPTAccountReadParams(refreshToken: refreshToken)
            )
            let account = try raw.validatedDTO()
            guard let signedInAccount = account.account else {
                throw ChatGPTConnectorError.notAuthenticated
            }
            guard case .chatGPT = signedInAccount else {
                throw ChatGPTConnectorError.unsupportedAuthenticationMode(
                    Self.authenticationModeName(signedInAccount)
                )
            }

            let rawLimits: ChatGPTRawRateLimitsResponse = try await session.request(
                method: "account/rateLimits/read"
            )
            let rawUsage: ChatGPTRawTokenUsageResponse = try await session.request(
                method: "account/usage/read"
            )
            return ChatGPTTelemetryDTO(
                capturedAt: capturedAt,
                account: account,
                rateLimits: try rawLimits.validatedDTO(),
                tokenUsage: try rawUsage.validatedDTO()
            )
        }
    }

    public func readRateLimits() async throws -> ChatGPTRateLimitsDTO {
        try await withProfileAccess { [self] in
            try await withInitializedSession { session in
                let raw: ChatGPTRawRateLimitsResponse = try await session.request(
                    method: "account/rateLimits/read"
                )
                return try raw.validatedDTO()
            }
        }
    }

    public func readTokenUsage(threadID: String? = nil) async throws -> ChatGPTTokenUsageDTO {
        let normalizedThreadID = try validatedThreadID(threadID)
        return try await withProfileAccess { [self] in
            try await withInitializedSession { session in
                let raw: ChatGPTRawTokenUsageResponse
                if let normalizedThreadID {
                    raw = try await session.request(
                        method: "account/usage/read",
                        params: ChatGPTUsageReadParams(threadId: normalizedThreadID)
                    )
                } else {
                    raw = try await session.request(method: "account/usage/read")
                }
                return try raw.validatedDTO()
            }
        }
    }

    /// Reads identity, windows, and account-wide token history over one initialized process.
    public func readTelemetry(
        refreshToken: Bool = false,
        capturedAt: Date = Date()
    ) async throws -> ChatGPTTelemetryDTO {
        try await withProfileAccess { [self] in
            if refreshToken {
                return try await readTelemetryWithoutCoordination(
                    refreshToken: true,
                    capturedAt: capturedAt
                )
            }
            return try await retryingTransientRead { [self] in
                try await readTelemetryWithoutCoordination(
                    refreshToken: false,
                    capturedAt: capturedAt
                )
            }
        }
    }

    /// Starts Codex-managed ChatGPT OAuth. The returned session owns the callback-capable process;
    /// retain it until `waitForCompletion()` or `cancel()` finishes.
    public func startManagedLogin(
        mode: ChatGPTManagedLoginMode = .browser
    ) async throws -> ChatGPTManagedLoginSession {
        let profileLease = try await acquireProfileLease()
        let session: ChatGPTAppServerRPCSession
        do {
            session = try ChatGPTAppServerRPCSession.launch(configuration: configuration)
        } catch {
            await ChatGPTProfileOperationCoordinator.shared.release(profileLease)
            throw error
        }
        do {
            _ = try await session.initialize(expectedCodexHomeURL: configuration.codexHomeURL)
            try Task.checkCancellation()
            guard await ChatGPTProfileOperationCoordinator.shared.isRetired(
                profileKey: profileKey
            ) == false else {
                throw ChatGPTConnectorError.profileRetired
            }
            let raw: ChatGPTRawLoginResponse
            switch mode {
            case .browser:
                raw = try await session.request(
                    method: "account/login/start",
                    params: ChatGPTBrowserLoginParams()
                )
            case .deviceCode:
                raw = try await session.request(
                    method: "account/login/start",
                    params: ChatGPTDeviceCodeLoginParams()
                )
            }
            let flow = try raw.validatedFlow(for: mode)
            try Task.checkCancellation()
            guard await ChatGPTProfileOperationCoordinator.shared.isRetired(
                profileKey: profileKey
            ) == false else {
                throw ChatGPTConnectorError.profileRetired
            }
            return ChatGPTManagedLoginSession(
                flow: flow,
                session: session,
                defaultTimeoutSeconds: configuration.loginTimeoutSeconds,
                profileLease: profileLease
            )
        } catch {
            await session.close()
            await ChatGPTProfileOperationCoordinator.shared.release(profileLease)
            throw error
        }
    }

    public func logout() async throws {
        try await withProfileAccess { [self] in
            try await logoutWithoutCoordination()
        }
    }

    /// Permanently blocks new profile work, waits for any in-flight read or login to finish, then
    /// signs the profile out while holding exclusive access. Call `reactivateProfile` only when a
    /// higher-level removal fails and keeps the account available for a retry.
    public func retireAndLogout() async throws {
        let lease = await ChatGPTProfileOperationCoordinator.shared.retireAndAcquire(
            profileKey: profileKey
        )
        do {
            try Task.checkCancellation()
            try await logoutWithoutCoordination()
            await ChatGPTProfileOperationCoordinator.shared.release(lease)
        } catch {
            await ChatGPTProfileOperationCoordinator.shared.release(lease)
            throw error
        }
    }

    public static func reactivateProfile(codexHomeURL: URL) async {
        await ChatGPTProfileOperationCoordinator.shared.reactivate(
            profileKey: chatGPTProfileCoordinationKey(codexHomeURL)
        )
    }

    private func logoutWithoutCoordination() async throws {
        try await withInitializedSession { session in
            let _: ChatGPTEmptyResponse = try await session.request(method: "account/logout")
        }
    }

    private func withProfileAccess<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let lease = try await acquireProfileLease()
        do {
            let result = try await operation()
            await ChatGPTProfileOperationCoordinator.shared.release(lease)
            return result
        } catch {
            await ChatGPTProfileOperationCoordinator.shared.release(lease)
            throw error
        }
    }

    private func acquireProfileLease() async throws -> ChatGPTProfileOperationLease {
        let lease = await ChatGPTProfileOperationCoordinator.shared.acquire(
            profileKey: profileKey
        )
        guard let lease else {
            try Task.checkCancellation()
            throw ChatGPTConnectorError.profileRetired
        }
        do {
            try Task.checkCancellation()
            return lease
        } catch {
            await ChatGPTProfileOperationCoordinator.shared.release(lease)
            throw error
        }
    }

    /// Read-only app-server calls can occasionally time out or return a transient internal error
    /// while Codex fetches provider data. Retrying in a new initialized process is safe and avoids
    /// reusing a session whose late response could otherwise be mistaken for the retry's response.
    private func retryingTransientRead<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as ChatGPTConnectorError {
                guard
                    Self.isRetryableReadError(error),
                    attempt < Self.maximumReadAttempts
                else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: Self.readRetryDelay)
            }
        }
    }

    private static func isRetryableReadError(_ error: ChatGPTConnectorError) -> Bool {
        switch error {
        case .requestTimedOut:
            true
        case let .rpcFailure(code):
            retryableRPCFailureCodes.contains(code)
        default:
            false
        }
    }

    private func withInitializedSession<Result: Sendable>(
        _ operation: (ChatGPTAppServerRPCSession) async throws -> Result
    ) async throws -> Result {
        let session = try ChatGPTAppServerRPCSession.launch(configuration: configuration)
        do {
            _ = try await session.initialize(expectedCodexHomeURL: configuration.codexHomeURL)
            let result = try await operation(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    private static func authenticationModeName(_ account: ChatGPTAccountDTO) -> String {
        switch account {
        case .chatGPT:
            "chatgpt"
        case .apiKey:
            "apiKey"
        case .amazonBedrock:
            "amazonBedrock"
        }
    }
}

/// Owns an in-flight managed sign-in and its local callback listener.
public actor ChatGPTManagedLoginSession {
    public nonisolated let flow: ChatGPTLoginFlowDTO

    private var session: ChatGPTAppServerRPCSession?
    private let defaultTimeoutSeconds: TimeInterval
    private var completedResult: ChatGPTLoginCompletionDTO?
    private var wasCancelled = false
    private var isWaiting = false
    private var profileLease: ChatGPTProfileOperationLease?

    fileprivate init(
        flow: ChatGPTLoginFlowDTO,
        session: ChatGPTAppServerRPCSession,
        defaultTimeoutSeconds: TimeInterval,
        profileLease: ChatGPTProfileOperationLease
    ) {
        self.flow = flow
        self.session = session
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.profileLease = profileLease
    }

    deinit {
        if let profileLease {
            Task {
                await ChatGPTProfileOperationCoordinator.shared.release(profileLease)
            }
        }
    }

    /// Waits for `account/login/completed`, then always shuts down the callback process.
    public func waitForCompletion(
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> ChatGPTLoginCompletionDTO {
        if let completedResult {
            return completedResult
        }
        guard !wasCancelled, let session else {
            throw ChatGPTConnectorError.loginFinished
        }
        guard !isWaiting else {
            throw ChatGPTConnectorError.loginFinished
        }

        let timeout = timeoutSeconds ?? defaultTimeoutSeconds
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else {
            throw ChatGPTConnectorError.invalidTimeout
        }

        isWaiting = true
        do {
            let raw: ChatGPTRawLoginCompletion = try await session.nextNotification(
                method: "account/login/completed",
                timeoutSeconds: timeout
            )
            guard !wasCancelled else {
                throw ChatGPTConnectorError.loginFinished
            }
            let completion = try raw.validatedDTO()
            guard completion.loginID == nil || completion.loginID == flow.loginID else {
                throw ChatGPTConnectorError.invalidProviderPayload
            }
            await session.close()
            self.session = nil
            await releaseProfileLease()
            completedResult = completion
            isWaiting = false
            return completion
        } catch {
            await session.close()
            self.session = nil
            await releaseProfileLease()
            isWaiting = false
            throw error
        }
    }

    /// Cancels this login id at the app-server and terminates the callback process. Idempotent.
    public func cancel() async throws {
        guard completedResult == nil, !wasCancelled, let session else { return }
        wasCancelled = true
        if isWaiting {
            // A concurrent waiter owns stdout. Closing the callback-capable process cancels the
            // pending flow without introducing a second JSONL reader on the same connection.
            await session.close()
            self.session = nil
            await releaseProfileLease()
            return
        }
        do {
            let _: ChatGPTEmptyResponse = try await session.request(
                method: "account/login/cancel",
                params: ChatGPTCancelLoginParams(loginId: flow.loginID)
            )
            await session.close()
            self.session = nil
            await releaseProfileLease()
        } catch {
            await session.close()
            self.session = nil
            await releaseProfileLease()
            throw error
        }
    }

    private func releaseProfileLease() async {
        guard let profileLease else { return }
        self.profileLease = nil
        await ChatGPTProfileOperationCoordinator.shared.release(profileLease)
    }
}

private func validatedThreadID(_ threadID: String?) throws -> String? {
    guard let threadID else { return nil }
    let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        !normalized.isEmpty,
        normalized.count <= 512,
        !normalized.contains("\n"),
        !normalized.contains("\r")
    else {
        throw ChatGPTConnectorError.invalidProviderPayload
    }
    return normalized
}

func chatGPTProfileCoordinationKey(_ url: URL) -> String {
    let canonicalURL = canonicalChatGPTProfileURL(url)
    let path = canonicalURL.path.precomposedStringWithCanonicalMapping
    return normalizedChatGPTProfileCoordinationPath(
        path,
        volumeSupportsCaseSensitiveNames: chatGPTVolumeSupportsCaseSensitiveNames(
            for: canonicalURL
        )
    )
}

private func canonicalChatGPTProfileURL(_ url: URL) -> URL {
    let standardizedURL = url.standardizedFileURL
    let path = standardizedURL.path
    for systemAlias in ["/var", "/tmp", "/etc"] {
        if path == systemAlias || path.hasPrefix("\(systemAlias)/") {
            return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
        }
    }
    return standardizedURL.resolvingSymlinksInPath().standardizedFileURL
}

func normalizedChatGPTProfileCoordinationPath(
    _ path: String,
    volumeSupportsCaseSensitiveNames: Bool?
) -> String {
    volumeSupportsCaseSensitiveNames == false ? path.lowercased() : path
}

private func chatGPTVolumeSupportsCaseSensitiveNames(for url: URL) -> Bool? {
    var candidate = canonicalChatGPTProfileURL(url)
    while !FileManager.default.fileExists(atPath: candidate.path) {
        let parent = canonicalChatGPTProfileURL(candidate.deletingLastPathComponent())
        guard parent.path != candidate.path else { return nil }
        candidate = parent
    }
    return try? candidate
        .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames
}
