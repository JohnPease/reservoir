import Foundation

/// The droplets that jump off the water when the phone is shaken hard (reservoir-0x1). Pure, so
/// the flight can be unit-tested. Each drop is tracked in the surface's own frame: `u` along the
/// surface from its middle, `h` above it, so gravity is simply "down toward the surface" however
/// the water is tilted, and the view rotates the result into place. Units are points at the large
/// droplet's size; the view scales them for smaller drops.
struct SplashModel: Equatable {
    struct Drop: Equatable {
        var u: Double
        var h: Double
        var du: Double
        var dh: Double
        var age: Double
        var life: Double
        var radius: Double

        /// 1 at launch, fading to 0 at the end of its life.
        var opacity: Double { max(0, 1 - age / life) }
    }

    /// Gravity in points per second squared; a drop of this size is meant to feel heavy, so it
    /// rises a moment and falls back quickly.
    static let gravity = 900.0
    static let maxDrops = 48
    /// Shortest time between two splashes, in seconds.
    static let cooldown = 0.07

    private(set) var drops: [Drop] = []
    private var sinceLast = SplashModel.cooldown

    /// How hard a shake is, 0...1, from the hand's acceleration in g. Anything under a third of a g is
    /// ordinary handling and splashes nothing.
    static func strength(userAcceleration: Double) -> Double {
        min(max((userAcceleration - 0.3) / 1.2, 0), 1)
    }

    /// Throws up a handful of drops from near the middle of the surface. Does nothing while a
    /// previous splash is still within the cooldown.
    mutating func emit(strength: Double, using generator: inout some RandomNumberGenerator) {
        guard strength > 0, sinceLast >= Self.cooldown else { return }
        sinceLast = 0
        let count = 4 + Int((strength * 12).rounded())
        for _ in 0..<count where drops.count < Self.maxDrops {
            drops.append(Drop(
                u: .random(in: -55...55, using: &generator),
                h: 2,
                du: .random(in: -70...70, using: &generator) * (0.5 + strength),
                dh: .random(in: 120...260, using: &generator) * (0.5 + strength * 0.8),
                age: 0,
                life: .random(in: 0.7...1.1, using: &generator),
                radius: .random(in: 1.6...3.6, using: &generator)
            ))
        }
    }

    /// Flies every drop on; drops that fall back into the water, or outlive their life, are removed.
    mutating func step(dt: Double) {
        let dt = min(max(dt, 0), 0.1)
        sinceLast += dt
        for index in drops.indices {
            drops[index].dh -= Self.gravity * dt
            drops[index].u += drops[index].du * dt
            drops[index].h += drops[index].dh * dt
            drops[index].age += dt
        }
        drops.removeAll { $0.h < 0 || $0.age >= $0.life }
    }
}
