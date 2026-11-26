import SwiftUI
import UIKit

/// The Settings "Notifications" section (reservoir-nka.3): one toggle for budget warnings,
/// and, when iOS notification permission is denied, a hint with a shortcut to iOS Settings.
/// All state and the permission flow live in `BudgetWarningSettings`.
struct BudgetWarningsSection: View {
    @Environment(BudgetWarningSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle(isOn: toggleBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Budget warnings")
                    Text("Get a heads-up when this month gets hard to recover or goes over budget.")
                        .font(.footnote)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
            }
            .disabled(settings.isRequesting)
            .accessibilityIdentifier("settings.budgetWarnings.toggle")

            if settings.isAuthorizationDenied {
                Text("Notifications are off for Reservoir in iOS Settings.")
                    .font(.footnote)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("settings.budgetWarnings.deniedHint")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("settings.budgetWarnings.openSettings")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Warnings are checked when you open Reservoir. You'll get at most one of each warning per month.")
                .foregroundStyle(Color("ReservoirTextSecondary"))
        }
    }

    /// Reads on while the system prompt is up, so the switch doesn't flicker back to off.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled || settings.isRequesting },
            set: { newValue in Task { await settings.setEnabled(newValue) } }
        )
    }
}
