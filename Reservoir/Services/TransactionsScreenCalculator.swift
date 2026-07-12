import Foundation
import SwiftData

/// Business logic for the Transactions tab (adq.3): the All/Variable/Fixed filter and the
/// day-grouping the list renders as `Section`s. Kept out of `TransactionsView` per
/// STANDARDS.md §3 so the exact filtering/grouping/section-title rules are unit-testable
/// without driving SwiftUI.
enum TransactionsScreenCalculator {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case variable = "Variable"
        case fixed = "Fixed"

        var id: String { rawValue }
    }

    static func filtered(_ transactions: [SpendTransaction], by filter: Filter) -> [SpendTransaction] {
        switch filter {
        case .all:
            return transactions
        case .variable:
            return transactions.filter { $0.type == .variable }
        case .fixed:
            return transactions.filter { $0.type == .fixed }
        }
    }

    /// One day's worth of transactions for the day-grouped list. `day` is the calendar
    /// start-of-day, used both as the section identity and as `sectionTitle`'s input.
    struct DaySection: Identifiable, Equatable {
        let day: Date
        let transactions: [SpendTransaction]
        var id: Date { day }

        static func == (lhs: DaySection, rhs: DaySection) -> Bool {
            lhs.day == rhs.day && lhs.transactions.map(\.persistentModelID) == rhs.transactions.map(\.persistentModelID)
        }
    }

    /// Groups `transactions` into day sections, preserving the incoming order both across
    /// sections (assumes `transactions` is already sorted date-descending, matching
    /// `TransactionsView`'s `@Query` sort) and within each section.
    static func groupedByDay(_ transactions: [SpendTransaction], calendar: Calendar = .current) -> [DaySection] {
        var order: [Date] = []
        var buckets: [Date: [SpendTransaction]] = [:]

        for transaction in transactions {
            let day = calendar.startOfDay(for: transaction.date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(transaction)
        }

        return order.map { day in DaySection(day: day, transactions: buckets[day] ?? []) }
    }

    /// "Today" / "Yesterday" / a full date, for a day section's header — `day` must
    /// already be a calendar start-of-day (as produced by `groupedByDay`).
    static func sectionTitle(for day: Date, referenceDate: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: referenceDate)
        if calendar.isDate(day, inSameDayAs: today) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}
