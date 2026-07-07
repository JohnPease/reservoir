import XCTest

final class ReservoirLaunchTests: XCTestCase {
    func testAppLaunchesToTabBar() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Goals"].exists)
        XCTAssertTrue(app.tabBars.buttons["Transactions"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }
}
