import Foundation

/// What `BudgetWarningMonitor` and `BudgetWarningSettings` talk to.
@MainActor
protocol BudgetWarningEvaluating: AnyObject {
    /// The Settings toggle. Callers skip building a result while it is off; the planner's
    /// disabled rule stays the authoritative guard.
    var isEnabled: Bool { get }
    /// Decides, records and (maybe) posts. Returns what was decided.
    @discardableResult
    func evaluate(result: BudgetRecoveryCalculator.Result?, isAccountBackfillComplete: Bool) async
        -> BudgetWarningNotificationPlanner.Decision
    /// Forgets the once-per-month record, so the next evaluation baselines silently.
    func resetBaseline()
}

/// The single UI-free entry point for budget warning notifications (reservoir-nka.3):
/// evaluate, de-duplicate and post, and the only code that touches the notified record. A
/// future background refresh (reservoir-kqy) can call `evaluate` with no view in the picture.
///
/// At-most-once: `evaluate` suspends only to read the permission status. Everything after it
/// (load record, decide, write record, deliver) runs synchronously on the main actor, and the
/// record is written before delivery, so two overlapping evaluations can't both post.
@MainActor
final class BudgetWarningNotifier: BudgetWarningEvaluating {
    private let store: BudgetWarningNotificationStoring
    private let authorizer: NotificationAuthorizing
    private let scheduler: NotificationScheduling
    private let calendar: Calendar

    init(
        store: BudgetWarningNotificationStoring,
        authorizer: NotificationAuthorizing,
        scheduler: NotificationScheduling,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.authorizer = authorizer
        self.scheduler = scheduler
        self.calendar = calendar
    }

    var isEnabled: Bool { store.isEnabled }

    @discardableResult
    func evaluate(result: BudgetRecoveryCalculator.Result?, isAccountBackfillComplete: Bool) async
        -> BudgetWarningNotificationPlanner.Decision {
        let authorization = await authorizer.authorizationStatus()
        // No suspension point below this line.
        let decision = BudgetWarningNotificationPlanner.decide(.init(
            isEnabled: store.isEnabled,
            authorization: authorization,
            isAccountBackfillComplete: isAccountBackfillComplete,
            result: result,
            record: store.loadRecord(),
            calendar: calendar
        ))
        switch decision {
        case .nothing:
            break
        case .clearRecord:
            store.clearRecord()
        case .saveRecord(let record):
            store.saveRecord(record)
        case .notify(let record, let content):
            store.saveRecord(record)
            scheduler.deliver(content)
        }
        return decision
    }

    func resetBaseline() {
        store.clearRecord()
    }

    /// The wired-up pieces `RootTabView` needs.
    struct Services {
        var notifier: BudgetWarningNotifier
        var authorizer: NotificationAuthorizing
        var store: BudgetWarningNotificationStoring
    }

    /// Live notification center, or inert doubles under unit tests and UI tests (so the real
    /// system prompt never appears and nothing is posted to the device).
    static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Services {
        let store = BudgetWarningNotificationStore()
        let authorizer: NotificationAuthorizing
        let scheduler: NotificationScheduling
        if TestProcessGate.isTestProcess(environment: environment) {
            authorizer = StubNotificationAuthorizer(environment: environment)
            scheduler = NoOpNotificationScheduler()
        } else {
            let client = UserNotificationCenterClient()
            authorizer = client
            scheduler = client
        }
        let notifier = BudgetWarningNotifier(store: store, authorizer: authorizer, scheduler: scheduler, calendar: calendar)
        return Services(notifier: notifier, authorizer: authorizer, store: store)
    }
}
