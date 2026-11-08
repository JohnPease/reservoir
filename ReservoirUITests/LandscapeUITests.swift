import XCTest

/// The wide-screen layouts (reservoir-h2k) reached by rotating a phone: Transactions' detail
/// pane, and that the forms stay usable on a landscape phone's short screen.
final class LandscapeUITests: XCTestCase {

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launchedApp(scenario: String, seedAccount: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.reservoirApp()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        if seedAccount { app.launchEnvironment["UITEST_SEED_LINKED_ACCOUNT"] = "1" }
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        // Rotation animates; give the simulator a moment before querying or tapping.
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    func testTransactionsShowsDetailPaneAfterSelectingARow() {
        let app = launchedApp(scenario: "transactionsList")
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["transactions.detailPlaceholder"].waitForExistence(timeout: 5))
        let row = app.staticTexts["Coffee Shop"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["transactions.detail.edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["transactions.detailPlaceholder"].exists)
        app.buttons["transactions.detail.edit"].tap()
        XCTAssertTrue(app.otherElements["transactions.editTransactionSheet"].waitForExistence(timeout: 5))
    }

    func testBudgetFormCanBeSavedFromALandscapePhone() {
        let app = launchedApp(scenario: "emptyGoal", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        app.buttons["budget.setRow"].tap()
        XCTAssertTrue(app.otherElements["budget.createBudgetSheet"].waitForExistence(timeout: 5))
        let submit = app.buttons["budget.form.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isHittable, "the toolbar's Create stays reachable in landscape")
        XCTAssertTrue(app.textFields["budget.form.monthlyAmount"].isHittable)
    }

    func testAddTransactionSheetIsReachableInLandscape() {
        let app = launchedApp(scenario: "transactionsList")
        app.tabBars.buttons["Transactions"].tap()
        app.buttons["transactions.addTransaction"].tap()
        XCTAssertTrue(app.otherElements["transactions.addTransactionSheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
    }
}
