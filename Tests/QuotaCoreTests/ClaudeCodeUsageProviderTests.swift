import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeUsageProviderTests: XCTestCase {
    func testProviderMapsPlanAndModelSpecificSubscriptionWindowsWithoutDuplicates() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T12:00:00Z"))
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(
                loggedIn: true,
                authMethod: "claude.ai",
                apiProvider: "firstParty",
                email: "person@example.com",
                organizationID: "org-123",
                organizationName: "Personal",
                subscriptionType: "pro"
            ),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "max",
                rateLimitsAvailable: true,
                rateLimits: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(
                        utilization: 25.5,
                        resetsAt: "2026-09-04T15:00:00Z"
                    ),
                    sevenDay: ClaudeCodeRateLimitWindowDTO(
                        utilization: 60,
                        resetsAt: "2026-09-09T10:00:00.000Z"
                    ),
                    sevenDayOAuthApps: ClaudeCodeRateLimitWindowDTO(
                        utilization: 15,
                        resetsAt: "2026-09-08T10:00:00Z"
                    ),
                    sevenDayOpus: ClaudeCodeRateLimitWindowDTO(
                        utilization: 90,
                        resetsAt: "2026-09-10T10:00:00Z"
                    ),
                    sevenDaySonnet: ClaudeCodeRateLimitWindowDTO(
                        utilization: 80,
                        resetsAt: "2026-09-10T10:00:00Z"
                    ),
                    modelScoped: [
                        ClaudeCodeModelScopedWindowDTO(
                            displayName: "Opus",
                            utilization: 95,
                            resetsAt: "2026-09-10T10:00:00Z"
                        ),
                        ClaudeCodeModelScopedWindowDTO(
                            displayName: "Fable",
                            utilization: 40,
                            resetsAt: "2026-09-11T10:00:00Z"
                        )
                    ],
                    extraUsage: ClaudeCodeExtraUsageDTO(
                        isEnabled: true,
                        monthlyLimit: 10_000,
                        usedCredits: 1_250,
                        utilization: 12.5,
                        currency: "USD",
                        minorUnitExponent: 2
                    )
                )
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )
        let account = try makeAccount(kind: .claudeMax)

        let result = try await provider.fetchUsage(for: account, credential: nil, now: now)

        XCTAssertEqual(result.providerAccountLabel, "person@example.com")
        XCTAssertEqual(result.providerIdentityKey, "org:org-123")
        XCTAssertEqual(result.providerPlanLabel, "Max")
        XCTAssertEqual(result.resolvedAccountKind, .claudeMax)
        XCTAssertEqual(result.snapshot.source, .claudeCodeOAuth)
        XCTAssertEqual(result.snapshot.capturedAt, now)
        XCTAssertEqual(
            result.snapshot.quotaWindows.value?.map(\.identifier),
            [
                "five_hour",
                "seven_day",
                "seven_day_oauth_apps",
                "model_scoped:fable",
                "model_scoped:opus",
                "seven_day_sonnet"
            ]
        )
        XCTAssertEqual(
            result.snapshot.quotaWindows.value?.map(\.name),
            [
                "5-hour limit",
                "7-day limit · all models",
                "7-day limit · OAuth apps",
                "7-day limit · Fable",
                "7-day limit · Opus",
                "7-day limit · Sonnet"
            ]
        )
        XCTAssertEqual(
            result.snapshot.quotaWindows.value?.map(\.usedPercent),
            [25.5, 60, 15, 40, 95, 80]
        )
        XCTAssertEqual(
            result.snapshot.quotaWindows.value?.map(\.durationMinutes),
            [300, 10_080, 10_080, 10_080, 10_080, 10_080]
        )
        XCTAssertEqual(
            result.snapshot.resetAt.value,
            ISO8601DateFormatter().date(from: "2026-09-04T15:00:00Z")
        )
        XCTAssertEqual(result.snapshot.allowance.value?.used, 12.5)
        XCTAssertEqual(result.snapshot.allowance.value?.limit, 100)
        XCTAssertEqual(result.snapshot.allowance.value?.unit, .dollars)
        XCTAssertEqual(result.snapshot.bankedResetCredits.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.totalTokens.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.inputTokens.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.cachedInputTokens.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.outputTokens.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.requests.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.costUSD.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.modelUsage.unavailability?.reason, .notExposedByProvider)
        XCTAssertEqual(result.snapshot.dailyUsage.unavailability?.reason, .notExposedByProvider)
    }

    func testProviderDoesNotMixClaudeEmailAndOrganizationIdentityNamespaces() async throws {
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(
                loggedIn: true,
                authMethod: "claude.ai",
                email: "person@example.com",
                organizationID: nil,
                subscriptionType: "pro"
            ),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "pro",
                rateLimitsAvailable: true,
                rateLimits: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(
                        utilization: 10,
                        resetsAt: nil
                    ),
                    sevenDay: nil
                )
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )

        let result = try await provider.fetchUsage(
            for: makeAccount(kind: .claudePro),
            credential: nil,
            now: Date()
        )

        XCTAssertEqual(result.providerAccountLabel, "person@example.com")
        XCTAssertNil(result.providerIdentityKey)
    }

    func testProviderFallsBackToTwoDecimalPlacesForUSDExtraUsage() async throws {
        let allowance = try await fetchExtraUsageAllowance(
            ClaudeCodeExtraUsageDTO(
                isEnabled: true,
                monthlyLimit: 2_000,
                usedCredits: 207,
                utilization: 10.35,
                currency: "USD"
            )
        )

        XCTAssertEqual(allowance.value?.used ?? 0, 2.07, accuracy: 0.000_001)
        XCTAssertEqual(allowance.value?.limit, 20)
        XCTAssertEqual(allowance.value?.unit, .dollars)
    }

    func testProviderHonorsReportedUSDMinorUnitExponent() async throws {
        let allowance = try await fetchExtraUsageAllowance(
            ClaudeCodeExtraUsageDTO(
                isEnabled: true,
                monthlyLimit: 20_000,
                usedCredits: 1_250,
                utilization: 6.25,
                currency: "USD",
                minorUnitExponent: 3
            )
        )

        XCTAssertEqual(allowance.value?.used, 1.25)
        XCTAssertEqual(allowance.value?.limit, 20)
        XCTAssertEqual(allowance.value?.unit, .dollars)
    }

    func testProviderDoesNotAssumeCurrencyUnitsWhenCurrencyIsMissing() async throws {
        let allowance = try await fetchExtraUsageAllowance(
            ClaudeCodeExtraUsageDTO(
                isEnabled: true,
                monthlyLimit: 2_000,
                usedCredits: 207,
                utilization: 10.35,
                currency: nil,
                minorUnitExponent: 2
            )
        )

        XCTAssertEqual(allowance.value?.used, 207)
        XCTAssertEqual(allowance.value?.limit, 2_000)
        XCTAssertEqual(allowance.value?.unit, .credits)
    }

    func testProviderPreservesUnavailableExtraUsageWithoutReportedLimit() async throws {
        let allowance = try await fetchExtraUsageAllowance(
            ClaudeCodeExtraUsageDTO(
                isEnabled: true,
                monthlyLimit: nil,
                usedCredits: 207,
                utilization: nil,
                currency: "USD",
                minorUnitExponent: 2
            )
        )

        XCTAssertEqual(allowance.unavailability?.reason, .notExposedByProvider)
        XCTAssertNil(allowance.value)
    }

    func testReportedPlanResolvesProAndMaxVariantsWithoutGuessingUnknownTiers() {
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts")
        )

        XCTAssertEqual(provider.resolvedAccountKind(from: "pro"), .claudePro)
        XCTAssertEqual(provider.resolvedAccountKind(from: "max_20x"), .claudeMax)
        XCTAssertNil(provider.resolvedAccountKind(from: "enterprise"))
    }

    func testProviderRejectsReportedTeamOrEnterpriseSubscription() async throws {
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(
                loggedIn: true,
                authMethod: "claude.ai",
                subscriptionType: "team"
            ),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "team",
                rateLimitsAvailable: true,
                rateLimits: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(utilization: 10, resetsAt: nil),
                    sevenDay: nil
                )
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .claudePro),
                credential: nil,
                now: Date()
            )
            XCTFail("Expected unsupported Claude subscription tier to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ClaudeCodeConnectorError,
                .unsupportedSubscriptionPlan
            )
        }
    }

    func testProviderRejectsLoggedOutAndNonSubscriptionAuthentication() async throws {
        let account = try makeAccount(kind: .claudeMax)
        let directory = URL(fileURLWithPath: "/private/tmp/claude-accounts")
        let emptyUsage = ClaudeCodeUsageDTO(
            subscriptionType: nil,
            rateLimitsAvailable: false,
            rateLimits: nil
        )

        let loggedOut = ClaudeCodeUsageProvider(
            accountsDirectoryURL: directory,
            connectorFactory: { _ in
                StubClaudeCodeConnector(
                    status: ClaudeCodeAuthStatusDTO(loggedIn: false, authMethod: "none"),
                    usage: emptyUsage
                )
            }
        )
        do {
            _ = try await loggedOut.fetchUsage(for: account, credential: nil, now: Date())
            XCTFail("Expected a logged-out account to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .notAuthenticated)
        }

        let apiKey = ClaudeCodeUsageProvider(
            accountsDirectoryURL: directory,
            connectorFactory: { _ in
                StubClaudeCodeConnector(
                    status: ClaudeCodeAuthStatusDTO(loggedIn: true, authMethod: "api_key"),
                    usage: emptyUsage
                )
            }
        )
        do {
            _ = try await apiKey.fetchUsage(for: account, credential: nil, now: Date())
            XCTFail("Expected API-key authentication to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .unsupportedAuthenticationMode)
        }
    }

    func testProviderFailsRefreshWhenRateLimitsAreTemporarilyUnavailable() async throws {
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(loggedIn: true, authMethod: "claude.ai"),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "max",
                rateLimitsAvailable: false,
                rateLimits: nil
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .claudeMax),
                credential: nil,
                now: Date()
            )
            XCTFail("Expected unavailable rate limits to preserve the prior successful reading")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .usageUnavailable)
        }
    }

    func testProviderFailsRefreshWhenSupportedWindowsAreMissing() async throws {
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(loggedIn: true, authMethod: "claude.ai"),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "max",
                rateLimitsAvailable: true,
                rateLimits: ClaudeCodeRateLimitsDTO(fiveHour: nil, sevenDay: nil)
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )

        do {
            _ = try await provider.fetchUsage(
                for: makeAccount(kind: .claudeMax),
                credential: nil,
                now: Date()
            )
            XCTFail("Expected protocol drift to preserve the prior successful reading")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeConnectorError, .usageUnavailable)
        }
    }

    func testProviderRejectsInvalidUtilizationAndResetDate() throws {
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts")
        )

        XCTAssertThrowsError(
            try provider.makeQuotaWindows(
                from: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(utilization: 101, resetsAt: nil),
                    sevenDay: nil
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try provider.makeQuotaWindows(
                from: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(
                        utilization: 20,
                        resetsAt: "not-a-date"
                    ),
                    sevenDay: nil
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testManagedClaudeRefreshDoesNotReadQuotaCredentialStore() async throws {
        let account = try makeAccount(kind: .claudeMax)
        let service = UsageRefreshService(
            registry: UsageProviderRegistry(providers: [ManagedClaudeFixtureProvider()]),
            credentialStore: FailOnUseCredentialStore()
        )

        let result = try await service.refresh(account: account)

        XCTAssertEqual(result.snapshot.accountID, account.id)
        XCTAssertEqual(result.snapshot.source, .claudeCodeOAuth)
    }

    func testAccountDirectoryIsStableAndAccountSpecific() {
        let base = URL(fileURLWithPath: "/private/tmp/claude-accounts", isDirectory: true)
        let accountID = UUID(uuidString: "58A8EF4D-A061-4889-BEB5-F5D4A38CFD3A")!
        let provider = ClaudeCodeUsageProvider(accountsDirectoryURL: base)

        XCTAssertEqual(
            provider.configurationDirectoryURL(for: accountID).path,
            "/private/tmp/claude-accounts/58a8ef4d-a061-4889-beb5-f5d4a38cfd3a"
        )
    }

    private func fetchExtraUsageAllowance(
        _ extraUsage: ClaudeCodeExtraUsageDTO
    ) async throws -> Metric<Allowance> {
        let connector = StubClaudeCodeConnector(
            status: ClaudeCodeAuthStatusDTO(
                loggedIn: true,
                authMethod: "claude.ai",
                subscriptionType: "max"
            ),
            usage: ClaudeCodeUsageDTO(
                subscriptionType: "max",
                rateLimitsAvailable: true,
                rateLimits: ClaudeCodeRateLimitsDTO(
                    fiveHour: ClaudeCodeRateLimitWindowDTO(
                        utilization: 1,
                        resetsAt: nil
                    ),
                    sevenDay: nil,
                    extraUsage: extraUsage
                )
            )
        )
        let provider = ClaudeCodeUsageProvider(
            accountsDirectoryURL: URL(fileURLWithPath: "/private/tmp/claude-accounts"),
            connectorFactory: { _ in connector }
        )
        let result = try await provider.fetchUsage(
            for: makeAccount(kind: .claudeMax),
            credential: nil,
            now: Date()
        )
        return result.snapshot.allowance
    }
}

private struct StubClaudeCodeConnector: ClaudeCodeConnecting {
    let status: ClaudeCodeAuthStatusDTO
    let usage: ClaudeCodeUsageDTO

    func authenticationStatus() async throws -> ClaudeCodeAuthStatusDTO {
        status
    }

    func readSubscriptionUsage() async throws -> ClaudeCodeSubscriptionUsage {
        guard status.loggedIn else {
            throw ClaudeCodeConnectorError.notAuthenticated
        }
        guard status.isClaudeSubscriptionAuthentication else {
            throw ClaudeCodeConnectorError.unsupportedAuthenticationMode
        }
        return ClaudeCodeSubscriptionUsage(status: status, usage: usage)
    }

    func logout() async throws {}
}

private struct ManagedClaudeFixtureProvider: UsageProvider {
    let dataSourceKind: UsageDataSourceKind = .claudeCodeOAuth

    func fetchUsage(
        for account: ConnectedAccount,
        credential: ProviderCredential?,
        now: Date
    ) async throws -> ProviderFetchResult {
        XCTAssertNil(credential)
        return ProviderFetchResult(
            snapshot: UsageSnapshot.awaitingRefresh(
                accountID: account.id,
                source: .claudeCodeOAuth,
                at: now
            )
        )
    }
}

private enum CredentialUseFixtureError: Error {
    case unexpectedlyUsed
}

private struct FailOnUseCredentialStore: CredentialStoring {
    func save(_ credential: ProviderCredential, for accountID: UUID) throws {
        throw CredentialUseFixtureError.unexpectedlyUsed
    }

    func credential(for accountID: UUID) throws -> ProviderCredential? {
        throw CredentialUseFixtureError.unexpectedlyUsed
    }

    func deleteCredential(for accountID: UUID) throws {
        throw CredentialUseFixtureError.unexpectedlyUsed
    }
}
