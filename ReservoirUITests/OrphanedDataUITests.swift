import XCTest

/// reservoir-xxm: Settings' "Remove transactions from unlinked accounts" control. The
/// scenario seeds three imported rows tagged with an unlinked item ("gone-item") and one
/// manual row, alongside a linked "uitest-item".
final class OrphanedDataUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication.reservoirApp()
        app.launchEnvironment["UITEST_SCENARIO"] = "orphanedImportedTransactions"
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launch()
        return app
    }

    func testRemoveOrphanedData_confirmationStatesCount_cancelKeeps_confirmRemovesOnlyOrphans() {
        let app = launchedApp()
        app.tabBars.buttons["Settings"].tap()

        let control = app.buttons["settings.removeOrphanedData"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.tap()

        // `.firstMatch`: confirmationDialog buttons can register twice (see PlaidRelinkUITests).
        let confirm = app.buttons.matching(identifier: "settings.confirmRemoveOrphanedData").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Remove 3 imported transactions?"].exists, "dialog must state how many transactions go.")

        // Cancel (tap outside, per reservoir-wcd) leaves the control and data in place.
        app.dismissPopoverByTappingOutside()
        XCTAssertFalse(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(control.exists)

        control.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        // Nothing left over, so the control disappears.
        XCTAssertFalse(control.waitForExistence(timeout: 5))

        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Manual Keep"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Orphan 1"].exists)
    }
}
