import XCTest
import SwiftData
import OSLog
@testable import Reservoir

/// Direct coverage for the shared save/rollback pattern (STANDARDS.md §3) extracted
/// from `TodayView.dismiss(_:)` and reused by goal create/edit/delete/dismiss. Uses a
/// real in-memory `ModelContainer` so `modelContext.save()` genuinely succeeds or fails
/// rather than being mocked.
///
/// The failure/rollback branch (previously unexercised — see git history) is covered
/// below by genuinely tripping a `ModelContext.save()` failure via
/// `SpendTransaction.plaidTransactionID`'s `@Attribute(.unique)` constraint: inserting a
/// second transaction with a `plaidTransactionID` already present in the store makes
/// `save()` throw deterministically, without needing to tear down the container
/// mid-call or mock anything.
final class PersistenceSaveHelperTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let logger = Logger(subsystem: "com.reservoir.tests", category: "PersistenceSaveHelperTests")

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    func testSaveOrRollbackReturnsNilAndAppliesMutationOnSuccess() throws {
        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        context.insert(goal)
        try context.save()

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: context,
            mutate: { goal.dismissedAt = .now },
            rollback: { goal.dismissedAt = nil },
            logger: logger
        )

        XCTAssertNil(error)
        XCTAssertNotNil(goal.dismissedAt)
    }

    func testSaveOrRollbackCallsMutateExactlyOnceOnSuccess() throws {
        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        context.insert(goal)
        try context.save()

        var mutateCallCount = 0
        var rollbackCallCount = 0

        _ = PersistenceSaveHelper.saveOrRollback(
            modelContext: context,
            mutate: { mutateCallCount += 1 },
            rollback: { rollbackCallCount += 1 },
            logger: logger
        )

        XCTAssertEqual(mutateCallCount, 1)
        XCTAssertEqual(rollbackCallCount, 0)
    }

    /// Opens a fresh on-disk store, writes a schema into it with a normal (writable)
    /// container, then reopens the *same* file with `allowsSave: false`. Any
    /// `modelContext.save()` against the resulting read-only context genuinely throws,
    /// giving deterministic coverage of `PersistenceSaveHelper`'s `catch` branch without
    /// mocking anything or tearing down a container mid-call.
    private func makeReadOnlyContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceSaveHelperTests-\(UUID().uuidString)")
            .appendingPathExtension("store")

        // First pass: create and initialize the store file with a normal, writable
        // container so it exists on disk before being reopened read-only.
        let seedConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let seedContainer = try ModelContainer(
            for: schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [seedConfiguration]
        )
        try ModelContext(seedContainer).save()

        let readOnlyConfiguration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let readOnlyContainer = try ModelContainer(
            for: schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [readOnlyConfiguration]
        )
        return ModelContext(readOnlyContainer)
    }

    func testSaveOrRollbackCallsRollbackAndReturnsFailureMessageWhenSaveIsDisallowed() throws {
        let readOnlyContext = try makeReadOnlyContext()

        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        readOnlyContext.insert(goal)

        var rollbackCallCount = 0
        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: readOnlyContext,
            mutate: { goal.dismissedAt = .now },
            rollback: {
                rollbackCallCount += 1
                goal.dismissedAt = nil
            },
            logger: logger
        )

        XCTAssertEqual(error, "Your change couldn't be saved. Please try again.")
        XCTAssertEqual(rollbackCallCount, 1)
        XCTAssertNil(goal.dismissedAt, "Rollback should have reverted the mutation.")
    }

    func testSaveOrRollbackReturnsCustomFailureMessageWhenSaveIsDisallowed() throws {
        let readOnlyContext = try makeReadOnlyContext()

        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        readOnlyContext.insert(goal)

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: readOnlyContext,
            mutate: { goal.dismissedAt = .now },
            rollback: { goal.dismissedAt = nil },
            logger: logger,
            failureMessage: "Custom failure message."
        )

        XCTAssertEqual(error, "Custom failure message.")
    }

    /// Regression coverage for `GoalsView.delete(_:)`'s rollback closure (code-review
    /// finding on PR #5): `modelContext.delete(goal)` applies the `.nullify` relationship
    /// side effect to the goal's attributed transactions immediately, in-memory — not
    /// only once `save()` succeeds. A rollback that only re-inserts the goal (without
    /// also re-linking `transaction.savingsGoal`) leaves those transactions permanently
    /// orphaned even though the deletion was "undone." This exercises the exact
    /// mutate/rollback closure shape `GoalsView.delete(_:)` now uses — capturing
    /// `goal.transactions` before `mutate()` runs and restoring `savingsGoal` on each in
    /// `rollback()` — against a genuinely failing `save()` (read-only store), matching
    /// this file's existing read-only-container pattern.
    func testSaveOrRollbackRestoresTransactionGoalLinkAfterFailedDelete() throws {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceSaveHelperTests-deleteRollback-\(UUID().uuidString)")
            .appendingPathExtension("store")

        let seedConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let seedContainer = try ModelContainer(
            for: schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [seedConfiguration]
        )
        let seedContext = ModelContext(seedContainer)

        let goal = SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 30
        )
        seedContext.insert(goal)
        let transaction = SpendTransaction(
            amount: 25,
            date: .now,
            merchantName: "Merchant",
            type: .variable,
            entryMethod: .manual,
            savingsGoal: goal
        )
        seedContext.insert(transaction)
        try seedContext.save()

        let readOnlyConfiguration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let readOnlyContainer = try ModelContainer(
            for: schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [readOnlyConfiguration]
        )
        let readOnlyContext = ModelContext(readOnlyContainer)
        let fetchedGoal = try XCTUnwrap(try readOnlyContext.fetch(FetchDescriptor<SavingsGoal>()).first)
        let fetchedTransaction = try XCTUnwrap(try readOnlyContext.fetch(FetchDescriptor<SpendTransaction>()).first)
        XCTAssertEqual(fetchedTransaction.savingsGoal?.persistentModelID, fetchedGoal.persistentModelID)

        let affectedTransactions = fetchedGoal.transactions
        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: readOnlyContext,
            mutate: { readOnlyContext.delete(fetchedGoal) },
            rollback: {
                readOnlyContext.insert(fetchedGoal)
                for transaction in affectedTransactions {
                    transaction.savingsGoal = fetchedGoal
                }
            },
            logger: logger
        )

        XCTAssertNotNil(error, "save() against the read-only store should have failed.")
        XCTAssertEqual(
            fetchedTransaction.savingsGoal?.persistentModelID,
            fetchedGoal.persistentModelID,
            "The transaction should still point back to the goal after a failed delete+rollback."
        )
    }

    func testSaveOrRollbackPersistsMutationAcrossFetch() throws {
        let goal = SavingsGoal(
            targetAmount: 500,
            targetDate: Calendar.current.date(byAdding: .day, value: 10, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: 50
        )
        context.insert(goal)
        try context.save()

        _ = PersistenceSaveHelper.saveOrRollback(
            modelContext: context,
            mutate: { goal.targetAmount = 999 },
            rollback: { goal.targetAmount = 500 },
            logger: logger
        )

        let fetched = try context.fetch(FetchDescriptor<SavingsGoal>())
        XCTAssertEqual(fetched.first?.targetAmount, 999)
    }
}
