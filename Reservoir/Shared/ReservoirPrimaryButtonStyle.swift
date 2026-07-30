import SwiftUI

/// The app's one primary/accent `ButtonStyle` — `ReservoirAccent` fill, `ReservoirOnAccent`
/// label. Originally a `private` type inside `TodayView` (Today screen redesign,
/// reservoir-d01) for its "Add transaction" CTA; extracted here (reservoir-jog) once
/// Goals/Transactions/Settings needed the identical treatment for their own primary CTAs
/// ("Create a goal", "Create"/"Save", "Link a bank account"/"Relink") — STANDARDS.md §3,
/// no copy-pasting this per screen.
///
/// Built as a custom `ButtonStyle` rather than `.buttonStyle(.borderedProminent).tint(...)`
/// because `.borderedProminent`'s label color isn't independently customizable — it's
/// always a system-chosen (effectively white) foreground regardless of `.tint()`, which
/// can't express `ReservoirOnAccent`'s dark-on-light-teal flip in dark mode (see
/// `docs/DESIGN_STANDARDS.md` §2's contrast note — the accent button uses dark text over a
/// lighter teal there, matching the app icon's own contrast). Corner radius/padding below
/// are a reasonable match to the prior `.borderedProminent` default, not a byte-for-byte
/// trace of its undocumented system metrics.
struct ReservoirPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color("ReservoirOnAccent"))
            .padding(.vertical, 14)
            .background(Color("ReservoirAccent"), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
