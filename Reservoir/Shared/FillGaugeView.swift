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

/// A teardrop silhouette — pointed top, rounded bottom — approximating the app icon's
/// droplet (`design_3_droplet`). Not a pixel-exact trace of that asset; a reasonable
/// vector approximation for a ~24x28pt gauge, per §3.1's "matching the app icon's
/// silhouette" (shape family, not an exact match requirement).
private struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let bulgeCenterY = rect.minY + height * 0.62

        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: bulgeCenterY),
            control1: CGPoint(x: rect.midX + width * 0.38, y: rect.minY + height * 0.12),
            control2: CGPoint(x: rect.maxX, y: rect.minY + height * 0.38)
        )
        path.addArc(
            center: CGPoint(x: rect.midX, y: bulgeCenterY),
            radius: width / 2,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + height * 0.38),
            control2: CGPoint(x: rect.midX - width * 0.38, y: rect.minY + height * 0.12)
        )
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
