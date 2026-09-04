import Foundation
import XCTest
@testable import QuotaCore

final class PersistenceTests: XCTestCase {
    func testLocalDataRoundTripKeepsAccountsAndHistory() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = try makeManualSnapshot(
            accountID: account.id,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            usedPercent: 25,
            resetAt: Date(timeIntervalSince1970: 1_800_003_600)
        )
        let expected = PersistentState(accounts: [account], snapshots: [snapshot])

        try await store.save(expected)
        let actual = try await store.load()

        XCTAssertEqual(actual, expected)
        let fileURL = temporaryDirectory.appendingPathComponent(LocalDataStore.stateFileName)
        let fileText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(fileText.contains("api-key"))
    }

    func testLocalDataRoundTripKeepsBankedResetCredits() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .chatGPTPro)
        let unavailable = UnavailableMetric(
            reason: .notReturned,
            detail: "Fixture metric is unavailable."
        )
        let expiry = Date(timeIntervalSince1970: 1_788_872_400)
        let bankedResets = try BankedResetCredits(
            availableCount: 2,
            credits: [
                try BankedResetCredit(status: .available, expiresAt: expiry)
            ]
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            capturedAt: Date(timeIntervalSince1970: 1_788_264_000),
            source: .chatGPTAppServer,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .unavailable(unavailable),
            resetAt: .unavailable(unavailable),
            bankedResetCredits: .available(bankedResets),
            totalTokens: .unavailable(unavailable),
            inputTokens: .unavailable(unavailable),
            cachedInputTokens: .unavailable(unavailable),
            outputTokens: .unavailable(unavailable),
            requests: .unavailable(unavailable),
            costUSD: .unavailable(unavailable),
            modelUsage: .unavailable(unavailable),
            dailyUsage: .unavailable(unavailable)
        )
        let expected = PersistentState(accounts: [account], snapshots: [snapshot])

        try await store.save(expected)
        let actual = try await store.load()

        XCTAssertEqual(actual, expected)
    }

    func testLocalDataRoundTripPreservesUnavailableNestedRequestCounts() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .anthropicAPI)
        let unavailable = UnavailableMetric(
            reason: .notExposedByProvider,
            detail: "Anthropic does not report request counts."
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .anthropicAdminAPI,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .unavailable(unavailable),
            resetAt: .unavailable(unavailable),
            totalTokens: .available(12),
            inputTokens: .available(10),
            cachedInputTokens: .available(2),
            outputTokens: .available(2),
            requests: .unavailable(unavailable),
            costUSD: .available(0.1),
            modelUsage: .available([
                ModelUsage(
                    model: "claude-sonnet-5",
                    inputTokens: 10,
                    cachedInputTokens: 2,
                    outputTokens: 2,
                    requests: nil
                )
            ]),
            dailyUsage: .available([
                DailyUsagePoint(
                    date: Date(timeIntervalSince1970: 1_799_971_200),
                    inputTokens: 10,
                    cachedInputTokens: 2,
                    outputTokens: 2,
                    requests: nil,
                    costUSD: 0.1
                )
            ])
        )

        try await store.save(PersistentState(accounts: [account], snapshots: [snapshot]))
        let loaded = try await store.load()

        XCTAssertNil(loaded.snapshots.first?.modelUsage.value?.first?.requests)
        XCTAssertNil(loaded.snapshots.first?.dailyUsage.value?.first?.requests)
    }

    func testLegacySnapshotWithoutBankedResetFieldLoadsAsUnavailable() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .chatGPTPro)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_788_264_000)
        )
        try await store.save(PersistentState(accounts: [account], snapshots: [snapshot]))

        let fileURL = temporaryDirectory.appendingPathComponent(LocalDataStore.stateFileName)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        var snapshots = try XCTUnwrap(root["snapshots"] as? [[String: Any]])
        snapshots[0].removeValue(forKey: "bankedResetCredits")
        root["snapshots"] = snapshots
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: fileURL, options: .atomic)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.snapshots.count, 1)
        XCTAssertEqual(
            loaded.snapshots[0].bankedResetCredits.unavailability?.reason,
            .notReturned
        )
    }

    func testBankedResetCreditsRejectInvalidValues() {
        XCTAssertThrowsError(try BankedResetCredits(availableCount: -1, credits: nil))
        XCTAssertThrowsError(
            try BankedResetCredit(
                status: .available,
                expiresAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )
    }

    func testLocalDataRejectsOrphanedHistory() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let snapshot = try makeManualSnapshot(
            accountID: UUID(),
            capturedAt: Date(),
            usedPercent: 50,
            resetAt: nil
        )

        do {
            try await store.save(PersistentState(accounts: [], snapshots: [snapshot]))
            XCTFail("Expected orphaned history to be rejected")
        } catch let error as LocalDataStoreError {
            XCTAssertEqual(error, .orphanedSnapshot)
        }
    }

    func testLocalDataRejectsHistoryFromAnotherProviderConnection() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .openAIAPI)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .anthropicAdminAPI,
            at: Date()
        )

        do {
            try await store.save(PersistentState(accounts: [account], snapshots: [snapshot]))
            XCTFail("Expected cross-provider history to be rejected")
        } catch let error as LocalDataStoreError {
            XCTAssertEqual(error, .invalidSnapshot)
        }
    }

    func testAllowanceRejectsInvalidBoundaryValues() {
        XCTAssertThrowsError(try Allowance(used: -1, limit: 100, unit: .percent))
        XCTAssertThrowsError(try Allowance(used: 1, limit: 0, unit: .percent))
        XCTAssertNoThrow(try Allowance(used: 120, limit: 100, unit: .percent))
    }

    func testLocalDataRejectsNegativeDecodedStyleMetrics() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let account = try makeAccount(kind: .openAIAPI)
        let unavailable = UnavailableMetric(
            reason: .notReturned,
            detail: "Fixture metric is unavailable."
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            capturedAt: Date(),
            source: .openAIAdminAPI,
            reportingPeriod: nil,
            allowance: .unavailable(unavailable),
            quotaWindows: .unavailable(unavailable),
            resetAt: .unavailable(unavailable),
            totalTokens: .available(-1),
            inputTokens: .available(-1),
            cachedInputTokens: .available(0),
            outputTokens: .available(0),
            requests: .available(0),
            costUSD: .available(0),
            modelUsage: .available([]),
            dailyUsage: .available([])
        )

        do {
            try await store.save(PersistentState(accounts: [account], snapshots: [snapshot]))
            XCTFail("Expected invalid metrics to be rejected")
        } catch let error as LocalDataStoreError {
            XCTAssertEqual(error, .invalidSnapshot)
        }
    }

    func testSchemaOneMigrationPreservesProvidersAndKeepsSubscriptionPlansAmbiguous() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let openAIAccount = try makeAccount(kind: .openAIAPI)
        let openAISnapshot = UsageSnapshot.awaitingRefresh(
            accountID: openAIAccount.id,
            source: .openAIAdminAPI,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.save(
            PersistentState(accounts: [openAIAccount], snapshots: [openAISnapshot])
        )

        let fileURL = temporaryDirectory.appendingPathComponent(LocalDataStore.stateFileName)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        let savedAccounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        let savedSnapshots = try XCTUnwrap(root["snapshots"] as? [[String: Any]])
        let legacyChatGPTID = UUID().uuidString
        let legacySubscriptionID = UUID().uuidString
        let legacyAPIID = UUID().uuidString

        var legacyChatGPT = try XCTUnwrap(savedAccounts.first)
        legacyChatGPT["id"] = legacyChatGPTID
        legacyChatGPT["displayName"] = "Legacy ChatGPT subscription"
        legacyChatGPT["kind"] = "chatGPTPro"

        var legacySubscription = try XCTUnwrap(savedAccounts.first)
        legacySubscription["id"] = legacySubscriptionID
        legacySubscription["displayName"] = "Legacy Claude subscription"
        legacySubscription["kind"] = "claudeMax"

        var legacyAPIAccount = try XCTUnwrap(savedAccounts.first)
        legacyAPIAccount["id"] = legacyAPIID
        legacyAPIAccount["displayName"] = "Anthropic API account"
        legacyAPIAccount["kind"] = "anthropicAPI"

        var legacySubscriptionSnapshot = try XCTUnwrap(savedSnapshots.first)
        legacySubscriptionSnapshot["id"] = UUID().uuidString
        legacySubscriptionSnapshot["accountID"] = legacySubscriptionID
        legacySubscriptionSnapshot["source"] = "manual"

        var legacyChatGPTSnapshot = try XCTUnwrap(savedSnapshots.first)
        legacyChatGPTSnapshot["id"] = UUID().uuidString
        legacyChatGPTSnapshot["accountID"] = legacyChatGPTID
        legacyChatGPTSnapshot["source"] = "chatGPTAppServer"

        var legacyAPISnapshot = try XCTUnwrap(savedSnapshots.first)
        legacyAPISnapshot["id"] = UUID().uuidString
        legacyAPISnapshot["accountID"] = legacyAPIID
        legacyAPISnapshot["source"] = "anthropicAdminAPI"

        var mismatchedSnapshot = try XCTUnwrap(savedSnapshots.first)
        mismatchedSnapshot["id"] = UUID().uuidString
        mismatchedSnapshot["source"] = "anthropicAdminAPI"

        root["schemaVersion"] = 1
        root["accounts"] = savedAccounts + [
            legacyChatGPT,
            legacySubscription,
            legacyAPIAccount
        ]
        root["snapshots"] = savedSnapshots + [
            legacyChatGPTSnapshot,
            legacySubscriptionSnapshot,
            legacyAPISnapshot,
            mismatchedSnapshot
        ]
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: fileURL, options: .atomic)

        let migrated = try await store.load()

        XCTAssertEqual(migrated.schemaVersion, PersistentState.currentSchemaVersion)
        XCTAssertEqual(migrated.accounts.count, 4)
        XCTAssertEqual(
            migrated.accounts.map(\.kind),
            [.openAIAPI, .chatGPTSubscription, .claudeSubscription, .anthropicAPI]
        )
        XCTAssertEqual(migrated.snapshots.count, 4)
        XCTAssertEqual(
            migrated.snapshots.map(\.source),
            [.openAIAdminAPI, .chatGPTAppServer, .manual, .anthropicAdminAPI]
        )

        let persistedText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persistedText.contains("chatGPTSubscription"))
        XCTAssertTrue(persistedText.contains("claudeSubscription"))
        XCTAssertTrue(persistedText.contains("anthropicAPI"))
        XCTAssertTrue(persistedText.contains("anthropicAdminAPI"))
        XCTAssertFalse(persistedText.contains("\"chatGPTPro\""))
        XCTAssertFalse(persistedText.contains("\"claudeMax\""))

        let reloaded = try await LocalDataStore(directoryURL: temporaryDirectory).load()
        XCTAssertEqual(reloaded, migrated)
    }

    func testClaudeCodeAccountAndSnapshotSurviveRepeatedLoads() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let account = try makeAccount(kind: .claudeMax)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .claudeCodeOAuth,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let expected = PersistentState(accounts: [account], snapshots: [snapshot])
        let store = try LocalDataStore(directoryURL: temporaryDirectory)

        try await store.save(expected)
        let firstLoad = try await store.load()
        let reloadedStore = try LocalDataStore(directoryURL: temporaryDirectory)
        let secondLoad = try await reloadedStore.load()
        XCTAssertEqual(firstLoad, expected)
        XCTAssertEqual(secondLoad, expected)
    }

    func testLegacyMigrationFailsClosedAndDoesNotRewriteUnrelatedCorruption() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let openAIAccount = try makeAccount(kind: .openAIAPI)
        let openAISnapshot = UsageSnapshot.awaitingRefresh(
            accountID: openAIAccount.id,
            source: .openAIAdminAPI,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.save(
            PersistentState(accounts: [openAIAccount], snapshots: [openAISnapshot])
        )

        let fileURL = temporaryDirectory.appendingPathComponent(LocalDataStore.stateFileName)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        var snapshots = try XCTUnwrap(root["snapshots"] as? [[String: Any]])
        accounts[0]["displayName"] = "   "

        let legacyAccountID = UUID().uuidString
        var legacyAccount = accounts[0]
        legacyAccount["id"] = legacyAccountID
        legacyAccount["displayName"] = "Retired account"
        legacyAccount["kind"] = "claudeMax"
        accounts.append(legacyAccount)

        var legacySnapshot = snapshots[0]
        legacySnapshot["id"] = UUID().uuidString
        legacySnapshot["accountID"] = legacyAccountID
        legacySnapshot["source"] = "manual"
        snapshots.append(legacySnapshot)

        root["accounts"] = accounts
        root["snapshots"] = snapshots
        root["schemaVersion"] = 1
        let storedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try storedData.write(to: fileURL, options: .atomic)

        do {
            _ = try await store.load()
            XCTFail("Expected unrelated account corruption to remain fatal")
        } catch let error as DomainValidationError {
            XCTAssertEqual(error, .emptyAccountName)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), storedData)
    }

    func testLegacyMigrationFailsClosedOnSupportedAccountIdentifierCollision() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try LocalDataStore(directoryURL: temporaryDirectory)
        let openAIAccount = try makeAccount(kind: .openAIAPI)
        try await store.save(PersistentState(accounts: [openAIAccount]))

        let fileURL = temporaryDirectory.appendingPathComponent(LocalDataStore.stateFileName)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        var legacyAccount = try XCTUnwrap(accounts.first)
        legacyAccount["kind"] = "claudeMax"
        accounts.append(legacyAccount)
        root["accounts"] = accounts
        root["schemaVersion"] = 1

        let storedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try storedData.write(to: fileURL, options: .atomic)

        do {
            _ = try await store.load()
            XCTFail("Expected an identifier collision to remain fatal")
        } catch let error as LocalDataStoreError {
            XCTAssertEqual(error, .duplicateAccountIdentifier)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), storedData)
    }
}
