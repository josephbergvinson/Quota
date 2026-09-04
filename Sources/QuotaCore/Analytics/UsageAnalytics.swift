import Foundation

public enum CapacityStatus: String, Sendable {
    case healthy
    case watch
    case low
    case exhausted
    case stale
    case unavailable

    public static func freshStatus(forRemainingFraction remainingFraction: Double) -> CapacityStatus {
        if remainingFraction == 0 { return .exhausted }
        if remainingFraction < 0.2 { return .low }
        if remainingFraction < 0.5 { return .watch }
        return .healthy
    }

    public static func freshStatus(forRemainingPercent remainingPercent: Double) -> CapacityStatus {
        freshStatus(forRemainingFraction: remainingPercent / 100)
    }
}

public struct AccountCapacity: Sendable, Equatable {
    public let account: ConnectedAccount
    public let remainingFraction: Double?
    public let limitingWindowName: String?
    public let nextResetAt: Date?
    public let capturedAt: Date?
    public let isStale: Bool

    public init(
        account: ConnectedAccount,
        remainingFraction: Double?,
        limitingWindowName: String?,
        nextResetAt: Date?,
        capturedAt: Date?,
        isStale: Bool
    ) {
        self.account = account
        self.remainingFraction = remainingFraction
        self.limitingWindowName = limitingWindowName
        self.nextResetAt = nextResetAt
        self.capturedAt = capturedAt
        self.isStale = isStale
    }

    public var status: CapacityStatus {
        guard let remainingFraction else { return .unavailable }
        if isStale { return .stale }
        return .freshStatus(forRemainingFraction: remainingFraction)
    }
}

public struct DashboardSummary: Sendable {
    public let capacities: [AccountCapacity]
    public let averageRemainingFraction: Double?
    public let recommendedAccount: AccountCapacity?
    public let totalTokens: Int?
    public let totalInputTokens: Int?
    public let totalOutputTokens: Int?
    public let totalRequests: Int?
    public let totalCostUSD: Double?

    public var accountsWithKnownCapacity: Int {
        capacities.count { $0.remainingFraction != nil && !$0.isStale }
    }
}

public struct ResetEvent: Identifiable, Sendable, Equatable {
    public let id: String
    public let account: ConnectedAccount
    public let windowName: String
    public let resetsAt: Date
    public let remainingFraction: Double
    public let capturedAt: Date
    public let source: UsageSource

    public init(
        account: ConnectedAccount,
        windowIdentifier: String,
        windowName: String,
        resetsAt: Date,
        remainingFraction: Double,
        capturedAt: Date,
        source: UsageSource
    ) {
        self.id = "\(account.id.uuidString)|\(windowIdentifier)|\(Int(resetsAt.timeIntervalSince1970))"
        self.account = account
        self.windowName = windowName
        self.resetsAt = resetsAt
        self.remainingFraction = min(1, max(0, remainingFraction))
        self.capturedAt = capturedAt
        self.source = source
    }
}

public enum UsageAnalytics {
    public static let capacityFreshnessInterval: TimeInterval = 6 * 60 * 60
    private static let uninitializedResetTolerance: TimeInterval = 5

    public static func dashboard(
        accounts: [ConnectedAccount],
        latestSnapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> DashboardSummary {
        let capacities = accounts.map { account in
            capacity(for: account, snapshot: latestSnapshots[account.id], now: now)
        }

        let knownFractions = capacities
            .filter { !$0.isStale }
            .compactMap(\.remainingFraction)
        let averageRemaining = knownFractions.isEmpty
            ? nil
            : knownFractions.reduce(0, +) / Double(knownFractions.count)
        let recommended = capacities
            .filter { $0.remainingFraction != nil && !$0.isStale }
            .sorted { left, right in
                guard let leftRemaining = left.remainingFraction, let rightRemaining = right.remainingFraction else {
                    return left.remainingFraction != nil
                }
                if leftRemaining == rightRemaining {
                    return left.account.displayName.localizedStandardCompare(right.account.displayName) == .orderedAscending
                }
                return leftRemaining > rightRemaining
            }
            .first

        let snapshots = accounts.compactMap { latestSnapshots[$0.id] }
        return DashboardSummary(
            capacities: capacities,
            averageRemainingFraction: averageRemaining,
            recommendedAccount: recommended,
            totalTokens: sumAvailable(snapshots.map(\.totalTokens)),
            totalInputTokens: sumAvailable(snapshots.map(\.inputTokens)),
            totalOutputTokens: sumAvailable(snapshots.map(\.outputTokens)),
            totalRequests: sumAvailable(snapshots.map(\.requests)),
            totalCostUSD: sumAvailable(snapshots.map(\.costUSD))
        )
    }

    public static func capacity(
        for account: ConnectedAccount,
        snapshot: UsageSnapshot?,
        now: Date
    ) -> AccountCapacity {
        guard let snapshot else {
            return AccountCapacity(
                account: account,
                remainingFraction: nil,
                limitingWindowName: nil,
                nextResetAt: nil,
                capturedAt: nil,
                isStale: false
            )
        }

        let isStale = now.timeIntervalSince(snapshot.capturedAt) > capacityFreshnessInterval
            || snapshot.capturedAt.timeIntervalSince(now) > 5 * 60

        let supportedWindows = supportedQuotaWindows(
            for: snapshot,
            accountKind: account.kind
        )
        let capacityWindows: [QuotaWindow]
        if snapshot.source == .claudeCodeOAuth {
            // Model- and surface-specific Claude limits are useful planning context, but they
            // do not describe the account's general availability. Keep the dashboard and account
            // recommendation anchored to the two plan-wide limits shown by Claude Code.
            capacityWindows = supportedWindows.filter {
                $0.identifier == "five_hour" || $0.identifier == "seven_day"
            }
        } else {
            capacityWindows = supportedWindows
        }
        let activeWindows = capacityWindows.filter { window in
            !isClearlyUninitializedChatGPTWindow(window, in: snapshot)
                && (window.resetsAt.map { $0 > now } ?? true)
        }
        if let limitingWindow = activeWindows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
            return AccountCapacity(
                account: account,
                remainingFraction: limitingWindow.remainingPercent / 100,
                limitingWindowName: limitingWindow.name,
                nextResetAt: limitingWindow.resetsAt,
                capturedAt: snapshot.capturedAt,
                isStale: isStale
            )
        }

        if
            snapshot.source != .claudeCodeOAuth,
            let allowance = snapshot.allowance.value,
            snapshot.resetAt.value.map({ $0 > now }) ?? true
        {
            return AccountCapacity(
                account: account,
                remainingFraction: allowance.remainingFraction,
                limitingWindowName: "Current allowance",
                nextResetAt: snapshot.resetAt.value,
                capturedAt: snapshot.capturedAt,
                isStale: isStale
            )
        }

        return AccountCapacity(
            account: account,
            remainingFraction: nil,
            limitingWindowName: nil,
            nextResetAt: nil,
            capturedAt: snapshot.capturedAt,
            isStale: isStale
        )
    }

    /// Returns the quota windows that Quota supports for presentation. ChatGPT-backed Codex can
    /// expose model-specific and unrelated buckets. Quota retains the regular one-week window
    /// for Pro, plus the regular five-hour window for Plus, while filtering older saved readings
    /// through the same tier-aware policy. Manual readings remain untouched.
    public static func supportedQuotaWindows(
        for snapshot: UsageSnapshot,
        accountKind: AccountKind
    ) -> [QuotaWindow] {
        let windows = snapshot.quotaWindows.value ?? []
        guard snapshot.source == .chatGPTAppServer else { return windows }
        return windows.filter {
            ChatGPTQuotaWindowPolicy.isSupportedWindow($0, accountKind: accountKind)
        }
    }

    public static func resetEvents(
        accounts: [ConnectedAccount],
        snapshots: [UsageSnapshot],
        in interval: DateInterval
    ) -> [ResetEvent] {
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let snapshotsByAccount = Dictionary(grouping: snapshots, by: \.accountID)
        let quotaReadingsByAccount = snapshotsByAccount.mapValues { accountSnapshots in
            accountSnapshots
                .filter { $0.source == .manual || $0.quotaWindows.value != nil }
                .sorted { $0.capturedAt < $1.capturedAt }
        }
        let allowanceReadingsByAccount = snapshotsByAccount.mapValues { accountSnapshots in
            accountSnapshots
                .filter { $0.allowance.value != nil }
                .sorted { $0.capturedAt < $1.capturedAt }
        }
        var eventsByID: [String: ResetEvent] = [:]

        for snapshot in snapshots {
            guard let account = accountsByID[snapshot.accountID] else { continue }
            let rawQuotaWindows = snapshot.quotaWindows.value ?? []
            let quotaWindows = supportedQuotaWindows(
                for: snapshot,
                accountKind: account.kind
            )
            for window in quotaWindows {
                guard !isClearlyUninitializedChatGPTWindow(window, in: snapshot) else { continue }
                guard let resetsAt = window.resetsAt, interval.containsHalfOpen(resetsAt) else { continue }
                guard !isSuperseded(
                    snapshot: snapshot,
                    windowIdentifier: window.identifier,
                    resetsAt: resetsAt,
                    authoritativeSnapshots: quotaReadingsByAccount[snapshot.accountID] ?? []
                ) else {
                    continue
                }
                let event = ResetEvent(
                    account: account,
                    windowIdentifier: window.identifier,
                    windowName: window.name,
                    resetsAt: resetsAt,
                    remainingFraction: window.remainingPercent / 100,
                    capturedAt: snapshot.capturedAt,
                    source: snapshot.source
                )
                if let existing = eventsByID[event.id], existing.capturedAt >= event.capturedAt {
                    continue
                }
                eventsByID[event.id] = event
            }

            // A reading containing only an excluded provider bucket is not an
            // allowance reading. Keep the raw-window check so its reset cannot
            // reappear under the generic "Current allowance" label.
            if
                rawQuotaWindows.isEmpty,
                let allowance = snapshot.allowance.value,
                let resetsAt = snapshot.resetAt.value,
                interval.containsHalfOpen(resetsAt),
                !isSupersededAllowanceReset(
                    snapshot: snapshot,
                    resetsAt: resetsAt,
                    authoritativeSnapshots: allowanceReadingsByAccount[snapshot.accountID] ?? []
                )
            {
                let event = ResetEvent(
                    account: account,
                    windowIdentifier: "allowance",
                    windowName: "Current allowance",
                    resetsAt: resetsAt,
                    remainingFraction: allowance.remainingFraction,
                    capturedAt: snapshot.capturedAt,
                    source: snapshot.source
                )
                if let existing = eventsByID[event.id], existing.capturedAt >= event.capturedAt {
                    continue
                }
                eventsByID[event.id] = event
            }
        }

        return eventsByID.values.sorted {
            if $0.resetsAt == $1.resetsAt {
                return $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending
            }
            return $0.resetsAt < $1.resetsAt
        }
    }

    public static func forwardResetInterval(
        startingAt referenceDate: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let anchorDay = calendar.startOfDay(for: referenceDate)
        guard let end = calendar.date(byAdding: .day, value: 8, to: anchorDay) else {
            return nil
        }
        return DateInterval(start: anchorDay, end: end)
    }

    private static func sumAvailable(_ metrics: [Metric<Int>]) -> Int? {
        let values = metrics.compactMap(\.value)
        guard !values.isEmpty else { return nil }
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (updated, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = updated
        }
        return total
    }

    private static func sumAvailable(_ metrics: [Metric<Double>]) -> Double? {
        let values = metrics.compactMap(\.value)
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let total = values.reduce(0, +)
        return total.isFinite ? total : nil
    }

    private static func isSuperseded(
        snapshot: UsageSnapshot,
        windowIdentifier: String,
        resetsAt: Date,
        authoritativeSnapshots: [UsageSnapshot]
    ) -> Bool {
        guard
            let newestReading = newestSnapshot(before: resetsAt, in: authoritativeSnapshots),
            newestReading.capturedAt > snapshot.capturedAt
        else {
            return false
        }
        let windows = newestReading.quotaWindows.value ?? []
        return windows.first(where: { $0.identifier == windowIdentifier })?.resetsAt != resetsAt
    }

    /// Older saved readings can contain an unused Codex bucket whose reset was anchored to the
    /// refresh instant. Ignore that exact sliding-placeholder signature during local analysis too.
    private static func isClearlyUninitializedChatGPTWindow(
        _ window: QuotaWindow,
        in snapshot: UsageSnapshot
    ) -> Bool {
        guard
            snapshot.source == .chatGPTAppServer,
            window.usedPercent == 0,
            let durationMinutes = window.durationMinutes,
            let resetsAt = window.resetsAt
        else {
            return false
        }
        let expectedReset = snapshot.capturedAt.addingTimeInterval(Double(durationMinutes) * 60)
        return abs(resetsAt.timeIntervalSince(expectedReset)) <= uninitializedResetTolerance
    }

    private static func isSupersededAllowanceReset(
        snapshot: UsageSnapshot,
        resetsAt: Date,
        authoritativeSnapshots: [UsageSnapshot]
    ) -> Bool {
        guard
            let newestReading = newestSnapshot(before: resetsAt, in: authoritativeSnapshots),
            newestReading.capturedAt > snapshot.capturedAt
        else {
            return false
        }
        return newestReading.resetAt.value != resetsAt
    }

    private static func newestSnapshot(
        before date: Date,
        in snapshots: [UsageSnapshot]
    ) -> UsageSnapshot? {
        var lowerBound = 0
        var upperBound = snapshots.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if snapshots[midpoint].capturedAt < date {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        guard lowerBound > 0 else { return nil }
        return snapshots[lowerBound - 1]
    }
}

private extension DateInterval {
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
