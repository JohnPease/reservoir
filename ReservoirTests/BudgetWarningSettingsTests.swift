import XCTest
@testable import Reservoir

@MainActor
private final class ResetCountingEvaluator: BudgetWarningEvaluating {
    private(set) var resets = 0
    @discardableResult
    func evaluate(result: BudgetRecoveryCalculator.Result?, isAccountBackfillComplete: Bool) async
        -> BudgetWarningNotificationPlanner.Decision { .nothing }
    func resetBaseline() { resets += 1 }
}

@MainActor
final class BudgetWarningSettingsTests: XCTestCase {
    private let store = InMemoryWarningStore()
    private let evaluator = ResetCountingEvaluator()

    private func make(
        _ authorizer: ControlledAuthorizer, enabled: Bool = false
    ) -> BudgetWarningSettings {
        store.isEnabled = enabled
        return BudgetWarningSettings(store: store, authorizer: authorizer, notifier: evaluator)
    }

    func testStartsFromStoredToggle() {
        XCTAssertFalse(make(ControlledAuthorizer(status: .notDetermined)).isEnabled)
        XCTAssertTrue(make(ControlledAuthorizer(status: .authorized), enabled: true).isEnabled)
    }

    func testAllowEnablesAndResetsBaseline() async {
        let authorizer = ControlledAuthorizer(status: .notDetermined, grantOnRequest: true)
        let settings = make(authorizer)
        await settings.setEnabled(true)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(settings.isAuthorizationDenied)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(evaluator.resets, 1)
    }

    func testDenySnapsOffAndFlagsDenied() async {
        let authorizer = ControlledAuthorizer(status: .notDetermined, grantOnRequest: false)
        let settings = make(authorizer)
        await settings.setEnabled(true)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(settings.isAuthorizationDenied)
        XCTAssertEqual(evaluator.resets, 0)
    }

    func testAlreadyDeniedDoesNotRequest() async {
        let authorizer = ControlledAuthorizer(status: .denied)
        let settings = make(authorizer)
        await settings.setEnabled(true)
        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.isAuthorizationDenied)
    }

    func testAuthorizedAndProvisionalSkipThePrompt() async {
        for status in [NotificationAuthorization.authorized, .provisional, .ephemeral] {
            let authorizer = ControlledAuthorizer(status: status)
            let settings = make(authorizer)
            await settings.setEnabled(true)
            XCTAssertTrue(settings.isEnabled, "\(status)")
            XCTAssertEqual(authorizer.requestCount, 0)
        }
        XCTAssertEqual(evaluator.resets, 3)
    }

    func testRefreshDeniedWhileEnabledSnapsOff() async {
        let authorizer = ControlledAuthorizer(status: .authorized)
        let settings = make(authorizer, enabled: true)
        await settings.refreshAuthorization()
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.isAuthorizationDenied)

        authorizer.status = .denied
        await settings.refreshAuthorization()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(settings.isAuthorizationDenied)
    }

    func testRefreshRevokedToNotDeterminedSnapsOffWithoutDeniedFlag() async {
        let authorizer = ControlledAuthorizer(status: .notDetermined)
        let settings = make(authorizer, enabled: true)
        await settings.refreshAuthorization()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.isAuthorizationDenied)
    }

    func testRefreshClearsDeniedFlagAfterReAllowing() async {
        let authorizer = ControlledAuthorizer(status: .denied)
        let settings = make(authorizer)
        await settings.refreshAuthorization()
        XCTAssertTrue(settings.isAuthorizationDenied)
        authorizer.status = .authorized
        await settings.refreshAuthorization()
        XCTAssertFalse(settings.isAuthorizationDenied)
    }

    func testToggleOffDisables() async {
        let settings = make(ControlledAuthorizer(status: .authorized), enabled: true)
        await settings.setEnabled(false)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(store.isEnabled)
    }

    func testReentrancyWhileRequestingIsIgnored() async {
        let authorizer = ControlledAuthorizer(status: .notDetermined, grantOnRequest: true, holding: true)
        let settings = make(authorizer)
        let first = Task { await settings.setEnabled(true) }
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(settings.isRequesting)
        await settings.setEnabled(false)
        await settings.setEnabled(true)
        authorizer.release()
        await first.value
        XCTAssertFalse(settings.isRequesting)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(authorizer.requestCount, 1)
    }
}
