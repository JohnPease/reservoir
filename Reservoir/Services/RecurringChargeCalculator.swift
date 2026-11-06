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
    }

    static let minimumCharges = 3
    /// Median days between charges must fall in this range to count as monthly.
    static let monthlyGapDays = 24.0...38.0
    /// A merchant that has not charged in this many days is treated as cancelled.
    static let activeWithinDays = 45
    static let newWithinDays = 100
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
        return groups.values.compactMap { recurring(from: $0, now: now, calendar: calendar) }
            .sorted {
                $0.typicalAmount != $1.typicalAmount ? $0.typicalAmount > $1.typicalAmount : $0.merchant < $1.merchant
            }
    }

    /// What recurring charges add up to in a month.
    static func monthlyTotal(_ recurring: [Recurring]) -> Decimal {
        recurring.reduce(0) { $0 + $1.typicalAmount }
    }

    /// What recurring charges add up to in a year (twelve months of `monthlyTotal`).
    static func yearlyTotal(_ recurring: [Recurring]) -> Decimal {
        monthlyTotal(recurring) * 12
    }

    /// Net monthly change across charges whose latest price differs from the one before
    /// (reservoir-1cm); positive when subscriptions got dearer. Zero when no price changed.
    static func monthlyPriceChange(_ recurring: [Recurring]) -> Decimal {
        recurring.reduce(0) { total, item in
            guard let previous = item.previousAmount else { return total }
            return total + (item.lastAmount - previous)
        }
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

    /// Recurring charges whose next one is expected from today through `upcomingWithinDays` days
    /// ahead, soonest first. The next date is one month after the last charge; a charge that is
    /// already late (expected before today) is left out rather than guessed at.
    static func upcoming(
        _ recurring: [Recurring], now: Date, withinDays: Int = upcomingWithinDays, calendar: Calendar = .current
    ) -> [Upcoming] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: withinDays + 1, to: today) else { return [] }
        return recurring.compactMap { item -> Upcoming? in
            guard let next = calendar.date(byAdding: .month, value: 1, to: item.lastDate) else { return nil }
            let day = calendar.startOfDay(for: next)
            guard day >= today, day < end else { return nil }
            return Upcoming(merchant: item.merchant, category: item.category, amount: item.typicalAmount, expectedDate: day)
        }
        .sorted { $0.expectedDate != $1.expectedDate ? $0.expectedDate < $1.expectedDate : $0.merchant < $1.merchant }
    }

    private static func recurring(from group: [CategorySpendCalculator.Entry], now: Date, calendar: Calendar) -> Recurring? {
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
            isNew: first.date >= newCutoff
        )
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
