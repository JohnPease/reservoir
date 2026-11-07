import Foundation

extension Decimal {
    /// "$1,234": US dollars with no cents, for summary lines where cents are noise.
    var wholeDollarText: String {
        formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
