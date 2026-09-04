import Foundation
import XCTest
@testable import QuotaCore

final class UsageAnalyticsTests: XCTestCase {
    func testRecommendationUsesMostConstrainedActiveWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeAccount(name: "First", kind: .chatGPTPro)
        let second = try makeAccount(name: "Second", kind: .chatGPTPro)

        let firstWindows = [
            try QuotaWindow(
                identifier: "short",
                name: "Short",
                usedPercent: 20,
                resetsAt: now.addingTimeInterval(3_600),
                durationMinutes: 300
            ),
            try QuotaWindow(
                identifier: "weekly",
                name: "Weekly",
                usedPercent: 70,
                resetsAt: now.addingTimeInterval(86_400),
                durationMinutes: 10_080
            )
        ]
        let firstSnapshot = UsageSnapshot.manual(
            accountID: first.id,
            allowance: nil,
            quotaWindows: firstWindows,
            resetAt: nil,
            capturedAt: now
        )
        let secondSnapshot = try makeManualSnapshot(
            accountID: second.id,
            capturedAt: now,
            usedPercent: 40,
            resetAt: now.addingTimeInterval(7_200)
        )

        let summary = UsageAnalytics.dashboard(
            accounts: [first, second],
            latestSnapshots: [first.id: firstSnapshot, second.id: secondSnapshot],
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(summary.capacities[0].remainingFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(summary.capacities[0].limitingWindowName, "Weekly")
        XCTAssertEqual(summary.capacities[0].nextResetAt, now.addingTimeInterval(86_400))
        XCTAssertEqual(summary.recommendedAccount?.account.id, second.id)
        XCTAssertEqual(try XCTUnwrap(summary.averageRemainingFraction), 0.45, accuracy: 0.0001)
    }

    func testCapacityStatusDistinguishesExactBoundariesAndUnknownStates() throws {
        let account = try makeAccount(kind: .chatGPTPro)

        func capacity(remainingFraction: Double?, isStale: Bool = false) -> AccountCapacity {
            AccountCapacity(
                account: account,
                remainingFraction: remainingFraction,
                limitingWindowName: nil,
                nextResetAt: nil,
                capturedAt: nil,
                isStale: isStale
            )
        }

        XCTAssertEqual(capacity(remainingFraction: nil).status, .unavailable)
        XCTAssertEqual(capacity(remainingFraction: nil, isStale: true).status, .unavailable)
        XCTAssertEqual(capacity(remainingFraction: 0).status, .exhausted)
        XCTAssertEqual(capacity(remainingFraction: 0.000_001).status, .low)
        XCTAssertEqual(capacity(remainingFraction: 0.199_999).status, .low)
        XCTAssertEqual(capacity(remainingFraction: 0.2).status, .watch)
        XCTAssertEqual(capacity(remainingFraction: 0.499_999).status, .watch)
        XCTAssertEqual(capacity(remainingFraction: 0.5).status, .healthy)
        XCTAssertEqual(capacity(remainingFraction: 0, isStale: true).status, .stale)
    }

    func testCapacityStatusUsesTheSameThresholdsForProviderPercentages() {
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 0), .exhausted)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 0.001), .low)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 19.999), .low)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 20), .watch)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 49.999), .watch)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 50), .healthy)
        XCTAssertEqual(CapacityStatus.freshStatus(forRemainingPercent: 100), .healthy)
    }

    func testCapacityResetBelongsToTheLimitingWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierReset = now.addingTimeInterval(3_600)
        let limitingReset = now.addingTimeInterval(86_400)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = UsageSnapshot.manual(
            accountID: account.id,
            allowance: nil,
            quotaWindows: [
                try QuotaWindow(
                    identifier: "short",
                    name: "Short",
                    usedPercent: 10,
                    resetsAt: earlierReset,
                    durationMinutes: 300
                ),
                try QuotaWindow(
                    identifier: "weekly",
                    name: "Weekly",
                    usedPercent: 90,
                    resetsAt: limitingReset,
                    durationMinutes: 10_080
                )
            ],
            resetAt: nil,
            capturedAt: now
        )

        let capacity = UsageAnalytics.capacity(for: account, snapshot: snapshot, now: now)

        XCTAssertEqual(capacity.limitingWindowName, "Weekly")
        XCTAssertEqual(capacity.remainingFraction, 0.1)
        XCTAssertEqual(capacity.nextResetAt, limitingReset)
    }

    func testClaudeRecommendationUsesPlanLimitsNotModelSpecificLimitsOrCredits() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = try makeAccount(kind: .claudeMax)
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Unavailable"
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            capturedAt: now,
            source: .claudeCodeOAuth,
            reportingPeriod: nil,
            allowance: .available(try Allowance(used: 99, limit: 100, unit: .dollars)),
            quotaWindows: .available([
                try QuotaWindow(
                    identifier: "five_hour",
                    name: "5-hour limit",
                    usedPercent: 25,
                    resetsAt: now.addingTimeInterval(3_600),
                    durationMinutes: 300
                ),
                try QuotaWindow(
                    identifier: "seven_day",
                    name: "7-day limit · all models",
                    usedPercent: 60,
                    resetsAt: now.addingTimeInterval(86_400),
                    durationMinutes: 10_080
                ),
                try QuotaWindow(
                    identifier: "seven_day_oauth_apps",
                    name: "7-day limit · OAuth apps",
                    usedPercent: 99,
                    resetsAt: now.addingTimeInterval(90_000),
                    durationMinutes: 10_080
                ),
                try QuotaWindow(
                    identifier: "model_scoped:opus",
                    name: "7-day limit · Opus",
                    usedPercent: 95,
                    resetsAt: now.addingTimeInterval(172_800),
                    durationMinutes: 10_080
                )
            ]),
            resetAt: .available(now.addingTimeInterval(3_600)),
            bankedResetCredits: .unavailable(unavailable),
            totalTokens: .unavailable(unavailable),
            inputTokens: .unavailable(unavailable),
            cachedInputTokens: .unavailable(unavailable),
            outputTokens: .unavailable(unavailable),
            requests: .unavailable(unavailable),
            costUSD: .unavailable(unavailable),
            modelUsage: .unavailable(unavailable),
            dailyUsage: .unavailable(unavailable)
        )

        let capacity = UsageAnalytics.capacity(for: account, snapshot: snapshot, now: now)

        XCTAssertEqual(capacity.remainingFraction, 0.4)
        XCTAssertEqual(capacity.limitingWindowName, "7-day limit · all models")
        XCTAssertEqual(capacity.nextResetAt, now.addingTimeInterval(86_400))
    }

    func testForwardResetIntervalIncludesAnchorAndNextSevenCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 15))
        )
        let anchorDay = calendar.startOfDay(for: referenceDate)

        let interval = try XCTUnwrap(
            UsageAnalytics.forwardResetInterval(startingAt: referenceDate, calendar: calendar)
        )
        let includedDays = (0..<8).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }

        XCTAssertEqual(interval.start, anchorDay)
        XCTAssertEqual(interval.end, calendar.date(byAdding: .day, value: 8, to: anchorDay))
        XCTAssertEqual(includedDays.count, 8)
        XCTAssertEqual(includedDays.first, interval.start)
        XCTAssertEqual(includedDays.last, calendar.date(byAdding: .day, value: 7, to: anchorDay))
        XCTAssertEqual(
            calendar.date(byAdding: .day, value: 1, to: try XCTUnwrap(includedDays.last)),
            interval.end
        )
    }

    func testForwardResetIntervalUsesCalendarDaysAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))
        )

        let interval = try XCTUnwrap(
            UsageAnalytics.forwardResetInterval(startingAt: referenceDate, calendar: calendar)
        )
        let startComponents = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: interval.start
        )
        let endComponents = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: interval.end
        )

        XCTAssertEqual(startComponents, DateComponents(year: 2026, month: 3, day: 8, hour: 0))
        XCTAssertEqual(endComponents, DateComponents(year: 2026, month: 3, day: 16, hour: 0))
        XCTAssertEqual(interval.duration, 8 * 24 * 60 * 60 - 60 * 60, accuracy: 0.001)
    }

    func testClaudeFiveHourResetAppearsBeforeAndAtExhaustionWhenResetIsReported() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activeAccount = try makeAccount(name: "Active", kind: .claudeMax)
        let exhaustedAccount = try makeAccount(name: "Exhausted", kind: .claudeMax)
        let missingResetAccount = try makeAccount(name: "Missing reset", kind: .claudeMax)
        let activeReset = now.addingTimeInterval(60 * 60)
        let exhaustedReset = now.addingTimeInterval(2 * 60 * 60)

        let activeSnapshot = try makeClaudeSnapshot(
            accountID: activeAccount.id,
            capturedAt: now,
            fiveHourUsedPercent: 40,
            resetsAt: activeReset
        )
        let exhaustedSnapshot = try makeClaudeSnapshot(
            accountID: exhaustedAccount.id,
            capturedAt: now,
            fiveHourUsedPercent: 100,
            resetsAt: exhaustedReset
        )
        let missingResetSnapshot = try makeClaudeSnapshot(
            accountID: missingResetAccount.id,
            capturedAt: now,
            fiveHourUsedPercent: 70,
            resetsAt: nil
        )
        let interval = DateInterval(
            start: now,
            end: now.addingTimeInterval(24 * 60 * 60)
        )

        let events = UsageAnalytics.resetEvents(
            accounts: [activeAccount, exhaustedAccount, missingResetAccount],
            snapshots: [activeSnapshot, exhaustedSnapshot, missingResetSnapshot],
            in: interval
        )

        XCTAssertEqual(events.map(\.account.id), [activeAccount.id, exhaustedAccount.id])
        XCTAssertEqual(events.map(\.windowName), ["5-hour limit", "5-hour limit"])
        XCTAssertEqual(events.map(\.resetsAt), [activeReset, exhaustedReset])
        XCTAssertEqual(events[0].remainingFraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(events[1].remainingFraction, 0, accuracy: 0.0001)
    }

    func testChatGPTPlusFiveHourResetAppearsAtExhaustionWhileProKeepsWeeklyOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plusAccount = try makeAccount(name: "Plus", kind: .chatGPTPlus)
        let proAccount = try makeAccount(name: "Pro", kind: .chatGPTPro)
        let fiveHourReset = now.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(5 * 24 * 60 * 60)
        let fiveHour = try QuotaWindow(
            identifier: "codex:primary",
            name: "Codex · 5-hour",
            usedPercent: 100,
            resetsAt: fiveHourReset,
            durationMinutes: 300
        )
        let weekly = try QuotaWindow(
            identifier: "codex:secondary",
            name: "Codex · 1-week",
            usedPercent: 45,
            resetsAt: weeklyReset,
            durationMinutes: 10_080
        )
        let plusSnapshot = makeChatGPTSnapshot(
            accountID: plusAccount.id,
            capturedAt: now,
            windows: [fiveHour, weekly],
            resetAt: fiveHourReset
        )
        let proSnapshot = makeChatGPTSnapshot(
            accountID: proAccount.id,
            capturedAt: now,
            windows: [fiveHour, weekly],
            resetAt: fiveHourReset
        )
        let interval = DateInterval(
            start: now,
            end: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let plusCapacity = UsageAnalytics.capacity(
            for: plusAccount,
            snapshot: plusSnapshot,
            now: now
        )
        let events = UsageAnalytics.resetEvents(
            accounts: [plusAccount, proAccount],
            snapshots: [plusSnapshot, proSnapshot],
            in: interval
        )
        let plusEvents = events.filter { $0.account.id == plusAccount.id }
        let proEvents = events.filter { $0.account.id == proAccount.id }

        XCTAssertEqual(plusCapacity.limitingWindowName, "Codex · 5-hour")
        XCTAssertEqual(plusCapacity.remainingFraction, 0)
        XCTAssertEqual(plusCapacity.nextResetAt, fiveHourReset)
        XCTAssertEqual(plusEvents.map(\.windowName), ["Codex · 5-hour", "Codex · 1-week"])
        XCTAssertEqual(plusEvents.map(\.remainingFraction), [0, 0.55])
        XCTAssertEqual(proEvents.map(\.windowName), ["Codex · 1-week"])
        XCTAssertEqual(proEvents.map(\.resetsAt), [weeklyReset])
    }

    func testExpiredWindowIsNotPresentedAsCurrentCapacity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: now.addingTimeInterval(-7_200),
            usedPercent: 20,
            resetAt: now.addingTimeInterval(-3_600)
        )

        let capacity = UsageAnalytics.capacity(for: account, snapshot: snapshot, now: now)

        XCTAssertNil(capacity.remainingFraction)
        XCTAssertEqual(capacity.status, .unavailable)
    }

    func testStaleReadingIsVisibleButExcludedFromRecommendation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: now.addingTimeInterval(-(UsageAnalytics.capacityFreshnessInterval + 1)),
            usedPercent: 20,
            resetAt: nil
        )

        let summary = UsageAnalytics.dashboard(
            accounts: [account],
            latestSnapshots: [account.id: snapshot],
            now: now
        )

        XCTAssertEqual(summary.capacities.first?.remainingFraction, 0.8)
        XCTAssertEqual(summary.capacities.first?.status, .stale)
        XCTAssertNil(summary.recommendedAccount)
        XCTAssertNil(summary.averageRemainingFraction)
        XCTAssertEqual(summary.accountsWithKnownCapacity, 0)
    }

    func testResetEventsAreHalfOpenAndLatestReadingWins() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let interval = DateInterval(start: weekStart, end: weekEnd)
        let reset = calendar.date(byAdding: .day, value: 2, to: weekStart)!
        let account = try makeAccount(kind: .chatGPTPro)

        let older = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart,
            usedPercent: 80,
            resetAt: reset
        )
        let newer = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart.addingTimeInterval(60),
            usedPercent: 50,
            resetAt: reset
        )
        let atExclusiveEnd = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart,
            usedPercent: 10,
            resetAt: weekEnd
        )

        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [older, newer, atExclusiveEnd],
            in: interval
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].remainingFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(events[0].capturedAt, newer.capturedAt)
    }

    func testFutureResetReplacedBeforeItOccursIsNotKeptOnCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let interval = DateInterval(
            start: weekStart,
            end: calendar.date(byAdding: .day, value: 7, to: weekStart)!
        )
        let originalReset = calendar.date(byAdding: .day, value: 2, to: weekStart)!
        let revisedReset = calendar.date(byAdding: .day, value: 3, to: weekStart)!
        let account = try makeAccount(kind: .chatGPTPro)
        let original = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart,
            usedPercent: 70,
            resetAt: originalReset
        )
        let revision = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart.addingTimeInterval(3_600),
            usedPercent: 65,
            resetAt: revisedReset
        )

        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [original, revision],
            in: interval
        )

        XCTAssertEqual(events.map(\.resetsAt), [revisedReset])
    }

    func testElapsedResetRemainsInHistoryAfterNextWindowIsRecorded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let interval = DateInterval(
            start: weekStart,
            end: calendar.date(byAdding: .day, value: 7, to: weekStart)!
        )
        let firstReset = weekStart.addingTimeInterval(3_600)
        let nextReset = calendar.date(byAdding: .day, value: 2, to: weekStart)!
        let account = try makeAccount(kind: .chatGPTPro)
        let first = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart,
            usedPercent: 80,
            resetAt: firstReset
        )
        let next = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: firstReset.addingTimeInterval(60),
            usedPercent: 10,
            resetAt: nextReset
        )

        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [first, next],
            in: interval
        )

        XCTAssertEqual(events.map(\.resetsAt), [firstReset, nextReset])
    }

    func testRemovedFutureWindowIsRemovedFromCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let interval = DateInterval(
            start: weekStart,
            end: calendar.date(byAdding: .day, value: 7, to: weekStart)!
        )
        let reset = calendar.date(byAdding: .day, value: 2, to: weekStart)!
        let account = try makeAccount(kind: .chatGPTPro)
        let original = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: weekStart,
            usedPercent: 70,
            resetAt: reset
        )
        let windowRemoved = UsageSnapshot.manual(
            accountID: account.id,
            allowance: try Allowance(used: 20, limit: 100, unit: .percent),
            quotaWindows: [],
            resetAt: nil,
            capturedAt: weekStart.addingTimeInterval(3_600)
        )

        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [original, windowRemoved],
            in: interval
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testSavedSlidingUnusedChatGPTWindowIsIgnoredImmediately() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let capturedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!
        let account = try makeAccount(kind: .chatGPTPro)
        let placeholder = try QuotaWindow(
            identifier: "codex-placeholder:primary",
            name: "Unused · 5-hour",
            usedPercent: 0,
            resetsAt: capturedAt.addingTimeInterval(5 * 60 * 60),
            durationMinutes: 300
        )
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Unavailable"
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            capturedAt: capturedAt,
            source: .chatGPTAppServer,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .available([placeholder]),
            resetAt: .available(try XCTUnwrap(placeholder.resetsAt)),
            totalTokens: .unavailable(unavailable),
            inputTokens: .unavailable(unavailable),
            cachedInputTokens: .unavailable(unavailable),
            outputTokens: .unavailable(unavailable),
            requests: .unavailable(unavailable),
            costUSD: .unavailable(unavailable),
            modelUsage: .unavailable(unavailable),
            dailyUsage: .unavailable(unavailable)
        )
        let interval = DateInterval(
            start: capturedAt,
            end: capturedAt.addingTimeInterval(24 * 60 * 60)
        )

        let capacity = UsageAnalytics.capacity(
            for: account,
            snapshot: snapshot,
            now: capturedAt.addingTimeInterval(60)
        )
        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [snapshot],
            in: interval
        )

        XCTAssertNil(capacity.remainingFraction)
        XCTAssertEqual(capacity.status, .unavailable)
        XCTAssertTrue(events.isEmpty)
    }

    func testSavedCodexSparkWindowsAreExcludedFromCapacityAndCalendar() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = try makeAccount(kind: .chatGPTPro)
        let sparkFiveHour = try QuotaWindow(
            identifier: "codex_bengalfox:primary",
            name: "GPT-5.3-Codex-Spark · 5-hour",
            usedPercent: 0,
            resetsAt: now.addingTimeInterval(3_600),
            durationMinutes: 300
        )
        let sparkWeekly = try QuotaWindow(
            identifier: "codex_bengalfox:secondary",
            name: "GPT-5.3-Codex-Spark · 1-week",
            usedPercent: 0,
            resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            durationMinutes: 10_080
        )
        let regular = try QuotaWindow(
            identifier: "codex:primary",
            name: "codex · 1-week",
            usedPercent: 0,
            resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            durationMinutes: 10_080
        )
        let regularShort = try QuotaWindow(
            identifier: "codex:secondary",
            name: "codex · 5-hour",
            usedPercent: 10,
            resetsAt: now.addingTimeInterval(3_600),
            durationMinutes: 300
        )
        let unrelatedWeekly = try QuotaWindow(
            identifier: "codex_other:primary",
            name: "Other · 1-week",
            usedPercent: 5,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            durationMinutes: 10_080
        )
        let snapshot = makeChatGPTSnapshot(
            accountID: account.id,
            capturedAt: now,
            windows: [sparkFiveHour, sparkWeekly, regularShort, unrelatedWeekly, regular],
            resetAt: sparkFiveHour.resetsAt
        )
        let interval = DateInterval(
            start: now,
            end: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let capacity = UsageAnalytics.capacity(for: account, snapshot: snapshot, now: now)
        let events = UsageAnalytics.resetEvents(
            accounts: [account],
            snapshots: [snapshot],
            in: interval
        )

        XCTAssertEqual(
            UsageAnalytics.supportedQuotaWindows(
                for: snapshot,
                accountKind: account.kind
            ).map(\.identifier),
            ["codex:primary"]
        )
        XCTAssertEqual(capacity.limitingWindowName, "codex · 1-week")
        XCTAssertEqual(capacity.remainingFraction, 1.0)
        XCTAssertEqual(events.map(\.windowName), ["codex · 1-week"])
        XCTAssertEqual(events.map(\.resetsAt), [regular.resetsAt])

        let sparkOnlySnapshot = makeChatGPTSnapshot(
            accountID: account.id,
            capturedAt: now,
            windows: [sparkFiveHour],
            resetAt: sparkFiveHour.resetsAt
        )
        let sparkOnlyCapacity = UsageAnalytics.capacity(
            for: account,
            snapshot: sparkOnlySnapshot,
            now: now
        )
        XCTAssertNil(sparkOnlyCapacity.remainingFraction)

        let manualSnapshot = UsageSnapshot.manual(
            accountID: account.id,
            allowance: nil,
            quotaWindows: [sparkFiveHour],
            resetAt: nil,
            capturedAt: now
        )
        XCTAssertEqual(
            UsageAnalytics.supportedQuotaWindows(
                for: manualSnapshot,
                accountKind: account.kind
            ).count,
            1
        )
    }

    private func makeChatGPTSnapshot(
        accountID: UUID,
        capturedAt: Date,
        windows: [QuotaWindow],
        resetAt: Date?
    ) -> UsageSnapshot {
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Unavailable"
        )
        return UsageSnapshot(
            accountID: accountID,
            capturedAt: capturedAt,
            source: .chatGPTAppServer,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .available(windows),
            resetAt: resetAt.map(Metric.available) ?? .unavailable(unavailable),
            totalTokens: .unavailable(unavailable),
            inputTokens: .unavailable(unavailable),
            cachedInputTokens: .unavailable(unavailable),
            outputTokens: .unavailable(unavailable),
            requests: .unavailable(unavailable),
            costUSD: .unavailable(unavailable),
            modelUsage: .unavailable(unavailable),
            dailyUsage: .unavailable(unavailable)
        )
    }

    private func makeClaudeSnapshot(
        accountID: UUID,
        capturedAt: Date,
        fiveHourUsedPercent: Double,
        resetsAt: Date?
    ) throws -> UsageSnapshot {
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Unavailable"
        )
        return UsageSnapshot(
            accountID: accountID,
            capturedAt: capturedAt,
            source: .claudeCodeOAuth,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .available([
                try QuotaWindow(
                    identifier: "five_hour",
                    name: "5-hour limit",
                    usedPercent: fiveHourUsedPercent,
                    resetsAt: resetsAt,
                    durationMinutes: 300
                )
            ]),
            resetAt: resetsAt.map(Metric.available) ?? .unavailable(unavailable),
            bankedResetCredits: .unavailable(unavailable),
            totalTokens: .unavailable(unavailable),
            inputTokens: .unavailable(unavailable),
            cachedInputTokens: .unavailable(unavailable),
            outputTokens: .unavailable(unavailable),
            requests: .unavailable(unavailable),
            costUSD: .unavailable(unavailable),
            modelUsage: .unavailable(unavailable),
            dailyUsage: .unavailable(unavailable)
        )
    }
}
