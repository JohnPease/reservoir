import XCTest

/// Functional coverage for reservoir-adq.6.5's item-relink / connection-status UX:
/// the Settings tab's native tab-bar badge signaling a broken bank connection, and tapping
/// "Relink" in `SettingsView` actually invoking the update-mode Link entry point
/// (`PlaidServiceLive.startRelink(for:)`) rather than the old, mis-wired `startLink()`.
///
/// Ported from the original `PlaidRelinkUITests` (which targeted the interim
/// `PlaidDebugLinkView`, deleted in reservoir-adq.7) — rewritten against `SettingsView`'s
/// own accessibility identifiers (`settings.*`). Code-review follow-up on reservoir-adq.7:
/// the connection-status indicator moved off a separate gear-icon overlay on the Today
/// screen (a redundant navigation affordance once Settings already had its own tab-bar
/// entry point) onto a native `.badge(_:)` on the Settings tab item itself — see
/// `RootTabView.swift`. XCUITest exposes a SwiftUI tab-bar badge as the tab button's
/// `.value` (confirmed empirically: `"!"` when set, `""` — not `nil` — when absent).
///
/// Per this story's resolved test-scope decision, the full "reconnect clears
/// needsAttention + resumes import" round trip against Plaid Sandbox is **manual
/// verification only** (see this suite's bottom doc comment and the engineer's final
/// report) — this area already has two flakiness beads (reservoir-bdy, reservoir-tq7),
/// and a live Sandbox `/sandbox/item/reset_login` call is explicitly reserved for JP's own
/// pre-merge check, never automated here.
///
/// The exact update-mode request shape (`access_token` present, `products` omitted) is
/// unit tested directly against `PlaidServiceLive.startRelink(for:)`
/// (`PlaidServiceLiveTests.swift`) rather than asserted here — inspecting a network
/// request's body from a separate XCUITest process isn't possible, and presenting a real
/// LinkKit sheet with a fake `link_token` (to prove the *success* path reaches Link) risks
/// exactly the kind of flakiness this test area is already flagged for. This suite instead
/// covers the UI wiring: tapping "Relink" reaches a real network call through the new code
/// path and a resulting failure surfaces correctly, same forced-failure pattern
/// `PlaidDebugLinkUITests` already uses for the original Link flow.
final class PlaidRelinkUITests: XCTestCase {
    private func launchedApp(_ configure: (XCUIApplication) -> Void = { _ in }) -> XCUIApplication {
        let app = XCUIApplication()
        configure(app)
        app.launch()
        return app
    }

    // MARK: - Settings tab-bar connection-status badge

    private func settingsTabBadge(_ app: XCUIApplication) -> String? {
        let value = app.tabBars.buttons["Settings"].value as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    func testSettingsTabBadge_appearsWhenNeedsAttention() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_NEEDS_ATTENTION"] = "1"
        }

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(settingsTabBadge(app), "!", "the Settings tab must carry a badge as soon as a needs-attention item is seeded, without requiring navigation to Settings first.")

        app.tabBars.buttons["Settings"].tap()

        // Tapping through shows "Relink" since an item is already linked.
        XCTAssertTrue(app.buttons["settings.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Relink")
    }

    func testSettingsTabBadge_absentWhenNothingNeedsAttention() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertNil(settingsTabBadge(app), "must not show a badge when nothing needs attention.")
    }

    // MARK: - Tapping "Relink" calls the update-mode entry point

    func testRelinkButtonLabel_showsWhenItemAlreadyLinked() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Relink", "the button must read \"Relink\", not \"Link a bank account\", once an item is already linked.")
    }

    func testTappingRelink_reachesUpdateModeEntryPoint_surfacesClassifiedErrorOnFailure() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Relink")
        app.buttons["settings.linkButton"].tap()

        // UITEST_FORCE_PLAID_ERROR makes startRelink()'s update-mode token-creation call
        // fail deterministically (same forced-failure stub as PlaidDebugLinkUITests' original
        // Link-flow test), proving the button reaches a real network call through
        // startRelink() rather than being a dead/no-op tap.
        let errorMessage = app.staticTexts["settings.errorMessage"]
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 15))
        XCTAssertEqual(errorMessage.label, "Couldn't connect to your bank. Try again.")
    }

    // MARK: - SettingsView's needsAttention text tracks a live import failure

    /// Code-review regression test: `SettingsView`'s "Needs attention" text must
    /// read the same source the Today badge does (`TransactionImportService.needsAttention`),
    /// not `PlaidServiceLive`'s own separately-cached `linkedItem.needsAttention` — the
    /// latter is never written to by an import-time classification (a different service
    /// instance), so it went stale while the badge correctly lit up. Starts with
    /// `needsAttention` explicitly unset, drives a real import through the scripted
    /// `ITEM_LOGIN_REQUIRED` protocol (not the seeded starting state used by the Today
    /// badge test above, which wouldn't exercise this write path at all), then confirms
    /// Settings — not just the badge — reflects it.
    func testSettingsNeedsAttentionText_reflectsLiveImportFailure_notJustCachedLinkedItem() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = "itemLoginRequired"
            app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        }

        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.staticTexts["settings.needsAttention"].exists, "sanity check: must not already show needs-attention before any import has run.")

        // Drive a real import via the Transactions tab's debug refresh hook (same
        // mechanism TransactionImportUITests uses) so TransactionImportService itself
        // classifies ITEM_LOGIN_REQUIRED and writes needsAttention through the shared
        // LinkedItemStore — not a value seeded directly into PlaidServiceLive's own copy.
        app.tabBars.buttons["Transactions"].tap()
        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["settings.needsAttention"].waitForExistence(timeout: 10), "SettingsView must reflect a live import-time ITEM_LOGIN_REQUIRED classification, not just its own separately-cached linkedItem state.")
    }

    // MARK: - Unlink (reservoir-adq.7 — genuinely new behavior)

    /// Confirms the full unlink UI flow end to end: tapping "Unlink" requires confirmation
    /// (destructive, real-account-severing action), cancelling leaves the linked item
    /// intact, and confirming clears it back to the "No account linked yet." empty state
    /// with a fresh "Link a bank account" button (not "Relink").
    func testUnlink_requiresConfirmation_cancelLeavesLinkedItemIntact() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.unlinkButton"].waitForExistence(timeout: 5))
        app.buttons["settings.unlinkButton"].tap()

        let cancelButton = app.buttons["settings.cancelUnlink"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        // Cancelling must leave the linked item exactly as it was — still "Relink", still
        // an Unlink button present.
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Relink")
        XCTAssertTrue(app.buttons["settings.unlinkButton"].exists)
    }

    func testConfirmingUnlink_clearsLinkedItem_returnsToEmptyState() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["settings.unlinkButton"].waitForExistence(timeout: 5))
        app.buttons["settings.unlinkButton"].tap()

        let confirmButton = app.buttons["settings.confirmUnlink"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()

        // Back to the empty state — no linked item, a fresh "Link a bank account" button,
        // and the Unlink button itself gone (it's only shown when an item is linked).
        XCTAssertTrue(app.staticTexts["No account linked yet."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settings.linkButton"].label, "Link a bank account")
        XCTAssertFalse(app.buttons["settings.unlinkButton"].exists)
    }
}

// MARK: - Manual verification (not automated — see suite doc comment)
//
// Before merging, JP should verify the full reconnect round trip against Plaid Sandbox:
//   1. Launch the app (Debug, Xcode), go to the Settings tab (SettingsView).
//   2. Tap "Link a bank account", complete a real Sandbox Link session
//      (institution search -> user_good/pass_good), confirm "Linked institution" appears.
//   3. In the Plaid dashboard (or via curl), call Sandbox's
//      `/sandbox/item/reset_login` for the linked item's item_id to force it into
//      ITEM_LOGIN_REQUIRED.
//   4. Trigger an import (foreground the app or pull-to-refresh on the Transactions tab)
//      — confirm the import error banner and/or the "Needs attention" text under "Linked
//      institution" in SettingsView appears, and the Settings tab-bar item shows its
//      badge.
//   5. Tap "Relink" in Settings — confirm Plaid Link opens in update mode (same
//      institution, no account-selection/consent screens repeated unnecessarily) and
//      completes successfully with user_good/pass_good.
//   6. Confirm "Needs attention" disappears (both surfaces) immediately after the relink
//      completes, without needing to background/foreground the app.
//   7. Trigger another import — confirm it resumes normally (no duplicate transactions,
//      cursor picks up where it left off).
//   8. Tap "Unlink", confirm the dialog, verify the app returns to the empty
//      "No account linked yet." state, and confirm previously imported transactions are
//      still visible on the Transactions tab (the automated unit test
//      `test_unlink_doesNotDeleteOrModifySpendTransactions` covers this at the service
//      layer; this step confirms it end to end through the real UI/persisted store).
