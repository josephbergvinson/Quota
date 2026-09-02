import Foundation

public struct ProviderFetchResult: Sendable {
    public let snapshot: UsageSnapshot
    public let warnings: [String]
    public let providerAccountLabel: String?
    public let providerPlanLabel: String?

    public init(
        snapshot: UsageSnapshot,
        warnings: [String] = [],
        providerAccountLabel: String? = nil,
        providerPlanLabel: String? = nil
    ) {
        self.snapshot = snapshot
        self.warnings = warnings
        self.providerAccountLabel = providerAccountLabel
        self.providerPlanLabel = providerPlanLabel
    }
}

public protocol UsageProvider: Sendable {
    var dataSourceKind: UsageDataSourceKind { get }

    func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult
}

public enum ProviderError: LocalizedError, Equatable {
    case unsupportedAccount
    case missingCredential
    case invalidURL
    case invalidHTTPResponse
    case unexpectedStatus(code: Int, message: String?)
    case invalidResponse
    case paginationLimitReached

    public var errorDescription: String? {
        switch self {
        case .unsupportedAccount:
            "This connector does not support the selected account."
        case .missingCredential:
            "This account needs an admin API key."
        case .invalidURL:
            "Quota could not construct the provider request."
        case .invalidHTTPResponse:
            "The provider returned an invalid response."
        case let .unexpectedStatus(code, message):
            if let message, !message.isEmpty {
                "Provider request failed (HTTP \(code)): \(message)"
            } else {
                "Provider request failed (HTTP \(code))."
            }
        case .invalidResponse:
            "The provider returned data Quota could not read."
        case .paginationLimitReached:
            "The provider returned too many result pages for one refresh."
        }
    }
}

extension ProviderError {
    static func from(response: HTTPResponse) -> ProviderError? {
        guard !(200...299).contains(response.statusCode) else { return nil }
        return .unexpectedStatus(
            code: response.statusCode,
            message: providerErrorMessage(from: response.data)
        )
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return nil
        }

        let singleLine = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(300))
    }
}

struct FlexibleDouble: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        let string = try container.decode(String.self)
        guard let number = Double(string), number.isFinite else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a finite decimal number."
            )
        }
        value = number
    }
}
