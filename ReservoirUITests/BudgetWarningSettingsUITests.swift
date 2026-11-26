import XCTest

/// reservoir-nka.3: the Settings "Budget warnings" toggle and its permission flow. The system
/// permission dialog never appears: under UI tests `BudgetWarningNotifier.makeDefault` swaps in
/// a stub authorizer scripted by `UITEST_NOTIFICATION_PERMISSION` (`allow`, `deny`,
/// `alreadyDenied`; absent means "not determined, and refuses"). Delivery, the real prompt and
/// tapping a delivered notification are manual checks (README, "Budget warning notifications").
final class BudgetWarningSettingsUITests: XCTestCase {
    private func launchedApp(permission: String? = nil) -> XCUIApplication {
        let app = XCUIApplication.reservoirApp()
        app.launchEnvironment["UITEST_SCENARIO"] = "normal"
        app.launchEnvironment["UITEST_RESET_BUDGET_WARNINGS"] = "1"
        if let permission { app.launchEnvironment["UITEST_NOTIFICATION_PERMISSION"] = permission }
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.budgetWarnings.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    /// A wide two-line toggle's centre is its label; the switch itself is at the trailing edge.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func testToggleDefaultsOffAndNoPromptAtLaunch() {
        let app = launchedApp()
        let toggle = openSettings(app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.buttons["settings.budgetWarnings.openSettings"].exists)
        XCTAssertFalse(app.staticTexts["settings.budgetWarnings.deniedHint"].exists)
    }

    func testToggleOnWithAllowStaysOn() {
        let app = launchedApp(permission: "allow")
        let toggle = openSettings(app)
        tapSwitch(toggle)
        let deadline = Date().addingTimeInterval(5)
        while toggle.value as? String != "1", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(toggle.value as? String, "1")
        // Still on a moment later (nothing snaps it back off).
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.buttons["settings.budgetWarnings.openSettings"].exists)
    }

    func testToggleOnWithDenySnapsOffAndShowsOpenSettings() {
        let app = launchedApp(permission: "deny")
        let toggle = openSettings(app)
        tapSwitch(toggle)
        XCTAssertTrue(app.staticTexts["settings.budgetWarnings.deniedHint"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.budgetWarnings.openSettings"].exists)
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testAlreadyDeniedShowsHint() {
        let app = launchedApp(permission: "alreadyDenied")
        let toggle = openSettings(app)
        // Shown on appearing, before any tap. Open Settings is deliberately not tapped.
        XCTAssertTrue(app.staticTexts["settings.budgetWarnings.deniedHint"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.budgetWarnings.openSettings"].exists)
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
