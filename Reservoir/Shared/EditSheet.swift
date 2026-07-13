import SwiftUI

/// The "sheet presented for whichever item is pending edit" pattern — extracted because
/// `TransactionsView`, `MerchantRulesView`, and `GoalsView` each hand-rolled the identical
/// `.sheet(isPresented: Binding(get: { pendingItem != nil }, set: { ... }))` wrapper around
/// their own edit form, differing only in the item type and the form view (STANDARDS.md
/// §3, no copy-paste). Mirrors `deleteConfirmation`'s shape in `DeleteConfirmation.swift`.
extension View {
    /// - Parameters:
    ///   - pendingItem: the item currently being edited, or `nil` when no edit sheet is
    ///     showing. Dismissing the sheet (by any means) resets this to `nil`.
    ///   - content: the edit form for the given item, built once the sheet is presented.
    func editSheet<T, Content: View>(
        pendingItem: Binding<T?>,
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        sheet(
            isPresented: Binding(
                get: { pendingItem.wrappedValue != nil },
                set: { isPresented in if !isPresented { pendingItem.wrappedValue = nil } }
            )
        ) {
            if let item = pendingItem.wrappedValue {
                content(item)
            }
        }
    }
}
