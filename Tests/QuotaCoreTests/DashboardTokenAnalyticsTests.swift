import Foundation
import XCTest
@testable import QuotaCore

final class DashboardTokenAnalyticsTests: XCTestCase {
    func testCommonRangeTotalsDoNotDoubleCountCachedInputAndReportCoverage() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let splitAccount = try makeAccount(name: "API", kind: .openAIAPI)
        let aggregateAccount = try makeAccount(name: "ChatGPT", kind: .chatGPTPro)
        let includedDay = utcDate(year: 2026, month: 9, day: 1)

        let splitSnapshot = makeSnapshot(
            accountID: splitAccount.id,
            capturedAt: now,
            inputMetric: .available(100),
            cachedMetric: .available(40),
            outputMetric: .available(20),
            points: [
                DailyUsagePoint(
                    date: includedDay,
                    inputTokens: 100,
                    cachedInputTokens: 40,
                    outputTokens: 20
                )
            ]
        )
        let aggregateSnapshot = makeSnapshot(
            accountID: aggregateAccount.id,
            capturedAt: now,
            inputMetric: unavailableMetric(),
            cachedMetric: unavailableMetric(),
            outputMetric: unavailableMetric(),
            points: [DailyUsagePoint(date: includedDay, unattributedTokens: 50)]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [splitAccount, aggregateAccount],
            snapshots: [splitSnapshot, aggregateSnapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertEqual(result.totalTokens, 170)
        XCTAssertEqual(result.uncachedInputTokens, 60)
        XCTAssertEqual(result.cachedInputTokens, 40)
        XCTAssertEqual(result.outputTokens, 20)
        XCTAssertEqual(result.unattributedTokens, 50)
        XCTAssertEqual(result.accountsReportingDailyUsage, 2)
        XCTAssertEqual(result.accountsReportingTokenSplit, 1)
        XCTAssertEqual(result.dailyPoints.count, 1)
        XCTAssertEqual(result.dailyPoints[0].totalTokens, 170)
    }

    func testTokenTotalsCombineOpenAIAndAnthropicReportedUsage() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let openAIAccount = try makeAccount(name: "OpenAI API", kind: .openAIAPI)
        let anthropicAccount = try makeAccount(name: "Anthropic API", kind: .anthropicAPI)
        let day = utcDate(year: 2026, month: 9, day: 1)
        let openAISnapshot = makeSnapshot(
            accountID: openAIAccount.id,
            capturedAt: now,
            inputMetric: .available(10),
            cachedMetric: .available(2),
            outputMetric: .available(3),
            points: [
                DailyUsagePoint(
                    date: day,
                    inputTokens: 10,
                    cachedInputTokens: 2,
                    outputTokens: 3
                )
            ],
            source: .openAIAdminAPI
        )
        let anthropicSnapshot = makeSnapshot(
            accountID: anthropicAccount.id,
            capturedAt: now,
            inputMetric: .available(20),
            cachedMetric: .available(4),
            outputMetric: .available(5),
            points: [
                DailyUsagePoint(
                    date: day,
                    inputTokens: 20,
                    cachedInputTokens: 4,
                    outputTokens: 5
                )
            ],
            source: .anthropicAdminAPI
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [openAIAccount, anthropicAccount],
            snapshots: [openAISnapshot, anthropicSnapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertEqual(result.totalTokens, 38)
        XCTAssertEqual(result.uncachedInputTokens, 24)
        XCTAssertEqual(result.cachedInputTokens, 6)
        XCTAssertEqual(result.outputTokens, 8)
        XCTAssertEqual(result.accountsReportingDailyUsage, 2)
        XCTAssertEqual(result.accountsReportingTokenSplit, 2)
        XCTAssertEqual(result.dailyPoints.map(\.totalTokens), [38])
    }

    func testRangeIncludesLastSevenUTCDaysAndUsesExclusiveEnd() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let account = try makeAccount(kind: .openAIAPI)
        let snapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: now,
            inputMetric: .available(6),
            cachedMetric: .available(0),
            outputMetric: .available(0),
            points: [
                DailyUsagePoint(date: utcDate(year: 2026, month: 8, day: 26), inputTokens: 1),
                DailyUsagePoint(date: utcDate(year: 2026, month: 8, day: 27), inputTokens: 2),
                DailyUsagePoint(date: utcDate(year: 2026, month: 9, day: 2), inputTokens: 4),
                DailyUsagePoint(date: utcDate(year: 2026, month: 9, day: 3), inputTokens: 8)
            ]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [account],
            snapshots: [snapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertEqual(result.totalTokens, 6)
        XCTAssertEqual(result.dailyPoints.map(\.inputTokens), [2, 4])
        XCTAssertEqual(result.interval.start, utcDate(year: 2026, month: 8, day: 27))
        XCTAssertEqual(result.interval.end, utcDate(year: 2026, month: 9, day: 3))
    }

    func testUnavailableTokenSplitStaysUnavailableInsteadOfBecomingZero() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: now,
            inputMetric: unavailableMetric(),
            cachedMetric: unavailableMetric(),
            outputMetric: unavailableMetric(),
            points: [DailyUsagePoint(date: now, unattributedTokens: 25)]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [account],
            snapshots: [snapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertEqual(result.totalTokens, 25)
        XCTAssertNil(result.uncachedInputTokens)
        XCTAssertNil(result.cachedInputTokens)
        XCTAssertNil(result.outputTokens)
        XCTAssertEqual(result.accountsReportingTokenSplit, 0)
    }

    func testOverflowMakesAggregateUnavailableInsteadOfWrapping() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let first = try makeAccount(name: "First", kind: .chatGPTPro)
        let second = try makeAccount(name: "Second", kind: .chatGPTPro)
        let unavailable: Metric<Int> = unavailableMetric()
        let firstSnapshot = makeSnapshot(
            accountID: first.id,
            capturedAt: now,
            inputMetric: unavailable,
            cachedMetric: unavailable,
            outputMetric: unavailable,
            points: [DailyUsagePoint(date: now, unattributedTokens: Int.max)]
        )
        let secondSnapshot = makeSnapshot(
            accountID: second.id,
            capturedAt: now,
            inputMetric: unavailable,
            cachedMetric: unavailable,
            outputMetric: unavailable,
            points: [DailyUsagePoint(date: now, unattributedTokens: 1)]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [first, second],
            snapshots: [firstSnapshot, secondSnapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertNil(result.totalTokens)
        XCTAssertTrue(result.dailyPoints.isEmpty)
    }

    func testAllHistoryStartsAtEarliestConnectedDailyBucket() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let account = try makeAccount(kind: .openAIAPI)
        let disconnectedAccount = try makeAccount(name: "Disconnected", kind: .openAIAPI)
        let earliestConnectedDay = utcDate(year: 2026, month: 6, day: 4)
        let snapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: now,
            inputMetric: .available(7),
            cachedMetric: .available(0),
            outputMetric: .available(0),
            points: [
                DailyUsagePoint(date: now, inputTokens: 5),
                DailyUsagePoint(date: earliestConnectedDay, inputTokens: 2)
            ]
        )
        let disconnectedSnapshot = makeSnapshot(
            accountID: disconnectedAccount.id,
            capturedAt: now,
            inputMetric: .available(100),
            cachedMetric: .available(0),
            outputMetric: .available(0),
            points: [
                DailyUsagePoint(
                    date: utcDate(year: 2025, month: 1, day: 1),
                    inputTokens: 100
                )
            ]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [account],
            snapshots: [snapshot, disconnectedSnapshot],
            now: now,
            dayCount: nil
        )

        XCTAssertEqual(result.interval.start, earliestConnectedDay)
        XCTAssertEqual(result.interval.end, utcDate(year: 2026, month: 9, day: 3))
        XCTAssertEqual(
            result.dailyPoints.map(\.date),
            [earliestConnectedDay, utcDate(year: 2026, month: 9, day: 2)]
        )
        XCTAssertEqual(result.totalTokens, 7)
    }

    func testAllHistoryMergesOlderRetainedBucketsAndUsesNewestOverlapOnce() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let account = try makeAccount(kind: .openAIAPI)
        let oldestDay = utcDate(year: 2026, month: 7, day: 1)
        let overlappingDay = utcDate(year: 2026, month: 8, day: 10)
        let currentDay = utcDate(year: 2026, month: 9, day: 2)

        let olderSnapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: utcDate(year: 2026, month: 8, day: 10, hour: 12),
            inputMetric: .available(30),
            cachedMetric: .available(6),
            outputMetric: .available(3),
            points: [
                DailyUsagePoint(
                    date: oldestDay,
                    inputTokens: 10,
                    cachedInputTokens: 2,
                    outputTokens: 1
                ),
                DailyUsagePoint(
                    date: overlappingDay,
                    inputTokens: 20,
                    cachedInputTokens: 4,
                    outputTokens: 2
                )
            ]
        )
        let newerSnapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: now,
            inputMetric: .available(55),
            cachedMetric: .available(11),
            outputMetric: .available(7),
            points: [
                DailyUsagePoint(
                    date: overlappingDay,
                    inputTokens: 25,
                    cachedInputTokens: 5,
                    outputTokens: 3
                ),
                DailyUsagePoint(
                    date: currentDay,
                    inputTokens: 30,
                    cachedInputTokens: 6,
                    outputTokens: 4
                )
            ]
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [account],
            snapshots: [newerSnapshot, olderSnapshot],
            now: now,
            dayCount: nil
        )

        XCTAssertEqual(result.interval.start, oldestDay)
        XCTAssertEqual(result.dailyPoints.map(\.date), [oldestDay, overlappingDay, currentDay])
        XCTAssertEqual(result.dailyPoints.map(\.inputTokens), [10, 25, 30])
        XCTAssertEqual(result.totalTokens, 73)
        XCTAssertEqual(result.uncachedInputTokens, 52)
        XCTAssertEqual(result.cachedInputTokens, 13)
        XCTAssertEqual(result.outputTokens, 8)
        XCTAssertEqual(result.accountsReportingDailyUsage, 1)
        XCTAssertEqual(result.accountsReportingTokenSplit, 1)
    }

    func testFixedRangesUseLatestSnapshotWithoutDoubleCountingRetainedOverlap() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let account = try makeAccount(kind: .openAIAPI)
        let overlappingDay = utcDate(year: 2026, month: 9, day: 1)
        let olderSnapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: utcDate(year: 2026, month: 9, day: 1, hour: 12),
            inputMetric: .available(100),
            cachedMetric: .available(0),
            outputMetric: .available(0),
            points: [DailyUsagePoint(date: overlappingDay, inputTokens: 100)]
        )
        let latestSnapshot = makeSnapshot(
            accountID: account.id,
            capturedAt: now,
            inputMetric: .available(10),
            cachedMetric: .available(0),
            outputMetric: .available(0),
            points: [
                DailyUsagePoint(date: overlappingDay, inputTokens: 7),
                DailyUsagePoint(date: utcDate(year: 2026, month: 9, day: 2), inputTokens: 3)
            ]
        )

        for dayCount in [7, 30] {
            let result = UsageAnalytics.tokenBreakdown(
                accounts: [account],
                snapshots: [olderSnapshot, latestSnapshot],
                now: now,
                dayCount: dayCount
            )

            XCTAssertEqual(result.totalTokens, 10)
            XCTAssertEqual(result.dailyPoints.map(\.inputTokens), [7, 3])
        }
    }

    func testCostProviderQualificationExcludesAwaitingAnthropicAccount() throws {
        let now = utcDate(year: 2026, month: 9, day: 2, hour: 12)
        let openAIAccount = try makeAccount(name: "OpenAI API", kind: .openAIAPI)
        let anthropicAccount = try makeAccount(name: "Anthropic API", kind: .anthropicAPI)
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Unavailable"
        )
        let openAISnapshot = UsageSnapshot(
            accountID: openAIAccount.id,
            capturedAt: now,
            source: .openAIAdminAPI,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .unavailable(unavailable),
            resetAt: .unavailable(unavailable),
            totalTokens: .available(10),
            inputTokens: .available(8),
            cachedInputTokens: .available(0),
            outputTokens: .available(2),
            requests: .available(1),
            costUSD: .available(0.25),
            modelUsage: .available([]),
            dailyUsage: .available([
                DailyUsagePoint(
                    date: now,
                    inputTokens: 8,
                    outputTokens: 2,
                    requests: 1,
                    costUSD: 0.25
                )
            ])
        )
        let anthropicSnapshot = UsageSnapshot.awaitingRefresh(
            accountID: anthropicAccount.id,
            source: .anthropicAdminAPI,
            at: now
        )

        let result = UsageAnalytics.tokenBreakdown(
            accounts: [openAIAccount, anthropicAccount],
            snapshots: [openAISnapshot, anthropicSnapshot],
            now: now,
            dayCount: 7
        )

        XCTAssertEqual(result.accountsReportingCost, 1)
        XCTAssertEqual(result.costContributingProviders, [.openAI])
        XCTAssertFalse(result.costContributingProviders.contains(.anthropic))
    }

    func testCumulativeUsagePreservesUnavailableRequestCounts() {
        let firstDay = utcDate(year: 2026, month: 9, day: 1)
        let secondDay = utcDate(year: 2026, month: 9, day: 2)

        let result = UsageAnalytics.cumulativeUsage([
            DailyUsagePoint(date: firstDay, inputTokens: 2, requests: nil),
            DailyUsagePoint(date: secondDay, inputTokens: 3, requests: 1)
        ])

        XCTAssertEqual(result.map(\.inputTokens), [2, 5])
        XCTAssertEqual(result.map(\.requests), [nil, nil])
    }

    func testCumulativeUsageSortsAndAccumulatesEveryMetric() {
        let firstDay = utcDate(year: 2026, month: 9, day: 1)
        let secondDay = utcDate(year: 2026, month: 9, day: 2)
        let result = UsageAnalytics.cumulativeUsage([
            DailyUsagePoint(
                date: secondDay,
                inputTokens: 5,
                cachedInputTokens: 1,
                outputTokens: 7,
                unattributedTokens: 6,
                requests: 2,
                costUSD: 1.25
            ),
            DailyUsagePoint(
                date: firstDay,
                inputTokens: 10,
                cachedInputTokens: 2,
                outputTokens: 3,
                unattributedTokens: 4,
                requests: 1,
                costUSD: 0.5
            )
        ])

        XCTAssertEqual(result.map(\.date), [firstDay, secondDay])
        XCTAssertEqual(result.map(\.inputTokens), [10, 15])
        XCTAssertEqual(result.map(\.cachedInputTokens), [2, 3])
        XCTAssertEqual(result.map(\.outputTokens), [3, 10])
        XCTAssertEqual(result.map(\.unattributedTokens), [4, 10])
        XCTAssertEqual(result.map(\.requests), [1, 3] as [Int?])
        XCTAssertEqual(result.map(\.costUSD), [0.5, 1.75])
        XCTAssertEqual(result.map(\.totalTokens), [17, 35])
    }

    func testCumulativeUsageRejectsOverflow() {
        let firstDay = utcDate(year: 2026, month: 9, day: 1)
        let secondDay = utcDate(year: 2026, month: 9, day: 2)

        let result = UsageAnalytics.cumulativeUsage([
            DailyUsagePoint(date: firstDay, inputTokens: Int.max),
            DailyUsagePoint(date: secondDay, inputTokens: 1)
        ])

        XCTAssertTrue(result.isEmpty)
    }

    func testCumulativeUsageRejectsNonfiniteCost() {
        let result = UsageAnalytics.cumulativeUsage([
            DailyUsagePoint(
                date: utcDate(year: 2026, month: 9, day: 1),
                inputTokens: 1,
                costUSD: .infinity
            )
        ])

        XCTAssertTrue(result.isEmpty)
    }

    private func makeSnapshot(
        accountID: UUID,
        capturedAt: Date,
        inputMetric: Metric<Int>,
        cachedMetric: Metric<Int>,
        outputMetric: Metric<Int>,
        points: [DailyUsagePoint],
        source: UsageSource = .openAIAdminAPI
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            capturedAt: capturedAt,
            source: source,
            reportingPeriod: nil,
            allowance: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            quotaWindows: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            resetAt: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            totalTokens: .unavailable(UnavailableMetric(reason: .notReturned, detail: "Unavailable")),
            inputTokens: inputMetric,
            cachedInputTokens: cachedMetric,
            outputTokens: outputMetric,
            requests: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            costUSD: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            modelUsage: .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable")),
            dailyUsage: .available(points)
        )
    }

    private func unavailableMetric() -> Metric<Int> {
        .unavailable(UnavailableMetric(reason: .notExposedByProvider, detail: "Unavailable"))
    }

    private func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
