import Foundation

/// The tank view's figures (reservoir-wrx): today's limit as a full tank, and each purchase
/// as a step down in the order it was entered. Pure; the caller passes the purchases that
/// count toward the limit, so the final level matches the hero's "remaining".
enum DayStepsCalculator {
    struct Purchase: Equatable {
        var merchant: String
        var amount: Decimal
        /// Entry order within the day. Plaid dates carry no time of day, so this is when
        /// the app saw the charge, not when it happened.
        var enteredAt: Date
    }

    struct Step: Equatable {
        var merchant: String
        var amount: Decimal
        /// What is left to spend once this purchase is made.
        var levelAfter: Decimal
    }

    struct Day: Equatable {
        var limit: Decimal
        var steps: [Step]
        /// What is left to spend now; negative once the day is over its limit.
        var remaining: Decimal { steps.last?.levelAfter ?? limit }
    }

    static func day(limit: Decimal, purchases: [Purchase]) -> Day {
        var level = limit
        let steps = purchases
            .enumerated()
            .sorted { $0.element.enteredAt != $1.element.enteredAt ? $0.element.enteredAt < $1.element.enteredAt : $0.offset < $1.offset }
            .map { _, purchase -> Step in
                level -= purchase.amount
                return Step(merchant: purchase.merchant, amount: purchase.amount, levelAfter: level)
            }
        return Day(limit: limit, steps: steps)
    }

    /// How full the tank is, 0...1: `level` against the day's `limit`. An empty or overdrawn
    /// tank is 0, and a day with no limit has nothing to fill.
    static func fill(level: Decimal, limit: Decimal) -> Double {
        guard limit > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: level / limit).doubleValue
        return min(max(fraction, 0), 1)
    }
}
