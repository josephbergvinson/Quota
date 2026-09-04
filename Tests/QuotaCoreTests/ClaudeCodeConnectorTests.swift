import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeConnectorTests: XCTestCase {
    func testAuthStatusDecodesLoggedInSubscriptionMetadata() throws {
        let data = Data(
            #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/private/account/projects","email":"person@example.com","orgId":"org-123","orgName":"Personal","subscriptionType":"max"}"#.utf8
        )

        let status = try JSONDecoder().decode(ClaudeCodeAuthStatusDTO.self, from: data)

        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.authMethod, "claude.ai")
        XCTAssertEqual(status.email, "person@example.com")
        XCTAssertEqual(status.organizationID, "org-123")
        XCTAssertEqual(status.organizationName, "Personal")
        XCTAssertEqual(status.subscriptionType, "max")
        XCTAssertTrue(status.isClaudeSubscriptionAuthentication)
    }

    func testAuthStatusDecodesLoggedOutResponseWithoutOptionalIdentity() throws {
        let data = Data(
            #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/private/account/projects"}"#.utf8
        )

        let status = try JSONDecoder().decode(ClaudeCodeAuthStatusDTO.self, from: data)

        XCTAssertFalse(status.loggedIn)
        XCTAssertNil(status.email)
        XCTAssertFalse(status.isClaudeSubscriptionAuthentication)
    }

    func testUsageParserRequiresMatchingSuccessfulControlResponse() throws {
        let data = Data(
            """
            {"type":"system","subtype":"init"}
            {"type":"control_response","response":{"subtype":"success","request_id":"other","response":{"subscription_type":"pro","rate_limits_available":false,"rate_limits":null}}}
            {"type":"control_response","response":{"subtype":"success","request_id":"quota-probe","response":{"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":25.5,"resets_at":"2026-09-04T15:00:00Z"},"seven_day":{"utilization":60,"resets_at":"2026-09-09T10:00:00.000Z"},"seven_day_opus":{"utilization":99,"resets_at":"2026-09-10T10:00:00Z"},"model_scoped":[{"display_name":"Fable","utilization":72,"resets_at":"2026-09-10T11:00:00Z"}],"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":1250,"utilization":12.5,"currency":"USD","decimal_places":2}},"behaviors":null}}}
            """.utf8
        )

        let usage = try ClaudeCodeUsageResponseParser.parse(data, matching: "quota-probe")

        XCTAssertEqual(usage.subscriptionType, "max")
        XCTAssertTrue(usage.rateLimitsAvailable)
        XCTAssertEqual(usage.rateLimits?.fiveHour?.utilization, 25.5)
        XCTAssertEqual(usage.rateLimits?.sevenDay?.utilization, 60)
        XCTAssertEqual(usage.rateLimits?.sevenDayOpus?.utilization, 99)
        XCTAssertEqual(usage.rateLimits?.modelScoped.first?.displayName, "Fable")
        XCTAssertEqual(usage.rateLimits?.extraUsage?.currency, "USD")
        XCTAssertEqual(usage.rateLimits?.extraUsage?.minorUnitExponent, 2)
    }

    func testUsageParserTreatsNoMatchingResponseAsUnsupported() {
        XCTAssertThrowsError(
            try ClaudeCodeUsageResponseParser.parse(Data(), matching: "quota-probe")
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .unsupportedUsageProtocol)
        }
    }

    func testUsageParserRejectsMatchedFailureResponse() {
        let data = Data(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"quota-probe","response":null}}"#.utf8
        )

        XCTAssertThrowsError(
            try ClaudeCodeUsageResponseParser.parse(data, matching: "quota-probe")
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .invalidResponse)
        }
    }

    func testClaudeEnvironmentIsAllowlistedAndAccountScoped() {
        let directory = URL(fileURLWithPath: "/private/tmp/quota-account", isDirectory: true)
        let environment = sanitizedClaudeEnvironment(
            configurationDirectoryURL: directory,
            parentEnvironment: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_GB.UTF-8",
                "ANTHROPIC_API_KEY": "must-not-leak",
                "ANTHROPIC_AUTH_TOKEN": "must-not-leak",
                "CLAUDE_CODE_OAUTH_TOKEN": "must-not-leak",
                "CLAUDE_CODE_USE_BEDROCK": "1",
                "AWS_SECRET_ACCESS_KEY": "must-not-leak"
            ]
        )

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(environment["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
    }

    func testProfileCoordinationKeyNormalizesSystemAndCaseAliases() {
        XCTAssertEqual(
            claudeProfileCoordinationKey(
                URL(fileURLWithPath: "/tmp/Quota-Profile", isDirectory: true)
            ),
            claudeProfileCoordinationKey(
                URL(fileURLWithPath: "/private/tmp/quota-profile", isDirectory: true)
            )
        )
    }

    func testProfileCoordinationPathFoldsOnlyKnownCaseInsensitiveVolumes() {
        let upper = "/Volumes/Provider/Quota-Profile"
        let lower = "/Volumes/Provider/quota-profile"
        XCTAssertEqual(
            normalizedClaudeProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: false
            ),
            normalizedClaudeProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: false
            )
        )
        XCTAssertNotEqual(
            normalizedClaudeProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: true
            ),
            normalizedClaudeProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: true
            )
        )
        XCTAssertNotEqual(
            normalizedClaudeProfileCoordinationPath(
                upper,
                volumeSupportsCaseSensitiveNames: nil
            ),
            normalizedClaudeProfileCoordinationPath(
                lower,
                volumeSupportsCaseSensitiveNames: nil
            )
        )
    }

    func testExecutableLocatorSelectsNewestCompatibleSignedCandidate() throws {
        let old = URL(fileURLWithPath: "/private/home/.local/share/claude/versions/2.1.11")
        let desktop = URL(
            fileURLWithPath: "/private/Claude/claude-code/2.1.258/claude.app/Contents/MacOS/claude"
        )
        let newest = URL(fileURLWithPath: "/private/home/.local/share/claude/versions/2.1.260")

        let selected = try ClaudeCodeExecutableLocator.selectNewestCompatible(
            from: [old, desktop, newest],
            isExecutable: { _ in true },
            isTrusted: { _ in true }
        )

        XCTAssertEqual(selected, newest)
    }

    func testExecutableLocatorRejectsOnlyOldSignedVersions() {
        XCTAssertThrowsError(
            try ClaudeCodeExecutableLocator.selectNewestCompatible(
                from: [
                    URL(
                        fileURLWithPath: "/private/home/.local/share/claude/versions/2.1.11"
                    )
                ],
                isExecutable: { _ in true },
                isTrusted: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .unsupportedClaudeCodeVersion)
        }
    }

    func testExecutableLocatorRejectsUnsignedExecutable() {
        XCTAssertThrowsError(
            try ClaudeCodeExecutableLocator.selectNewestCompatible(
                from: [URL(fileURLWithPath: "/private/native/2.1.260/claude")],
                isExecutable: { _ in true },
                isTrusted: { _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .untrustedExecutable)
        }
    }

    func testExecutableLocatorRejectsSignedCandidateWithoutVersion() {
        XCTAssertThrowsError(
            try ClaudeCodeExecutableLocator.selectNewestCompatible(
                from: [URL(fileURLWithPath: "/private/Claude/claude")],
                isExecutable: { _ in true },
                isTrusted: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .unsupportedClaudeCodeVersion)
        }
    }

    func testExecutableLocatorIgnoresSemverOutsideOfficialInstallLayout() {
        XCTAssertThrowsError(
            try ClaudeCodeExecutableLocator.selectNewestCompatible(
                from: [URL(fileURLWithPath: "/private/2.1.999/copied/claude")],
                isExecutable: { _ in true },
                isTrusted: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .unsupportedClaudeCodeVersion)
        }
    }

    func testRetiringProfileRejectsQueuedAndFutureOperations() async {
        let coordinator = ClaudeCodeProfileOperationCoordinator()
        let profileKey = "/private/tmp/claude-profile-\(UUID().uuidString)"

        let initialAcquisition = await coordinator.acquire(profileKey: profileKey)
        XCTAssertTrue(initialAcquisition)
        let queuedOperation = Task {
            await coordinator.acquire(profileKey: profileKey)
        }
        while await coordinator.queuedOperationCount(profileKey: profileKey) == 0 {
            await Task.yield()
        }

        let retirement = Task {
            await coordinator.retireAndAcquire(profileKey: profileKey)
        }
        while await !coordinator.isRetired(profileKey: profileKey) {
            await Task.yield()
        }

        let queuedAcquisition = await queuedOperation.value
        XCTAssertFalse(queuedAcquisition)
        await coordinator.release(profileKey: profileKey)
        await retirement.value
        await coordinator.release(profileKey: profileKey)
        let futureAcquisition = await coordinator.acquire(profileKey: profileKey)
        XCTAssertFalse(futureAcquisition)
    }

    func testRetiredProfileCanBeReactivatedAfterAbortedRemoval() async {
        let coordinator = ClaudeCodeProfileOperationCoordinator()
        let profileKey = "/private/tmp/claude-profile-\(UUID().uuidString)"

        await coordinator.retireAndAcquire(profileKey: profileKey)
        await coordinator.release(profileKey: profileKey)
        let retiredAcquisition = await coordinator.acquire(profileKey: profileKey)
        XCTAssertFalse(retiredAcquisition)

        await coordinator.reactivate(profileKey: profileKey)
        let reactivatedAcquisition = await coordinator.acquire(profileKey: profileKey)
        XCTAssertTrue(reactivatedAcquisition)
        await coordinator.release(profileKey: profileKey)
    }

    func testCancellingQueuedProfileOperationRemovesItPromptly() async {
        let coordinator = ClaudeCodeProfileOperationCoordinator()
        let profileKey = "/private/tmp/claude-profile-\(UUID().uuidString)"

        let initialAcquisition = await coordinator.acquire(profileKey: profileKey)
        XCTAssertTrue(initialAcquisition)
        let queuedOperation = Task {
            await coordinator.acquire(profileKey: profileKey)
        }
        while await coordinator.queuedOperationCount(profileKey: profileKey) == 0 {
            await Task.yield()
        }

        queuedOperation.cancel()
        let queuedAcquisition = await queuedOperation.value
        let queuedOperationCount = await coordinator.queuedOperationCount(profileKey: profileKey)

        XCTAssertFalse(queuedAcquisition)
        XCTAssertEqual(queuedOperationCount, 0)
        await coordinator.release(profileKey: profileKey)
    }

    func testProcessReaderCapturesFinalOutputBeforeReturning() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/bin/sh"),
            configurationDirectoryURL: temporaryDirectory
        )
        let expected = String(repeating: "final-chunk", count: 8_192)

        let result = try await ClaudeCodeProcess.run(
            configuration: configuration,
            arguments: ["-c", "printf %s \"$1\"", "quota-test", expected],
            standardInput: nil,
            captureOutput: true,
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), expected)
    }

    func testProcessWithoutCapturedOutputCompletesNormally() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            configurationDirectoryURL: temporaryDirectory
        )

        let result = try await ClaudeCodeProcess.run(
            configuration: configuration,
            arguments: [],
            standardInput: nil,
            captureOutput: false,
            timeoutSeconds: 1
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testProcessReaderRejectsOutputBeyondHardLimit() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/usr/bin/head"),
            configurationDirectoryURL: temporaryDirectory
        )

        do {
            _ = try await ClaudeCodeProcess.run(
                configuration: configuration,
                arguments: [
                    "-c",
                    String(ClaudeCodeProcess.maximumCapturedOutputBytes + 1),
                    "/dev/zero"
                ],
                standardInput: nil,
                captureOutput: true,
                timeoutSeconds: 5
            )
            XCTFail("Expected oversized output to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .outputTooLarge)
        }
    }

    func testProcessRejectsSymlinkedConfigurationDirectoryComponents() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let realParent = temporaryDirectory.appendingPathComponent("real", isDirectory: true)
        let linkedParent = temporaryDirectory.appendingPathComponent("linked", isDirectory: true)
        let realChild = realParent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realChild,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            configurationDirectoryURL: linkedParent
                .appendingPathComponent("child", isDirectory: true)
                .appendingPathComponent("account", isDirectory: true)
        )

        do {
            _ = try await ClaudeCodeProcess.run(
                configuration: configuration,
                arguments: [],
                standardInput: nil,
                captureOutput: false,
                timeoutSeconds: 1
            )
            XCTFail("Expected a symlinked profile ancestor to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .invalidConfigurationDirectory)
        }
    }

    func testProcessTimeoutAlsoBoundsOutputInheritedByAChildProcess() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/bin/sh"),
            configurationDirectoryURL: temporaryDirectory
        )
        let startedAt = Date()

        do {
            _ = try await ClaudeCodeProcess.run(
                configuration: configuration,
                arguments: ["-c", "trap '' HUP; sleep 3 & exit 0"],
                standardInput: nil,
                captureOutput: true,
                timeoutSeconds: 0.15
            )
            XCTFail("Expected the inherited output pipe to respect the operation timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .requestTimedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testProcessCancellationAllowsTermHandlerToFinish() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let markerURL = temporaryDirectory.appendingPathComponent("terminated.txt")
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: URL(fileURLWithPath: "/bin/sh"),
            configurationDirectoryURL: temporaryDirectory
        )
        let process = try ClaudeCodeProcess.launch(
            configuration: configuration,
            arguments: [
                "-c",
                "trap 'printf terminated > \"$1\"; exit 0' TERM; while :; do :; done",
                "quota-test",
                markerURL.path
            ],
            standardInput: nil,
            captureOutput: false
        )

        try await Task.sleep(for: .milliseconds(100))
        await process.cancel()

        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "terminated")
    }

    func testManagedLoginSubmitsFallbackCodeToTheSameRunningProcess() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              if [ -f "$CLAUDE_CONFIG_DIR/logged-in" ]; then
                printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"max"}'
              else
                printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              fi
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              printf '%s\\n' "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?flow=test"
              IFS= read -r code || exit 2
              [ "$code" = 'abc#state' ] || exit 3
              : > "$CLAUDE_CONFIG_DIR/logged-in"
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let configuration = try ClaudeCodeConfiguration(
            trustedExecutableURL: executableURL,
            configurationDirectoryURL: temporaryDirectory,
            requestTimeoutSeconds: 2,
            loginTimeoutSeconds: 5
        )
        let connector = ClaudeCodeConnector(configuration: configuration)
        let initialStatus = try await connector.authenticationStatus()
        XCTAssertFalse(initialStatus.loggedIn)
        let session = try await connector.startManagedLogin()

        let fallbackURL = try await session.manualAuthorizationURL()
        XCTAssertEqual(fallbackURL.host, "claude.com")
        XCTAssertEqual(fallbackURL.path, "/cai/oauth/authorize")
        let completion = Task { try await session.waitForCompletion() }
        try await session.submitManualAuthorizationCode("abc#state")
        let status = try await completion.value

        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.email, "person@example.com")
        XCTAssertEqual(status.subscriptionType, "max")
    }

    func testManagedLoginWaitsForHelperCleanupAfterBrowserAuthSucceeds() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              if [ -f "$CLAUDE_CONFIG_DIR/logged-in" ]; then
                printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}'
              else
                printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              fi
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              : > "$CLAUDE_CONFIG_DIR/logged-in"
              sleep 0.2
              : > "$CLAUDE_CONFIG_DIR/login-cleanup-finished"
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 2,
                loginTimeoutSeconds: 5
            )
        )

        let initialStatus = try await connector.authenticationStatus()
        XCTAssertFalse(initialStatus.loggedIn)
        let session = try await connector.startManagedLogin()
        let status = try await session.waitForCompletion()

        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.subscriptionType, "pro")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.appendingPathComponent("login-cleanup-finished").path
            )
        )
    }

    func testManagedLoginRecoversCommittedAuthenticationAfterHelperTimeout() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              if [ -f "$CLAUDE_CONFIG_DIR/logged-in" ]; then
                printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
              else
                printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              fi
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              : > "$CLAUDE_CONFIG_DIR/logged-in"
              sleep 5
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 1,
                loginTimeoutSeconds: 0.2
            )
        )

        let session = try await connector.startManagedLogin()
        let status = try await session.waitForCompletion()

        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.subscriptionType, "max")
    }

    func testManagedLoginDoesNotTreatExistingAuthenticationAsTimeoutRecovery() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"old@example.com","subscriptionType":"max"}'
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              sleep 5
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 1,
                loginTimeoutSeconds: 0.2
            )
        )

        let session = try await connector.startManagedLogin()
        do {
            _ = try await session.waitForCompletion()
            XCTFail("Expected the uncompleted replacement sign-in to time out")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .loginTimedOut)
        }
    }

    func testManagedLoginRetriesVerificationAfterSuccessfulHelperExit() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              count=0
              if [ -f "$CLAUDE_CONFIG_DIR/status-count" ]; then
                count=$(cat "$CLAUDE_CONFIG_DIR/status-count")
              fi
              count=$((count + 1))
              printf '%s' "$count" > "$CLAUDE_CONFIG_DIR/status-count"
              if [ "$count" -eq 2 ]; then
                sleep 5
                exit 0
              fi
              printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"pro"}'
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 1,
                loginTimeoutSeconds: 2
            )
        )

        let session = try await connector.startManagedLogin()
        let status = try await session.waitForCompletion()

        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.email, "person@example.com")
        XCTAssertEqual(status.subscriptionType, "pro")
    }

    func testCancellingManagedLoginReleasesProfileForFutureOperations() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              trap 'exit 0' TERM
              while :; do sleep 0.1; done
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 1,
                loginTimeoutSeconds: 5
            )
        )
        let session = try await connector.startManagedLogin()
        let completion = Task { try await session.waitForCompletion() }

        try await Task.sleep(for: .milliseconds(100))
        await session.cancel()

        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let statusAfterCancellation = try await connector.authenticationStatus()
        XCTAssertFalse(statusAfterCancellation.loggedIn)
    }

    func testRetiringProfileDuringLoginPreflightPreventsBrowserLaunch() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let preflightStartedURL = temporaryDirectory.appendingPathComponent("preflight-started")
        let allowPreflightURL = temporaryDirectory.appendingPathComponent("allow-preflight")
        let loginStartedURL = temporaryDirectory.appendingPathComponent("login-started")
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              : > "$CLAUDE_CONFIG_DIR/preflight-started"
              while [ ! -f "$CLAUDE_CONFIG_DIR/allow-preflight" ]; do sleep 0.02; done
              printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              : > "$CLAUDE_CONFIG_DIR/login-started"
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 2,
                loginTimeoutSeconds: 5
            )
        )
        let profileKey = claudeProfileCoordinationKey(temporaryDirectory)
        let login = Task { try await connector.startManagedLogin() }
        while !FileManager.default.fileExists(atPath: preflightStartedURL.path) {
            await Task.yield()
        }
        let retirement = Task {
            await ClaudeCodeProfileOperationCoordinator.shared.retireAndAcquire(
                profileKey: profileKey
            )
            await ClaudeCodeProfileOperationCoordinator.shared.release(profileKey: profileKey)
        }
        while await !ClaudeCodeProfileOperationCoordinator.shared.isRetired(
            profileKey: profileKey
        ) {
            await Task.yield()
        }
        try Data().write(to: allowPreflightURL)

        do {
            _ = try await login.value
            XCTFail("Expected profile retirement to abort sign-in")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .profileRetired)
        }
        await retirement.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: loginStartedURL.path))
    }

    func testManagedLoginDoesNotWaitForOutputPipeInheritedByExitedHelperChild() async throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("quota-claude-login-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = try makeExecutable(
            in: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            source: """
            #!/bin/sh
            if [ "$*" = "auth status --json" ]; then
              if [ -f "$CLAUDE_CONFIG_DIR/logged-in" ]; then
                printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}'
              else
                printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
              fi
              exit 0
            fi
            if [ "$*" = "auth login --claudeai" ]; then
              : > "$CLAUDE_CONFIG_DIR/logged-in"
              sleep 2 &
              exit 0
            fi
            exit 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }
        let connector = ClaudeCodeConnector(
            configuration: try ClaudeCodeConfiguration(
                trustedExecutableURL: executableURL,
                configurationDirectoryURL: temporaryDirectory,
                requestTimeoutSeconds: 1,
                loginTimeoutSeconds: 5
            )
        )
        let startedAt = Date()

        let session = try await connector.startManagedLogin()
        let status = try await session.waitForCompletion()

        XCTAssertTrue(status.loggedIn)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testLoginOutputParserPublishesOnlyAllowedOAuthURLs() {
        let state = ClaudeCodeLoginOutputState()
        state.consume(Data("If the browser didn't open, ".utf8))
        state.consume(
            Data("visit: https://claude.com/cai/oauth/authorize?flow=one\\n".utf8)
        )
        XCTAssertEqual(state.authorizationURL()?.host, "claude.com")

        let wrongHostState = ClaudeCodeLoginOutputState()
        wrongHostState.consume(
            Data("If the browser didn't open, visit: https://example.com/oauth/steal?state=secret\\n".utf8)
        )
        XCTAssertNil(wrongHostState.authorizationURL())

        let insecureState = ClaudeCodeLoginOutputState()
        insecureState.consume(
            Data("If the browser didn't open, visit: http://claude.ai/oauth/code?state=secret\\n".utf8)
        )
        XCTAssertNil(insecureState.authorizationURL())

        let wrongPathState = ClaudeCodeLoginOutputState()
        wrongPathState.consume(
            Data("If the browser didn't open, visit: https://claude.com/not-oauth?state=secret\\n".utf8)
        )
        XCTAssertNil(wrongPathState.authorizationURL())
    }

    func testClosedLoginOutputStateCannotBeRepopulated() {
        let state = ClaudeCodeLoginOutputState()
        state.close()

        state.consume(
            Data("If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?state=secret\\n".utf8)
        )

        XCTAssertNil(state.authorizationURL())
    }

    func testManualAuthorizationCodeValidationRejectsMalformedOrOversizedInput() throws {
        XCTAssertEqual(
            try ClaudeCodeManagedLoginSession.validatedManualAuthorizationCode("  abc#state  "),
            "abc#state"
        )
        for invalid in ["", "missing-state", "#state", "abc#", "abc#state#extra", "abc#state\nother"] {
            XCTAssertThrowsError(
                try ClaudeCodeManagedLoginSession.validatedManualAuthorizationCode(invalid)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeCodeConnectorError,
                    .invalidManualAuthorizationCode
                )
            }
        }
        let oversized = String(repeating: "a", count: 8 * 1_024) + "#state"
        XCTAssertThrowsError(
            try ClaudeCodeManagedLoginSession.validatedManualAuthorizationCode(oversized)
        ) { error in
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .invalidManualAuthorizationCode)
        }
    }

    private func makeExecutable(in directory: URL, source: String) throws -> URL {
        let executableURL = directory.appendingPathComponent(
            "quota-claude-fixture-\(UUID().uuidString)"
        )
        try source.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        return executableURL
    }
}
