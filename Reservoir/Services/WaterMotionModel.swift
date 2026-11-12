import Foundation

/// The physics behind the droplet's water (reservoir-0x1): which way "down" points on the
/// screen, and a damped spring that lets the water surface overshoot and settle rather than
/// snap. Pure, so the maths is unit-testable without a gyroscope.
struct WaterMotionModel: Equatable {
    /// Which edge of the device the interface's top is on; mirrors `UIInterfaceOrientation`
    /// without importing UIKit.
    enum Orientation: Equatable {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
    }

    /// Largest tilt drawn, in radians (about 50 degrees); past that the water would leave the drop.
    static let maxAngle = 0.87
    /// How much the drawn surface exaggerates the phone's real tilt, so a small lean reads clearly on a
    /// drop only a couple of hundred points wide.
    static let gain = 2.5
    /// Spring tuning: a thick, heavy slosh (underdamped, about one swing past the mark).
    static let stiffness = 70.0
    static let damping = 7.5

    /// Surface rotation in radians, positive clockwise on screen.
    private(set) var angle = 0.0
    private(set) var velocity = 0.0
    /// 0...1: how disturbed the surface is, from how fast it is swinging. Smoothed so ripples build
    /// quickly and fade over about half a second.
    private(set) var ripple = 0.0

    /// The surface angle gravity asks for. `gravity` is Core Motion's device-frame gravity
    /// (x right, y up the portrait device, in g) and `userAcceleration` the push of the hand, so
    /// a quick shove sideways tips the water the way it would in a real glass.
    static func targetAngle(
        gravity: (x: Double, y: Double),
        userAcceleration: (x: Double, y: Double) = (0, 0),
        orientation: Orientation,
        sensorFrame: Orientation = .portrait
    ) -> Double {
        let effective = (x: gravity.x - userAcceleration.x, y: gravity.y - userAcceleration.y)
        let screen = screenFrame(screenFrame(effective, sensorFrame), orientation)
        // Upright, gravity is straight down the screen (0, -1) and the surface is level.
        let inPlane = (screen.x * screen.x + screen.y * screen.y).squareRoot()
        guard inPlane > 0 else { return 0 }
        // Held nearly flat, almost no gravity lies in the screen and its direction is just noise, so
        // the tilt fades out below 0.3 g rather than jittering.
        let weight = min(inPlane / 0.3, 1)
        let raw = atan2(screen.x, -screen.y) * gain * weight
        return min(max(raw, -maxAngle), maxAngle)
    }

    /// The sensor's frame is not the same on every device: the foldable reports gravity along its
    /// x axis when held upright. From one reading taken while the phone is held the way the screen
    /// is turned (the interface follows the device), picks the quarter turn that makes it read
    /// level. Nil while the phone is flat, or tilted more than about 20 degrees off upright.
    static func calibratedSensorFrame(gravity: (x: Double, y: Double), orientation: Orientation) -> Orientation? {
        guard (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot() > 0.25 else { return nil }
        let candidates: [Orientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        let best = candidates.min {
            abs(targetAngle(gravity: gravity, orientation: orientation, sensorFrame: $0))
                < abs(targetAngle(gravity: gravity, orientation: orientation, sensorFrame: $1))
        }
        guard let best,
              abs(targetAngle(gravity: gravity, orientation: orientation, sensorFrame: best)) < 0.35 * gain else { return nil }
        return best
    }

    /// Rotates a device-frame vector into the screen's (x right, y up) frame.
    static func screenFrame(_ v: (x: Double, y: Double), _ orientation: Orientation) -> (x: Double, y: Double) {
        switch orientation {
        case .portrait: return (v.x, v.y)
        case .portraitUpsideDown: return (-v.x, -v.y)
        case .landscapeRight: return (-v.y, v.x)
        case .landscapeLeft: return (v.y, -v.x)
        }
    }

    /// Advances the spring toward `target` by `dt` seconds. Long frames are split so the
    /// integration stays stable after a hitch.
    mutating func step(toward target: Double, dt: Double) {
        var remaining = min(max(dt, 0), 0.1)
        let slice = 1.0 / 120.0
        while remaining > 0 {
            let h = min(slice, remaining)
            let acceleration = Self.stiffness * (target - angle) - Self.damping * velocity
            velocity += acceleration * h
            angle += velocity * h
            remaining -= h
        }
        angle = min(max(angle, -Self.maxAngle), Self.maxAngle)
        let disturbed = min(abs(velocity) / 1.4, 1)
        ripple += (disturbed - ripple) * min(1, (disturbed > ripple ? 12 : 3) * min(max(dt, 0), 0.1))
    }
}
