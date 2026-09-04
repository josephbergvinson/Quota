import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAI
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        }
    }
}

public enum UsageDataSourceKind: String, Codable, Sendable {
    case manual
    case chatGPTAppServer
    case claudeCodeOAuth
    case openAIAdminAPI
    case anthropicAdminAPI
}

public enum AccountKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPTPlus
    case chatGPTPro
    /// Migrated from the old account type, which labeled every ChatGPT subscription "Pro".
    case chatGPTSubscription
    case claudePro
    case claudeMax
    /// Migrated from the old ambiguous "Claude Pro / Max" account type.
    case claudeSubscription
    case openAIAPI
    case anthropicAPI

    public static let allCases: [AccountKind] = [
        .chatGPTPlus,
        .chatGPTPro,
        .openAIAPI,
        .claudePro,
        .claudeMax,
        .anthropicAPI
    ]

    public var id: String { rawValue }

    public var provider: ProviderKind {
        switch self {
        case .chatGPTPlus, .chatGPTPro, .chatGPTSubscription, .openAIAPI:
            .openAI
        case .claudePro, .claudeMax, .claudeSubscription, .anthropicAPI:
            .anthropic
        }
    }

    public var dataSource: UsageDataSourceKind {
        switch self {
        case .chatGPTPlus, .chatGPTPro, .chatGPTSubscription:
            .chatGPTAppServer
        case .claudePro, .claudeMax, .claudeSubscription:
            .claudeCodeOAuth
        case .openAIAPI:
            .openAIAdminAPI
        case .anthropicAPI:
            .anthropicAdminAPI
        }
    }

    public var displayName: String {
        switch self {
        case .chatGPTPlus:
            "ChatGPT Plus"
        case .chatGPTPro:
            "ChatGPT Pro"
        case .chatGPTSubscription:
            "ChatGPT subscription"
        case .claudePro:
            "Claude Pro"
        case .claudeMax:
            "Claude Max"
        case .claudeSubscription:
            "Claude subscription"
        case .openAIAPI:
            "OpenAI API organization"
        case .anthropicAPI:
            "Anthropic API organization"
        }
    }

    public var shortName: String {
        switch self {
        case .chatGPTPlus:
            "ChatGPT Plus"
        case .chatGPTPro:
            "ChatGPT Pro"
        case .chatGPTSubscription:
            "ChatGPT subscription"
        case .claudePro:
            "Claude Pro"
        case .claudeMax:
            "Claude Max"
        case .claudeSubscription:
            "Claude subscription"
        case .openAIAPI:
            "OpenAI API"
        case .anthropicAPI:
            "Anthropic API"
        }
    }

    public var requiresCredential: Bool {
        switch dataSource {
        case .openAIAdminAPI, .anthropicAdminAPI:
            true
        case .manual, .chatGPTAppServer, .claudeCodeOAuth:
            false
        }
    }

    public var isChatGPTSubscription: Bool {
        dataSource == .chatGPTAppServer
    }

    public var isClaudeSubscription: Bool {
        dataSource == .claudeCodeOAuth
    }

    public var isManagedSubscription: Bool {
        isChatGPTSubscription || isClaudeSubscription
    }

    public var isAPIOrganization: Bool {
        dataSource == .openAIAdminAPI || dataSource == .anthropicAdminAPI
    }
}

public struct ConnectedAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let kind: AccountKind
    public var organizationIdentifier: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: AccountKind,
        organizationIdentifier: String? = nil,
        createdAt: Date = Date()
    ) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw DomainValidationError.emptyAccountName
        }

        self.id = id
        self.displayName = normalizedName
        self.kind = kind
        let normalizedOrganizationIdentifier = organizationIdentifier?.nilIfBlank
        if let normalizedOrganizationIdentifier {
            let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            guard normalizedOrganizationIdentifier.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
                throw DomainValidationError.invalidOrganizationIdentifier
            }
        }
        self.organizationIdentifier = normalizedOrganizationIdentifier
        self.createdAt = createdAt
    }

    public func validated() throws -> ConnectedAccount {
        try ConnectedAccount(
            id: id,
            displayName: displayName,
            kind: kind,
            organizationIdentifier: organizationIdentifier,
            createdAt: createdAt
        )
    }
}

public enum DomainValidationError: LocalizedError, Equatable {
    case emptyAccountName
    case nonFiniteUsage
    case negativeUsage
    case invalidLimit
    case invalidReportingPeriod
    case invalidOrganizationIdentifier
    case emptyQuotaWindowName
    case invalidUsagePercentage
    case invalidWindowDuration
    case invalidBankedResetCredits

    public var errorDescription: String? {
        switch self {
        case .emptyAccountName:
            "Enter a name for this account."
        case .nonFiniteUsage:
            "Usage values must be finite numbers."
        case .negativeUsage:
            "Usage cannot be negative."
        case .invalidLimit:
            "The limit must be greater than zero."
        case .invalidReportingPeriod:
            "The reporting period must end after it starts."
        case .invalidOrganizationIdentifier:
            "The organization identifier contains unsupported characters."
        case .emptyQuotaWindowName:
            "Enter a name for the usage window."
        case .invalidUsagePercentage:
            "Used percentage must be a non-negative number."
        case .invalidWindowDuration:
            "Window duration must be greater than zero."
        case .invalidBankedResetCredits:
            "Banked reset data contains an invalid count or expiry time."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
