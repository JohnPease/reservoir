import XCTest

/// Covers the monthly budget flows (reservoir-j8t PR2): empty-state entry points on
/// Today and Plans, the create flow through the account picker, the Today budget hero
/// above/without a savings goal, and delete. Math is covered by unit tests.
final class BudgetUITests: XCTestCase {

    private func launchedApp(scenario: String, seedAccount: Bool = false, seedSecondAccount: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        if seedAccount { app.launchEnvironment["UITEST_SEED_LINKED_ACCOUNT"] = "1" }
        if seedSecondAccount { app.launchEnvironment["UITEST_SEED_SECOND_LINKED_ACCOUNT"] = "1" }
        app.launch()
        return app
    }

    private func setCurrencyField(_ field: XCUIElement, to value: String) {
        field.tap()
        if let currentValue = field.value as? String, !currentValue.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        field.typeText(value)
    }

    func testTabIsRenamedToPlansAndShowsSetBudgetRowWhenNoBudget() {
        let app = launchedApp(scenario: "emptyGoal")
        XCTAssertFalse(app.tabBars.buttons["Goals"].exists)
        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(app.buttons["budget.setRow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Monthly budget"].exists)
        XCTAssertTrue(app.staticTexts["Savings goals"].exists)
        XCTAssertTrue(app.otherElements["goals.emptyState"].exists)
    }

    func testTodayEmptyStateOffersBudgetLinkThatOpensForm() {
        let app = launchedApp(scenario: "emptyGoal")
        XCTAssertTrue(app.otherElements["today.emptyGoalState"].waitForExistence(timeout: 5))
        let link = app.buttons["today.setBudgetLink"]
        XCTAssertTrue(link.exists)
        link.tap()
        XCTAssertTrue(app.otherElements["today.createBudgetSheet"].waitForExistence(timeout: 5))
    }

    func testCreateBudgetFlowAppearsOnPlansAndToday() {
        let app = launchedApp(scenario: "emptyGoal", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        app.buttons["budget.setRow"].tap()
        XCTAssertTrue(app.otherElements["budget.createBudgetSheet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["budget.form.submit"].isEnabled)

        setCurrencyField(app.textFields["budget.form.monthlyAmount"], to: "3000")
        let toggle = app.switches["budget.form.account.uitest-account"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // Same trailing-edge tap workaround `GoalAccountAssociationUITests.tapToggle` documents
        // for two-line Toggle labels in a Form row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")

        XCTAssertTrue(app.buttons["budget.form.submit"].isEnabled)
        app.buttons["budget.form.submit"].tap()

        XCTAssertTrue(app.otherElements["budget.card"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.otherElements["today.budgetHero"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["today.emptyGoalState"].exists, "a budget alone needs no goal prompt")
    }

    func testSeededBudgetShowsHeroWithoutGoalPromptAndSavingsStaysHidden() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        XCTAssertTrue(app.otherElements["today.budgetHero"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["today.budgetHero.amount"].exists)
        XCTAssertTrue(app.otherElements["today.budgetHero.stats"].exists)
        XCTAssertFalse(app.otherElements["today.emptyGoalState"].exists)
        XCTAssertFalse(app.otherElements["today.hero"].exists)
        XCTAssertFalse(app.buttons["today.setBudgetLink"].exists)
    }

    func testEditShowsRecalculationFooterAndDeleteRemovesBudget() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(app.otherElements["budget.card"].waitForExistence(timeout: 5))

        app.buttons["budget.card.edit"].tap()
        XCTAssertTrue(app.otherElements["budget.editBudgetSheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["budget.form.editFooter"].exists)
        app.buttons["Cancel"].tap()

        app.buttons["budget.card.delete"].tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["budget.setRow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["budget.card"].exists)
    }

    // MARK: - Insights (PR3)

    private func assertSentence(_ app: XCUIApplication, spent: String, file: StaticString = #filePath, line: UInt = #line) {
        let sentence = app.descendants(matching: .any)["budget.progressSentence"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(sentence.label.hasPrefix("Day "), sentence.label, file: file, line: line)
        XCTAssertTrue(sentence.label.contains("You've spent \(spent)"), sentence.label, file: file, line: line)
    }

    func testTodayBudgetHeroShowsProgressSentenceOnly() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        XCTAssertTrue(app.otherElements["today.budgetHero"].waitForExistence(timeout: 5))
        assertSentence(app, spent: "$20")
        XCTAssertFalse(app.staticTexts["budget.projection"].exists)
        XCTAssertFalse(app.otherElements["budget.breakdown"].exists)
    }

    func testPlansCardShowsSentenceAndHidesBreakdownForSingleAccount() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(app.otherElements["budget.card"].waitForExistence(timeout: 5))
        assertSentence(app, spent: "$20")
        XCTAssertFalse(app.otherElements["budget.breakdown"].exists)
    }

    func testPlansCardShowsSentenceAndBreakdownForTwoAccounts() {
        let app = launchedApp(scenario: "budgetTwoAccounts", seedAccount: true, seedSecondAccount: true)
        app.tabBars.buttons["Plans"].tap()
        XCTAssertTrue(app.otherElements["budget.card"].waitForExistence(timeout: 5))
        assertSentence(app, spent: "$65")
        XCTAssertTrue(app.otherElements["budget.breakdown"].exists)
        let card = app.descendants(matching: .any)["budget.breakdown.row.uitest-account-2"]
        XCTAssertTrue(card.exists)
        XCTAssertTrue(card.label.contains("Card ••1111"), card.label)
        XCTAssertTrue(app.descendants(matching: .any)["budget.breakdown.row.uitest-account"].exists)
    }

    // MARK: - Past months (reservoir-62p)

    private func monthID(monthsAgo: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .month, value: -monthsAgo, to: .now)!
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    private func openPastMonths(_ app: XCUIApplication) {
        let row = app.buttons["budget.pastMonths.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.otherElements["budget.pastMonths.sheet"].waitForExistence(timeout: 5))
    }

    func testPastMonthsRowIsTappableAcrossItsWidth() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        let row = app.buttons["budget.pastMonths.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.otherElements["budget.pastMonths.sheet"].waitForExistence(timeout: 5), "tapping the middle of the row must open Past months")
    }

    func testPastMonthsShowsEmptyStateForBudgetStartedThisMonth() {
        let app = launchedApp(scenario: "budgetSeeded", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        openPastMonths(app)
        XCTAssertTrue(app.staticTexts["budget.pastMonths.empty"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["budget.pastMonths.empty"].label, "No completed months yet")
        app.buttons["budget.pastMonths.done"].tap()
        XCTAssertTrue(app.otherElements["budget.card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["budget.pastMonths.sheet"].exists)
    }

    func testPastMonthsListsCompletedMonthsNewestFirst() {
        let app = launchedApp(scenario: "budgetPastMonths", seedAccount: true)
        app.tabBars.buttons["Plans"].tap()
        openPastMonths(app)

        let last = app.descendants(matching: .any)["budget.pastMonths.row.\(monthID(monthsAgo: 1))"]
        let older = app.descendants(matching: .any)["budget.pastMonths.row.\(monthID(monthsAgo: 2))"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(older.exists)
        XCTAssertLessThan(last.frame.minY, older.frame.minY, "newest month first")
        XCTAssertFalse(app.descendants(matching: .any)["budget.pastMonths.row.\(monthID(monthsAgo: 0))"].exists, "current month is not reviewed")
        XCTAssertFalse(app.staticTexts["budget.pastMonths.empty"].exists)

        let lastDelta = app.staticTexts["budget.pastMonths.delta.\(monthID(monthsAgo: 1))"]
        XCTAssertTrue(lastDelta.exists)
        XCTAssertTrue(lastDelta.label.hasSuffix("under"), lastDelta.label)
        XCTAssertEqual(app.staticTexts["budget.pastMonths.daysOver.\(monthID(monthsAgo: 1))"].label, "0 days over")
        XCTAssertTrue(app.staticTexts["budget.pastMonths.carry.\(monthID(monthsAgo: 1))"].label.hasPrefix("Ended with"))
    }
}
