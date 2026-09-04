import Darwin
import Foundation
import XCTest
@testable import QuotaCore

final class ChatGPTAppServerConnectorTests: XCTestCase {
    func testProfileCoordinationKeyNormalizesSystemAndCaseAliases() {
        XCTAssertEqual(
            chatGPTProfileCoordinationKey(
                URL(fileURLWithPath: "/tmp/Quota-Profile", isDirectory: true)
            ),
            chatGPTProfileCoordinationKey(
                URL(fileURLWithPath: "/private/tmp/quota-profile", isDirectory: true)
            )
        )
    }

    func testProfileCoordinationPathFoldsOnlyKnownCaseInsensitiveVolumes() {
        let upper = "/Volumes/Provider/Quota-Profile"
        let lower = "/Volumes/Provider/quota-profile"

        XCTAssertEqual(
            normalizedChatGPTProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: false
            ),
            normalizedChatGPTProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: false
            )
        )
        XCTAssertNotEqual(
            normalizedChatGPTProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: true
            ),
            normalizedChatGPTProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: true
            )
        )
        XCTAssertNotEqual(
            normalizedChatGPTProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: nil
            ),
            normalizedChatGPTProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: nil
            )
        )
    }

    func testRetiringProfileRejectsQueuedAndFutureOperations() async throws {
        let coordinator = ChatGPTProfileOperationCoordinator()
        let profileKey = "/private/tmp/chatgpt-profile-\(UUID().uuidString)"

        let acquiredInitialLease = await coordinator.acquire(profileKey: profileKey)
        let initialLease = try XCTUnwrap(acquiredInitialLease)
        let queuedOperation = Task {
            await coordinator.acquire(profileKey: profileKey)
        }
        try await waitForQueuedOperation(in: coordinator, profileKey: profileKey)

        let retirement = Task {
            await coordinator.retireAndAcquire(profileKey: profileKey)
        }
        try await waitForRetirement(in: coordinator, profileKey: profileKey)

        let queuedLease = await queuedOperation.value
        XCTAssertNil(queuedLease)
        let futureLease = await coordinator.acquire(profileKey: profileKey)
        XCTAssertNil(futureLease)

        await coordinator.release(initialLease)
        let retirementLease = await retirement.value
        await coordinator.release(retirementLease)
    }

    func testRetiredProfileCanBeReactivatedAfterAbortedRemoval() async throws {
        let coordinator = ChatGPTProfileOperationCoordinator()
        let profileKey = "/private/tmp/chatgpt-profile-\(UUID().uuidString)"

        let retirementLease = await coordinator.retireAndAcquire(profileKey: profileKey)
        await coordinator.release(retirementLease)
        let retiredLease = await coordinator.acquire(profileKey: profileKey)
        XCTAssertNil(retiredLease)

        await coordinator.reactivate(profileKey: profileKey)
        let acquiredReactivatedLease = await coordinator.acquire(profileKey: profileKey)
        let reactivatedLease = try XCTUnwrap(acquiredReactivatedLease)
        await coordinator.release(reactivatedLease)
    }

    func testCancellingQueuedProfileOperationRemovesItPromptly() async throws {
        let coordinator = ChatGPTProfileOperationCoordinator()
        let profileKey = "/private/tmp/chatgpt-profile-\(UUID().uuidString)"
        let acquiredInitialLease = await coordinator.acquire(profileKey: profileKey)
        let initialLease = try XCTUnwrap(acquiredInitialLease)
        let queuedOperation = Task {
            await coordinator.acquire(profileKey: profileKey)
        }
        try await waitForQueuedOperation(in: coordinator, profileKey: profileKey)

        queuedOperation.cancel()

        let queuedLease = await queuedOperation.value
        XCTAssertNil(queuedLease)
        let queuedOperationCount = await coordinator.queuedOperationCount(profileKey: profileKey)
        XCTAssertEqual(queuedOperationCount, 0)
        await coordinator.release(initialLease)
    }

    func testExecutableDiscoveryPrefersAppBundleOverApplicationsAndPATH() throws {
        let root = try makeTemporaryDirectory()
        let bundledExecutable = root.appendingPathComponent("bundle/codex")
        let applicationExecutable = root.appendingPathComponent("application/codex")
        let pathDirectory = root.appendingPathComponent("path", isDirectory: true)
        try makeExecutable(at: bundledExecutable)
        try makeExecutable(at: applicationExecutable)
        try makeExecutable(at: pathDirectory.appendingPathComponent("codex"))

        let discovered = ChatGPTAppServerConfiguration.discoverCodexExecutable(
            bundledCandidate: bundledExecutable,
            applicationCandidates: [applicationExecutable],
            path: pathDirectory.path,
            homeDirectoryURL: root.appendingPathComponent("home", isDirectory: true),
            systemSearchDirectories: [],
            fileManager: .default
        )

        XCTAssertEqual(discovered, bundledExecutable.standardizedFileURL)
    }

    func testExecutableDiscoveryFindsStandaloneInstallOutsideFinderPATH() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let standaloneExecutable = home.appendingPathComponent(".local/bin/codex")
        try makeExecutable(at: standaloneExecutable)

        let discovered = ChatGPTAppServerConfiguration.discoverCodexExecutable(
            bundledCandidate: nil,
            applicationCandidates: [],
            path: "/usr/bin:/bin:/usr/sbin:/sbin",
            homeDirectoryURL: home,
            systemSearchDirectories: [],
            fileManager: .default
        )

        XCTAssertEqual(discovered, standaloneExecutable.standardizedFileURL)
    }

    func testExecutableDiscoveryFindsNewestNVMInstallWithoutFinderPATH() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let olderExecutable = home.appendingPathComponent(".nvm/versions/node/v22.9.0/bin/codex")
        let newerExecutable = home.appendingPathComponent(".nvm/versions/node/v22.10.0/bin/codex")
        try makeExecutable(at: olderExecutable)
        try makeExecutable(at: newerExecutable)

        let discovered = ChatGPTAppServerConfiguration.discoverCodexExecutable(
            bundledCandidate: nil,
            applicationCandidates: [],
            path: nil,
            homeDirectoryURL: home,
            systemSearchDirectories: [],
            fileManager: .default
        )

        XCTAssertEqual(discovered, newerExecutable.standardizedFileURL)
    }

    func testAccountFixtureDecodesChatGPTProWithoutInventingMissingEmail() throws {
        let raw: ChatGPTRawAccountReadResponse = try decodeFixture(
            """
            {
              "account": { "type": "chatgpt", "email": null, "planType": "pro" },
              "requiresOpenaiAuth": true
            }
            """
        )

        let account = try raw.validatedDTO()
        XCTAssertTrue(account.requiresOpenAIAuth)
        XCTAssertEqual(account.account, .chatGPT(email: nil, planType: "pro"))
    }

    func testRateLimitFixturePreservesAllBucketsAndResetCreditSemantics() throws {
        let raw: ChatGPTRawRateLimitsResponse = try decodeFixture(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": "Codex",
                "planType": "pro",
                "primary": {
                  "usedPercent": 82,
                  "windowDurationMins": 300,
                  "resetsAt": 1788264000
                },
                "secondary": {
                  "usedPercent": 47,
                  "windowDurationMins": 10080,
                  "resetsAt": 1788656400
                },
                "credits": { "balance": "12.50", "hasCredits": true, "unlimited": false },
                "individualLimit": {
                  "used": "7.50",
                  "limit": "20.00",
                  "remainingPercent": 63,
                  "resetsAt": 1788656400
                },
                "rateLimitReachedType": null,
                "spendControlReached": false
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 82,
                    "windowDurationMins": 300,
                    "resetsAt": 1788264000
                  }
                },
                "codex_other": {
                  "limitId": "codex_other",
                  "limitName": "Other models",
                  "primary": {
                    "usedPercent": 19,
                    "windowDurationMins": 1440,
                    "resetsAt": 1788307200
                  }
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [{
                  "id": "reset_1",
                  "resetType": "codexRateLimits",
                  "status": "available",
                  "grantedAt": 1788004800,
                  "expiresAt": 1788872400,
                  "title": "Full reset",
                  "description": "Resets eligible Codex windows."
                }]
              }
            }
            """
        )

        let limits = try raw.validatedDTO()
        XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 82)
        XCTAssertEqual(limits.rateLimits.primary?.remainingPercent, 18)
        XCTAssertEqual(limits.rateLimits.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(
            limits.rateLimits.primary?.resetsAt,
            Date(timeIntervalSince1970: 1_788_264_000)
        )
        XCTAssertEqual(limits.rateLimits.secondary?.usedPercent, 47)
        XCTAssertEqual(limits.rateLimitsByLimitID?["codex_other"]?.primary?.usedPercent, 19)
        XCTAssertEqual(limits.rateLimits.credits?.balance, "12.50")
        XCTAssertEqual(limits.rateLimits.individualLimit?.remainingPercent, 63)

        XCTAssertEqual(limits.resetCredits?.availableCount, 2)
        XCTAssertEqual(limits.resetCredits?.credits?.count, 1)
        XCTAssertEqual(limits.resetCredits?.credits?.first?.id, "reset_1")
        XCTAssertEqual(
            limits.resetCredits?.credits?.first?.expiresAt,
            Date(timeIntervalSince1970: 1_788_872_400)
        )
    }

    func testRateLimitOutOfRangeProviderPercentIsRetainedButNotUsedToDeriveRemaining() throws {
        let raw: ChatGPTRawRateLimitsResponse = try decodeFixture(
            """
            {
              "rateLimits": { "primary": { "usedPercent": 137 } },
              "rateLimitResetCredits": { "availableCount": 3, "credits": null }
            }
            """
        )

        let limits = try raw.validatedDTO()
        XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 137)
        XCTAssertNil(limits.rateLimits.primary?.remainingPercent)
        XCTAssertEqual(limits.resetCredits?.availableCount, 3)
        XCTAssertNil(limits.resetCredits?.credits)
    }

    func testSpendControlRejectsOutOfRangeRemainingPercent() throws {
        let raw: ChatGPTRawSpendControl = try decodeFixture(
            """
            {
              "used": "1.00",
              "limit": "10.00",
              "remainingPercent": 140,
              "resetsAt": 1788656400
            }
            """
        )

        XCTAssertThrowsError(try raw.validatedDTO()) { error in
            XCTAssertEqual(error as? ChatGPTConnectorError, .invalidProviderPayload)
        }
    }

    func testAccountWideUsageFixturePreservesUnavailableSummaryMetricsAndDailyHistory() throws {
        let raw: ChatGPTRawTokenUsageResponse = try decodeFixture(
            """
            {
              "summary": {
                "lifetimeTokens": 1234567,
                "peakDailyTokens": 45678,
                "longestRunningTurnSec": null,
                "currentStreakDays": 8,
                "longestStreakDays": null
              },
              "dailyUsageBuckets": [
                { "startDate": "2026-08-30", "tokens": 1200 },
                { "startDate": "2026-08-31", "tokens": 3400 }
              ],
              "threadUsage": null
            }
            """
        )

        let usage = try raw.validatedDTO()
        XCTAssertEqual(usage.summary.lifetimeTokens, 1_234_567)
        XCTAssertNil(usage.summary.longestRunningTurnSeconds)
        XCTAssertNil(usage.summary.longestStreakDays)
        XCTAssertEqual(usage.dailyUsage?.map(\.tokens), [1_200, 3_400])
        XCTAssertEqual(usage.dailyUsage?.first?.date, utcDate(year: 2026, month: 8, day: 30))
        XCTAssertNil(usage.threadUsage)
    }

    func testThreadUsageFixtureDecodesModelBreakdownAsInt64() throws {
        let raw: ChatGPTRawTokenUsageResponse = try decodeFixture(
            """
            {
              "summary": {},
              "dailyUsageBuckets": null,
              "threadUsage": {
                "threadId": "thr_123",
                "estimatedUsageCreditsMicros": 1250000,
                "estimatedUsageUsdMicros": 175000,
                "groups": [{
                  "model": "gpt-5.6-sol",
                  "reasoningEffort": "high",
                  "speed": "standard",
                  "estimatedUsageCreditsMicros": 1250000,
                  "inputTokens": 9000000000,
                  "cachedInputTokens": 7000000000,
                  "netNewInputTokens": 2000000000,
                  "outputTokens": 500000000,
                  "totalTokens": 9500000000
                }]
              }
            }
            """
        )

        let usage = try raw.validatedDTO()
        XCTAssertNil(usage.dailyUsage)
        XCTAssertEqual(usage.threadUsage?.threadID, "thr_123")
        XCTAssertEqual(usage.threadUsage?.groups.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(usage.threadUsage?.groups.first?.inputTokens, 9_000_000_000)
        XCTAssertEqual(usage.threadUsage?.groups.first?.totalTokens, 9_500_000_000)
    }

    func testNegativeTokenFixtureIsRejectedInsteadOfClamped() throws {
        let raw: ChatGPTRawTokenUsageResponse = try decodeFixture(
            """
            {
              "summary": { "lifetimeTokens": -1 },
              "dailyUsageBuckets": null
            }
            """
        )

        XCTAssertThrowsError(try raw.validatedDTO()) { error in
            XCTAssertEqual(error as? ChatGPTConnectorError, .invalidProviderPayload)
        }
    }

    func testLoginFixturesReturnHTTPSBrowserAndDeviceCodeFlows() throws {
        let browser: ChatGPTRawLoginResponse = try decodeFixture(
            """
            {
              "type": "chatgpt",
              "loginId": "login_browser",
              "authUrl": "https://chatgpt.com/auth/codex?state=fixture"
            }
            """
        )
        XCTAssertEqual(
            try browser.validatedFlow(for: .browser),
            .browser(
                loginID: "login_browser",
                authorizationURL: URL(string: "https://chatgpt.com/auth/codex?state=fixture")!
            )
        )

        let device: ChatGPTRawLoginResponse = try decodeFixture(
            """
            {
              "type": "chatgptDeviceCode",
              "loginId": "login_device",
              "verificationUrl": "https://auth.openai.com/codex/device",
              "userCode": "ABCD-1234"
            }
            """
        )
        XCTAssertEqual(
            try device.validatedFlow(for: .deviceCode),
            .deviceCode(
                loginID: "login_device",
                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                userCode: "ABCD-1234"
            )
        )
    }

    func testLoginFixtureRejectsNonHTTPSAuthorizationURL() throws {
        let raw: ChatGPTRawLoginResponse = try decodeFixture(
            """
            {
              "type": "chatgpt",
              "loginId": "login_browser",
              "authUrl": "http://example.com/not-safe"
            }
            """
        )

        XCTAssertThrowsError(try raw.validatedFlow(for: .browser)) { error in
            XCTAssertEqual(error as? ChatGPTConnectorError, .invalidProviderPayload)
        }
    }

    func testLoginCompletionDoesNotExposeProviderErrorText() throws {
        let raw: ChatGPTRawLoginCompletion = try decodeFixture(
            """
            {
              "loginId": "login_browser",
              "success": false,
              "error": "bearer secret-provider-token at https://example.com/callback?code=secret"
            }
            """
        )

        let completion = try raw.validatedDTO()
        XCTAssertFalse(completion.succeeded)
        XCTAssertEqual(completion.errorMessage, "ChatGPT sign-in did not complete.")
        XCTAssertFalse(completion.errorMessage?.contains("secret-provider-token") ?? true)
    }

    func testConnectorPerformsHandshakeAndAllTelemetryReadsOverJSONL() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryFixtureScript)
        let capturedAt = Date(timeIntervalSince1970: 1_788_321_600)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 2,
            loginTimeoutSeconds: 2
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        let telemetry = try await connector.readTelemetry(capturedAt: capturedAt)

        XCTAssertEqual(telemetry.capturedAt, capturedAt)
        XCTAssertEqual(telemetry.account.account, .chatGPT(email: "fixture@example.com", planType: "pro"))
        XCTAssertEqual(telemetry.rateLimits.rateLimits.primary?.usedPercent, 61)
        XCTAssertEqual(telemetry.tokenUsage.summary.lifetimeTokens, 4_200)
        XCTAssertEqual(telemetry.tokenUsage.dailyUsage?.first?.tokens, 900)
    }

    func testRetiringProfileWaitsForSlowTelemetryAndPreventsProfileRecreation() async throws {
        let fixture = try makeProcessFixture(script: Self.slowTelemetryAndLogoutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 2
        )
        let telemetryConnector = ChatGPTAppServerConnector(configuration: configuration)
        let removalConnector = ChatGPTAppServerConnector(configuration: configuration)
        let allowTelemetryURL = fixture.codexHome.appendingPathComponent("allow-telemetry")
        defer { try? Data("continue".utf8).write(to: allowTelemetryURL, options: .atomic) }

        let telemetry = Task {
            try await telemetryConnector.readTelemetry()
        }
        try await waitForFile(
            fixture.codexHome.appendingPathComponent("telemetry-started")
        )

        let removal = Task {
            try await removalConnector.retireAndLogout()
        }
        let profileKey = chatGPTProfileCoordinationKey(fixture.codexHome)
        try await waitForRetirement(
            in: ChatGPTProfileOperationCoordinator.shared,
            profileKey: profileKey
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.codexHome.appendingPathComponent("logout-started").path
            )
        )
        do {
            _ = try await ChatGPTAppServerConnector(configuration: configuration).readRateLimits()
            XCTFail("Expected work queued after retirement to be rejected")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .profileRetired)
        }
        XCTAssertEqual(try fixtureLaunchCount(in: fixture.codexHome), 1)

        try Data("continue".utf8).write(to: allowTelemetryURL, options: .atomic)
        _ = try await telemetry.value
        try await removal.value

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.codexHome.appendingPathComponent("logout-started").path
            )
        )
        XCTAssertEqual(try fixtureLaunchCount(in: fixture.codexHome), 2)

        try FileManager.default.removeItem(at: fixture.codexHome)
        do {
            _ = try await ChatGPTAppServerConnector(configuration: configuration).readRateLimits()
            XCTFail("Expected a retired profile to reject reads after deletion")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .profileRetired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.codexHome.path))
    }

    func testCancelledRetirementKeepsProfileBlockedUntilRemovalRollsBack() async throws {
        let fixture = try makeProcessFixture(script: Self.slowTelemetryAndLogoutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 2
        )
        let telemetryConnector = ChatGPTAppServerConnector(configuration: configuration)
        let removalConnector = ChatGPTAppServerConnector(configuration: configuration)
        let allowTelemetryURL = fixture.codexHome.appendingPathComponent("allow-telemetry")
        defer { try? Data("continue".utf8).write(to: allowTelemetryURL, options: .atomic) }

        let telemetry = Task {
            try await telemetryConnector.readTelemetry()
        }
        try await waitForFile(
            fixture.codexHome.appendingPathComponent("telemetry-started")
        )

        let removal = Task {
            try await removalConnector.retireAndLogout()
        }
        let profileKey = chatGPTProfileCoordinationKey(fixture.codexHome)
        try await waitForRetirement(
            in: ChatGPTProfileOperationCoordinator.shared,
            profileKey: profileKey
        )
        removal.cancel()
        try Data("continue".utf8).write(to: allowTelemetryURL, options: .atomic)
        _ = try await telemetry.value

        do {
            try await removal.value
            XCTFail("Expected the cancelled retirement to stop before logout")
        } catch is CancellationError {
            // Expected. The profile remains retired until the caller rolls the removal back.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.codexHome.appendingPathComponent("logout-started").path
            )
        )
        do {
            _ = try await telemetryConnector.readTelemetry()
            XCTFail("Expected cancellation to leave the profile retired")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .profileRetired)
        }

        await ChatGPTAppServerConnector.reactivateProfile(codexHomeURL: fixture.codexHome)
        let refreshedTelemetry = try await telemetryConnector.readTelemetry()
        XCTAssertEqual(refreshedTelemetry.tokenUsage.summary.lifetimeTokens, 4_200)
        XCTAssertEqual(try fixtureLaunchCount(in: fixture.codexHome), 2)
    }

    func testFailedRetirementCanBeReactivatedForRemovalRetry() async throws {
        let fixture = try makeProcessFixture(script: Self.slowTelemetryAndLogoutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 2
        )
        try FileManager.default.createDirectory(
            at: fixture.codexHome,
            withIntermediateDirectories: true
        )
        let failLogoutURL = fixture.codexHome.appendingPathComponent("fail-logout")
        try Data("fail".utf8).write(to: failLogoutURL, options: .atomic)
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            try await connector.retireAndLogout()
            XCTFail("Expected logout failure")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .rpcFailure(code: -32_000))
        }
        do {
            _ = try await connector.readTelemetry()
            XCTFail("Expected failed removal to leave the profile retired")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .profileRetired)
        }

        try FileManager.default.removeItem(at: failLogoutURL)
        try Data("continue".utf8).write(
            to: fixture.codexHome.appendingPathComponent("allow-telemetry"),
            options: .atomic
        )
        await ChatGPTAppServerConnector.reactivateProfile(codexHomeURL: fixture.codexHome)
        let telemetry = try await connector.readTelemetry()
        XCTAssertEqual(telemetry.rateLimits.rateLimits.primary?.usedPercent, 61)
        XCTAssertEqual(try fixtureLaunchCount(in: fixture.codexHome), 2)
    }

    func testTelemetryRetriesOneTimedOutReadInANewProcess() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryRetryFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        let telemetry = try await connector.readTelemetry()

        XCTAssertEqual(telemetry.rateLimits.rateLimits.primary?.usedPercent, 61)
        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 2)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 2)
    }

    func testTelemetryRetriesOneTransientRPCFailureInANewProcess() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryTransientRPCFailureFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        let telemetry = try await connector.readTelemetry()

        XCTAssertEqual(telemetry.rateLimits.rateLimits.primary?.usedPercent, 61)
        XCTAssertEqual(telemetry.tokenUsage.summary.lifetimeTokens, 4_200)
        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 2)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 2)
    }

    func testTelemetryPropagatesSecondTransientRPCFailureAndStopsBothProcesses() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryAlwaysRPCFailureFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readTelemetry()
            XCTFail("Expected the second transient RPC failure to propagate")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .rpcFailure(code: -32_603))
            XCTAssertTrue(error.localizedDescription.contains("temporary internal error"))
            XCTAssertTrue(error.localizedDescription.contains("try again"))
        }

        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 2)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 2)
    }

    func testTelemetryPropagatesSecondTimeoutAndStopsBothProcesses() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryAlwaysTimesOutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readTelemetry()
            XCTFail("Expected the second timeout to propagate")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .requestTimedOut(method: "account/rateLimits/read"))
            XCTAssertFalse(error.localizedDescription.contains("account/rateLimits/read"))
            XCTAssertTrue(error.localizedDescription.contains("Try again"))
        }

        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 2)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 2)
    }

    func testTelemetryDoesNotRetryANonTimeoutFailure() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryRPCFailureFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readTelemetry()
            XCTFail("Expected the RPC failure to propagate")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .rpcFailure(code: -32_000))
        }

        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 1)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 1)
    }

    func testTelemetryDoesNotRetryTimeoutWhenRefreshingAuthentication() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryAlwaysTimesOutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readTelemetry(refreshToken: true)
            XCTFail("Expected the authentication refresh timeout to propagate")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .requestTimedOut(method: "account/rateLimits/read"))
        }

        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 1)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 1)
    }

    func testTelemetryDoesNotRetryTransientRPCFailureWhenRefreshingAuthentication() async throws {
        let fixture = try makeProcessFixture(script: Self.telemetryAlwaysRPCFailureFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readTelemetry(refreshToken: true)
            XCTFail("Expected the authentication refresh RPC failure to propagate")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .rpcFailure(code: -32_603))
        }

        XCTAssertEqual(try fixtureAttemptCount(in: fixture.codexHome), 1)
        try assertFixtureProcessesExited(in: fixture.codexHome, expectedCount: 1)
    }

    func testConnectorTimesOutAndTerminatesAnUnresponsiveProcess() async throws {
        let fixture = try makeProcessFixture(script: Self.timeoutFixtureScript)
        let configuration = try ChatGPTAppServerConfiguration(
            codexHomeURL: fixture.codexHome,
            codexExecutableURL: fixture.executable,
            requestTimeoutSeconds: 5,
            loginTimeoutSeconds: 1
        )
        let connector = ChatGPTAppServerConnector(configuration: configuration)

        do {
            _ = try await connector.readRateLimits()
            XCTFail("Expected a timeout")
        } catch let error as ChatGPTConnectorError {
            XCTAssertEqual(error, .requestTimedOut(method: "account/rateLimits/read"))
        }

        let pidURL = fixture.codexHome.appendingPathComponent("fixture.pid")
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func decodeFixture<Value: Decodable>(_ fixture: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(fixture.utf8))
    }

    private func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeProcessFixture(script: String) throws -> (executable: URL, codexHome: URL) {
        let root = try makeTemporaryDirectory()
        let executable = root.appendingPathComponent("fake-codex", isDirectory: false)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, codexHome)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-chatgpt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func waitForQueuedOperation(
        in coordinator: ChatGPTProfileOperationCoordinator,
        profileKey: String
    ) async throws {
        for _ in 0..<200 {
            if await coordinator.queuedOperationCount(profileKey: profileKey) > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureWaitError.timedOut
    }

    private func waitForRetirement(
        in coordinator: ChatGPTProfileOperationCoordinator,
        profileKey: String
    ) async throws {
        for _ in 0..<200 {
            if await coordinator.isRetired(profileKey: profileKey) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureWaitError.timedOut
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureWaitError.timedOut
    }

    private func fixtureLaunchCount(in codexHome: URL) throws -> Int {
        let text = try String(
            contentsOf: codexHome.appendingPathComponent("fixture-launch-count"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int(text))
    }

    private func fixtureAttemptCount(in codexHome: URL) throws -> Int {
        let text = try String(
            contentsOf: codexHome.appendingPathComponent("fixture-attempt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int(text))
    }

    private func assertFixtureProcessesExited(
        in codexHome: URL,
        expectedCount: Int
    ) throws {
        let text = try String(
            contentsOf: codexHome.appendingPathComponent("fixture-pids"),
            encoding: .utf8
        )
        let pids = try text.split(whereSeparator: \.isNewline).map { value in
            try XCTUnwrap(Int32(value))
        }
        XCTAssertEqual(pids.count, expectedCount)
        for pid in pids {
            XCTAssertEqual(Darwin.kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    private static let telemetryFixtureScript = #"""
    #!/bin/sh
    echo 'this stderr text is deliberately discarded credential=fixture-marker' >&2
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1788264000}},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}'
          ;;
        *account*usage*read*)
          printf '%s\n' '{"id":4,"result":{"summary":{"lifetimeTokens":4200},"dailyUsageBuckets":[{"startDate":"2026-09-01","tokens":900}],"threadUsage":null}}'
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let slowTelemetryAndLogoutFixtureScript = #"""
    #!/bin/sh
    launch_file="$CODEX_HOME/fixture-launch-count"
    launch_count=1
    if [ -f "$launch_file" ]; then
      launch_count=$(( $(cat "$launch_file") + 1 ))
    fi
    printf '%s\n' "$launch_count" > "$launch_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*logout*)
          : > "$CODEX_HOME/logout-started"
          if [ -f "$CODEX_HOME/fail-logout" ]; then
            printf '%s\n' '{"id":2,"error":{"code":-32000,"message":"fixture logout failure"}}'
          else
            printf '%s\n' '{"id":2,"result":{}}'
          fi
          ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1788264000}},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}'
          ;;
        *account*usage*read*)
          printf '%s\n' '{"id":4,"result":{"summary":{"lifetimeTokens":4200},"dailyUsageBuckets":[{"startDate":"2026-09-01","tokens":900}],"threadUsage":null}}'
          ;;
        *account*read*)
          : > "$CODEX_HOME/telemetry-started"
          wait_count=0
          while [ ! -f "$CODEX_HOME/allow-telemetry" ] && [ "$wait_count" -lt 500 ]; do
            sleep 0.01
            wait_count=$((wait_count + 1))
          done
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let telemetryRetryFixtureScript = #"""
    #!/bin/sh
    attempt_file="$CODEX_HOME/fixture-attempt"
    pids_file="$CODEX_HOME/fixture-pids"
    attempt=1
    if [ -f "$attempt_file" ]; then
      attempt=$(( $(cat "$attempt_file") + 1 ))
    fi
    printf '%s\n' "$attempt" > "$attempt_file"
    printf '%s\n' "$$" >> "$pids_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          if [ "$attempt" -gt 1 ]; then
            printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1788264000}},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}'
          fi
          ;;
        *account*usage*read*)
          printf '%s\n' '{"id":4,"result":{"summary":{"lifetimeTokens":4200},"dailyUsageBuckets":[{"startDate":"2026-09-01","tokens":900}],"threadUsage":null}}'
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let telemetryAlwaysTimesOutFixtureScript = #"""
    #!/bin/sh
    attempt_file="$CODEX_HOME/fixture-attempt"
    pids_file="$CODEX_HOME/fixture-pids"
    attempt=1
    if [ -f "$attempt_file" ]; then
      attempt=$(( $(cat "$attempt_file") + 1 ))
    fi
    printf '%s\n' "$attempt" > "$attempt_file"
    printf '%s\n' "$$" >> "$pids_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let telemetryTransientRPCFailureFixtureScript = #"""
    #!/bin/sh
    attempt_file="$CODEX_HOME/fixture-attempt"
    pids_file="$CODEX_HOME/fixture-pids"
    attempt=1
    if [ -f "$attempt_file" ]; then
      attempt=$(( $(cat "$attempt_file") + 1 ))
    fi
    printf '%s\n' "$attempt" > "$attempt_file"
    printf '%s\n' "$$" >> "$pids_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":61,"windowDurationMins":300,"resetsAt":1788264000}},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}'
          ;;
        *account*usage*read*)
          if [ "$attempt" -eq 1 ]; then
            printf '%s\n' '{"id":4,"error":{"code":-32603,"message":"temporary fixture failure"}}'
          else
            printf '%s\n' '{"id":4,"result":{"summary":{"lifetimeTokens":4200},"dailyUsageBuckets":[{"startDate":"2026-09-01","tokens":900}],"threadUsage":null}}'
          fi
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let telemetryAlwaysRPCFailureFixtureScript = #"""
    #!/bin/sh
    attempt_file="$CODEX_HOME/fixture-attempt"
    pids_file="$CODEX_HOME/fixture-pids"
    attempt=1
    if [ -f "$attempt_file" ]; then
      attempt=$(( $(cat "$attempt_file") + 1 ))
    fi
    printf '%s\n' "$attempt" > "$attempt_file"
    printf '%s\n' "$$" >> "$pids_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"id":3,"error":{"code":-32603,"message":"temporary fixture failure"}}'
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let telemetryRPCFailureFixtureScript = #"""
    #!/bin/sh
    attempt_file="$CODEX_HOME/fixture-attempt"
    pids_file="$CODEX_HOME/fixture-pids"
    attempt=1
    if [ -f "$attempt_file" ]; then
      attempt=$(( $(cat "$attempt_file") + 1 ))
    fi
    printf '%s\n' "$attempt" > "$attempt_file"
    printf '%s\n' "$$" >> "$pids_file"
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"id":3,"error":{"code":-32000,"message":"fixture failure"}}'
          ;;
        *account*read*)
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
          ;;
      esac
    done
    """#

    private static let timeoutFixtureScript = #"""
    #!/bin/sh
    printf '%s\n' "$$" > "$CODEX_HOME/fixture.pid"
    trap '' TERM
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*)
          printf '{"id":1,"result":{"userAgent":"fixture","codexHome":"%s","platformFamily":"unix","platformOs":"macos"}}\n' "$CODEX_HOME"
          ;;
      esac
    done
    while :; do :; done
    """#
}

private enum FixtureWaitError: Error {
    case timedOut
}
