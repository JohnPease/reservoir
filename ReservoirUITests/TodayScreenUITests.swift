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
        // Regression for review finding 2: the "no active goal" empty-state prompt must
        // not render underneath a completion banner — a completed-undismissed goal isn't
        // the same as having no goals at all.
        XCTAssertFalse(app.otherElements["today.emptyGoalState"].exists)
    }

    func testCompletedGoalWithOrphanedSpendShowsSpendWithoutEmptyStateOrHero() {
        let app = launchedApp(scenario: "completedGoalBannerWithOrphanedSpend")

        XCTAssertTrue(app.otherElements["today.completionBanner"].waitForExistence(timeout: 5))
        // Regression for review finding 2: orphaned spend dated today must stay visible
        // even though there's no active goal to attach a daily-limit hero to.
        XCTAssertTrue(app.otherElements["today.spentTodayOnly"].exists)
        XCTAssertFalse(app.otherElements["today.hero"].exists)
        XCTAssertFalse(app.otherElements["today.emptyGoalState"].exists)
    }

    func testDismissingBannerResetsToEmptyGoalState() {
        let app = launchedApp(scenario: "completedGoalBanner")

        XCTAssertTrue(app.buttons["today.dismissBanner"].waitForExistence(timeout: 5))
        app.buttons["today.dismissBanner"].tap()

        XCTAssertTrue(app.otherElements["today.emptyGoalState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.completionBanner"].exists)
    }

    // MARK: - Goal-met verification (reservoir-4za)

    func testCompletedGoalMetShowsCelebratoryCopy() {
        // "completedGoalBanner" has no spend recorded, so cumulative carry-forward
        // through targetDate is a full lifetime of underspend — the "met" case.
        let app = launchedApp(scenario: "completedGoalBanner")

        XCTAssertTrue(app.otherElements["today.completionBanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You reached your goal — nice work!"].exists)
        XCTAssertFalse(app.staticTexts["Your target date has arrived"].exists)
    }

    func testCompletedGoalNotMetShowsFactualNonPunitiveCopy() {
        let app = launchedApp(scenario: "completedGoalBannerNotMet")

        XCTAssertTrue(app.otherElements["today.completionBanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your target date has arrived"].exists)
        XCTAssertTrue(app.staticTexts["You spent more than planned along the way."].exists)
        XCTAssertFalse(app.staticTexts["You reached your goal — nice work!"].exists)
    }

    func testDismissingNotMetBannerResetsToEmptyGoalState() {
        // Dismiss behavior must be unchanged for the "not met" variant too.
        let app = launchedApp(scenario: "completedGoalBannerNotMet")

        XCTAssertTrue(app.buttons["today.dismissBanner"].waitForExistence(timeout: 5))
        app.buttons["today.dismissBanner"].tap()

        XCTAssertTrue(app.otherElements["today.emptyGoalState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.completionBanner"].exists)
    }
}
