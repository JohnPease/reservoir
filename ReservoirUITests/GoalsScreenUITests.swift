import XCTest

/// Covers the Goals tab (reservoir-adq.5) per STANDARDS.md §5: list rendering (active +
/// completed-undismissed sections), goal creation (including backdating and validation
/// error paths), the per-card Pace/Simulation segmented-control toggle, and the
/// edit/delete confirm-and-save flows. Each test launches the app with `UITEST_SCENARIO`
/// set so it starts from a deterministic in-memory fixture — see `UITestScenario`.
final class GoalsScreenUITests: XCTestCase {

    private func launchedApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launch()
        app.tabBars.buttons["Goals"].tap()
        return app
    }

    /// Computes the `(monthOffset, day)` pair `selectDate` needs to land on
    /// `dayOffset` calendar days from "today" (the live device clock, matching what
    /// `selectDate`'s own `.now`-based month/day lookup uses) — e.g. `dayOffset: 1` for
    /// "tomorrow". Handles month (and year) rollover so callers don't have to hardcode a
    /// day-of-month tied to whatever day the suite happened to run on (reservoir-4w8).
    private func calendarOffset(forDaysFromToday dayOffset: Int) -> (monthOffset: Int, day: Int) {
        let calendar = Calendar.current
        let today = Date()
        let target = calendar.date(byAdding: .day, value: dayOffset, to: today)!

        let todayMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let targetMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: target))!
        let monthOffset = calendar.dateComponents([.month], from: todayMonthStart, to: targetMonthStart).month ?? 0
        let day = calendar.component(.day, from: target)

        return (monthOffset, day)
    }

    /// Taps a `DatePicker`'s compact button to open its calendar popover, navigates
    /// `monthOffset` calendar months from the current month (negative = back, positive =
    /// forward), and taps the day cell matching `day` in that displayed month. Matches
    /// the standard SwiftUI DatePicker calendar overlay's accessibility surface:
    /// `DatePicker.PreviousMonth` / `DatePicker.NextMonth` navigation buttons and day
    /// cells labeled e.g. "Wednesday, June 24".
    private func selectDate(in app: XCUIApplication, datePickerIdentifier: String, monthOffset: Int, day: Int) {
        let picker = app.datePickers[datePickerIdentifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        if monthOffset > 0 {
            for _ in 0..<monthOffset {
                app.buttons["DatePicker.NextMonth"].tap()
            }
        } else if monthOffset < 0 {
            for _ in 0..<(-monthOffset) {
                app.buttons["DatePicker.PreviousMonth"].tap()
            }
        }

        let calendar = Calendar.current
        let targetMonth = calendar.date(byAdding: .month, value: monthOffset, to: .now)!
        var components = calendar.dateComponents([.year, .month], from: targetMonth)
        components.day = day
        let targetDate = calendar.date(from: components)!

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        let label = formatter.string(from: targetDate)

        let dayButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
        XCTAssertTrue(dayButton.waitForExistence(timeout: 5), "Expected a day cell containing '\(label)'")
        dayButton.tap()

        // The calendar overlay doesn't auto-dismiss on day selection — it stays on
        // screen (as a full-bleed `PopoverDismissRegion`) and would intercept
        // subsequent taps intended for the form underneath if left open.
        let dismissRegion = app.buttons["PopoverDismissRegion"]
        if dismissRegion.waitForExistence(timeout: 2) {
            dismissRegion.tap()
        }
    }

    /// Clears a formatted currency `TextField`'s pre-filled value (e.g. "$0.00") before
    /// typing a new one — plain `typeText` on an already-populated formatted field
    /// appends rather than replaces, producing an unparseable value.
    private func setCurrencyField(_ field: XCUIElement, to value: String) {
        field.tap()
        if let currentValue = field.value as? String, !currentValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            field.typeText(deleteString)
        }
        field.typeText(value)
    }

    // MARK: - List rendering

    func testGoalListRendersActiveAndCompletedSections() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        XCTAssertTrue(app.staticTexts["Active goals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        XCTAssertTrue(app.otherElements["goals.card"].exists)
        XCTAssertTrue(app.otherElements["goals.completedCard"].exists)
    }

    func testEmptyGoalStateShowsCreatePromptOnGoalsTab() {
        let app = launchedApp(scenario: "emptyGoal")

        XCTAssertTrue(app.otherElements["goals.emptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["goals.card"].exists)
    }

    // MARK: - Create goal: happy path + backdating

    func testCreateGoalHappyPathWithBackdatedStartDate() {
        let app = launchedApp(scenario: "emptyGoal")

        XCTAssertTrue(app.buttons["goals.createGoal"].waitForExistence(timeout: 5))
        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["goalForm.targetAmount"], to: "1000")

        // Backdate the start date 14 days into the past (one calendar month back, day 24
        // relative to "today" = July 8 per the fixed clock this suite runs under).
        selectDate(in: app, datePickerIdentifier: "goalForm.startDate", monthOffset: -1, day: 24)

        XCTAssertFalse(app.staticTexts["goalForm.error.Start date"].exists)
        XCTAssertTrue(app.buttons["goalForm.submit"].isEnabled)

        app.buttons["goalForm.submit"].tap()

        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["goals.createGoalSheet"].exists)
    }

    // MARK: - Create goal: validation error paths

    func testCreateGoalTargetAmountBelowStartingBalanceShowsErrorAndDisablesSubmit() {
        let app = launchedApp(scenario: "emptyGoal")
        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        // targetAmount defaults to $0.00; typing a positive starting balance alone is
        // enough to make targetAmount <= startingBalance.
        setCurrencyField(app.textFields["goalForm.startingBalance"], to: "100")

        XCTAssertTrue(app.staticTexts["goalForm.error.Target amount"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["goalForm.submit"].isEnabled)
    }

    func testCreateGoalStartDateInFutureShowsError() {
        let app = launchedApp(scenario: "emptyGoal")
        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["goalForm.targetAmount"], to: "1000")

        // One day after "today" — computed relative to Date() at test-run time (not a
        // hardcoded day-of-month) so this doesn't flake as the wall clock advances
        // (reservoir-4w8: flaked when "today" moved from July 8 to July 9, then again to
        // July 10, because the picker's DatePicker overlay and the app's own validation
        // both use the live device clock, not an injected reference date).
        let (monthOffset, day) = calendarOffset(forDaysFromToday: 1)
        selectDate(in: app, datePickerIdentifier: "goalForm.startDate", monthOffset: monthOffset, day: day)

        let error = app.staticTexts["goalForm.error.Start date"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Start date can't be in the future")
        XCTAssertFalse(app.buttons["goalForm.submit"].isEnabled)
    }

    func testCreateGoalStartDateMoreThanNinetyDaysAgoShowsError() {
        let app = launchedApp(scenario: "emptyGoal")
        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["goalForm.targetAmount"], to: "1000")

        // Four calendar months back, day 1 — comfortably more than 90 days ago
        // regardless of exact month lengths.
        selectDate(in: app, datePickerIdentifier: "goalForm.startDate", monthOffset: -4, day: 1)

        let error = app.staticTexts["goalForm.error.Start date"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Start date can't be more than 90 days ago")
        XCTAssertFalse(app.buttons["goalForm.submit"].isEnabled)
    }

    // MARK: - Pace / Simulation segmented control toggle

    func testPaceSimulationSegmentedControlTogglesCardContent() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
        let paceContent = app.staticTexts.matching(identifier: "goals.card.paceContent").firstMatch
        XCTAssertTrue(paceContent.waitForExistence(timeout: 5))
        XCTAssertTrue(paceContent.label.contains("On pace"), "Expected the default Pace segment: got '\(paceContent.label)'")

        app.segmentedControls["goals.card.segmentedControl"].buttons["Simulation"].tap()

        // The "goals.card.paceContent" accessibility identifier is applied to a `Group`
        // wrapping the switch's content, which SwiftUI propagates onto each child
        // `StaticText` individually (there are two: the amount line and the completion
        // line) rather than onto a single container — so matching by identifier returns
        // more than one element.
        let simulationTexts = app.staticTexts.matching(identifier: "goals.card.paceContent")
        let amountText = simulationTexts.element(matching: NSPredicate(format: "label CONTAINS[c] %@", "Simulation:"))
        XCTAssertTrue(amountText.waitForExistence(timeout: 5), "Expected Simulation segment copy to replace Pace copy")
    }

    // MARK: - Edit goal

    func testEditGoalConfirmationAndSaveUpdatesCard() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        XCTAssertTrue(app.buttons["goals.card.edit"].waitForExistence(timeout: 5))
        app.buttons["goals.card.edit"].tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))

        let targetAmountField = app.textFields["goalForm.targetAmount"]
        XCTAssertTrue(targetAmountField.waitForExistence(timeout: 5))
        setCurrencyField(targetAmountField, to: "2500")

        app.buttons["goalForm.submit"].tap()

        XCTAssertTrue(app.staticTexts["Changing your target will reset today's carry-forward balance. Any amount you're ahead or behind will not carry over. Continue?"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["goals.editGoalSheet"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "$2,500")).firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Delete goal

    func testDeleteGoalConfirmationAndSaveRemovesCard() {
        let app = launchedApp(scenario: "goalsScreenMixed")

        XCTAssertTrue(app.buttons["goals.card.delete"].waitForExistence(timeout: 5))
        app.buttons["goals.card.delete"].tap()

        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()

        XCTAssertFalse(app.otherElements["goals.card"].waitForExistence(timeout: 3))
        // The completed-undismissed goal from the mixed fixture should still be present —
        // deleting the active goal doesn't touch it.
        XCTAssertTrue(app.otherElements["goals.completedCard"].exists)
    }
}
