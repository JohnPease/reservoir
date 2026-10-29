import XCTest

/// Shared XCUITest helpers — extracted so the same interaction pattern isn't
/// copy-pasted across test files (STANDARDS.md, no duplicated logic).
extension XCUIApplication {
    /// Dismisses a `confirmationDialog`-as-popover by tapping outside it.
    ///
    /// reservoir-wcd: on this iOS version, `DeleteConfirmation`'s
    /// `confirmationDialog` renders as a system popover with no accessible
    /// "Cancel" button — the button exists in the view hierarchy (see
    /// `DeleteConfirmation.swift`'s doc comment) but isn't reachable via
    /// XCUITest lookups. Tap-outside is the only working dismissal, and is
    /// standard system behavior for a popover, so this is accepted as-is
    /// rather than worked around.
    func dismissPopoverByTappingOutside() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    }
}

extension XCUIApplication {
    /// The one way UI tests create the app under test. Sets `UITEST_DISABLE_WIDGET_PUBLISH`
    /// so `WidgetSnapshotPublisher.makeDefault` selects the no-op publisher: a UI-test
    /// launch must never write the real App Group `widget-snapshot.json` or reload the
    /// device's widget timelines (reservoir-apd). Every launch site routes through here,
    /// including ones that set no other `UITEST_*` variable.
    static func reservoirApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DISABLE_WIDGET_PUBLISH"] = "1"
        return app
    }
}
