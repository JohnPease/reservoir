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

    /// Which empty-list state the Transactions tab shows (reservoir-xle).
    enum EmptyStateKind: Equatable {
        /// A post-link import is in flight.
        case importing
        /// Plaid hasn't finished the first pull (post-link poll gave up, or a refresh found
        /// the item still not ready) — not an error; offers a Refresh button.
        case stillFetching
        /// Nothing imported, nothing pending: the plain "No transactions yet".
        case none
    }

    static func emptyStateKind(isInitialImport: Bool, isInitialDataPending: Bool) -> EmptyStateKind {
        if isInitialImport { return .importing }
        if isInitialDataPending { return .stillFetching }
        return .none
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

    /// The category menu's selection (reservoir-473): every charge, one Plaid primary category,
    /// or charges with no category (manual entries and anything Plaid did not label).
    enum CategoryFilter: Hashable {
        case all
        case category(String)
        case uncategorized

        var title: String {
            switch self {
            case .all: return "All categories"
            case .category(let category): return CategorySpendCalculator.displayName(for: category)
            case .uncategorized: return CategorySpendCalculator.uncategorizedName
            }
        }
    }

    static func filtered(_ transactions: [SpendTransaction], by filter: Filter, category: CategoryFilter) -> [SpendTransaction] {
        let byType = filtered(transactions, by: filter)
        switch category {
        case .all: return byType
        case .category(let name): return byType.filter { $0.category == name }
        case .uncategorized: return byType.filter { $0.category == nil }
        }
    }

    /// The choices for the category menu: only categories that exist in `transactions`, by name,
    /// with "Uncategorized" last and only when some charge has none. Empty when nothing is
    /// categorized, so manual-only users never see the menu.
    static func categoryChoices(_ transactions: [SpendTransaction]) -> [CategoryFilter] {
        let names = Set(transactions.compactMap(\.category))
        guard !names.isEmpty else { return [] }
        var choices: [CategoryFilter] = [.all]
        choices += names
            .sorted { CategorySpendCalculator.displayName(for: $0) < CategorySpendCalculator.displayName(for: $1) }
            .map(CategoryFilter.category)
        if transactions.contains(where: { $0.category == nil }) { choices.append(.uncategorized) }
        return choices
    }

    /// The charges behind one category row (reservoir-473): `category` (nil = uncategorized),
    /// optionally narrowed to one detailed label, inside `interval`; newest first.
    static func charges(
        _ transactions: [SpendTransaction],
        category: String?,
        detailed: String?? = nil,
        in interval: DateInterval
    ) -> [SpendTransaction] {
        transactions
            .filter { transaction in
                guard transaction.category == category, transaction.date >= interval.start, transaction.date < interval.end
                else { return false }
                if let detailed { return transaction.categoryDetailed == detailed }
                return true
            }
            .sorted {
                $0.date != $1.date ? $0.date > $1.date : $0.createdAt > $1.createdAt
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
