import SwiftUI

/// A form row pairing a control with its inline validation error, matching the "exact
/// error copy shown inline under the offending field" requirement without repeating the
/// `VStack`/error-`Text` boilerplate at every field (STANDARDS.md §3). Originally a
/// private type inside `GoalFormView` (adq.5); extracted here so `TransactionEntryView`/
/// `MerchantRuleEntryView` (adq.3) reuse the same pattern instead of redefining it.
struct LabeledField<Content: View>: View {
    let label: String
    let error: String?
    /// Prefix for the error `Text`'s accessibility identifier (`"<prefix>.error.<label>"`)
    /// — each form keeps its own existing identifier namespace (`goalForm`,
    /// `transactionEntry`, `merchantRuleEntry`) rather than sharing one.
    var errorIdentifierPrefix: String = "goalForm"
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(errorIdentifierPrefix).error.\(label)")
            }
        }
    }
}
