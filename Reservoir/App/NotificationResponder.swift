import Foundation
import Observation
import UserNotifications

/// Reads the deep link a budget warning notification carries.
enum NotificationDeepLink {
    static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let string = userInfo[UserNotificationCenterClient.deepLinkUserInfoKey] as? String else { return nil }
        return URL(string: string)
    }
}

/// Hands a tapped notification's link from the (nonisolated) notification delegate to the
/// SwiftUI hierarchy. `pending` survives until `RootTabView` consumes it, which covers a cold
/// launch where the tap arrives before the view hierarchy exists.
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private(set) var pending: URL?

    func route(_ url: URL?) {
        guard let url else { return }
        pending = url
    }

    /// Returns and clears the pending link.
    func consume() -> URL? {
        defer { pending = nil }
        return pending
    }
}

/// `UNUserNotificationCenter`'s delegate: shows warnings while the app is open (foreground-only
/// warnings would otherwise be silent) and routes a tap to Today. Uses the completion-handler
/// delegate methods, which are nonisolated, so no actor-isolation conflicts with the
/// Objective-C protocol; the hop to the main actor is explicit.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let url = NotificationDeepLink.url(from: response.notification.request.content.userInfo)
        Task { @MainActor in DeepLinkRouter.shared.route(url) }
        completionHandler()
    }
}
