import Foundation
import SwiftData

/// Maps a stored transaction to the plain value `CategorySpendCalculator` reads, so the calculator
/// itself stays free of SwiftData.
extension CategorySpendCalculator.Entry {
    init(_ transaction: SpendTransaction) {
        self.init(
            date: transaction.date, amount: transaction.amount,
            category: transaction.category, categoryDetailed: transaction.categoryDetailed
        )
    }
}
