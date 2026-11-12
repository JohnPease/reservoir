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

    private var model = WaterMotionModel()
    private let manager = CMMotionManager()
    private var sensorFrame: WaterMotionModel.Orientation?
    private var lastTimestamp: TimeInterval?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lastTimestamp = nil
        sensorFrame = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let dt = self.lastTimestamp.map { motion.timestamp - $0 } ?? 1.0 / 60.0
            self.lastTimestamp = motion.timestamp
            let orientation = Self.interfaceOrientation
            if self.sensorFrame == nil {
                self.sensorFrame = WaterMotionModel.calibratedSensorFrame(
                    gravity: (motion.gravity.x, motion.gravity.y), orientation: orientation
                )
            }
            let target = WaterMotionModel.targetAngle(
                gravity: (motion.gravity.x, motion.gravity.y),
                userAcceleration: (motion.userAcceleration.x, motion.userAcceleration.y),
                orientation: orientation,
                sensorFrame: self.sensorFrame ?? .portrait
            )
            self.model.step(toward: target, dt: dt)
            self.angle = self.model.angle
            self.ripple = self.model.ripple
            self.phase += dt * 2.2
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        model = WaterMotionModel()
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
        content(WaterState(angle: .radians(motion.angle), ripple: motion.ripple, phase: motion.phase))
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
        let amplitude = 1.2 + 4.5 * CGFloat(water.ripple)
        let phase = water.phase + phaseOffset
        func surface(_ x: CGFloat) -> CGFloat {
            let dx = x - rect.midX
            return level + dx * slope
                + amplitude * CGFloat(sin(Double(dx) / 16 + phase))
                + amplitude * 0.5 * CGFloat(sin(Double(dx) / 7 - phase * 1.7))
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
