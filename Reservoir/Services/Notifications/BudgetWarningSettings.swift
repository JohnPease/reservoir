import Foundation
import Observation

/// Settings-screen state for budget warnings (reservoir-nka.3): the on/off toggle and the
/// notification permission flow behind it. The system prompt appears only when the user turns
/// the toggle on. Turning it on (re)baselines the once-per-month record, so a warning already
/// showing on Today is not announced.
@Observable
@MainActor
final class BudgetWarningSettings {
    private(set) var isEnabled: Bool
    /// True while the system prompt is up; the toggle is disabled and `setEnabled` ignores calls.
    private(set) var isRequesting = false
    /// Permission is denied in iOS Settings (the toggle can't be on).
    private(set) var isAuthorizationDenied = false

    @ObservationIgnored private let store: BudgetWarningNotificationStoring
    @ObservationIgnored private let authorizer: NotificationAuthorizing
    @ObservationIgnored private let notifier: BudgetWarningEvaluating

    init(store: BudgetWarningNotificationStoring, authorizer: NotificationAuthorizing, notifier: BudgetWarningEvaluating) {
        self.store = store
        self.authorizer = authorizer
        self.notifier = notifier
        isEnabled = store.isEnabled
    }

    func setEnabled(_ on: Bool) async {
        guard !isRequesting else { return }
        guard on else {
            store.isEnabled = false
            isEnabled = false
            return
        }
        isRequesting = true
        defer { isRequesting = false }
        switch await authorizer.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            enable()
        case .denied:
            snapOff(denied: true)
        case .notDetermined:
            if await authorizer.requestAuthorization() {
                enable()
            } else {
                // Declined, or the request itself failed: only a real `.denied` earns the
                // "off in iOS Settings" hint.
                snapOff(denied: await authorizer.authorizationStatus() == .denied)
            }
        }
    }

    /// Re-reads permission (the user may have changed it in iOS Settings). A toggle that is on
    /// while permission is gone snaps off.
    func refreshAuthorization() async {
        let status = await authorizer.authorizationStatus()
        isAuthorizationDenied = status == .denied
        if isEnabled, !status.allowsDelivery {
            store.isEnabled = false
            isEnabled = false
        }
    }

    private func enable() {
        notifier.resetBaseline()
        store.isEnabled = true
        isEnabled = true
        isAuthorizationDenied = false
    }

    private func snapOff(denied: Bool) {
        store.isEnabled = false
        isEnabled = false
        isAuthorizationDenied = denied
    }
}
