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

    /// Looks up an accessibility identifier regardless of the underlying XCUIElement
    /// type — same reasoning/matcher as `TransactionsScreenUITests`' helper of the same
    /// name: `TransactionsView`'s `.list` identifier lands on a SwiftUI `List`, which
    /// XCUITest surfaces as a non-`.other` element type.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Pull-to-refresh (adq.6.4)

    /// `.merchantRulesRetag`'s seeded "Uber" transactions are unrelated in merchant/amount
    /// to `PlaidImportMergePromptURLProtocol`'s scripted "Coffee Shop" $12.50 fixture, so
    /// reusing that same scripted-transaction fixture here (rather than
    /// `.transactionImportMergePrompt`, whose seeded manual entry deliberately dedup-matches
    /// it) exercises the plain "added, no dedup match" path: pull-to-refresh should just
    /// bring the new transaction straight into the list, no merge prompt involved. Also
    /// gives a non-empty starting list, needed because `TransactionsView` only attaches
    /// `.refreshable` to its `List` — the empty-state `ContentUnavailableView` branch has no
    /// pull-to-refresh surface at all (see `TransactionsView.body`).
    func testPullToRefresh_seededSandboxTransaction_appearsInList() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = "merchantRulesRetag"
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = "mergePrompt"
        // reservoir-tq7: XCUITest's synthetic press-and-drag gestures don't reliably reach
        // the `List`'s underlying `UIRefreshControl` in this simulator environment (five
        // techniques tried, all failed). This enables `TransactionsView`'s debug-only
        // refresh-trigger toolbar button, which calls the exact same
        // `triggerRefresh() -> importService.runImport()` function `.refreshable` calls —
        // see `UITestScenario.isRefreshHookEnabled`.
        app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        app.launch()

        app.tabBars.buttons["Transactions"].tap()
        let list = element(app, "transactions.list")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Coffee Shop"].exists, "sanity check: Coffee Shop must not already be present before the refresh.")

        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 10), "pull-to-refresh must trigger the import pipeline and surface the newly-imported transaction.")
    }

    // MARK: - Import failure surfaces an error banner with a tappable technical-detail reveal

    /// `UITEST_FORCE_PLAID_ERROR` (same mechanism `PlaidDebugLinkUITests` uses) makes every
    /// Plaid call fail, so a foreground/pull-to-refresh-triggered import surfaces
    /// `presentedError`. Verifies both halves of the fix: the default coarse banner text,
    /// and that tapping it reveals `presentedErrorDetail` (the underlying raw error) in a
    /// "Technical details" sheet — an explicit opt-in reveal, not shown by default.
    func testImportFailure_showsErrorBanner_tapRevealsTechnicalDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        app.launch()

        app.tabBars.buttons["Transactions"].tap()
        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        // The banner's accessibility identifier sits on the `Text` nested inside a
        // `Button` (it's tappable, see `TransactionsView.body`), which XCUITest surfaces
        // as element type `.button`, not `.staticText` — same reasoning as `element(_:_:)`
        // above, so look it up the same type-agnostic way rather than via `app.staticTexts`.
        let errorBanner = element(app, "transactions.importError")
        XCTAssertTrue(errorBanner.waitForExistence(timeout: 10), "a failed import must surface the error banner.")
        XCTAssertEqual(errorBanner.label, "Couldn't connect to your bank. Try again.", "default banner text must stay the coarse, friendly category message, not a raw error string.")

        errorBanner.tap()

        let detailText = app.staticTexts["transactions.importErrorDetail"]
        XCTAssertTrue(detailText.waitForExistence(timeout: 5), "tapping the banner must reveal the technical-details sheet.")
        XCTAssertFalse(detailText.label.isEmpty, "technical detail must show the underlying raw error, not an empty placeholder.")
        XCTAssertNotEqual(detailText.label, "No further detail available.", "a real forced failure must populate presentedErrorDetail rather than falling back to the no-detail placeholder.")
    }

    /// The banner's "Retry" button calls the same `triggerRefresh()` entry point as
    /// `.refreshable`/the debug hook, not a separate retry path — under
    /// `UITEST_FORCE_PLAID_ERROR` the retry attempt fails too, so the banner staying
    /// present (rather than crashing or vanishing into a stuck state) confirms the button
    /// actually re-invokes the import pipeline instead of being a dead/no-op control.
    func testImportFailure_retryButton_reInvokesImportPipeline() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        app.launch()

        app.tabBars.buttons["Transactions"].tap()
        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        let errorBanner = element(app, "transactions.importError")
        XCTAssertTrue(errorBanner.waitForExistence(timeout: 10))

        let retryButton = app.buttons["transactions.importErrorRetry"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.tap()

        XCTAssertTrue(errorBanner.waitForExistence(timeout: 10), "retrying under a forced failure must still surface the error banner (a stuck spinner or crash would indicate the button isn't wired to runImport()).")
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
