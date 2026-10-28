import Foundation
import SwiftData

/// Month-end review for the monthly budget (reservoir-62p): one `MonthReview` per
/// *completed* month, recomputed on demand from (the budget's current fields, the
/// transactions, the reference date). Nothing is persisted. Imports SwiftData for the
/// model types only (STANDARDS.md §4's `*Calculator` exception); never SwiftUI.
///
/// The day walk mirrors `DailyLimitCalculator.carryForward` exactly (same `startOfDay`
/// stepping, same reset-on-the-1st rule for "Start fresh"), so a carry-mode month's
/// `endingCarry` equals `carryForward(asOf: first of next month)`.
enum BudgetMonthReviewCalculator {

    /// One completed month's result.
    struct MonthReview: Codable, Equatable {
        /// Start of the month (calendar day 1, start of day).
        var monthStart: Date
        /// True for the budget's first month when `startDate` falls after the 1st.
        var isPartialStart: Bool
        /// First tracked day in the month: `startDate`'s day for a partial month, else `monthStart`.
        var windowStart: Date
        /// Sum of the daily bases over the tracked days (exactly `monthlyAmount` for a full month).
        var budgeted: Decimal
        var spent: Decimal
        /// `budgeted - spent` (positive = under).
        var delta: Decimal
        /// Days whose counted spend exceeded that day's limit (base + carry). Zero-spend days never count.
        var daysOver: Int
        /// Carry into the next month; always 0 in "Start fresh" mode.
        var endingCarry: Decimal

        enum Verdict: Equatable { case under, over, rightOn }

        /// "Right on" when the difference rounds inside the pace tolerance.
        var verdict: Verdict {
            if abs(delta) < BudgetSummaryCalculator.rightOnTolerance { return .rightOn }
            return delta > 0 ? .under : .over
        }

        /// "$120 under" / "$45 over" / "right on".
        var deltaText: String {
            switch verdict {
            case .under: return "\(BudgetSummaryCalculator.whole(delta)) under"
            case .over: return "\(BudgetSummaryCalculator.whole(-delta)) over"
            case .rightOn: return "right on"
            }
        }

        var daysOverText: String { "\(daysOver) \(daysOver == 1 ? "day" : "days") over" }
    }

    // MARK: - Reviews

    /// Completed months from `startDate`'s month through the month before
    /// `referenceDate`'s month, newest first. Empty while the budget's first month is
    /// still the current one (or the budget starts in the future).
    static func reviews(
        budget: Budget,
        transactions: [SpendTransaction],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [MonthReview] {
        let startDay = calendar.startOfDay(for: budget.startDate)
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start,
              startDay < currentMonthStart
        else { return [] }

        let counting = BudgetCalculator.countingTransactions(transactions, for: budget, calendar: calendar)
        var spentByDay: [Date: Decimal] = [:]
        for transaction in counting {
            spentByDay[calendar.startOfDay(for: transaction.date), default: 0] += transaction.amount
        }

        let schedule = BaseSchedule.monthly(budget.monthlyAmount)
        let resetsOnFirst = !budget.carriesAcrossMonths

        var results: [MonthReview] = []
        var carry: Decimal = 0
        var current: MonthReview?
        var day = startDay
        while day < currentMonthStart {
            let monthStart = calendar.dateInterval(of: .month, for: day)?.start ?? day
            if current?.monthStart != monthStart {
                if let finished = current { results.append(finish(finished, carry: carry, resets: resetsOnFirst)) }
                current = MonthReview(
                    monthStart: monthStart, isPartialStart: day > monthStart, windowStart: day,
                    budgeted: 0, spent: 0, delta: 0, daysOver: 0, endingCarry: 0
                )
            }
            // Deliberately a separate walk from DailyLimitCalculator.carryForward (that API returns
            // only the final carry; this needs per-day/per-month state). Keep the stepping and the
            // reset-on-the-1st rule in sync; the agreement tests in BudgetMonthReviewCalculatorTests
            // fail if they drift.
            if resetsOnFirst && calendar.component(.day, from: day) == 1 {
                carry = 0
            }
            let base = schedule.base(on: day, calendar: calendar)
            let spend = spentByDay[day] ?? 0
            current?.budgeted += base
            current?.spent += spend
            if spend > 0 && spend > base + carry { current?.daysOver += 1 }
            carry += base - spend

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        if let finished = current { results.append(finish(finished, carry: carry, resets: resetsOnFirst)) }
        return results.reversed()
    }

    private static func finish(_ review: MonthReview, carry: Decimal, resets: Bool) -> MonthReview {
        var done = review
        done.delta = done.budgeted - done.spent
        done.endingCarry = resets ? 0 : carry
        return done
    }

    // MARK: - Screen state

    /// What the review screen shows; gated like the budget cards so a syncing or
    /// account-less budget never renders as zeros.
    enum Screen: Equatable {
        case status(BudgetCalculator.CardState)
        case empty
        case months([MonthReview])
    }

    static let emptyMessage = "No completed months yet"

    static func screen(
        budget: Budget,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Screen {
        let state = BudgetCalculator.cardState(for: budget, isAccountBackfillComplete: isAccountBackfillComplete)
        guard state == .active else { return .status(state) }
        let months = reviews(budget: budget, transactions: transactions, referenceDate: referenceDate, calendar: calendar)
        return months.isEmpty ? .empty : .months(months)
    }
}
