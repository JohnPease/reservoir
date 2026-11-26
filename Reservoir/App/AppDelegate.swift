import UIKit
import UserNotifications

/// Exists to install the notification delegate before the app finishes launching, which is
/// the only point iOS guarantees a tap that cold-launched the app is delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Strong: `UNUserNotificationCenter.delegate` is weak.
    private let notificationResponder = NotificationResponder()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Unit-test and UI-test processes never touch the real notification center.
        if !TestProcessGate.isTestProcess() {
            UNUserNotificationCenter.current().delegate = notificationResponder
        }
        return true
    }
}
