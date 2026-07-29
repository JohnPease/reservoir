import XCTest
import SwiftData
import OSLog
@testable import Reservoir

/// Covers `GoalAccountAssociationService`'s "at most one goal per item ID at a time"
/// invariant (reservoir-loc.1): associating an item with a goal, moving it from one goal
/// to another (an implicit "steal," not an error), dissociating, the lookup helper, and
/// atomicity (a failed save leaves every affected goal's `associatedItemIDs` untouched).
final class GoalAccountAssociationServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let logger = Logger(subsystem: "com.reservoir.tests", category: "GoalAccountAssociationServiceTests")

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func makeGoal(dailyBase: Decimal = 30, associatedItemIDs: [String] = []) -> SavingsGoal {
        SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: dailyBase,
            associatedItemIDs: associatedItemIDs
        )
    }

    // MARK: - associate(itemID:with:)

    func testAssociate_addsItemIDToGoal() throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.associate(itemID: "item-1", with: goal, modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertEqual(goal.associatedItemIDs, ["item-1"])
    }

    func testAssociate_sameItemIDTwice_doesNotDuplicate() throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        _ = GoalAccountAssociationService.associate(itemID: "item-1", with: goal, modelContext: context, logger: logger)
        _ = GoalAccountAssociationService.associate(itemID: "item-1", with: goal, modelContext: context, logger: logger)

        XCTAssertEqual(goal.associatedItemIDs, ["item-1"])
    }

    /// The core invariant: an item already associated with one goal, associated with a
    /// second goal, must be removed from the first — "at most one goal per item ID at a
    /// time," enforced at this single choke point.
    func testAssociate_itemAlreadyOnAnotherGoal_movesIt_removingFromOldGoal() throws {
        let oldGoal = makeGoal(dailyBase: 10, associatedItemIDs: ["item-1"])
        let newGoal = makeGoal(dailyBase: 20)
        context.insert(oldGoal)
        context.insert(newGoal)
        try context.save()

        let error = GoalAccountAssociationService.associate(itemID: "item-1", with: newGoal, modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertEqual(newGoal.associatedItemIDs, ["item-1"], "the item must now be associated with the new goal.")
        XCTAssertTrue(oldGoal.associatedItemIDs.isEmpty, "the item must no longer be associated with its old goal — moving is an implicit steal, not an error.")
    }

    func testAssociate_leavesOtherItemIDsOnOldGoalUntouched() throws {
        let oldGoal = makeGoal(dailyBase: 10, associatedItemIDs: ["item-1", "item-2"])
        let newGoal = makeGoal(dailyBase: 20)
        context.insert(oldGoal)
        context.insert(newGoal)
        try context.save()

        _ = GoalAccountAssociationService.associate(itemID: "item-1", with: newGoal, modelContext: context, logger: logger)

        XCTAssertEqual(oldGoal.associatedItemIDs, ["item-2"], "only the moved item ID should be removed from the old goal.")
    }

    func testAssociate_leavesOtherGoalsUnrelatedToTheItemUntouched() throws {
        let goal = makeGoal(dailyBase: 10)
        let unrelatedGoal = makeGoal(dailyBase: 20, associatedItemIDs: ["item-other"])
        context.insert(goal)
        context.insert(unrelatedGoal)
        try context.save()

        _ = GoalAccountAssociationService.associate(itemID: "item-1", with: goal, modelContext: context, logger: logger)

        XCTAssertEqual(unrelatedGoal.associatedItemIDs, ["item-other"])
    }

    // MARK: - dissociate(itemID:)

    func testDissociate_removesItemFromWhicheverGoalHoldsIt() throws {
        let goal = makeGoal(associatedItemIDs: ["item-1"])
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.dissociate(itemID: "item-1", modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertTrue(goal.associatedItemIDs.isEmpty)
    }

    func testDissociate_whenNoGoalHoldsTheItem_isANoOp_returnsNil() throws {
        let goal = makeGoal(associatedItemIDs: ["item-other"])
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.dissociate(itemID: "item-1", modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertEqual(goal.associatedItemIDs, ["item-other"], "dissociating an unrelated item ID must not touch any goal's associations.")
    }

    func testDissociate_leavesOtherItemIDsOnTheSameGoalUntouched() throws {
        let goal = makeGoal(associatedItemIDs: ["item-1", "item-2"])
        context.insert(goal)
        try context.save()

        _ = GoalAccountAssociationService.dissociate(itemID: "item-1", modelContext: context, logger: logger)

        XCTAssertEqual(goal.associatedItemIDs, ["item-2"])
    }

    // MARK: - associatedGoal(for:in:)

    func testAssociatedGoal_returnsTheGoalHoldingTheItemID() {
        let goal = makeGoal(associatedItemIDs: ["item-1"])
        let otherGoal = makeGoal(dailyBase: 20, associatedItemIDs: ["item-2"])

        let found = GoalAccountAssociationService.associatedGoal(for: "item-1", in: [goal, otherGoal])

        XCTAssertEqual(found?.persistentModelID, goal.persistentModelID)
    }

    func testAssociatedGoal_returnsNil_whenNoGoalHoldsTheItemID() {
        let goal = makeGoal(associatedItemIDs: ["item-other"])

        let found = GoalAccountAssociationService.associatedGoal(for: "item-1", in: [goal])

        XCTAssertNil(found)
    }

    // MARK: - Atomicity: a failed save leaves every affected goal untouched

    /// Opens a fresh on-disk store with `allowsSave: false`, so `modelContext.save()`
    /// genuinely throws — same pattern as `PersistenceSaveHelperTests
    /// .makeReadOnlyContext()` — giving deterministic coverage of the rollback path
    /// without mocking anything. Goals are inserted directly into the returned context
    /// (never previously saved), same as that precedent's own read-only tests: a
    /// `ModelContext.fetch` sees its own pending inserts even before a save succeeds.
    private func makeReadOnlyContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalAccountAssociationServiceTests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        addTeardownBlock {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }

        // First pass: create and initialize the store file with a normal, writable
        // container so it exists on disk before being reopened read-only.
        let seedConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let seedContainer = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [seedConfiguration])
        try ModelContext(seedContainer).save()

        let readOnlyConfiguration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let readOnlyContainer = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [readOnlyConfiguration])
        return ModelContext(readOnlyContainer)
    }

    /// The explicit acceptance criterion: associating/removing is atomic — no
    /// partial-move state where the item is removed from its old goal but not added to
    /// the new one (or vice versa) if the save fails.
    func testAssociate_whenSaveFails_rollsBackBothOldAndNewGoal_noPartialMoveState() throws {
        let readOnlyContext = try makeReadOnlyContext()
        let oldGoal = makeGoal(dailyBase: 10, associatedItemIDs: ["item-1"])
        let newGoal = makeGoal(dailyBase: 20)
        readOnlyContext.insert(oldGoal)
        readOnlyContext.insert(newGoal)

        let error = GoalAccountAssociationService.associate(itemID: "item-1", with: newGoal, modelContext: readOnlyContext, logger: logger)

        XCTAssertNotNil(error, "sanity check: the read-only store must actually reject the save.")
        XCTAssertEqual(oldGoal.associatedItemIDs, ["item-1"], "a failed save must leave the old goal's association exactly as it was — not removed.")
        XCTAssertTrue(newGoal.associatedItemIDs.isEmpty, "a failed save must not leave the new goal with a half-applied addition.")
    }

    func testDissociate_whenSaveFails_rollsBackToOriginalAssociation() throws {
        let readOnlyContext = try makeReadOnlyContext()
        let goal = makeGoal(associatedItemIDs: ["item-1", "item-2"])
        readOnlyContext.insert(goal)

        let error = GoalAccountAssociationService.dissociate(itemID: "item-1", modelContext: readOnlyContext, logger: logger)

        XCTAssertNotNil(error, "sanity check: the read-only store must actually reject the save.")
        XCTAssertEqual(goal.associatedItemIDs, ["item-1", "item-2"], "a failed save must leave associations exactly as they were.")
    }
}
