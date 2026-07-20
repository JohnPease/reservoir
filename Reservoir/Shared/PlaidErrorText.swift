import SwiftUI

/// The consistent `Text(error.userFacingMessage).foregroundStyle(.red)` treatment for a
/// `PlaidErrorCategory`, shared by every place a Plaid-related failure is shown inline
/// (`SettingsView`'s Link-error section, `TransactionsView`'s import error banner) —
/// extracted after those call sites drifted into copy-paste (STANDARDS.md §3), same
/// reasoning as `SaveErrorAlert.swift`'s extraction.
/// Callers still chain their own `.accessibilityIdentifier(...)`/layout modifiers on top.
struct PlaidErrorText: View {
    let error: PlaidErrorCategory

    var body: some View {
        Text(error.userFacingMessage)
            .foregroundStyle(.red)
    }
}
