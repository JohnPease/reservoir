import Foundation
import UserNotifications

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
