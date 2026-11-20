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
        // 30 degrees of real tilt: the dead zone comes off, the rest is exaggerated by the gain.
        let thirty = 30.0 * .pi / 180
        let expected = (thirty - WaterMotionModel.deadZone) * WaterMotionModel.gain
        XCTAssertEqual(target(sin(thirty), -cos(thirty)), expected, accuracy: 1e-6)
        XCTAssertEqual(target(-sin(thirty), -cos(thirty)), -expected, accuracy: 1e-6)
    }

    func testAngleIsClampedBeforeTheWaterLeavesTheDrop() {
        XCTAssertEqual(target(1, 0), WaterMotionModel.maxAngle)
        XCTAssertEqual(target(-1, 0.2), -WaterMotionModel.maxAngle)
    }

    func testTiltFadesOutAsThePhoneGoesFlat() {
        let leaning = target(0.04, -0.1)
        let upright = target(0.4, -1.0)
        XCTAssertLessThan(abs(leaning), abs(upright), "same direction, less gravity in the screen")
        XCTAssertEqual(target(0.01, -0.01), 0, accuracy: 0.1)
    }

    func testSmallLeansDoNotMoveTheWater() {
        let fiveDegrees = 5.0 * .pi / 180
        XCTAssertEqual(target(sin(fiveDegrees), -cos(fiveDegrees)), 0)
        XCTAssertEqual(target(-sin(fiveDegrees), -cos(fiveDegrees)), 0)
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

    func testCalibrationFindsTheSensorTurnFromOneReading() {
        func frame(_ x: Double, _ y: Double, _ o: WaterMotionModel.Orientation = .portrait) -> WaterMotionModel.Orientation? {
            WaterMotionModel.calibratedSensorFrame(gravity: (x, y), orientation: o)
        }
        XCTAssertEqual(frame(0, -1), .portrait, "ordinary phone held upright")
        XCTAssertEqual(frame(-1, 0.05), .landscapeRight, "foldable: gravity along -x while upright")
        XCTAssertEqual(frame(0.3, -0.95), .portrait, "tilted a little still reads as upright")
        XCTAssertEqual(frame(-1, 0, .landscapeRight), .portrait, "ordinary phone held in landscape")
        XCTAssertEqual(frame(-0.47, 0.004), .landscapeRight, "foldable leaning back, little gravity in the screen")
        XCTAssertNil(frame(0.05, -0.1), "flat on a table")
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

    func testRippleBuildsWhileSwingingAndFadesOnceSettled() {
        var model = WaterMotionModel()
        XCTAssertEqual(model.ripple, 0)
        for _ in 0..<12 { model.step(toward: 0.8, dt: 1.0 / 60.0) }
        XCTAssertGreaterThan(model.ripple, 0.3)
        for _ in 0..<900 { model.step(toward: 0.8, dt: 1.0 / 60.0) }
        XCTAssertLessThan(model.ripple, 0.01)
    }

    func testALongFrameStaysStable() {
        var model = WaterMotionModel()
        model.step(toward: 0.5, dt: 5)
        XCTAssertLessThanOrEqual(abs(model.angle), WaterMotionModel.maxAngle)
    }
}
