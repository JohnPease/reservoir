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
        let dayCount = calendar.dateComponents([.day], from: startDay, to: today).day ?? 0
        let resetsOnFirst = goal.monthBoundary == .reset

        var carry: Decimal = 0
        for offset in 0..<dayCount {
            let day = calendar.date(byAdding: .day, value: offset, to: startDay)!
            if resetsOnFirst && calendar.component(.day, from: day) == 1 {
                carry = 0
            }
            carry += goal.schedule.base(on: day, calendar: calendar) - (spentByDay[day] ?? 0)
        }
        // The loop only visits days *before* `referenceDate`'s day, so a reset that falls
        // exactly on `referenceDate`'s own day (the 1st) must be applied here.
        if resetsOnFirst && calendar.component(.day, from: today) == 1 {
            carry = 0
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
        let base = goal.schedule.base(on: calendar.startOfDay(for: referenceDate), calendar: calendar)
        return GoalDailyLimit(id: goal.id, dailyBase: base, carryForward: carry, limit: base + carry)
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

    // MARK: - Goal-met verification

    /// Whether the goal's cumulative carry-forward balance was >= 0 across its full
    /// lifetime (`effectiveStartDate` through `targetDate` inclusive) — i.e. the user
    /// never net-overspent once the whole plan is taken into account. A day where the
    /// user went over their daily limit but recovered later does NOT disqualify — only
    /// the final cumulative position at `targetDate` matters (carry-forward is designed
    /// to absorb exactly this kind of fluctuation; see PROJECT_SPEC "Core mechanic").
    ///
    /// Implemented by calling `carryForward` with `referenceDate = targetDate + 1 day`,
    /// which sums every day through `targetDate` inclusive (entries dated after
    /// `targetDate` are naturally excluded since the day-loop only visits offsets within
    /// that window) — no new day-by-day logic needed.
    public static func isGoalMet(
        for goal: GoalCarryForwardInput,
        targetDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let dayAfterTarget = calendar.date(byAdding: .day, value: 1, to: targetDate)!
        return carryForward(for: goal, asOf: dayAfterTarget, calendar: calendar) >= 0
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

    /// How much each day contributes before spend is subtracted. Goals use
    /// `.constant` (fixed at creation/edit, see `DailyLimitCalculator.dailyBase`); the
    /// monthly budget uses `.monthly`. Owned by the caller, not recomputed here.
    public var schedule: BaseSchedule

    /// Whether carry rolls across month boundaries (goals, and a budget in "Carry over"
    /// mode) or is zeroed on every 1st (a budget in "Start fresh" mode).
    public var monthBoundary: MonthBoundary

    /// The base on `effectiveStartDate` — for goals (a `.constant` schedule) simply the
    /// goal's fixed daily base. Kept so existing call sites that read a scalar base
    /// compile unchanged.
    public var dailyBase: Decimal {
        schedule.base(on: effectiveStartDate, calendar: .current)
    }

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

    public init(
        id: AnyHashable,
        schedule: BaseSchedule,
        monthBoundary: MonthBoundary = .carry,
        effectiveStartDate: Date,
        spendEntries: [SpendEntry]
    ) {
        self.id = id
        self.schedule = schedule
        self.monthBoundary = monthBoundary
        self.effectiveStartDate = effectiveStartDate
        self.spendEntries = spendEntries
    }

    /// Convenience for the constant-base, carry-across-months shape every goal uses.
    public init(id: AnyHashable, dailyBase: Decimal, effectiveStartDate: Date, spendEntries: [SpendEntry]) {
        self.init(
            id: id,
            schedule: .constant(dailyBase),
            effectiveStartDate: effectiveStartDate,
            spendEntries: spendEntries
        )
    }
}

/// The per-day base amount a calculator window accrues.
public enum BaseSchedule: Equatable {
    /// The same base every day (savings goals).
    case constant(Decimal)
    /// A monthly amount spread evenly over the days of whichever month a day falls in:
    /// `monthlyAmount / daysInMonth(day)`, never `*12/365`.
    case monthly(Decimal)

    /// Decimal places the per-day share is rounded to so a month's days always sum to
    /// *exactly* the monthly amount (`Decimal` division is otherwise inexact for e.g.
    /// 1000/30): every day but the month's last gets the rounded share, and the last day
    /// absorbs the sub-1e-9 remainder. 10 places is far below a cent.
    static let monthlyShareScale = 10

    public func base(on day: Date, calendar: Calendar) -> Decimal {
        switch self {
        case .constant(let amount):
            return amount
        case .monthly(let monthlyAmount):
            guard let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count, daysInMonth > 0 else {
                return 0
            }
            var share = monthlyAmount / Decimal(daysInMonth)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &share, Self.monthlyShareScale, .plain)
            if calendar.component(.day, from: day) == daysInMonth {
                return monthlyAmount - rounded * Decimal(daysInMonth - 1)
            }
            return rounded
        }
    }
}

/// What happens to accumulated carry when a new month begins.
public enum MonthBoundary: Equatable {
    /// Surplus and debt roll across months (goals; budget "Carry over").
    case carry
    /// Carry is zeroed on each 1st — a clean slate (budget "Start fresh").
    case reset
}

/// The computed daily limit for a single goal, decomposed so callers (the Today screen)
/// can render "$base + $carried forward" per PROJECT_SPEC's UX design.
public struct GoalDailyLimit: Equatable {
    public var id: AnyHashable
    public var dailyBase: Decimal
    public var carryForward: Decimal
    public var limit: Decimal
}
