import XCTest
@testable import Reservoir

final class SplashModelTests: XCTestCase {
    /// A repeatable "random" source so the flight can be asserted exactly.
    private struct Counter: RandomNumberGenerator {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testOnlyAHardShakeSplashes() {
        XCTAssertEqual(SplashModel.strength(userAcceleration: 0.3), 0)
        XCTAssertEqual(SplashModel.strength(userAcceleration: 0.5), 0)
        XCTAssertEqual(SplashModel.strength(userAcceleration: 1.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SplashModel.strength(userAcceleration: 5), 1)
    }

    func testAStrongerShakeThrowsMoreDrops() {
        var generator = Counter()
        var gentle = SplashModel()
        gentle.emit(strength: 0.1, using: &generator)
        var hard = SplashModel()
        hard.emit(strength: 1, using: &generator)
        XCTAssertGreaterThan(hard.drops.count, gentle.drops.count)
        XCTAssertLessThanOrEqual(hard.drops.count, SplashModel.maxDrops)
    }

    func testNoSplashWithoutAShake() {
        var generator = Counter()
        var splash = SplashModel()
        splash.emit(strength: 0, using: &generator)
        XCTAssertTrue(splash.drops.isEmpty)
    }

    func testDropsRiseThenFallBackIntoTheWater() {
        var generator = Counter()
        var splash = SplashModel()
        splash.emit(strength: 1, using: &generator)
        var peak = 0.0
        for _ in 0..<120 {
            splash.step(dt: 1.0 / 60.0)
            peak = max(peak, splash.drops.map(\.h).max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 10, "they leave the surface")
        XCTAssertTrue(splash.drops.isEmpty, "and are gone within two seconds")
    }

    func testCooldownStopsBackToBackSplashes() {
        var generator = Counter()
        var splash = SplashModel()
        splash.emit(strength: 1, using: &generator)
        let first = splash.drops.count
        splash.step(dt: 0.01)
        splash.emit(strength: 1, using: &generator)
        XCTAssertEqual(splash.drops.count, first)
        splash.step(dt: 0.2)
        splash.emit(strength: 1, using: &generator)
        XCTAssertGreaterThan(splash.drops.count, 0)
    }
}
