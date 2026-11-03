import Foundation

/// User-entered subscription details, separate from metered usage and its reset windows.
public struct SubscriptionBillingDetails: Codable, Equatable, Sendable {
    public let planName: String?
    public let renewalDate: Date?
    public let costCADCents: Int64?

    public init(planName: String?, renewalDate: Date?, costCADCents: Int64?) throws {
        let name = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard costCADCents.map({ $0 >= 0 }) ?? true else {
            throw DomainValidationError.invalidSubscriptionCost
        }
        self.planName = name.flatMap { $0.isEmpty ? nil : $0 }
        self.renewalDate = renewalDate.map { Self.billingCalendar.startOfDay(for: $0) }
        self.costCADCents = costCADCents
    }

    public var isEmpty: Bool {
        planName == nil && renewalDate == nil && costCADCents == nil
    }

    // The invoice's civil date should not change when the Mac changes time zones.
    public static var billingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    public static func billingDate(onLocalDayOf date: Date) -> Date {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .autoupdatingCurrent
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        return billingCalendar.date(from: components) ?? billingCalendar.startOfDay(for: date)
    }

    public static func parseCADCents(_ input: String) throws -> Int64? {
        let amount = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !amount.isEmpty else { return nil }
        guard amount.wholeMatch(of: /[0-9]+(?:\.[0-9]{1,2})?/) != nil else {
            throw DomainValidationError.invalidSubscriptionCost
        }
        let parts = amount.split(separator: ".")
        let cents = parts.count == 2 ? parts[1].padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        guard let value = Int64(String(parts[0]) + cents) else {
            throw DomainValidationError.invalidSubscriptionCost
        }
        return value
    }
}
