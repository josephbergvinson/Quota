import Foundation

public enum UsageUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case messages
    case tokens
    case dollars
    case percent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .messages:
            "messages"
        case .tokens:
            "tokens"
        case .dollars:
            "USD"
        case .percent:
            "percent"
        }
    }
}

public struct Allowance: Codable, Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let unit: UsageUnit

    public init(used: Double, limit: Double, unit: UsageUnit) throws {
        guard used.isFinite, limit.isFinite else {
            throw DomainValidationError.nonFiniteUsage
        }
        guard used >= 0 else {
            throw DomainValidationError.negativeUsage
        }
        guard limit > 0 else {
            throw DomainValidationError.invalidLimit
        }

        self.used = used
        self.limit = limit
        self.unit = unit
    }

    public var remaining: Double {
        max(0, limit - used)
    }

    public var usedFraction: Double {
        min(1, used / limit)
    }

    public var remainingFraction: Double {
        max(0, 1 - usedFraction)
    }

    public func validated() throws -> Allowance {
        try Allowance(used: used, limit: limit, unit: unit)
    }
}

public struct ReportingPeriod: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) throws {
        guard end > start else {
            throw DomainValidationError.invalidReportingPeriod
        }
        self.start = start
        self.end = end
    }

    public func validated() throws -> ReportingPeriod {
        try ReportingPeriod(start: start, end: end)
    }
}

public struct ModelUsage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { model }

    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let requests: Int

    public init(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        requests: Int
    ) {
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.requests = max(0, requests)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens
    }
}

public struct DailyUsagePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { date }

    public let date: Date
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let unattributedTokens: Int
    public let requests: Int
    public let costUSD: Double

    public init(
        date: Date,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        unattributedTokens: Int = 0,
        requests: Int = 0,
        costUSD: Double = 0
    ) {
        self.date = date
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.unattributedTokens = max(0, unattributedTokens)
        self.requests = max(0, requests)
        self.costUSD = max(0, costUSD)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + unattributedTokens
    }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { identifier }

    public let identifier: String
    public let name: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let durationMinutes: Int?

    public init(
        identifier: String,
        name: String,
        usedPercent: Double,
        resetsAt: Date?,
        durationMinutes: Int?
    ) throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty, !normalizedName.isEmpty else {
            throw DomainValidationError.emptyQuotaWindowName
        }
        guard usedPercent.isFinite, usedPercent >= 0 else {
            throw DomainValidationError.invalidUsagePercentage
        }
        if let durationMinutes, durationMinutes <= 0 {
            throw DomainValidationError.invalidWindowDuration
        }

        self.identifier = normalizedIdentifier
        self.name = normalizedName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    public func validated() throws -> QuotaWindow {
        try QuotaWindow(
            identifier: identifier,
            name: name,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            durationMinutes: durationMinutes
        )
    }
}

public enum BankedResetCreditStatus: String, Codable, Equatable, Sendable {
    case available
    case redeeming
    case redeemed
    case unknown
}

public struct BankedResetCredit: Codable, Equatable, Sendable {
    public let status: BankedResetCreditStatus
    public let expiresAt: Date?

    public init(status: BankedResetCreditStatus, expiresAt: Date?) throws {
        if let expiresAt, !expiresAt.timeIntervalSinceReferenceDate.isFinite {
            throw DomainValidationError.invalidBankedResetCredits
        }
        self.status = status
        self.expiresAt = expiresAt
    }

    public func validated() throws -> BankedResetCredit {
        try BankedResetCredit(status: status, expiresAt: expiresAt)
    }
}

public struct BankedResetCredits: Codable, Equatable, Sendable {
    /// The provider's authoritative available count. Detail rows may be capped.
    public let availableCount: Int
    /// `nil` means the provider returned only the count.
    public let credits: [BankedResetCredit]?

    public init(availableCount: Int, credits: [BankedResetCredit]?) throws {
        guard availableCount >= 0 else {
            throw DomainValidationError.invalidBankedResetCredits
        }
        self.availableCount = availableCount
        self.credits = try credits?.map { try $0.validated() }
    }

    public func validated() throws -> BankedResetCredits {
        try BankedResetCredits(availableCount: availableCount, credits: credits)
    }
}

public enum UsageSource: String, Codable, Sendable {
    case manual
    case chatGPTAppServer
    case openAIAdminAPI
}

public struct UsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let capturedAt: Date
    public let source: UsageSource
    public let reportingPeriod: ReportingPeriod?
    public let allowance: Metric<Allowance>
    public let quotaWindows: Metric<[QuotaWindow]>
    public let resetAt: Metric<Date>
    public let bankedResetCredits: Metric<BankedResetCredits>
    public let totalTokens: Metric<Int>
    public let inputTokens: Metric<Int>
    public let cachedInputTokens: Metric<Int>
    public let outputTokens: Metric<Int>
    public let requests: Metric<Int>
    public let costUSD: Metric<Double>
    public let modelUsage: Metric<[ModelUsage]>
    public let dailyUsage: Metric<[DailyUsagePoint]>

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        capturedAt: Date,
        source: UsageSource,
        reportingPeriod: ReportingPeriod?,
        allowance: Metric<Allowance>,
        quotaWindows: Metric<[QuotaWindow]>,
        resetAt: Metric<Date>,
        bankedResetCredits: Metric<BankedResetCredits>? = nil,
        totalTokens: Metric<Int>,
        inputTokens: Metric<Int>,
        cachedInputTokens: Metric<Int>,
        outputTokens: Metric<Int>,
        requests: Metric<Int>,
        costUSD: Metric<Double>,
        modelUsage: Metric<[ModelUsage]>,
        dailyUsage: Metric<[DailyUsagePoint]>
    ) {
        self.id = id
        self.accountID = accountID
        self.capturedAt = capturedAt
        self.source = source
        self.reportingPeriod = reportingPeriod
        self.allowance = allowance
        self.quotaWindows = quotaWindows
        self.resetAt = resetAt
        self.bankedResetCredits = bankedResetCredits ?? Self.missingBankedResetCredits
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.costUSD = costUSD
        self.modelUsage = modelUsage
        self.dailyUsage = dailyUsage
    }

    public static func awaitingRefresh(accountID: UUID, source: UsageSource, at date: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            capturedAt: date,
            source: source,
            reportingPeriod: nil,
            allowance: .unavailable(.awaitingFirstRefresh),
            quotaWindows: .unavailable(.awaitingFirstRefresh),
            resetAt: .unavailable(.awaitingFirstRefresh),
            bankedResetCredits: .unavailable(.awaitingFirstRefresh),
            totalTokens: .unavailable(.awaitingFirstRefresh),
            inputTokens: .unavailable(.awaitingFirstRefresh),
            cachedInputTokens: .unavailable(.awaitingFirstRefresh),
            outputTokens: .unavailable(.awaitingFirstRefresh),
            requests: .unavailable(.awaitingFirstRefresh),
            costUSD: .unavailable(.awaitingFirstRefresh),
            modelUsage: .unavailable(.awaitingFirstRefresh),
            dailyUsage: .unavailable(.awaitingFirstRefresh)
        )
    }

    public static func manual(
        accountID: UUID,
        allowance: Allowance?,
        quotaWindows: [QuotaWindow] = [],
        resetAt: Date?,
        capturedAt: Date
    ) -> UsageSnapshot {
        let providerMetric = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "This consumer subscription does not expose this metric through a supported provider API."
        )

        return UsageSnapshot(
            accountID: accountID,
            capturedAt: capturedAt,
            source: .manual,
            reportingPeriod: nil,
            allowance: allowance.map(Metric.available) ?? .unavailable(.notEntered),
            quotaWindows: quotaWindows.isEmpty ? .unavailable(.notEntered) : .available(quotaWindows),
            resetAt: resetAt.map(Metric.available) ?? .unavailable(.notEntered),
            bankedResetCredits: .unavailable(providerMetric),
            totalTokens: .unavailable(providerMetric),
            inputTokens: .unavailable(providerMetric),
            cachedInputTokens: .unavailable(providerMetric),
            outputTokens: .unavailable(providerMetric),
            requests: .unavailable(providerMetric),
            costUSD: .unavailable(providerMetric),
            modelUsage: .unavailable(providerMetric),
            dailyUsage: .unavailable(providerMetric)
        )
    }

    private static let missingBankedResetCredits = Metric<BankedResetCredits>.unavailable(
        UnavailableMetric(
            reason: .notReturned,
            detail: "Banked reset data was not captured for this reading. Refresh the account to check again."
        )
    )

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case capturedAt
        case source
        case reportingPeriod
        case allowance
        case quotaWindows
        case resetAt
        case bankedResetCredits
        case totalTokens
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case requests
        case costUSD
        case modelUsage
        case dailyUsage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            accountID: try container.decode(UUID.self, forKey: .accountID),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            source: try container.decode(UsageSource.self, forKey: .source),
            reportingPeriod: try container.decodeIfPresent(ReportingPeriod.self, forKey: .reportingPeriod),
            allowance: try container.decode(Metric<Allowance>.self, forKey: .allowance),
            quotaWindows: try container.decode(Metric<[QuotaWindow]>.self, forKey: .quotaWindows),
            resetAt: try container.decode(Metric<Date>.self, forKey: .resetAt),
            bankedResetCredits: try container.decodeIfPresent(
                Metric<BankedResetCredits>.self,
                forKey: .bankedResetCredits
            ),
            totalTokens: try container.decode(Metric<Int>.self, forKey: .totalTokens),
            inputTokens: try container.decode(Metric<Int>.self, forKey: .inputTokens),
            cachedInputTokens: try container.decode(Metric<Int>.self, forKey: .cachedInputTokens),
            outputTokens: try container.decode(Metric<Int>.self, forKey: .outputTokens),
            requests: try container.decode(Metric<Int>.self, forKey: .requests),
            costUSD: try container.decode(Metric<Double>.self, forKey: .costUSD),
            modelUsage: try container.decode(Metric<[ModelUsage]>.self, forKey: .modelUsage),
            dailyUsage: try container.decode(Metric<[DailyUsagePoint]>.self, forKey: .dailyUsage)
        )
    }
}
