import XCTest

/// Covers the tap-to-expand spend chart modal on `ActiveGoalCardView` (reservoir-t5u):
/// tapping the compact chart opens `SpendingChartDetailView`'s sheet, and swiping down
/// dismisses it. Uses the `goalsScreenMixed` fixture (existing scenario,
/// `ReservoirUITests/GoalsScreenUITests.swift`) — its active goal started 10 days ago
/// with zero spend, so the compact chart renders real bars (not the "not enough data"
/// state, which needs < 3 days of history) but stays within a single 30-day window
/// (`chartWindowCount == 1`).
///
/// Swipe-paging between chart windows (`TabView(.page)`) is NOT covered here: doing so
/// would require a fixture goal older than 30 days (none of the existing scenarios have
/// one), and driving `TabView(.page)` swipes reliably alongside Swift Charts'
/// `chartXSelection` tap gesture in XCUITest is a known source of flaky UI tests. Per
/// the task instructions, skipping rather than writing a test likely to flap — the
/// underlying windowing math (`chartWindowCount`/`chartWindowEnd`/`spendChartWindow`
/// boundaries) is fully covered by `GoalsScreenCalculatorTests`, which is the layer
/// that actually needs the boundary assurance.
final class GoalSpendingChartUITests: XCTestCase {

    private func launchedApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        app.tabBars.buttons["Goals"].tap()
        return app
    }

    func testTapCompactChartOnGoalCardOpensDetailSheet() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        let chartButton = app.buttons["goals.card.chart"]
        XCTAssertTrue(chartButton.waitForExistence(timeout: 5))
        chartButton.tap()

        XCTAssertTrue(app.otherElements["goals.chartDetailSheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["goals.chartDetail.goalName"].exists)
        XCTAssertTrue(app.staticTexts["goals.chartDetail.dateRange"].exists)
        // The active goal's chart, page 0, must actually be present (not the
        // "not enough data" state — 10 days of history clears the 3-day minimum).
        XCTAssertTrue(app.otherElements["goals.chartDetail.chart.0"].exists)
    }

    func testSwipeDownDismissesChartDetailSheet() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        let chartButton = app.buttons["goals.card.chart"]
        XCTAssertTrue(chartButton.waitForExistence(timeout: 5))
        chartButton.tap()

        let sheet = app.otherElements["goals.chartDetailSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        // Plain `sheet.swipeDown()` computes its touch-down point relative to the
        // WHOLE identified element's bounds (header text + the 280pt-tall chart +
        // footer) — on a `.large`-detent sheet that touch-down point lands inside the
        // chart's own frame, not above it. `GoalSpendingChartView`'s modal chart is
        // wired with `.chartXSelection` (tap-to-annotate), which Swift Charts backs
        // with a drag-recognizing gesture, so a touch that starts inside the chart gets
        // claimed as a scrub instead of propagating to the system's interactive
        // sheet-dismiss gesture. Explicitly start the drag near the very top of the
        // sheet (in the header/nav-bar chrome above the chart, well before its ~11%
        // vertical offset) so the touch-down never lands on `Chart` at all.
        let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let end = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertFalse(sheet.waitForExistence(timeout: 3))
        // Back on the Goals list underneath.
        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
    }
}
