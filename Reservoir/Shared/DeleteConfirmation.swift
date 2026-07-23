import SwiftUI

/// The confirmation-dialog + "pending item" `@State` pattern — extracted because it
/// was copy-pasted across `GoalsView`, `TransactionsView`, and `MerchantRulesView`,
/// differing only in the pending item's type/title (STANDARDS.md §3, no copy-paste).
/// Originally delete-only; generalized (PR #12 review finding) to also back
/// `SettingsView`'s Sandbox -> Production switch confirmation and its Unlink
/// confirmation, both of which needed a non-"Delete" action label, an optional message,
/// and accessibility-identifier hooks.
extension View {
    /// - Parameters:
    ///   - pendingItem: the item awaiting confirmation, or `nil` when no confirmation
    ///     is showing. Tapping the action button or "Cancel" (or dismissing the dialog
    ///     any other way) resets this to `nil`.
    ///   - title: the confirmation dialog's title, computed from the pending item (e.g.
    ///     `GoalsView`'s pluralized "N attributed transactions" copy).
    ///   - message: optional body text shown below the title (e.g.
    ///     `SettingsView`'s real-money warning). Defaults to no message, matching
    ///     every pre-existing `deleteConfirmation` caller.
    ///   - actionTitle: the destructive action button's label, computed from the
    ///     pending item. Defaults to `"Delete"`, matching every pre-existing caller.
    ///   - actionAccessibilityIdentifier / cancelAccessibilityIdentifier: optional
    ///     accessibility identifiers for the two buttons, for UI tests that need to
    ///     target them directly. `nil` (the default) attaches no identifier, matching
    ///     every pre-existing caller's un-identified Delete/Cancel buttons.
    ///   - onConfirm: performs the confirmed action for the pending item.
    func deleteConfirmation<T>(
        pendingItem: Binding<T?>,
        title: (T) -> String,
        message: (T) -> String? = { _ in nil },
        actionTitle: (T) -> String = { _ in "Delete" },
        actionAccessibilityIdentifier: String? = nil,
        cancelAccessibilityIdentifier: String? = nil,
        onDelete onConfirm: @escaping (T) -> Void
    ) -> some View {
        confirmationDialog(
            pendingItem.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { pendingItem.wrappedValue != nil },
                set: { isPresented in if !isPresented { pendingItem.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingItem.wrappedValue
        ) { item in
            Button(actionTitle(item), role: .destructive) {
                onConfirm(item)
                pendingItem.wrappedValue = nil
            }
            .accessibilityIdentifier(actionAccessibilityIdentifier)
            Button("Cancel", role: .cancel) { pendingItem.wrappedValue = nil }
                .accessibilityIdentifier(cancelAccessibilityIdentifier)
        } message: { item in
            if let text = message(item) {
                Text(text)
            }
        }
    }
}

private extension View {
    /// `.accessibilityIdentifier(_:)` requires a non-optional `String` — this lets
    /// call sites pass `nil` to mean "no identifier" without an `if let` at each site.
    @ViewBuilder
    func accessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
