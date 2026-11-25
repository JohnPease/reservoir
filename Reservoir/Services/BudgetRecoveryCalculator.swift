import Foundation

/// Budget recovery and month warnings (reservoir-nka.1): how long until a budget that is behind
/// gets its full daily limit back at the user's usual pace, a shorter "keep to" target, and one
/// month-level warning (tracking over, hard to recover, point of no return), composed into an
/// at-most-two-line banner for Today. Pure: no SwiftData, no SwiftUI, nothing persisted; every
/// input is a plain value resolved by `BudgetSummaryCalculator.insights`, which runs this only
/// when the caller passes `includeRecovery: true` (Today; the widget will with reservoir-nka.2).
///
/// Notation (all amounts in dollars, `tolerance` = `BudgetSummaryCalculator.rightOnTolerance`):
/// - `C` (carry into the month) = `remaining - paceDelta` in carry mode (an exact identity with
///   the carry walk, so no new walk is needed), 0 in reset mode. A budget that started this
///   month has `C = 0` naturally.
/// - `available = windowBudget + C`; `daysLeft = daysInMonth - dayOfMonth` (from tomorrow).
/// - Debt `D = -remaining` is tomorrow's opening debt; the recovery block shows only when
///   `D >= tolerance`. The *payoff day* is the day whose spending at the usual pace clears it;
///   the full limit is back the day after (the *full-limit day*), which is what the copy names.
/// - Usual pace `U` = mean counted daily spend over the last 14 completed days (today excluded,
///   zero days included, floored at the budget start, each day capped at 2x its base); `nil`
///   with fewer than 7 completed days.
enum BudgetRecoveryCalculator {

    static let usualPaceLookbackDays = 14
    static let usualPaceMinimumDays = 7
    /// Each day's spend counts at most this multiple of that day's base toward `U`, so one big
    /// purchase doesn't make the usual pace look permanently high.
    static let usualPaceDailyCapMultiple: Decimal = 2
    static let lowTypicalLookbackDays = 90
    static let lowTypicalMinimumDays = 28
    static let lowTypicalWindowDays = 7
    /// Nearest-rank percentile of the rolling weekly averages used as "almost any week".
    static let lowTypicalPercentile = 10
    /// Forward walk cap for carry-mode recovery.
    static let recoveryHorizonDays = 366
    static let targetDayRange = 3...7

    // MARK: - Output types

    enum Outcome: Codable, Equatable {
        /// The full limit is back on the given day (the day after the payoff day), `Int` days
        /// from today, so at least 2: tomorrow still opens with the debt. In reset mode a payoff
        /// on the month's last day gives the next 1st (where the limit is full anyway).
        case days(Int, on: Date)
        /// Carry mode: the usual pace never pays the debt down (within the walk cap).
        case never
        /// Reset mode: still behind when the month resets on this day (the next 1st).
        case resetsOnFirst(Date)
        /// Too little history for a usual pace.
        case unavailable
    }

    struct Target: Codable, Equatable {
        /// Whole dollars, rounded down.
        var daily: Decimal
        /// The horizon: keep to `daily` for this many days from tomorrow.
        var days: Int
        /// The full-limit day: the day after the horizon's last day.
        var by: Date
    }

    struct Recovery: Codable, Equatable {
        var debt: Decimal
        var usualDaily: Decimal?
        var outcome: Outcome
        /// Carry mode only: the full-limit day falls in a later month than today.
        var crossesMonth: Bool
        var target: Target?
    }

    struct Warning: Codable, Equatable {
        var level: BudgetWarningLevel
        /// Unrounded `(available - spent) / daysLeft` (may be zero or negative); the copy rounds
        /// it down. `nil` on the last day.
        var neededDaily: Decimal?
        /// P10 of rolling 7-day averages, computed only once tracking over holds (it decides
        /// level 2); `nil` otherwise, and with under 28 completed days of history.
        var lowTypicalDaily: Decimal?
        /// Levels 1 and 2: `-(projectedDelta + C)`.
        var headingOver: Decimal?
        /// Level 3: `spent - windowBudget - C`.
        var overBy: Decimal?
    }

    /// Up to two lines, each in the progress sentence's shape; only a level-3 line sets
    /// `deficitPhrase` (the one phrase a view colors).
    struct Banner: Codable, Equatable {
        var lines: [BudgetSummaryCalculator.ProgressSentence]

        var text: String { lines.map(\.text).joined(separator: " ") }
        /// Unused by Today's view today; intentional API for reservoir-nka.3/nka.4.
        var isDeficit: Bool { lines.contains { $0.deficitPhrase != nil } }
    }

    struct Result: Codable, Equatable {
        /// Unused by Today's view today; intentional API for reservoir-nka.3/nka.4.
        var monthStart: Date
        var carryIn: Decimal
        var recovery: Recovery?
        var warning: Warning
        var banner: Banner?
    }

    struct Input {
        var monthlyAmount: Decimal
        var monthBoundary: MonthBoundary
        /// Start of the reference day.
        var today: Date
        /// `BudgetCalculator.summary`'s remaining (limit - spent today).
        var remaining: Decimal
        /// Month-to-date counted spend, today included.
        var spent: Decimal
        var windowBudget: Decimal
        var paceDelta: Decimal
        /// The month-local `Projection.projectedDelta`, or `nil` when the projection is hidden.
        var projectedDelta: Decimal?
        var dayOfMonth: Int
        var daysInMonth: Int
        /// Counted spend keyed by `startOfDay` (`BudgetCalculator.countedSpendByDay`).
        var spentByDay: [Date: Decimal]
        var budgetStartDay: Date
    }

    // MARK: - Entry point

    static func result(_ input: Input, calendar: Calendar = .current) -> Result {
        let tolerance = BudgetSummaryCalculator.rightOnTolerance
        let today = input.today
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let nextMonthStart = calendar.dateInterval(of: .month, for: today)?.end ?? today
        let tomorrow = BudgetCalculator.nextDayStart(after: today, calendar: calendar)
        let daysLeft = max(0, input.daysInMonth - input.dayOfMonth)
        let carries = input.monthBoundary == .carry
        let carryIn = carryIn(remaining: input.remaining, paceDelta: input.paceDelta, boundary: input.monthBoundary)
        let schedule = BaseSchedule.monthly(input.monthlyAmount)

        // Recovery block.
        var recovery: Recovery?
        let debt = -input.remaining
        if debt >= tolerance {
            let usual = usualDailySpend(
                spentByDay: input.spentByDay, today: today, budgetStartDay: input.budgetStartDay,
                schedule: schedule, calendar: calendar
            )
            let outcome = recoveryOutcome(
                debt: debt, usualDaily: usual, tomorrow: tomorrow, nextMonthStart: nextMonthStart,
                boundary: input.monthBoundary, schedule: schedule, monthlyAmount: input.monthlyAmount, calendar: calendar
            )
            var crosses = false
            if carries, case .days(_, let day) = outcome { crosses = day >= nextMonthStart }
            recovery = Recovery(
                debt: debt,
                usualDaily: usual,
                outcome: outcome,
                crossesMonth: crosses,
                target: target(
                    debt: debt, outcome: outcome, tomorrow: tomorrow, daysLeft: daysLeft,
                    boundary: input.monthBoundary, schedule: schedule, calendar: calendar
                )
            )
        }

        let warning = warning(input, carryIn: carryIn, daysLeft: daysLeft, calendar: calendar)

        let banner = banner(
            recovery: recovery, warning: warning, carryIn: carryIn, carries: carries,
            today: today, tomorrow: tomorrow, nextMonthStart: nextMonthStart, daysLeft: daysLeft,
            schedule: schedule, calendar: calendar
        )

        return Result(monthStart: monthStart, carryIn: carryIn, recovery: recovery, warning: warning, banner: banner)
    }

    // MARK: - Carry in

    /// `C`: the carry the month started with. In carry mode `remaining = C + paceDelta` exactly
    /// (the carry walk's month-to-date part is `budgetedToDate - spent`), so no walk is needed.
    static func carryIn(remaining: Decimal, paceDelta: Decimal, boundary: MonthBoundary) -> Decimal {
        boundary == .carry ? remaining - paceDelta : 0
    }

    // MARK: - Usual pace

    /// Completed day starts in `[today - lookback, today)`, floored at `floor`, stepped
    /// DST-safely with `BudgetCalculator.nextDayStart`.
    static func completedDays(lookback: Int, before today: Date, notBefore floor: Date, calendar: Calendar) -> [Date] {
        guard let back = calendar.date(byAdding: .day, value: -lookback, to: today) else { return [] }
        var day = max(calendar.startOfDay(for: back), floor)
        var days: [Date] = []
        while day < today {
            days.append(day)
            day = BudgetCalculator.nextDayStart(after: day, calendar: calendar)
        }
        return days
    }

    static func usualDailySpend(
        spentByDay: [Date: Decimal],
        today: Date,
        budgetStartDay: Date,
        schedule: BaseSchedule,
        calendar: Calendar
    ) -> Decimal? {
        let days = completedDays(lookback: usualPaceLookbackDays, before: today, notBefore: budgetStartDay, calendar: calendar)
        guard days.count >= usualPaceMinimumDays else { return nil }
        let total = days.reduce(Decimal(0)) { total, day in
            let cap = usualPaceDailyCapMultiple * schedule.base(on: day, calendar: calendar)
            return total + min(spentByDay[day] ?? 0, cap)
        }
        return total / Decimal(days.count)
    }

    // MARK: - Recovery

    /// Walks payoff days from tomorrow adding `base(d) - U`; the outcome names the day after the
    /// payoff day (the full-limit day). Reset mode only walks payoff days within the month.
    static func recoveryOutcome(
        debt: Decimal,
        usualDaily: Decimal?,
        tomorrow: Date,
        nextMonthStart: Date,
        boundary: MonthBoundary,
        schedule: BaseSchedule,
        monthlyAmount: Decimal,
        calendar: Calendar
    ) -> Outcome {
        guard let usual = usualDaily else { return .unavailable }
        let resets = boundary == .reset
        // The largest base any day can have is a 28-day February's share.
        if !resets && usual >= monthlyAmount / 28 { return .never }

        var total: Decimal = 0
        var day = tomorrow
        for count in 1...recoveryHorizonDays {
            if resets && day >= nextMonthStart { break }
            total += schedule.base(on: day, calendar: calendar) - usual
            if total >= debt {
                // `count` payoff days from tomorrow; the full limit returns the day after.
                return .days(count + 1, on: BudgetCalculator.nextDayStart(after: day, calendar: calendar))
            }
            day = BudgetCalculator.nextDayStart(after: day, calendar: calendar)
        }
        return resets ? .resetsOnFirst(nextMonthStart) : .never
    }

    /// `n` = usual-pace payoff days; `N = ceil(n/2)` clamped to 3...7 (7 when there is no
    /// usual-pace day count). `T = (baseSum(tomorrow, N) - D) / N`, rounded down; keeping to it
    /// for `N` days pays the debt off, so `by` is the day after the horizon. Reset mode caps `N`
    /// at `daysLeft - 1` so `by` stays within the month (the limit is full on the 1st anyway).
    /// Hidden when `T < $1` or when `N >= n` (not nearer than the usual pace; payoff-day counts
    /// on both sides).
    static func target(
        debt: Decimal,
        outcome: Outcome,
        tomorrow: Date,
        daysLeft: Int,
        boundary: MonthBoundary,
        schedule: BaseSchedule,
        calendar: Calendar
    ) -> Target? {
        var usualPayoffDays: Int?
        if case .days(let count, _) = outcome { usualPayoffDays = count - 1 }
        var days = usualPayoffDays.map { min(max((($0 + 1) / 2), targetDayRange.lowerBound), targetDayRange.upperBound) }
            ?? targetDayRange.upperBound
        if boundary == .reset { days = min(days, daysLeft - 1) }
        guard days > 0 else { return nil }
        if let usualPayoffDays, days >= usualPayoffDays { return nil }

        let daily = (BudgetSummaryCalculator.baseSum(schedule, from: tomorrow, days: days, calendar: calendar) - debt) / Decimal(days)
        guard daily >= BudgetSummaryCalculator.rightOnTolerance else { return nil }
        var by = tomorrow
        for _ in 0..<days { by = BudgetCalculator.nextDayStart(after: by, calendar: calendar) }
        return Target(daily: BudgetSummaryCalculator.wholeDollars(daily, mode: .down), days: days, by: by)
    }

    // MARK: - Warnings

    /// Unrounded `(available - spent) / daysLeft`; `nil` on the month's last day.
    static func rawNeededDaily(available: Decimal, spent: Decimal, daysLeft: Int) -> Decimal? {
        daysLeft > 0 ? (available - spent) / Decimal(daysLeft) : nil
    }

    static func warning(_ input: Input, carryIn: Decimal, daysLeft: Int, calendar: Calendar) -> Warning {
        let tolerance = BudgetSummaryCalculator.rightOnTolerance
        let available = input.windowBudget + carryIn
        let rawNeeded = rawNeededDaily(available: available, spent: input.spent, daysLeft: daysLeft)
        var warning = Warning(level: .none, neededDaily: rawNeeded, lowTypicalDaily: nil, headingOver: nil, overBy: nil)

        let overBy = input.spent - available
        if BudgetSummaryCalculator.isOver(by: overBy) {
            warning.level = .pointOfNoReturn
            warning.overBy = overBy
            return warning
        }
        if let projected = input.projectedDelta, projected + carryIn <= -tolerance {
            warning.level = .trackingOver
            warning.headingOver = -(projected + carryIn)
            // Only needed here (it decides level 2), so the 90-day lookback runs only now.
            let lowTypical = lowTypicalDailySpend(
                spentByDay: input.spentByDay, today: input.today, budgetStartDay: input.budgetStartDay, calendar: calendar
            )
            warning.lowTypicalDaily = lowTypical
            // Compared unrounded; rounding is for display only.
            if let rawNeeded, let lowTypical, rawNeeded < lowTypical {
                warning.level = .hardToRecover
            }
        }
        return warning
    }

    /// P10 (nearest rank: the `ceil(p/100 * count)`-th smallest, at least the 1st) of every
    /// rolling 7-day average of counted daily spend over the last 90 completed days, zero days
    /// included, floored at the budget start. `nil` with under 28 completed days.
    static func lowTypicalDailySpend(
        spentByDay: [Date: Decimal],
        today: Date,
        budgetStartDay: Date,
        calendar: Calendar
    ) -> Decimal? {
        let days = completedDays(lookback: lowTypicalLookbackDays, before: today, notBefore: budgetStartDay, calendar: calendar)
        guard days.count >= lowTypicalMinimumDays else { return nil }
        let values = days.map { spentByDay[$0] ?? 0 }
        let width = lowTypicalWindowDays
        var averages: [Decimal] = []
        var windowSum = values[0..<width].reduce(0, +)
        averages.append(windowSum / Decimal(width))
        for index in width..<values.count {
            windowSum += values[index] - values[index - width]
            averages.append(windowSum / Decimal(width))
        }
        return nearestRank(percentile: lowTypicalPercentile, of: averages)
    }

    /// Nearest-rank percentile: sorted ascending, the value at rank `ceil(p * count / 100)`
    /// (1-based, at least 1).
    static func nearestRank(percentile: Int, of values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, (percentile * sorted.count + 99) / 100)
        return sorted[min(rank, sorted.count) - 1]
    }

    // MARK: - Banner

    /// Behind: line 1 = recovery headline (or the target when there is no usual pace), line 2 =
    /// the month warning, else the target. Not behind: the month warning alone. Neither: `nil`.
    static func banner(
        recovery: Recovery?,
        warning: Warning,
        carryIn: Decimal,
        carries: Bool,
        today: Date,
        tomorrow: Date,
        nextMonthStart: Date,
        daysLeft: Int,
        schedule: BaseSchedule,
        calendar: Calendar
    ) -> Banner? {
        let warningLine = warningLine(warning, carryIn: carryIn, carries: carries, today: today, nextMonthStart: nextMonthStart, calendar: calendar)
        var lines: [BudgetSummaryCalculator.ProgressSentence] = []
        if let recovery {
            let targetLine = recovery.target.map { plain(targetText($0, calendar: calendar)) }
            let headline = recoveryHeadline(
                recovery, carries: carries, tomorrow: tomorrow, nextMonthStart: nextMonthStart, daysLeft: daysLeft,
                schedule: schedule, calendar: calendar
            ).map(plain)
            var usedTarget = false
            if let headline {
                lines.append(headline)
            } else if let targetLine {
                lines.append(targetLine)
                usedTarget = true
            }
            if let warningLine {
                lines.append(warningLine)
            } else if let targetLine, !usedTarget {
                lines.append(targetLine)
            }
        } else if let warningLine {
            lines.append(warningLine)
        }
        return lines.isEmpty ? nil : Banner(lines: lines)
    }

    private static func plain(_ text: String) -> BudgetSummaryCalculator.ProgressSentence {
        BudgetSummaryCalculator.ProgressSentence(lead: text, deficitPhrase: nil, tail: "")
    }

    /// `nil` when there is no usual pace (the target line stands in). Names the full-limit day;
    /// "tomorrow" never applies because tomorrow still opens with the debt.
    static func recoveryHeadline(
        _ recovery: Recovery,
        carries: Bool,
        tomorrow: Date,
        nextMonthStart: Date,
        daysLeft: Int,
        schedule: BaseSchedule,
        calendar: Calendar
    ) -> String? {
        guard let usual = recovery.usualDaily else { return nil }
        let lead = "At your usual \(BudgetSummaryCalculator.whole(usual)) a day, "
        switch recovery.outcome {
        case .days(let count, let day):
            let limit = BudgetSummaryCalculator.whole(schedule.base(on: day, calendar: calendar))
            // Reset mode, paid off on the last day: the limit is full on the 1st either way.
            if !carries && day >= nextMonthStart { return lead + "your full \(limit) limit is back on the 1st." }
            let when = "in \(count) days (\(weekdayMonthDay(day, calendar: calendar)))"
            let crossing = recovery.crossesMonth ? ", carrying into \(monthName(day, calendar: calendar))" : ""
            return lead + "your full \(limit) limit is back \(when)\(crossing)."
        case .never:
            let limit = BudgetSummaryCalculator.whole(schedule.base(on: tomorrow, calendar: calendar))
            return lead + "you won't catch up. Your limit stays below \(limit) until you spend less."
        case .resetsOnFirst:
            return lead + "you'll still be behind when your limit resets \(daysLeft == 0 ? "tomorrow" : "on the 1st")."
        case .unavailable:
            return nil
        }
    }

    static func targetText(_ target: Target, calendar: Calendar) -> String {
        "Keep to \(BudgetSummaryCalculator.whole(target.daily)) a day to have your full limit back by \(weekdayMonthDay(target.by, calendar: calendar))."
    }

    /// `carryIn` is 0 in reset mode, so the carry clause is empty there; `carries` only picks
    /// wording that genuinely differs ("even" vs "on budget", the reset level-3 line).
    static func warningLine(
        _ warning: Warning,
        carryIn: Decimal,
        carries: Bool,
        today: Date,
        nextMonthStart: Date,
        calendar: Calendar
    ) -> BudgetSummaryCalculator.ProgressSentence? {
        let month = monthName(today, calendar: calendar)
        let clause = carryClause(carryIn)
        switch warning.level {
        case .none:
            return nil
        case .pointOfNoReturn:
            let overBy = BudgetSummaryCalculator.whole(warning.overBy ?? 0)
            guard carries else {
                return BudgetSummaryCalculator.ProgressSentence(
                    lead: "", deficitPhrase: "\(month)'s budget is spent.",
                    tail: " It starts fresh on \(BudgetSummaryCalculator.monthDay(nextMonthStart, calendar: calendar))."
                )
            }
            let phrase: String
            switch carrySign(carryIn) {
            case 1: phrase = "\(month)'s budget and the \(BudgetSummaryCalculator.whole(carryIn)) carried over are spent, \(overBy) over."
            case -1: phrase = "\(month)'s budget can't cover the \(BudgetSummaryCalculator.whole(-carryIn)) you started behind, \(overBy) over."
            default: phrase = "\(month)'s budget is spent, \(overBy) over."
            }
            return BudgetSummaryCalculator.ProgressSentence(
                lead: "", deficitPhrase: phrase,
                tail: " More spending this month carries into \(monthName(nextMonthStart, calendar: calendar))."
            )
        case .trackingOver, .hardToRecover:
            let heading = "Heading about \(BudgetSummaryCalculator.whole(warning.headingOver ?? 0)) over for \(month)\(clause.isEmpty ? "" : "," + clause). "
            let finish = carries ? "even" : "on budget"
            // Within the $1 tolerance of level 3 the raw need can be zero or negative.
            let needed = warning.neededDaily ?? 0
            if needed <= 0 { return plain(heading + "Finishing \(finish) means no more spending this month.") }
            let amount = neededText(needed)
            if warning.level == .trackingOver {
                return plain(heading + "Keep to \(amount) a day from tomorrow to finish \(finish).")
            }
            return plain(heading + "Finishing \(finish) takes \(amount) a day, lighter than almost any week you've had lately.")
        }
    }

    /// A positive daily need rounded down; under a dollar reads "under $1" rather than "$0".
    private static func neededText(_ amount: Decimal) -> String {
        amount >= 1 ? BudgetSummaryCalculator.whole(BudgetSummaryCalculator.wholeDollars(amount, mode: .down)) : "under $1"
    }

    /// 1, -1, or 0 when the carry rounds to under a dollar either way.
    private static func carrySign(_ carryIn: Decimal) -> Int {
        let rounded = BudgetSummaryCalculator.wholeDollars(carryIn)
        return rounded > 0 ? 1 : (rounded < 0 ? -1 : 0)
    }

    /// " counting the $500 carried over" / " counting the $300 you started behind", or "" when the
    /// carry rounds to under $1 (always in reset mode, where `C = 0`). Callers add any leading comma.
    static func carryClause(_ carryIn: Decimal) -> String {
        switch carrySign(carryIn) {
        case 1: return " counting the \(BudgetSummaryCalculator.whole(carryIn)) carried over"
        case -1: return " counting the \(BudgetSummaryCalculator.whole(-carryIn)) you started behind"
        default: return ""
        }
    }

    // MARK: - Date copy

    static func weekdayMonthDay(_ date: Date, calendar: Calendar) -> String {
        BudgetSummaryCalculator.formatted(date, "EEE, MMM d", calendar: calendar)
    }

    static func monthName(_ date: Date, calendar: Calendar) -> String {
        BudgetSummaryCalculator.formatted(date, "MMMM", calendar: calendar)
    }
}

/// One month-level budget warning at a time; the highest that holds wins. Raw values are pinned
/// (`Comparable` follows them). `Comparable`/`CaseIterable` are intentional API for
/// reservoir-nka.3/nka.4 (threshold comparisons), not yet used by the app.
enum BudgetWarningLevel: Int, Codable, Comparable, CaseIterable {
    case none = 0
    case trackingOver = 1
    case hardToRecover = 2
    case pointOfNoReturn = 3

    static func < (lhs: BudgetWarningLevel, rhs: BudgetWarningLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
