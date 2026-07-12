import SwiftUI

/// The delete-confirmation `.confirmationDialog` + "pending item" `@State` pattern —
/// extracted because it was copy-pasted across `GoalsView`, `TransactionsView`, and
/// `MerchantRulesView`, differing only in the pending item's type/title (STANDARDS.md
/// §3, no copy-paste).
extension View {
    /// - Parameters:
    ///   - pendingItem: the item awaiting delete confirmation, or `nil` when no
    ///     confirmation is showing. Tapping "Delete" or "Cancel" (or dismissing the
    ///     dialog any other way) resets this to `nil`.
    ///   - title: the confirmation dialog's title, computed from the pending item (e.g.
    ///     `GoalsView`'s pluralized "N attributed transactions" copy).
    ///   - onDelete: performs the actual delete for the confirmed item.
    func deleteConfirmation<T>(
        pendingItem: Binding<T?>,
        title: (T) -> String,
        onDelete: @escaping (T) -> Void
    ) -> some View {
        confirmationDialog(
            pendingItem.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { pendingItem.wrappedValue != nil },
                set: { isPresented in if !isPresented { pendingItem.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingItem.wrappedValue { onDelete(item) }
                pendingItem.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pendingItem.wrappedValue = nil }
        }
    }
}
