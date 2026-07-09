import XCTest
import SwiftData
import OSLog
@testable import Reservoir

/// Direct coverage for the shared save/rollback pattern (STANDARDS.md §3) extracted
/// from `TodayView.dismiss(_:)` and reused by goal create/edit/delete/dismiss. Uses a
/// real in-memory `ModelContainer` so `modelContext.save()` genuinely succeeds rather
/// than being mocked.
///
/// The failure/rollback branch isn't exercised here: forcing a genuine, deterministic
/// `ModelContext.save()` failure in an in-memory SwiftData store (short of tearing down
/// the container mid-call) isn't practical, and this mirrors the original
/// `TodayView.dismiss(_:)` implementation this helper was extracted from, which was
/// likewise only manually verified for its failure path, not unit-tested — this
/// extraction doesn't change that. The branch itself is a single trivial `catch` (call
/// `rollback`, log, return `failureMessage`), reviewed by inspection.
final class PersistenceSaveHelperTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let logger = Logger(subsystem: "com.reservoir.tests", category: "PersistenceSaveHelperTests")

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV3.self)
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
