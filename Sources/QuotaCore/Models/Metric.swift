import Foundation

public enum UnavailableReason: String, Codable, Equatable, Sendable {
    case awaitingFirstRefresh
    case notExposedByProvider
    case notEntered
    case unsupportedForAccount
    case refreshFailed
    case notReturned
}

public struct UnavailableMetric: Codable, Equatable, Sendable {
    public let reason: UnavailableReason
    public let detail: String

    public init(reason: UnavailableReason, detail: String) {
        self.reason = reason
        self.detail = detail
    }

    public static let awaitingFirstRefresh = UnavailableMetric(
        reason: .awaitingFirstRefresh,
        detail: "Available after the first successful refresh."
    )

    public static let notEntered = UnavailableMetric(
        reason: .notEntered,
        detail: "No manual reading has been recorded."
    )
}

public enum Metric<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case available(Value)
    case unavailable(UnavailableMetric)

    public var value: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }

    public var unavailability: UnavailableMetric? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}
