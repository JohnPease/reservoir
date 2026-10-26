import SwiftUI

extension View {
    /// The app's standard rounded card surface (`ReservoirSurface`, 12pt corners) — one
    /// definition shared by the goal card, the budget cards and the stat cards
    /// (STANDARDS.md §3, no copy-paste). Pass a different asset-catalog fill (e.g.
    /// `ReservoirSurfaceDeficit`) for a status variant; the shape stays the same.
    func reservoirCardBackground(_ fill: Color = Color("ReservoirSurface")) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: 12))
    }
}
