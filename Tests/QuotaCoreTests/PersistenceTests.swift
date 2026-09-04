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

    func testLoadMigratesLegacyProviderRecordsAndKeepsOpenAIHistory() async throws {
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
        let legacySubscriptionID = UUID().uuidString
        let legacyAPIID = UUID().uuidString

        var legacySubscription = try XCTUnwrap(savedAccounts.first)
        legacySubscription["id"] = legacySubscriptionID
        legacySubscription["displayName"] = "Retired subscription"
        legacySubscription["kind"] = "claudeMax"

        var legacyAPIAccount = try XCTUnwrap(savedAccounts.first)
        legacyAPIAccount["id"] = legacyAPIID
        legacyAPIAccount["displayName"] = "Retired API account"
        legacyAPIAccount["kind"] = "anthropicAPI"

        var legacySubscriptionSnapshot = try XCTUnwrap(savedSnapshots.first)
        legacySubscriptionSnapshot["id"] = UUID().uuidString
        legacySubscriptionSnapshot["accountID"] = legacySubscriptionID
        legacySubscriptionSnapshot["source"] = "manual"

        var legacyAPISnapshot = try XCTUnwrap(savedSnapshots.first)
        legacyAPISnapshot["id"] = UUID().uuidString
        legacyAPISnapshot["accountID"] = legacyAPIID
        legacyAPISnapshot["source"] = "anthropicAdminAPI"

        var retiredSourceOnOpenAIAccount = try XCTUnwrap(savedSnapshots.first)
        retiredSourceOnOpenAIAccount["id"] = UUID().uuidString
        retiredSourceOnOpenAIAccount["source"] = "anthropicAdminAPI"

        root["accounts"] = savedAccounts + [legacySubscription, legacyAPIAccount]
        root["snapshots"] = savedSnapshots + [
            legacySubscriptionSnapshot,
            legacyAPISnapshot,
            retiredSourceOnOpenAIAccount
        ]
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: fileURL, options: .atomic)

        let migrated = try await store.load()

        XCTAssertEqual(migrated.accounts, [openAIAccount])
        XCTAssertEqual(migrated.snapshots, [openAISnapshot])

        let persistedText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("claudeMax"))
        XCTAssertFalse(persistedText.contains("anthropicAPI"))
        XCTAssertFalse(persistedText.contains("anthropicAdminAPI"))

        let reloaded = try await LocalDataStore(directoryURL: temporaryDirectory).load()
        XCTAssertEqual(reloaded, migrated)
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
