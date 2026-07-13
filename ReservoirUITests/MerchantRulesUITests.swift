import XCTest

/// Covers Merchant Rule management (reservoir-adq.3) per STANDARDS.md §5: create/edit/
/// delete, duplicate-merchant-name rejection with an inline error, and the retroactive
/// retag pass — including the `isManualOverride` protection that keeps a manually
/// overridden transaction from being silently retagged by a later rule change. Each test
/// launches the app with `UITEST_SCENARIO` set so it starts from a deterministic
/// in-memory fixture — see `UITestScenario`.
final class MerchantRulesUITests: XCTestCase {

    private func launchedOnMerchantRulesScreen(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.buttons["transactions.merchantRulesLink"].waitForExistence(timeout: 5))
        app.buttons["transactions.merchantRulesLink"].tap()
        return app
    }

    /// Looks up an accessibility identifier regardless of the underlying XCUIElement type
    /// — see `TransactionsScreenUITests`' identical helper for why `otherElements` alone
    /// isn't enough for a SwiftUI `List`'s identifier (it surfaces as `CollectionView`).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Create

    func testCreateMerchantRuleRequiresExplicitTypeThenSucceeds() {
        let app = launchedOnMerchantRulesScreen(scenario: "merchantRulesManage")

        app.buttons["merchantRules.addRule"].tap()
        XCTAssertTrue(app.otherElements["merchantRules.createSheet"].waitForExistence(timeout: 5))

        app.textFields["merchantRuleEntry.merchantName"].tap()
        app.textFields["merchantRuleEntry.merchantName"].typeText("Trader Joes")

        // No default type is chosen — "Choose a type" is still selected, so save stays
        // disabled until the user makes an explicit choice.
        XCTAssertFalse(app.buttons["merchantRuleEntry.submit"].isEnabled)

        app.buttons["merchantRuleEntry.type"].tap()
        let variableOption = app.buttons["Variable"]
        XCTAssertTrue(variableOption.waitForExistence(timeout: 5))
        variableOption.tap()

        XCTAssertTrue(app.buttons["merchantRuleEntry.submit"].isEnabled)
        app.buttons["merchantRuleEntry.submit"].tap()

        XCTAssertTrue(element(app, "merchantRules.list").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Trader Joes"].waitForExistence(timeout: 5))
    }

    // MARK: - Duplicate name rejection

    func testDuplicateMerchantNameShowsInlineErrorAndBlocksSave() {
        let app = launchedOnMerchantRulesScreen(scenario: "merchantRulesManage")

        app.buttons["merchantRules.addRule"].tap()
        XCTAssertTrue(app.otherElements["merchantRules.createSheet"].waitForExistence(timeout: 5))

        // "Starbucks" already exists (case-insensitively) in the fixture.
        app.textFields["merchantRuleEntry.merchantName"].tap()
        app.textFields["merchantRuleEntry.merchantName"].typeText("starbucks")

        let error = app.staticTexts["merchantRuleEntry.error.Merchant name"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "A rule for this merchant already exists.")
        XCTAssertFalse(app.buttons["merchantRuleEntry.submit"].isEnabled)
    }

    // MARK: - Edit

    func testEditMerchantRuleChangesType() {
        let app = launchedOnMerchantRulesScreen(scenario: "merchantRulesManage")

        XCTAssertTrue(app.staticTexts["Starbucks"].waitForExistence(timeout: 5))
        app.staticTexts["Starbucks"].tap()
        XCTAssertTrue(app.otherElements["merchantRules.editSheet"].waitForExistence(timeout: 5))

        app.buttons["merchantRuleEntry.type"].tap()
        let fixedOption = app.buttons["Fixed"]
        XCTAssertTrue(fixedOption.waitForExistence(timeout: 5))
        fixedOption.tap()

        app.buttons["merchantRuleEntry.submit"].tap()

        XCTAssertTrue(element(app, "merchantRules.list").waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["merchantRules.editSheet"].exists)
        XCTAssertTrue(app.staticTexts["Fixed"].waitForExistence(timeout: 5))
    }

    // MARK: - Delete

    func testDeleteMerchantRuleRequiresConfirmation() {
        let app = launchedOnMerchantRulesScreen(scenario: "merchantRulesManage")

        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))
        app.staticTexts["Amazon"].swipeLeft()

        let swipeDeleteButton = app.buttons["Delete"]
        XCTAssertTrue(swipeDeleteButton.waitForExistence(timeout: 5))
        swipeDeleteButton.tap()

        XCTAssertTrue(app.staticTexts["Delete this merchant rule? Existing transactions keep their current tag."].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()

        XCTAssertFalse(app.staticTexts["Amazon"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Starbucks"].exists)
    }

    // MARK: - Retroactive retag + isManualOverride protection

    func testCreatingMerchantRuleRetagsMatchingTransactionButNotManualOverride() {
        let app = launchedOnMerchantRulesScreen(scenario: "merchantRulesRetag")

        // Both fixture transactions ("Uber" $25, not overridden; "Uber" $40, manually
        // overridden) start as `variable` — no visible "Excluded from limit" caption yet.
        app.buttons["merchantRules.addRule"].tap()
        XCTAssertTrue(app.otherElements["merchantRules.createSheet"].waitForExistence(timeout: 5))

        app.textFields["merchantRuleEntry.merchantName"].tap()
        app.textFields["merchantRuleEntry.merchantName"].typeText("Uber")

        app.buttons["merchantRuleEntry.type"].tap()
        let fixedOption = app.buttons["Fixed"]
        XCTAssertTrue(fixedOption.waitForExistence(timeout: 5))
        fixedOption.tap()

        app.buttons["merchantRuleEntry.submit"].tap()
        XCTAssertTrue(element(app, "merchantRules.list").waitForExistence(timeout: 5))

        // Back to the Transactions tab (pushed via `NavigationLink` from there) to confirm
        // the retag is visible in the list.
        app.navigationBars.buttons["Transactions"].tap()
        XCTAssertTrue(element(app, "transactions.list").waitForExistence(timeout: 5))

        // Exactly one "Excluded from limit" caption should now be showing — the
        // non-overridden $25 Uber transaction got retagged to fixed; the manually
        // overridden $40 one was left untouched (still variable, still shows a time
        // instead of the muted caption).
        let excludedCaptions = app.staticTexts.matching(NSPredicate(format: "label == %@", "Excluded from limit"))
        XCTAssertEqual(excludedCaptions.count, 1, "Only the non-manually-overridden Uber transaction should have been retagged to fixed")
    }
}
