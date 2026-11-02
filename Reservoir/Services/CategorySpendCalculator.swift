import Foundation

/// Spend grouped by Plaid category for one calendar month (reservoir-27a). Pure; no SwiftData
/// or SwiftUI. Takes the inputs it needs as plain values so the view and the tests share it.
enum CategorySpendCalculator {
    struct Row: Equatable {
        /// Plaid's raw primary category, or nil for uncategorized spend.
        var category: String?
        var amount: Decimal
        var count: Int
        /// Spend in the comparison window of the month before (see `Month.comparesPartialMonth`).
        var previousAmount: Decimal = 0

        var name: String { CategorySpendCalculator.displayName(for: category) }
        /// Positive when spending is up on the month before.
        var change: Decimal { amount - previousAmount }
    }

    struct Month: Equatable {
        var rows: [Row]
        var total: Decimal
        var previousTotal: Decimal = 0
        /// True when the month is still in progress, so the comparison covers only the same
        /// days of the month before (day 1 through today) rather than all of it.
        var comparesPartialMonth = false
    }

    /// One bar of a category's history.
    struct MonthTotal: Equatable {
        var monthStart: Date
        var amount: Decimal
    }

    static let uncategorizedName = "Uncategorized"

    /// One entry per spend transaction: the inputs this calculator reads.
    struct Entry: Equatable {
        var date: Date
        var amount: Decimal
        var category: String?
    }

    /// Rows for the month containing `month`, largest first (ties by name); uncategorized
    /// spend is its own row. Each row carries the month before's spend for comparison: when
    /// `now` falls inside the month, only the same days (day 1 through today) of the month
    /// before, so a half-finished month is not compared with a whole one. Categories that
    /// had spend only in the month before still get a row.
    static func month(
        containing month: Date,
        entries: [Entry],
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> Month {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return Month(rows: [], total: 0) }
        let current = totals(in: interval.start..<interval.end, entries: entries)

        var previous: [String?: (amount: Decimal, count: Int)] = [:]
        var partial = false
        if let priorDay = calendar.date(byAdding: .day, value: -1, to: interval.start),
           let prior = calendar.dateInterval(of: .month, for: priorDay) {
            var end = prior.end
            if let now, now >= interval.start, now < interval.end {
                let elapsed = (calendar.dateComponents([.day], from: interval.start, to: calendar.startOfDay(for: now)).day ?? 0) + 1
                if let sameDays = calendar.date(byAdding: .day, value: elapsed, to: prior.start), sameDays < prior.end {
                    end = sameDays
                    partial = true
                }
            }
            previous = totals(in: prior.start..<end, entries: entries)
        }

        let rows = Set(current.keys).union(previous.keys)
            .map { category in
                Row(
                    category: category,
                    amount: current[category]?.amount ?? 0,
                    count: current[category]?.count ?? 0,
                    previousAmount: previous[category]?.amount ?? 0
                )
            }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                if $0.previousAmount != $1.previousAmount { return $0.previousAmount > $1.previousAmount }
                return $0.name < $1.name
            }
        return Month(
            rows: rows,
            total: current.values.reduce(0) { $0 + $1.amount },
            previousTotal: previous.values.reduce(0) { $0 + $1.amount },
            comparesPartialMonth: partial
        )
    }

    /// The category's spend for each of the `months` months ending with the one containing
    /// `month`, oldest first; months with no spend are present with 0.
    static func history(
        for category: String?,
        months: Int,
        endingAt month: Date,
        entries: [Entry],
        calendar: Calendar = .current
    ) -> [MonthTotal] {
        guard months > 0, let last = calendar.dateInterval(of: .month, for: month) else { return [] }
        return (0..<months).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: last.start),
                  let interval = calendar.dateInterval(of: .month, for: start)
            else { return nil }
            let amount = entries
                .filter { $0.category == category && $0.date >= interval.start && $0.date < interval.end }
                .reduce(Decimal(0)) { $0 + $1.amount }
            return MonthTotal(monthStart: interval.start, amount: amount)
        }
    }

    private static func totals(in range: Range<Date>, entries: [Entry]) -> [String?: (amount: Decimal, count: Int)] {
        var byCategory: [String?: (amount: Decimal, count: Int)] = [:]
        for entry in entries where range.contains(entry.date) {
            byCategory[entry.category, default: (0, 0)].amount += entry.amount
            byCategory[entry.category, default: (0, 0)].count += 1
        }
        return byCategory
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
