import SwiftUI

/// The hero fill-gauge (`docs/TODAY_SCREEN_REDESIGN_REQUIREMENTS.md` §3.1) — a small
/// teardrop, matching the app icon's silhouette, split by a horizontal waterline into a
/// filled bottom region (`displayFill` tall) and an unfilled top region. All the
/// numeric/color-regime work lives in `FillGaugeCalculator` (no SwiftUI import there);
/// this view only renders the `FillGaugeCalculator.Result` it's given.
///
/// No animation on `displayFill` changes for MVP (§3.1 — instantaneous fill is
/// acceptable; animating the transition is an explicitly-deferred Phase 2 item).
struct FillGaugeView: View {
    let result: FillGaugeCalculator.Result
    var width: CGFloat = 24
    var height: CGFloat = 28

    private var fillColorAssetName: String {
        switch result.colorRegime {
        case .healthy: "ReservoirDropletHealthy"
        case .deficit: "ReservoirDropletDeficit"
        }
    }

    var body: some View {
        ZStack {
            DropletShape()
                .fill(Color("ReservoirDropletTrack"))

            DropletShape()
                .fill(Color(fillColorAssetName))
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: height * CGFloat(result.displayFill))
                }
        }
        .frame(width: width, height: height)
        // Decorative only — the hero number next to it already carries the same
        // information in accessible text form (§3.2), so this doesn't need its own
        // VoiceOver description.
        .accessibilityHidden(true)
    }
}

/// A teardrop silhouette matching the app icon's actual construction
/// (`design_3_droplet`): a circle whose diameter spans the full width of `rect`, capped
/// by a triangular spike that meets the circle tangentially (not an arbitrary S-curve
/// approximation) — the same shape family as the Material "water drop" glyph the icon
/// is built from. The circle's diameter equals `rect.width`; the apex sits at
/// `rect.minY`, and the circle's bottom sits at `rect.maxY`, so the shape exactly fills
/// whatever rect it's given regardless of aspect ratio.
private struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        // Distance from the apex down to the circle's center — the circle's bottom
        // (center + radius) lands exactly on rect.maxY.
        let apexToCenter = rect.height - radius
        let center = CGPoint(x: rect.midX, y: rect.minY + apexToCenter)
        let apex = CGPoint(x: rect.midX, y: rect.minY)

        // Tangent points where the two straight spike edges meet the circle smoothly
        // (no kink), per the standard external-point-to-circle tangent construction.
        let tangentLength = (apexToCenter * apexToCenter - radius * radius).squareRoot()
        let tangentXOffset = radius * tangentLength / apexToCenter
        let tangentYOffset = radius * radius / apexToCenter
        let tangentRight = CGPoint(x: center.x + tangentXOffset, y: center.y - tangentYOffset)
        let tangentLeft = CGPoint(x: center.x - tangentXOffset, y: center.y - tangentYOffset)

        let angleRight = atan2(tangentRight.y - center.y, tangentRight.x - center.x)
        let angleLeft = atan2(tangentLeft.y - center.y, tangentLeft.x - center.x)

        var path = Path()
        path.move(to: apex)
        path.addLine(to: tangentRight)
        // Sweeps through the bottom of the circle (the long way around) back to the
        // left tangent point — see the arc-direction note above for why
        // `clockwise: false` is the visually-clockwise sweep in this y-down space.
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .radians(angleRight),
            endAngle: .radians(angleLeft),
            clockwise: false
        )
        path.addLine(to: apex)
        path.closeSubpath()
        return path
    }
}

#Preview("Healthy") {
    FillGaugeView(result: .init(displayFill: 0.7, colorRegime: .healthy))
        .padding()
}

#Preview("Deficit") {
    FillGaugeView(result: .init(displayFill: 0.3, colorRegime: .deficit))
        .padding()
}

#Preview("Deficit — floor") {
    FillGaugeView(result: .init(displayFill: FillGaugeCalculator.deficitDisplayFloor, colorRegime: .deficit))
        .padding()
}
