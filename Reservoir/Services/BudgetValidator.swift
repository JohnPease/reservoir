import Foundation
import SwiftData

/// Pure validation for the budget form (reservoir-j8t). Kept out of `BudgetFormView`
/// (STANDARDS.md §3) so the rules, floor computation and exact copy are unit-testable.
enum BudgetValidator {

    /// Plaid's history cap; the budget window can't start earlier.
    static let maxHistoryDays = 730

    /// Largest accepted monthly amount (inclusive); keeps absurd typos out of the math.
    static let maxMonthlyAmount: Decimal = 1_000_000

    struct ValidationResult: Equatable {
        var amountError: String?
        var accountsError: String?
        var startDateError: String?

        var isValid: Bool { amountError == nil && accountsError == nil && startDateError == nil }
    }

    /// New budgets default to the 1st of the current month.
    static func defaultStartDate(referenceDate: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: referenceDate)
        return calendar.date(from: components) ?? calendar.startOfDay(for: referenceDate)
    }

    /// The earliest allowed start: Plaid's history cap. Deliberately not tied to the earliest
    /// imported transaction, so a freshly linked phone (or a quiet first few days of a month)
    /// can still back-date to the 1st; days with no spend simply accrue their full base.
    static func startDateFloor(referenceDate: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: -maxHistoryDays, to: today) ?? today
    }

    static func validate(
        monthlyAmount: Decimal,
        selectedAccountIDs: Set<String>,
        startDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> ValidationResult {
        ValidationResult(
            amountError: amountError(for: monthlyAmount),
            accountsError: selectedAccountIDs.isEmpty ? "Choose at least one account." : nil,
            startDateError: validateStartDate(
                startDate,
                floor: startDateFloor(referenceDate: referenceDate, calendar: calendar),
                referenceDate: referenceDate,
                calendar: calendar
            )
        )
    }

    private static func amountError(for amount: Decimal) -> String? {
        if amount <= 0 { return "Enter a monthly amount greater than $0." }
        if amount > maxMonthlyAmount { return "Enter an amount of $1,000,000 or less." }
        return nil
    }

    private static func validateStartDate(_ startDate: Date, floor: Date, referenceDate: Date, calendar: Calendar) -> String? {
        let startDay = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: referenceDate)
        guard startDay <= today else { return "Start date can't be in the future." }
        guard startDay >= floor else {
            return "Start date can't be before \(floor.formatted(.dateTime.month(.abbreviated).day().year()))."
        }
        return nil
    }
}
