import Foundation
import SwiftData
import OSLog

/// Enforces "at most one goal per linked-item ID at a time" (reservoir-loc.1) — the single
/// choke point for the goal<->account association `SavingsGoal.associatedItemIDs` backs.
/// Stories reservoir-loc.2 (import-time account-aware attribution) and reservoir-loc.3
/// (Settings/GoalFormView UI) both call into these static methods rather than
/// reimplementing the invariant themselves, per STANDARDS §3's no-duplicated-logic rule.
///
/// A plain stateless `enum` of static methods taking `modelContext` per call — the same
/// shape `PersistenceSaveHelper` uses (this type is built directly on top of it for its
/// save/rollback semantics) — rather than an instantiable class the caller has to
/// construct and hold. `TransactionDedupMatcher` is this codebase's other precedent for a
/// stateless logic enum, though that one never touches persistence at all; this type is
/// closer to `PersistenceSaveHelper` itself in shape, since its whole job is a
/// multi-object, atomically-saved mutation.
enum GoalAccountAssociationService {
    /// Associates `itemID` with `goal`: first removes `itemID` from every *other* goal's
    /// `associatedItemIDs` (an item already associated with goal A moving to goal B is an
    /// implicit "steal," not an error state — the story's explicit call), then adds it to
    /// `goal`'s own `associatedItemIDs` if not already present. Both the removal and the
    /// addition happen inside one `modelContext.save()` via
    /// `PersistenceSaveHelper.saveOrRollback` — a failed save rolls every affected goal's
    /// `associatedItemIDs` back to exactly what it was before this call, so there is never
    /// a partial-move state where `itemID` is removed from its old goal but not added to
    /// the new one (or vice versa). Returns `nil` on success, a user-facing failure
    /// message on failure (same convention as `PersistenceSaveHelper.saveOrRollback`).
    static func associate(
        itemID: String,
        with goal: SavingsGoal,
        modelContext: ModelContext,
        logger: Logger = Logger(subsystem: "com.reservoir.app", category: "GoalAccountAssociationService")
    ) -> String? {
        let allGoals = (try? modelContext.fetch(FetchDescriptor<SavingsGoal>())) ?? []
        let snapshot = snapshotAssociations(allGoals)

        return PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                for other in allGoals where other.persistentModelID != goal.persistentModelID {
                    other.associatedItemIDs.removeAll { $0 == itemID }
                }
                if !goal.associatedItemIDs.contains(itemID) {
                    goal.associatedItemIDs.append(itemID)
                }
            },
            rollback: { Self.restore(snapshot, to: allGoals) },
            logger: logger
        )
    }

    /// Applies `associate(itemID:with:modelContext:)` for every ID in `itemIDs`, in order,
    /// stopping at the first failure — reservoir-loc.3's `GoalFormView` create-mode
    /// staged-association apply step (once a newly-created goal is confirmed persisted).
    /// Extracted out of that view (rather than left as an inline loop there) so this
    /// stop-on-first-failure sequencing is unit-testable directly (`GoalFormView`'s own
    /// `createGoal()` is otherwise untestable at the unit level, being private state on a
    /// SwiftUI `View`) and so no second copy of the same loop shape appears if another
    /// caller ever needs it (STANDARDS §3).
    ///
    /// Does **not** roll back items already associated earlier in the loop if a later one
    /// fails, and does not attempt any item after the first failure — each individual
    /// `associate` call is already atomic on its own (see that method's doc comment), and
    /// a goal ending up with *some* but not all of its intended associations is an
    /// accepted, self-healable partial state (the caller can retry from Edit), not one
    /// this method compensates for. Returns `nil` if every item associated successfully,
    /// or the first failure's message otherwise.
    static func associateAll(
        itemIDs: some Sequence<String>,
        with goal: SavingsGoal,
        modelContext: ModelContext,
        logger: Logger = Logger(subsystem: "com.reservoir.app", category: "GoalAccountAssociationService")
    ) -> String? {
        for itemID in itemIDs {
            if let error = associate(itemID: itemID, with: goal, modelContext: modelContext, logger: logger) {
                return error
            }
        }
        return nil
    }

    /// Dissociates `itemID` from whatever goal currently holds it, if any — a no-op
    /// (returns `nil` immediately, no save attempted) if no goal currently references
    /// `itemID`. Atomic via the same `saveOrRollback` pattern as `associate(itemID:with:)`.
    static func dissociate(
        itemID: String,
        modelContext: ModelContext,
        logger: Logger = Logger(subsystem: "com.reservoir.app", category: "GoalAccountAssociationService")
    ) -> String? {
        let allGoals = (try? modelContext.fetch(FetchDescriptor<SavingsGoal>())) ?? []
        guard allGoals.contains(where: { $0.associatedItemIDs.contains(itemID) }) else { return nil }
        let snapshot = snapshotAssociations(allGoals)

        return PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                for goal in allGoals {
                    goal.associatedItemIDs.removeAll { $0 == itemID }
                }
            },
            rollback: { Self.restore(snapshot, to: allGoals) },
            logger: logger
        )
    }

    /// Looks up the goal (if any) currently associated with `itemID` among `goals` —
    /// callers that already have a fetched/`@Query`'d array of goals in hand use this
    /// directly rather than triggering a second `ModelContext` fetch.
    static func associatedGoal(for itemID: String, in goals: [SavingsGoal]) -> SavingsGoal? {
        goals.first { $0.associatedItemIDs.contains(itemID) }
    }

    // MARK: - Snapshot/restore (shared rollback helper for associate/dissociate)

    private static func snapshotAssociations(_ goals: [SavingsGoal]) -> [PersistentIdentifier: [String]] {
        Dictionary(uniqueKeysWithValues: goals.map { ($0.persistentModelID, $0.associatedItemIDs) })
    }

    private static func restore(_ snapshot: [PersistentIdentifier: [String]], to goals: [SavingsGoal]) {
        for goal in goals {
            if let original = snapshot[goal.persistentModelID] {
                goal.associatedItemIDs = original
            }
        }
    }
}
