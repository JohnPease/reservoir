import XCTest

/// Covers the Transactions tab (reservoir-adq.3) per STANDARDS.md §5: day-grouped list
/// rendering + empty state, the All/Variable/Fixed filter, add-transaction end to end from
/// both entry points (the tab's own "+" and Today's "Add transaction"), edit (including
/// goal reassignment), delete-with-confirmation, and a validation-failure path showing the
/// inline field-level error. Each test launches the app with `UITEST_SCENARIO` set so it
/// starts from a deterministic in-memory fixture — see `UITestScenario`.
final class TransactionsScreenUITests: XCTestCase {

    private func launchedApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        return app
    }

    private func launchedOnTransactionsTab(scenario: String) -> XCUIApplication {
        let app = launchedApp(scenario: scenario)
        app.tabBars.buttons["Transactions"].tap()
        return app
    }

    /// Clears a formatted currency `TextField`'s pre-filled value before typing a new one
    /// — matches `GoalsScreenUITests`' helper of the same shape.
    private func setCurrencyField(_ field: XCUIElement, to value: String) {
        field.tap()
        if let currentValue = field.value as? String, !currentValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            field.typeText(deleteString)
        }
        field.typeText(value)
    }

    /// Looks up an accessibility identifier regardless of the underlying XCUIElement type.
    /// `TransactionsView`/`MerchantRulesView` apply their `.list`/`.emptyState` identifiers
    /// to a SwiftUI `List`/`ContentUnavailableView`, which XCUITest surfaces as a
    /// `CollectionView`/other non-`.other` element type — unlike the plain `VStack`-backed
    /// containers (`today.hero`, `goals.card`, etc.) elsewhere in this app that `otherElements`
    /// happens to match. Matching `.any` sidesteps needing to know the concrete type.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - List rendering / empty state

    func testEmptyStateShowsMessageNotBlankList() {
        let app = launchedOnTransactionsTab(scenario: "transactionsZeroGoals")

        XCTAssertTrue(element(app, "transactions.emptyState").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "transactions.list").exists)
    }

    func testTransactionsListRendersRowsWithTypeAttributionAndFixedMuting() {
        let app = launchedOnTransactionsTab(scenario: "transactionsList")

        XCTAssertTrue(element(app, "transactions.list").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Coffee Shop"].exists)
        XCTAssertTrue(app.staticTexts["Rent"].exists)
        XCTAssertTrue(app.staticTexts["Grocery Store"].exists)
        XCTAssertTrue(app.staticTexts["Excluded from limit"].exists, "Fixed transaction should show the muted 'Excluded from limit' caption")
        XCTAssertTrue(app.staticTexts["Unattributed"].exists, "The unattributed Rent transaction should show 'Unattributed'")
        // Day grouping: "Today" and "Yesterday" section headers.
        XCTAssertTrue(app.staticTexts["Today"].exists)
        XCTAssertTrue(app.staticTexts["Yesterday"].exists)
    }

    // MARK: - Filter control

    func testFilterControlShowsOnlyMatchingType() {
        let app = launchedOnTransactionsTab(scenario: "transactionsList")

        XCTAssertTrue(element(app, "transactions.list").waitForExistence(timeout: 5))
        let filter = app.segmentedControls["transactions.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))

        filter.buttons["Variable"].tap()
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Grocery Store"].exists)
        XCTAssertFalse(app.staticTexts["Rent"].exists)

        filter.buttons["Fixed"].tap()
        XCTAssertTrue(app.staticTexts["Rent"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Coffee Shop"].exists)
        XCTAssertFalse(app.staticTexts["Grocery Store"].exists)

        filter.buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rent"].exists)
        XCTAssertTrue(app.staticTexts["Grocery Store"].exists)
    }

    // MARK: - Add transaction: Transactions tab's own "+"

    func testAddTransactionFromTransactionsTabEndToEnd() {
        // Zero active goals: the goal picker should already be a confirmed "Unattributed"
        // no-op, so save is reachable with just amount/date/merchant filled in — the gap
        // this entry point specifically has to cover that Today's doesn't (Today hides its
        // "Add transaction" button entirely with zero goals).
        let app = launchedOnTransactionsTab(scenario: "transactionsZeroGoals")

        XCTAssertTrue(app.buttons["transactions.addTransaction"].waitForExistence(timeout: 5))
        app.buttons["transactions.addTransaction"].tap()
        XCTAssertTrue(app.otherElements["transactions.addTransactionSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["transactionEntry.amount"], to: "42")
        app.textFields["transactionEntry.merchantName"].tap()
        app.textFields["transactionEntry.merchantName"].typeText("Bookstore")

        XCTAssertTrue(app.buttons["transactionEntry.submit"].isEnabled, "Zero active goals should not block save on an unconfirmed goal picker")
        app.buttons["transactionEntry.submit"].tap()

        XCTAssertTrue(element(app, "transactions.list").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Bookstore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["transactions.addTransactionSheet"].exists)
    }

    // MARK: - Add transaction: Today's "Add transaction"

    func testAddTransactionFromTodayEndToEnd() {
        let app = launchedApp(scenario: "normal")

        XCTAssertTrue(app.buttons["today.addTransaction"].waitForExistence(timeout: 5))
        app.buttons["today.addTransaction"].tap()
        XCTAssertTrue(app.otherElements["today.addTransactionSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["transactionEntry.amount"], to: "8")
        app.textFields["transactionEntry.merchantName"].tap()
        app.textFields["transactionEntry.merchantName"].typeText("Corner Deli")

        // "normal" has exactly one active goal, so the goal picker auto-selects it —
        // save should already be enabled without touching the picker.
        XCTAssertTrue(app.buttons["transactionEntry.submit"].isEnabled)
        app.buttons["transactionEntry.submit"].tap()

        XCTAssertTrue(app.otherElements["today.recentTransactions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Corner Deli"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.addTransactionSheet"].exists)
    }

    // MARK: - Edit transaction (including goal reassignment)

    func testEditTransactionReassignsGoal() {
        let app = launchedOnTransactionsTab(scenario: "transactionsList")

        XCTAssertTrue(app.staticTexts["Grocery Store"].waitForExistence(timeout: 5))
        app.staticTexts["Grocery Store"].tap()
        XCTAssertTrue(app.otherElements["transactions.editTransactionSheet"].waitForExistence(timeout: 5))

        // "Grocery Store" starts attributed to the fixture's one active goal; reassign it
        // to Unattributed via the goal picker (a `Form`-style Picker pushes a selection
        // list on tap; choosing a row pops back automatically).
        app.buttons["transactionEntry.goalPicker"].tap()
        let unattributedOption = app.buttons["Unattributed"]
        XCTAssertTrue(unattributedOption.waitForExistence(timeout: 5))
        unattributedOption.tap()

        app.buttons["transactionEntry.submit"].tap()

        XCTAssertTrue(element(app, "transactions.list").waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["transactions.editTransactionSheet"].exists)
        // Both fixture rows without a goal ("Rent" and now "Grocery Store") should read
        // "Unattributed" — assert at least two such labels exist post-edit.
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "transactions.row.goalLabel").matching(NSPredicate(format: "label == %@", "Unattributed")).count, 2)
    }

    // MARK: - Delete transaction (with confirmation)

    func testDeleteTransactionRequiresConfirmation() {
        let app = launchedOnTransactionsTab(scenario: "transactionsList")

        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 5))
        app.staticTexts["Coffee Shop"].swipeLeft()

        let swipeDeleteButton = app.buttons["Delete"]
        XCTAssertTrue(swipeDeleteButton.waitForExistence(timeout: 5))
        swipeDeleteButton.tap()

        XCTAssertTrue(app.staticTexts["Delete this transaction? This can't be undone."].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()

        XCTAssertFalse(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 3))
        // Unrelated fixture rows should be untouched.
        XCTAssertTrue(app.staticTexts["Rent"].exists)
        XCTAssertTrue(app.staticTexts["Grocery Store"].exists)
    }

    // MARK: - Validation failure end to end

    func testValidationFailureShowsInlineErrorAndBlocksSave() {
        let app = launchedOnTransactionsTab(scenario: "transactionsZeroGoals")

        app.buttons["transactions.addTransaction"].tap()
        XCTAssertTrue(app.otherElements["transactions.addTransactionSheet"].waitForExistence(timeout: 5))

        // Amount defaults to $0.00 — leave it untouched and only fill the merchant name,
        // so the amount-must-be-positive rule is the sole failing field.
        app.textFields["transactionEntry.merchantName"].tap()
        app.textFields["transactionEntry.merchantName"].typeText("Test Merchant")

        let amountError = app.staticTexts["transactionEntry.error.Amount"]
        XCTAssertTrue(amountError.waitForExistence(timeout: 5))
        XCTAssertEqual(amountError.label, "Amount must be greater than zero.")
        XCTAssertFalse(app.buttons["transactionEntry.submit"].isEnabled)
    }
}
