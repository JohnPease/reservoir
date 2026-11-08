import Foundation
import SwiftData

/// Day-by-day figures for one month of the monthly budget (reservoir-h2k's "month strip"):
/// each day's base, spend, the limit it started with and the carry it left behind. Imports
/// SwiftData for the model types only (STANDARDS.md §4's `*Calculator` exception); never
/// SwiftUI.
///
/// The walk mirrors `DailyLimitCalculator.carryForward` (same `startOfDay` stepping, same
/// reset-on-the-1st rule for "Start fresh"), so the last past day's `carryOut` equals the
/// carry the Today hero adds to today's base. `BudgetMonthStripCalculatorTests` pins that.
enum BudgetMonthStripCalculator {

    struct Day: Equatable, Identifiable {
        var date: Date
        var base: Decimal
        var spent: Decimal
        /// Carry brought into the day (0 on the 1st in "Start fresh" mode).
        var carryIn: Decimal
        var isToday: Bool
        var isFuture: Bool

        var id: Date { date }
        /// What the day could spend: base plus carry in.
        var limit: Decimal { base + carryIn }
        /// Carry the day leaves for tomorrow; future days carry nothing forward yet.
        var carryOut: Decimal { isFuture ? carryIn : carryIn + base - spent }
        /// Spent more than the day's limit. Zero-spend days are never over.
        var isOver: Bool { spent > 0 && spent > limit }
        /// Spent more than the base alone (the red bars on the strip).
        var isOverBase: Bool { spent > base }
    }

    struct Strip: Equatable {
        var monthStart: Date
        var days: [Day]
        /// Carry banked so far: after the last finished day (today's spend is not counted yet).
        var carryNow: Decimal
        /// Whether an earlier month exists to page back to.
        var hasPrevious: Bool
        var hasNext: Bool
    }

    /// `nil` when the month is before the budget starts or after `referenceDate`'s month.
    static func strip(
        budget: Budget,
        transactions: [SpendTransaction],
        month: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Strip? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let currentMonthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start
        else { return nil }
        let startDay = calendar.startOfDay(for: budget.startDate)
        let firstMonthStart = calendar.dateInterval(of: .month, for: startDay)?.start ?? startDay
        guard monthInterval.start >= firstMonthStart, monthInterval.start <= currentMonthStart else { return nil }

        var spentByDay: [Date: Decimal] = [:]
        for transaction in BudgetCalculator.countingTransactions(transactions, for: budget, calendar: calendar) {
            spentByDay[calendar.startOfDay(for: transaction.date), default: 0] += transaction.amount
        }

        let schedule = BaseSchedule.monthly(budget.monthlyAmount)
        let resetsOnFirst = !budget.carriesAcrossMonths
        let today = calendar.startOfDay(for: referenceDate)

        var carry: Decimal = 0
        var days: [Day] = []
        // Days before the budget starts (a partial first month) are not tracked at all.
        var day = max(monthInterval.start, startDay)
        if monthInterval.start > startDay {
            // Walk from the budget start to the month start to get the carry into this month.
            var walk = startDay
            while walk < monthInterval.start {
                if resetsOnFirst && calendar.component(.day, from: walk) == 1 { carry = 0 }
                carry += schedule.base(on: walk, calendar: calendar) - (spentByDay[walk] ?? 0)
                guard let next = calendar.date(byAdding: .day, value: 1, to: walk) else { break }
                walk = calendar.startOfDay(for: next)
            }
        }
        var carryNow = carry
        while day < monthInterval.end {
            if resetsOnFirst && calendar.component(.day, from: day) == 1 { carry = 0 }
            let isFuture = day > today
            let entry = Day(
                date: day,
                base: schedule.base(on: day, calendar: calendar),
                spent: isFuture ? 0 : (spentByDay[day] ?? 0),
                carryIn: carry,
                isToday: day == today,
                isFuture: isFuture
            )
            days.append(entry)
            // Today's own spend is not banked yet, matching the Today hero's carried-forward figure.
            if !isFuture { carryNow = entry.isToday ? entry.carryIn : entry.carryOut }
            carry = entry.carryOut
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return Strip(
            monthStart: monthInterval.start,
            days: days,
            carryNow: carryNow,
            hasPrevious: monthInterval.start > firstMonthStart,
            hasNext: monthInterval.start < currentMonthStart
        )
    }
}
