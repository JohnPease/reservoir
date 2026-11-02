import Foundation

/// Spend grouped by Plaid category for one calendar month (reservoir-27a). Pure; no SwiftData
/// or SwiftUI. Takes the inputs it needs as plain values so the view and the tests share it.
enum CategorySpendCalculator {
    struct Row: Equatable {
        /// Plaid's raw primary category, or nil for uncategorized spend.
        var category: String?
        var amount: Decimal
        var count: Int

        var name: String { CategorySpendCalculator.displayName(for: category) }
    }

    struct Month: Equatable {
        var rows: [Row]
        var total: Decimal
    }

    static let uncategorizedName = "Uncategorized"

    /// One entry per spend transaction: the inputs this calculator reads.
    struct Entry: Equatable {
        var date: Date
        var amount: Decimal
        var category: String?
    }

    /// Rows for the month containing `month`, largest first (ties by name); uncategorized
    /// spend is its own row, last among equals.
    static func month(containing month: Date, entries: [Entry], calendar: Calendar = .current) -> Month {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return Month(rows: [], total: 0) }
        var byCategory: [String?: (amount: Decimal, count: Int)] = [:]
        var total: Decimal = 0
        for entry in entries where entry.date >= interval.start && entry.date < interval.end {
            byCategory[entry.category, default: (0, 0)].amount += entry.amount
            byCategory[entry.category, default: (0, 0)].count += 1
            total += entry.amount
        }
        let rows = byCategory
            .map { Row(category: $0.key, amount: $0.value.amount, count: $0.value.count) }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.name < $1.name
            }
        return Month(rows: rows, total: total)
    }

    /// `FOOD_AND_DRINK` becomes "Food and drink"; nil becomes "Uncategorized".
    static func displayName(for category: String?) -> String {
        guard let category, !category.isEmpty else { return uncategorizedName }
        let words = category.lowercased().split(separator: "_").map(String.init)
        guard let first = words.first else { return uncategorizedName }
        let rest = words.dropFirst().joined(separator: " ")
        return (first.prefix(1).uppercased() + first.dropFirst()) + (rest.isEmpty ? "" : " " + rest)
    }
}
