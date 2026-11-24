import Foundation

/// Credit card billing cycles (reservoir-17g). A card closes its statement on one day of the
/// month and the bill is due on another day; the bill is what was charged between two closing
/// dates. Pure, so the month-length and boundary rules are unit-testable.
enum StatementCycleCalculator {
    struct Cycle: Equatable {
        /// First day of the cycle (the day after the previous statement closed).
        let start: Date
        /// Last day of the cycle; the statement closes at the end of this day.
        let closing: Date
        /// When the bill for this cycle is due, if the card's due day is known.
        let dueDate: Date?
        /// True for the cycle that has not closed yet.
        let isOpen: Bool
    }

    /// The cycles ending at the first closing date on or after `asOf`, then the closed ones
    /// before it: `count` cycles, newest first. The first one is open (or closes today).
    static func cycles(
        closingDay: Int,
        dueDay: Int?,
        asOf: Date,
        count: Int,
        calendar: Calendar = .current
    ) -> [Cycle] {
        let today = calendar.startOfDay(for: asOf)
        var closing = closingDate(inMonthOf: today, day: closingDay, calendar: calendar)
        if closing < today { closing = closingDate(inMonthOf: addMonths(1, to: today, calendar), day: closingDay, calendar: calendar) }
        var result: [Cycle] = []
        for index in 0..<max(count, 0) {
            let previous = closingDate(inMonthOf: addMonths(-1, to: closing, calendar), day: closingDay, calendar: calendar)
            let start = calendar.date(byAdding: .day, value: 1, to: previous) ?? previous
            result.append(Cycle(
                start: start,
                closing: closing,
                dueDate: dueDay.map { dueDate(after: closing, day: $0, calendar: calendar) },
                isOpen: index == 0 && closing >= today
            ))
            closing = previous
        }
        return result
    }

    /// The charges on `accountID` inside `cycle`, closing day included. Counts everything the
    /// card was charged, fixed charges too, because the bill does.
    /// The card's transactions inside the cycle, newest first.
    static func transactions(in cycle: Cycle, accountID: String, from transactions: [SpendTransaction], calendar: Calendar = .current) -> [SpendTransaction] {
        let end = calendar.date(byAdding: .day, value: 1, to: cycle.closing) ?? cycle.closing
        return transactions
            .filter { $0.plaidAccountID == accountID && $0.date >= cycle.start && $0.date < end }
            .sorted { $0.date > $1.date }
    }

    static func total(of cycle: Cycle, accountID: String, in transactions: [SpendTransaction], calendar: Calendar = .current) -> Decimal {
        self.transactions(in: cycle, accountID: accountID, from: transactions, calendar: calendar)
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// The statement the next payment is for: the newest closed cycle whose due date has not
    /// passed. Nil when no due day is set or nothing is waiting to be paid.
    static func billDue(in cycles: [Cycle], asOf: Date, calendar: Calendar = .current) -> Cycle? {
        let today = calendar.startOfDay(for: asOf)
        return cycles.first { !$0.isOpen && ($0.dueDate.map { $0 >= today } ?? false) }
    }

    /// `day` in `date`'s month, clamped to the month's length (a card closing on the 31st closes
    /// on the 28th in a short February).
    static func closingDate(inMonthOf date: Date, day: Int, calendar: Calendar) -> Date {
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let length = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
        let clamped = min(max(day, 1), length)
        return calendar.date(byAdding: .day, value: clamped - 1, to: month) ?? month
    }

    /// The first `day` of a month that falls after `closing`: the same month when the due day is
    /// later than the closing day, otherwise the next.
    static func dueDate(after closing: Date, day: Int, calendar: Calendar) -> Date {
        let sameMonth = closingDate(inMonthOf: closing, day: day, calendar: calendar)
        if sameMonth > closing { return sameMonth }
        return closingDate(inMonthOf: addMonths(1, to: closing, calendar), day: day, calendar: calendar)
    }

    private static func addMonths(_ months: Int, to date: Date, _ calendar: Calendar) -> Date {
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    enum ChargeSort: String, CaseIterable {
        case date = "Date"
        case amount = "Amount"
    }

    struct ChargeGroup {
        let name: String
        let charges: [SpendTransaction]
        var total: Decimal { charges.reduce(Decimal.zero) { $0 + $1.amount } }
    }

    /// Orders charges newest first or largest first (ties fall back to newest first).
    static func sorted(_ charges: [SpendTransaction], by sort: ChargeSort) -> [SpendTransaction] {
        switch sort {
        case .date:
            return charges.sorted { $0.date > $1.date }
        case .amount:
            return charges.sorted { ($0.amount, $0.date) > ($1.amount, $1.date) }
        }
    }

    /// Charges grouped by Plaid category, each group sorted by `sort`. Groups run largest total
    /// first, or most recent charge first when sorting by date. Uncategorized charges form one group.
    static func grouped(_ charges: [SpendTransaction], by sort: ChargeSort) -> [ChargeGroup] {
        let byName = Dictionary(grouping: charges) { CategorySpendCalculator.displayName(for: $0.category) }
        let groups = byName.map { ChargeGroup(name: $0.key, charges: sorted($0.value, by: sort)) }
        switch sort {
        case .amount:
            return groups.sorted { ($0.total, $1.name) > ($1.total, $0.name) }
        case .date:
            return groups.sorted { ($0.charges[0].date, $1.name) > ($1.charges[0].date, $0.name) }
        }
    }
}
