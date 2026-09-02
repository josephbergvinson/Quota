import Foundation
import XCTest
@testable import QuotaCore

final class QuotaRepositoryTests: XCTestCase {
    func testOlderRefreshCannotReplaceNewerSnapshot() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)

        let olderDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newerDate = olderDate.addingTimeInterval(60)
        let newer = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: newerDate
        )
        let older = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: olderDate
        )

        _ = try await repository.record(snapshot: newer)
        let state = try await repository.record(snapshot: older)

        XCTAssertEqual(state.snapshots.count, 1)
        XCTAssertEqual(state.snapshots.first?.id, newer.id)
        XCTAssertEqual(state.latestSnapshotsByAccount[account.id]?.capturedAt, newerDate)
    }

    func testRemoveAccountDeletesItsHistoryAndPersistsTheRemoval() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let account = try makeAccount(kind: .chatGPTPro)
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        _ = try await repository.add(account: account, credential: nil)
        _ = try await repository.record(
            snapshot: makeManualSnapshot(
                accountID: account.id,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                usedPercent: 25,
                resetAt: nil
            )
        )

        let removal = try await repository.remove(accountID: account.id)

        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)
        XCTAssertFalse(removal.credentialCleanupFailed)

        let reader = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let reloadedState = try await reader.load()
        XCTAssertTrue(reloadedState.accounts.isEmpty)
        XCTAssertTrue(reloadedState.snapshots.isEmpty)
    }

    func testRemoveAccountPersistsEvenWhenCredentialCleanupFails() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let account = try makeAccount(kind: .openAIAPI)
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: DeleteFailingCredentialStore()
        )
        _ = try await repository.add(
            account: account,
            credential: ProviderCredential(secret: "temporary-test-key")
        )
        _ = try await repository.record(
            snapshot: UsageSnapshot.awaitingRefresh(
                accountID: account.id,
                source: .openAIAdminAPI,
                at: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        let removal = try await repository.remove(accountID: account.id)

        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)
        XCTAssertTrue(removal.credentialCleanupFailed)

        let reader = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let reloadedState = try await reader.load()
        XCTAssertTrue(reloadedState.accounts.isEmpty)
        XCTAssertTrue(reloadedState.snapshots.isEmpty)
    }

    func testRefreshCannotRewriteAccountAfterRemovalHasStartedSaving() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataStore = ControlledRemovalDataStore(directoryURL: temporaryDirectory)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)
        await dataStore.pauseNextSaveAfterCommit()

        let removalTask = Task {
            try await repository.remove(accountID: account.id)
        }
        await dataStore.waitUntilSaveIsPaused()

        let lateRefresh = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        do {
            _ = try await repository.record(snapshot: lateRefresh)
            XCTFail("Expected a refresh racing with removal to be rejected")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountNotFound)
        }

        await dataStore.resumePausedSave()
        let removal = try await removalTask.value
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)

        let reloadedState = await dataStore.load()
        XCTAssertTrue(reloadedState.accounts.isEmpty)
        XCTAssertTrue(reloadedState.snapshots.isEmpty)
    }

    func testRefreshThatStartedBeforeRemovalCannotPublishStaleStateAfterRemovalFinishes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataStore = ControlledRemovalDataStore(directoryURL: temporaryDirectory)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)

        let refresh = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await dataStore.pauseNextSaveAfterCommit()
        let refreshTask = Task {
            try await repository.record(snapshot: refresh)
        }
        await dataStore.waitUntilSaveIsPaused()

        let removal: AccountRemovalResult
        do {
            removal = try await repository.remove(accountID: account.id)
        } catch {
            await dataStore.resumePausedSave()
            throw error
        }
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)

        await dataStore.resumePausedSave()
        do {
            _ = try await refreshTask.value
            XCTFail("Expected the older refresh result to be invalidated by removal")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountNotFound)
        }

        let inMemoryState = try await repository.load()
        XCTAssertTrue(inMemoryState.accounts.isEmpty)
        XCTAssertTrue(inMemoryState.snapshots.isEmpty)

        do {
            _ = try await repository.record(snapshot: refresh)
            XCTFail("Expected a later refresh for the removed account to be rejected")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountNotFound)
        }

        let reader = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let reloadedState = try await reader.load()
        XCTAssertTrue(reloadedState.accounts.isEmpty)
        XCTAssertTrue(reloadedState.snapshots.isEmpty)
    }
}

private actor ControlledRemovalDataStore: PersistentStateStoring {
    nonisolated let directoryURL: URL

    private var state = PersistentState()
    private var shouldPauseNextSave = false
    private var saveIsPaused = false
    private var savePausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveResumeWaiter: CheckedContinuation<Void, Never>?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func load() -> PersistentState {
        state
    }

    func save(_ state: PersistentState) async {
        self.state = state
        guard shouldPauseNextSave else { return }
        shouldPauseNextSave = false
        saveIsPaused = true
        let waiters = savePausedWaiters
        savePausedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            saveResumeWaiter = continuation
        }
        saveIsPaused = false
    }

    func pauseNextSaveAfterCommit() {
        shouldPauseNextSave = true
    }

    func waitUntilSaveIsPaused() async {
        guard !saveIsPaused else { return }
        await withCheckedContinuation { continuation in
            savePausedWaiters.append(continuation)
        }
    }

    func resumePausedSave() {
        saveResumeWaiter?.resume()
        saveResumeWaiter = nil
    }
}

private enum CredentialCleanupFixtureError: Error {
    case deleteFailed
}

private struct DeleteFailingCredentialStore: CredentialStoring {
    func save(_ credential: ProviderCredential, for accountID: UUID) throws {}

    func credential(for accountID: UUID) throws -> ProviderCredential? {
        nil
    }

    func deleteCredential(for accountID: UUID) throws {
        throw CredentialCleanupFixtureError.deleteFailed
    }
}
