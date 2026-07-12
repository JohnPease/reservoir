import Foundation
import SwiftData

/// Pure validation logic for the merchant rule creation/edit form (adq.3), kept out of
/// `MerchantRuleEntryView` per STANDARDS.md §3. No `SwiftUI` import.
enum MerchantRuleValidator {
    struct ValidationResult: Equatable {
        var merchantNameError: String?
        var typeError: String?

        var isValid: Bool {
            merchantNameError == nil && typeError == nil
        }
    }

    /// - Parameters:
    ///   - type: `nil` represents "no type chosen yet" — required on create (no silent
    ///     default, since this rule will silently tag transactions both going forward and
    ///     retroactively).
    ///   - ruleBeingEdited: the rule currently being edited, excluded from the duplicate
    ///     check against itself. `nil` on create.
    static func validate(
        merchantName: String,
        type: TransactionType?,
        existingRules: [MerchantRule],
        excluding ruleBeingEdited: MerchantRule? = nil
    ) -> ValidationResult {
        ValidationResult(
            merchantNameError: validateMerchantName(merchantName, existingRules: existingRules, excluding: ruleBeingEdited),
            typeError: type == nil ? "Choose a type." : nil
        )
    }

    private static func validateMerchantName(
        _ merchantName: String,
        existingRules: [MerchantRule],
        excluding ruleBeingEdited: MerchantRule?
    ) -> String? {
        let trimmed = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Merchant name is required."
        }
        let isDuplicate = existingRules.contains { rule in
            rule !== ruleBeingEdited && rule.merchantName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !isDuplicate else {
            return "A rule for this merchant already exists."
        }
        return nil
    }
}
