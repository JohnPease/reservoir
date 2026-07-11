import Foundation

/// Pure validation logic for the goal creation/edit form (adq.5), kept out of
/// `GoalFormView` per STANDARDS.md §3 so the exact validation rules and error copy are
/// unit-testable without driving SwiftUI. No `SwiftData`/`SwiftUI` import.
enum GoalFormValidator {

    /// Field-level validation errors for the goal form. `nil` for a field means that
    /// field currently passes validation.
    struct ValidationResult: Equatable {
        var targetAmountError: String?
        var targetDateError: String?
        var startingBalanceError: String?
        var startDateError: String?

        var isValid: Bool {
            targetAmountError == nil && targetDateError == nil
                && startingBalanceError == nil && startDateError == nil
        }
    }

    /// Bounds on how far in the past a creation-time `startDate` may be backdated.
    /// 90 days: generous headroom for JP's stated use case ("I started two weeks ago")
    /// while guarding against a mis-tapped date picker producing a multi-year-old
    /// `startDate` that would silently wreck `dailyBase` — see the bead description's
    /// "Start date" section for the full reasoning.
    static let maxBackdateDays = 90

    /// Validates all four creation fields. `targetAmount`/`startingBalance` are
    /// non-optional `Decimal` — `GoalFormView`'s bound `@State` properties are always a
    /// concrete `Decimal` (defaulting to `0`), never an unparsable/empty state, so there
    /// is no "field is empty" case to represent here.
    static func validateCreation(
        targetAmount: Decimal,
        targetDate: Date,
        startingBalance: Decimal,
        startDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> ValidationResult {
        ValidationResult(
            targetAmountError: validateTargetAmount(targetAmount, startingBalance: startingBalance),
            targetDateError: validateTargetDate(targetDate, mustBeAfter: referenceDate, calendar: calendar),
            startingBalanceError: validateStartingBalance(startingBalance),
            startDateError: validateStartDate(startDate, referenceDate: referenceDate, calendar: calendar)
        )
    }

    /// Validates the two editable edit-flow fields (`targetAmount`/`targetDate`) against
    /// the same rules as creation — `startingBalance`/`startDate` are read-only post
    /// creation, so they're passed in as fixed context, not re-validated. `targetDate`
    /// must be after both today-at-edit-time and the goal's (unchanged) `startDate`.
    static func validateEdit(
        targetAmount: Decimal,
        targetDate: Date,
        startingBalance: Decimal,
        startDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> ValidationResult {
        let targetDateFloor = max(referenceDate, startDate)
        return ValidationResult(
            targetAmountError: validateTargetAmount(targetAmount, startingBalance: startingBalance),
            targetDateError: validateTargetDate(targetDate, mustBeAfter: targetDateFloor, calendar: calendar),
            startingBalanceError: nil,
            startDateError: nil
        )
    }

    // MARK: - Per-field rules

    private static func validateTargetAmount(_ targetAmount: Decimal, startingBalance: Decimal) -> String? {
        guard targetAmount > startingBalance else {
            return "Target amount must be greater than your starting balance."
        }
        return nil
    }

    private static func validateTargetDate(_ targetDate: Date, mustBeAfter floor: Date, calendar: Calendar) -> String? {
        let targetDay = calendar.startOfDay(for: targetDate)
        let floorDay = calendar.startOfDay(for: floor)
        guard targetDay > floorDay else {
            return "Target date must be after today."
        }
        return nil
    }

    private static func validateStartingBalance(_ startingBalance: Decimal) -> String? {
        guard startingBalance >= 0 else {
            return "Starting balance can't be negative."
        }
        return nil
    }

    /// Bounds `startDate` to `[today - maxBackdateDays, today]` — see bead description's
    /// "Start date" section. Both error strings are the bead's exact, product-specified
    /// copy.
    private static func validateStartDate(_ startDate: Date, referenceDate: Date, calendar: Calendar) -> String? {
        let startDay = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: referenceDate)
        guard startDay <= today else {
            return "Start date can't be in the future"
        }
        let earliestAllowed = calendar.date(byAdding: .day, value: -maxBackdateDays, to: today)!
        guard startDay >= earliestAllowed else {
            return "Start date can't be more than 90 days ago"
        }
        return nil
    }
}
