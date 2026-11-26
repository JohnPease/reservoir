import XCTest
import UserNotifications
@testable import Reservoir

/// Test doubles shared by the budget warning notifier, monitor and settings tests.
@MainActor
final class RecordingScheduler: NotificationScheduling {
    private(set) var delivered: [BudgetWarningNotificationContent] = []
    /// Runs at the moment of delivery, before it is recorded here.
    var onDeliver: (() -> Void)?
    func deliver(_ content: BudgetWarningNotificationContent) {
        onDeliver?()
        delivered.append(content)
    }
}

final class InMemoryWarningStore: BudgetWarningNotificationStoring {
    var isEnabled = false
    var record: BudgetWarningNotificationRecord?
    func loadRecord() -> BudgetWarningNotificationRecord? { record }
    func saveRecord(_ record: BudgetWarningNotificationRecord) { self.record = record }
    func clearRecord() { record = nil }
}

/// Reports a fixed status, optionally holding every status call until `release()`.
@MainActor
final class ControlledAuthorizer: NotificationAuthorizing {
    var status: NotificationAuthorization
    var grantOnRequest: Bool
    /// What a failed request leaves the status as (a declined prompt leaves `.denied`; an
    /// error leaves it unchanged).
    var statusAfterFailedRequest: NotificationAuthorization = .denied
    private(set) var requestCount = 0
    private var holding: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(status: NotificationAuthorization, grantOnRequest: Bool = true, holding: Bool = false) {
        self.status = status
        self.grantOnRequest = grantOnRequest
        self.holding = holding
    }

    func authorizationStatus() async -> NotificationAuthorization {
        if holding { await withCheckedContinuation { waiters.append($0) } }
        return status
    }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if holding { await withCheckedContinuation { waiters.append($0) } }
        status = grantOnRequest ? .authorized : statusAfterFailedRequest
        return grantOnRequest
    }

    func release() {
        holding = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class BudgetWarningNotifierTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func result(_ level: BudgetWarningLevel) -> BudgetRecoveryCalculator.Result {
        BudgetRecoveryCalculator.Result(
            monthStart: calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!,
            carryIn: 0, recovery: nil,
            warning: BudgetRecoveryCalculator.Warning(level: level), banner: nil
        )
    }

    private func make(status: NotificationAuthorization = .authorized, enabled: Bool = true, holding: Bool = false)
        -> (BudgetWarningNotifier, InMemoryWarningStore, ControlledAuthorizer, RecordingScheduler) {
        let store = InMemoryWarningStore()
        store.isEnabled = enabled
        let authorizer = ControlledAuthorizer(status: status, holding: holding)
        let scheduler = RecordingScheduler()
        let notifier = BudgetWarningNotifier(store: store, authorizer: authorizer, scheduler: scheduler, calendar: calendar)
        return (notifier, store, authorizer, scheduler)
    }

    func testRecordIsWrittenBeforeDeliver() async {
        let (notifier, store, _, scheduler) = make()
        await notifier.evaluate(result: result(.none), isAccountBackfillComplete: true)
        var recordAtDelivery: BudgetWarningNotificationRecord?
        scheduler.onDeliver = { recordAtDelivery = store.record }
        await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true)
        XCTAssertEqual(scheduler.delivered.count, 1)
        XCTAssertEqual(recordAtDelivery?.level, .hardToRecover)
    }

    func testExactlyOnceAcrossRepeatedEvaluations() async {
        let (notifier, _, _, scheduler) = make()
        await notifier.evaluate(result: result(.none), isAccountBackfillComplete: true)
        for _ in 0..<4 { await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true) }
        XCTAssertEqual(scheduler.delivered.count, 1)
        await notifier.evaluate(result: result(.pointOfNoReturn), isAccountBackfillComplete: true)
        XCTAssertEqual(scheduler.delivered.map(\.title), ["Hard to recover this month", "Over budget this month"])
        XCTAssertEqual(Set(scheduler.delivered.map(\.identifier)).count, 1)
    }

    func testOverlappingEvaluationsDeliverOnce() async {
        let (notifier, store, authorizer, scheduler) = make(holding: true)
        store.record = BudgetWarningNotificationRecord(month: BudgetWarningMonth(year: 2026, month: 11), level: .none)
        let first = Task { await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true) }
        let second = Task { await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true) }
        await Task.yield()
        await Task.yield()
        authorizer.release()
        _ = await (first.value, second.value)
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    func testNotifierExposesStoreToggle() {
        let (notifier, store, _, _) = make(enabled: false)
        XCTAssertFalse(notifier.isEnabled)
        store.isEnabled = true
        XCTAssertTrue(notifier.isEnabled)
    }

    func testDeniedDisabledAndUndeterminedNeverDeliver() async {
        for (status, enabled) in [(NotificationAuthorization.denied, true), (.notDetermined, true), (.authorized, false)] {
            let (notifier, store, _, scheduler) = make(status: status, enabled: enabled)
            store.record = BudgetWarningNotificationRecord(month: BudgetWarningMonth(year: 2026, month: 11), level: .none)
            let decision = await notifier.evaluate(result: result(.pointOfNoReturn), isAccountBackfillComplete: true)
            XCTAssertEqual(decision, .nothing)
            XCTAssertTrue(scheduler.delivered.isEmpty)
        }
    }

    func testBackfillIncompleteClearsRecord() async {
        let (notifier, store, _, scheduler) = make()
        store.record = BudgetWarningNotificationRecord(month: BudgetWarningMonth(year: 2026, month: 11), level: .hardToRecover)
        await notifier.evaluate(result: result(.pointOfNoReturn), isAccountBackfillComplete: false)
        XCTAssertNil(store.record)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testFirstEvaluationBaselinesSilently() async {
        let (notifier, store, _, scheduler) = make()
        await notifier.evaluate(result: result(.pointOfNoReturn), isAccountBackfillComplete: true)
        XCTAssertEqual(store.record?.level, .pointOfNoReturn)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testResetBaselineClearsRecord() async {
        let (notifier, store, _, scheduler) = make()
        await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true)
        XCTAssertNotNil(store.record)
        notifier.resetBaseline()
        XCTAssertNil(store.record)
        // Baselines silently again rather than announcing the level already showing.
        await notifier.evaluate(result: result(.hardToRecover), isAccountBackfillComplete: true)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testMakeDefaultUnderTestEnvironmentUsesInertDoubles() async {
        let services = BudgetWarningNotifier.makeDefault(environment: [
            "UITEST_SCENARIO": "x", StubNotificationAuthorizer.environmentKey: "allow",
        ])
        let stub = services.authorizer as? StubNotificationAuthorizer
        XCTAssertNotNil(stub)
        let status = await services.authorizer.authorizationStatus()
        XCTAssertEqual(status, .notDetermined)
        let granted = await services.authorizer.requestAuthorization()
        XCTAssertTrue(granted)
        let after = await services.authorizer.authorizationStatus()
        XCTAssertEqual(after, .authorized)
    }

    func testMakeDefaultOutsideTestsPicksLiveClientTypes() {
        // Type check only: building the live client has no side effect, and nothing here
        // evaluates, so no notification can be requested or posted.
        XCTAssertFalse(TestProcessGate.isTestProcess(environment: ["HOME": "/x"]))
        let client = UserNotificationCenterClient()
        XCTAssertTrue((client as NotificationAuthorizing) is UserNotificationCenterClient)
        XCTAssertTrue((client as NotificationScheduling) is UserNotificationCenterClient)
    }

    func testAuthorizationMappingCoversEveryStatus() {
        let pairs: [(UNAuthorizationStatus, NotificationAuthorization)] = [
            (.notDetermined, .notDetermined), (.denied, .denied), (.authorized, .authorized),
            (.provisional, .provisional), (.ephemeral, .ephemeral),
        ]
        for (system, expected) in pairs {
            XCTAssertEqual(UserNotificationCenterClient.authorization(from: system), expected)
        }
    }

    // MARK: Stub authorizer

    func testStubAuthorizerScenarios() async {
        let deny = StubNotificationAuthorizer(environment: [StubNotificationAuthorizer.environmentKey: "deny"])
        let denyGranted = await deny.requestAuthorization()
        XCTAssertFalse(denyGranted)
        XCTAssertEqual(deny.status, .denied)

        let already = StubNotificationAuthorizer(environment: [StubNotificationAuthorizer.environmentKey: "alreadyDenied"])
        XCTAssertEqual(already.status, .denied)
        let alreadyGranted = await already.requestAuthorization()
        XCTAssertFalse(alreadyGranted)

        let absent = StubNotificationAuthorizer(environment: [:])
        XCTAssertEqual(absent.status, .notDetermined)
        let absentGranted = await absent.requestAuthorization()
        XCTAssertFalse(absentGranted)

        NoOpNotificationScheduler().deliver(BudgetWarningNotificationContent(
            title: "t", body: "b", identifier: "i", threadIdentifier: "t", deepLink: URL(string: "reservoir://today")!
        ))
    }
}
