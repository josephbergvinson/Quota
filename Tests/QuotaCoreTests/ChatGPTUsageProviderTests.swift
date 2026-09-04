import Foundation
import XCTest
@testable import QuotaCore

final class ChatGPTUsageProviderTests: XCTestCase {
    func testReportedPlanResolvesPlusAndProWithoutGuessingOtherTiers() {
        let provider = makeProvider()

        XCTAssertEqual(provider.resolvedAccountKind(from: "chatgpt_plus"), .chatGPTPlus)
        XCTAssertEqual(provider.resolvedAccountKind(from: "Pro"), .chatGPTPro)
        XCTAssertNil(provider.resolvedAccountKind(from: "business"))
    }

    func testProviderRejectsReportedUnsupportedSubscriptionTier() async throws {
        let now = Date(timeIntervalSince1970: 1_788_264_000)
        let telemetry = ChatGPTTelemetryDTO(
            capturedAt: now,
            account: ChatGPTAccountReadDTO(
                account: .chatGPT(email: "person@example.com", planType: "business"),
                requiresOpenAIAuth: true
            ),
            rateLimits: ChatGPTRateLimitsDTO(
                rateLimits: makeSnapshot(),
                rateLimitsByLimitID: nil,
                resetCredits: nil
            ),
            tokenUsage: ChatGPTTokenUsageDTO(
                summary: ChatGPTTokenUsageSummaryDTO(
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    longestRunningTurnSeconds: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsage: nil,
                threadUsage: nil
            )
        )
        let connector = StubChatGPTConnector(telemetry: telemetry)
        let provider = ChatGPTUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/chatgpt-accounts"),
            connectorFactory: { _ in connector }
        )

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .chatGPTPro),
                credential: nil,
                now: now
            )
            XCTFail("Expected unsupported ChatGPT subscription tier to be rejected")
        } catch {
            XCTAssertEqual(error as? ChatGPTConnectorError, .unsupportedSubscriptionPlan)
        }
    }

    func testProviderEmitsCanonicalChatGPTEmailIdentity() async throws {
        let result = try await fetchResult(email: " Person@Example.COM ")

        XCTAssertEqual(result.providerAccountLabel, "Person@Example.COM")
        XCTAssertEqual(result.providerIdentityKey, "email:person@example.com")
    }

    func testProviderLeavesChatGPTIdentityUnverifiedWhenEmailIsMissing() async throws {
        let result = try await fetchResult(email: nil)

        XCTAssertNil(result.providerAccountLabel)
        XCTAssertNil(result.providerIdentityKey)
    }

    func testProviderReportedTierControlsWindowsDuringTheSameRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: makeWindow(
                        usedPercent: 100,
                        durationMinutes: 300,
                        resetsAt: now.addingTimeInterval(2 * 60 * 60)
                    ),
                    secondary: makeWindow(
                        usedPercent: 40,
                        durationMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
                    )
                )
            ],
            resetCredits: nil
        )

        let reportedPlus = try await fetchResult(
            email: "plus@example.com",
            reportedPlan: "plus",
            localKind: .chatGPTPro,
            rateLimits: limits
        )
        let reportedPro = try await fetchResult(
            email: "pro@example.com",
            reportedPlan: "pro",
            localKind: .chatGPTPlus,
            rateLimits: limits
        )

        XCTAssertEqual(reportedPlus.resolvedAccountKind, .chatGPTPlus)
        XCTAssertEqual(
            reportedPlus.snapshot.quotaWindows.value?.map(\.name),
            ["Codex · 5-hour", "Codex · 1-week"]
        )
        XCTAssertEqual(reportedPro.resolvedAccountKind, .chatGPTPro)
        XCTAssertEqual(
            reportedPro.snapshot.quotaWindows.value?.map(\.name),
            ["Codex · 1-week"]
        )
    }

    func testBankedResetCreditsUseAuthoritativeCountAndPreserveExpiryDetails() throws {
        let grantedAt = Date(timeIntervalSince1970: 1_788_004_800)
        let firstExpiry = Date(timeIntervalSince1970: 1_788_872_400)
        let resetCredits = ChatGPTRateLimitResetCreditsDTO(
            availableCount: 3,
            credits: [
                ChatGPTRateLimitResetCreditDTO(
                    id: "reset_1",
                    resetType: "codexRateLimits",
                    status: "available",
                    grantedAt: grantedAt,
                    expiresAt: firstExpiry,
                    title: "Full reset",
                    detail: "Resets eligible Codex windows."
                ),
                ChatGPTRateLimitResetCreditDTO(
                    id: "reset_2",
                    resetType: "codexRateLimits",
                    status: "available",
                    grantedAt: grantedAt,
                    expiresAt: nil,
                    title: nil,
                    detail: nil
                )
            ]
        )

        let metric = try makeProvider().makeBankedResetCredits(from: resetCredits)
        let credits = try XCTUnwrap(metric.value)

        XCTAssertEqual(credits.availableCount, 3)
        XCTAssertEqual(credits.credits?.map(\.status), [.available, .available])
        XCTAssertEqual(credits.credits?.first?.expiresAt, firstExpiry)
        XCTAssertNil(credits.credits?.last?.expiresAt)
    }

    func testBankedResetCreditsDistinguishCountOnlyZeroAndUnavailable() throws {
        let provider = makeProvider()

        let countOnly = try XCTUnwrap(
            provider.makeBankedResetCredits(
                from: ChatGPTRateLimitResetCreditsDTO(availableCount: 2, credits: nil)
            ).value
        )
        XCTAssertEqual(countOnly.availableCount, 2)
        XCTAssertNil(countOnly.credits)

        let zero = try XCTUnwrap(
            provider.makeBankedResetCredits(
                from: ChatGPTRateLimitResetCreditsDTO(availableCount: 0, credits: [])
            ).value
        )
        XCTAssertEqual(zero.availableCount, 0)
        XCTAssertEqual(zero.credits, [])

        let unavailable = try provider.makeBankedResetCredits(from: nil)
        XCTAssertNil(unavailable.value)
        XCTAssertEqual(unavailable.unavailability?.reason, .notReturned)
    }

    func testUnknownBankedResetStatusRemainsExplicit() throws {
        let resetCredits = ChatGPTRateLimitResetCreditsDTO(
            availableCount: 1,
            credits: [
                ChatGPTRateLimitResetCreditDTO(
                    id: "reset_1",
                    resetType: "codexRateLimits",
                    status: "future-provider-state",
                    grantedAt: Date(timeIntervalSince1970: 1_788_004_800),
                    expiresAt: Date(timeIntervalSince1970: 1_788_872_400),
                    title: nil,
                    detail: nil
                )
            ]
        )

        let credits = try XCTUnwrap(
            makeProvider().makeBankedResetCredits(from: resetCredits).value
        )

        XCTAssertEqual(credits.credits?.first?.status, .unknown)
    }

    func testQuotaWindowsKeepOnlyTheRegularCodexWeeklyBucket() throws {
        let reset = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: ChatGPTRateLimitWindowDTO(
                        usedPercent: 72,
                        windowDurationMinutes: 10_080,
                        resetsAt: reset
                    ),
                    secondary: ChatGPTRateLimitWindowDTO(
                        usedPercent: 12,
                        windowDurationMinutes: 300,
                        resetsAt: reset.addingTimeInterval(300 * 60)
                    )
                )
            ],
            resetCredits: nil
        )

        let provider = ChatGPTUsageProvider(accountsDirectoryURL: URL(fileURLWithPath: "/tmp"))
        let windows = try provider.makeQuotaWindows(
            from: limits,
            capturedAt: reset.addingTimeInterval(-1_800),
            accountKind: .chatGPTPro
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].identifier, "codex:primary")
        XCTAssertEqual(windows[0].name, "Codex · 1-week")
        XCTAssertEqual(windows[0].usedPercent, 72)
        XCTAssertEqual(windows[0].remainingPercent, 28)
        XCTAssertEqual(windows[0].resetsAt, reset)
    }

    func testChatGPTPlusKeepsRegularFiveHourAndWeeklyBuckets() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let fiveHourReset = capturedAt.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = capturedAt.addingTimeInterval(5 * 24 * 60 * 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: makeWindow(
                        usedPercent: 100,
                        durationMinutes: 300,
                        resetsAt: fiveHourReset
                    ),
                    secondary: makeWindow(
                        usedPercent: 45,
                        durationMinutes: 10_080,
                        resetsAt: weeklyReset
                    )
                )
            ],
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPlus
        )

        XCTAssertEqual(windows.map(\.identifier), ["codex:primary", "codex:secondary"])
        XCTAssertEqual(windows.map(\.name), ["Codex · 5-hour", "Codex · 1-week"])
        XCTAssertEqual(windows.map(\.usedPercent), [100, 45])
        XCTAssertEqual(windows.map(\.resetsAt), [fiveHourReset, weeklyReset])

        let unresolvedWindows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTSubscription
        )
        XCTAssertEqual(unresolvedWindows.map(\.name), ["Codex · 1-week"])
    }

    func testOutOfRangeProviderPercentageIsRejected() {
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                limitID: "codex",
                limitName: "Codex",
                primary: ChatGPTRateLimitWindowDTO(
                    usedPercent: 137,
                    windowDurationMinutes: 10_080,
                    resetsAt: nil
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )
        let provider = ChatGPTUsageProvider(accountsDirectoryURL: URL(fileURLWithPath: "/tmp"))

        XCTAssertThrowsError(
            try provider.makeQuotaWindows(
                from: limits,
                capturedAt: Date(),
                accountKind: .chatGPTPro
            )
        ) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testSlidingUnusedWindowIsExcluded() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                limitID: "codex",
                limitName: "Codex",
                primary: makeWindow(
                    usedPercent: 0,
                    durationMinutes: 10_080,
                    resetsAt: capturedAt.addingTimeInterval(10_080 * 60 + 2)
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPro
        )

        XCTAssertTrue(windows.isEmpty)
    }

    func testStableUnusedWindowIsRetained() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let reset = capturedAt.addingTimeInterval(10_080 * 60 - 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                limitID: "codex",
                limitName: "Codex",
                primary: makeWindow(
                    usedPercent: 0,
                    durationMinutes: 10_080,
                    resetsAt: reset
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPro
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.resetsAt, reset)
    }

    func testUsedWindowIsRetainedEvenWhenResetMatchesFullDuration() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let reset = capturedAt.addingTimeInterval(10_080 * 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                limitID: "codex",
                limitName: "Codex",
                primary: makeWindow(
                    usedPercent: 1,
                    durationMinutes: 10_080,
                    resetsAt: reset
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPro
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.usedPercent, 1)
        XCTAssertEqual(windows.first?.resetsAt, reset)
    }

    func testActualResetWinsAfterSlidingPlaceholderIsExcluded() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let actualReset = capturedAt.addingTimeInterval(2 * 24 * 60 * 60)
        let placeholderReset = capturedAt.addingTimeInterval(300 * 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex": makeSnapshot(
                    limitID: "codex",
                    primary: makeWindow(
                        usedPercent: 84,
                        durationMinutes: 10_080,
                        resetsAt: actualReset
                    )
                ),
                "unused": makeSnapshot(
                    limitID: "unused",
                    primary: makeWindow(
                        usedPercent: 0,
                        durationMinutes: 300,
                        resetsAt: placeholderReset
                    )
                )
            ],
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPro
        )

        XCTAssertEqual(windows.map(\.identifier), ["codex:primary"])
        XCTAssertEqual(windows.compactMap(\.resetsAt).min(), actualReset)
    }

    func testCodexSparkBucketsAreExcludedWhileRegularCodexBucketIsRetained() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex_bengalfox": makeSnapshot(
                    limitID: "codex_bengalfox",
                    limitName: "GPT-5.3-Codex-Spark",
                    primary: makeWindow(
                        usedPercent: 0,
                        durationMinutes: 300,
                        // This is just outside the generic placeholder tolerance. The
                        // model/identifier policy must still exclude it.
                        resetsAt: capturedAt.addingTimeInterval(18_007)
                    ),
                    secondary: makeWindow(
                        usedPercent: 25,
                        durationMinutes: 10_080,
                        resetsAt: capturedAt.addingTimeInterval(6 * 24 * 60 * 60)
                    )
                ),
                // The map key is the provider's authoritative metered ID. Keep
                // excluding Spark if nested metadata ever disagrees with it.
                "codex_bengalfox_mismatch": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: makeWindow(
                        usedPercent: 10,
                        durationMinutes: 10_080,
                        resetsAt: capturedAt.addingTimeInterval(3 * 24 * 60 * 60)
                    )
                ),
                "codex": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: makeWindow(
                        usedPercent: 12,
                        durationMinutes: 300,
                        resetsAt: capturedAt.addingTimeInterval(5 * 60 * 60)
                    ),
                    secondary: makeWindow(
                        usedPercent: 80,
                        durationMinutes: 10_080,
                        resetsAt: capturedAt.addingTimeInterval(2 * 24 * 60 * 60)
                    )
                )
            ],
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt,
            accountKind: .chatGPTPro
        )

        XCTAssertEqual(windows.map(\.identifier), ["codex:secondary"])
        XCTAssertEqual(windows.first?.remainingPercent, 20)
    }

    private func fetchResult(
        email: String?,
        reportedPlan: String = "pro",
        localKind: AccountKind = .chatGPTPro,
        rateLimits: ChatGPTRateLimitsDTO? = nil
    ) async throws -> ProviderFetchResult {
        let now = Date(timeIntervalSince1970: 1_788_264_000)
        let telemetry = ChatGPTTelemetryDTO(
            capturedAt: now,
            account: ChatGPTAccountReadDTO(
                account: .chatGPT(email: email, planType: reportedPlan),
                requiresOpenAIAuth: true
            ),
            rateLimits: rateLimits ?? ChatGPTRateLimitsDTO(
                rateLimits: makeSnapshot(
                    primary: makeWindow(
                        usedPercent: 20,
                        durationMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(24 * 60 * 60)
                    )
                ),
                rateLimitsByLimitID: nil,
                resetCredits: nil
            ),
            tokenUsage: ChatGPTTokenUsageDTO(
                summary: ChatGPTTokenUsageSummaryDTO(
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    longestRunningTurnSeconds: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsage: nil,
                threadUsage: nil
            )
        )
        let connector = StubChatGPTConnector(telemetry: telemetry)
        let provider = ChatGPTUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/chatgpt-accounts"),
            connectorFactory: { _ in connector }
        )

        return try await provider.fetchUsage(
            for: makeAccount(kind: localKind),
            credential: nil,
            now: now
        )
    }

    private func makeSnapshot(
        limitID: String? = nil,
        limitName: String? = nil,
        primary: ChatGPTRateLimitWindowDTO? = nil,
        secondary: ChatGPTRateLimitWindowDTO? = nil
    ) -> ChatGPTRateLimitSnapshotDTO {
        ChatGPTRateLimitSnapshotDTO(
            limitID: limitID,
            limitName: limitName,
            planType: "pro",
            primary: primary,
            secondary: secondary,
            credits: nil,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil
        )
    }

    private func makeWindow(
        usedPercent: Int,
        durationMinutes: Int64,
        resetsAt: Date
    ) -> ChatGPTRateLimitWindowDTO {
        ChatGPTRateLimitWindowDTO(
            usedPercent: usedPercent,
            windowDurationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }

    private func makeProvider() -> ChatGPTUsageProvider {
        ChatGPTUsageProvider(accountsDirectoryURL: URL(fileURLWithPath: "/tmp"))
    }
}

private struct StubChatGPTConnector: ChatGPTAppServerConnecting {
    let telemetry: ChatGPTTelemetryDTO

    func readAccount(refreshToken: Bool) async throws -> ChatGPTAccountReadDTO {
        telemetry.account
    }

    func readRateLimits() async throws -> ChatGPTRateLimitsDTO {
        telemetry.rateLimits
    }

    func readTokenUsage(threadID: String?) async throws -> ChatGPTTokenUsageDTO {
        telemetry.tokenUsage
    }

    func readTelemetry(
        refreshToken: Bool,
        capturedAt: Date
    ) async throws -> ChatGPTTelemetryDTO {
        telemetry
    }

    func startManagedLogin(
        mode: ChatGPTManagedLoginMode
    ) async throws -> ChatGPTManagedLoginSession {
        throw ChatGPTConnectorError.loginFinished
    }

    func logout() async throws {}
}
