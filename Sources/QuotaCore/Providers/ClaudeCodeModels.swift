import Foundation

/// The non-secret account metadata returned by `claude auth status --json`.
public struct ClaudeCodeAuthStatusDTO: Codable, Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    public let analyticsDisabled: Bool?
    public let projectsDirectory: String?
    public let email: String?
    public let organizationID: String?
    public let organizationName: String?
    public let subscriptionType: String?

    public init(
        loggedIn: Bool,
        authMethod: String? = nil,
        apiProvider: String? = nil,
        analyticsDisabled: Bool? = nil,
        projectsDirectory: String? = nil,
        email: String? = nil,
        organizationID: String? = nil,
        organizationName: String? = nil,
        subscriptionType: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.analyticsDisabled = analyticsDisabled
        self.projectsDirectory = projectsDirectory
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
    }

    private enum CodingKeys: String, CodingKey {
        case loggedIn
        case authMethod
        case apiProvider
        case analyticsDisabled
        case projectsDirectory
        case email
        case organizationID = "orgId"
        case organizationName = "orgName"
        case subscriptionType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
        authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
        apiProvider = try container.decodeIfPresent(String.self, forKey: .apiProvider)
        analyticsDisabled = try container.decodeIfPresent(Bool.self, forKey: .analyticsDisabled)
        projectsDirectory = try container.decodeIfPresent(String.self, forKey: .projectsDirectory)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
        organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
    }
}

struct ClaudeCodeRateLimitWindowDTO: Decodable, Equatable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeCodeModelScopedWindowDTO: Decodable, Equatable, Sendable {
    let displayName: String
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeCodeExtraUsageDTO: Decodable, Equatable, Sendable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    let minorUnitExponent: Int?

    init(
        isEnabled: Bool,
        monthlyLimit: Double?,
        usedCredits: Double?,
        utilization: Double?,
        currency: String?,
        minorUnitExponent: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
        self.minorUnitExponent = minorUnitExponent
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
        case minorUnitExponent = "decimal_places"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        monthlyLimit = try container.decodeIfPresent(Double.self, forKey: .monthlyLimit)
        usedCredits = try container.decodeIfPresent(Double.self, forKey: .usedCredits)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        minorUnitExponent = try container.decodeIfPresent(
            Int.self,
            forKey: .minorUnitExponent
        )
    }
}

struct ClaudeCodeRateLimitsDTO: Decodable, Equatable, Sendable {
    let fiveHour: ClaudeCodeRateLimitWindowDTO?
    let sevenDay: ClaudeCodeRateLimitWindowDTO?
    let sevenDayOAuthApps: ClaudeCodeRateLimitWindowDTO?
    let sevenDayOpus: ClaudeCodeRateLimitWindowDTO?
    let sevenDaySonnet: ClaudeCodeRateLimitWindowDTO?
    let modelScoped: [ClaudeCodeModelScopedWindowDTO]
    let extraUsage: ClaudeCodeExtraUsageDTO?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case modelScoped = "model_scoped"
        case extraUsage = "extra_usage"
    }

    init(
        fiveHour: ClaudeCodeRateLimitWindowDTO?,
        sevenDay: ClaudeCodeRateLimitWindowDTO?,
        sevenDayOAuthApps: ClaudeCodeRateLimitWindowDTO? = nil,
        sevenDayOpus: ClaudeCodeRateLimitWindowDTO? = nil,
        sevenDaySonnet: ClaudeCodeRateLimitWindowDTO? = nil,
        modelScoped: [ClaudeCodeModelScopedWindowDTO] = [],
        extraUsage: ClaudeCodeExtraUsageDTO? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOAuthApps = sevenDayOAuthApps
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.modelScoped = modelScoped
        self.extraUsage = extraUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(
            ClaudeCodeRateLimitWindowDTO.self,
            forKey: .fiveHour
        )
        sevenDay = try container.decodeIfPresent(
            ClaudeCodeRateLimitWindowDTO.self,
            forKey: .sevenDay
        )
        sevenDayOAuthApps = try container.decodeIfPresent(
            ClaudeCodeRateLimitWindowDTO.self,
            forKey: .sevenDayOAuthApps
        )
        sevenDayOpus = try container.decodeIfPresent(
            ClaudeCodeRateLimitWindowDTO.self,
            forKey: .sevenDayOpus
        )
        sevenDaySonnet = try container.decodeIfPresent(
            ClaudeCodeRateLimitWindowDTO.self,
            forKey: .sevenDaySonnet
        )
        modelScoped = try container.decodeIfPresent(
            [ClaudeCodeModelScopedWindowDTO].self,
            forKey: .modelScoped
        ) ?? []
        extraUsage = try container.decodeIfPresent(
            ClaudeCodeExtraUsageDTO.self,
            forKey: .extraUsage
        )
    }
}

struct ClaudeCodeUsageDTO: Decodable, Equatable, Sendable {
    let subscriptionType: String?
    let rateLimitsAvailable: Bool
    let rateLimits: ClaudeCodeRateLimitsDTO?

    private enum CodingKeys: String, CodingKey {
        case subscriptionType = "subscription_type"
        case rateLimitsAvailable = "rate_limits_available"
        case rateLimits = "rate_limits"
    }

    init(
        subscriptionType: String?,
        rateLimitsAvailable: Bool,
        rateLimits: ClaudeCodeRateLimitsDTO?
    ) {
        self.subscriptionType = subscriptionType
        self.rateLimitsAvailable = rateLimitsAvailable
        self.rateLimits = rateLimits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
        rateLimitsAvailable = try container.decodeIfPresent(Bool.self, forKey: .rateLimitsAvailable)
            ?? false
        rateLimits = try container.decodeIfPresent(ClaudeCodeRateLimitsDTO.self, forKey: .rateLimits)
    }
}

private struct ClaudeCodeControlResponseEnvelope: Decodable {
    let type: String
    let response: Response

    struct Response: Decodable {
        let subtype: String
        let requestID: String
        let response: ClaudeCodeUsageDTO?

        private enum CodingKeys: String, CodingKey {
            case subtype
            case requestID = "request_id"
            case response
        }
    }
}

enum ClaudeCodeUsageResponseParser {
    static func parse(_ data: Data, matching requestID: String) throws -> ClaudeCodeUsageDTO {
        guard data.count <= ClaudeCodeProcess.maximumCapturedOutputBytes else {
            throw ClaudeCodeConnectorError.outputTooLarge
        }

        let decoder = JSONDecoder()
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard rawLine.count <= ClaudeCodeProcess.maximumProtocolLineBytes else {
                throw ClaudeCodeConnectorError.outputTooLarge
            }
            guard
                let envelope = try? decoder.decode(
                    ClaudeCodeControlResponseEnvelope.self,
                    from: Data(rawLine)
                ),
                envelope.type == "control_response",
                envelope.response.requestID == requestID
            else {
                continue
            }
            guard
                envelope.response.subtype == "success",
                let usage = envelope.response.response
            else {
                throw ClaudeCodeConnectorError.invalidResponse
            }
            return usage
        }
        throw ClaudeCodeConnectorError.unsupportedUsageProtocol
    }
}
