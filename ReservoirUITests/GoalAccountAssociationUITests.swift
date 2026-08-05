import XCTest

/// Covers `GoalFormView`'s goal<->account association section (reservoir-loc.3): the
/// zero-linked-accounts empty state, create-mode's local staging (association only applied
/// once the goal is actually persisted, never earlier), and edit-mode's immediate
/// associate/dissociate — including the "steal" semantics (reassigning an already-associated
/// item moves it off its previous goal) and the "Currently linked to <goal>" indicator.
///
/// `GoalAccountAssociationService`'s own atomicity/at-most-one-goal invariant is unit tested
/// directly (`GoalAccountAssociationServiceTests.swift`); this suite instead covers the view
/// wiring — that toggling in the UI actually reaches the service at the right time (after
/// Create, not before; immediately in edit mode) and that the resulting state is what a user
/// would actually see.
///
/// Every test sets `UITEST_RESET_PLAID_LINKED_ITEMS=1` — see `PlaidRelinkUITests`' doc
/// comment for why `LinkedItemStore`'s real `UserDefaults`-backed state needs an explicit
/// reset between tests, unlike this app's always-fresh in-memory SwiftData store.
final class GoalAccountAssociationUITests: XCTestCase {
    private func launchedApp(scenario: String, configure: (XCUIApplication) -> Void = { _ in }) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        configure(app)
        app.launch()
        app.tabBars.buttons["Goals"].tap()
        return app
    }

    /// A plain `.tap()` on `goalForm.accountToggle.<itemID>` (a `Toggle` whose label is a
    /// two-line `VStack`, not a single-line label) is unreliable in this environment — a
    /// center-of-frame synthesized tap doesn't consistently register as flipping the
    /// switch (confirmed by direct diagnostic: reading `.value` immediately after `.tap()`,
    /// still within the same sheet, showed the un-flipped value). Tapping a coordinate
    /// nearer the switch's actual trailing-edge position is the reliable fix — a known
    /// XCUITest workaround for `Toggle`s with multi-line/custom labels in a `List`/`Form`
    /// row, where the row's overall accessibility frame's center doesn't coincide with the
    /// switch control itself.
    private func tapToggle(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Mirrors `GoalsScreenUITests.setCurrencyField` — clears a pre-filled formatted
    /// currency `TextField` before typing a new value.
    private func setCurrencyField(_ field: XCUIElement, to value: String) {
        field.tap()
        if let currentValue = field.value as? String, !currentValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            field.typeText(deleteString)
        }
        field.typeText(value)
    }

    // MARK: - Empty state (zero linked accounts)

    func testZeroLinkedAccounts_showsHintText_inCreateMode() {
        let app = launchedApp(scenario: "emptyGoal")

        XCTAssertTrue(app.buttons["goals.createGoal"].waitForExistence(timeout: 5))
        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.staticTexts["Link an account in Settings to associate it with this goal"].waitForExistence(timeout: 5),
            "with zero linked accounts, the section must show the hint text, not a ContentUnavailableView (JP, 2026-08-01: section stays visible so a user learns the feature exists)."
        )
        // No toggle rows should exist since there's nothing to associate.
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "goalForm.accountToggle.")).firstMatch.exists)
    }

    // MARK: - Create mode: staged association applied only after Create

    /// Toggling an account on during creation must not associate anything until the goal is
    /// actually persisted (JP's explicit bug-risk call-out: a bug here would silently
    /// associate against a not-yet-real goal). This is proved end to end: toggle on, tap
    /// Create, then reopen the resulting goal's edit form and confirm the association
    /// actually landed — which could only be true if `createGoal()`'s post-persist
    /// `associate` loop ran, not some earlier/different code path.
    func testCreateMode_toggledAssociation_isAppliedAfterCreate() {
        let app = launchedApp(scenario: "emptyGoal") { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))

        setCurrencyField(app.textFields["goalForm.targetAmount"], to: "1000")

        let toggle = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "sanity check: toggle starts off.")
        tapToggle(toggle)
        XCTAssertEqual(toggle.value as? String, "1", "sanity check: toggle reads on immediately after tapping, still within the create sheet — proves the tap itself registered.")

        XCTAssertTrue(app.buttons["goalForm.submit"].isEnabled)
        app.buttons["goalForm.submit"].tap()

        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["goals.createGoalSheet"].exists)

        // Reopen the newly created goal's edit form — the toggle must already be ON,
        // proving the staged selection was actually applied via
        // GoalAccountAssociationService.associate after persistence.
        app.buttons["goals.card.edit"].tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))
        let editToggle = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(editToggle.value as? String, "1", "the staged association from create mode must have been applied to the persisted goal.")
    }

    /// A staged toggle left untouched (never turned on) must not associate anything —
    /// baseline sanity check alongside the positive case above.
    func testCreateMode_untouchedToggle_leavesGoalUnassociated() {
        let app = launchedApp(scenario: "emptyGoal") { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        app.buttons["goals.createGoal"].tap()
        XCTAssertTrue(app.otherElements["goals.createGoalSheet"].waitForExistence(timeout: 5))
        setCurrencyField(app.textFields["goalForm.targetAmount"], to: "1000")

        XCTAssertTrue(app.switches["goalForm.accountToggle.uitest-item"].waitForExistence(timeout: 5))
        app.buttons["goalForm.submit"].tap()

        XCTAssertTrue(app.otherElements["goals.card"].waitForExistence(timeout: 5))
        app.buttons["goals.card.edit"].tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))
        let editToggle = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(editToggle.value as? String, "0", "a toggle never turned on during creation must leave the goal unassociated.")
    }

    // MARK: - Edit mode: immediate associate/dissociate, "steal" semantics

    /// Uses the `goalAccountAssociation` fixture: Goal A (targetAmount $1,000, sorts
    /// first) starts associated with "uitest-item"; Goal B (targetAmount $2,000, sorts
    /// second) starts unassociated. Edit-mode toggling calls the association service
    /// immediately (no Save/confirmation needed) — reassigning the item to Goal B must
    /// move it off Goal A ("steal" semantics, not an error), and each goal's edit form
    /// must show "Currently linked to <the other goal>" correctly before/after the move.
    func testEditMode_reassigningItem_movesItOffPreviousGoal_updatesCurrentlyLinkedIndicator() {
        let app = launchedApp(scenario: "goalAccountAssociation") { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        let editButtons = app.buttons.matching(identifier: "goals.card.edit")
        XCTAssertTrue(editButtons.element(boundBy: 1).waitForExistence(timeout: 5), "expected two active goal cards (Goal A, Goal B) from the goalAccountAssociation fixture.")

        // Open Goal B (the second card, sorted by later targetDate) — it should show the
        // item as currently linked to Goal A ($1,000 by <date>), not itself.
        editButtons.element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))
        let currentlyLinkedToGoalA = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Currently linked to $1,000")
        ).firstMatch
        XCTAssertTrue(currentlyLinkedToGoalA.waitForExistence(timeout: 5), "Goal B's edit form must show the item as currently linked to Goal A before reassignment.")

        let toggle = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "sanity check: Goal B must not start associated with the item.")
        tapToggle(toggle)
        XCTAssertEqual(toggle.value as? String, "1", "sanity check: the tap itself registered before dismissing.")

        // Edit-mode association is applied immediately on tap (no Save/confirmation
        // needed) — dismiss via Cancel, which must not undo the association.
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.otherElements["goals.editGoalSheet"].exists)

        // Reopen Goal A (the first card) — the item must now be off Goal A, and Goal A's
        // form must show it as currently linked to Goal B instead.
        XCTAssertTrue(editButtons.element(boundBy: 0).waitForExistence(timeout: 5))
        editButtons.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))

        let goalAToggle = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(goalAToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(goalAToggle.value as? String, "0", "the item must have been removed from Goal A once reassigned to Goal B — the 'steal', not a duplicate association.")

        let currentlyLinkedToGoalB = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Currently linked to $2,000")
        ).firstMatch
        XCTAssertTrue(currentlyLinkedToGoalB.waitForExistence(timeout: 5), "Goal A's edit form must now show the item as currently linked to Goal B, reflecting the reassignment.")
        app.buttons["Cancel"].tap()

        // Finally, reopen Goal B and confirm the toggle is ON with no "currently linked to
        // <other goal>" label for itself (an item can't be "linked to" the very goal whose
        // form is showing it).
        XCTAssertTrue(editButtons.element(boundBy: 1).waitForExistence(timeout: 5))
        editButtons.element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["goals.editGoalSheet"].waitForExistence(timeout: 5))
        let goalBToggleAfter = app.switches["goalForm.accountToggle.uitest-item"]
        XCTAssertTrue(goalBToggleAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(goalBToggleAfter.value as? String, "1", "Goal B must now hold the association.")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Currently linked to")).firstMatch.exists,
            "a goal's own form must never show 'Currently linked to' for an item associated with itself."
        )
    }
}
