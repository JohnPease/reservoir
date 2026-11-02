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
        var categoryDetailed: String? = nil
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
        guard let windows = windows(for: month, now: now, calendar: calendar) else { return Month(rows: [], total: 0) }
        let current = totals(in: windows.current, entries: entries)
        let previous = windows.previous.map { totals(in: $0, entries: entries) } ?? [:]
        let partial = windows.comparesPartialMonth

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

    /// The month containing `month` and the window it is compared with: the whole month before,
    /// or, when `now` falls inside `month`, only the same days (day 1 through today) of it.
    private static func windows(
        for month: Date, now: Date?, calendar: Calendar
    ) -> (current: Range<Date>, previous: Range<Date>?, comparesPartialMonth: Bool)? {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return nil }
        let current = interval.start..<interval.end
        guard let priorDay = calendar.date(byAdding: .day, value: -1, to: interval.start),
              let prior = calendar.dateInterval(of: .month, for: priorDay)
        else { return (current, nil, false) }
        var end = prior.end
        var partial = false
        if let now, now >= interval.start, now < interval.end {
            let elapsed = (calendar.dateComponents([.day], from: interval.start, to: calendar.startOfDay(for: now)).day ?? 0) + 1
            if let sameDays = calendar.date(byAdding: .day, value: elapsed, to: prior.start), sameDays < prior.end {
                end = sameDays
                partial = true
            }
        }
        return (current, prior.start..<end, partial)
    }

    // MARK: - Detailed categories (reservoir-e1y)

    /// One Plaid detailed label inside a primary category, with the same comparison as `Row`.
    struct DetailRow: Equatable {
        var detailed: String?
        /// The primary category this label belongs to; used to shorten the display name.
        var category: String?
        var amount: Decimal
        var count: Int
        var previousAmount: Decimal = 0

        var name: String { CategorySpendCalculator.displayName(forDetailed: detailed, in: category) }
        var change: Decimal { amount - previousAmount }
    }

    /// The month's spend inside `category` split by Plaid's detailed label, largest first.
    /// Labels with spend only in the comparison window still get a row.
    static func detail(
        for category: String?,
        month: Date,
        entries: [Entry],
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> [DetailRow] {
        guard let windows = windows(for: month, now: now, calendar: calendar) else { return [] }
        let inCategory = entries.filter { $0.category == category }
        func grouped(_ range: Range<Date>) -> [String?: (amount: Decimal, count: Int)] {
            var result: [String?: (amount: Decimal, count: Int)] = [:]
            for entry in inCategory where range.contains(entry.date) {
                result[entry.categoryDetailed, default: (0, 0)].amount += entry.amount
                result[entry.categoryDetailed, default: (0, 0)].count += 1
            }
            return result
        }
        let current = grouped(windows.current)
        let previous = windows.previous.map(grouped) ?? [:]
        return Set(current.keys).union(previous.keys)
            .map {
                DetailRow(
                    detailed: $0, category: category,
                    amount: current[$0]?.amount ?? 0, count: current[$0]?.count ?? 0,
                    previousAmount: previous[$0]?.amount ?? 0
                )
            }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                if $0.previousAmount != $1.previousAmount { return $0.previousAmount > $1.previousAmount }
                return $0.name < $1.name
            }
    }

    /// `FOOD_AND_DRINK_FAST_FOOD` inside `FOOD_AND_DRINK` becomes "Fast food". A label that
    /// does not start with its category is shown in full; nil becomes "Other".
    static func displayName(forDetailed detailed: String?, in category: String?) -> String {
        guard let detailed, !detailed.isEmpty else { return "Other" }
        var trimmed = detailed
        if let category, !category.isEmpty, detailed.hasPrefix(category + "_") {
            trimmed = String(detailed.dropFirst(category.count + 1))
        }
        return displayName(for: trimmed)
    }

    // MARK: - Unusual months (reservoir-qj2)

    struct Callout: Equatable {
        var category: String
        var amount: Decimal
        /// Average monthly spend in the category over the earlier months.
        var usual: Decimal
        /// True when the month is still in progress, so the amount is a floor, not a total.
        var inProgress: Bool

        var name: String { CategorySpendCalculator.displayName(for: category) }
        var ratio: Double { usual > 0 ? NSDecimalNumber(decimal: amount / usual).doubleValue : 0 }

        /// "Entertainment is 2.1× its usual" / "Entertainment was 2.1× its usual".
        var text: String { "\(name) \(inProgress ? "is already" : "was") \(Self.ratioText(ratio)) its usual" }
        /// "$310 so far vs about $150 a month".
        var detailText: String {
            let money = { (value: Decimal) in value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
            return "\(money(amount))\(inProgress ? " so far" : "") vs about \(money(usual)) a month"
        }

        private static func ratioText(_ ratio: Double) -> String {
            ratio >= 10 ? "\(Int(ratio.rounded()))×" : String(format: "%.1f×", ratio)
        }
    }

    /// Thresholds: at least two earlier months of data, a usual of at least $20 a month, and
    /// this month at least 1.5× usual and at least $25 above it.
    static let calloutMinimumPriorMonths = 2
    static let calloutMinimumUsual: Decimal = 20
    static let calloutRatio: Decimal = 1.5
    static let calloutMinimumExcess: Decimal = 25
    private static let calloutLookbackMonths = 5

    /// Categories whose spend in `month` is well above their average for the earlier months
    /// (up to five, none before the first month with any data), biggest excess first. For a
    /// month in progress the comparison is its spend so far against a whole usual month, so
    /// it only fires when the month has already outrun the average.
    static func callouts(
        month: Date,
        entries: [Entry],
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> [Callout] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstEntry = entries.map(\.date).min(),
              let firstMonth = calendar.dateInterval(of: .month, for: firstEntry)?.start
        else { return [] }

        var priorMonths: [Range<Date>] = []
        for back in 1...calloutLookbackMonths {
            guard let start = calendar.date(byAdding: .month, value: -back, to: interval.start),
                  let prior = calendar.dateInterval(of: .month, for: start),
                  prior.start >= firstMonth
            else { break }
            priorMonths.append(prior.start..<prior.end)
        }
        guard priorMonths.count >= calloutMinimumPriorMonths else { return [] }

        let current = totals(in: interval.start..<interval.end, entries: entries)
        let inProgress = now.map { $0 >= interval.start && $0 < interval.end } ?? false
        let priorTotals = priorMonths.map { totals(in: $0, entries: entries) }

        var result: [Callout] = []
        for (category, spend) in current {
            guard let category else { continue }
            let usual = priorTotals.reduce(Decimal(0)) { $0 + ($1[category]?.amount ?? 0) } / Decimal(priorTotals.count)
            guard usual >= calloutMinimumUsual,
                  spend.amount >= usual * calloutRatio,
                  spend.amount - usual >= calloutMinimumExcess
            else { continue }
            result.append(Callout(category: category, amount: spend.amount, usual: usual, inProgress: inProgress))
        }
        return result.sorted {
            let lhs = $0.amount - $0.usual, rhs = $1.amount - $1.usual
            return lhs != rhs ? lhs > rhs : $0.name < $1.name
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
