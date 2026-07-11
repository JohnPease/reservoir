import Foundation
import SwiftData
import OSLog

/// Extracted from `TodayView.dismiss(_:)`'s original mutate/try-save/rollback/alert
/// shape (STANDARDS.md §3 — "no copy-paste") so goal create/edit/delete/dismiss all
/// share one save-and-rollback implementation instead of four near-identical copies.
///
/// If a save fails, the caller's mutation must be rolled back rather than left
/// applied-but-unpersisted — otherwise the in-memory SwiftData state would silently
/// diverge from what's on disk (the mutation appears to have "worked" for the rest of
/// the session, then reverts on next launch with no indication anything went wrong). The
/// error is both logged here and returned as a user-facing message so a persistent
/// failure (e.g. a full disk) doesn't fail silently — callers are responsible for
/// surfacing it (typically via an `.alert`).
enum PersistenceSaveHelper {
    /// Performs `mutate`, attempts `modelContext.save()`, and — on failure — calls
    /// `rollback` and returns a user-facing error message. Returns `nil` on success.
    ///
    /// - Warning: If `mutate` deletes an object that has SwiftData relationships with a
    ///   `.nullify` delete rule (e.g. `SavingsGoal.transactions`), SwiftData applies that
    ///   nullify side effect to the *related* objects in-memory as soon as `mutate` calls
    ///   `modelContext.delete(_:)` — not only once `save()` here actually succeeds. If
    ///   `save()` then throws, simply re-inserting the deleted object in `rollback` is not
    ///   enough to undo the mutation: the object comes back, but the related objects it
    ///   used to point to (or be pointed to by) are left nullified/orphaned, because
    ///   `rollback` only sees whatever state `mutate` already changed, not a snapshot from
    ///   before it ran. Callers whose `mutate` deletes an object with such relationships
    ///   must capture the affected related objects *before* calling `mutate`, and
    ///   re-link them explicitly inside `rollback` — see `GoalsView.delete(_:)` for a
    ///   worked example. This helper does not attempt to make relationship rollback
    ///   generic: with one call site needing it today, a capture-and-relink closure is
    ///   simpler than a relationship-aware API surface here.
    static func saveOrRollback(
        modelContext: ModelContext,
        mutate: () -> Void,
        rollback: () -> Void,
        logger: Logger,
        failureMessage: String = "Your change couldn't be saved. Please try again."
    ) -> String? {
        mutate()
        do {
            try modelContext.save()
            return nil
        } catch {
            rollback()
            logger.error("Failed to save change: \(error.localizedDescription, privacy: .public)")
            return failureMessage
        }
    }
}
