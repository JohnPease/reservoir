import XCTest
import SwiftData
@testable import Reservoir

final class ModelPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func makeGoal(
        targetAmount: Decimal = 1000,
        startingBalance: Decimal = 100,
        dailyBase: Decimal = 30
    ) -> SavingsGoal {
        SavingsGoal(
            targetAmount: targetAmount,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: startingBalance,
            dailyBase: dailyBase
        )
    }

    func testSavingsGoalPersists() throws {
        let context = ModelContext(container)
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SavingsGoal>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 1000)
        XCTAssertEqual(fetched.first?.dailyBase, 30)
    }

    func testTransactionLinksToSavingsGoal() throws {
        let context = ModelContext(container)
        let goal = makeGoal()
        context.insert(goal)

        let manualTransaction = SpendTransaction(
            amount: 12.50,
            date: Date(),
            merchantName: "Coffee Shop",
            type: .variable,
            entryMethod: .manual,
            savingsGoal: goal
        )
        context.insert(manualTransaction)
        try context.save()

        XCTAssertEqual(goal.transactions.count, 1)
        XCTAssertEqual(goal.transactions.first?.merchantName, "Coffee Shop")
        XCTAssertNil(goal.transactions.first?.plaidTransactionID)
        XCTAssertFalse(goal.transactions.first?.isManualOverride ?? true)
    }

    func testImportedTransactionCarriesPlaidID() throws {
        let context = ModelContext(container)
        let transaction = SpendTransaction(
            amount: 45.00,
            date: Date(),
            merchantName: "Grocery Store",
            type: .variable,
            entryMethod: .imported,
            plaidTransactionID: "plaid-txn-123"
        )
        context.insert(transaction)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.plaidTransactionID, "plaid-txn-123")
        XCTAssertEqual(fetched.first?.entryMethod, .imported)
    }

    func testManualOverridePreventsRetagging() throws {
        let context = ModelContext(container)
        let transaction = SpendTransaction(
            amount: 20.00,
            date: Date(),
            merchantName: "Ambiguous Merchant",
            type: .fixed,
            entryMethod: .manual,
            isManualOverride: true
        )
        context.insert(transaction)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.isManualOverride, true)
    }

    func testMerchantRulePersists() throws {
        let context = ModelContext(container)
        let rule = MerchantRule(merchantName: "Rent LLC", type: .fixed)
        context.insert(rule)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MerchantRule>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.type, .fixed)
    }

    /// `GoalsView.delete(_:)` (adq.5) relies on `SavingsGoal.transactions`'s
    /// `@Relationship(deleteRule: .nullify, ...)` (declared identically across
    /// `SchemaV1`/`V2`/`V3`) to orphan attributed transactions rather than delete them —
    /// "Its N attributed transactions will no longer count toward any daily limit, but
    /// will not be deleted" is the confirmation copy's exact promise. This is a
    /// framework-level guarantee, not new adq.5 calculator logic, but it's the load-
    /// bearing behavior the new delete flow depends on, so it's covered directly rather
    /// than only implicitly relied upon.
    func testDeletingGoalNullifiesAttributedTransactionsInsteadOfDeletingThem() throws {
        let context = ModelContext(container)
        let goal = makeGoal()
        context.insert(goal)

        let transaction = SpendTransaction(
            amount: 12.50,
            date: .now,
            merchantName: "Coffee Shop",
            type: .variable,
            entryMethod: .manual,
            savingsGoal: goal
        )
        context.insert(transaction)
        try context.save()

        context.delete(goal)
        try context.save()

        let remainingGoals = try context.fetch(FetchDescriptor<SavingsGoal>())
        XCTAssertTrue(remainingGoals.isEmpty)

        let remainingTransactions = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(remainingTransactions.count, 1, "The transaction must survive goal deletion, orphaned rather than deleted.")
        XCTAssertNil(remainingTransactions.first?.savingsGoal, "The deleted goal's relationship must be nullified on the surviving transaction.")
        XCTAssertEqual(remainingTransactions.first?.merchantName, "Coffee Shop")
    }
}
