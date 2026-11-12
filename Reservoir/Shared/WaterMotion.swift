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
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        model = WaterMotionModel()
        angle = 0
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
    @ViewBuilder var content: (_ angle: Angle) -> Content

    @State private var motion = WaterMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(.radians(motion.angle))
            .onAppear { if !reduceMotion { motion.start() } }
            .onDisappear { motion.stop() }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce { motion.stop() } else { motion.start() }
            }
    }
}
