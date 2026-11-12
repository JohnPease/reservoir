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
    /// Spring tuning: a lively but short slosh (underdamped, roughly two swings).
    static let stiffness = 120.0
    static let damping = 5.0

    /// Surface rotation in radians, positive clockwise on screen.
    private(set) var angle = 0.0
    private(set) var velocity = 0.0

    /// The surface angle gravity asks for. `gravity` is Core Motion's device-frame gravity
    /// (x right, y up the portrait device, in g) and `userAcceleration` the push of the hand, so
    /// a quick shove sideways tips the water the way it would in a real glass.
    static func targetAngle(
        gravity: (x: Double, y: Double),
        userAcceleration: (x: Double, y: Double) = (0, 0),
        orientation: Orientation
    ) -> Double {
        let effective = (x: gravity.x - userAcceleration.x, y: gravity.y - userAcceleration.y)
        let screen = screenFrame(effective, orientation)
        // Upright, gravity is straight down the screen (0, -1) and the surface is level.
        guard screen.x != 0 || screen.y != 0 else { return 0 }
        let raw = atan2(screen.x, -screen.y)
        return min(max(raw, -maxAngle), maxAngle)
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
    }
}
