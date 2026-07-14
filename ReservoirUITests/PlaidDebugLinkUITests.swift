import XCTest

/// Manual/functional coverage for reservoir-adq.6.1's debug Plaid entry
/// point, standing in for the parts of the acceptance criteria that need an
/// actual running app rather than a unit test: the entry point rendering,
/// the tap-through to `startLink()`, and the error-classification UI wiring
/// (`PlaidErrorCategory.userFacingMessage` actually reaching the screen).
///
/// This suite intentionally does *not* attempt a real Plaid Sandbox Link
/// session (institution search, `user_good`/`pass_good`, an OAuth
/// institution, `ins_20`) — that requires a real Sandbox `client_id`/secret
/// in `Config/Plaid.xcconfig`, which isn't available in CI/this environment.
///
/// reservoir-z0o: the error-classification test used to rely on Plaid's real
/// Sandbox API rejecting whatever credentials happened to be in
/// `Config/Plaid.xcconfig` — which passed "by accident" only because the
/// app's old custom-scheme redirect_uri was itself invalid and got rejected
/// regardless of credential validity. Once the redirect_uri became a
/// legitimate https universal link, that test started succeeding or failing
/// depending on whether the developer's local xcconfig held real, valid
/// Sandbox credentials. It now forces the failure deterministically via
/// `UITEST_FORCE_PLAID_ERROR=1`, which makes `PlaidDebugLinkView` hand
/// `PlaidServiceLive` a `URLSession` that intercepts every Plaid REST call
/// and fails it with a non-2xx response (see `UITestScenario.plaidURLSession`
/// in `UITestSupport.swift`) — the full real code path (network round-trip,
/// non-2xx handling, `PlaidErrorClassifier`, UI update) still runs, just
/// without depending on Plaid's actual API or local credentials.
final class PlaidDebugLinkUITests: XCTestCase {
    private func launchedApp(forcePlaidError: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if forcePlaidError {
            app.launchEnvironment["UITEST_FORCE_PLAID_ERROR"] = "1"
        }
        app.launch()
        return app
    }

    func testDebugEntryPointRendersLinkButton() {
        let app = launchedApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["plaidDebug.linkButton"].label, "Link a bank account")
        XCTAssertTrue(app.staticTexts["No account linked yet."].exists)
    }

    func testTappingLinkButtonWithForcedFailureSurfacesClassifiedError() {
        let app = launchedApp(forcePlaidError: true)
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        app.buttons["plaidDebug.linkButton"].tap()

        // UITEST_FORCE_PLAID_ERROR makes startLink()'s own token-creation
        // call fail deterministically before Link ever presents (see the
        // suite-level doc comment), independent of whatever's in
        // Config/Plaid.xcconfig locally. PlaidErrorClassifier maps the
        // resulting non-2xx response to .plaidSide, surfaced via
        // PlaidDebugLinkView's error banner and "Try again" affordance.
        let errorMessage = app.staticTexts["plaidDebug.errorMessage"]
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 15))
        XCTAssertEqual(errorMessage.label, "Couldn't connect to your bank. Try again.")
        XCTAssertTrue(app.buttons["plaidDebug.tryAgain"].exists)
    }

    func testVerifyTokenStoredReportsNoTokenWhenNothingLinked() {
        let app = launchedApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.verifyTokenStored"].waitForExistence(timeout: 5))
        app.buttons["plaidDebug.verifyTokenStored"].tap()

        let result = app.staticTexts["plaidDebug.verifyTokenResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "No token found in Keychain.")
    }
}
