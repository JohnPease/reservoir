import Foundation
import SwiftData

/// Business logic for the Today screen: goal lifecycle (active / completed-awaiting-
/// dismissal), the `SavingsGoal`/`SpendTransaction` -> `GoalCarryForwardInput` mapping
/// `DailyLimitCalculator` needs, and the spent/remaining summary shown in the two-stat
/// row. Kept out of `TodayView` per STANDARDS.md §3 ("business logic stays out of
/// views") so it's unit-testable without driving the UI.
///
/// This type imports SwiftData for the model types themselves — `SavingsGoal` and
/// `SpendTransaction` can be constructed and read without a live `ModelContainer` — but
/// never imports SwiftUI. `DailyLimitCalculator` itself stays pure Foundation; this is
/// the one place its plain value types meet the SwiftData model layer.
enum TodayScreenCalculator {

    // MARK: - Goal lifecycle

    /// A goal is "active" from creation through `targetDate` inclusive (`targetDate >=
    /// today`, compared as whole device-local calendar days) and stops being active the
    /// day after. A goal the user has already dismissed (see `SavingsGoal.dismissedAt`)
    /// is never active again, even if `targetDate` is somehow still in the future
    /// (defensive — shouldn't occur since dismissal only ever follows completion).
    static func isActive(
        _ goal: SavingsGoal,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard goal.dismissedAt == nil else { return false }
        let today = calendar.startOfDay(for: referenceDate)
        let target = calendar.startOfDay(for: goal.targetDate)
        return target >= today
    }

    /// Every goal in `goals` for which `isActive` is true.
    static func activeGoals(
        _ goals: [SavingsGoal],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [SavingsGoal] {
        goals.filter { isActive($0, referenceDate: referenceDate, calendar: calendar) }
    }

    /// Goals whose `targetDate` has passed but which the user hasn't yet dismissed the
    /// Today screen's completion banner for. Each renders its own banner — goals are
    /// never pooled (PROJECT_SPEC "Multi-goal scope"), so more than one can complete
    /// independently.
    static func completedUndismissedGoals(
        _ goals: [SavingsGoal],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [SavingsGoal] {
        let today = calendar.startOfDay(for: referenceDate)
        return goals.filter { goal in
            goal.dismissedAt == nil && calendar.startOfDay(for: goal.targetDate) < today
        }
    }

    // MARK: - DailyLimitCalculator mapping

    /// Maps one `SavingsGoal` and its transactions into the plain value type
    /// `DailyLimitCalculator` operates on. This is the sole place `SavingsGoal`/
    /// `SpendTransaction` meet the pure calculator, per this story's acceptance
    /// criteria — callers (namely `TodayView`, `GoalsScreenCalculator`) never build a
    /// `GoalCarryForwardInput` themselves.
    ///
    /// `effectiveStartDate` is `lastEditedDate ?? max(startDate, createdAt)` (adq.5) —
    /// not `lastEditedDate ?? startDate` alone (the pre-adq.5 formula). `startDate` is
    /// now user-backdatable (see `GoalFormValidator`), but `SpendTransaction.savingsGoal`
    /// is only ever set at transaction-entry time — there's no retroactive-attribution
    /// UI — so days before the goal's real `createdAt` genuinely have zero attributable
    /// transactions, not zero real spend. Flooring at `createdAt` stops a backdated
    /// `startDate` from crediting carry-forward for days that predate the goal's actual
    /// existence in the app (which would fabricate banked surplus from nothing). An
    /// edited goal (`lastEditedDate` set) still wins outright, unaffected by this floor.
    static func carryForwardInput(for goal: SavingsGoal, calendar: Calendar = .current) -> GoalCarryForwardInput {
        GoalCarryForwardInput(
            id: goal.persistentModelID,
            dailyBase: goal.dailyBase,
            effectiveStartDate: goal.lastEditedDate ?? effectiveStartDateFloor(startDate: goal.startDate, createdAt: goal.createdAt, calendar: calendar),
            spendEntries: goal.transactions.map { transaction in
                GoalCarryForwardInput.SpendEntry(
                    date: transaction.date,
                    amount: transaction.amount,
                    kind: transaction.type == .fixed ? .fixed : .variable
                )
            }
        )
    }

    /// `max(startDate, createdAt)`, compared as whole calendar days (mirrors every other
    /// date comparison in this mapping/`DailyLimitCalculator`, which all operate at
    /// day granularity, not exact `Date` instants).
    private static func effectiveStartDateFloor(startDate: Date, createdAt: Date, calendar: Calendar) -> Date {
        let startDay = calendar.startOfDay(for: startDate)
        let createdDay = calendar.startOfDay(for: createdAt)
        return max(startDay, createdDay)
    }

    /// Whether `goal` was actually met — an end-state check on the goal's cumulative
    /// carry-forward balance through `goal.targetDate` inclusive, not merely that
    /// `targetDate` has passed. Mirrors `carryForwardInput(for:)`'s mapping pattern;
    /// callers (namely `TodayView.CompletionBannerView`) never build a
    /// `GoalCarryForwardInput` themselves. See `DailyLimitCalculator.isGoalMet` for the
    /// full end-state-vs-day-by-day reasoning.
    static func isGoalMet(_ goal: SavingsGoal, calendar: Calendar = .current) -> Bool {
        DailyLimitCalculator.isGoalMet(
            for: carryForwardInput(for: goal, calendar: calendar),
            targetDate: goal.targetDate,
            calendar: calendar
        )
    }

    // MARK: - Today summary

    /// The hero number + two-stat row's underlying figures.
    struct Summary: Equatable {
        var dailyBase: Decimal
        var carriedForward: Decimal
        var limit: Decimal
        var spentToday: Decimal
        var remaining: Decimal
    }

    /// The hero number + two-stat row, computed across every active goal (never pooled
    /// — each goal's own carry-forward is summed independently, per
    /// `DailyLimitCalculator.totalDailyLimit`) plus any orphaned transaction
    /// (`savingsGoal == nil`) dated today, which still counts against the user's spend
    /// even though it isn't attributed to a specific goal.
    ///
    /// `completedUndismissedGoals` only affects `spentToday`/`remaining`: a goal whose
    /// `targetDate` has passed but hasn't been dismissed yet is still "current" from the
    /// spend-tracking point of view — its transactions shouldn't vanish from
    /// `spentToday` the instant the target date passes, only once the user dismisses its
    /// completion banner (see `TodayScreenCalculator.spentToday`). It never contributes
    /// to `dailyBase`/`carriedForward`/`limit`, which are strictly a function of the
    /// still-active goal set.
    ///
    /// Returns `nil` when `activeGoals` is empty — the daily limit itself is undefined
    /// with no active goal. Callers that still need to surface today's spend in that
    /// case (finding: orphaned/completed-goal spend shouldn't disappear from the screen
    /// just because there's no active goal) should call `spentToday` directly instead of
    /// relying on this returning a `Summary`.
    static func summary(
        activeGoals: [SavingsGoal],
        completedUndismissedGoals: [SavingsGoal] = [],
        allTransactions: [SpendTransaction],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Summary? {
        guard !activeGoals.isEmpty else { return nil }

        let goalLimits = activeGoals.map {
            DailyLimitCalculator.dailyLimit(for: carryForwardInput(for: $0, calendar: calendar), asOf: referenceDate, calendar: calendar)
        }
        let dailyBase = goalLimits.reduce(Decimal(0)) { $0 + $1.dailyBase }
        let carriedForward = goalLimits.reduce(Decimal(0)) { $0 + $1.carryForward }
        let limit = goalLimits.reduce(Decimal(0)) { $0 + $1.limit }

        let spentToday = self.spentToday(
            allTransactions: allTransactions,
            attributedGoals: activeGoals + completedUndismissedGoals,
            referenceDate: referenceDate,
            calendar: calendar
        )

        return Summary(
            dailyBase: dailyBase,
            carriedForward: carriedForward,
            limit: limit,
            spentToday: spentToday,
            remaining: limit - spentToday
        )
    }

    /// Total spend today (variable transactions dated `referenceDate`) attributed to any
    /// goal in `attributedGoals`, plus any orphaned transaction (`savingsGoal == nil`),
    /// which always counts regardless of `attributedGoals` — it isn't attributed to a
    /// specific goal, so there's no goal-lifecycle state that could exclude it.
    ///
    /// Exposed standalone (not just as a `summary` implementation detail) so the Today
    /// screen can still show today's spend when there's no active goal — e.g. every goal
    /// is completed-but-undismissed — rather than that spend disappearing from view
    /// entirely just because `summary` returns `nil` in that case.
    static func spentToday(
        allTransactions: [SpendTransaction],
        attributedGoals: [SavingsGoal],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let today = calendar.startOfDay(for: referenceDate)
        let attributedGoalIDs = Set(attributedGoals.map(\.persistentModelID))
        return allTransactions.reduce(Decimal(0)) { total, transaction in
            guard transaction.type == .variable,
                  calendar.startOfDay(for: transaction.date) == today
            else { return total }

            let countsTowardLimit: Bool
            if let owningGoalID = transaction.savingsGoal?.persistentModelID {
                countsTowardLimit = attributedGoalIDs.contains(owningGoalID)
            } else {
                // Orphaned transaction (savingsGoal == nil) — still counts, per this
                // story's acceptance criteria.
                countsTowardLimit = true
            }
            return countsTowardLimit ? total + transaction.amount : total
        }
    }

    // MARK: - Recent transactions

    /// The most recent `limit` transactions across all goals (including orphaned ones),
    /// most-recent first. Ties on `date` break by `createdAt` (most recently created
    /// first), so same-day entries land in a stable, predictable order regardless of
    /// fetch order.
    static func recentTransactions(
        from transactions: [SpendTransaction],
        limit: Int = 3
    ) -> [SpendTransaction] {
        Array(
            transactions
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date > rhs.date }
                    return lhs.createdAt > rhs.createdAt
                }
                .prefix(limit)
        )
    }
}
