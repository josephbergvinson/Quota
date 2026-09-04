import Darwin
import Foundation

public enum ChatGPTConnectorError: LocalizedError, Equatable, Sendable {
    case codexExecutableNotFound
    case invalidCodexExecutable
    case invalidCodexHome
    case invalidTimeout
    case processLaunchFailed
    case processExited(status: Int32)
    case connectionClosed
    case requestTimedOut(method: String)
    case malformedProtocolMessage
    case protocolBufferOverflow
    case rpcFailure(code: Int)
    case invalidProviderPayload
    case unsupportedAuthenticationMode(String)
    case unsupportedSubscriptionPlan
    case notAuthenticated
    case authenticationOperationInProgress
    case loginFinished
    case profileRetired

    public var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            "Quota could not find the Codex command. Install or update the ChatGPT app or Codex CLI."
        case .invalidCodexExecutable:
            "The selected Codex command is not an executable file."
        case .invalidCodexHome:
            "The selected account storage folder is invalid."
        case .invalidTimeout:
            "The Codex connector timeout is invalid."
        case .processLaunchFailed:
            "Quota could not start the local Codex service."
        case let .processExited(status):
            "The local Codex service stopped unexpectedly (status \(status))."
        case .connectionClosed:
            "The local Codex service closed the connection."
        case .requestTimedOut:
            "Quota could not refresh this account because the local Codex service did not respond in time. Try again."
        case .malformedProtocolMessage:
            "The local Codex service returned a message Quota could not read."
        case .protocolBufferOverflow:
            "The local Codex service produced more data than Quota can safely buffer."
        case .rpcFailure(code: -32_603):
            "The local Codex service encountered a temporary internal error. Please try again."
        case let .rpcFailure(code):
            "The local Codex service rejected the request (\(code))."
        case .invalidProviderPayload:
            "The local Codex service returned invalid account data."
        case let .unsupportedAuthenticationMode(mode):
            "This Codex authentication mode is not supported by Quota (\(mode))."
        case .unsupportedSubscriptionPlan:
            "Quota currently supports ChatGPT Plus and Pro subscriptions, not Business, Team, or Enterprise plans."
        case .notAuthenticated:
            "This account is not signed in to ChatGPT."
        case .authenticationOperationInProgress:
            "Another ChatGPT sign-in or credential refresh is already in progress for this account."
        case .loginFinished:
            "This ChatGPT sign-in attempt has already finished."
        case .profileRetired:
            "This ChatGPT account is being removed."
        }
    }
}

public struct ChatGPTAppServerConfiguration: Equatable, Sendable {
    public let codexExecutableURL: URL
    public let codexHomeURL: URL
    public let requestTimeoutSeconds: TimeInterval
    public let loginTimeoutSeconds: TimeInterval

    public init(
        codexHomeURL: URL,
        codexExecutableURL: URL? = nil,
        requestTimeoutSeconds: TimeInterval = 30,
        loginTimeoutSeconds: TimeInterval = 600
    ) throws {
        let fileManager = FileManager.default
        guard
            codexHomeURL.isFileURL,
            codexHomeURL.path.hasPrefix("/"),
            codexHomeURL.standardizedFileURL.path != "/"
        else {
            throw ChatGPTConnectorError.invalidCodexHome
        }
        guard
            requestTimeoutSeconds.isFinite,
            requestTimeoutSeconds > 0,
            requestTimeoutSeconds <= 300,
            loginTimeoutSeconds.isFinite,
            loginTimeoutSeconds > 0,
            loginTimeoutSeconds <= 3_600
        else {
            throw ChatGPTConnectorError.invalidTimeout
        }

        guard let executable = codexExecutableURL ?? Self.discoverCodexExecutable() else {
            throw ChatGPTConnectorError.codexExecutableNotFound
        }
        guard
            executable.isFileURL,
            executable.path.hasPrefix("/"),
            fileManager.isExecutableFile(atPath: executable.path)
        else {
            throw ChatGPTConnectorError.invalidCodexExecutable
        }

        self.codexExecutableURL = executable.standardizedFileURL
        self.codexHomeURL = codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }

    /// Finds Codex without running shell startup files. Finder-launched apps commonly receive a
    /// minimal `PATH`, so the documented standalone install and common package-manager locations
    /// are checked after the app bundle, installed apps, and inherited `PATH`.
    public static func discoverCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        return discoverCodexExecutable(
            bundledCandidate: Bundle.main.url(forAuxiliaryExecutable: "codex"),
            applicationCandidates: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
            ],
            path: ProcessInfo.processInfo.environment["PATH"],
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            systemSearchDirectories: [
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                URL(fileURLWithPath: "/opt/local/bin", isDirectory: true)
            ],
            fileManager: fileManager
        )
    }

    static func discoverCodexExecutable(
        bundledCandidate: URL?,
        applicationCandidates: [URL],
        path: String?,
        homeDirectoryURL: URL,
        systemSearchDirectories: [URL],
        fileManager: FileManager
    ) -> URL? {
        var candidates = [URL]()
        if let bundledCandidate {
            candidates.append(bundledCandidate)
        }
        candidates.append(contentsOf: applicationCandidates)

        if let path {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                let directory = String(component)
                guard directory.hasPrefix("/") else { continue }
                candidates.append(
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("codex", isDirectory: false)
                )
            }
        }

        candidates.append(contentsOf: systemSearchDirectories.map {
            $0.appendingPathComponent("codex", isDirectory: false)
        })

        if homeDirectoryURL.isFileURL, homeDirectoryURL.path.hasPrefix("/") {
            let userSearchComponents = [
                [".local", "bin"],
                [".npm-global", "bin"],
                [".volta", "bin"],
                [".bun", "bin"],
                [".asdf", "shims"],
                [".local", "share", "mise", "shims"],
                ["Library", "pnpm"],
                [".nix-profile", "bin"]
            ]
            candidates.append(contentsOf: userSearchComponents.map { components in
                components.reduce(homeDirectoryURL) { partialURL, component in
                    partialURL.appendingPathComponent(component, isDirectory: true)
                }.appendingPathComponent("codex", isDirectory: false)
            })
            candidates.append(
                contentsOf: nvmCodexCandidates(
                    homeDirectoryURL: homeDirectoryURL,
                    fileManager: fileManager
                )
            )
        }

        var visitedPaths = Set<String>()
        for candidate in candidates {
            let standardizedCandidate = candidate.standardizedFileURL
            guard
                standardizedCandidate.isFileURL,
                standardizedCandidate.path.hasPrefix("/"),
                visitedPaths.insert(standardizedCandidate.path).inserted,
                fileManager.isExecutableFile(atPath: standardizedCandidate.path)
            else {
                continue
            }
            return standardizedCandidate
        }
        return nil
    }

    private static func nvmCodexCandidates(
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let versionsDirectory = homeDirectoryURL
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versionDirectories = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versionDirectories
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedDescending
            }
            .prefix(32)
            .map {
                $0.appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            }
    }
}

private enum ChatGPTLineStreamError: Error, Sendable {
    case lineTooLarge
    case bufferOverflow
    case truncatedLine
    case cancelled
}

/// Converts a pipe into bounded JSONL messages without ever retaining stderr output.
private final class ChatGPTLineStream: @unchecked Sendable {
    private static let maximumLineBytes = 4 * 1_024 * 1_024
    private static let maximumBufferedMessages = 128

    private let handle: FileHandle
    private let lock = NSLock()
    private var pendingBytes = Data()
    private var queuedLines: [Data] = []
    private var waiter: (
        id: UInt64,
        continuation: CheckedContinuation<Result<Data?, ChatGPTLineStreamError>, Never>
    )?
    private var activeReadIDs: Set<UInt64> = []
    private var nextReadID: UInt64 = 0
    private var terminalResult: Result<Data?, ChatGPTLineStreamError>?
    private var stopped = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readableHandle in
            let chunk = readableHandle.availableData
            self?.receive(chunk)
        }
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        let readID = beginRead()
        let result: Result<Data?, ChatGPTLineStreamError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard activeReadIDs.contains(readID) else {
                    lock.unlock()
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                if !queuedLines.isEmpty {
                    let line = queuedLines.removeFirst()
                    activeReadIDs.remove(readID)
                    lock.unlock()
                    continuation.resume(returning: .success(line))
                    return
                }
                if let terminalResult {
                    activeReadIDs.remove(readID)
                    lock.unlock()
                    continuation.resume(returning: terminalResult)
                    return
                }
                guard waiter == nil else {
                    activeReadIDs.remove(readID)
                    lock.unlock()
                    continuation.resume(returning: .failure(.bufferOverflow))
                    return
                }
                waiter = (readID, continuation)
                lock.unlock()
            }
        } onCancel: {
            self.cancelPendingRead(readID)
        }
        return try result.get()
    }

    private func beginRead() -> UInt64 {
        lock.lock()
        nextReadID &+= 1
        let readID = nextReadID
        activeReadIDs.insert(readID)
        lock.unlock()
        return readID
    }

    private func cancelPendingRead(_ readID: UInt64) {
        let waiting: CheckedContinuation<Result<Data?, ChatGPTLineStreamError>, Never>?
        lock.lock()
        guard activeReadIDs.remove(readID) != nil else {
            lock.unlock()
            return
        }
        if waiter?.id == readID {
            waiting = waiter?.continuation
            waiter = nil
        } else {
            waiting = nil
        }
        lock.unlock()
        waiting?.resume(returning: .failure(.cancelled))
    }

    func stop() {
        let waiting: CheckedContinuation<Result<Data?, ChatGPTLineStreamError>, Never>?
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        handle.readabilityHandler = nil
        pendingBytes.removeAll(keepingCapacity: false)
        queuedLines.removeAll(keepingCapacity: false)
        terminalResult = .success(nil)
        if let waiter {
            activeReadIDs.remove(waiter.id)
            waiting = waiter.continuation
        } else {
            waiting = nil
        }
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: .success(nil))
    }

    private func receive(_ chunk: Data) {
        var lines: [Data] = []
        var terminalError: ChatGPTLineStreamError?
        var waiting: CheckedContinuation<Result<Data?, ChatGPTLineStreamError>, Never>?
        var waitingResult: Result<Data?, ChatGPTLineStreamError>?

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }

        if chunk.isEmpty {
            stopped = true
            handle.readabilityHandler = nil
            if !pendingBytes.isEmpty {
                pendingBytes.removeAll(keepingCapacity: false)
                terminalError = .truncatedLine
            }
        } else {
            pendingBytes.append(chunk)
            while let newlineIndex = pendingBytes.firstIndex(of: 0x0A) {
                var line = Data(pendingBytes[..<newlineIndex])
                pendingBytes.removeSubrange(...newlineIndex)
                if line.last == 0x0D {
                    line.removeLast()
                }
                if line.count > Self.maximumLineBytes {
                    terminalError = .lineTooLarge
                    lines.removeAll(keepingCapacity: false)
                    break
                }
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            if pendingBytes.count > Self.maximumLineBytes {
                stopped = true
                handle.readabilityHandler = nil
                pendingBytes.removeAll(keepingCapacity: false)
                terminalError = ChatGPTLineStreamError.lineTooLarge
            }
        }

        if terminalError != nil {
            stopped = true
            handle.readabilityHandler = nil
            pendingBytes.removeAll(keepingCapacity: false)
        }

        if let first = lines.first, let currentWaiter = waiter {
            activeReadIDs.remove(currentWaiter.id)
            waiting = currentWaiter.continuation
            waiter = nil
            waitingResult = .success(first)
            lines.removeFirst()
        }
        if queuedLines.count + lines.count > Self.maximumBufferedMessages {
            queuedLines.removeAll(keepingCapacity: false)
            terminalError = .bufferOverflow
        } else {
            queuedLines.append(contentsOf: lines)
        }

        if let terminalError {
            terminalResult = .failure(terminalError)
            if waiting == nil, let currentWaiter = waiter {
                activeReadIDs.remove(currentWaiter.id)
                waiting = currentWaiter.continuation
                waiter = nil
                waitingResult = .failure(terminalError)
            }
        } else if chunk.isEmpty {
            terminalResult = .success(nil)
            if waiting == nil, let currentWaiter = waiter, queuedLines.isEmpty {
                activeReadIDs.remove(currentWaiter.id)
                waiting = currentWaiter.continuation
                waiter = nil
                waitingResult = .success(nil)
            }
        }
        lock.unlock()

        if let waiting, let waitingResult {
            waiting.resume(returning: waitingResult)
        }
    }
}

/// Owns the subprocess and provides idempotent, escalating termination on every exit path.
private final class ChatGPTProcessLease: @unchecked Sendable {
    private let process: Process
    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    deinit {
        closeWithoutWaiting()
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, process.isRunning else {
            throw ChatGPTConnectorError.connectionClosed
        }
        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw ChatGPTConnectorError.connectionClosed
        }
    }

    func close() async {
        guard beginClose() else { return }
        try? standardInput.close()

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                terminateAndWaitBounded()
                continuation.resume()
            }
        }
        closeOutputHandles()
    }

    fileprivate func closeWithoutWaiting() {
        guard beginClose() else { return }
        try? standardInput.close()
        if process.isRunning {
            process.terminate()
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        closeOutputHandles()
    }

    private func beginClose() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        closed = true
        lock.unlock()
        return true
    }

    private func terminateAndWaitBounded() {
        wait(upToMicroseconds: 200_000)
        if process.isRunning {
            process.terminate()
            wait(upToMicroseconds: 500_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            wait(upToMicroseconds: 200_000)
        }
    }

    private func closeOutputHandles() {
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        try? standardOutput.close()
        try? standardError.close()
    }

    func exitedStatus() -> Int32? {
        guard !process.isRunning else { return nil }
        return process.terminationStatus
    }

    private func wait(upToMicroseconds maximumWait: UInt32) {
        let interval: UInt32 = 10_000
        var waited: UInt32 = 0
        while process.isRunning, waited < maximumWait {
            usleep(interval)
            waited += interval
        }
    }
}

private struct ChatGPTRPCErrorPayload: Sendable {
    let code: Int
}

private struct ChatGPTNotification: Sendable {
    let method: String
    let params: Data
}

private enum ChatGPTWireMessage: Sendable {
    case response(id: Int, result: Data?, error: ChatGPTRPCErrorPayload?)
    case notification(ChatGPTNotification)
    case serverRequest
}

actor ChatGPTAppServerRPCSession {
    private let lease: ChatGPTProcessLease
    private let lineStream: ChatGPTLineStream
    private let requestTimeoutSeconds: TimeInterval
    private var requestID = 0
    private var pendingNotifications: [ChatGPTNotification] = []
    private var isClosed = false

    static func launch(configuration: ChatGPTAppServerConfiguration) throws -> ChatGPTAppServerRPCSession {
        try prepareCodexHome(configuration.codexHomeURL)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let lineStream = ChatGPTLineStream(handle: outputPipe.fileHandleForReading)

        process.executableURL = configuration.codexExecutableURL
        process.arguments = [
            "app-server",
            "--stdio",
            "--strict-config",
            "-c",
            "cli_auth_credentials_store=\"keyring\"",
            "--disable",
            "plugins",
            "--disable",
            "apps"
        ]
        process.environment = sanitizedEnvironment(codexHomeURL: configuration.codexHomeURL)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain and discard stderr. It is deliberately never retained, logged, or surfaced because
        // it belongs to a credential-bearing process and is not a safe user-facing error channel.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            lineStream.stop()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ChatGPTConnectorError.processLaunchFailed
        }

        let lease = ChatGPTProcessLease(
            process: process,
            standardInput: inputPipe.fileHandleForWriting,
            standardOutput: outputPipe.fileHandleForReading,
            standardError: errorPipe.fileHandleForReading
        )
        return ChatGPTAppServerRPCSession(
            lease: lease,
            lineStream: lineStream,
            requestTimeoutSeconds: configuration.requestTimeoutSeconds
        )
    }

    private init(
        lease: ChatGPTProcessLease,
        lineStream: ChatGPTLineStream,
        requestTimeoutSeconds: TimeInterval
    ) {
        self.lease = lease
        self.lineStream = lineStream
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    deinit {
        lineStream.stop()
        lease.closeWithoutWaiting()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        lineStream.stop()
        await lease.close()
    }

    func request<Result: Decodable & Sendable>(
        method: String,
        resultType: Result.Type = Result.self
    ) async throws -> Result {
        try await request(method: method, paramsData: nil, resultType: resultType)
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        resultType: Result.Type = Result.self
    ) async throws -> Result {
        let paramsData: Data
        do {
            paramsData = try JSONEncoder().encode(params)
        } catch {
            throw ChatGPTConnectorError.malformedProtocolMessage
        }
        return try await request(method: method, paramsData: paramsData, resultType: resultType)
    }

    func notify<Params: Encodable & Sendable>(method: String, params: Params) throws {
        guard !isClosed else { throw ChatGPTConnectorError.connectionClosed }
        let encodedParams: Data
        do {
            encodedParams = try JSONEncoder().encode(params)
        } catch {
            throw ChatGPTConnectorError.malformedProtocolMessage
        }
        let message = try encodeOutgoingMessage(id: nil, method: method, params: encodedParams)
        try lease.write(message)
    }

    func nextNotification<Result: Decodable & Sendable>(
        method: String,
        timeoutSeconds: TimeInterval,
        resultType: Result.Type = Result.self
    ) async throws -> Result {
        let deadline = monotonicDeadline(after: timeoutSeconds)
        while true {
            if let index = pendingNotifications.firstIndex(where: { $0.method == method }) {
                let notification = pendingNotifications.remove(at: index)
                return try decode(Result.self, from: notification.params)
            }

            let incoming = try await nextWireMessage(
                deadline: deadline,
                operationName: method
            )
            switch incoming {
            case let .notification(notification):
                if notification.method == method {
                    return try decode(Result.self, from: notification.params)
                }
                try buffer(notification)
            case .response, .serverRequest:
                throw ChatGPTConnectorError.malformedProtocolMessage
            }
        }
    }

    private func request<Result: Decodable & Sendable>(
        method: String,
        paramsData: Data?,
        resultType: Result.Type
    ) async throws -> Result {
        guard !isClosed else { throw ChatGPTConnectorError.connectionClosed }
        requestID += 1
        let currentID = requestID
        let message = try encodeOutgoingMessage(id: currentID, method: method, params: paramsData)
        let deadline = monotonicDeadline(after: requestTimeoutSeconds)
        try lease.write(message)

        while true {
            let incoming = try await nextWireMessage(
                deadline: deadline,
                operationName: method
            )
            switch incoming {
            case let .response(id, result, error):
                guard id == currentID else {
                    throw ChatGPTConnectorError.malformedProtocolMessage
                }
                if let error {
                    throw ChatGPTConnectorError.rpcFailure(code: error.code)
                }
                guard let result else {
                    throw ChatGPTConnectorError.malformedProtocolMessage
                }
                return try decode(Result.self, from: result)
            case let .notification(notification):
                try buffer(notification)
            case .serverRequest:
                // This client does not advertise capabilities that allow server-initiated requests.
                throw ChatGPTConnectorError.malformedProtocolMessage
            }
        }
    }

    private func buffer(_ notification: ChatGPTNotification) throws {
        guard pendingNotifications.count < 128 else {
            throw ChatGPTConnectorError.protocolBufferOverflow
        }
        pendingNotifications.append(notification)
    }

    private func nextWireMessage(
        deadline: UInt64,
        operationName: String
    ) async throws -> ChatGPTWireMessage {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            throw ChatGPTConnectorError.requestTimedOut(method: operationName)
        }
        let nanoseconds = deadline - now
        return try await withThrowingTaskGroup(of: ChatGPTWireMessage.self) { group in
            defer { group.cancelAll() }
            group.addTask { [self] in
                try await nextWireMessageWithoutTimeout()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ChatGPTConnectorError.requestTimedOut(method: operationName)
            }

            guard let first = try await group.next() else {
                throw ChatGPTConnectorError.connectionClosed
            }
            group.cancelAll()
            return first
        }
    }

    private func nextWireMessageWithoutTimeout() async throws -> ChatGPTWireMessage {
        do {
            guard let line = try await lineStream.next() else {
                if let status = lease.exitedStatus(), status != 0 {
                    throw ChatGPTConnectorError.processExited(status: status)
                }
                throw ChatGPTConnectorError.connectionClosed
            }
            return try Self.parseIncomingMessage(line)
        } catch ChatGPTLineStreamError.bufferOverflow, ChatGPTLineStreamError.lineTooLarge {
            throw ChatGPTConnectorError.protocolBufferOverflow
        } catch ChatGPTLineStreamError.truncatedLine {
            throw ChatGPTConnectorError.malformedProtocolMessage
        } catch ChatGPTLineStreamError.cancelled {
            throw CancellationError()
        } catch let error as ChatGPTConnectorError {
            throw error
        } catch {
            throw ChatGPTConnectorError.connectionClosed
        }
    }

    private static func parseIncomingMessage(_ data: Data) throws -> ChatGPTWireMessage {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw ChatGPTConnectorError.malformedProtocolMessage
        }

        if let id = dictionary["id"] as? Int {
            if dictionary["method"] != nil {
                return .serverRequest
            }

            let errorPayload: ChatGPTRPCErrorPayload?
            if let error = dictionary["error"] as? [String: Any] {
                guard let code = error["code"] as? Int, error["message"] is String else {
                    throw ChatGPTConnectorError.malformedProtocolMessage
                }
                errorPayload = ChatGPTRPCErrorPayload(code: code)
            } else {
                errorPayload = nil
            }

            let resultData = try dictionary["result"].map(encodeJSONObject)
            guard resultData != nil || errorPayload != nil else {
                throw ChatGPTConnectorError.malformedProtocolMessage
            }
            return .response(id: id, result: resultData, error: errorPayload)
        }

        guard let method = dictionary["method"] as? String, !method.isEmpty else {
            throw ChatGPTConnectorError.malformedProtocolMessage
        }
        let params = try dictionary["params"].map(encodeJSONObject) ?? Data("{}".utf8)
        return .notification(ChatGPTNotification(method: method, params: params))
    }

    private func decode<Result: Decodable>(_ type: Result.Type, from data: Data) throws -> Result {
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
    }
}

private struct ChatGPTEmptyParams: Codable, Sendable {}

struct ChatGPTInitializeParams: Encodable, Sendable {
    let clientInfo: ClientInfo

    struct ClientInfo: Encodable, Sendable {
        let name: String
        let title: String
        let version: String
    }
}

struct ChatGPTAccountReadParams: Encodable, Sendable {
    let refreshToken: Bool
}

struct ChatGPTUsageReadParams: Encodable, Sendable {
    let threadId: String?
}

struct ChatGPTBrowserLoginParams: Encodable, Sendable {
    let type = "chatgpt"
    let useHostedLoginSuccessPage = true
    let appBrand = "chatgpt"
}

struct ChatGPTDeviceCodeLoginParams: Encodable, Sendable {
    let type = "chatgptDeviceCode"
}

struct ChatGPTCancelLoginParams: Encodable, Sendable {
    let loginId: String
}

struct ChatGPTEmptyResponse: Decodable, Sendable {}

extension ChatGPTAppServerRPCSession {
    func initialize(expectedCodexHomeURL: URL) async throws -> ChatGPTAppServerInformationDTO {
        let raw: ChatGPTRawInitializeResponse = try await request(
            method: "initialize",
            params: ChatGPTInitializeParams(
                clientInfo: .init(name: "quota", title: "Quota", version: "0.1.0")
            )
        )
        let information = try raw.validatedDTO()
        guard information.codexHomeURL.standardizedFileURL == expectedCodexHomeURL.standardizedFileURL else {
            throw ChatGPTConnectorError.invalidCodexHome
        }
        try notify(method: "initialized", params: ChatGPTEmptyParams())
        return information
    }
}

private func prepareCodexHome(_ url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else { throw ChatGPTConnectorError.invalidCodexHome }
        return
    }

    do {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        throw ChatGPTConnectorError.invalidCodexHome
    }
}

private func sanitizedEnvironment(codexHomeURL: URL) -> [String: String] {
    let parentEnvironment = ProcessInfo.processInfo.environment
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
    environment["CODEX_HOME"] = codexHomeURL.path
    return environment
}

private func encodeOutgoingMessage(id: Int?, method: String, params: Data?) throws -> Data {
    guard !method.isEmpty else { throw ChatGPTConnectorError.malformedProtocolMessage }
    var object: [String: Any] = ["method": method]
    if let id {
        object["id"] = id
    }
    if let params {
        guard let paramsObject = try? JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed]) else {
            throw ChatGPTConnectorError.malformedProtocolMessage
        }
        object["params"] = paramsObject
    }
    var data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: object)
    } catch {
        throw ChatGPTConnectorError.malformedProtocolMessage
    }
    data.append(0x0A)
    return data
}

private func encodeJSONObject(_ object: Any) throws -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    } catch {
        throw ChatGPTConnectorError.malformedProtocolMessage
    }
}

private func monotonicDeadline(after seconds: TimeInterval) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let duration = UInt64(seconds * 1_000_000_000)
    let (deadline, overflow) = now.addingReportingOverflow(duration)
    return overflow ? UInt64.max : deadline
}
