import Foundation
import SwiftData

/// Pure, testable merchant-name -> `MerchantRule.type` lookup (adq.3). Shared by two call
/// sites within this story: the manual transaction entry form's auto-suggest
/// (`TransactionEntryView`) and the retroactive retag pass triggered on `MerchantRule`
/// create/edit (`MerchantRuleEntryView`, via `MerchantRuleRetagCalculator`) — see the
/// bead's "Scope note" for why one shared implementation is required rather than two.
///
/// Exact, case-insensitive match against `MerchantRule.merchantName` — no substring/fuzzy
/// matching, per `docs/PROJECT_SPEC.md`'s "Merchant matching" rule. Exposed as a
/// standalone, non-private type (not buried inside a view) so reservoir-adq.4's
/// Plaid import-time flow can call it directly without reimplementing the match rule.
enum MerchantMatcher {
    /// Returns the `type` of the first rule in `rules` whose `merchantName` matches
    /// `merchantName` case-insensitively (after trimming whitespace), or `nil` if no rule
    /// matches (including when `merchantName` is empty/whitespace-only).
    static func match(rules: [MerchantRule], merchantName: String) -> TransactionType? {
        let trimmed = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rules.first { $0.merchantName.caseInsensitiveCompare(trimmed) == .orderedSame }?.type
    }
}
