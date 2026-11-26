import Foundation
import UserNotifications

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

/// The live `UNUserNotificationCenter` boundary (an I/O boundary, excluded from the unit
/// coverage bar like `PlaidServiceLive`). Resolves `UNUserNotificationCenter.current()` on each
/// use and never stores it, so constructing this is free of side effects.
@MainActor
final class UserNotificationCenterClient: NotificationAuthorizing, NotificationScheduling {
    /// The `userInfo` key `NotificationResponder` reads the deep link from.
    nonisolated static let deepLinkUserInfoKey = "deepLink"

    func authorizationStatus() async -> NotificationAuthorization {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.authorization(from: settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    func deliver(_ content: BudgetWarningNotificationContent) {
        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.sound = .default
        payload.threadIdentifier = content.threadIdentifier
        payload.userInfo = [Self.deepLinkUserInfoKey: content.deepLink.absoluteString]
        // A nil trigger delivers immediately; reusing the identifier replaces the earlier one.
        let request = UNNotificationRequest(identifier: content.identifier, content: payload, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated static func authorization(from status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
        }
    }
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
