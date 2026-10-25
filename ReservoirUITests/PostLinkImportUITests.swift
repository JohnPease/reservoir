import XCTest

/// Covers reservoir-xle's post-link auto-import UI: the importing state, rows appearing
/// without a "No transactions yet" flash, and the give-up ("Still fetching") state with its
/// Refresh button.
///
/// Real Plaid Link can't be automated, so the `onLinkSuccess` wiring itself is NOT driven
/// here. `UITEST_ENABLE_POST_LINK_HOOK=1` renders a debug toolbar button that calls the exact
/// `TransactionImportService.runImportAfterLink(itemID:)` the hook calls (unit tests cover
/// the hook firing). `UITEST_PLAID_IMPORT_SCENARIO` scripts `/transactions/sync` as
/// NOT_READY (empty) a couple of times, then data (`notReadyThenReady`), or forever
/// (`neverReady`); poll waits are shortened to 1.5s in those scenarios.
final class PostLinkImportUITests: XCTestCase {
    private func launchedApp(scenario: String, uiScenario: String = "transactionsZeroGoals") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = uiScenario
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = scenario
        app.launchEnvironment["UITEST_ENABLE_POST_LINK_HOOK"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func startPostLinkImport(_ app: XCUIApplication) {
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(element(app, "transactions.emptyState").waitForExistence(timeout: 5), "sanity: an empty app starts on the plain empty state.")
        let trigger = app.buttons["transactions.debugPostLinkTrigger"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()
    }

    func testPostLinkImport_notReadyThenReady_showsImportingThenRows_withoutEmptyStateFlash() {
        let app = launchedApp(scenario: "notReadyThenReady")
        startPostLinkImport(app)

        XCTAssertTrue(element(app, "transactions.importingState").waitForExistence(timeout: 5), "the importing state must show while the post-link import polls.")
        XCTAssertFalse(element(app, "transactions.emptyState").exists, "'No transactions yet' must not show while importing.")
        XCTAssertFalse(element(app, "transactions.stillFetchingState").exists)

        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 15), "rows must appear once Plaid reports the item ready.")
        XCTAssertFalse(element(app, "transactions.importingState").exists)
        XCTAssertFalse(element(app, "transactions.emptyState").exists)
    }

    func testPostLinkImport_neverReady_givesUpWithStillFetchingStateAndRefreshButton() {
        let app = launchedApp(scenario: "neverReady")
        startPostLinkImport(app)

        XCTAssertTrue(element(app, "transactions.importingState").waitForExistence(timeout: 5))

        let stillFetching = element(app, "transactions.stillFetchingState")
        XCTAssertTrue(stillFetching.waitForExistence(timeout: 15), "after the bounded poll gives up, the empty state explains it's still fetching.")
        XCTAssertFalse(element(app, "transactions.importingState").exists)
        XCTAssertFalse(element(app, "transactions.emptyState").exists, "giving up is not the plain empty state.")
        XCTAssertFalse(element(app, "transactions.importError").exists, "giving up is not an error.")
        XCTAssertTrue(app.staticTexts["Still fetching your transactions"].exists)

        let refresh = app.buttons["transactions.refreshButton"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        // A plain refresh is a single sync (no polling); still not ready, so the same state remains.
        XCTAssertTrue(stillFetching.waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
    }

    /// reservoir-crf: relinking keeps existing rows, so the full-screen importing state never
    /// shows — a slim banner must.
    func testPostLinkImport_withExistingRows_showsImportingBannerThenClearsIt() {
        let app = launchedApp(scenario: "notReadyThenReady", uiScenario: "transactionsList")
        app.tabBars.buttons["Transactions"].tap()
        let trigger = app.buttons["transactions.debugPostLinkTrigger"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()

        XCTAssertTrue(element(app, "transactions.importingBanner").waitForExistence(timeout: 5), "a banner must show while importing even though the list already has rows.")
        XCTAssertFalse(element(app, "transactions.importingState").exists, "the full-screen state is only for an empty list.")

        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 15))
        let banner = element(app, "transactions.importingBanner")
        let deadline = Date().addingTimeInterval(15)
        while banner.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertFalse(banner.exists, "the banner must clear once the import finishes.")
    }
}
