import Darwin
import Foundation
import Security

public enum ClaudeCodeConnectorError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case unsupportedClaudeCodeVersion
    case untrustedExecutable
    case invalidConfigurationDirectory
    case invalidTimeout
    case processLaunchFailed
    case processExited(status: Int32)
    case requestTimedOut
    case outputTooLarge
    case invalidResponse
    case unsupportedUsageProtocol
    case usageUnavailable
    case notAuthenticated
    case unsupportedAuthenticationMode
    case unsupportedSubscriptionPlan
    case loginNotCompleted
    case loginTimedOut
    case loginFinished
    case manualLoginUnavailable
    case invalidManualAuthorizationCode
    case profileRetired

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Install or update Claude Code before connecting this account."
        case .unsupportedClaudeCodeVersion:
            "Quota needs a current Claude Code installation to read subscription usage."
        case .untrustedExecutable:
            "Quota found Claude Code, but macOS could not verify it as an Anthropic-signed app."
        case .invalidConfigurationDirectory:
            "Quota could not prepare this account's private Claude configuration directory."
        case .invalidTimeout:
            "The Claude Code operation has an invalid timeout."
        case .processExited:
            "Claude Code could not complete the operation. Update Claude Code, then try again."
        case .processLaunchFailed:
            "Quota could not start Claude Code."
        case .requestTimedOut:
            "Claude Code did not finish the operation in time."
        case .outputTooLarge, .invalidResponse:
            "Claude Code returned data Quota could not read."
        case .unsupportedUsageProtocol:
            "This Claude Code version does not expose subscription usage to Quota."
        case .usageUnavailable:
            "Claude Code did not make subscription limits available. Try refreshing again shortly."
        case .notAuthenticated:
            "Connect this Claude account in the browser before refreshing it."
        case .unsupportedAuthenticationMode:
            "This Claude Code profile is not connected to a Claude Pro or Max subscription."
        case .unsupportedSubscriptionPlan:
            "Quota currently supports Claude Pro and Max subscriptions, not Team or Enterprise plans."
        case .loginNotCompleted:
            "Claude sign-in was not completed. Try again and finish the browser approval."
        case .loginTimedOut:
            "Claude sign-in timed out. Start it again and finish the browser approval."
        case .loginFinished:
            "This Claude sign-in session has already finished."
        case .manualLoginUnavailable:
            "Claude has not made the code-based sign-in available yet. Wait a moment, then try again."
        case .invalidManualAuthorizationCode:
            "Paste the complete sign-in code Claude showed in the browser."
        case .profileRetired:
            "This Claude account is being removed."
        }
    }
}

public struct ClaudeCodeConfiguration: Equatable, Sendable {
    public let configurationDirectoryURL: URL
    public let workingDirectoryURL: URL
    public let executableURL: URL
    public let requestTimeoutSeconds: TimeInterval
    public let loginTimeoutSeconds: TimeInterval

    public init(
        configurationDirectoryURL: URL,
        executableURL: URL? = nil,
        requestTimeoutSeconds: TimeInterval = 15,
        loginTimeoutSeconds: TimeInterval = 600
    ) throws {
        guard
            configurationDirectoryURL.isFileURL,
            configurationDirectoryURL.path.hasPrefix("/"),
            configurationDirectoryURL.standardizedFileURL.path != "/"
        else {
            throw ClaudeCodeConnectorError.invalidConfigurationDirectory
        }
        guard
            requestTimeoutSeconds.isFinite,
            requestTimeoutSeconds > 0,
            requestTimeoutSeconds <= 300,
            loginTimeoutSeconds.isFinite,
            loginTimeoutSeconds > 0,
            loginTimeoutSeconds <= 3_600
        else {
            throw ClaudeCodeConnectorError.invalidTimeout
        }

        let resolvedExecutable: URL
        if let executableURL {
            resolvedExecutable = try ClaudeCodeExecutableLocator.selectNewestCompatible(
                from: [executableURL],
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
                isTrusted: ClaudeCodeExecutableLocator.isAnthropicSigned
            )
        } else {
            resolvedExecutable = try ClaudeCodeExecutableLocator.discover()
        }

        let standardizedDirectory = canonicalClaudeConfigurationURL(
            configurationDirectoryURL
        )
        self.configurationDirectoryURL = standardizedDirectory
        self.workingDirectoryURL = standardizedDirectory
            .appendingPathComponent("QuotaWorkingDirectory", isDirectory: true)
        self.executableURL = resolvedExecutable
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }

    init(
        trustedExecutableURL: URL,
        configurationDirectoryURL: URL,
        requestTimeoutSeconds: TimeInterval = 15,
        loginTimeoutSeconds: TimeInterval = 600
    ) throws {
        guard
            configurationDirectoryURL.isFileURL,
            configurationDirectoryURL.path.hasPrefix("/"),
            configurationDirectoryURL.standardizedFileURL.path != "/"
        else {
            throw ClaudeCodeConnectorError.invalidConfigurationDirectory
        }
        guard
            requestTimeoutSeconds.isFinite,
            requestTimeoutSeconds > 0,
            requestTimeoutSeconds <= 300,
            loginTimeoutSeconds.isFinite,
            loginTimeoutSeconds > 0,
            loginTimeoutSeconds <= 3_600
        else {
            throw ClaudeCodeConnectorError.invalidTimeout
        }

        let standardizedDirectory = canonicalClaudeConfigurationURL(
            configurationDirectoryURL
        )
        self.configurationDirectoryURL = standardizedDirectory
        self.workingDirectoryURL = standardizedDirectory
            .appendingPathComponent("QuotaWorkingDirectory", isDirectory: true)
        self.executableURL = trustedExecutableURL.standardizedFileURL
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }
}

protocol ClaudeCodeConnecting: Sendable {
    func authenticationStatus() async throws -> ClaudeCodeAuthStatusDTO
    func readSubscriptionUsage() async throws -> ClaudeCodeSubscriptionUsage
    func logout() async throws
}

struct ClaudeCodeSubscriptionUsage: Equatable, Sendable {
    let status: ClaudeCodeAuthStatusDTO
    let usage: ClaudeCodeUsageDTO
}

/// Serializes every Claude Code process that can touch one account profile. Retiring a profile
/// immediately rejects queued and future work, then waits for the active operation to finish.
/// This keeps a late refresh from recreating credentials or configuration after account removal.
actor ClaudeCodeProfileOperationCoordinator {
    static let shared = ClaudeCodeProfileOperationCoordinator()

    private struct Waiter {
        let id: UUID
        let isRetirement: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeProfileKeys = Set<String>()
    private var retiredProfileKeys = Set<String>()
    private var waitersByProfileKey: [String: [Waiter]] = [:]

    func acquire(profileKey: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !retiredProfileKeys.contains(profileKey) else { return false }
        guard activeProfileKeys.contains(profileKey) else {
            activeProfileKeys.insert(profileKey)
            return true
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
        if Task.isCancelled {
            if acquired {
                release(profileKey: profileKey)
            }
            return false
        }
        return acquired
    }

    func retireAndAcquire(profileKey: String) async {
        retiredProfileKeys.insert(profileKey)

        let existingWaiters = waitersByProfileKey.removeValue(forKey: profileKey) ?? []
        let retirementWaiters = existingWaiters.filter(\.isRetirement)
        existingWaiters
            .filter { !$0.isRetirement }
            .forEach { $0.continuation.resume(returning: false) }

        guard activeProfileKeys.contains(profileKey) else {
            activeProfileKeys.insert(profileKey)
            retirementWaiters.forEach { $0.continuation.resume(returning: true) }
            return
        }

        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waitersByProfileKey[profileKey] = retirementWaiters + [
                Waiter(id: UUID(), isRetirement: true, continuation: continuation)
            ]
        }
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

    func release(profileKey: String) {
        var waiters = waitersByProfileKey[profileKey] ?? []
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            waitersByProfileKey[profileKey] = waiters.isEmpty ? nil : waiters
            next.continuation.resume(returning: true)
        } else {
            activeProfileKeys.remove(profileKey)
            waitersByProfileKey[profileKey] = nil
        }
    }

    func isRetired(profileKey: String) -> Bool {
        retiredProfileKeys.contains(profileKey)
    }

    func queuedOperationCount(profileKey: String) -> Int {
        waitersByProfileKey[profileKey]?.count ?? 0
    }

    func reactivate(profileKey: String) {
        retiredProfileKeys.remove(profileKey)
    }
}

/// Runs only the Anthropic-signed Claude Code executable. OAuth credentials remain owned by
/// Claude Code in the account-specific `CLAUDE_CONFIG_DIR`; Quota never reads or copies them.
public actor ClaudeCodeConnector: ClaudeCodeConnecting {
    public nonisolated let configuration: ClaudeCodeConfiguration

    private nonisolated var profileKey: String {
        claudeProfileCoordinationKey(configuration.configurationDirectoryURL)
    }

    public init(configuration: ClaudeCodeConfiguration) {
        self.configuration = configuration
    }

    public init(
        configurationDirectoryURL: URL,
        executableURL: URL? = nil,
        requestTimeoutSeconds: TimeInterval = 15,
        loginTimeoutSeconds: TimeInterval = 600
    ) throws {
        self.configuration = try ClaudeCodeConfiguration(
            configurationDirectoryURL: configurationDirectoryURL,
            executableURL: executableURL,
            requestTimeoutSeconds: requestTimeoutSeconds,
            loginTimeoutSeconds: loginTimeoutSeconds
        )
    }

    public func authenticationStatus() async throws -> ClaudeCodeAuthStatusDTO {
        try await withProfileAccess {
            try await self.authenticationStatusWithoutCoordination()
        }
    }

    fileprivate func authenticationStatusWithoutCoordination() async throws -> ClaudeCodeAuthStatusDTO {
        let result = try await ClaudeCodeProcess.run(
            configuration: configuration,
            arguments: ["auth", "status", "--json"],
            standardInput: nil,
            captureOutput: true,
            timeoutSeconds: configuration.requestTimeoutSeconds
        )
        guard result.status == 0 || result.status == 1 else {
            throw ClaudeCodeConnectorError.processExited(status: result.status)
        }
        do {
            return try JSONDecoder().decode(ClaudeCodeAuthStatusDTO.self, from: result.output)
        } catch {
            throw ClaudeCodeConnectorError.unsupportedClaudeCodeVersion
        }
    }

    public func startManagedLogin() async throws -> ClaudeCodeManagedLoginSession {
        try await acquireProfileLease()
        do {
            try Task.checkCancellation()
            // This harmless status command is a version/capability check. In particular, it keeps
            // an older signed binary from receiving browser-login arguments it may not understand.
            let preflightStatus = try await authenticationStatusWithoutCoordination()
            try Task.checkCancellation()
            let profileWasRetiredDuringPreflight = await ClaudeCodeProfileOperationCoordinator.shared.isRetired(
                profileKey: profileKey
            )
            guard !profileWasRetiredDuringPreflight else {
                throw ClaudeCodeConnectorError.profileRetired
            }
            let loginOutputState = ClaudeCodeLoginOutputState()
            do {
                let process = try ClaudeCodeProcess.launch(
                    configuration: configuration,
                    arguments: ["auth", "login", "--claudeai"],
                    standardInput: nil,
                    captureOutput: false,
                    keepsStandardInputOpen: true,
                    outputObserver: { chunk in
                        loginOutputState.consume(chunk)
                    }
                )
                let profileWasRetired = await ClaudeCodeProfileOperationCoordinator.shared
                    .isRetired(profileKey: profileKey)
                if Task.isCancelled || profileWasRetired {
                    loginOutputState.close()
                    await process.cancel()
                    try Task.checkCancellation()
                    throw ClaudeCodeConnectorError.profileRetired
                }
                return ClaudeCodeManagedLoginSession(
                    process: process,
                    connector: self,
                    profileKey: profileKey,
                    timeoutSeconds: configuration.loginTimeoutSeconds,
                    preflightWasLoggedIn: preflightStatus.loggedIn,
                    loginOutputState: loginOutputState
                )
            } catch {
                loginOutputState.close()
                throw error
            }
        } catch {
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
            throw error
        }
    }

    public func logout() async throws {
        try await withProfileAccess {
            try await self.logoutWithoutCoordination()
        }
    }

    public func retireAndLogout() async throws {
        await ClaudeCodeProfileOperationCoordinator.shared.retireAndAcquire(profileKey: profileKey)
        do {
            let status = try await authenticationStatusWithoutCoordination()
            if status.loggedIn {
                try await logoutWithoutCoordination()
            }
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
        } catch {
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
            throw error
        }
    }

    public static func retireProfile(configurationDirectoryURL: URL) async {
        let profileKey = claudeProfileCoordinationKey(configurationDirectoryURL)
        await ClaudeCodeProfileOperationCoordinator.shared.retireAndAcquire(profileKey: profileKey)
        await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
    }

    public static func reactivateProfile(configurationDirectoryURL: URL) async {
        await ClaudeCodeProfileOperationCoordinator.shared.reactivate(
            profileKey: claudeProfileCoordinationKey(configurationDirectoryURL)
        )
    }

    private func logoutWithoutCoordination() async throws {
        let result = try await ClaudeCodeProcess.run(
            configuration: configuration,
            arguments: ["auth", "logout"],
            standardInput: nil,
            captureOutput: false,
            timeoutSeconds: configuration.requestTimeoutSeconds
        )
        guard result.status == 0 else {
            throw ClaudeCodeConnectorError.processExited(status: result.status)
        }
    }

    func readSubscriptionUsage() async throws -> ClaudeCodeSubscriptionUsage {
        try await withProfileAccess {
            let status = try await self.authenticationStatusWithoutCoordination()
            guard status.loggedIn else {
                throw ClaudeCodeConnectorError.notAuthenticated
            }
            guard status.isClaudeSubscriptionAuthentication else {
                throw ClaudeCodeConnectorError.unsupportedAuthenticationMode
            }
            guard status.hasSupportedClaudeSubscriptionPlan else {
                throw ClaudeCodeConnectorError.unsupportedSubscriptionPlan
            }
            let usage = try await self.readUsageWithoutCoordination()
            return ClaudeCodeSubscriptionUsage(status: status, usage: usage)
        }
    }

    private func readUsageWithoutCoordination() async throws -> ClaudeCodeUsageDTO {
        let requestID = UUID().uuidString.lowercased()
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "get_usage"]
        ]
        var requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: request)
        } catch {
            throw ClaudeCodeConnectorError.invalidResponse
        }
        requestData.append(0x0A)

        let result = try await ClaudeCodeProcess.run(
            configuration: configuration,
            arguments: [
                "--print",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--safe-mode",
                "--no-session-persistence",
                "--tools", ""
            ],
            standardInput: requestData,
            captureOutput: true,
            timeoutSeconds: configuration.requestTimeoutSeconds
        )
        guard result.status == 0 else {
            throw ClaudeCodeConnectorError.processExited(status: result.status)
        }
        return try ClaudeCodeUsageResponseParser.parse(result.output, matching: requestID)
    }

    private func withProfileAccess<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquireProfileLease()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
            return value
        } catch {
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
            throw error
        }
    }

    private func acquireProfileLease() async throws {
        let acquired = await ClaudeCodeProfileOperationCoordinator.shared.acquire(
            profileKey: profileKey
        )
        guard acquired else {
            try Task.checkCancellation()
            throw ClaudeCodeConnectorError.profileRetired
        }
        do {
            try Task.checkCancellation()
        } catch {
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
            throw error
        }
    }
}

/// Owns one browser sign-in process. A bounded parser keeps only Claude's manual fallback URL in
/// memory while the session is active; OAuth URLs, codes, and state are never persisted or logged.
public actor ClaudeCodeManagedLoginSession {
    private var process: ClaudeCodeProcess?
    private let connector: ClaudeCodeConnector
    private let profileKey: String
    private let timeoutSeconds: TimeInterval
    private let preflightWasLoggedIn: Bool
    private let loginOutputState: ClaudeCodeLoginOutputState
    private var completedStatus: ClaudeCodeAuthStatusDTO?
    private var isWaiting = false
    private var wasCancelled = false
    private var holdsProfileLease = true

    fileprivate init(
        process: ClaudeCodeProcess,
        connector: ClaudeCodeConnector,
        profileKey: String,
        timeoutSeconds: TimeInterval,
        preflightWasLoggedIn: Bool,
        loginOutputState: ClaudeCodeLoginOutputState
    ) {
        self.process = process
        self.connector = connector
        self.profileKey = profileKey
        self.timeoutSeconds = timeoutSeconds
        self.preflightWasLoggedIn = preflightWasLoggedIn
        self.loginOutputState = loginOutputState
    }

    deinit {
        guard holdsProfileLease else { return }
        let process = process
        let profileKey = profileKey
        loginOutputState.close()
        Task.detached {
            await process?.cancel()
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
        }
    }

    public func waitForCompletion() async throws -> ClaudeCodeAuthStatusDTO {
        if let completedStatus {
            return completedStatus
        }
        guard !wasCancelled, !isWaiting, let process else {
            throw ClaudeCodeConnectorError.loginFinished
        }
        isWaiting = true
        defer { isWaiting = false }
        var helperExitedSuccessfully = false

        do {
            let result = try await process.waitForDirectExit(timeoutSeconds: timeoutSeconds)
            guard !wasCancelled else { throw CancellationError() }
            self.process = nil
            guard result.status == 0 else {
                throw ClaudeCodeConnectorError.loginNotCompleted
            }
            helperExitedSuccessfully = true
            let status = try await connector.authenticationStatusWithoutCoordination()
            guard !wasCancelled else { throw CancellationError() }
            guard status.loggedIn else {
                throw ClaudeCodeConnectorError.loginNotCompleted
            }
            guard status.isClaudeSubscriptionAuthentication else {
                throw ClaudeCodeConnectorError.unsupportedAuthenticationMode
            }
            guard status.hasSupportedClaudeSubscriptionPlan else {
                throw ClaudeCodeConnectorError.unsupportedSubscriptionPlan
            }
            completedStatus = status
            loginOutputState.close()
            await releaseProfileLeaseIfNeeded()
            return status
        } catch {
            if error as? ClaudeCodeConnectorError == .requestTimedOut, !wasCancelled {
                // If the helper itself timed out, only a logged-out-to-logged-in transition proves
                // this attempt committed credentials. If the helper exited successfully and only
                // the first verification timed out, a successful retry is authoritative by itself.
                if Task.isCancelled {
                    self.process = nil
                    loginOutputState.close()
                    await releaseProfileLeaseIfNeeded()
                    throw CancellationError()
                }
                let recoveredStatus = try? await connector.authenticationStatusWithoutCoordination()
                if wasCancelled || Task.isCancelled {
                    self.process = nil
                    loginOutputState.close()
                    await releaseProfileLeaseIfNeeded()
                    throw CancellationError()
                }
                if
                    helperExitedSuccessfully || !preflightWasLoggedIn,
                    let status = recoveredStatus,
                    status.loggedIn
                {
                    guard status.isClaudeSubscriptionAuthentication else {
                        self.process = nil
                        loginOutputState.close()
                        await releaseProfileLeaseIfNeeded()
                        throw ClaudeCodeConnectorError.unsupportedAuthenticationMode
                    }
                    guard status.hasSupportedClaudeSubscriptionPlan else {
                        self.process = nil
                        loginOutputState.close()
                        await releaseProfileLeaseIfNeeded()
                        throw ClaudeCodeConnectorError.unsupportedSubscriptionPlan
                    }
                    self.process = nil
                    completedStatus = status
                    loginOutputState.close()
                    await releaseProfileLeaseIfNeeded()
                    return status
                }
            }
            let presentedError: Error
            if error as? ClaudeCodeConnectorError == .requestTimedOut {
                presentedError = ClaudeCodeConnectorError.loginTimedOut
            } else {
                presentedError = error
            }
            await process.cancel()
            self.process = nil
            loginOutputState.close()
            await releaseProfileLeaseIfNeeded()
            throw presentedError
        }
    }

    public func manualAuthorizationURL(waitUpTo timeoutSeconds: TimeInterval = 2) async throws -> URL {
        guard
            !wasCancelled,
            completedStatus == nil,
            process?.isRunning == true,
            timeoutSeconds.isFinite,
            timeoutSeconds >= 0,
            timeoutSeconds <= 10
        else {
            throw ClaudeCodeConnectorError.manualLoginUnavailable
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(timeoutSeconds * 1_000_000_000)
        repeat {
            try Task.checkCancellation()
            guard !wasCancelled, completedStatus == nil, process?.isRunning == true else {
                throw ClaudeCodeConnectorError.loginFinished
            }
            if let url = loginOutputState.authorizationURL() {
                return url
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline || process?.isRunning != true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        } while true
        throw ClaudeCodeConnectorError.manualLoginUnavailable
    }

    public func submitManualAuthorizationCode(_ rawCode: String) throws {
        guard !wasCancelled, completedStatus == nil, let process, process.isRunning else {
            throw ClaudeCodeConnectorError.loginFinished
        }
        let code = try Self.validatedManualAuthorizationCode(rawCode)
        try process.writeLine(code)
    }

    public func cancel() async {
        guard completedStatus == nil, !wasCancelled else { return }
        wasCancelled = true
        let process = self.process
        self.process = nil
        loginOutputState.close()
        await process?.cancel()
        if !isWaiting {
            await releaseProfileLeaseIfNeeded()
        }
    }

    private func releaseProfileLeaseIfNeeded() async {
        guard holdsProfileLease else { return }
        holdsProfileLease = false
        await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
    }

    static func validatedManualAuthorizationCode(_ rawCode: String) throws -> String {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !code.isEmpty,
            code.utf8.count <= ClaudeCodeProcess.maximumInteractiveLineBytes,
            code.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            })
        else {
            throw ClaudeCodeConnectorError.invalidManualAuthorizationCode
        }
        let components = code.split(separator: "#", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else {
            throw ClaudeCodeConnectorError.invalidManualAuthorizationCode
        }
        return code
    }
}

extension ClaudeCodeAuthStatusDTO {
    var isClaudeSubscriptionAuthentication: Bool {
        guard loggedIn else { return false }
        let normalizedMethod = authMethod?
            .lowercased()
            .filter(\.isLetter) ?? ""
        return normalizedMethod == "claudeai"
    }

    var hasSupportedClaudeSubscriptionPlan: Bool {
        guard
            let plan = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !plan.isEmpty
        else {
            return true
        }
        return resolvedClaudeSubscriptionAccountKind(from: plan) != nil
    }
}

struct ClaudeCodeProcessResult: Sendable {
    let status: Int32
    let output: Data
}

private final class ClaudeCodeOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Data, ClaudeCodeConnectorError>?

    func complete(with result: Result<Data, ClaudeCodeConnectorError>) {
        lock.withLock {
            guard storedResult == nil else { return }
            storedResult = result
        }
    }

    func result() -> Result<Data, ClaudeCodeConnectorError>? {
        lock.withLock { storedResult }
    }
}

private final class ClaudeCodeOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let outputState: ClaudeCodeOutputState
    private let captureOutput: Bool
    private let outputObserver: (@Sendable (Data) -> Void)?
    private let lock = NSLock()
    private var output = Data()
    private var isFinished = false

    init(
        handle: FileHandle,
        outputState: ClaudeCodeOutputState,
        captureOutput: Bool,
        outputObserver: (@Sendable (Data) -> Void)?
    ) {
        self.handle = handle
        self.outputState = outputState
        self.captureOutput = captureOutput
        self.outputObserver = outputObserver
    }

    func start() {
        handle.readabilityHandler = { [weak self] readableHandle in
            self?.consume(readableHandle.availableData)
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else {
            finish(with: nil)
            return
        }
        guard lock.withLock({ !isFinished }) else { return }

        outputObserver?(chunk)
        var failure: ClaudeCodeConnectorError?
        lock.withLock {
            guard !isFinished, captureOutput else { return }
            guard chunk.count <= ClaudeCodeProcess.maximumCapturedOutputBytes - output.count else {
                isFinished = true
                failure = .outputTooLarge
                return
            }
            output.append(chunk)
        }
        if let failure {
            finishAlreadyMarked(with: .failure(failure))
        }
    }

    private func finish(with failure: ClaudeCodeConnectorError?) {
        let result: Result<Data, ClaudeCodeConnectorError>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if let failure {
                return .failure(failure)
            }
            return .success(output)
        }
        guard let result else { return }
        finishAlreadyMarked(with: result)
    }

    private func finishAlreadyMarked(with result: Result<Data, ClaudeCodeConnectorError>) {
        handle.readabilityHandler = nil
        outputState.complete(with: result)
        try? handle.close()
    }
}

final class ClaudeCodeLoginOutputState: @unchecked Sendable {
    private static let marker = "If the browser didn't open, visit:"
    private static let maximumScannedBytes = 256 * 1_024
    private static let maximumBufferBytes = 64 * 1_024
    private static let authorizationHost = "claude.com"
    private static let authorizationPath = "/cai/oauth/authorize"

    private let lock = NSLock()
    private var scannedBytes = 0
    private var buffer = Data()
    private var storedAuthorizationURL: URL?
    private var isClosed = false

    func consume(_ chunk: Data) {
        lock.withLock {
            guard
                !isClosed,
                storedAuthorizationURL == nil,
                scannedBytes < Self.maximumScannedBytes
            else {
                return
            }
            let remaining = Self.maximumScannedBytes - scannedBytes
            let accepted = chunk.prefix(remaining)
            scannedBytes += accepted.count
            buffer.append(contentsOf: accepted)
            if buffer.count > Self.maximumBufferBytes {
                buffer.removeFirst(buffer.count - Self.maximumBufferBytes)
            }
            storedAuthorizationURL = Self.parseAuthorizationURL(from: buffer)
            if storedAuthorizationURL != nil {
                buffer.removeAll(keepingCapacity: false)
            }
        }
    }

    func authorizationURL() -> URL? {
        lock.withLock { isClosed ? nil : storedAuthorizationURL }
    }

    func close() {
        lock.withLock {
            isClosed = true
            scannedBytes = 0
            buffer.removeAll(keepingCapacity: false)
            storedAuthorizationURL = nil
        }
    }

    private static func parseAuthorizationURL(from data: Data) -> URL? {
        let output = String(decoding: data, as: UTF8.self)
        guard
            let markerRange = output.range(of: marker),
            let schemeRange = output.range(of: "https://", range: markerRange.upperBound..<output.endIndex)
        else {
            return nil
        }
        let suffix = output[schemeRange.lowerBound...]
        let end = suffix.firstIndex { character in
            character.unicodeScalars.contains { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || scalar.value < 0x20
                    || scalar.value == 0x7F
            }
        } ?? suffix.endIndex
        var value = String(suffix[..<end])
        while let last = value.last, ["\"", "'", ")", "]"].contains(last) {
            value.removeLast()
        }
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            host == authorizationHost,
            components.path.lowercased() == authorizationPath,
            let url = components.url
        else {
            return nil
        }
        return url
    }
}

final class ClaudeCodeProcess: @unchecked Sendable {
    static let maximumCapturedOutputBytes = 4 * 1_024 * 1_024
    static let maximumProtocolLineBytes = 1 * 1_024 * 1_024
    static let maximumInteractiveLineBytes = 8 * 1_024

    private let process: Process
    private let inputHandle: FileHandle?
    private let outputHandle: FileHandle?
    private let outputReader: ClaudeCodeOutputReader?
    private let outputState: ClaudeCodeOutputState?
    private let lock = NSLock()
    private var finishedResult: ClaudeCodeProcessResult?
    private var didCancel = false

    static func run(
        configuration: ClaudeCodeConfiguration,
        arguments: [String],
        standardInput: Data?,
        captureOutput: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> ClaudeCodeProcessResult {
        try Task.checkCancellation()
        let process = try launch(
            configuration: configuration,
            arguments: arguments,
            standardInput: standardInput,
            captureOutput: captureOutput
        )
        return try await process.wait(timeoutSeconds: timeoutSeconds)
    }

    static func launch(
        configuration: ClaudeCodeConfiguration,
        arguments: [String],
        standardInput: Data?,
        captureOutput: Bool,
        keepsStandardInputOpen: Bool = false,
        outputObserver: (@Sendable (Data) -> Void)? = nil
    ) throws -> ClaudeCodeProcess {
        try prepareDirectory(configuration.configurationDirectoryURL)
        try prepareDirectory(configuration.workingDirectoryURL)

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.environment = sanitizedClaudeEnvironment(
            configurationDirectoryURL: configuration.configurationDirectoryURL
        )
        let inputPipe: Pipe?
        if standardInput != nil || keepsStandardInputOpen {
            let pipe = Pipe()
            inputPipe = pipe
            process.standardInput = pipe
        } else {
            inputPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let outputPipe: Pipe?
        if captureOutput || outputObserver != nil {
            let pipe = Pipe()
            outputPipe = pipe
            process.standardOutput = pipe
            process.standardError = outputObserver == nil ? FileHandle.nullDevice : pipe
        } else {
            outputPipe = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw ClaudeCodeConnectorError.processLaunchFailed
        }

        let outputState = outputPipe.map { _ in ClaudeCodeOutputState() }
        let outputReader: ClaudeCodeOutputReader? = outputPipe.flatMap { pipe in
            guard let outputState else { return nil }
            return ClaudeCodeOutputReader(
                handle: pipe.fileHandleForReading,
                outputState: outputState,
                captureOutput: captureOutput,
                outputObserver: outputObserver
            )
        }
        outputReader?.start()

        if let standardInput, let inputPipe {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                if !keepsStandardInputOpen {
                    try inputPipe.fileHandleForWriting.close()
                }
            } catch {
                process.terminate()
                outputReader?.cancel()
                try? outputPipe?.fileHandleForReading.close()
                throw ClaudeCodeConnectorError.processLaunchFailed
            }
        }

        return ClaudeCodeProcess(
            process: process,
            inputHandle: inputPipe?.fileHandleForWriting,
            outputHandle: outputPipe?.fileHandleForReading,
            outputReader: outputReader,
            outputState: outputState
        )
    }

    private init(
        process: Process,
        inputHandle: FileHandle?,
        outputHandle: FileHandle?,
        outputReader: ClaudeCodeOutputReader?,
        outputState: ClaudeCodeOutputState?
    ) {
        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.outputReader = outputReader
        self.outputState = outputState
    }

    deinit {
        terminateWithoutWaiting()
    }

    var isRunning: Bool {
        process.isRunning
    }

    func writeLine(_ value: String) throws {
        guard
            value.utf8.count <= Self.maximumInteractiveLineBytes,
            let inputHandle,
            process.isRunning
        else {
            throw ClaudeCodeConnectorError.loginFinished
        }
        var data = Data(value.utf8)
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw ClaudeCodeConnectorError.loginFinished
        }
    }

    func wait(timeoutSeconds: TimeInterval) async throws -> ClaudeCodeProcessResult {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 3_600 else {
            throw ClaudeCodeConnectorError.invalidTimeout
        }
        if let result = cachedResult() {
            return result
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(timeoutSeconds * 1_000_000_000)

        do {
            return try await withTaskCancellationHandler {
                while process.isRunning || outputIsPending {
                    if Task.isCancelled {
                        await cancel()
                        throw CancellationError()
                    }
                    if DispatchTime.now().uptimeNanoseconds >= deadline {
                        await cancel()
                        throw ClaudeCodeConnectorError.requestTimedOut
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                return try finish()
            } onCancel: { [weak self] in
                self?.terminateWithoutWaiting()
            }
        } catch {
            await cancel()
            throw error
        }
    }

    /// Browser helpers can leave a short-lived descendant holding the output pipe open after the
    /// signed-in parent has exited. Login completion is therefore keyed to the direct process;
    /// structured commands continue using `wait`, which drains all captured output before return.
    func waitForDirectExit(timeoutSeconds: TimeInterval) async throws -> ClaudeCodeProcessResult {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 3_600 else {
            throw ClaudeCodeConnectorError.invalidTimeout
        }
        if let result = cachedResult() {
            return result
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(timeoutSeconds * 1_000_000_000)

        do {
            return try await withTaskCancellationHandler {
                while process.isRunning {
                    if Task.isCancelled {
                        await cancel()
                        throw CancellationError()
                    }
                    if DispatchTime.now().uptimeNanoseconds >= deadline {
                        await cancel()
                        throw ClaudeCodeConnectorError.requestTimedOut
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }

                try? inputHandle?.close()
                outputReader?.cancel()
                try? outputHandle?.close()
                let result = ClaudeCodeProcessResult(
                    status: process.terminationStatus,
                    output: Data()
                )
                lock.withLock {
                    finishedResult = result
                }
                return result
            } onCancel: { [weak self] in
                self?.terminateWithoutWaiting()
            }
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        terminateAndWaitBounded()
        try? inputHandle?.close()
        outputReader?.cancel()
        try? outputHandle?.close()
    }

    private func finish() throws -> ClaudeCodeProcessResult {
        try? inputHandle?.close()
        defer { try? outputHandle?.close() }
        let output: Data
        if let outputState {
            guard let result = outputState.result() else {
                throw ClaudeCodeConnectorError.invalidResponse
            }
            output = try result.get()
        } else {
            output = Data()
        }
        let result = ClaudeCodeProcessResult(
            status: process.terminationStatus,
            output: output
        )
        lock.withLock {
            finishedResult = result
        }
        return result
    }

    private func cachedResult() -> ClaudeCodeProcessResult? {
        lock.withLock { finishedResult }
    }

    private var outputIsPending: Bool {
        guard let outputState else { return false }
        return outputState.result() == nil
    }

    private func terminateWithoutWaiting() {
        let shouldTerminate = markCancelled()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
        try? inputHandle?.close()
        outputReader?.cancel()
        try? outputHandle?.close()
    }

    private func markCancelled() -> Bool {
        lock.withLock {
            guard !didCancel else { return false }
            didCancel = true
            return true
        }
    }

    private func terminateAndWaitBounded() {
        let shouldTerminate = markCancelled()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
        var waited: UInt32 = 0
        while process.isRunning, waited < 500_000 {
            usleep(10_000)
            waited += 10_000
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        waited = 0
        while process.isRunning, waited < 200_000 {
            usleep(10_000)
            waited += 10_000
        }
    }

    private static func prepareDirectory(_ url: URL) throws {
        // Recreate the URL for each check. Foundation can cache resource values on a URL that was
        // constructed before its directory existed, which otherwise makes a second process for the
        // same newly-created profile look invalid.
        let directoryURL = canonicalClaudeConfigurationURL(
            URL(fileURLWithPath: url.path, isDirectory: true)
        )
        try validateExistingPathComponents(directoryURL)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            let values: URLResourceValues
            do {
                values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
            guard isDirectory.boolValue, values.isSymbolicLink == false else {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
        } else {
            try prepareMissingParentDirectory(
                canonicalClaudeConfigurationURL(directoryURL.deletingLastPathComponent())
            )
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw ClaudeCodeConnectorError.invalidConfigurationDirectory
        }
    }

    private static func prepareMissingParentDirectory(_ url: URL) throws {
        let directoryURL = canonicalClaudeConfigurationURL(
            URL(fileURLWithPath: url.path, isDirectory: true)
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            let values: URLResourceValues
            do {
                values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
            guard isDirectory.boolValue, values.isSymbolicLink == false else {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
            return
        }

        let parent = canonicalClaudeConfigurationURL(directoryURL.deletingLastPathComponent())
        guard parent.path != directoryURL.path else {
            throw ClaudeCodeConnectorError.invalidConfigurationDirectory
        }
        try prepareMissingParentDirectory(parent)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ClaudeCodeConnectorError.invalidConfigurationDirectory
        }
    }

    private static func validateExistingPathComponents(_ url: URL) throws {
        let directoryURL = canonicalClaudeConfigurationURL(url)
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directoryURL.pathComponents.dropFirst() {
            currentURL.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: currentURL.path,
                isDirectory: &isDirectory
            ) else {
                return
            }

            let values: URLResourceValues
            do {
                values = try currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
            guard isDirectory.boolValue, values.isSymbolicLink == false else {
                throw ClaudeCodeConnectorError.invalidConfigurationDirectory
            }
        }
    }
}

func canonicalClaudeConfigurationURL(_ url: URL) -> URL {
    let standardizedURL = url.standardizedFileURL
    let path = standardizedURL.path
    for systemAlias in ["/var", "/tmp", "/etc"] {
        if path == systemAlias || path.hasPrefix("\(systemAlias)/") {
            return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
        }
    }
    return standardizedURL
}

func claudeProfileCoordinationKey(_ url: URL) -> String {
    let canonicalURL = canonicalClaudeConfigurationURL(url)
    let path = canonicalURL.path.precomposedStringWithCanonicalMapping
    return normalizedClaudeProfileCoordinationPath(
        path,
        volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames(for: canonicalURL)
    )
}

func normalizedClaudeProfileCoordinationPath(
    _ path: String,
    volumeSupportsCaseSensitiveNames: Bool?
) -> String {
    volumeSupportsCaseSensitiveNames == false ? path.lowercased() : path
}

private func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool? {
    var candidate = canonicalClaudeConfigurationURL(url)
    var isDirectory: ObjCBool = false
    while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
        let parent = canonicalClaudeConfigurationURL(candidate.deletingLastPathComponent())
        guard parent.path != candidate.path else { return nil }
        candidate = parent
    }
    return try? candidate
        .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames
}

func sanitizedClaudeEnvironment(
    configurationDirectoryURL: URL,
    parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    let allowedNames: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TMPDIR",
        "USER"
    ]
    var environment = parentEnvironment.filter { allowedNames.contains($0.key.uppercased()) }
    environment["CLAUDE_CONFIG_DIR"] = configurationDirectoryURL.path
    environment["DISABLE_AUTOUPDATER"] = "1"
    return environment
}

private struct ClaudeCodeVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum ClaudeCodeExecutableLocator {
    private static let minimumSupportedVersion = ClaudeCodeVersion("2.1.258")!

    static func discover(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let candidates = candidateURLs(
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL,
            environment: environment
        )
        return try selectNewestCompatible(
            from: candidates,
            isExecutable: { fileManager.isExecutableFile(atPath: $0.path) },
            isTrusted: isAnthropicSigned
        )
    }

    static func candidateURLs(
        fileManager: FileManager,
        homeDirectoryURL: URL,
        environment: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []

        let desktopRoot = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: desktopRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.map {
                $0.appendingPathComponent("claude.app/Contents/MacOS/claude", isDirectory: false)
            })
        }

        let nativeRoot = homeDirectoryURL
            .appendingPathComponent(".local/share/claude/versions", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nativeRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions)
        }
        candidates.append(
            homeDirectoryURL.appendingPathComponent(".local/bin/claude", isDirectory: false)
        )

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let commonDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        for directory in pathDirectories + commonDirectories {
            candidates.append(
                URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("claude", isDirectory: false)
            )
        }
        return candidates
    }

    static func selectNewestCompatible(
        from candidates: [URL],
        isExecutable: (URL) -> Bool,
        isTrusted: (URL) -> Bool
    ) throws -> URL {
        var sawExecutable = false
        var sawTrusted = false
        var resolvedCandidates: [(url: URL, version: ClaudeCodeVersion)] = []
        var seenPaths = Set<String>()

        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seenPaths.insert(resolved.path).inserted else { continue }
            guard isExecutable(resolved) else { continue }
            sawExecutable = true
            guard isTrusted(resolved) else { continue }
            sawTrusted = true
            guard
                let version = version(in: resolved),
                version >= minimumSupportedVersion
            else {
                continue
            }
            resolvedCandidates.append((resolved, version))
        }

        guard !resolvedCandidates.isEmpty else {
            if sawExecutable, !sawTrusted {
                throw ClaudeCodeConnectorError.untrustedExecutable
            }
            if sawTrusted {
                throw ClaudeCodeConnectorError.unsupportedClaudeCodeVersion
            }
            throw ClaudeCodeConnectorError.executableNotFound
        }
        return resolvedCandidates.sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version > rhs.version }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }[0].url
    }

    static func isAnthropicSigned(_ url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else {
            return false
        }

        var requirement: SecRequirement?
        let requirementText = #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#
        guard
            SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess,
            let requirement
        else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func version(in url: URL) -> ClaudeCodeVersion? {
        let components = url.standardizedFileURL.pathComponents

        // Claude's native installer stores the signed executable itself under this versioned path.
        if components.count >= 5 {
            let suffix = Array(components.suffix(5))
            if
                suffix[0] == ".local",
                suffix[1] == "share",
                suffix[2] == "claude",
                suffix[3] == "versions"
            {
                return ClaudeCodeVersion(suffix[4])
            }
        }

        // Claude Desktop's managed copy uses a version directory immediately above its app bundle.
        if components.count >= 6 {
            let suffix = Array(components.suffix(6))
            if
                suffix[0] == "claude-code",
                suffix[2] == "claude.app",
                suffix[3] == "Contents",
                suffix[4] == "MacOS",
                suffix[5] == "claude"
            {
                return ClaudeCodeVersion(suffix[1])
            }
        }
        return nil
    }
}
