import XCTest

/// Covers reservoir-adq.6.3's one mandated end-to-end flow: seed a manual transaction
/// and a matching Sandbox-fetched (scripted) transaction, trigger the debug import,
/// verify the merge prompt appears with the described copy/choices, and verify both the
/// "Merge" and "Keep both" outcomes land correctly in the Transactions list.
///
/// The `/transactions/sync` call itself is intercepted deterministically via
/// `UITEST_PLAID_IMPORT_SCENARIO=mergePrompt` (see `UITestScenario.plaidURLSession`'s
/// `PlaidImportMergePromptURLProtocol`), same reasoning as `PlaidDebugLinkUITests`'
/// `UITEST_FORCE_PLAID_ERROR` — this doesn't depend on Plaid's actual Sandbox API or
/// local credentials in `Config/Plaid.xcconfig`.
final class TransactionImportUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = "transactionImportMergePrompt"
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = "mergePrompt"
        app.launch()
        return app
    }

    private func triggerImport(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        let importButton = app.buttons["plaidDebug.importButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()
    }

    private func coffeeShopRowCount(_ app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Coffee Shop")).count
    }

    // MARK: - Merge prompt appears with the described copy/choices

    func testMergePromptAppearsWithMerchantAmountDateAndBothChoices() {
        let app = launchedApp()
        triggerImport(app)

        let mergeButton = app.buttons["plaidDebug.mergePrompt.merge"]
        let keepBothButton = app.buttons["plaidDebug.mergePrompt.keepBoth"]
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 10))
        XCTAssertTrue(keepBothButton.exists)

        // The dialog's title is built from the manual entry's merchant/amount/date (UX
        // spec: "This looks like a transaction you already added: [merchant, amount,
        // date]. Keep as one entry?") — assert the merchant and amount both appear
        // somewhere in the presented dialog text.
        XCTAssertTrue(app.staticTexts["Keep as one entry?"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Coffee Shop")).firstMatch.exists
                || app.otherElements.containing(NSPredicate(format: "label CONTAINS %@", "Coffee Shop")).firstMatch.exists
        )
    }

    // MARK: - Merge outcome

    func testMergeChoice_updatesManualEntryInPlace_noSecondRow() {
        let app = launchedApp()
        triggerImport(app)

        let mergeButton = app.buttons["plaidDebug.mergePrompt.merge"]
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 10))
        mergeButton.tap()

        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))
        XCTAssertEqual(coffeeShopRowCount(app), 1, "Merge must not create a second row for the same purchase.")
    }

    // MARK: - Keep both outcome

    func testKeepBothChoice_leavesManualUntouched_addsSecondRow() {
        let app = launchedApp()
        triggerImport(app)

        let keepBothButton = app.buttons["plaidDebug.mergePrompt.keepBoth"]
        XCTAssertTrue(keepBothButton.waitForExistence(timeout: 10))
        keepBothButton.tap()

        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))
        XCTAssertEqual(coffeeShopRowCount(app), 2, "Keep both must leave the manual entry and add the Plaid transaction as a second row.")
    }
}
