import XCTest
@testable import Reservoir

final class WaterMotionModelTests: XCTestCase {
    private func target(_ x: Double, _ y: Double, _ o: WaterMotionModel.Orientation = .portrait) -> Double {
        WaterMotionModel.targetAngle(gravity: (x, y), orientation: o)
    }

    func testUprightPhoneKeepsTheWaterLevel() {
        XCTAssertEqual(target(0, -1), 0, accuracy: 1e-9)
    }

    func testTiltingRightTipsTheSurfaceClockwise() {
        // 10 degrees of real tilt is drawn exaggerated by the gain.
        let tenDegrees = 10.0 * .pi / 180
        XCTAssertEqual(target(sin(tenDegrees), -cos(tenDegrees)), tenDegrees * WaterMotionModel.gain, accuracy: 1e-6)
        XCTAssertEqual(target(-sin(tenDegrees), -cos(tenDegrees)), -tenDegrees * WaterMotionModel.gain, accuracy: 1e-6)
    }

    func testAngleIsClampedBeforeTheWaterLeavesTheDrop() {
        XCTAssertEqual(target(1, 0), WaterMotionModel.maxAngle)
        XCTAssertEqual(target(-1, 0.2), -WaterMotionModel.maxAngle)
    }

    func testFlatOnTheTableIsLevel() {
        XCTAssertEqual(target(0, 0), 0)
    }

    func testLandscapeMapsGravityIntoTheScreenFrame() {
        // Home button on the right: the device's right edge points up, so gravity along device -x is screen down.
        XCTAssertEqual(target(-1, 0, .landscapeRight), 0, accuracy: 1e-9)
        XCTAssertEqual(target(1, 0, .landscapeLeft), 0, accuracy: 1e-9)
        XCTAssertEqual(target(0, 1, .portraitUpsideDown), 0, accuracy: 1e-9)
    }

    func testAShoveSidewaysTipsTheWater() {
        let pushed = WaterMotionModel.targetAngle(gravity: (0, -1), userAcceleration: (-0.3, 0), orientation: .portrait)
        XCTAssertGreaterThan(pushed, 0)
    }

    func testSpringSettlesOnTheTargetAfterOvershooting() {
        var model = WaterMotionModel()
        var peak = 0.0
        for _ in 0..<600 {
            model.step(toward: 0.5, dt: 1.0 / 60.0)
            peak = max(peak, model.angle)
        }
        XCTAssertGreaterThan(peak, 0.5, "slosh overshoots")
        XCTAssertEqual(model.angle, 0.5, accuracy: 0.01)
        XCTAssertEqual(model.velocity, 0, accuracy: 0.01)
    }

    func testALongFrameStaysStable() {
        var model = WaterMotionModel()
        model.step(toward: 0.5, dt: 5)
        XCTAssertLessThanOrEqual(abs(model.angle), WaterMotionModel.maxAngle)
    }
}
