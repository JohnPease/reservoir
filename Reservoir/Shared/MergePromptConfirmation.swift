import SwiftUI

/// A new sibling to `DeleteConfirmation.swift`'s `deleteConfirmation`, not a forced
/// reuse of it (adq.6.3's technical approach) — `deleteConfirmation` hardcodes one
/// `.destructive` action plus "Cancel"; this prompt is a genuine two-way choice with no
/// cancel state and no destructive semantics (see the bead's "Merge prompt UX" section:
/// "Merge" updates the existing manual entry in place, "Keep both" imports the incoming
/// transaction alongside it — neither is a delete).
extension View {
    /// - Parameters:
    ///   - pendingItem: the item awaiting a merge/keep-both decision, or `nil` when no
    ///     prompt is showing. Dismissing the dialog by swipe (rather than tapping either
    ///     button) leaves `pendingItem` as-is — the caller's queue still holds the item,
    ///     so it's re-prompted the next time this view appears, per the bead's "No undo
    ///     needed beyond edit/delete" note (there is deliberately no silent-dismiss
    ///     "Cancel" option here — one of the two choices must be made).
    ///   - title / message: computed from the pending item, mirroring
    ///     `deleteConfirmation`'s shape.
    ///   - mergeActionTitle / keepBothActionTitle: button labels, defaulting to "Merge"/
    ///     "Keep both" per the UX spec's copy.
    ///   - mergeAccessibilityIdentifier / keepBothAccessibilityIdentifier: optional
    ///     accessibility identifiers for UI tests to target the two buttons directly.
    ///   - onMerge / onKeepBoth: performs the corresponding resolution for the pending
    ///     item.
    func mergePromptConfirmation<T>(
        pendingItem: Binding<T?>,
        title: (T) -> String,
        message: (T) -> String? = { _ in nil },
        mergeActionTitle: (T) -> String = { _ in "Merge" },
        keepBothActionTitle: (T) -> String = { _ in "Keep both" },
        mergeAccessibilityIdentifier: String? = nil,
        keepBothAccessibilityIdentifier: String? = nil,
        onMerge: @escaping (T) -> Void,
        onKeepBoth: @escaping (T) -> Void
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
            // Merge listed first — the closest thing to "recommended" a
            // confirmationDialog's plain-button API allows (button order + copy; there
            // is no dedicated "default" role distinct from `.cancel`/`.destructive`).
            Button(mergeActionTitle(item)) {
                onMerge(item)
                pendingItem.wrappedValue = nil
            }
            .accessibilityIdentifier(mergeAccessibilityIdentifier)
            Button(keepBothActionTitle(item)) {
                onKeepBoth(item)
                pendingItem.wrappedValue = nil
            }
            .accessibilityIdentifier(keepBothAccessibilityIdentifier)
        } message: { item in
            if let text = message(item) {
                Text(text)
            }
        }
    }
}

private extension View {
    /// `.accessibilityIdentifier(_:)` requires a non-optional `String` — this lets call
    /// sites pass `nil` to mean "no identifier" without an `if let` at each site. Mirrors
    /// `DeleteConfirmation.swift`'s private helper of the same shape (kept file-local,
    /// not shared, since `extension View` helpers can't be `internal`-exported without
    /// risking ambiguous-overload collisions between the two files' identical
    /// signatures).
    @ViewBuilder
    func accessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
