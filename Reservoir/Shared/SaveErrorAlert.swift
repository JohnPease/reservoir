import SwiftUI

/// The "Couldn't save" alert shown after a `PersistenceSaveHelper.saveOrRollback` failure
/// — extracted because this exact `isPresented`/`presenting`/`Button("OK")`/message block
/// was duplicated verbatim across every entry form and list view that performs a save or
/// delete (`TransactionEntryView`, `MerchantRuleEntryView`, `TransactionsView`,
/// `MerchantRulesView`, `GoalFormView`, `GoalsView`, `TodayView`) (STANDARDS.md §3, no
/// copy-paste).
extension View {
    /// - Parameter error: the error message to display, or `nil` when there's nothing to
    ///   show. Dismissing the alert (via "OK" or a swipe/tap-away) clears it back to `nil`.
    func saveErrorAlert(_ error: Binding<String?>) -> some View {
        alert(
            "Couldn't save",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { isPresented in if !isPresented { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK") { error.wrappedValue = nil }
        } message: { message in
            Text(message)
        }
    }
}
