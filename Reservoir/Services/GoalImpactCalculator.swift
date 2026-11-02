import Foundation

/// "What cutting a category would do for this goal" (reservoir-11z). Pure; uses the same model as
/// the goal's Simulation segment: finishing date moves by (extra per day x days remaining) /
/// dailyBase days, so the answer agrees with the pace figures the card already shows.
enum GoalImpactCalculator {
    struct Impact: Equatable {
        var category: String
        /// Average monthly spend in the category over the months used.
        var monthlyAverage: Decimal
        /// The share of it cut, e.g. 0.25.
        var cutFraction: Decimal
        /// What the cut frees each month.
        var monthlySaving: Decimal
        var daysSooner: Int

        var categoryName: String { CategorySpendCalculator.displayName(for: category) }

        /// "Cutting a quarter of Food and drink (about $103 a month) would finish this goal roughly 9 days sooner."
        var text: String {
            let money = monthlySaving.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            return "Cutting a quarter of \(categoryName) (about \(money) a month) would finish this goal roughly \(daysSooner) \(daysSooner == 1 ? "day" : "days") sooner."
        }
    }

    /// Categories it makes sense to suggest trimming; rent, loans, transfers and similar are not.
    static let discretionary: Set<String> = [
        "FOOD_AND_DRINK", "ENTERTAINMENT", "GENERAL_MERCHANDISE", "PERSONAL_CARE", "TRAVEL",
    ]
    static let cutFraction: Decimal = 0.25
    /// Full months of history averaged (the most recent ones before the current month).
    static let monthsAveraged = 3
    static let minimumMonths = 2
    static let minimumDaysRemaining = 7
    private static let averageDaysPerMonth: Decimal = 30.4375

    /// The biggest discretionary category's impact, or nil when there is not enough history, the goal is too
    /// close to its date, or the cut would move it by less than a day.
    static func impact(
        entries: [CategorySpendCalculator.Entry],
        dailyBase: Decimal,
        targetDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Impact? {
        guard dailyBase > 0,
              let thisMonth = calendar.dateInterval(of: .month, for: referenceDate),
              let firstEntry = entries.map(\.date).min(),
              let firstMonth = calendar.dateInterval(of: .month, for: firstEntry)?.start
        else { return nil }
        let today = calendar.startOfDay(for: referenceDate)
        let daysRemaining = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: targetDate)).day ?? 0
        guard daysRemaining >= minimumDaysRemaining else { return nil }

        var ranges: [Range<Date>] = []
        for back in 1...monthsAveraged {
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonth.start),
                  let month = calendar.dateInterval(of: .month, for: start),
                  month.start >= firstMonth
            else { break }
            ranges.append(month.start..<month.end)
        }
        guard ranges.count >= minimumMonths else { return nil }

        var totals: [String: Decimal] = [:]
        for entry in entries {
            guard let category = entry.category, discretionary.contains(category),
                  ranges.contains(where: { $0.contains(entry.date) })
            else { continue }
            totals[category, default: 0] += entry.amount
        }
        guard let top = totals.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }

        let average = top.value / Decimal(ranges.count)
        let saving = average * cutFraction
        let extraPerDay = saving / averageDaysPerMonth
        let days = NSDecimalNumber(decimal: extraPerDay * Decimal(daysRemaining) / dailyBase)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )).intValue
        guard days >= 1 else { return nil }
        return Impact(category: top.key, monthlyAverage: average, cutFraction: cutFraction, monthlySaving: saving, daysSooner: days)
    }
}
