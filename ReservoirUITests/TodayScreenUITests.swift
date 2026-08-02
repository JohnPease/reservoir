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

    func testRecentTransactionsRowShowsDateNotJustTime() {
        // TodayView passes `showDate: true` to `TransactionRowView` (unlike
        // `TransactionsView`, whose day-grouped list leaves it at the `false` default):
        // this list is flat and can span multiple days, so a bare time like "7:24 AM" is
        // ambiguous. Assert the row's secondary caption includes a recognizable date
        // component (month abbreviation + day, e.g. "Jul 29, 7:24 AM"), not just a
        // time-only string.
        let app = launchedApp(scenario: "normal")

        XCTAssertTrue(app.otherElements["today.recentTransactions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))

        // Locale-formatted as e.g. "Aug 1 at 9:29 AM" (month abbreviation + day + time),
        // not just "9:29 AM" — matching on the leading "<3-letter month> <day>" prefix
        // rather than a specific separator keeps this independent of the exact
        // `.dateTime` phrasing.
        let dateCaption = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[A-Za-z]{3} \\d{1,2}.*\\d{1,2}:\\d{2}.*")
        )
        XCTAssertGreaterThan(dateCaption.count, 0, "Recent-transactions row caption should include a date, not a bare time")
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
