import Foundation

public struct DashboardTokenBreakdown: Sendable, Equatable {
    public let interval: DateInterval
    public let dailyPoints: [DailyUsagePoint]
    public let totalTokens: Int?
    public let uncachedInputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let unattributedTokens: Int?
    public let accountCount: Int
    public let accountsReportingDailyUsage: Int
    public let accountsReportingTokenSplit: Int

    public init(
        interval: DateInterval,
        dailyPoints: [DailyUsagePoint],
        totalTokens: Int?,
        uncachedInputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        unattributedTokens: Int?,
        accountCount: Int,
        accountsReportingDailyUsage: Int,
        accountsReportingTokenSplit: Int
    ) {
        self.interval = interval
        self.dailyPoints = dailyPoints
        self.totalTokens = totalTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.unattributedTokens = unattributedTokens
        self.accountCount = accountCount
        self.accountsReportingDailyUsage = accountsReportingDailyUsage
        self.accountsReportingTokenSplit = accountsReportingTokenSplit
    }
}

private struct IndexedUsageSnapshot {
    let index: Int
    let snapshot: UsageSnapshot
}

private struct SelectedSnapshotDayPoint {
    let point: DailyUsagePoint
    let capturedAt: Date
    let snapshotIndex: Int
    let reportsTokenSplit: Bool
}

public extension UsageAnalytics {
    /// Aggregates provider-reported daily buckets over a common UTC date range.
    /// All-time results merge retained snapshots, choosing the newest reported value for each
    /// account/day so rolling provider payloads are not counted more than once. Fixed ranges keep
    /// using each account's latest snapshot. Cached input is a subset of input and is never added
    /// to total tokens a second time.
    static func tokenBreakdown(
        accounts: [ConnectedAccount],
        snapshots: [UsageSnapshot],
        now: Date,
        dayCount: Int?
    ) -> DashboardTokenBreakdown {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!

        let connectedAccountIDs = Set(accounts.map(\.id))
        let connectedSnapshots = snapshots.enumerated().compactMap { index, snapshot in
            connectedAccountIDs.contains(snapshot.accountID)
                ? IndexedUsageSnapshot(index: index, snapshot: snapshot)
                : nil
        }
        let candidateSnapshots: [IndexedUsageSnapshot]
        if dayCount == nil {
            candidateSnapshots = connectedSnapshots
        } else {
            var latestByAccount: [UUID: IndexedUsageSnapshot] = [:]
            for candidate in connectedSnapshots {
                guard let current = latestByAccount[candidate.snapshot.accountID] else {
                    latestByAccount[candidate.snapshot.accountID] = candidate
                    continue
                }
                if isMoreRecent(candidate, than: current) {
                    latestByAccount[candidate.snapshot.accountID] = candidate
                }
            }
            candidateSnapshots = Array(latestByAccount.values)
        }

        let start: Date
        if let dayCount {
            let normalizedDayCount = max(1, dayCount)
            start = calendar.date(byAdding: .day, value: -normalizedDayCount, to: end)!
        } else {
            let earliestBucket = candidateSnapshots
                .compactMap { $0.snapshot.dailyUsage.value }
                .flatMap { $0 }
                .map(\.date)
                .filter { $0.timeIntervalSinceReferenceDate.isFinite && $0 < end }
                .min()
            start = earliestBucket.map { calendar.startOfDay(for: $0) }
                ?? calendar.startOfDay(for: now)
        }
        let interval = DateInterval(start: start, end: end)

        var pointsByDay: [Date: DailyUsagePoint] = [:]
        var allDailyValuesAreValid = true
        var dailyReportingCount = 0
        var splitReportingCount = 0
        var splitInput = 0
        var splitCached = 0
        var splitOutput = 0
        var splitValuesAreValid = true

        let candidatesByAccount = Dictionary(
            grouping: candidateSnapshots,
            by: { $0.snapshot.accountID }
        )
        for account in accounts {
            let dailySnapshots = (candidatesByAccount[account.id] ?? []).filter {
                $0.snapshot.dailyUsage.value != nil
            }
            guard !dailySnapshots.isEmpty else { continue }
            dailyReportingCount += 1

            var selectedPointsByDay: [Date: SelectedSnapshotDayPoint] = [:]
            for candidate in dailySnapshots {
                var snapshotPointsByDay: [Date: DailyUsagePoint] = [:]
                for point in candidate.snapshot.dailyUsage.value ?? []
                    where interval.containsHalfOpen(point.date)
                {
                    let day = calendar.startOfDay(for: point.date)
                    guard let combined = combinedDailyPoint(
                        snapshotPointsByDay[day],
                        point,
                        day: day
                    ) else {
                        allDailyValuesAreValid = false
                        continue
                    }
                    snapshotPointsByDay[day] = combined
                }

                let reportsTokenSplit = reportsTokenSplit(candidate.snapshot)
                for (day, point) in snapshotPointsByDay {
                    if let current = selectedPointsByDay[day],
                       !isMoreRecent(candidate, than: current) {
                        continue
                    }
                    selectedPointsByDay[day] = SelectedSnapshotDayPoint(
                        point: point,
                        capturedAt: candidate.snapshot.capturedAt,
                        snapshotIndex: candidate.index,
                        reportsTokenSplit: reportsTokenSplit
                    )
                }
            }

            let selectedPoints = selectedPointsByDay.values.map(\.point)
            for point in selectedPoints {
                let day = point.date
                guard let combined = combinedDailyPoint(pointsByDay[day], point, day: day) else {
                    allDailyValuesAreValid = false
                    continue
                }
                pointsByDay[day] = combined
            }

            let reportsSplit: Bool
            if selectedPointsByDay.isEmpty {
                let latestDailySnapshot = dailySnapshots.max {
                    isMoreRecent($1, than: $0)
                }
                reportsSplit = latestDailySnapshot.map { reportsTokenSplit($0.snapshot) } ?? false
            } else {
                reportsSplit = selectedPointsByDay.values.allSatisfy(\.reportsTokenSplit)
            }
            guard reportsSplit else { continue }

            var accountInput = 0
            var accountCached = 0
            var accountOutput = 0
            var accountValuesAreValid = true
            for point in selectedPoints {
                guard
                    point.cachedInputTokens <= point.inputTokens,
                    let nextInput = checkedAdd(accountInput, point.inputTokens),
                    let nextCached = checkedAdd(accountCached, point.cachedInputTokens),
                    let nextOutput = checkedAdd(accountOutput, point.outputTokens)
                else {
                    accountValuesAreValid = false
                    break
                }
                accountInput = nextInput
                accountCached = nextCached
                accountOutput = nextOutput
            }
            guard accountValuesAreValid else {
                splitValuesAreValid = false
                continue
            }

            splitReportingCount += 1
            guard
                let nextInput = checkedAdd(splitInput, accountInput),
                let nextCached = checkedAdd(splitCached, accountCached),
                let nextOutput = checkedAdd(splitOutput, accountOutput)
            else {
                splitValuesAreValid = false
                continue
            }
            splitInput = nextInput
            splitCached = nextCached
            splitOutput = nextOutput
        }

        let dailyPoints = allDailyValuesAreValid
            ? pointsByDay.values.sorted { $0.date < $1.date }
            : []
        let totalTokens = dailyReportingCount > 0 && allDailyValuesAreValid
            ? checkedSum(dailyPoints.map(\.totalTokens))
            : nil
        let unattributedTokens = dailyReportingCount > 0 && allDailyValuesAreValid
            ? checkedSum(dailyPoints.map(\.unattributedTokens))
            : nil
        let hasValidSplit = splitReportingCount > 0 && splitValuesAreValid

        return DashboardTokenBreakdown(
            interval: interval,
            dailyPoints: dailyPoints,
            totalTokens: totalTokens,
            uncachedInputTokens: hasValidSplit ? splitInput - splitCached : nil,
            cachedInputTokens: hasValidSplit ? splitCached : nil,
            outputTokens: hasValidSplit ? splitOutput : nil,
            unattributedTokens: unattributedTokens,
            accountCount: accounts.count,
            accountsReportingDailyUsage: dailyReportingCount,
            accountsReportingTokenSplit: splitReportingCount
        )
    }

    private static func isMoreRecent(
        _ candidate: IndexedUsageSnapshot,
        than current: IndexedUsageSnapshot
    ) -> Bool {
        if candidate.snapshot.capturedAt != current.snapshot.capturedAt {
            return candidate.snapshot.capturedAt > current.snapshot.capturedAt
        }
        return candidate.index > current.index
    }

    private static func isMoreRecent(
        _ candidate: IndexedUsageSnapshot,
        than current: SelectedSnapshotDayPoint
    ) -> Bool {
        if candidate.snapshot.capturedAt != current.capturedAt {
            return candidate.snapshot.capturedAt > current.capturedAt
        }
        return candidate.index > current.snapshotIndex
    }

    private static func reportsTokenSplit(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.inputTokens.value != nil
            && snapshot.cachedInputTokens.value != nil
            && snapshot.outputTokens.value != nil
    }

    /// Converts daily increments into a date-sorted running series. Invalid arithmetic is rejected
    /// as a whole so charts never present wrapped or partially accumulated values.
    static func cumulativeUsage(_ points: [DailyUsagePoint]) -> [DailyUsagePoint] {
        guard points.allSatisfy({ point in
            point.date.timeIntervalSinceReferenceDate.isFinite
                && point.inputTokens >= 0
                && point.cachedInputTokens >= 0
                && point.cachedInputTokens <= point.inputTokens
                && point.outputTokens >= 0
                && point.unattributedTokens >= 0
                && point.requests >= 0
                && point.costUSD.isFinite
                && point.costUSD >= 0
        }) else {
            return []
        }

        let sortedPoints = points.enumerated().sorted { left, right in
            if left.element.date == right.element.date {
                return left.offset < right.offset
            }
            return left.element.date < right.element.date
        }
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var unattributedTokens = 0
        var requests = 0
        var costUSD = 0.0
        var cumulativePoints: [DailyUsagePoint] = []
        cumulativePoints.reserveCapacity(sortedPoints.count)

        for entry in sortedPoints {
            let point = entry.element
            guard
                let nextInputTokens = checkedAdd(inputTokens, point.inputTokens),
                let nextCachedInputTokens = checkedAdd(
                    cachedInputTokens,
                    point.cachedInputTokens
                ),
                let nextOutputTokens = checkedAdd(outputTokens, point.outputTokens),
                let nextUnattributedTokens = checkedAdd(
                    unattributedTokens,
                    point.unattributedTokens
                ),
                let nextRequests = checkedAdd(requests, point.requests),
                let attributedTokens = checkedAdd(nextInputTokens, nextOutputTokens),
                checkedAdd(attributedTokens, nextUnattributedTokens) != nil
            else {
                return []
            }

            let nextCostUSD = costUSD + point.costUSD
            guard nextCostUSD.isFinite, nextCostUSD >= 0 else { return [] }

            inputTokens = nextInputTokens
            cachedInputTokens = nextCachedInputTokens
            outputTokens = nextOutputTokens
            unattributedTokens = nextUnattributedTokens
            requests = nextRequests
            costUSD = nextCostUSD
            cumulativePoints.append(
                DailyUsagePoint(
                    date: point.date,
                    inputTokens: inputTokens,
                    cachedInputTokens: cachedInputTokens,
                    outputTokens: outputTokens,
                    unattributedTokens: unattributedTokens,
                    requests: requests,
                    costUSD: costUSD
                )
            )
        }

        return cumulativePoints
    }

    private static func combinedDailyPoint(
        _ previous: DailyUsagePoint?,
        _ next: DailyUsagePoint,
        day: Date
    ) -> DailyUsagePoint? {
        guard
            let inputTokens = checkedAdd(previous?.inputTokens ?? 0, next.inputTokens),
            let cachedInputTokens = checkedAdd(
                previous?.cachedInputTokens ?? 0,
                next.cachedInputTokens
            ),
            let outputTokens = checkedAdd(previous?.outputTokens ?? 0, next.outputTokens),
            let unattributedTokens = checkedAdd(
                previous?.unattributedTokens ?? 0,
                next.unattributedTokens
            ),
            let requests = checkedAdd(previous?.requests ?? 0, next.requests),
            let attributedTokens = checkedAdd(inputTokens, outputTokens),
            checkedAdd(attributedTokens, unattributedTokens) != nil
        else {
            return nil
        }

        let costUSD = (previous?.costUSD ?? 0) + next.costUSD
        guard costUSD.isFinite else { return nil }
        return DailyUsagePoint(
            date: day,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            unattributedTokens: unattributedTokens,
            requests: requests,
            costUSD: costUSD
        )
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        values.reduce(0) { partial, value in
            guard let partial else { return nil }
            return checkedAdd(partial, value)
        }
    }

    private static func checkedAdd(_ left: Int, _ right: Int) -> Int? {
        guard left >= 0, right >= 0 else { return nil }
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? nil : result
    }
}

private extension DateInterval {
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
