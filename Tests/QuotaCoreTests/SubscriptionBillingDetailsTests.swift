import Foundation
import XCTest
@testable import QuotaCore

final class SubscriptionBillingDetailsTests: XCTestCase {
    func testCADInputPreservesCentsAndRejectsAmbiguousOrInvalidAmounts() throws {
        XCTAssertNil(try SubscriptionBillingDetails.parseCADCents(" "))
        XCTAssertEqual(try SubscriptionBillingDetails.parseCADCents(" 129.99 "), 12_999)
        XCTAssertEqual(try SubscriptionBillingDetails.parseCADCents("129.9"), 12_990)
        XCTAssertEqual(try SubscriptionBillingDetails.parseCADCents("0"), 0)
        for invalid in ["-1", "1.234", "1,23", "100e2", "1 CAD", "9999999999999999999999"] {
            XCTAssertThrowsError(try SubscriptionBillingDetails.parseCADCents(invalid))
        }
    }

    func testOptionalBillingDataDecodesWithLegacyAccountAndRoundTripsWithNewAccount() throws {
        let legacy = try ConnectedAccount(displayName: "Claude", kind: .claudeMax)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacyData = try encoder.encode(legacy)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(fields["subscriptionBilling"])
        XCTAssertNil(try decoder.decode(ConnectedAccount.self, from: legacyData).subscriptionBilling)

        let date = Date(timeIntervalSince1970: 86_400 + 45)
        let billing = try SubscriptionBillingDetails(planName: " Max 20x ", renewalDate: date, costCADCents: 29_999)
        let account = try ConnectedAccount(displayName: "Claude", kind: .claudeMax, subscriptionBilling: billing)
        XCTAssertEqual(billing.planName, "Max 20x")
        XCTAssertEqual(billing.renewalDate, Date(timeIntervalSince1970: 86_400))
        XCTAssertEqual(try decoder.decode(ConnectedAccount.self, from: encoder.encode(account)), account)
    }
}
