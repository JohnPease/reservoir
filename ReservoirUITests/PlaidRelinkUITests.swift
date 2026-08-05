import XCTest

/// Functional coverage for `SettingsView`'s multi-item linked-accounts UI (reservoir-loc.3)
/// and the connection-status affordances that predate it (reservoir-adq.6.5/adq.7): the
/// Settings tab-bar badge, per-row Relink/Unlink, and the persistent "Link another account"
/// affordance.
///
/// **Rewritten for reservoir-loc.3** — the original version of this suite predated the
/// multi-item redesign and hardcoded single-item assumptions no longer true of the current
/// UI: a label-switching `settings.linkButton` ("Link a bank account" vs. "Relink" depending
/// on whether one item existed) and static single `settings.unlinkButton`/
/// `settings.needsAttention` identifiers. `SettingsView` now renders an unbounded `ForEach`
/// over `service.linkedItems`, each row with its own `settings.relinkButton.<itemID>` /
/// `settings.unlinkButton.<itemID>` / `settings.needsAttention.<itemID>` identifiers, and
/// "Link another account" (`settings.linkButton`) is a single, persistent, non-label-
/// switching affordance regardless of how many items are already linked — see
/// `SettingsView.body`'s doc comments for the full rationale. This suite is rewritten
/// against that real shape rather than patched to keep compiling against the old one.
///
/// Every test below sets `UITEST_RESET_PLAID_LINKED_ITEMS=1` alongside whatever it
/// explicitly seeds — `LinkedItemStore` is backed by real `UserDefaults.standard`, which
/// (unlike this app's always-fresh in-memory SwiftData store under `UITEST_SCENARIO`)
/// survives across launches within a single XCUITest run, so a test that doesn't reset
/// could otherwise inherit another test's leftover seeded item(s). See
/// `UITestScenario.resetPlaidLinkedItemsIfRequested()`.
///
/// Per this story's resolved test-scope decision, the full "reconnect clears
/// needsAttention + resumes import" round trip against Plaid Sandbox is **manual
/// verification only** (see this suite's bottom doc comment) — this area already has two
/// flakiness beads (reservoir-bdy, reservoir-tq7), and a live Sandbox
/// `/sandbox/item/reset_login` call is explicitly reserved for JP's own pre-merge check,
/// never automated here.
///
/// The exact update-mode request shape (`access_token` present, `products` omitted) and the
/// multi-item `startRelink`/`retry`/`unlink` bookkeeping (which item's flag gets cleared,
/// which item's token goes out over the network) are unit tested directly against
/// `PlaidServiceLive` (`PlaidServiceLiveTests.swift`) rather than asserted here — inspecting
/// a network request's body, or a specific item's in-memory state, from a separate XCUITest
/// process isn't possible. This suite instead covers the UI wiring itself: which row's
/// button reaches which item, and that the tab-bar badge/per-row state reflect the real
/// underlying multi-item data rather than a stale single-item assumption.
final class PlaidRelinkUITests: XCTestCase {
    private func launchedApp(_ configure: (XCUIApplication) -> Void = { _ in }) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_RESET_PLAID_LINKED_ITEMS"] = "1"
        configure(app)
        app.launch()
        return app
    }

    // MARK: - Settings tab-bar connection-status badge

    /// **Not asserted via XCUITest** (deliberately, after investigation): `RootTabView`'s
    /// native `TabView` `.badge(_:)` does not reliably expose its string through
    /// `XCUIElement.value`/`debugDescription` on this Xcode/iOS 26.5 simulator combo — a
    /// diagnostic probe (10 one-second samples of `app.tabBars.buttons["Settings"].value`
    /// and the full tab-bar `debugDescription`, against a seeded needs-attention item)
    /// consistently returned an empty string the entire time, never `"!"`, even though the
    /// underlying `TransactionImportService.needsAttention` state is correct from the first
    /// frame (confirmed independently via a temporary in-app accessibility probe, and
    /// visually via a manual simulator screenshot showing the badge rendering exactly as
    /// designed). That combination — data correct immediately, visual rendering correct,
    /// XCUITest's introspection never once seeing anything but empty — points at a
    /// platform/tooling gap in exposing native SwiftUI tab badges to the accessibility
    /// tree here, not a timing race or an app bug. Asserting on `.value` would have made
    /// this suite's negative cases ("badge absent") pass for the wrong reason too — "can't
    /// observe the badge" and "badge genuinely absent" are indistinguishable through this
    /// API on this environment.
    ///
    /// The native badge itself is still worth checking, just manually — see this file's
    /// bottom doc comment — and re-enabling an automated check here is worth revisiting if
    /// a newer Xcode/simulator fixes the introspection gap.
    ///
    /// The actual acceptance criterion this badge encodes — `needsAttention` is an OR
    /// across every linked item, not a first-item-only read — is unit tested directly and
    /// reliably against `TransactionImportService` (the badge's real data source):
    /// `testNeedsAttention_multipleItems_isOrAcrossAllItems_notFirstItemOnly` in
    /// `TransactionImportServiceTests.swift`. What this suite covers instead, at the UI
    /// layer, is the one thing XCUITest *can* reliably see here: that a seeded
    /// needs-attention item's own row renders its indicator once the user is on the
    /// Settings screen (`testSettingsTabBadge_appearsWhenNeedsAttention` below) — the tab
    /// bar's own aggregate badge is manually verified per this file's bottom doc comment.
    func testSettingsTabBadge_appearsWhenNeedsAttention() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_NEEDS_ATTENTION"] = "1"
        }

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.needsAttention.uitest-item"].exists, "a needs-attention item seeded before launch must show its row indicator without requiring a live import first.")
    }

    func testSettingsTabBadge_absentWhenNothingNeedsAttention() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["settings.needsAttention.uitest-item"].exists, "must not show a needs-attention indicator when nothing needs attention.")
    }

    /// UI-layer complement to `testNeedsAttention_multipleItems_isOrAcrossAllItems_notFirstItemOnly`
    /// (`TransactionImportServiceTests.swift`, the reliable coverage for the actual OR
    /// logic — see this file's doc comment above): with two linked items and only the
    /// second needing attention, each row must reflect its *own* item's state — item-1's
    /// row must stay clean, item-2's row must show the indicator. Proves the per-row wiring
    /// in the real UI, not just the underlying service property.
    func testSettingsRows_withTwoItems_onlyTheAffectedItemsRowShowsIndicator() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_NEEDS_ATTENTION"] = "1"
            // item-1 deliberately healthy — proves this is per-item, not "some item needs
            // attention so show it everywhere."
        }

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item-2"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.staticTexts["settings.needsAttention.uitest-item"].exists, "item-1 is healthy — its row must not show the indicator just because item-2 needs attention.")
        XCTAssertTrue(app.staticTexts["settings.needsAttention.uitest-item-2"].exists, "item-2's row must show the indicator.")
    }

    // MARK: - Multi-item "Linked accounts" section rendering

    func testLinkedAccountsSection_rendersOneRowPerLinkedItem_eachWithOwnRelinkAndUnlink() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_ITEM"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item"].exists)
        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item-2"].exists)
        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item-2"].exists)

        // The "Link another account" affordance is persistent — present regardless of how
        // many items are already linked, not hidden or relabeled once an item exists.
        XCTAssertTrue(app.buttons["settings.linkButton"].exists)
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Link another account")
    }

    func testEmptyState_showsNoAccountLinkedYet_withLinkAnotherAccountAffordance() {
        let app = launchedApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["No account linked yet."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.linkButton"].exists)
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Link another account")
    }

    // MARK: - Tapping a specific row's "Relink" calls the update-mode entry point for that item

    func testTappingRelink_onASpecificRow_reachesUpdateModeEntryPoint_surfacesClassifiedErrorOnFailure() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        // Relink the second row specifically — proves the tap reaches *that* item's flow,
        // not just "some" relink.
        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item-2"].waitForExistence(timeout: 5))
        app.buttons["settings.relinkButton.uitest-item-2"].tap()

        // UITEST_FORCE_PLAID_ERROR makes startRelink()'s update-mode token-creation call
        // fail deterministically (same forced-failure stub as PlaidDebugLinkUITests' original
        // Link-flow test), proving the button reaches a real network call through
        // startRelink() rather than being a dead/no-op tap.
        let errorMessage = app.staticTexts["settings.errorMessage"]
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 15))
        XCTAssertEqual(errorMessage.label, "Couldn't connect to your bank. Try again.")
    }

    // MARK: - SettingsView's per-item needsAttention text tracks a live import failure

    /// Code-review regression test: `SettingsView`'s per-row "Needs attention" text must
    /// read the item's own `needsAttention` (sourced from `LinkedItemStore`, the single
    /// owner both `PlaidServiceLive` and `TransactionImportService` write through), not a
    /// stale in-memory copy. Starts with `needsAttention` explicitly unset, drives a real
    /// import through the scripted `ITEM_LOGIN_REQUIRED` protocol, then confirms Settings —
    /// not just the tab-bar badge — reflects it for the correct item.
    func testSettingsNeedsAttentionText_reflectsLiveImportFailure_notJustCachedLinkedItem() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = "itemLoginRequired"
            app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        }

        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.staticTexts["settings.needsAttention.uitest-item"].exists, "sanity check: must not already show needs-attention before any import has run.")

        // Drive a real import via the Transactions tab's debug refresh hook (same
        // mechanism TransactionImportUITests uses) so TransactionImportService itself
        // classifies ITEM_LOGIN_REQUIRED and writes needsAttention through the shared
        // LinkedItemStore — not a value seeded directly into PlaidServiceLive's own copy.
        app.tabBars.buttons["Transactions"].tap()
        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["settings.needsAttention.uitest-item"].waitForExistence(timeout: 10), "SettingsView must reflect a live import-time ITEM_LOGIN_REQUIRED classification for this item, not just its own separately-cached state.")
    }

    // MARK: - Unlink (per-item, reservoir-loc.3)

    /// Confirms the full unlink UI flow end to end for one item among two: tapping "Unlink"
    /// on a specific row requires confirmation, cancelling leaves both items intact, and
    /// confirming removes only the targeted item — the other linked item's row must survive
    /// completely untouched (reservoir-loc.3's explicit "unlink one of two items doesn't
    /// disturb the other" acceptance criterion, exercised here through the real UI rather
    /// than just the service layer).
    func testUnlink_requiresConfirmation_cancelLeavesBothItemsIntact() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item"].waitForExistence(timeout: 5))
        app.buttons["settings.unlinkButton.uitest-item"].tap()

        // `.firstMatch` (not the plain identifier subscript): the confirmation dialog's
        // action button is a pre-existing, environment-level quirk observed on this
        // Xcode/simulator combo — SwiftUI's `confirmationDialog` button occasionally
        // registers as two nested accessibility elements sharing one identifier (seen
        // identically on `RootTabView`'s unrelated merge-prompt dialog, which this story
        // never touches), so a plain `app.buttons["id"]` subscript can throw "multiple
        // matching elements." `.firstMatch` resolves to the same tappable button either way.
        let cancelButton = app.buttons.matching(identifier: "settings.cancelUnlink").firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10))
        cancelButton.tap()

        // Cancelling must leave both rows exactly as they were.
        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item"].exists)
        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item-2"].exists)
    }

    func testConfirmingUnlink_removesOnlyThatItem_leavesTheOtherItemIntact() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_SECOND_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item"].waitForExistence(timeout: 5))
        app.buttons["settings.unlinkButton.uitest-item"].tap()

        // See `.firstMatch` note above.
        let confirmButton = app.buttons.matching(identifier: "settings.confirmUnlink").firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10))
        confirmButton.tap()

        // "uitest-item" is gone…
        XCTAssertFalse(app.buttons["settings.unlinkButton.uitest-item"].waitForExistence(timeout: 5))
        // …but "uitest-item-2" is completely untouched, still fully interactive.
        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item-2"].exists)
        XCTAssertTrue(app.buttons["settings.relinkButton.uitest-item-2"].exists)
        // Not back to the empty state — one item still remains.
        XCTAssertFalse(app.staticTexts["No account linked yet."].exists)
    }

    func testConfirmingUnlink_ofLastRemainingItem_returnsToEmptyState() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.unlinkButton.uitest-item"].waitForExistence(timeout: 5))
        app.buttons["settings.unlinkButton.uitest-item"].tap()

        // See `.firstMatch` note above.
        let confirmButton = app.buttons.matching(identifier: "settings.confirmUnlink").firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10))
        confirmButton.tap()

        // Back to the empty state — no linked items at all, and the persistent
        // "Link another account" affordance remains (it never disappears/relabels).
        XCTAssertTrue(app.staticTexts["No account linked yet."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Link another account")
        XCTAssertFalse(app.buttons["settings.unlinkButton.uitest-item"].exists)
    }
}

// MARK: - Manual verification (not automated — see suite doc comment)
//
// Before merging, JP should verify the full reconnect round trip against Plaid Sandbox:
//   1. Launch the app (Debug, Xcode), go to the Settings tab (SettingsView).
//   2. Tap "Link another account", complete a real Sandbox Link session
//      (institution search -> user_good/pass_good), confirm the new row appears.
//   3. Repeat once more so two real linked items are present — confirm both rows render
//      independently (institution name, item ID, own Relink/Unlink).
//   4. In the Plaid dashboard (or via curl), call Sandbox's
//      `/sandbox/item/reset_login` for one linked item's item_id to force it into
//      ITEM_LOGIN_REQUIRED.
//   5. Trigger an import (foreground the app or pull-to-refresh on the Transactions tab)
//      — confirm the import error banner and/or that specific row's "Needs attention" text
//      in SettingsView appears, the *other* row stays clean, and the Settings tab-bar item
//      shows its badge.
//   6. Tap "Relink" on the affected row — confirm Plaid Link opens in update mode (same
//      institution, no account-selection/consent screens repeated unnecessarily) and
//      completes successfully with user_good/pass_good.
//   7. Confirm "Needs attention" disappears for that row (both surfaces) immediately after
//      the relink completes, without needing to background/foreground the app, and the
//      other item's row/state is unaffected throughout.
//   8. Trigger another import — confirm it resumes normally for both items (no duplicate
//      transactions, cursors pick up where each left off).
//   9. Tap "Unlink" on one row, confirm the dialog, verify only that row disappears (the
//      other remains), and confirm previously imported transactions for the unlinked item
//      are still visible on the Transactions tab (the automated unit test
//      `test_unlink_doesNotDeleteOrModifySpendTransactions` covers this at the service
//      layer; this step confirms it end to end through the real UI/persisted store). Then
//      unlink the second item and confirm the app returns to "No account linked yet."
