import Foundation

/// Pure, SwiftData/SwiftUI-independent implementation of the app's core mechanic: a
/// rolling daily spending limit with continuous carry-forward, per
/// `docs/PROJECT_SPEC.md` ("Core mechanic"). No `import SwiftData`/`import SwiftUI` —
/// this keeps the math unit-testable without a `ModelContainer` or the simulator.
///
/// The SwiftData layer (`SavingsGoal`/`SpendTransaction`) is mapped into the plain
/// value types below by the caller (Services/persistence layer), not here.
public enum DailyLimitCalculator {

    // MARK: - Base amount

    /// `base = (targetAmount - startingBalance) / totalDaysFromStart`, fixed at goal
    /// creation and recomputed only when the goal itself is edited (never recomputed
    /// retroactively against later balance drift — see PROJECT_SPEC "Core mechanic").
    ///
    /// `startDate`/`targetDate` are compared as whole device-local calendar days.
    /// Returns 0 if `targetDate` is not after `startDate` (defensive; creation-time
    /// validation in PROJECT_SPEC "Validation" should prevent this from occurring).
    public static func dailyBase(
        targetAmount: Decimal,
        startingBalance: Decimal,
        startDate: Date,
        targetDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let totalDays = totalDaysFromStart(startDate: startDate, targetDate: targetDate, calendar: calendar)
        guard totalDays > 0 else { return 0 }
        return (targetAmount - startingBalance) / Decimal(totalDays)
    }

    /// Whole calendar-day count from `startDate` to `targetDate` (device-local midnight
    /// boundaries), used as the divisor in `dailyBase`.
    public static func totalDaysFromStart(
        startDate: Date,
        targetDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let target = calendar.startOfDay(for: targetDate)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    // MARK: - Carry-forward

    /// Accumulated carry-forward for one goal, summed over every complete calendar day
    /// from `goal.effectiveStartDate` up to (but excluding) `referenceDate`'s calendar
    /// day. Positive means underspend banked forward; negative means overspend borrowed
    /// from future days. Today's own spend is intentionally excluded — the Today screen
    /// derives "remaining" separately from today's transactions (see PROJECT_SPEC "UX
    /// design — Today screen").
    ///
    /// Days with no recorded spend still contribute a full `dailyBase` to the carry
    /// forward, which is what makes multi-day gaps (app not opened for several days)
    /// resolve correctly without any special-casing.
    public static func carryForward(
        for goal: GoalCarryForwardInput,
        asOf referenceDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let startDay = calendar.startOfDay(for: goal.effectiveStartDate)
        let today = calendar.startOfDay(for: referenceDate)
        guard startDay < today else { return 0 }

        let spentByDay = variableSpendByDay(goal.spendEntries, calendar: calendar)

        var carry: Decimal = 0
        var day = startDay
        while day < today {
            carry += goal.dailyBase - (spentByDay[day] ?? 0)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return carry
    }

    /// Today's limit for a single goal: `dailyBase + carryForward`.
    public static func dailyLimit(
        for goal: GoalCarryForwardInput,
        asOf referenceDate: Date,
        calendar: Calendar = .current
    ) -> GoalDailyLimit {
        let carry = carryForward(for: goal, asOf: referenceDate, calendar: calendar)
        return GoalDailyLimit(id: goal.id, dailyBase: goal.dailyBase, carryForward: carry, limit: goal.dailyBase + carry)
    }

    /// Total daily limit across every active goal: the **sum** of each goal's
    /// independently computed base + carry-forward. Goals are never pooled — each
    /// tracks its own carry-forward balance in isolation (see PROJECT_SPEC "Multi-goal
    /// scope").
    public static func totalDailyLimit(
        for goals: [GoalCarryForwardInput],
        asOf referenceDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        goals.reduce(Decimal(0)) { $0 + dailyLimit(for: $1, asOf: referenceDate, calendar: calendar).limit }
    }

    // MARK: - Private helpers

    /// Sums spend entries per calendar day, counting only `.variable`-kind entries.
    /// `.fixed` entries reduce the goal's account balance elsewhere but are excluded
    /// from the limit/carry-forward math (PROJECT_SPEC "Fixed expenses").
    private static func variableSpendByDay(
        _ entries: [GoalCarryForwardInput.SpendEntry],
        calendar: Calendar
    ) -> [Date: Decimal] {
        entries.reduce(into: [:]) { result, entry in
            guard entry.kind == .variable else { return }
            let day = calendar.startOfDay(for: entry.date)
            result[day, default: 0] += entry.amount
        }
    }
}

// MARK: - Input/output value types

/// A pure snapshot of one `SavingsGoal`'s spend history, mapped from SwiftData by the
/// caller and fed into `DailyLimitCalculator`.
public struct GoalCarryForwardInput: Equatable {

    /// Whether a spend entry counts against the daily limit. Fixed expenses (e.g. rent)
    /// still reduce the account balance backing a goal but are excluded here.
    public enum SpendKind: Equatable {
        case variable
        case fixed
    }

    /// One dated, kinded spend amount attributed to a goal. Mirrors the fields of
    /// `SpendTransaction` the calculator actually needs, without importing SwiftData.
    public struct SpendEntry: Equatable {
        public var date: Date
        public var amount: Decimal
        public var kind: SpendKind

        public init(date: Date, amount: Decimal, kind: SpendKind) {
            self.date = date
            self.amount = amount
            self.kind = kind
        }
    }

    /// Identifies the goal for the caller's benefit (e.g. a `PersistentIdentifier`
    /// wrapped in `AnyHashable`); the calculator itself only uses it to key results.
    public var id: AnyHashable

    /// Fixed at goal creation, or reset at the goal's most recent edit — see
    /// `DailyLimitCalculator.dailyBase`. Owned by the caller, not recomputed here.
    public var dailyBase: Decimal

    /// The date carry-forward starts accumulating from: the goal's creation date, or —
    /// if the goal has since been edited — the date of the most recent edit. An edit is
    /// treated as a new goal state (PROJECT_SPEC "Core mechanic"), so any carry-forward
    /// banked before the edit is intentionally not carried across; entries dated before
    /// `effectiveStartDate` are simply never visited by `carryForward`.
    public var effectiveStartDate: Date

    /// All spend entries attributed to this goal, variable and fixed alike. Passing both
    /// kinds (rather than pre-filtering) lets the calculator itself enforce and be
    /// tested on the fixed/variable exclusion rule.
    public var spendEntries: [SpendEntry]

    public init(id: AnyHashable, dailyBase: Decimal, effectiveStartDate: Date, spendEntries: [SpendEntry]) {
        self.id = id
        self.dailyBase = dailyBase
        self.effectiveStartDate = effectiveStartDate
        self.spendEntries = spendEntries
    }
}

/// The computed daily limit for a single goal, decomposed so callers (the Today screen)
/// can render "$base + $carried forward" per PROJECT_SPEC's UX design.
public struct GoalDailyLimit: Equatable {
    public var id: AnyHashable
    public var dailyBase: Decimal
    public var carryForward: Decimal
    public var limit: Decimal
}
