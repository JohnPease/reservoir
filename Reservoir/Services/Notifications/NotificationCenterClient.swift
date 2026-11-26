import Foundation

/// Asks iOS about, and for, notification permission.
@MainActor
protocol NotificationAuthorizing: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    /// Shows the system prompt when status is `notDetermined`; `true` when permission was granted.
    func requestAuthorization() async -> Bool
}

/// Posts a budget warning to the user.
@MainActor
protocol NotificationScheduling: AnyObject {
    func deliver(_ content: BudgetWarningNotificationContent)
}

/// Used under unit tests and UI tests, where posting a real notification would be a side
/// effect on the host device.
@MainActor
final class NoOpNotificationScheduler: NotificationScheduling {
    func deliver(_ content: BudgetWarningNotificationContent) {}
}

/// Scriptable permission, so UI tests never show the real system prompt. In a test process
/// the default (no `UITEST_NOTIFICATION_PERMISSION`) is "not determined, and refuses".
@MainActor
final class StubNotificationAuthorizer: NotificationAuthorizing {
    static let environmentKey = "UITEST_NOTIFICATION_PERMISSION"

    private(set) var status: NotificationAuthorization
    private let requestGrants: Bool
    private(set) var requestCount = 0

    init(status: NotificationAuthorization = .notDetermined, requestGrants: Bool = false) {
        self.status = status
        self.requestGrants = requestGrants
    }

    /// `allow` grants the prompt, `deny` refuses it, `alreadyDenied` starts denied; anything
    /// else (or nothing) starts undetermined and refuses.
    convenience init(environment: [String: String]) {
        switch environment[Self.environmentKey] {
        case "allow": self.init(status: .notDetermined, requestGrants: true)
        case "alreadyDenied": self.init(status: .denied, requestGrants: false)
        default: self.init(status: .notDetermined, requestGrants: false)
        }
    }

    func authorizationStatus() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        guard status == .notDetermined else { return status.allowsDelivery }
        status = requestGrants ? .authorized : .denied
        return requestGrants
    }
}
