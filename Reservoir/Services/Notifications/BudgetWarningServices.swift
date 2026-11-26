import Foundation

/// The budget warning pieces `RootTabView` owns for the app's lifetime: the monitor that
/// triggers evaluations and the settings model Settings binds to.
@MainActor
struct BudgetWarningServices {
    let monitor: BudgetWarningMonitor
    let settings: BudgetWarningSettings

    static func makeDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> BudgetWarningServices {
        let services = BudgetWarningNotifier.makeDefault(environment: environment)
        return BudgetWarningServices(
            monitor: BudgetWarningMonitor(notifier: services.notifier),
            settings: BudgetWarningSettings(
                store: services.store, authorizer: services.authorizer, notifier: services.notifier
            )
        )
    }
}
