import Foundation

/// A provider boundary for supported ChatGPT Pro/Codex telemetry exposed by `codex app-server`.
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

public actor ChatGPTAppServerConnector: ChatGPTAppServerConnecting {
    private static let maximumReadAttempts = 2
    private static let readRetryDelay: Duration = .milliseconds(500)
    private static let retryableRPCFailureCodes: Set<Int> = [-32_603]

    public nonisolated let configuration: ChatGPTAppServerConfiguration

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
        let operation = { [self] in
            try await withInitializedSession { session in
                let raw: ChatGPTRawAccountReadResponse = try await session.request(
                    method: "account/read",
                    params: ChatGPTAccountReadParams(refreshToken: refreshToken)
                )
                return try raw.validatedDTO()
            }
        }
        if refreshToken {
            return try await withAuthenticationMutation(operation)
        }
        return try await operation()
    }

    private func readTelemetryWithoutAuthenticationGate(
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
        try await withInitializedSession { session in
            let raw: ChatGPTRawRateLimitsResponse = try await session.request(
                method: "account/rateLimits/read"
            )
            return try raw.validatedDTO()
        }
    }

    public func readTokenUsage(threadID: String? = nil) async throws -> ChatGPTTokenUsageDTO {
        let normalizedThreadID = try validatedThreadID(threadID)
        return try await withInitializedSession { session in
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

    /// Reads identity, windows, and account-wide token history over one initialized process.
    public func readTelemetry(
        refreshToken: Bool = false,
        capturedAt: Date = Date()
    ) async throws -> ChatGPTTelemetryDTO {
        if refreshToken {
            return try await withAuthenticationMutation { [self] in
                try await readTelemetryWithoutAuthenticationGate(
                    refreshToken: true,
                    capturedAt: capturedAt
                )
            }
        }
        return try await retryingTransientRead { [self] in
            try await readTelemetryWithoutAuthenticationGate(
                refreshToken: false,
                capturedAt: capturedAt
            )
        }
    }

    /// Starts Codex-managed ChatGPT OAuth. The returned session owns the callback-capable process;
    /// retain it until `waitForCompletion()` or `cancel()` finishes.
    public func startManagedLogin(
        mode: ChatGPTManagedLoginMode = .browser
    ) async throws -> ChatGPTManagedLoginSession {
        let authenticationLease = try await ChatGPTAuthenticationOperationRegistry.shared.acquire(
            codexHomePath: configuration.codexHomeURL.path
        )
        let session: ChatGPTAppServerRPCSession
        do {
            session = try ChatGPTAppServerRPCSession.launch(configuration: configuration)
        } catch {
            await ChatGPTAuthenticationOperationRegistry.shared.release(authenticationLease)
            throw error
        }
        do {
            _ = try await session.initialize(expectedCodexHomeURL: configuration.codexHomeURL)
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
            return ChatGPTManagedLoginSession(
                flow: flow,
                session: session,
                defaultTimeoutSeconds: configuration.loginTimeoutSeconds,
                authenticationLease: authenticationLease
            )
        } catch {
            await session.close()
            await ChatGPTAuthenticationOperationRegistry.shared.release(authenticationLease)
            throw error
        }
    }

    public func logout() async throws {
        try await withAuthenticationMutation { [self] in
            try await withInitializedSession { session in
                let _: ChatGPTEmptyResponse = try await session.request(method: "account/logout")
            }
        }
    }

    private func withAuthenticationMutation<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let lease = try await ChatGPTAuthenticationOperationRegistry.shared.acquire(
            codexHomePath: configuration.codexHomeURL.path
        )
        do {
            let result = try await operation()
            await ChatGPTAuthenticationOperationRegistry.shared.release(lease)
            return result
        } catch {
            await ChatGPTAuthenticationOperationRegistry.shared.release(lease)
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
    private var authenticationLease: ChatGPTAuthenticationOperationLease?

    fileprivate init(
        flow: ChatGPTLoginFlowDTO,
        session: ChatGPTAppServerRPCSession,
        defaultTimeoutSeconds: TimeInterval,
        authenticationLease: ChatGPTAuthenticationOperationLease
    ) {
        self.flow = flow
        self.session = session
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.authenticationLease = authenticationLease
    }

    deinit {
        if let authenticationLease {
            Task {
                await ChatGPTAuthenticationOperationRegistry.shared.release(authenticationLease)
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
            await releaseAuthenticationLease()
            completedResult = completion
            isWaiting = false
            return completion
        } catch {
            await session.close()
            self.session = nil
            await releaseAuthenticationLease()
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
            await releaseAuthenticationLease()
            return
        }
        do {
            let _: ChatGPTEmptyResponse = try await session.request(
                method: "account/login/cancel",
                params: ChatGPTCancelLoginParams(loginId: flow.loginID)
            )
            await session.close()
            self.session = nil
            await releaseAuthenticationLease()
        } catch {
            await session.close()
            self.session = nil
            await releaseAuthenticationLease()
            throw error
        }
    }

    private func releaseAuthenticationLease() async {
        guard let authenticationLease else { return }
        self.authenticationLease = nil
        await ChatGPTAuthenticationOperationRegistry.shared.release(authenticationLease)
    }
}

fileprivate struct ChatGPTAuthenticationOperationLease: Equatable, Sendable {
    let codexHomePath: String
    let id: UUID
}

fileprivate actor ChatGPTAuthenticationOperationRegistry {
    static let shared = ChatGPTAuthenticationOperationRegistry()

    private var activeLeases: [String: UUID] = [:]

    func acquire(codexHomePath: String) throws -> ChatGPTAuthenticationOperationLease {
        guard activeLeases[codexHomePath] == nil else {
            throw ChatGPTConnectorError.authenticationOperationInProgress
        }
        let lease = ChatGPTAuthenticationOperationLease(codexHomePath: codexHomePath, id: UUID())
        activeLeases[codexHomePath] = lease.id
        return lease
    }

    func release(_ lease: ChatGPTAuthenticationOperationLease) {
        guard activeLeases[lease.codexHomePath] == lease.id else { return }
        activeLeases.removeValue(forKey: lease.codexHomePath)
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
