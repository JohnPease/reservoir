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

    /// `startingBalance + carryForward` — the same banked-surplus carry-forward the
    /// daily limit and Today screen already use, evaluated `asOf: referenceDate`
    /// (reservoir-1et; confirmed product decision, JP 2026-07-10, replacing the earlier
    /// `startingBalance + sum(transactions)` formula that made *more spending* move the
    /// goal progress bar *up* — the opposite of the "underspend banks savings"
    /// carry-forward mechanic used everywhere else).
    ///
    /// Walkthrough this formula satisfies: spending $0/day banks the full `dailyBase`
    /// every day, so `currentBalance == targetAmount` (100%) by `targetDate`. Spending
    /// exactly today's displayed daily limit (`dailyBase + carryForward`) nets zero
    /// progress change that day. Overspending drives `carryForward` negative, so
    /// `currentBalance` can drop below `startingBalance`. Fixed-kind transactions don't
    /// erode progress because `DailyLimitCalculator.carryForward` already excludes them
    /// from its per-day sum (see its `variableSpendByDay` helper) — `currentBalance`
    /// inherits that exclusion for free by building on `carryForward` rather than
    /// re-deriving from `goal.transactions` itself.
    ///
    /// Takes the already-mapped `GoalCarryForwardInput` rather than re-deriving it from
    /// `goal.transactions` — see the `for goal:` overload below for the single-call
    /// convenience form, and `paceStatus(input:targetDate:referenceDate:calendar:)`'s
    /// doc comment for why this split exists.
    static func currentBalance(
        input: GoalCarryForwardInput,
        goal: SavingsGoal,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let limit = DailyLimitCalculator.dailyLimit(for: input, asOf: referenceDate, calendar: calendar)
        return goal.startingBalance + limit.carryForward
    }

    /// Convenience overload that derives the `GoalCarryForwardInput` itself — for call
    /// sites that only need this one value and aren't already holding a precomputed
    /// input.
    static func currentBalance(for goal: SavingsGoal, referenceDate: Date, calendar: Calendar = .current) -> Decimal {
        currentBalance(
            input: TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar),
            goal: goal,
            referenceDate: referenceDate,
            calendar: calendar
        )
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
    /// see the `for goal:` overload below for the single-call convenience form. No
    /// `referenceDate` needed here directly — it's already baked into the
    /// `currentBalance` value passed in.
    static func progressFraction(currentBalance: Decimal, goal: SavingsGoal) -> Decimal {
        let denominator = goal.targetAmount - goal.startingBalance
        guard denominator > 0 else { return 0 }
        return (currentBalance - goal.startingBalance) / denominator
    }

    /// Convenience overload that derives `currentBalance` itself — for call sites that
    /// only need this one value and aren't already holding a precomputed
    /// `currentBalance`.
    static func progressFraction(for goal: SavingsGoal, referenceDate: Date, calendar: Calendar = .current) -> Decimal {
        progressFraction(currentBalance: currentBalance(for: goal, referenceDate: referenceDate, calendar: calendar), goal: goal)
    }

    /// `progressFraction`, clamped to `[0, 1]` for progress-bar fill. The percentage
    /// *text* shown alongside the bar uses the unclamped value so a negative or
    /// over-100% goal is still shown truthfully (PROJECT_SPEC trust principle) even
    /// though the bar itself visually clamps.
    static func clampedProgressFraction(currentBalance: Decimal, goal: SavingsGoal) -> Decimal {
        min(max(progressFraction(currentBalance: currentBalance, goal: goal), 0), 1)
    }

    /// Convenience overload — see `progressFraction(for:referenceDate:calendar:)`.
    static func clampedProgressFraction(for goal: SavingsGoal, referenceDate: Date, calendar: Calendar = .current) -> Decimal {
        clampedProgressFraction(currentBalance: currentBalance(for: goal, referenceDate: referenceDate, calendar: calendar), goal: goal)
    }

    /// `progressFraction * 100`, rounded to the nearest whole percent (ties away from
    /// zero) for the "N% to goal" caption. Takes `currentBalance` for the same
    /// single-computation-per-render reason as `progressFraction(currentBalance:goal:)`.
    static func progressPercentRounded(currentBalance: Decimal, goal: SavingsGoal) -> Int {
        decimalRound(progressFraction(currentBalance: currentBalance, goal: goal) * 100)
    }

    /// Convenience overload — see `progressFraction(for:referenceDate:calendar:)`.
    static func progressPercentRounded(for goal: SavingsGoal, referenceDate: Date, calendar: Calendar = .current) -> Int {
        progressPercentRounded(currentBalance: currentBalance(for: goal, referenceDate: referenceDate, calendar: calendar), goal: goal)
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

    // MARK: - Spend chart (reservoir-t5u)

    /// One day's plotted point for the per-goal spend chart: that day's variable spend
    /// and that day's own daily limit (`dailyBase + carryForward`, as of that day),
    /// suitable for a `BarMark` + per-day `RuleMark` pair. `id` is the day itself — days
    /// within one goal's window are always unique.
    public struct DailySpendPoint: Equatable, Identifiable {
        public var day: Date
        public var variableSpend: Decimal
        public var dailyLimit: Decimal
        public var id: Date { day }

        public init(day: Date, variableSpend: Decimal, dailyLimit: Decimal) {
            self.day = day
            self.variableSpend = variableSpend
            self.dailyLimit = dailyLimit
        }
    }

    /// The chart window length for a given goal/`windowEnd` pair: `min(30, days from the
    /// goal's `effectiveStartDate` through `windowEnd`, inclusive)`. Pulled out as its own
    /// function so `chartWindowCount`/tests can reason about window length without
    /// building the full point array.
    static func chartWindowLength(
        effectiveStartDate: Date,
        windowEnd: Date,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: effectiveStartDate)
        let end = calendar.startOfDay(for: windowEnd)
        guard start <= end else { return 0 }
        let daysSinceStart = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return min(30, daysSinceStart)
    }

    /// Builds the windowed `(day, variableSpend, dailyLimit)` array for one goal, ending
    /// on `windowEnd` (inclusive) and covering the trailing 30 days OR the goal's full
    /// history since `input.effectiveStartDate`, whichever is shorter — same rule
    /// `chartWindowLength` computes. `windowEnd` is a parameter, never `Date()` internally,
    /// so this same function serves both the compact card (`windowEnd = today`) and the
    /// modal's historical paging (`windowEnd` = an arbitrary earlier date) — see
    /// `chartWindowEnd(page:referenceDate:calendar:)` for how the modal derives that
    /// earlier date.
    ///
    /// Reuses `DailyLimitCalculator.variableSpendByDay` (now internal, not private — see
    /// its doc comment) for the per-day spend bucketing, and
    /// `DailyLimitCalculator.dailyLimit(for:asOf:)` for each day's limit — no
    /// reimplementation of either (STANDARDS.md §3). Pure Foundation math; no view-layer
    /// logic, so it's directly unit-testable on boundary cases (goal younger than 30
    /// days, `windowEnd` before the goal existed, etc.) without SwiftUI or SwiftData.
    static func spendChartWindow(
        input: GoalCarryForwardInput,
        windowEnd: Date,
        calendar: Calendar = .current
    ) -> [DailySpendPoint] {
        let windowLength = chartWindowLength(effectiveStartDate: input.effectiveStartDate, windowEnd: windowEnd, calendar: calendar)
        guard windowLength > 0 else { return [] }

        let end = calendar.startOfDay(for: windowEnd)
        let windowStart = calendar.date(byAdding: .day, value: -(windowLength - 1), to: end)!
        let spentByDay = DailyLimitCalculator.variableSpendByDay(input.spendEntries, calendar: calendar)

        var points: [DailySpendPoint] = []
        points.reserveCapacity(windowLength)
        for offset in 0..<windowLength {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart)!
            let limit = DailyLimitCalculator.dailyLimit(for: input, asOf: day, calendar: calendar).limit
            points.append(DailySpendPoint(day: day, variableSpend: spentByDay[day] ?? 0, dailyLimit: limit))
        }
        return points
    }

    /// Convenience overload that derives the `GoalCarryForwardInput` itself — for call
    /// sites that only need this one value and aren't already holding a precomputed
    /// input. See the `input:` overload's doc comment for the full behavior.
    static func spendChartWindow(
        for goal: SavingsGoal,
        windowEnd: Date,
        calendar: Calendar = .current
    ) -> [DailySpendPoint] {
        spendChartWindow(
            input: TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar),
            windowEnd: windowEnd,
            calendar: calendar
        )
    }

    /// How many 30-day (or shorter) windows exist between `effectiveStartDate` and
    /// `referenceDate`, inclusive — the page count `SpendingChartDetailView`'s pager
    /// bounds itself to. Always >= 1 so a goal younger than one full window still gets a
    /// single (short) page rather than zero.
    static func chartWindowCount(
        effectiveStartDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: effectiveStartDate)
        let end = calendar.startOfDay(for: referenceDate)
        guard start <= end else { return 1 }
        let totalDays = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return max(1, Int(ceil(Double(totalDays) / 30.0)))
    }

    /// The `windowEnd` for page `page` of the modal's pager: `page == 0` is the current
    /// (most recent) 30-day window ending on `referenceDate`; each increment steps back
    /// one further 30-day window. The earliest page's resulting window is naturally
    /// shorter than 30 days (handled by `chartWindowLength`/`spendChartWindow` themselves)
    /// rather than needing separate clamp logic here — `chartWindowCount` already bounds
    /// how many pages exist, so callers never pass a `page` that would compute a
    /// `windowEnd` before the goal's `effectiveStartDate`.
    static func chartWindowEnd(
        page: Int,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: -30 * page, to: today)!
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
