import XCTest
@testable import Reservoir

final class MerchantRuleRetagCalculatorTests: XCTestCase {

    // MARK: - requiresRetag

    func testRequiresRetagFalseWhenNameAndTypeUnchanged() {
        let result = MerchantRuleRetagCalculator.requiresRetag(
            oldMerchantName: "Netflix",
            oldType: .fixed,
            newMerchantName: "Netflix",
            newType: .fixed
        )
        XCTAssertFalse(result)
    }

    func testRequiresRetagFalseWhenOnlyCasingDiffers() {
        // Case-insensitive equality — retagging on a same-string, different-case save
        // (a true no-op edit) must not refire.
        let result = MerchantRuleRetagCalculator.requiresRetag(
            oldMerchantName: "netflix",
            oldType: .fixed,
            newMerchantName: "Netflix",
            newType: .fixed
        )
        XCTAssertFalse(result)
    }

    func testRequiresRetagTrueWhenTypeChanges() {
        let result = MerchantRuleRetagCalculator.requiresRetag(
            oldMerchantName: "Netflix",
            oldType: .fixed,
            newMerchantName: "Netflix",
            newType: .variable
        )
        XCTAssertTrue(result)
    }

    func testRequiresRetagTrueWhenMerchantNameChanges() {
        let result = MerchantRuleRetagCalculator.requiresRetag(
            oldMerchantName: "Netflix",
            oldType: .fixed,
            newMerchantName: "Netflix Inc",
            newType: .fixed
        )
        XCTAssertTrue(result)
    }

    // MARK: - transactionsToRetag

    func testTransactionsToRetagIncludesCaseInsensitiveMatchesExcludingManualOverrides() {
        let matchingNotOverridden = SpendTransaction(
            amount: 10, date: .now, merchantName: "netflix", type: .variable, entryMethod: .manual
        )
        let matchingOverridden = SpendTransaction(
            amount: 12, date: .now, merchantName: "Netflix", type: .variable, entryMethod: .manual, isManualOverride: true
        )
        let nonMatching = SpendTransaction(
            amount: 20, date: .now, merchantName: "Hulu", type: .variable, entryMethod: .manual
        )

        let result = MerchantRuleRetagCalculator.transactionsToRetag(
            [matchingNotOverridden, matchingOverridden, nonMatching],
            merchantName: "Netflix"
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.contains { $0 === matchingNotOverridden })
        XCTAssertFalse(result.contains { $0 === matchingOverridden })
    }

    func testTransactionsToRetagReturnsEmptyWhenNoneMatch() {
        let transaction = SpendTransaction(amount: 10, date: .now, merchantName: "Hulu", type: .variable, entryMethod: .manual)
        let result = MerchantRuleRetagCalculator.transactionsToRetag([transaction], merchantName: "Netflix")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - applyRetag

    func testApplyRetagSetsTypeOnEachProvidedTransaction() {
        let transactionA = SpendTransaction(amount: 10, date: .now, merchantName: "Netflix", type: .variable, entryMethod: .manual)
        let transactionB = SpendTransaction(amount: 12, date: .now, merchantName: "netflix", type: .variable, entryMethod: .manual)

        MerchantRuleRetagCalculator.applyRetag(to: [transactionA, transactionB], newType: .fixed)

        XCTAssertEqual(transactionA.type, .fixed)
        XCTAssertEqual(transactionB.type, .fixed)
    }

    // MARK: - Mixed fixture (matches bead's required coverage)

    func testMixedFixtureOnlyRetagsNonOverriddenMatchingTransactions() {
        let overridden = SpendTransaction(
            amount: 15, date: .now, merchantName: "Rent LLC", type: .variable, entryMethod: .manual, isManualOverride: true
        )
        let plainMatch = SpendTransaction(
            amount: 900, date: .now, merchantName: "Rent LLC", type: .variable, entryMethod: .manual
        )
        let differentMerchant = SpendTransaction(
            amount: 50, date: .now, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual
        )

        let toRetag = MerchantRuleRetagCalculator.transactionsToRetag(
            [overridden, plainMatch, differentMerchant],
            merchantName: "Rent LLC"
        )
        MerchantRuleRetagCalculator.applyRetag(to: toRetag, newType: .fixed)

        XCTAssertEqual(overridden.type, .variable, "Manually overridden transaction must not be retagged.")
        XCTAssertEqual(plainMatch.type, .fixed, "Non-overridden matching transaction must be retagged.")
        XCTAssertEqual(differentMerchant.type, .variable, "Non-matching merchant must not be retagged.")
    }
}
