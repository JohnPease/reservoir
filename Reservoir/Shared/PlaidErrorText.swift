import SwiftUI

/// The consistent `Text(error.userFacingMessage).foregroundStyle(Color("ReservoirDeficit"))` treatment for a
/// `PlaidErrorCategory`, shared by every place a Plaid-related failure is shown inline
/// (`SettingsView`'s Link-error section, `TransactionsView`'s import error banner) —
/// extracted after those call sites drifted into copy-paste (STANDARDS.md §3), same
/// reasoning as `SaveErrorAlert.swift`'s extraction.
/// Callers still chain their own `.accessibilityIdentifier(...)`/layout modifiers on top.
struct PlaidErrorText: View {
    let error: PlaidErrorCategory

    var body: some View {
        Text(error.userFacingMessage)
            // Reuses `ReservoirDeficit` — see `LabeledField`'s identical note (reservoir-jog):
            // it's the only existing "something's wrong" text token, applied here to a
            // Plaid connection/import failure rather than its documented financial-deficit
            // meaning. Flagged for confirmation rather than inventing a new asset.
            .foregroundStyle(Color("ReservoirDeficit"))
    }
}
