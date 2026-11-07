import Foundation

/// Finds charges that repeat about monthly (subscriptions, bills) from the stored history
/// (reservoir-o0a). Pure; reads `CategorySpendCalculator.Entry`, so it has no SwiftData or SwiftUI.
enum RecurringChargeCalculator {
    struct Recurring: Equatable {
        var merchant: String
        var category: String?
        /// Median of the last three charges.
        var typicalAmount: Decimal
        var lastDate: Date
        var lastAmount: Decimal
        var firstDate: Date
        var chargeCount: Int
        /// The charge before the latest one, set only when the latest differs by at least 5% and $1.
        var previousAmount: Decimal?
        /// First seen within the last `newWithinDays` days.
        var isNew: Bool

        var priceChanged: Bool { previousAmount != nil }

        /// Day of the month the charge usually posts (median across its charges), so a bill that
        /// posted early in a short month still lands on its usual day the month after.
        var usualDay: Int = 1
        /// What the next charge is expected to be: the latest amount once the price has moved,
        /// otherwise the typical amount.
        var currentAmount: Decimal { priceChanged ? lastAmount : typicalAmount }
    }

    static let minimumCharges = 3
    /// Median days between charges must fall in this range to count as monthly.
    static let monthlyGapDays = 24.0...38.0
    /// A merchant that has not charged in this many days is treated as cancelled.
    static let activeWithinDays = 45
    static let newWithinDays = 100
    /// "New" needs this much history from before the charge, so a freshly linked account whose
    /// first import is recent does not flag every subscription it finds.
    static let newMinimumPriorHistoryDays = 60
    /// How far back history is considered.
    static let lookbackDays = 210
    /// Share of charges within 15% of the median amount.
    static let steadyShare = 0.6

    /// Active monthly merchants, largest typical amount first.
    static func detect(entries: [CategorySpendCalculator.Entry], now: Date, calendar: Calendar = .current) -> [Recurring] {
        guard let cutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: now) else { return [] }
        let groups = Dictionary(grouping: entries.filter { !$0.merchant.isEmpty && $0.date >= cutoff && $0.date <= now }) {
            CategorySpendCalculator.merchantKey($0.merchant)
        }
        let historyStart = entries.map(\.date).min()
        return groups.values.compactMap { recurring(from: $0, historyStart: historyStart, now: now, calendar: calendar) }
            .sorted {
                $0.typicalAmount != $1.typicalAmount ? $0.typicalAmount > $1.typicalAmount : $0.merchant < $1.merchant
            }
    }

    /// What recurring charges add up to in a month, at their current prices.
    static func monthlyTotal(_ recurring: [Recurring]) -> Decimal {
        recurring.reduce(0) { $0 + $1.currentAmount }
    }

    /// What recurring charges add up to in a year (twelve months of `monthlyTotal`).
    static func yearlyTotal(_ recurring: [Recurring]) -> Decimal {
        monthlyTotal(recurring) * 12
    }

    /// Sum of (latest charge - the one before) over charges whose price moved (reservoir-1cm);
    /// positive when subscriptions got dearer. A one-off blip counts as a change. Zero when no
    /// price moved.
    static func monthlyPriceChange(_ recurring: [Recurring]) -> Decimal {
        recurring.reduce(0) { total, item in
            guard let previous = item.previousAmount else { return total }
            return total + (item.lastAmount - previous)
        }
    }

    /// "About $212 a month, $2,544 a year", plus the net price move when any price changed.
    static func summaryText(_ recurring: [Recurring]) -> String {
        var text = "About \(monthlyTotal(recurring).wholeDollarText) a month, \(yearlyTotal(recurring).wholeDollarText) a year"
        let change = monthlyPriceChange(recurring)
        if change != 0 {
            text += " · prices \(change > 0 ? "up" : "down") \(abs(change).wholeDollarText) a month"
        }
        return text
    }

    // MARK: - Upcoming (reservoir-nm8)

    /// A recurring charge expected within the next few days.
    struct Upcoming: Equatable {
        var merchant: String
        var category: String?
        var amount: Decimal
        var expectedDate: Date
    }

    static let upcomingWithinDays = 7
    /// A charge expected up to this many days ago and not yet seen is still listed (banks post late).
    static let upcomingGraceDays = 2

    /// What the listed upcoming charges add up to.
    static func total(of upcoming: [Upcoming]) -> Decimal {
        upcoming.reduce(0) { $0 + $1.amount }
    }

    /// Recurring charges expected from `upcomingGraceDays` days ago through `upcomingWithinDays`
    /// days ahead, soonest first. The next date is the charge's usual day of the month in the
    /// month after the last charge (clamped to that month's length, so a bill that usually posts
    /// on the 31st is expected on Feb 28 and Mar 31). Anything later than the grace period is
    /// left out rather than guessed at.
    static func upcoming(
        _ recurring: [Recurring], now: Date, withinDays: Int = upcomingWithinDays, calendar: Calendar = .current
    ) -> [Upcoming] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -upcomingGraceDays, to: today),
              let end = calendar.date(byAdding: .day, value: withinDays + 1, to: today)
        else { return [] }
        return recurring.compactMap { item -> Upcoming? in
            guard let day = nextExpectedDay(after: item.lastDate, usualDay: item.usualDay, calendar: calendar),
                  day >= start, day < end
            else { return nil }
            return Upcoming(merchant: item.merchant, category: item.category, amount: item.currentAmount, expectedDate: day)
        }
        .sorted { $0.expectedDate != $1.expectedDate ? $0.expectedDate < $1.expectedDate : $0.merchant < $1.merchant }
    }

    /// A bill that posted days early (usually the 1st, this time Jan 31) already paid for the
    /// month its usual day falls in; the next one is a month further on.
    private static let minimumGapDays = 15

    private static func nextExpectedDay(after last: Date, usualDay: Int, calendar: Calendar) -> Date? {
        guard var day = dayInMonth(after: last, usualDay: usualDay, calendar: calendar) else { return nil }
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: day).day ?? 0
        if gap < minimumGapDays {
            guard let later = dayInMonth(after: day, usualDay: usualDay, calendar: calendar) else { return nil }
            day = later
        }
        return day
    }

    private static func dayInMonth(after date: Date, usualDay: Int, calendar: Calendar) -> Date? {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: date),
              let length = calendar.range(of: .day, in: .month, for: nextMonth)?.count
        else { return nil }
        var parts = calendar.dateComponents([.year, .month], from: nextMonth)
        parts.day = min(max(usualDay, 1), length)
        return calendar.date(from: parts).map { calendar.startOfDay(for: $0) }
    }

    private static func recurring(
        from group: [CategorySpendCalculator.Entry], historyStart: Date?, now: Date, calendar: Calendar
    ) -> Recurring? {
        let charges = group.sorted { $0.date < $1.date }
        guard charges.count >= minimumCharges, let first = charges.first, let last = charges.last else { return nil }

        // At most one charge per calendar month counts as "the" monthly charge; a merchant that
        // bills several times a month is a shop, not a subscription.
        let months = Set(charges.map { calendar.dateComponents([.year, .month], from: $0.date) })
        guard months.count == charges.count else { return nil }

        let gaps = zip(charges, charges.dropFirst()).map { pair -> Double in
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: pair.0.date), to: calendar.startOfDay(for: pair.1.date)).day ?? 0
            return Double(days)
        }
        guard monthlyGapDays.contains(median(gaps)) else { return nil }

        let amounts = charges.map(\.amount)
        let middle = median(amounts)
        let steady = amounts.filter { middle > 0 && abs($0 - middle) <= middle * Decimal(0.15) }.count
        guard Double(steady) / Double(amounts.count) >= steadyShare else { return nil }

        guard let activeCutoff = calendar.date(byAdding: .day, value: -activeWithinDays, to: now), last.date >= activeCutoff else { return nil }

        let recent = Array(charges.suffix(3))
        let previous = charges.dropLast().last?.amount
        let changed = previous.map { abs(last.amount - $0) >= 1 && abs(last.amount - $0) >= $0 * Decimal(0.05) } ?? false
        let newCutoff = calendar.date(byAdding: .day, value: -newWithinDays, to: now) ?? now
        return Recurring(
            merchant: last.merchant,
            category: mostCommonCategory(charges),
            typicalAmount: median(recent.map(\.amount)),
            lastDate: last.date,
            lastAmount: last.amount,
            firstDate: first.date,
            chargeCount: charges.count,
            previousAmount: changed ? previous : nil,
            isNew: first.date >= newCutoff && hasHistory(before: first.date, since: historyStart, calendar: calendar),
            usualDay: Int(median(charges.map { Double(calendar.component(.day, from: $0.date)) }).rounded())
        )
    }

    /// Whether the data reaches back far enough before `date` for "first seen" to mean "new".
    private static func hasHistory(before date: Date, since historyStart: Date?, calendar: Calendar) -> Bool {
        guard let historyStart,
              let needed = calendar.date(byAdding: .day, value: -newMinimumPriorHistoryDays, to: date)
        else { return false }
        return historyStart <= needed
    }

    private static func mostCommonCategory(_ charges: [CategorySpendCalculator.Entry]) -> String? {
        var counts: [String: Int] = [:]
        for case let category? in charges.map(\.category) { counts[category, default: 0] += 1 }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
