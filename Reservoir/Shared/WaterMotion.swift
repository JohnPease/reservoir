import CoreMotion
import SwiftUI
import UIKit

/// Feeds the droplet's water the phone's tilt (reservoir-0x1). Owns one `CMMotionManager` for as
/// long as a droplet is on screen; with no motion hardware (the simulator) or with Reduce Motion
/// on, the angle stays 0 and the water sits level.
@MainActor
@Observable
final class WaterMotion {
    private(set) var angle = 0.0
    private(set) var ripple = 0.0
    /// Advances with time so the waves travel along the surface even when the phone is still.
    private(set) var phase = 0.0
    private(set) var drops: [SplashModel.Drop] = []
    private var splash = SplashModel()

    private var model = WaterMotionModel()
    private let manager = CMMotionManager()
    /// The sensor's turn is a fact about the device, so once found it is kept for the life of the
    /// app; recalibrating on every appearance left the water 90 degrees off until the phone moved.
    private static var sensorFrame: WaterMotionModel.Orientation?
    private var pending: (frame: WaterMotionModel.Orientation, orientation: WaterMotionModel.Orientation, count: Int)?
    private var lastTimestamp: TimeInterval?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lastTimestamp = nil
        pending = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let dt = self.lastTimestamp.map { motion.timestamp - $0 } ?? 1.0 / 60.0
            self.lastTimestamp = motion.timestamp
            let orientation = Self.interfaceOrientation
            if Self.sensorFrame == nil {
                self.calibrate(gravity: (motion.gravity.x, motion.gravity.y), orientation: orientation)
            }
            // Until the sensor's turn is known the water sits level rather than guessing wrong.
            let target = Self.sensorFrame.map {
                WaterMotionModel.targetAngle(
                    gravity: (motion.gravity.x, motion.gravity.y),
                    userAcceleration: (motion.userAcceleration.x, motion.userAcceleration.y),
                    orientation: orientation,
                    sensorFrame: $0
                )
            } ?? 0
            self.model.step(toward: target, dt: dt)
            self.angle = self.model.angle
            self.ripple = self.model.ripple
            self.phase += dt * 1.3
            let push = (motion.userAcceleration.x * motion.userAcceleration.x
                + motion.userAcceleration.y * motion.userAcceleration.y
                + motion.userAcceleration.z * motion.userAcceleration.z).squareRoot()
            var generator = SystemRandomNumberGenerator()
            self.splash.emit(strength: SplashModel.strength(userAcceleration: push), using: &generator)
            self.splash.step(dt: dt)
            self.drops = self.splash.drops
        }
    }

    /// Commits the sensor's turn only after half a second of readings that all agree, so one
    /// stray sample (a launch in mid-rotation, a bump) can never fix a wrong answer for good.
    private func calibrate(gravity: (x: Double, y: Double), orientation: WaterMotionModel.Orientation) {
        guard let candidate = WaterMotionModel.calibratedSensorFrame(gravity: gravity, orientation: orientation) else {
            pending = nil
            return
        }
        if pending?.frame == candidate, pending?.orientation == orientation {
            pending?.count += 1
        } else {
            pending = (candidate, orientation, 1)
        }
        if let pending, pending.count >= 30 { Self.sensorFrame = pending.frame }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        model = WaterMotionModel()
        splash = SplashModel()
        drops = []
        angle = 0
        ripple = 0
    }

    private static var interfaceOrientation: WaterMotionModel.Orientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.interfaceOrientation {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }
}

/// Hands its content the current water tilt, running the gyroscope only while it is on screen
/// and not under Reduce Motion.
struct TiltingWater<Content: View>: View {
    @ViewBuilder var content: (_ water: WaterState) -> Content

    @State private var motion = WaterMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(WaterState(angle: .radians(motion.angle), ripple: motion.ripple, phase: motion.phase, drops: motion.drops))
            .onAppear { if !reduceMotion { motion.start() } }
            .onDisappear { motion.stop() }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce { motion.stop() } else { motion.start() }
            }
    }
}

/// What the water looks like this frame: the tilt of its surface and how much it is rippling.
struct WaterState {
    var angle: Angle
    var ripple: Double
    var phase: Double
    var drops: [SplashModel.Drop] = []
}

/// The water below a surface line (reservoir-0x1): the line tilts about its middle and carries two
/// travelling sine waves, a small one always and a larger one that grows with `ripple`. Extends
/// well past the rect so a tilted surface never uncovers a corner; clip it to the drop.
struct WaterSurfaceShape: Shape {
    /// Height of the surface at the middle, measured down from the top of the rect.
    var level: CGFloat
    var water: WaterState
    /// Shifts the waves so a second layer does not move in step with the first.
    var phaseOffset = 0.0

    func path(in rect: CGRect) -> Path {
        let slope = CGFloat(tan(water.angle.radians))
        let amplitude = 1.6 + 6 * CGFloat(water.ripple)
        let phase = water.phase + phaseOffset
        func surface(_ x: CGFloat) -> CGFloat {
            let dx = x - rect.midX
            return level + dx * slope
                + amplitude * CGFloat(sin(Double(dx) / 22 + phase))
                + amplitude * 0.6 * CGFloat(sin(Double(dx) / 10 - phase * 1.5))
                + amplitude * 0.3 * CGFloat(sin(Double(dx) / 5 + phase * 2.3))
        }
        var path = Path()
        let left = rect.minX - rect.width
        let right = rect.maxX + rect.width
        let bottom = rect.maxY + rect.height * 3
        path.move(to: CGPoint(x: left, y: surface(left)))
        var x = left
        while x < right {
            x += 3
            path.addLine(to: CGPoint(x: x, y: surface(x)))
        }
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// The splash drawn over the water: each drop is placed on the tilted surface's own axes, so it
/// leaves along the surface's normal and falls back toward it. `pivot` is the middle of the water
/// line and `scale` the drop's size relative to the large hero droplet.
struct SplashView: View {
    let water: WaterState
    let pivot: CGPoint
    let scale: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let theta = water.angle.radians
            let along = CGVector(dx: cos(theta), dy: sin(theta))
            let normal = CGVector(dx: sin(theta), dy: -cos(theta))
            for drop in water.drops {
                let u = CGFloat(drop.u) * scale
                let h = CGFloat(drop.h) * scale
                let x = pivot.x + u * along.dx + h * normal.dx
                let y = pivot.y + u * along.dy + h * normal.dy
                let r = CGFloat(drop.radius) * scale
                context.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(drop.opacity))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
