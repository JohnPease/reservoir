import XCTest
@testable import Reservoir

/// Covers reservoir-adq.6.3's dedup-match and merge-resolution acceptance criteria:
/// exact match, amount mismatch, date-outside-window, merchant case-difference (still
/// matches), merchant substring-only (no match, per PROJECT_SPEC's no-fuzzy-matching
/// rule), and `applyMerge`'s field-level behavior.
final class TransactionDedupMatcherTests: XCTestCase {
    private func makeManual(
        amount: Decimal = 12.50,
        date: Date = .now,
        merchantName: String = "Coffee Shop",
        type: TransactionType = .variable,
        isManualOverride: Bool = false
    ) -> SpendTransaction {
        SpendTransaction(
            amount: amount,
            date: date,
            merchantName: merchantName,
            type: type,
            entryMethod: .manual,
            isManualOverride: isManualOverride
        )
    }

    private func mapped(
        id: String = "plaid-1",
        amount: Decimal = 12.50,
        date: Date = .now,
        merchantName: String = "Coffee Shop"
    ) -> MappedPlaidTransaction {
        MappedPlaidTransaction(plaidTransactionID: id, amount: amount, date: date, merchantName: merchantName)
    }

    // MARK: - findMatch

    func testFindMatch_exactAmountDateMerchant_matches() {
        let manual = makeManual()
        let incoming = mapped()

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [manual])

        XCTAssertTrue(result === manual)
    }

    func testFindMatch_amountMismatch_noMatch() {
        let manual = makeManual(amount: 12.50)
        let incoming = mapped(amount: 12.51)

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [manual])

        XCTAssertNil(result)
    }

    func testFindMatch_dateOutsideSameDayWindow_noMatch() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let manual = makeManual(date: yesterday)
        let incoming = mapped(date: today)

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [manual])

        XCTAssertNil(result)
    }

    func testFindMatch_merchantCaseDifference_stillMatches() {
        let manual = makeManual(merchantName: "coffee shop")
        let incoming = mapped(merchantName: "COFFEE SHOP")

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [manual])

        XCTAssertTrue(result === manual)
    }

    func testFindMatch_merchantSubstringOnly_noMatch() {
        // No fuzzy/substring matching per PROJECT_SPEC's "Merchant matching" rule —
        // "Coffee Shop" is a substring of "Downtown Coffee Shop Inc" but not an exact
        // (case-insensitive) match.
        let manual = makeManual(merchantName: "Coffee Shop")
        let incoming = mapped(merchantName: "Downtown Coffee Shop Inc")

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [manual])

        XCTAssertNil(result)
    }

    func testFindMatch_ignoresNonManualTransactions() {
        let imported = SpendTransaction(
            amount: 12.50, date: .now, merchantName: "Coffee Shop", type: .variable,
            entryMethod: .imported, plaidTransactionID: "already-imported"
        )
        let incoming = mapped()

        let result = TransactionDedupMatcher.findMatch(for: incoming, existingManualTransactions: [imported])

        XCTAssertNil(result)
    }

    // MARK: - applyMerge

    func testApplyMerge_plaidWinsOnAmountDateMerchant() {
        let manual = makeManual(amount: 12.49, merchantName: "Cofee Shop Typo")
        let incoming = mapped(id: "plaid-42", amount: 12.50, merchantName: "Coffee Shop")

        TransactionDedupMatcher.applyMerge(to: manual, incoming: incoming)

        XCTAssertEqual(manual.amount, 12.50)
        XCTAssertEqual(manual.merchantName, "Coffee Shop")
        XCTAssertEqual(manual.date, incoming.date)
        XCTAssertEqual(manual.plaidTransactionID, "plaid-42")
        XCTAssertEqual(manual.entryMethod, .imported)
        XCTAssertTrue(manual.wasMergedFromManual)
    }

    func testApplyMerge_preservesTypeAndManualOverride() {
        let manual = makeManual(type: .fixed, isManualOverride: true)
        let incoming = mapped()

        TransactionDedupMatcher.applyMerge(to: manual, incoming: incoming)

        XCTAssertEqual(manual.type, .fixed)
        XCTAssertTrue(manual.isManualOverride)
    }

    func testApplyMerge_preservesSavingsGoal() {
        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        let manual = makeManual()
        manual.savingsGoal = goal
        let incoming = mapped()

        TransactionDedupMatcher.applyMerge(to: manual, incoming: incoming)

        XCTAssertTrue(manual.savingsGoal === goal)
    }
}
