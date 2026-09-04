import Foundation
import XCTest
@testable import QuotaCore

final class QuotaRepositoryTests: XCTestCase {
    func testAPIAccountAdditionPersistsMetadataBeforeSavingCredential() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let account = try makeAccount(kind: .openAIAPI)
        let credential = try ProviderCredential(secret: "temporary-test-key")

        let state = try await repository.add(
            account: account,
            credential: credential
        )

        XCTAssertEqual(
            eventRecorder.values,
            [
                .stateSave(accountCount: 1, snapshotCount: 0),
                .credentialSave(account.id)
            ]
        )
        XCTAssertEqual(state.accounts, [account])
        let persistedState = await dataStore.load()
        XCTAssertEqual(persistedState, state)
        XCTAssertEqual(try credentialStore.credential(for: account.id), credential)
    }

    func testCredentialSaveFailureRollsBackAPIAccountMetadataAndAllowsRetry() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let existingAccount = try makeAccount(name: "Existing", kind: .chatGPTPro)
        _ = try await repository.add(account: existingAccount, credential: nil)
        eventRecorder.reset()
        let account = try makeAccount(kind: .anthropicAPI)
        let credential = try ProviderCredential(secret: "temporary-test-key")
        let initialSnapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .anthropicAdminAPI,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        credentialStore.setSaveShouldFail(true)

        do {
            _ = try await repository.add(
                account: account,
                credential: credential,
                initialSnapshot: initialSnapshot
            )
            XCTFail("Expected Keychain failure to roll back account metadata")
        } catch {
            XCTAssertEqual(error as? CredentialCleanupFixtureError, .saveFailed)
        }

        XCTAssertEqual(
            eventRecorder.values,
            [
                .stateSave(accountCount: 2, snapshotCount: 1),
                .credentialSave(account.id),
                .stateSave(accountCount: 1, snapshotCount: 0)
            ]
        )
        let rolledBackState = try await repository.load()
        let persistedRolledBackState = await dataStore.load()
        XCTAssertEqual(rolledBackState.accounts, [existingAccount])
        XCTAssertTrue(rolledBackState.snapshots.isEmpty)
        XCTAssertEqual(persistedRolledBackState, rolledBackState)
        XCTAssertNil(try credentialStore.credential(for: account.id))

        credentialStore.setSaveShouldFail(false)
        let retriedState = try await repository.add(
            account: account,
            credential: credential,
            initialSnapshot: initialSnapshot
        )
        let persistedRetriedState = await dataStore.load()
        XCTAssertEqual(retriedState.accounts, [existingAccount, account])
        XCTAssertEqual(retriedState.snapshots, [initialSnapshot])
        XCTAssertEqual(persistedRetriedState, retriedState)
        XCTAssertEqual(try credentialStore.credential(for: account.id), credential)
    }

    func testMetadataSaveFailureNeverWritesAPIAccountCredential() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let account = try makeAccount(kind: .openAIAPI)
        let credential = try ProviderCredential(secret: "temporary-test-key")
        await dataStore.failNextSave()

        do {
            _ = try await repository.add(account: account, credential: credential)
            XCTFail("Expected metadata persistence to fail before Keychain is used")
        } catch {
            XCTAssertEqual(error as? RepositoryRemovalFixtureError, .saveFailed)
        }

        XCTAssertEqual(
            eventRecorder.values,
            [.stateSave(accountCount: 1, snapshotCount: 0)]
        )
        let persistedState = await dataStore.load()
        XCTAssertTrue(persistedState.accounts.isEmpty)
        XCTAssertNil(try credentialStore.credential(for: account.id))
    }

    func testRollbackFailureAfterCredentialSaveFailureKeepsAccountVisibleAndDurable() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let account = try makeAccount(kind: .openAIAPI)
        let credential = try ProviderCredential(secret: "temporary-test-key")
        credentialStore.setSaveShouldFail(true)
        await dataStore.failSave(afterSuccessfulSaves: 1)

        do {
            _ = try await repository.add(account: account, credential: credential)
            XCTFail("Expected the failed credential save and rollback to be reported")
        } catch {
            XCTAssertEqual(
                error as? QuotaRepositoryError,
                .credentialSaveFailedAccountRetained
            )
        }

        let inMemoryState = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(inMemoryState.accounts, [account])
        XCTAssertEqual(inMemoryState, persistedState)
        XCTAssertNil(try credentialStore.credential(for: account.id))
    }

    func testUpdateRejectsAPIToManagedKindChangeBeforeOrphaningCredential() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let account = try makeAccount(kind: .openAIAPI)
        let credential = try ProviderCredential(secret: "temporary-test-key")
        _ = try await repository.add(account: account, credential: credential)
        eventRecorder.reset()
        let changedKind = try ConnectedAccount(
            id: account.id,
            displayName: account.displayName,
            kind: .chatGPTPro,
            createdAt: account.createdAt
        )

        do {
            _ = try await repository.update(
                account: changedKind,
                replacementCredential: nil
            )
            XCTFail("Expected an API account to keep its original connection type")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountKindChangeNotAllowed)
        }

        XCTAssertTrue(eventRecorder.values.isEmpty)
        let state = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(state.accounts, [account])
        XCTAssertEqual(persistedState, state)
        XCTAssertEqual(try credentialStore.credential(for: account.id), credential)
    }

    func testUpdateRejectsManagedToAPIKindChangeBeforeSavingCredential() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)
        eventRecorder.reset()
        let changedKind = try ConnectedAccount(
            id: account.id,
            displayName: account.displayName,
            kind: .openAIAPI,
            createdAt: account.createdAt
        )

        do {
            _ = try await repository.update(
                account: changedKind,
                replacementCredential: ProviderCredential(secret: "temporary-test-key")
            )
            XCTFail("Expected a managed account to keep its original connection type")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountKindChangeNotAllowed)
        }

        XCTAssertTrue(eventRecorder.values.isEmpty)
        let state = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(state.accounts, [account])
        XCTAssertEqual(persistedState, state)
        XCTAssertNil(try credentialStore.credential(for: account.id))
    }

    func testManagedClaudeLifecycleNeverUsesQuotaCredentialStore() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NeverUseCredentialStore()
        )
        let account = try makeAccount(kind: .claudeMax)
        _ = try await repository.add(account: account, credential: nil)
        let renamed = try ConnectedAccount(
            id: account.id,
            displayName: "Renamed Claude",
            kind: .claudeMax,
            createdAt: account.createdAt
        )

        _ = try await repository.update(account: renamed, replacementCredential: nil)
        let removal = try await repository.remove(accountID: account.id)

        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertFalse(removal.credentialCleanupFailed)
    }

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

    func testDirectPlanRelabelIsRejectedButProviderResolutionUpdatesAtomically() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NeverUseCredentialStore()
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)
        let directlyRelabeled = try ConnectedAccount(
            id: account.id,
            displayName: account.displayName,
            kind: .chatGPTPlus,
            createdAt: account.createdAt
        )

        do {
            _ = try await repository.update(
                account: directlyRelabeled,
                replacementCredential: nil
            )
            XCTFail("Expected direct plan relabeling to be rejected")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountKindChangeNotAllowed)
        }
        let unchangedState = try await repository.load()
        XCTAssertEqual(unchangedState.accounts, [account])

        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let state = try await repository.record(
            snapshot: snapshot,
            resolvedAccountKind: .chatGPTPlus
        )

        XCTAssertEqual(state.accounts.first?.kind, .chatGPTPlus)
        XCTAssertEqual(state.snapshots, [snapshot])
        let reloaded = try await LocalDataStore(directoryURL: temporaryDirectory).load()
        XCTAssertEqual(reloaded, state)
    }

    func testProviderPlanResolutionRejectsAConnectorFamilyChange() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let account = try makeAccount(kind: .chatGPTPro)
        _ = try await repository.add(account: account, credential: nil)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        do {
            _ = try await repository.record(
                snapshot: snapshot,
                resolvedAccountKind: .claudeMax
            )
            XCTFail("Expected a cross-provider plan change to be rejected")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .invalidResolvedAccountKind)
        }
        let state = try await repository.load()
        XCTAssertEqual(state.accounts.first?.kind, .chatGPTPro)
        XCTAssertTrue(state.snapshots.isEmpty)
    }

    func testRepositoryRejectsSnapshotFromAnotherProviderConnection() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let account = try makeAccount(kind: .openAIAPI)
        _ = try await repository.add(
            account: account,
            credential: ProviderCredential(secret: "temporary-test-key")
        )
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .anthropicAdminAPI,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        do {
            _ = try await repository.record(snapshot: snapshot)
            XCTFail("Expected cross-provider history to be rejected")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .snapshotSourceMismatch)
        }
        let state = try await repository.load()
        XCTAssertTrue(state.snapshots.isEmpty)
    }

    func testRecordAndAddOnDifferentAccountsCannotLoseEitherWrite() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataStore = ControlledRemovalDataStore(directoryURL: temporaryDirectory)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let existingAccount = try makeAccount(name: "Existing", kind: .chatGPTPro)
        let addedAccount = try makeAccount(name: "Added", kind: .chatGPTPro)
        _ = try await repository.add(account: existingAccount, credential: nil)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: existingAccount.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        await dataStore.pauseNextSaveAfterCommit()
        let recordTask = Task {
            try await repository.record(snapshot: snapshot)
        }
        await dataStore.waitUntilSaveIsPaused()
        let addTask = Task {
            try await repository.add(account: addedAccount, credential: nil)
        }
        try await waitForPendingStateTransactions(1, in: repository)

        await dataStore.resumePausedSave()
        _ = try await recordTask.value
        _ = try await addTask.value

        let inMemoryState = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(inMemoryState, persistedState)
        XCTAssertEqual(Set(inMemoryState.accounts.map(\.id)), [existingAccount.id, addedAccount.id])
        XCTAssertEqual(inMemoryState.snapshots, [snapshot])
    }

    func testRemoveAndUpdateOnDifferentAccountsCannotResurrectRemovedAccount() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataStore = ControlledRemovalDataStore(directoryURL: temporaryDirectory)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let removedAccount = try makeAccount(name: "Removed", kind: .chatGPTPro)
        let updatedAccount = try makeAccount(name: "Before", kind: .chatGPTPro)
        _ = try await repository.add(account: removedAccount, credential: nil)
        _ = try await repository.add(account: updatedAccount, credential: nil)
        let renamedAccount = try ConnectedAccount(
            id: updatedAccount.id,
            displayName: "After",
            kind: updatedAccount.kind,
            createdAt: updatedAccount.createdAt
        )

        await dataStore.pauseNextSaveAfterCommit()
        let removalTask = Task {
            try await repository.remove(accountID: removedAccount.id)
        }
        await dataStore.waitUntilSaveIsPaused()
        let updateTask = Task {
            try await repository.update(account: renamedAccount, replacementCredential: nil)
        }
        try await waitForPendingStateTransactions(1, in: repository)

        await dataStore.resumePausedSave()
        _ = try await removalTask.value
        _ = try await updateTask.value

        let inMemoryState = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(inMemoryState, persistedState)
        XCTAssertEqual(inMemoryState.accounts, [renamedAccount])
    }

    func testCancelledStateTransactionWaiterDoesNotBlockTheNextMutation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataStore = ControlledRemovalDataStore(directoryURL: temporaryDirectory)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: NoopCredentialStore()
        )
        let existingAccount = try makeAccount(name: "Existing", kind: .chatGPTPro)
        let cancelledAccount = try makeAccount(name: "Cancelled", kind: .chatGPTPro)
        let addedAccount = try makeAccount(name: "Added", kind: .chatGPTPro)
        _ = try await repository.add(account: existingAccount, credential: nil)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: existingAccount.id,
            source: .chatGPTAppServer,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        await dataStore.pauseNextSaveAfterCommit()
        let recordTask = Task {
            try await repository.record(snapshot: snapshot)
        }
        await dataStore.waitUntilSaveIsPaused()
        let cancelledTask = Task {
            try await repository.add(account: cancelledAccount, credential: nil)
        }
        try await waitForPendingStateTransactions(1, in: repository)

        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected the queued mutation to observe cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let pendingTransactionCount = await repository.pendingStateTransactionCount()
        XCTAssertEqual(pendingTransactionCount, 0)

        let addTask = Task {
            try await repository.add(account: addedAccount, credential: nil)
        }
        try await waitForPendingStateTransactions(1, in: repository)
        await dataStore.resumePausedSave()
        _ = try await recordTask.value
        _ = try await addTask.value

        let state = try await repository.load()
        XCTAssertEqual(Set(state.accounts.map(\.id)), [existingAccount.id, addedAccount.id])
        XCTAssertEqual(state.snapshots, [snapshot])
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

    func testRemoveDeletesCredentialBeforePersistingAccountAndHistoryRemoval() async throws {
        let eventRecorder = RemovalEventRecorder()
        let dataStore = InspectablePersistentStateStore(eventRecorder: eventRecorder)
        let credentialStore = RecordingCredentialStore(eventRecorder: eventRecorder)
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let (account, _) = try await addAPIAccountWithHistory(to: repository)
        eventRecorder.reset()

        let removal = try await repository.remove(accountID: account.id)

        XCTAssertEqual(
            eventRecorder.values,
            [
                .credentialDelete(account.id),
                .stateSave(accountCount: 0, snapshotCount: 0)
            ]
        )
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)
        XCTAssertFalse(removal.credentialCleanupFailed)
    }

    func testRemoveKeepsAccountAndHistoryWhenCredentialCleanupFailsAndCanRetry() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let credentialStore = RecordingCredentialStore()
        let repository = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: credentialStore
        )
        let (account, snapshot) = try await addAPIAccountWithHistory(to: repository)
        credentialStore.setDeleteShouldFail(true)

        do {
            _ = try await repository.remove(accountID: account.id)
            XCTFail("Expected Keychain cleanup failure to abort account removal")
        } catch {
            XCTAssertEqual(error as? CredentialCleanupFixtureError, .deleteFailed)
        }

        let inMemoryState = try await repository.load()
        XCTAssertEqual(inMemoryState.accounts, [account])
        XCTAssertEqual(inMemoryState.snapshots, [snapshot])
        XCTAssertNotNil(try credentialStore.credential(for: account.id))

        let reader = QuotaRepository(
            dataStore: try LocalDataStore(directoryURL: temporaryDirectory),
            credentialStore: NoopCredentialStore()
        )
        let reloadedState = try await reader.load()
        XCTAssertEqual(reloadedState, inMemoryState)

        credentialStore.setDeleteShouldFail(false)
        let removal = try await repository.remove(accountID: account.id)
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)
        XCTAssertNil(try credentialStore.credential(for: account.id))
    }

    func testStateSaveFailureAfterCredentialCleanupKeepsAccountDurableAndAllowsRetry() async throws {
        let dataStore = InspectablePersistentStateStore()
        let credentialStore = RecordingCredentialStore()
        let repository = QuotaRepository(
            dataStore: dataStore,
            credentialStore: credentialStore
        )
        let (account, snapshot) = try await addAPIAccountWithHistory(to: repository)
        await dataStore.failNextSave()

        do {
            _ = try await repository.remove(accountID: account.id)
            XCTFail("Expected the failed state save to abort account removal")
        } catch {
            XCTAssertEqual(error as? RepositoryRemovalFixtureError, .saveFailed)
        }

        XCTAssertNil(try credentialStore.credential(for: account.id))
        let inMemoryState = try await repository.load()
        let persistedState = await dataStore.load()
        XCTAssertEqual(inMemoryState.accounts, [account])
        XCTAssertEqual(inMemoryState.snapshots, [snapshot])
        XCTAssertEqual(persistedState, inMemoryState)

        let removal = try await repository.remove(accountID: account.id)
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)
        let retriedPersistedState = await dataStore.load()
        XCTAssertEqual(retriedPersistedState, removal.state)
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

        let removalTask = Task {
            try await repository.remove(accountID: account.id)
        }
        try await waitForPendingStateTransactions(1, in: repository)
        await dataStore.resumePausedSave()
        do {
            _ = try await refreshTask.value
            XCTFail("Expected the older refresh result to be invalidated by removal")
        } catch {
            XCTAssertEqual(error as? QuotaRepositoryError, .accountNotFound)
        }
        let removal = try await removalTask.value
        XCTAssertTrue(removal.state.accounts.isEmpty)
        XCTAssertTrue(removal.state.snapshots.isEmpty)

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

    private func waitForPendingStateTransactions(
        _ expectedCount: Int,
        in repository: QuotaRepository
    ) async throws {
        for _ in 0..<10_000 {
            if await repository.pendingStateTransactionCount() == expectedCount {
                return
            }
            await Task.yield()
        }
        throw RepositoryConcurrencyFixtureError.transactionDidNotQueue
    }

    private func addAPIAccountWithHistory(
        to repository: QuotaRepository
    ) async throws -> (ConnectedAccount, UsageSnapshot) {
        let account = try makeAccount(kind: .openAIAPI)
        let snapshot = UsageSnapshot.awaitingRefresh(
            accountID: account.id,
            source: .openAIAdminAPI,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = try await repository.add(
            account: account,
            credential: ProviderCredential(secret: "temporary-test-key")
        )
        _ = try await repository.record(snapshot: snapshot)
        return (account, snapshot)
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

private enum CredentialCleanupFixtureError: Error, Equatable {
    case deleteFailed
    case saveFailed
}

private enum RepositoryConcurrencyFixtureError: Error {
    case transactionDidNotQueue
}

private enum RepositoryRemovalFixtureError: Error, Equatable {
    case saveFailed
}

private enum RemovalEvent: Equatable {
    case credentialDelete(UUID)
    case credentialSave(UUID)
    case stateSave(accountCount: Int, snapshotCount: Int)
}

private final class RemovalEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [RemovalEvent] = []

    var values: [RemovalEvent] {
        lock.withLock { storedValues }
    }

    func append(_ event: RemovalEvent) {
        lock.withLock { storedValues.append(event) }
    }

    func reset() {
        lock.withLock { storedValues.removeAll() }
    }
}

private actor InspectablePersistentStateStore: PersistentStateStoring {
    nonisolated let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    private var state = PersistentState()
    private var successfulSavesBeforeFailure: Int?
    private let eventRecorder: RemovalEventRecorder?

    init(eventRecorder: RemovalEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func load() -> PersistentState {
        state
    }

    func save(_ state: PersistentState) throws {
        eventRecorder?.append(
            .stateSave(
                accountCount: state.accounts.count,
                snapshotCount: state.snapshots.count
            )
        )
        if successfulSavesBeforeFailure == 0 {
            successfulSavesBeforeFailure = nil
            throw RepositoryRemovalFixtureError.saveFailed
        }
        self.state = state
        if let remaining = successfulSavesBeforeFailure {
            successfulSavesBeforeFailure = remaining - 1
        }
    }

    func failNextSave() {
        successfulSavesBeforeFailure = 0
    }

    func failSave(afterSuccessfulSaves count: Int) {
        successfulSavesBeforeFailure = count
    }
}

private final class RecordingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: ProviderCredential] = [:]
    private var deleteShouldFail = false
    private var saveShouldFail = false
    private let eventRecorder: RemovalEventRecorder?

    init(eventRecorder: RemovalEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func save(_ credential: ProviderCredential, for accountID: UUID) throws {
        eventRecorder?.append(.credentialSave(accountID))
        try lock.withLock {
            if saveShouldFail {
                throw CredentialCleanupFixtureError.saveFailed
            }
            credentials[accountID] = credential
        }
    }

    func credential(for accountID: UUID) throws -> ProviderCredential? {
        lock.withLock { credentials[accountID] }
    }

    func deleteCredential(for accountID: UUID) throws {
        eventRecorder?.append(.credentialDelete(accountID))
        try lock.withLock {
            if deleteShouldFail {
                throw CredentialCleanupFixtureError.deleteFailed
            }
            credentials[accountID] = nil
        }
    }

    func setDeleteShouldFail(_ shouldFail: Bool) {
        lock.withLock { deleteShouldFail = shouldFail }
    }

    func setSaveShouldFail(_ shouldFail: Bool) {
        lock.withLock { saveShouldFail = shouldFail }
    }
}

private struct NeverUseCredentialStore: CredentialStoring {
    func save(_ credential: ProviderCredential, for accountID: UUID) throws {
        throw CredentialCleanupFixtureError.deleteFailed
    }

    func credential(for accountID: UUID) throws -> ProviderCredential? {
        throw CredentialCleanupFixtureError.deleteFailed
    }

    func deleteCredential(for accountID: UUID) throws {
        throw CredentialCleanupFixtureError.deleteFailed
    }
}
