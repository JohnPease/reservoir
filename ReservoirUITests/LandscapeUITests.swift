import XCTest

/// The wide-screen layouts (reservoir-h2k, reservoir-wrx) reached by rotating a phone: the stock tab bar,
/// Today's tank, Transactions' detail pane, the category ledger
/// spread, and that the forms stay usable on a landscape phone's short screen.
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

    func testLandscapeKeepsTheStockTabBar() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget.card"].waitForExistence(timeout: 5))
    }

    func testTodayDrawsTheBudgetAsATankWithTheDaysPurchases() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        XCTAssertTrue(app.descendants(matching: .any)["today.tank"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["today.tank.remaining"].exists)
        XCTAssertTrue(app.staticTexts["Budget Coffee"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["today.budgetHero"].exists, "the tank replaces the number hero")
    }

    func testCategoryLedgerShowsTheChargesBesideTheList() {
        let app = launchedApp(scenario: "categorizedSpend")
        let card = app.descendants(matching: .any)["today.categoryCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["categories.ledger"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Concert Hall"].waitForExistence(timeout: 5), "the biggest category's charges are open")
        XCTAssertTrue(app.buttons["categories.ledger.trend"].exists)
    }
}
