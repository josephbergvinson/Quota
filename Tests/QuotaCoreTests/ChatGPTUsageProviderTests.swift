import Foundation
import XCTest
@testable import QuotaCore

final class ChatGPTUsageProviderTests: XCTestCase {
    func testQuotaWindowsPreserveProviderBucketsAndDurations() throws {
        let reset = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(),
            rateLimitsByLimitID: [
                "codex": makeSnapshot(
                    limitID: "codex",
                    limitName: "Codex",
                    primary: ChatGPTRateLimitWindowDTO(
                        usedPercent: 72,
                        windowDurationMinutes: 300,
                        resetsAt: reset
                    )
                )
            ],
            resetCredits: nil
        )

        let provider = ChatGPTUsageProvider(accountsDirectoryURL: URL(fileURLWithPath: "/tmp"))
        let windows = try provider.makeQuotaWindows(
            from: limits,
            capturedAt: reset.addingTimeInterval(-1_800)
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].identifier, "codex:primary")
        XCTAssertEqual(windows[0].name, "Codex · 5-hour")
        XCTAssertEqual(windows[0].usedPercent, 72)
        XCTAssertEqual(windows[0].remainingPercent, 28)
        XCTAssertEqual(windows[0].resetsAt, reset)
    }

    func testOutOfRangeProviderPercentageIsRejected() {
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                primary: ChatGPTRateLimitWindowDTO(
                    usedPercent: 137,
                    windowDurationMinutes: nil,
                    resetsAt: nil
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )
        let provider = ChatGPTUsageProvider(accountsDirectoryURL: URL(fileURLWithPath: "/tmp"))

        XCTAssertThrowsError(
            try provider.makeQuotaWindows(from: limits, capturedAt: Date())
        ) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testSlidingUnusedWindowIsExcluded() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                primary: makeWindow(
                    usedPercent: 0,
                    durationMinutes: 300,
                    resetsAt: capturedAt.addingTimeInterval(300 * 60 + 2)
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt
        )

        XCTAssertTrue(windows.isEmpty)
    }

    func testStableUnusedWindowIsRetained() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let reset = capturedAt.addingTimeInterval(300 * 60 - 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                primary: makeWindow(
                    usedPercent: 0,
                    durationMinutes: 300,
                    resetsAt: reset
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.resetsAt, reset)
    }

    func testUsedWindowIsRetainedEvenWhenResetMatchesFullDuration() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_788_264_000)
        let reset = capturedAt.addingTimeInterval(300 * 60)
        let limits = ChatGPTRateLimitsDTO(
            rateLimits: makeSnapshot(
                primary: makeWindow(
                    usedPercent: 1,
                    durationMinutes: 300,
                    resetsAt: reset
                )
            ),
            rateLimitsByLimitID: nil,
            resetCredits: nil
        )

        let windows = try makeProvider().makeQuotaWindows(
            from: limits,
            capturedAt: capturedAt
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
            capturedAt: capturedAt
        )

        XCTAssertEqual(windows.map(\.identifier), ["codex:primary"])
        XCTAssertEqual(windows.compactMap(\.resetsAt).min(), actualReset)
    }

    private func makeSnapshot(
        limitID: String? = nil,
        limitName: String? = nil,
        primary: ChatGPTRateLimitWindowDTO? = nil
    ) -> ChatGPTRateLimitSnapshotDTO {
        ChatGPTRateLimitSnapshotDTO(
            limitID: limitID,
            limitName: limitName,
            planType: "pro",
            primary: primary,
            secondary: nil,
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
