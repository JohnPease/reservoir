import XCTest
@testable import Reservoir

final class ScreenLayoutTests: XCTestCase {
    func testPhoneSizesUseOneColumn() {
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 440, height: 956)), .column)
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 466, height: 678)), .column, "cover portrait")
    }

    func testInnerDisplayPortraitIsWideColumn() {
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 626, height: 890)), .wideColumn)
    }

    func testLandscapeFromCoverWidthUpIsPanes() {
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 678, height: 466)), .panes, "cover landscape")
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 890, height: 626)), .panes, "inner landscape")
    }

    func testThresholdIsInclusive() {
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 599, height: 900)), .column)
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 600, height: 900)), .wideColumn)
    }

    func testStandardPhoneLandscapeIsPanes() {
        XCTAssertEqual(ScreenLayout.layout(for: CGSize(width: 874, height: 402)), .panes)
    }
}
