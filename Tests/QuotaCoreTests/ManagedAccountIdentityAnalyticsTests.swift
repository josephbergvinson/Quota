import XCTest
@testable import QuotaCore

final class ManagedAccountIdentityAnalyticsTests: XCTestCase {
    func testManagedAccountsWithoutVerifiedIdentityAreIneligible() throws {
        let claude = try makeAccount(name: "Claude", kind: .claudeMax)
        let chatGPT = try makeAccount(name: "ChatGPT", kind: .chatGPTPlus)
        let api = try makeAccount(name: "Anthropic API", kind: .anthropicAPI)

        let result = UsageAnalytics.managedAccountIdentityAssessment(
            accounts: [claude, chatGPT, api],
            identityKeys: [:]
        )

        XCTAssertEqual(result.unverifiedAccountIDs, [claude.id, chatGPT.id])
        XCTAssertEqual(result.ineligibleAccountIDs, [claude.id, chatGPT.id])
        XCTAssertTrue(result.duplicateAccountIDsByAccount.isEmpty)
    }

    func testDuplicateIdentityIsScopedToProviderAndExcludesBothRows() throws {
        let firstClaude = try makeAccount(name: "Claude one", kind: .claudePro)
        let secondClaude = try makeAccount(name: "Claude two", kind: .claudeMax)
        let chatGPT = try makeAccount(name: "ChatGPT", kind: .chatGPTPro)
        let sharedID = "1d5920d1-2b7c-4d17-ae69-d90baf186e30"
        let sharedKey = "org:\(sharedID)"

        let result = UsageAnalytics.managedAccountIdentityAssessment(
            accounts: [firstClaude, secondClaude, chatGPT],
            identityKeys: [
                firstClaude.id: sharedKey,
                secondClaude.id: " ORG:\(sharedID.uppercased()) ",
                chatGPT.id: sharedKey
            ]
        )

        XCTAssertEqual(
            result.duplicateAccountIDsByAccount[firstClaude.id],
            [secondClaude.id]
        )
        XCTAssertEqual(
            result.duplicateAccountIDsByAccount[secondClaude.id],
            [firstClaude.id]
        )
        XCTAssertNil(result.duplicateAccountIDsByAccount[chatGPT.id])
        XCTAssertEqual(result.ineligibleAccountIDs, [firstClaude.id, secondClaude.id])
    }

    func testCaseDistinctOpaqueOrganizationIdentifiersDoNotCollide() throws {
        let first = try makeAccount(name: "Claude one", kind: .claudePro)
        let second = try makeAccount(name: "Claude two", kind: .claudeMax)

        let result = UsageAnalytics.managedAccountIdentityAssessment(
            accounts: [first, second],
            identityKeys: [
                first.id: "org:opaque-ID",
                second.id: "ORG:opaque-id"
            ]
        )

        XCTAssertTrue(result.duplicateAccountIDsByAccount.isEmpty)
        XCTAssertTrue(result.ineligibleAccountIDs.isEmpty)
    }

    func testEmailIdentityNormalizationIsCaseAndWhitespaceInsensitive() throws {
        let first = try makeAccount(name: "ChatGPT one", kind: .chatGPTPlus)
        let second = try makeAccount(name: "ChatGPT two", kind: .chatGPTPro)

        let result = UsageAnalytics.managedAccountIdentityAssessment(
            accounts: [first, second],
            identityKeys: [
                first.id: "email:Person@Example.com",
                second.id: " EMAIL:person@example.COM "
            ]
        )

        XCTAssertEqual(result.ineligibleAccountIDs, [first.id, second.id])
    }
}
