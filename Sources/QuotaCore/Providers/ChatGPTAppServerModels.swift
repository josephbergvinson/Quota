import Foundation

/// The account information returned by Codex's supported `account/read` app-server method.
public struct ChatGPTAccountReadDTO: Equatable, Sendable {
    public let account: ChatGPTAccountDTO?
    public let requiresOpenAIAuth: Bool

    public init(account: ChatGPTAccountDTO?, requiresOpenAIAuth: Bool) {
        self.account = account
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }
}

public enum ChatGPTAccountDTO: Equatable, Sendable {
    case chatGPT(email: String?, planType: String)
    case apiKey
    case amazonBedrock(usesCodexManagedCredentials: Bool)
}

/// Metadata returned by the app-server initialization handshake.
public struct ChatGPTAppServerInformationDTO: Equatable, Sendable {
    public let codexHomeURL: URL
    public let platformFamily: String
    public let platformOS: String
    public let userAgent: String

    public init(
        codexHomeURL: URL,
        platformFamily: String,
        platformOS: String,
        userAgent: String
    ) {
        self.codexHomeURL = codexHomeURL
        self.platformFamily = platformFamily
        self.platformOS = platformOS
        self.userAgent = userAgent
    }
}

/// A quota window from `account/rateLimits/read`.
public struct ChatGPTRateLimitWindowDTO: Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int64?
    public let resetsAt: Date?

    public init(usedPercent: Int, windowDurationMinutes: Int64?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    /// Derived only when the provider returns a conventional percentage range.
    public var remainingPercent: Int? {
        guard (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }
}

public struct ChatGPTCreditsSnapshotDTO: Equatable, Sendable {
    /// Provider-formatted balance. It is intentionally not interpreted as a currency value.
    public let balance: String?
    public let hasCredits: Bool
    public let unlimited: Bool

    public init(balance: String?, hasCredits: Bool, unlimited: Bool) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }
}

public struct ChatGPTSpendControlDTO: Equatable, Sendable {
    /// Provider-formatted values, retained losslessly because the protocol does not declare a unit.
    public let used: String
    public let limit: String
    public let remainingPercent: Int
    public let resetsAt: Date

    public init(used: String, limit: String, remainingPercent: Int, resetsAt: Date) {
        self.used = used
        self.limit = limit
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public struct ChatGPTRateLimitSnapshotDTO: Equatable, Sendable {
    public let limitID: String?
    public let limitName: String?
    public let planType: String?
    public let primary: ChatGPTRateLimitWindowDTO?
    public let secondary: ChatGPTRateLimitWindowDTO?
    public let credits: ChatGPTCreditsSnapshotDTO?
    public let individualLimit: ChatGPTSpendControlDTO?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?

    public init(
        limitID: String?,
        limitName: String?,
        planType: String?,
        primary: ChatGPTRateLimitWindowDTO?,
        secondary: ChatGPTRateLimitWindowDTO?,
        credits: ChatGPTCreditsSnapshotDTO?,
        individualLimit: ChatGPTSpendControlDTO?,
        rateLimitReachedType: String?,
        spendControlReached: Bool?
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.individualLimit = individualLimit
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
    }
}

public struct ChatGPTRateLimitResetCreditDTO: Equatable, Sendable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let detail: String?

    public init(
        id: String,
        resetType: String,
        status: String,
        grantedAt: Date,
        expiresAt: Date?,
        title: String?,
        detail: String?
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.detail = detail
    }
}

public struct ChatGPTRateLimitResetCreditsDTO: Equatable, Sendable {
    /// The authoritative count. The provider may cap `credits`, so the array can be shorter.
    public let availableCount: Int64
    /// `nil` means only the count is known; an empty array means details were fetched but none exist.
    public let credits: [ChatGPTRateLimitResetCreditDTO]?

    public init(availableCount: Int64, credits: [ChatGPTRateLimitResetCreditDTO]?) {
        self.availableCount = availableCount
        self.credits = credits
    }
}

public struct ChatGPTRateLimitsDTO: Equatable, Sendable {
    /// Backward-compatible single-bucket view supplied by Codex.
    public let rateLimits: ChatGPTRateLimitSnapshotDTO
    /// Multi-bucket view keyed by the provider's metered limit identifier, when supplied.
    public let rateLimitsByLimitID: [String: ChatGPTRateLimitSnapshotDTO]?
    public let resetCredits: ChatGPTRateLimitResetCreditsDTO?

    public init(
        rateLimits: ChatGPTRateLimitSnapshotDTO,
        rateLimitsByLimitID: [String: ChatGPTRateLimitSnapshotDTO]?,
        resetCredits: ChatGPTRateLimitResetCreditsDTO?
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitID = rateLimitsByLimitID
        self.resetCredits = resetCredits
    }
}

public struct ChatGPTTokenUsageSummaryDTO: Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSeconds: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct ChatGPTDailyTokenUsageDTO: Equatable, Sendable, Identifiable {
    public var id: Date { date }

    /// UTC midnight for the provider's ISO-8601 `startDate` bucket.
    public let date: Date
    public let tokens: Int64

    public init(date: Date, tokens: Int64) {
        self.date = date
        self.tokens = tokens
    }
}

public struct ChatGPTThreadUsageGroupDTO: Equatable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let speed: String?
    public let inputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let netNewInputTokens: Int64?
    public let outputTokens: Int64?
    public let totalTokens: Int64?
    public let estimatedUsageCreditsMicros: Int64

    public init(
        model: String?,
        reasoningEffort: String?,
        speed: String?,
        inputTokens: Int64?,
        cachedInputTokens: Int64?,
        netNewInputTokens: Int64?,
        outputTokens: Int64?,
        totalTokens: Int64?,
        estimatedUsageCreditsMicros: Int64
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.netNewInputTokens = netNewInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedUsageCreditsMicros = estimatedUsageCreditsMicros
    }
}

public struct ChatGPTThreadUsageDTO: Equatable, Sendable {
    public let threadID: String
    public let estimatedUsageCreditsMicros: Int64
    public let estimatedUsageUSDMicros: Int64?
    public let groups: [ChatGPTThreadUsageGroupDTO]

    public init(
        threadID: String,
        estimatedUsageCreditsMicros: Int64,
        estimatedUsageUSDMicros: Int64?,
        groups: [ChatGPTThreadUsageGroupDTO]
    ) {
        self.threadID = threadID
        self.estimatedUsageCreditsMicros = estimatedUsageCreditsMicros
        self.estimatedUsageUSDMicros = estimatedUsageUSDMicros
        self.groups = groups
    }
}

public struct ChatGPTTokenUsageDTO: Equatable, Sendable {
    public let summary: ChatGPTTokenUsageSummaryDTO
    /// `nil` means the provider did not return historical buckets.
    public let dailyUsage: [ChatGPTDailyTokenUsageDTO]?
    /// Present only when `account/usage/read` was called for a specific thread and billing data exists.
    public let threadUsage: ChatGPTThreadUsageDTO?

    public init(
        summary: ChatGPTTokenUsageSummaryDTO,
        dailyUsage: [ChatGPTDailyTokenUsageDTO]?,
        threadUsage: ChatGPTThreadUsageDTO?
    ) {
        self.summary = summary
        self.dailyUsage = dailyUsage
        self.threadUsage = threadUsage
    }
}

public struct ChatGPTTelemetryDTO: Equatable, Sendable {
    public let capturedAt: Date
    public let account: ChatGPTAccountReadDTO
    public let rateLimits: ChatGPTRateLimitsDTO
    public let tokenUsage: ChatGPTTokenUsageDTO

    public init(
        capturedAt: Date,
        account: ChatGPTAccountReadDTO,
        rateLimits: ChatGPTRateLimitsDTO,
        tokenUsage: ChatGPTTokenUsageDTO
    ) {
        self.capturedAt = capturedAt
        self.account = account
        self.rateLimits = rateLimits
        self.tokenUsage = tokenUsage
    }
}

public enum ChatGPTManagedLoginMode: Equatable, Sendable {
    case browser
    case deviceCode
}

public enum ChatGPTLoginFlowDTO: Equatable, Sendable {
    case browser(loginID: String, authorizationURL: URL)
    case deviceCode(loginID: String, verificationURL: URL, userCode: String)

    public var loginID: String {
        switch self {
        case let .browser(loginID, _), let .deviceCode(loginID, _, _):
            loginID
        }
    }
}

public struct ChatGPTLoginCompletionDTO: Equatable, Sendable {
    public let loginID: String?
    public let succeeded: Bool
    public let errorMessage: String?

    public init(loginID: String?, succeeded: Bool, errorMessage: String?) {
        self.loginID = loginID
        self.succeeded = succeeded
        self.errorMessage = errorMessage
    }
}

// MARK: - App-server wire models

struct ChatGPTRawInitializeResponse: Decodable, Sendable {
    let codexHome: String
    let platformFamily: String
    let platformOs: String
    let userAgent: String

    func validatedDTO() throws -> ChatGPTAppServerInformationDTO {
        guard codexHome.hasPrefix("/") else {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        let url = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        return ChatGPTAppServerInformationDTO(
            codexHomeURL: url,
            platformFamily: try platformFamily.nonBlankProviderValue(),
            platformOS: try platformOs.nonBlankProviderValue(),
            userAgent: try userAgent.nonBlankProviderValue()
        )
    }
}

struct ChatGPTRawAccountReadResponse: Decodable, Sendable {
    let account: ChatGPTRawAccount?
    let requiresOpenaiAuth: Bool

    func validatedDTO() throws -> ChatGPTAccountReadDTO {
        ChatGPTAccountReadDTO(
            account: try account?.validatedDTO(),
            requiresOpenAIAuth: requiresOpenaiAuth
        )
    }
}

struct ChatGPTRawAccount: Decodable, Sendable {
    let type: String
    let email: String?
    let planType: String?
    let usesCodexManagedCredentials: Bool?

    func validatedDTO() throws -> ChatGPTAccountDTO {
        switch type {
        case "chatgpt":
            guard let planType else { throw ChatGPTConnectorError.invalidProviderPayload }
            return .chatGPT(
                email: email?.nilIfBlankProviderValue,
                planType: try planType.nonBlankProviderValue()
            )
        case "apiKey":
            return .apiKey
        case "amazonBedrock":
            return .amazonBedrock(usesCodexManagedCredentials: usesCodexManagedCredentials ?? false)
        default:
            throw ChatGPTConnectorError.unsupportedAuthenticationMode("unknown")
        }
    }
}

struct ChatGPTRawRateLimitsResponse: Decodable, Sendable {
    let rateLimits: ChatGPTRawRateLimitSnapshot
    let rateLimitsByLimitId: [String: ChatGPTRawRateLimitSnapshot]?
    let rateLimitResetCredits: ChatGPTRawResetCredits?

    func validatedDTO() throws -> ChatGPTRateLimitsDTO {
        let bucketDTOs = try rateLimitsByLimitId?.reduce(
            into: [String: ChatGPTRateLimitSnapshotDTO]()
        ) { result, item in
            let key = try item.key.nonBlankProviderValue()
            guard result[key] == nil else {
                throw ChatGPTConnectorError.invalidProviderPayload
            }
            result[key] = try item.value.validatedDTO()
        }

        return ChatGPTRateLimitsDTO(
            rateLimits: try rateLimits.validatedDTO(),
            rateLimitsByLimitID: bucketDTOs,
            resetCredits: try rateLimitResetCredits?.validatedDTO()
        )
    }
}

struct ChatGPTRawRateLimitSnapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: ChatGPTRawRateLimitWindow?
    let secondary: ChatGPTRawRateLimitWindow?
    let credits: ChatGPTRawCreditsSnapshot?
    let individualLimit: ChatGPTRawSpendControl?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?

    func validatedDTO() throws -> ChatGPTRateLimitSnapshotDTO {
        ChatGPTRateLimitSnapshotDTO(
            limitID: limitId?.nilIfBlankProviderValue,
            limitName: limitName?.nilIfBlankProviderValue,
            planType: planType?.nilIfBlankProviderValue,
            primary: try primary?.validatedDTO(),
            secondary: try secondary?.validatedDTO(),
            credits: try credits?.validatedDTO(),
            individualLimit: try individualLimit?.validatedDTO(),
            rateLimitReachedType: rateLimitReachedType?.nilIfBlankProviderValue,
            spendControlReached: spendControlReached
        )
    }
}

struct ChatGPTRawRateLimitWindow: Decodable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    func validatedDTO() throws -> ChatGPTRateLimitWindowDTO {
        guard usedPercent >= 0 else {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        if let windowDurationMins, windowDurationMins <= 0 {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        return ChatGPTRateLimitWindowDTO(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: try resetsAt.map(validatedUnixDate)
        )
    }
}

struct ChatGPTRawCreditsSnapshot: Decodable, Sendable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool

    func validatedDTO() throws -> ChatGPTCreditsSnapshotDTO {
        ChatGPTCreditsSnapshotDTO(
            balance: balance?.nilIfBlankProviderValue,
            hasCredits: hasCredits,
            unlimited: unlimited
        )
    }
}

struct ChatGPTRawSpendControl: Decodable, Sendable {
    let used: String
    let limit: String
    let remainingPercent: Int
    let resetsAt: Int64

    func validatedDTO() throws -> ChatGPTSpendControlDTO {
        guard (0...100).contains(remainingPercent) else {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        return ChatGPTSpendControlDTO(
            used: try used.nonBlankProviderValue(),
            limit: try limit.nonBlankProviderValue(),
            remainingPercent: remainingPercent,
            resetsAt: try validatedUnixDate(resetsAt)
        )
    }
}

struct ChatGPTRawResetCredits: Decodable, Sendable {
    let availableCount: Int64
    let credits: [ChatGPTRawResetCredit]?

    func validatedDTO() throws -> ChatGPTRateLimitResetCreditsDTO {
        guard availableCount >= 0 else { throw ChatGPTConnectorError.invalidProviderPayload }
        return ChatGPTRateLimitResetCreditsDTO(
            availableCount: availableCount,
            credits: try credits?.map { try $0.validatedDTO() }
        )
    }
}

struct ChatGPTRawResetCredit: Decodable, Sendable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?

    func validatedDTO() throws -> ChatGPTRateLimitResetCreditDTO {
        ChatGPTRateLimitResetCreditDTO(
            id: try id.nonBlankProviderValue(),
            resetType: try resetType.nonBlankProviderValue(),
            status: try status.nonBlankProviderValue(),
            grantedAt: try validatedUnixDate(grantedAt),
            expiresAt: try expiresAt.map(validatedUnixDate),
            title: title?.nilIfBlankProviderValue,
            detail: description?.nilIfBlankProviderValue
        )
    }
}

struct ChatGPTRawTokenUsageResponse: Decodable, Sendable {
    let summary: ChatGPTRawTokenUsageSummary
    let dailyUsageBuckets: [ChatGPTRawDailyUsage]?
    let threadUsage: ChatGPTRawThreadUsage?

    func validatedDTO() throws -> ChatGPTTokenUsageDTO {
        ChatGPTTokenUsageDTO(
            summary: try summary.validatedDTO(),
            dailyUsage: try dailyUsageBuckets?.map { try $0.validatedDTO() },
            threadUsage: try threadUsage?.validatedDTO()
        )
    }
}

struct ChatGPTRawTokenUsageSummary: Decodable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?

    func validatedDTO() throws -> ChatGPTTokenUsageSummaryDTO {
        try validateNonnegative(
            lifetimeTokens,
            peakDailyTokens,
            longestRunningTurnSec,
            currentStreakDays,
            longestStreakDays
        )
        return ChatGPTTokenUsageSummaryDTO(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            longestRunningTurnSeconds: longestRunningTurnSec,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays
        )
    }
}

struct ChatGPTRawDailyUsage: Decodable, Sendable {
    let startDate: String
    let tokens: Int64

    func validatedDTO() throws -> ChatGPTDailyTokenUsageDTO {
        guard tokens >= 0 else { throw ChatGPTConnectorError.invalidProviderPayload }
        return ChatGPTDailyTokenUsageDTO(
            date: try parseUTCDate(startDate),
            tokens: tokens
        )
    }
}

struct ChatGPTRawThreadUsage: Decodable, Sendable {
    let threadId: String
    let estimatedUsageCreditsMicros: Int64
    let estimatedUsageUsdMicros: Int64?
    let groups: [ChatGPTRawThreadUsageGroup]

    func validatedDTO() throws -> ChatGPTThreadUsageDTO {
        try validateNonnegative(estimatedUsageCreditsMicros, estimatedUsageUsdMicros)
        return ChatGPTThreadUsageDTO(
            threadID: try threadId.nonBlankProviderValue(),
            estimatedUsageCreditsMicros: estimatedUsageCreditsMicros,
            estimatedUsageUSDMicros: estimatedUsageUsdMicros,
            groups: try groups.map { try $0.validatedDTO() }
        )
    }
}

struct ChatGPTRawThreadUsageGroup: Decodable, Sendable {
    let model: String?
    let reasoningEffort: String?
    let speed: String?
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let netNewInputTokens: Int64?
    let outputTokens: Int64?
    let totalTokens: Int64?
    let estimatedUsageCreditsMicros: Int64

    func validatedDTO() throws -> ChatGPTThreadUsageGroupDTO {
        try validateNonnegative(
            inputTokens,
            cachedInputTokens,
            netNewInputTokens,
            outputTokens,
            totalTokens,
            estimatedUsageCreditsMicros
        )
        return ChatGPTThreadUsageGroupDTO(
            model: model?.nilIfBlankProviderValue,
            reasoningEffort: reasoningEffort?.nilIfBlankProviderValue,
            speed: speed?.nilIfBlankProviderValue,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            netNewInputTokens: netNewInputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            estimatedUsageCreditsMicros: estimatedUsageCreditsMicros
        )
    }
}

struct ChatGPTRawLoginResponse: Decodable, Sendable {
    let type: String
    let loginId: String?
    let authUrl: String?
    let verificationUrl: String?
    let userCode: String?

    func validatedFlow(for mode: ChatGPTManagedLoginMode) throws -> ChatGPTLoginFlowDTO {
        guard let loginId else { throw ChatGPTConnectorError.invalidProviderPayload }
        let validatedLoginID = try loginId.nonBlankProviderValue()
        switch (mode, type) {
        case (.browser, "chatgpt"):
            guard let authUrl else { throw ChatGPTConnectorError.invalidProviderPayload }
            return .browser(
                loginID: validatedLoginID,
                authorizationURL: try validatedHTTPSURL(authUrl)
            )
        case (.deviceCode, "chatgptDeviceCode"):
            guard let verificationUrl, let userCode else {
                throw ChatGPTConnectorError.invalidProviderPayload
            }
            return .deviceCode(
                loginID: validatedLoginID,
                verificationURL: try validatedHTTPSURL(verificationUrl),
                userCode: try userCode.nonBlankSingleLineProviderValue()
            )
        default:
            throw ChatGPTConnectorError.invalidProviderPayload
        }
    }
}

struct ChatGPTRawLoginCompletion: Decodable, Sendable {
    let loginId: String?
    let success: Bool
    let error: String?

    func validatedDTO() throws -> ChatGPTLoginCompletionDTO {
        ChatGPTLoginCompletionDTO(
            loginID: loginId?.nilIfBlankProviderValue,
            succeeded: success,
            errorMessage: error == nil ? nil : "ChatGPT sign-in did not complete."
        )
    }
}

private func validatedUnixDate(_ seconds: Int64) throws -> Date {
    guard seconds > 0 else { throw ChatGPTConnectorError.invalidProviderPayload }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
}

private func parseUTCDate(_ value: String) throws -> Date {
    let components = value.split(separator: "-", omittingEmptySubsequences: false)
    guard
        components.count == 3,
        components[0].count == 4,
        components[1].count == 2,
        components[2].count == 2,
        let year = Int(components[0]),
        let month = Int(components[1]),
        let day = Int(components[2])
    else {
        throw ChatGPTConnectorError.invalidProviderPayload
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dateComponents = DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day
    )
    guard
        let date = calendar.date(from: dateComponents),
        calendar.dateComponents([.year, .month, .day], from: date) ==
            DateComponents(year: year, month: month, day: day)
    else {
        throw ChatGPTConnectorError.invalidProviderPayload
    }
    return date
}

private func validatedHTTPSURL(_ value: String) throws -> URL {
    guard
        let url = URL(string: value),
        url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false
    else {
        throw ChatGPTConnectorError.invalidProviderPayload
    }
    return url
}

private func validateNonnegative(_ values: Int64?...) throws {
    guard values.allSatisfy({ $0.map { $0 >= 0 } ?? true }) else {
        throw ChatGPTConnectorError.invalidProviderPayload
    }
}

private extension String {
    var nilIfBlankProviderValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func nonBlankProviderValue() throws -> String {
        guard let value = nilIfBlankProviderValue else {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        return value
    }

    func nonBlankSingleLineProviderValue() throws -> String {
        let value = try nonBlankProviderValue()
        guard !value.contains("\n"), !value.contains("\r") else {
            throw ChatGPTConnectorError.invalidProviderPayload
        }
        return value
    }
}
