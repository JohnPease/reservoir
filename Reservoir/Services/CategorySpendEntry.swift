import Foundation
import SwiftData

/// Maps a stored transaction to the plain value `CategorySpendCalculator` reads, so the calculator
/// itself stays free of SwiftData.
extension CategorySpendCalculator.Entry {
    init(_ transaction: SpendTransaction) {
        self.init(
            date: transaction.date, amount: transaction.amount,
            category: transaction.category, categoryDetailed: transaction.categoryDetailed,
            merchant: transaction.merchantName,
            id: transaction.persistentModelID
        )
    }
}

extension CategorySpendCalculator {
    /// Stored transactions much larger than their merchant's usual (reservoir-cn4), as the usual
    /// amount keyed by `persistentModelID`. Subscriptions (`recurring`) are left out; their price
    /// changes are reported on the recurring list.
    static func outliers(
        entries: [Entry], recurring: [RecurringChargeCalculator.Recurring], calendar: Calendar = .current
    ) -> [PersistentIdentifier: Decimal] {
        let found = outliers(entries: entries, excluding: Set(recurring.map { merchantKey($0.merchant) }), calendar: calendar)
        return Dictionary(uniqueKeysWithValues: found.compactMap { key, value in
            (key.base as? PersistentIdentifier).map { ($0, value) }
        })
    }

    /// Same, detecting subscriptions itself, for screens that do not already have them.
    static func outliers(
        in transactions: [SpendTransaction], now: Date, calendar: Calendar = .current
    ) -> [PersistentIdentifier: Decimal] {
        let entries = transactions.map(Entry.init)
        let recurring = RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar)
        return outliers(entries: entries, recurring: recurring, calendar: calendar)
    }
}
