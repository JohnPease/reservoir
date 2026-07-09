import XCTest
import SwiftData
@testable import Reservoir

final class ModelPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV3.self)
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
}
