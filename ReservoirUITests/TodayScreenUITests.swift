import XCTest

/// Covers the Today screen's state transitions per STANDARDS.md §5 ("XCUITest for key
/// flows") and the reservoir-adq.2 testability notes: empty state, normal state,
/// completion banner, and dismiss-and-reset. Each test launches the app with
/// `UITEST_SCENARIO` set so it starts from a deterministic in-memory fixture rather than
/// whatever's left in the on-disk store — see `UITestScenario` / `ReservoirApp`.
///
/// 44px hero sizing is a manual/code-review check, not asserted here.
final class TodayScreenUITests: XCTestCase {

    private func launchedApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testEmptyGoalStateShowsCreatePromptInsteadOfHero() {
        let app = launchedApp(scenario: "emptyGoal")

        XCTAssertTrue(app.otherElements["today.emptyGoalState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.hero"].exists)
        XCTAssertFalse(app.otherElements["today.stats"].exists)
    }

    func testEmptyGoalStateCreateGoalOpensStubSheet() {
        let app = launchedApp(scenario: "emptyGoal")

        XCTAssertTrue(app.buttons["today.createGoal"].waitForExistence(timeout: 5))
        app.buttons["today.createGoal"].tap()

        XCTAssertTrue(app.otherElements["today.createGoalSheet"].waitForExistence(timeout: 5))
    }

    func testNormalStateShowsHeroStatsAndRecentTransactions() {
        let app = launchedApp(scenario: "normal")

        XCTAssertTrue(app.otherElements["today.hero"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["today.stats"].exists)
        XCTAssertTrue(app.otherElements["today.recentTransactions"].exists)
        XCTAssertTrue(app.staticTexts["Coffee Shop"].exists)
        XCTAssertTrue(app.staticTexts["Excluded from limit"].exists)
    }

    func testAddTransactionOpensStubSheet() {
        let app = launchedApp(scenario: "normal")

        XCTAssertTrue(app.buttons["today.addTransaction"].waitForExistence(timeout: 5))
        app.buttons["today.addTransaction"].tap()

        XCTAssertTrue(app.otherElements["today.addTransactionSheet"].waitForExistence(timeout: 5))
    }

    func testCompletedGoalShowsBanner() {
        let app = launchedApp(scenario: "completedGoalBanner")

        XCTAssertTrue(app.otherElements["today.completionBanner"].waitForExistence(timeout: 5))
        // The completed goal isn't active, so the hero number shouldn't render alongside
        // the banner.
        XCTAssertFalse(app.otherElements["today.hero"].exists)
    }

    func testDismissingBannerResetsToEmptyGoalState() {
        let app = launchedApp(scenario: "completedGoalBanner")

        XCTAssertTrue(app.buttons["today.dismissBanner"].waitForExistence(timeout: 5))
        app.buttons["today.dismissBanner"].tap()

        XCTAssertTrue(app.otherElements["today.emptyGoalState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.completionBanner"].exists)
    }
}
