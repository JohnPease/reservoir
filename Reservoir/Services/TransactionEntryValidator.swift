import Foundation
import SwiftData

/// Pure validation + form-default logic for the manual transaction entry form (adq.3),
/// kept out of `TransactionEntryView` per STANDARDS.md §3. Imports `SwiftData` only to
/// reference the `SavingsGoal`/`TransactionType` model types themselves (per STANDARDS.md
/// §4's `*Validator`/`*Calculator` exception for mapping `@Model` types) — never imports
/// `SwiftUI`.
enum TransactionEntryValidator {
    struct ValidationResult: Equatable {
        var amountError: String?
        var dateError: String?
        var merchantNameError: String?
        var goalAttributionError: String?

        var isValid: Bool {
            amountError == nil && dateError == nil && merchantNameError == nil && goalAttributionError == nil
        }
    }

    /// The goal-attribution picker's required behavior, driven entirely by how many
    /// active goals exist (see bead "Goal attribution" section, incl. the 2026-07-12
    /// zero-active-goals clarification).
    enum GoalAttributionRequirement: Equatable {
        /// Exactly one active goal exists — pre-select it; no explicit confirmation step
        /// needed (minimizes taps for the common case).
        case autoSelect(SavingsGoal)
        /// Zero active goals exist — there is nothing to pick from. "Unattributed" is
        /// pre-selected and already counts as confirmed; the picker must not render as an
        /// empty/broken control requiring action that isn't actually available.
        case noActiveGoals
        /// Two or more active goals exist — the user must explicitly pick one or confirm
        /// "Unattributed" before save is enabled; never silently guess among goals.
        case explicitChoiceRequired

        static func == (lhs: GoalAttributionRequirement, rhs: GoalAttributionRequirement) -> Bool {
            switch (lhs, rhs) {
            case (.autoSelect(let left), .autoSelect(let right)):
                return left.persistentModelID == right.persistentModelID
            case (.noActiveGoals, .noActiveGoals):
                return true
            case (.explicitChoiceRequired, .explicitChoiceRequired):
                return true
            default:
                return false
            }
        }
    }

    /// Reuses `TodayScreenCalculator.activeGoals` as the sole source of "active goal"
    /// logic (per the bead's kickoff check 1) — callers pass the already-filtered active
    /// goal list in, this function never re-derives activeness itself.
    static func goalAttributionRequirement(activeGoals: [SavingsGoal]) -> GoalAttributionRequirement {
        if activeGoals.count == 1, let onlyGoal = activeGoals.first {
            return .autoSelect(onlyGoal)
        }
        if activeGoals.isEmpty {
            return .noActiveGoals
        }
        return .explicitChoiceRequired
    }

    /// Resolves the `isManualOverride` flag to persist when saving from the entry form.
    ///
    /// Invariant (see `SpendTransaction.isManualOverride`'s doc comment in
    /// `SchemaV3.swift`): this flag records *sticky user intent* — "did a person
    /// deliberately set/change `type` on this transaction" — not a live comparison
    /// against whatever `MerchantRule` happens to match right now. A `MerchantRule`
    /// added or edited after the fact must never flip this retroactively (that's what
    /// `MerchantRuleRetagCalculator` relies on to know which transactions are safe to
    /// retag).
    ///
    /// That means the answer depends on whether the user actually touched the type
    /// control *during this entry/edit session*:
    /// - If they didn't touch it, their intent didn't change this session, so whatever
    ///   was already true stands: `false` for a brand-new transaction (nothing to
    ///   override yet), or the transaction's existing `isManualOverride` when editing
    ///   (preserved exactly, not recomputed from current rule state).
    /// - If they did touch it, compare their final choice to what the default would be
    ///   absent any explicit interaction — the matching rule's suggestion, or `.variable`
    ///   if no rule matches. A choice that lands back on the default isn't an override
    ///   (e.g. re-confirming the auto-suggested type); a choice that diverges is.
    ///
    /// - Parameters:
    ///   - suggestedType: the currently-matching `MerchantRule`'s suggested type, if any.
    ///   - chosenType: the type currently selected in the form.
    ///   - hasUserInteractedWithTypeControl: true once the user has directly tapped the
    ///     type segmented control during this entry/edit session (as opposed to the type
    ///     merely being pre-filled or auto-suggested) — see
    ///     `TransactionEntryView.typeBinding`.
    ///   - existingIsManualOverride: the value to fall back to when the control wasn't
    ///     touched this session — pass `false` for create mode, or the transaction's
    ///     current `isManualOverride` for edit mode.
    static func isManualOverride(
        suggestedType: TransactionType?,
        chosenType: TransactionType,
        hasUserInteractedWithTypeControl: Bool,
        existingIsManualOverride: Bool
    ) -> Bool {
        guard hasUserInteractedWithTypeControl else {
            return existingIsManualOverride
        }
        let defaultType = suggestedType ?? .variable
        return chosenType != defaultType
    }

    static func validate(
        amount: Decimal,
        date: Date,
        merchantName: String,
        hasConfirmedGoalAttribution: Bool,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> ValidationResult {
        ValidationResult(
            amountError: validateAmount(amount),
            dateError: validateDate(date, referenceDate: referenceDate, calendar: calendar),
            merchantNameError: validateMerchantName(merchantName),
            goalAttributionError: validateGoalAttribution(hasConfirmedGoalAttribution: hasConfirmedGoalAttribution)
        )
    }

    // MARK: - Per-field rules

    private static func validateAmount(_ amount: Decimal) -> String? {
        guard amount > 0 else {
            return "Amount must be greater than zero."
        }
        return nil
    }

    /// Date must be today or in the past (device-local calendar day) — a future-dated
    /// entry would inflate "spent today"/carry-forward math on a day that hasn't happened
    /// yet. No lower bound: backdating is a legitimate fallback use case.
    private static func validateDate(_ date: Date, referenceDate: Date, calendar: Calendar) -> String? {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: referenceDate)
        guard day <= today else {
            return "Date can't be in the future."
        }
        return nil
    }

    private static func validateMerchantName(_ merchantName: String) -> String? {
        let trimmed = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Merchant name is required."
        }
        return nil
    }

    private static func validateGoalAttribution(hasConfirmedGoalAttribution: Bool) -> String? {
        guard !hasConfirmedGoalAttribution else { return nil }
        return "Choose a goal or confirm Unattributed."
    }
}
