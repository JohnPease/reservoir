# Daily Limit Finance App — Project Spec

Personal iOS app for tracking spending against a daily limit derived from savings goals. Sideloaded via Xcode, single-user, no backend.

## Architecture decisions (locked)

- **Platform**: iOS 17+ (required for SwiftData and `@Observable`), Swift + SwiftUI
- **Persistence**: SwiftData for local storage
- **Bank integration**: Plaid iOS LinkKit SDK, called directly from Swift with API keys stored in-app — no backend, no hosted infrastructure, no auth layer (acceptable for personal/sideloaded use)
  - Plaid `access_token` is stored in Keychain, never `UserDefaults` or a
    committed config file.
  - Plaid environment: Sandbox during development, Production once linked
    to real accounts — switched via an in-app settings toggle/flag (not a
    separate build configuration), so the environment can change without a
    rebuild.
  - No webhooks (no backend to receive them): transactions are refreshed by
    polling on app foreground plus a manual pull-to-refresh, not on a
    background timer.
- **Build/distribution**: Xcode, sideloaded, not App Store

## Core mechanic

Rolling daily spending limit with continuous carry-forward:
- Overspending a day borrows from future days
- Underspending a day adds to future days
- Balance compounds continuously — no resets

**Base amount**: each `SavingsGoal`'s daily base is `(targetAmount −
startingBalance) / totalDaysFromStart`, calculated once at goal creation and
fixed for the life of the goal. It does not recalculate against later
balance changes — only the rolling carry-forward adjusts day to day. Editing
a goal's `targetAmount`/`targetDate` recalculates the base from that point
forward (treated as a new goal state, not a silent drift).

**Multi-goal scope**: when more than one `SavingsGoal` is active, the Today
screen's daily limit is the **sum of each goal's independent base +
carry-forward**. Each goal tracks its own carry-forward balance; they are
not pooled.

**Fixed expenses**: a `Transaction` tagged `fixed` still reduces the
account balance backing a goal (it's real money leaving), but is excluded
from the daily variable-spend number and carry-forward math. This is why
fixed transactions render muted with "excluded from limit" in the Today UI.

**Day boundary**: a day starts/ends at the device's local midnight
(`Calendar.current`, not a fixed timezone). Time-zone travel shifts the
boundary with the device — acceptable for a single-user app.

## Data model

| Entity | Key fields |
|---|---|
| `SavingsGoal` | `targetAmount`, `targetDate`, `startDate`, `startingBalance`, derived `currentBalance`, derived `dailyBase` (fixed at creation/edit, see Core mechanic) |
| `Transaction` | `amount`, `date`, `merchantName`, `type` (variable/fixed), `entryMethod` (manual/imported), `plaidTransactionID` (nil for manual entries) |
| `MerchantRule` | `merchantName` (exact, case-insensitive match), `type` (variable/fixed) |

No `User` entity — this is a single-user, single-device app with no auth;
app-wide settings (linked accounts, notification prefs) live in a small
`AppSettings` singleton or `UserDefaults`, not a SwiftData model.

- Fixed expenses are designated by merchant name (via `MerchantRule`) or
  tagged per-transaction as an override.
- Onboarding requires users to manually enter existing savings balances so
  day-one limit math is accurate.
- **Merchant matching**: exact, case-insensitive match against
  `merchantName`. A per-transaction manual tag always overrides a
  `MerchantRule` match. No fuzzy/substring matching in MVP — merchant names
  from Plaid are normalized enough that exact match covers the common case;
  substring matching risks false-positive tagging.
- **Dedup**: imported transactions carry Plaid's `plaidTransactionID`. Before
  import, check for an existing manual transaction with the same date +
  amount (± same-day) and merchant; if found, prompt to merge rather than
  double-count. This is a Phase 1 (MVP) concern, not deferred — double
  counting breaks the core mechanic's trust.

## Information architecture

Single `TabView`, four tabs:

1. **Today** — daily limit view (launch screen; core mechanic lives here)
2. **Goals** — progress + "at current pace" projections per `SavingsGoal`
3. **Transactions** — imported/manual list, fixed/variable tagging, `MerchantRule` management
4. **Settings** — linked accounts (Plaid Link), starting balances, goal management

## Feature prioritization

| Feature | Usefulness | Feasibility | Verdict |
|---|---|---|---|
| Daily limit calc + carry-forward | Core mechanic — whole app depends on it | Trivial — pure SwiftData query + arithmetic | **MVP, build first** |
| Manual transaction entry | Needed as fallback even with Plaid | Trivial | **MVP** |
| Plaid Link + transaction import | Difference between a budget app and a chore | Moderate — LinkKit SDK integration, webhook-free polling (no backend) | **MVP** |
| MerchantRule auto-tagging | High leverage — avoids manual triage on every import | Low-moderate — simple string-match rules | **MVP** |
| Goal progress + pace projection | Core "why" behind the daily number | Low — derived math from existing `SavingsGoal` fields | **MVP** |
| Push notifications | Motivational hook | Local `UNUserNotificationCenter` scheduling, no backend needed | **Phase 2** |
| Multi-account / multi-goal support | Useful once >1 goal exists | Data model already supports it; just needs a picker UI | **Phase 2** |
| Charts/trends | Satisfying, doesn't change daily behavior | Swift Charts, easy to add later | **Phase 2, low priority** |
| Widgets / Lock Screen | High usefulness — glanceable number is the point | Needs App Group + shared SwiftData container | **Phase 2** |
| Siri/Shortcuts | Low — single-user app | Nontrivial App Intents work for the value | **Cut** |

## Recommended build order

1. SwiftData models: `SavingsGoal`, `Transaction`, `MerchantRule`
2. Daily limit / carry-forward calculation as a standalone, unit-tested function (cover: overspend day, underspend day, goal edited mid-stream, multi-day gaps)
3. Today screen in SwiftUI, wired to real/seeded data
4. Transactions list, then Goals screen
5. Plaid integration last (highest external risk/effort — de-risk core logic first)

## UX design — Today screen

The Today tab is the launch screen and carries the core mechanic. Layout, top to bottom:

- **Date header**
- **Daily limit — the hero element.** Large (44px), centered, single number. Subtext breaks it down as `$base + $carried forward` so the rolling mechanic stays visible instead of feeling like a mystery number.
- **Two-stat row**: spent today / remaining, in muted metric cards — supporting context, not competing with the hero number.
- **Recent transactions** (last 2-3): icon, merchant, tag (variable/fixed) + timestamp, amount. Fixed expenses (e.g. rent) render muted with "excluded from limit" so users understand why they don't eat into the daily number, without cluttering the variable-spend view.
- **Single primary action**: "Add transaction" — one tap, since Plaid import won't catch everything (cash, lag).
- **Tab bar**: Today / Goals / Transactions / Settings, in that order of expected use frequency.

Design principles driving these choices:
- The number is the hero — a one-second glance should answer "how am I doing today," full stop.
- Carry-forward math is shown, not hidden, to build trust in the system for a target user who isn't financially sophisticated.
- Visual hierarchy (muted vs. emphasized) does the work of separating "acts on my daily limit" from "informational only," rather than relying on labels alone.

Reference mockup was built as a rough guide for the SwiftUI implementation, not a pixel-exact spec — final layout should flex to what SwiftUI/SwiftData make natural.

## Empty states and validation

- **No active goal**: Today screen shows a prompt to create a goal instead
  of a hero number — there's nothing to derive a limit from yet. This is
  the actual first-run state, not onboarding-balance-entry (which comes
  after goal creation).
- **No transactions yet**: recent-transactions list shows an empty-state
  message, not a blank space; two-stat row shows $0 spent / full limit
  remaining.
- **Validation**: transaction amount must be > 0; `targetDate` must be
  after `startDate` and after today at creation time; `startingBalance` may
  be zero or positive only.

## Key learnings

- Plaid's token exchange flow is a best practice for distributed apps, not a platform restriction — direct SDK calls from the app are viable for personal/sideloaded use.
- Starting with Plaid integration from day one (vs. manual-only first) is the right call for this use case.
