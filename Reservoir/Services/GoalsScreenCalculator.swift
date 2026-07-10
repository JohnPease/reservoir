import Foundation
import SwiftData

/// Business logic unique to the Goals screen (adq.5): progress-percentage math and the
/// two pace-projection reads ("Pace" / "Simulation"). Goal lifecycle primitives
/// (`activeGoals`, `completedUndismissedGoals`, `isGoalMet`, the `GoalCarryForwardInput`
/// mapping) stay in `TodayScreenCalculator` as the single source of truth —
/// `GoalsScreenCalculator` calls into those rather than duplicating them (STANDARDS.md
/// §3). Kept out of `GoalsView` for the same testability reason `TodayScreenCalculator`
/// is kept out of `TodayView`.
///
/// Like `TodayScreenCalculator`, this imports `SwiftData` for the model types themselves
/// but never `SwiftUI` — the exact display copy is built in the view layer (matching how
/// `TodayView.CompletionBannerView` builds its own copy today), while this type exposes
/// structured, unit-testable results.
enum GoalsScreenCalculator {

    // MARK: - Progress

    /// `startingBalance + sum(all transactions attributed to this goal)` — per the
    /// bead's exact spec. `currentBalance` for a goal without a linked account
    /// (pre-Plaid, MVP) has no other ground truth to derive from; this mirrors how the
    /// daily limit already treats transactions as the source of truth rather than a
    /// separately persisted running balance.
    ///
    /// NOTE (engineer flag, not a silent reinterpretation): `SpendTransaction.amount` is
    /// always a positive spend magnitude (see `DailyLimitCalculator`, which subtracts it
    /// from `dailyBase`), and this app has no "deposit" transaction kind. Summing it here
    /// with a `+` means *more spending* is why `currentBalance` rises toward
    /// `targetAmount` — i.e. spending against this goal reads as progress, the opposite
    /// of the "underspend banks savings" carry-forward mechanic the rest of the app is
    /// built on. Implemented exactly as specified rather than silently changed to a
    /// carry-forward-based formula, since the bead states this formula explicitly and
    /// engineer isn't authorized to unilaterally reinterpret a stated product decision —
    /// flagged for product-lead confirmation before this ships.
    static func currentBalance(for goal: SavingsGoal) -> Decimal {
        goal.startingBalance + goal.transactions.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// `(currentBalance - startingBalance) / (targetAmount - startingBalance)`,
    /// unclamped — can be negative or exceed 1.0. Returns 0 if the denominator is <= 0
    /// (defensive; creation/edit validation requires `targetAmount > startingBalance`
    /// strictly, so this shouldn't be reachable via the validated UI flow).
    ///
    /// Takes `currentBalance` as a parameter rather than recomputing it from
    /// `goal.transactions` so callers that need multiple derived values in the same pass
    /// (e.g. `ActiveGoalCardView`'s single render) can compute `currentBalance` once and
    /// thread it through, instead of each sub-computation independently re-deriving it —
    /// see the `for goal:` overload below for the single-call convenience form.
    static func progressFraction(currentBalance: Decimal, goal: SavingsGoal) -> Decimal {
        let denominator = goal.targetAmount - goal.startingBalance
        guard denominator > 0 else { return 0 }
        return (currentBalance - goal.startingBalance) / denominator
    }

    /// Convenience overload that derives `currentBalance` itself — for call sites that
    /// only need this one value and aren't already holding a precomputed
    /// `currentBalance`.
    static func progressFraction(for goal: SavingsGoal) -> Decimal {
        progressFraction(currentBalance: currentBalance(for: goal), goal: goal)
    }

    /// `progressFraction`, clamped to `[0, 1]` for progress-bar fill. The percentage
    /// *text* shown alongside the bar uses the unclamped value so a negative or
    /// over-100% goal is still shown truthfully (PROJECT_SPEC trust principle) even
    /// though the bar itself visually clamps.
    static func clampedProgressFraction(currentBalance: Decimal, goal: SavingsGoal) -> Decimal {
        min(max(progressFraction(currentBalance: currentBalance, goal: goal), 0), 1)
    }

    /// Convenience overload — see `progressFraction(for:)`.
    static func clampedProgressFraction(for goal: SavingsGoal) -> Decimal {
        clampedProgressFraction(currentBalance: currentBalance(for: goal), goal: goal)
    }

    /// `progressFraction * 100`, rounded to the nearest whole percent (ties away from
    /// zero) for the "N% to goal" caption. Takes `currentBalance` for the same
    /// single-computation-per-render reason as `progressFraction(currentBalance:goal:)`.
    static func progressPercentRounded(currentBalance: Decimal, goal: SavingsGoal) -> Int {
        decimalRound(progressFraction(currentBalance: currentBalance, goal: goal) * 100)
    }

    /// Convenience overload — see `progressFraction(for:)`.
    static func progressPercentRounded(for goal: SavingsGoal) -> Int {
        progressPercentRounded(currentBalance: currentBalance(for: goal), goal: goal)
    }

    // MARK: - Pace segment

    /// The light, carryForward-sign-based pace read — unchanged math from the original
    /// spec, just exposed as a structured result so the view builds exact copy from it.
    enum PaceStatus: Equatable {
        /// `dailyBase == 0` (same-day start/target) — defensive; not reachable via the
        /// validated creation/edit flow (`targetDate > startDate` is always enforced).
        case unavailable
        case onPace(targetDate: Date)
        case behindPace(daysBehind: Int)
    }

    /// Takes the already-mapped `GoalCarryForwardInput` rather than re-deriving it from
    /// `goal.transactions` — see the `for goal:` overload below for the single-call
    /// convenience form, and `progressFraction(currentBalance:goal:)`'s doc comment for
    /// why this split exists.
    static func paceStatus(
        input: GoalCarryForwardInput,
        targetDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> PaceStatus {
        guard input.dailyBase != 0 else { return .unavailable }

        let limit = DailyLimitCalculator.dailyLimit(for: input, asOf: referenceDate, calendar: calendar)
        guard limit.carryForward >= 0 else {
            let daysBehind = daysBehindCount(carryForward: limit.carryForward, dailyBase: input.dailyBase)
            return .behindPace(daysBehind: daysBehind)
        }
        return .onPace(targetDate: targetDate)
    }

    /// Convenience overload that derives the `GoalCarryForwardInput` itself — for call
    /// sites that only need this one value and aren't already holding a precomputed
    /// input.
    static func paceStatus(
        for goal: SavingsGoal,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> PaceStatus {
        paceStatus(
            input: TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar),
            targetDate: goal.targetDate,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    /// `N = ceil(abs(carryForward) / dailyBase)`.
    private static func daysBehindCount(carryForward: Decimal, dailyBase: Decimal) -> Int {
        let ratio = abs(carryForward) / dailyBase
        return decimalCeil(ratio)
    }

    // MARK: - Simulation segment

    /// Trailing-window length, in calendar days, used for the Simulation segment's
    /// `avgDailyNet`. 14, not 7: a 7-day window is skewed by which weekday "today"
    /// happens to be; 14 days spans two weekly cycles and smooths that out while staying
    /// recent — a product/UX call, not an engineering default (see bead description).
    static let simulationWindowDays = 14

    enum SimulationStatus: Equatable {
        /// `dailyBase == 0` — same defensive/unreachable-via-validated-UI guard as
        /// `PaceStatus.unavailable`.
        case unavailable
        /// Goal created today, or genuinely zero variable spend logged in the window —
        /// do not fabricate an average from zero data points.
        case notEnoughHistory
        case computed(SimulationProjection)
    }

    struct SimulationProjection: Equatable {
        var avgDailyNet: Decimal
        var projectedSurplusShortfall: Decimal
        var daysRemaining: Int
        var completionOutcome: CompletionOutcome
    }

    enum CompletionOutcome: Equatable {
        case onSchedule(date: Date)
        case early(days: Int, date: Date)
        case late(days: Int, date: Date)
    }

    /// Takes the already-mapped `GoalCarryForwardInput` rather than re-deriving it from
    /// `goal.transactions` — see `paceStatus(input:targetDate:referenceDate:calendar:)`'s
    /// doc comment for why this split exists.
    static func simulationStatus(
        input: GoalCarryForwardInput,
        targetDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> SimulationStatus {
        guard input.dailyBase != 0 else { return .unavailable }

        let today = calendar.startOfDay(for: referenceDate)
        let effectiveStart = calendar.startOfDay(for: input.effectiveStartDate)
        let daysSinceStart = max(0, calendar.dateComponents([.day], from: effectiveStart, to: today).day ?? 0)
        let windowLength = min(simulationWindowDays, daysSinceStart)
        guard windowLength > 0 else { return .notEnoughHistory }

        let avgDailyNet = averageDailyNet(
            dailyBase: input.dailyBase,
            spendEntries: input.spendEntries,
            windowLength: windowLength,
            today: today,
            calendar: calendar
        )

        let targetDay = calendar.startOfDay(for: targetDate)
        let daysRemaining = calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0
        let projectedSurplusShortfall = avgDailyNet * Decimal(daysRemaining)

        let completionOutcome = self.completionOutcome(
            avgDailyNet: avgDailyNet,
            projectedSurplusShortfall: projectedSurplusShortfall,
            dailyBase: input.dailyBase,
            targetDate: targetDay,
            today: today,
            calendar: calendar
        )

        return .computed(SimulationProjection(
            avgDailyNet: avgDailyNet,
            projectedSurplusShortfall: projectedSurplusShortfall,
            daysRemaining: daysRemaining,
            completionOutcome: completionOutcome
        ))
    }

    /// Convenience overload that derives the `GoalCarryForwardInput` itself — for call
    /// sites that only need this one value and aren't already holding a precomputed
    /// input.
    static func simulationStatus(
        for goal: SavingsGoal,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> SimulationStatus {
        simulationStatus(
            input: TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar),
            targetDate: goal.targetDate,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    /// Sum of `dailyBase - variableSpendThatDay` over the trailing `windowLength` days
    /// before `today` (today excluded — same convention `DailyLimitCalculator
    /// .carryForward` uses), divided by `windowLength`. A day with zero variable
    /// transactions contributes a full `+dailyBase`, consistent with how `carryForward`
    /// already treats gap days.
    private static func averageDailyNet(
        dailyBase: Decimal,
        spendEntries: [GoalCarryForwardInput.SpendEntry],
        windowLength: Int,
        today: Date,
        calendar: Calendar
    ) -> Decimal {
        var spendByDay: [Date: Decimal] = [:]
        for entry in spendEntries where entry.kind == .variable {
            let day = calendar.startOfDay(for: entry.date)
            spendByDay[day, default: 0] += entry.amount
        }

        let windowStart = calendar.date(byAdding: .day, value: -windowLength, to: today)!
        var totalNet: Decimal = 0
        for offset in 0..<windowLength {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart)!
            totalNet += dailyBase - (spendByDay[day] ?? 0)
        }
        return totalNet / Decimal(windowLength)
    }

    /// `avgDailyNet < 0`: `targetDate + ceil(abs(projectedSurplusShortfall) / dailyBase)`
    /// days. `avgDailyNet >= 0`: `targetDate - floor(projectedSurplusShortfall /
    /// dailyBase)` days, floored at not going earlier than tomorrow. `avgDailyNet == 0`
    /// exactly: no date arithmetic, on schedule at `targetDate` itself. `avgDailyNet > 0`
    /// with `targetDate == today` (zero days of remaining runway): also on schedule
    /// rather than "early" — `projectedSurplusShortfall` is always 0 with no runway, so
    /// there's no meaningful "early" — and without this guard the tomorrow-floor would
    /// push the reported completion date to one day *after* `targetDate`.
    private static func completionOutcome(
        avgDailyNet: Decimal,
        projectedSurplusShortfall: Decimal,
        dailyBase: Decimal,
        targetDate: Date,
        today: Date,
        calendar: Calendar
    ) -> CompletionOutcome {
        if avgDailyNet == 0 {
            return .onSchedule(date: targetDate)
        }

        if avgDailyNet < 0 {
            let lateDays = decimalCeil(abs(projectedSurplusShortfall) / dailyBase)
            let completionDate = calendar.date(byAdding: .day, value: lateDays, to: targetDate)!
            return .late(days: lateDays, date: completionDate)
        }

        if targetDate == today {
            return .onSchedule(date: targetDate)
        }

        let earlyDaysRaw = decimalFloor(projectedSurplusShortfall / dailyBase)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var completionDate = calendar.date(byAdding: .day, value: -earlyDaysRaw, to: targetDate)!
        if completionDate < tomorrow {
            completionDate = tomorrow
        }
        let earlyDays = max(0, calendar.dateComponents([.day], from: completionDate, to: targetDate).day ?? 0)
        return .early(days: earlyDays, date: completionDate)
    }

    // MARK: - Decimal rounding helpers

    /// Every call site passes a non-negative `value` (an `abs(...)` result or a ratio of
    /// two same-signed quantities), so `NSDecimalNumber.RoundingMode.up` ("round away
    /// from zero") is equivalent to a true mathematical ceiling here — it would NOT be
    /// for a negative input.
    private static func decimalCeil(_ value: Decimal) -> Int {
        var result = Decimal()
        var mutableValue = value
        NSDecimalRound(&result, &mutableValue, 0, .up)
        return (result as NSDecimalNumber).intValue
    }

    /// Same non-negative-input caveat as `decimalCeil`: `.down` ("round toward zero") is
    /// equivalent to a true mathematical floor only because every call site's `value` is
    /// non-negative.
    private static func decimalFloor(_ value: Decimal) -> Int {
        var result = Decimal()
        var mutableValue = value
        NSDecimalRound(&result, &mutableValue, 0, .down)
        return (result as NSDecimalNumber).intValue
    }

    /// Rounds to the nearest integer, ties away from zero (`.plain`) — unlike
    /// `decimalCeil`/`decimalFloor`, `progressPercentRounded`'s input can be negative (an
    /// over/under-target goal's unclamped percentage), so this uses `NSDecimalRound`'s
    /// true nearest-rounding mode rather than `.up`/`.down`, which are only equivalent to
    /// ceiling/floor for non-negative inputs. Replaces the previous
    /// `NSDecimalNumber(decimal:).intValue`, which truncates toward zero instead of
    /// rounding (code-review finding — 66.9% rendered as "66%", not "67%").
    private static func decimalRound(_ value: Decimal) -> Int {
        var result = Decimal()
        var mutableValue = value
        NSDecimalRound(&result, &mutableValue, 0, .plain)
        return (result as NSDecimalNumber).intValue
    }
}
