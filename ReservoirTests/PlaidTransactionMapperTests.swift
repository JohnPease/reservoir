import XCTest
@testable import Reservoir

/// Covers `PlaidTransactionMapper`'s wire-to-domain mapping, including the amount-sign
/// verification called for by reservoir-adq.6.3's plan: Plaid's `/transactions/sync`
/// `amount` is positive for a debit/expense, negative for a credit/income — verified
/// 2026-07-15 against Plaid's docs (see `PlaidTransactionMapper`'s doc comment). A
/// negative (credit) amount must be skipped entirely (this app has no income-tracking
/// concept), not sign-flipped into positive spend.
final class PlaidTransactionMapperTests: XCTestCase {
    private func makeTransaction(
        id: String = "plaid-1",
        amount: Decimal = 12.50,
        date: String = "2026-07-10",
        merchantName: String? = "Coffee Shop",
        name: String = "COFFEE SHOP #123"
    ) -> PlaidTransaction {
        PlaidTransaction(transaction_id: id, amount: amount, date: date, merchant_name: merchantName, name: name)
    }

    func testMap_positiveAmount_mapsAsPositiveSpend() throws {
        let transaction = makeTransaction(amount: 12.50)
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        XCTAssertEqual(mapped.amount, 12.50)
    }

    func testMap_negativeAmount_isSkipped() {
        // A credit (refund, direct deposit, payment) — not spend, not imported.
        let transaction = makeTransaction(amount: -50.00)
        XCTAssertNil(PlaidTransactionMapper.map(transaction))
    }

    func testMap_zeroAmount_isSkipped() {
        let transaction = makeTransaction(amount: 0)
        XCTAssertNil(PlaidTransactionMapper.map(transaction))
    }

    func testMap_usesMerchantNameWhenPresent() throws {
        let transaction = makeTransaction(merchantName: "Starbucks", name: "SQ *STARBUCKS #4521")
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        XCTAssertEqual(mapped.merchantName, "Starbucks")
    }

    func testMap_fallsBackToNameWhenMerchantNameNil() throws {
        let transaction = makeTransaction(merchantName: nil, name: "SQ *STARBUCKS #4521")
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        XCTAssertEqual(mapped.merchantName, "SQ *STARBUCKS #4521")
    }

    func testMap_fallsBackToNameWhenMerchantNameEmpty() throws {
        let transaction = makeTransaction(merchantName: "   ", name: "SQ *STARBUCKS #4521")
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        XCTAssertEqual(mapped.merchantName, "SQ *STARBUCKS #4521")
    }

    func testMap_parsesDateString() throws {
        let transaction = makeTransaction(date: "2026-03-15")
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        let components = Calendar(identifier: .iso8601).dateComponents(in: TimeZone(identifier: "UTC")!, from: mapped.date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
    }

    func testMap_malformedDate_returnsNil() {
        let transaction = makeTransaction(date: "not-a-date")
        XCTAssertNil(PlaidTransactionMapper.map(transaction))
    }

    func testMap_carriesTransactionID() throws {
        let transaction = makeTransaction(id: "plaid-xyz-999")
        let mapped = try XCTUnwrap(PlaidTransactionMapper.map(transaction))
        XCTAssertEqual(mapped.plaidTransactionID, "plaid-xyz-999")
    }
}
