import Foundation

/// Pure calculation for the Today screen's hero fill-gauge (droplet), per
/// `docs/TODAY_SCREEN_REDESIGN_REQUIREMENTS.md` §3.1/§4. No SwiftUI/SwiftData import —
/// `*Calculator` naming convention per STANDARDS.md §4 (plain business logic,
/// unit-testable without a live UI or model container).
///
/// There is no persisted "tank capacity" for the gauge to fill against, so this derives
/// one from an existing field rather than adding a new persisted value purely for a
/// visual element (`docs/DESIGN_STANDARDS.md` §4): a week's worth of the goal's current
/// base daily rate, `7 * baseDailyAmount`. This is the resolved formula from the
/// requirements doc's §4 "Open decision" — the recommended option, not the deprioritized
/// user-set-tank-capacity alternative.
///
/// `currentBalance`/`baseDailyAmount` are deliberately named to match the requirements
/// doc's formula rather than any one `TodayScreenCalculator.Summary` field — callers
/// decide which summary figure represents "the balance the gauge/hero number track."
/// `TodayView` passes `summary.limit`/`summary.dailyBase` (the same value that drives
/// the hero number's own healthy/deficit color switch, §3.2), not `summary.remaining` —
/// see `TodayView.HeroSection` doc comment for why.
enum FillGaugeCalculator {

    enum ColorRegime: Equatable {
        case healthy
        case deficit
    }

    /// The gauge's rendered fill amount (always in `[0, 1]`, so callers never have to
    /// re-clamp) and which color-token regime to paint it with.
    struct Result: Equatable {
        var displayFill: Double
        var colorRegime: ColorRegime
    }

    /// Floor applied on the deficit side (§4) so a small deficit never renders as a
    /// fully empty gauge — a zero-height fill reads as a rendering bug, not a real data
    /// state. This only ever engages near the zero boundary: once the deficit magnitude
    /// clears the floor on its own (a "large" deficit, in the DoD checklist's phrasing),
    /// the actual clamped magnitude is already above it and the floor is a no-op — the
    /// clamp at 1.0, not the floor, is what keeps a very large deficit from overflowing
    /// past a full gauge.
    static let deficitDisplayFloor: Double = 0.06

    /// - Parameters:
    ///   - currentBalance: the value the gauge represents.
    ///   - baseDailyAmount: the reference "full tank" rate — scaled to a week
    ///     (`7 * baseDailyAmount`) per §4's resolved formula.
    static func result(currentBalance: Decimal, baseDailyAmount: Decimal) -> Result {
        let fillPercent = signedFillPercent(currentBalance: currentBalance, baseDailyAmount: baseDailyAmount)

        if currentBalance < 0 {
            let magnitude = min(abs(fillPercent), 1.0)
            return Result(displayFill: max(magnitude, deficitDisplayFloor), colorRegime: .deficit)
        } else {
            return Result(displayFill: min(fillPercent, 1.0), colorRegime: .healthy)
        }
    }

    /// `clamp(currentBalance / (7 * baseDailyAmount), -1, 1)` per §4 — exposed
    /// separately from `result(currentBalance:baseDailyAmount:)` so the raw formula is
    /// directly testable against the spec, independent of the display-floor/color
    /// mapping layered on top of it.
    static func signedFillPercent(currentBalance: Decimal, baseDailyAmount: Decimal) -> Double {
        guard baseDailyAmount != 0 else {
            // No reference window to measure against — a zero daily base is a
            // degenerate/edge configuration. Treat it as "at capacity" in whichever
            // direction currentBalance points rather than dividing by zero, so the
            // gauge still renders a sane, non-crashing value.
            if currentBalance > 0 { return 1 }
            if currentBalance < 0 { return -1 }
            return 0
        }

        let window = baseDailyAmount * 7
        let ratio = currentBalance / window
        let clamped = max(Decimal(-1), min(Decimal(1), ratio))
        return NSDecimalNumber(decimal: clamped).doubleValue
    }
}
