import XCTest

/// The card statements view tab (reservoir-17g).
final class CardStatementsUITests: XCTestCase {
    private func launchedApp(cycle: String?) -> XCUIApplication {
        let app = XCUIApplication.reservoirApp()
        app.launchEnvironment["UITEST_SCENARIO"] = "cardStatements"
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        app.launchEnvironment["UITEST_SEED_LINKED_ACCOUNT"] = "1"
        app.launchEnvironment["UITEST_SEED_SECOND_LINKED_ACCOUNT"] = "1"
        if let cycle { app.launchEnvironment["UITEST_SEED_CARD_CYCLE"] = cycle }
        app.launch()
        app.tabBars.buttons["Statements"].tap()
        return app
    }

    func testOpenCycleTotalsTheCardsChargesAndExcludesOtherAccounts() {
        let app = launchedApp(cycle: "28,16")
        let open = app.descendants(matching: .any)["statements.open.uitest-account-2"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.label.contains("$65.00"), "got: \(open.label)")
        XCTAssertTrue(app.staticTexts["Card ••1111"].exists, "the card is listed by name and mask")
    }

    func testACardWithNoClosingDayAsksForOne() {
        let app = launchedApp(cycle: nil)
        XCTAssertTrue(app.staticTexts["statements.prompt.uitest-account-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["statements.open.uitest-account-2"].exists)
    }
}
