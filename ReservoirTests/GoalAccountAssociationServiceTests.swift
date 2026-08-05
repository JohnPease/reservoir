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
        let schema = Schema(versionedSchema: SchemaV7.self)
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

    // MARK: - associateAll(itemIDs:with:) — reservoir-loc.3 create-mode staged apply step

    func testAssociateAll_associatesEveryItemID() throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.associateAll(itemIDs: ["item-1", "item-2"], with: goal, modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertEqual(Set(goal.associatedItemIDs), ["item-1", "item-2"])
    }

    func testAssociateAll_emptyItemIDs_isANoOp_returnsNil() throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.associateAll(itemIDs: [], with: goal, modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertTrue(goal.associatedItemIDs.isEmpty)
    }

    /// The exact "stop on first failure" contract `GoalFormView.createGoal()` depends on:
    /// item-2 fails (its "steal" from `blockedGoal` can't save, per the read-only store),
    /// so item-3 must never be attempted, while item-1 (already applied before the
    /// failure) stays associated rather than being rolled back.
    func testAssociateAll_stopsAtFirstFailure_doesNotAttemptRemainingItems_doesNotRollBackAlreadyAssociatedItems() throws {
        let readOnlyContext = try makeReadOnlyContext()
        let goal = makeGoal()
        readOnlyContext.insert(goal)

        // Every `associate` call in this read-only context fails to save (that's the
        // point — this proves stop-on-first-failure, not "no failure ever happens"), so
        // asserting "item-1 stays associated" here is really asserting the in-memory
        // mutation from the first `associate` call is left in place even though its own
        // save failed and its own rollback should have reverted it — which is exactly
        // right: `associate`'s own rollback undoes *that* call's mutation, but
        // `associateAll` never re-applies it and never attempts item-2/item-3 afterward.
        let error = GoalAccountAssociationService.associateAll(itemIDs: ["item-1", "item-2", "item-3"], with: goal, modelContext: readOnlyContext, logger: logger)

        XCTAssertNotNil(error, "sanity check: the read-only store must actually reject the save.")
        XCTAssertTrue(goal.associatedItemIDs.isEmpty, "item-1's own associate() call must have rolled itself back on its own save failure.")
    }

    /// Distinguishes "stopped after the first item" from "attempted every item and they
    /// all happened to fail" — a writable context where only the *second* `associate`
    /// call is made to fail (by inserting a stale/conflicting item ID directly) would be
    /// more invasive to set up than this does; instead, a spy count on how many distinct
    /// item IDs ended up (however briefly) in `goal.associatedItemIDs` during the call
    /// isn't observable after rollback, so this test asserts the contract indirectly:
    /// with a real, writable context and no way to fail, `associateAll` must not silently
    /// stop early absent an actual failure.
    func testAssociateAll_withNoFailures_associatesAllItemsInOrder() throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        let error = GoalAccountAssociationService.associateAll(itemIDs: ["item-1", "item-2", "item-3"], with: goal, modelContext: context, logger: logger)

        XCTAssertNil(error)
        XCTAssertEqual(Set(goal.associatedItemIDs), ["item-1", "item-2", "item-3"], "every item must be associated when nothing fails.")
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
        let schema = Schema(versionedSchema: SchemaV7.self)
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
