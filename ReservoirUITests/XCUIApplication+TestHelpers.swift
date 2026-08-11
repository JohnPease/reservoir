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
