import XCTest
import SwiftData
@testable import Reservoir

final class ModelPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
    }

    override func tearDownWithError() throws {
        container = nil
    }

    func testSavingsGoalPersists() throws {
        let context = ModelContext(container)
        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Date(timeIntervalSinceNow: 60 * 60 * 24 * 30),
            startDate: Date(),
            startingBalance: 100,
            dailyBase: 30
        )
        context.insert(goal)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SavingsGoal>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 1000)
        XCTAssertEqual(fetched.first?.dailyBase, 30)
    }

    func testTransactionLinksToSavingsGoal() throws {
        let context = ModelContext(container)
        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Date(timeIntervalSinceNow: 60 * 60 * 24 * 30),
            startDate: Date(),
            startingBalance: 100,
            dailyBase: 30
        )
        context.insert(goal)

        let manualTransaction = Transaction(
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
    }

    func testImportedTransactionCarriesPlaidID() throws {
        let context = ModelContext(container)
        let transaction = Transaction(
            amount: 45.00,
            date: Date(),
            merchantName: "Grocery Store",
            type: .variable,
            entryMethod: .imported,
            plaidTransactionID: "plaid-txn-123"
        )
        context.insert(transaction)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(fetched.first?.plaidTransactionID, "plaid-txn-123")
        XCTAssertEqual(fetched.first?.entryMethod, .imported)
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
