import XCTest

/// Functional coverage for reservoir-adq.6.5's item-relink / connection-status UX:
/// the Today-screen gear-icon badge and its navigation to the reconnect flow, and tapping
/// "Relink" in `PlaidDebugLinkView` actually invoking the update-mode Link entry point
/// (`PlaidServiceLive.startRelink(for:)`) rather than the old, mis-wired `startLink()`.
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

    // MARK: - Today-screen connection-status badge

    func testTodayBadgeAppearsWhenNeedsAttention_navigatesToReconnectFlow() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_NEEDS_ATTENTION"] = "1"
        }

        // Today is the default/launch tab — the badge must be visible without navigating
        // anywhere first (this story's UX section: "surface on Today ... since Settings is
        // not the launch screen").
        XCTAssertTrue(app.images["today.connectionBadge"].waitForExistence(timeout: 5))

        app.buttons["today.settings"].tap()

        // Tapping while flagged routes to the reconnect flow (PlaidDebugLinkView, this
        // story's interim Settings stand-in) via programmatic tab selection, not the
        // normal placeholder Settings sheet.
        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["plaidDebug.linkButton"].label, "Relink")
        XCTAssertFalse(app.otherElements["today.settingsSheet"].exists, "must not have shown the placeholder Settings sheet instead.")
    }

    func testTodayBadgeAbsentWhenNoAttentionNeeded_gearOpensPlaceholderSettingsSheet() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }

        XCTAssertFalse(app.images["today.connectionBadge"].waitForExistence(timeout: 3))

        app.buttons["today.settings"].tap()

        // Existing (pre-adq.6.5) behavior must be unaffected when nothing needs attention.
        // `StubSheet`'s accessibilityIdentifier is on its containing NavigationStack (an
        // "Other" element), not a StaticText.
        XCTAssertTrue(app.otherElements["today.settingsSheet"].waitForExistence(timeout: 5))
    }

    // MARK: - Tapping "Relink" calls the update-mode entry point

    func testRelinkButtonLabel_showsWhenItemAlreadyLinked() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["plaidDebug.linkButton"].label, "Relink", "the button must read \"Relink\", not \"Link a bank account\", once an item is already linked.")
    }

    func testTappingRelink_reachesUpdateModeEntryPoint_surfacesClassifiedErrorOnFailure() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        }
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["plaidDebug.linkButton"].label, "Relink")
        app.buttons["plaidDebug.linkButton"].tap()

        // UITEST_FORCE_PLAID_ERROR makes startRelink()'s update-mode token-creation call
        // fail deterministically (same forced-failure stub as PlaidDebugLinkUITests' original
        // Link-flow test), proving the button reaches a real network call through
        // startRelink() rather than being a dead/no-op tap — the old, mis-wired button
        // called startLink() instead, which this forced failure would surface identically,
        // but that old call site is gone entirely now (see PlaidDebugLinkView's Relink
        // button doc comment) and startRelink()'s own request-shape correctness is proven
        // separately by the unit tests above.
        let errorMessage = app.staticTexts["plaidDebug.errorMessage"]
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 15))
        XCTAssertEqual(errorMessage.label, "Couldn't connect to your bank. Try again.")
    }

    // MARK: - PlaidDebugLinkView's needsAttention text tracks a live import failure

    /// Code-review regression test: `PlaidDebugLinkView`'s "Needs attention" text must
    /// read the same source the Today badge does (`TransactionImportService.needsAttention`),
    /// not `PlaidServiceLive`'s own separately-cached `linkedItem.needsAttention` — the
    /// latter is never written to by an import-time classification (a different service
    /// instance), so it went stale while the badge correctly lit up. Starts with
    /// `needsAttention` explicitly unset, drives a real import through the scripted
    /// `ITEM_LOGIN_REQUIRED` protocol (not the seeded starting state used by the Today
    /// badge test above, which wouldn't exercise this write path at all), then confirms
    /// the debug view — not just the badge — reflects it.
    func testDebugViewNeedsAttentionText_reflectsLiveImportFailure_notJustCachedLinkedItem() {
        let app = launchedApp { app in
            app.launchEnvironment["UITEST_SCENARIO"] = "normal"
            app.launchEnvironment["UITEST_SEED_PLAID_LINKED_ITEM"] = "1"
            app.launchEnvironment["UITEST_SEED_PLAID_TOKEN"] = "1"
            app.launchEnvironment["UITEST_PLAID_IMPORT_SCENARIO"] = "itemLoginRequired"
            app.launchEnvironment["UITEST_ENABLE_REFRESH_HOOK"] = "1"
        }

        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.staticTexts["plaidDebug.needsAttention"].exists, "sanity check: must not already show needs-attention before any import has run.")

        // Drive a real import via the Transactions tab's debug refresh hook (same
        // mechanism TransactionImportUITests uses) so TransactionImportService itself
        // classifies ITEM_LOGIN_REQUIRED and writes needsAttention through the shared
        // LinkedItemStore — not a value seeded directly into PlaidServiceLive's own copy.
        app.tabBars.buttons["Transactions"].tap()
        let debugRefreshTrigger = app.buttons["transactions.debugRefreshTrigger"]
        XCTAssertTrue(debugRefreshTrigger.waitForExistence(timeout: 5))
        debugRefreshTrigger.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["plaidDebug.needsAttention"].waitForExistence(timeout: 10), "PlaidDebugLinkView must reflect a live import-time ITEM_LOGIN_REQUIRED classification, not just its own separately-cached linkedItem state.")
    }
}

// MARK: - Manual verification (not automated — see suite doc comment)
//
// Before merging, JP should verify the full reconnect round trip against Plaid Sandbox:
//   1. Launch the app (Debug, Xcode), go to the Settings tab (PlaidDebugLinkView).
//   2. Tap "Link a bank account", complete a real Sandbox Link session
//      (institution search -> user_good/pass_good), confirm "Linked institution" appears.
//   3. In the Plaid dashboard (or via curl), call Sandbox's
//      `/sandbox/item/reset_login` for the linked item's item_id to force it into
//      ITEM_LOGIN_REQUIRED.
//   4. Trigger an import (foreground the app, pull-to-refresh, or the debug "Import
//      transactions" button) — confirm the import error banner and/or the
//      "Needs attention" text under "Linked institution" in PlaidDebugLinkView appears,
//      and the Today-screen gear badge appears.
//   5. Tap the Today badge (or the "Relink" button in Settings) — confirm Plaid Link opens
//      in update mode (same institution, no account-selection/consent screens repeated
//      unnecessarily) and completes successfully with user_good/pass_good.
//   6. Confirm "Needs attention" disappears (both surfaces) immediately after the relink
//      completes, without needing to background/foreground the app.
//   7. Trigger another import — confirm it resumes normally (no duplicate transactions,
//      cursor picks up where it left off).
