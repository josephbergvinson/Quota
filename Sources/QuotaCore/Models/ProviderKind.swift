import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        }
    }
}

public enum UsageDataSourceKind: String, Codable, Sendable {
    case manual
    case chatGPTAppServer
    case openAIAdminAPI
}

public enum AccountKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPTPro
    case openAIAPI

    public var id: String { rawValue }

    public var provider: ProviderKind {
        switch self {
        case .chatGPTPro, .openAIAPI:
            .openAI
        }
    }

    public var dataSource: UsageDataSourceKind {
        switch self {
        case .chatGPTPro:
            .chatGPTAppServer
        case .openAIAPI:
            .openAIAdminAPI
        }
    }

    public var displayName: String {
        switch self {
        case .chatGPTPro:
            "ChatGPT Pro"
        case .openAIAPI:
            "OpenAI API organization"
        }
    }

    public var shortName: String {
        switch self {
        case .chatGPTPro:
            "ChatGPT Pro"
        case .openAIAPI:
            "OpenAI API"
        }
    }

    public var requiresCredential: Bool {
        switch dataSource {
        case .openAIAdminAPI:
            true
        case .manual, .chatGPTAppServer:
            false
        }
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
