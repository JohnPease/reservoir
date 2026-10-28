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
