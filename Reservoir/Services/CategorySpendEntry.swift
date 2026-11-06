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
    /// amount keyed by `persistentModelID`. Subscriptions are left out; their price changes are
    /// reported on the recurring list.
    static func outliers(
        in transactions: [SpendTransaction], now: Date, calendar: Calendar = .current
    ) -> [PersistentIdentifier: Decimal] {
        let entries = transactions.map(Entry.init)
        let subscriptions = Set(
            RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar)
                .map { merchantKey($0.merchant) }
        )
        let found = outliers(entries: entries, excluding: subscriptions, calendar: calendar)
        return Dictionary(uniqueKeysWithValues: found.compactMap { key, value in
            (key.base as? PersistentIdentifier).map { ($0, value) }
        })
    }
}
