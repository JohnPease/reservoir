import XCTest
@testable import Reservoir

final class TestProcessGateTests: XCTestCase {
    func testXCTestHostIsTestProcess() {
        XCTAssertTrue(TestProcessGate.isTestProcess(environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    func testDisableKeyIsTestProcess() {
        XCTAssertTrue(TestProcessGate.isTestProcess(environment: [WidgetSnapshotPublisher.uiTestDisableKey: "1"]))
    }

    func testAnyUITestPrefixIsTestProcess() {
        XCTAssertTrue(TestProcessGate.isTestProcess(environment: ["UITEST_ANYTHING": "1"]))
    }

    func testPlainEnvironmentIsNotTestProcess() {
        XCTAssertFalse(TestProcessGate.isTestProcess(environment: [:]))
        XCTAssertFalse(TestProcessGate.isTestProcess(environment: ["HOME": "/x"]))
    }
}
