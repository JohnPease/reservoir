import Foundation

/// The one USD formatter shared by the app's Today screen and the home screen widget
/// (extracted from `HeroSection`'s private `currency(_:)` — STANDARDS.md §3, no
/// duplicated logic). Lives in `Shared/Widget/` because that folder compiles into both
/// the app and the widget extension.
enum CurrencyFormatting {
    /// "$1,234.50" / "-$12.60" per the system's USD currency format.
    static func usd(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD"))
    }

    /// Widget form: a negative amount renders as a typographic minus (U+2212) before the
    /// dollar sign ("−$12.60"), matching the widget design. Non-negative amounts match
    /// `usd(_:)` exactly.
    static func usdWithTypographicMinus(_ amount: Decimal) -> String {
        amount < 0 ? "\u{2212}" + usd(-amount) : usd(amount)
    }
}
