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
/// With placeholder credentials, `startLink()`'s `/link/token/create` call
/// reaches the real `sandbox.plaid.com` and gets rejected (invalid
/// client), which is itself a real, live exercise of the "Plaid-side error"
/// classification path end to end — the network round-trip, the non-2xx
/// response, `PlaidErrorClassifier`, and the UI update are all real, only
/// the specific rejection reason differs from a credentialed run.
final class PlaidDebugLinkUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
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

    func testTappingLinkButtonWithInvalidCredentialsSurfacesClassifiedError() {
        let app = launchedApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["plaidDebug.linkButton"].waitForExistence(timeout: 5))
        app.buttons["plaidDebug.linkButton"].tap()

        // The placeholder Config/Plaid.xcconfig credentials get rejected by
        // Plaid's real Sandbox API — startLink()'s own token-creation call
        // fails before Link ever presents, which PlaidErrorClassifier maps
        // to .plaidSide (a non-network HTTP failure), surfaced via
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
