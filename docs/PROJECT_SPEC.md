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
  - Post-link import (reservoir-xle): a successful Link also starts one
    bounded poll for the new item (re-calls `/transactions/sync` while Plaid
    returns empty + `transactions_update_status: NOT_READY`, backoff
    2/4/8/15/30/30s, about 89s total, then gives up quietly; the next
    foreground or pull-to-refresh sync picks the data up). Still no
    background timer or webhooks.
  - Account-level capture (reservoir-j8t): `/transactions/sync` `account_id`
    is stored on each imported transaction (`plaidAccountID`) and account
    metadata (name, mask, type, subtype) from the response's `accounts` array
    is merged across pages into `LinkedAccountStore` (pages list only the
    accounts they reference; absence never deletes). Existing rows are
    backfilled once per item by resetting the sync cursor and replaying history
    (up to 730 days); replayed transactions only get a nil account stamped and
    never change type, overrides, goal links or merge state, and never queue
    merge prompts. The old cursor is kept until the replay completes.
  - History depth: fresh links request `transactions.days_requested = 730`
    (Plaid's max) in `/link/token/create`. It is fixed at first link; update-mode
    (relink) tokens don't send it because Plaid ignores it for existing items.
    Items linked before this change keep their original depth (see
    reservoir-ljr).
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

**Monthly budget** (reservoir-j8t): one optional app-wide budget, independent
of savings goals. `monthlyAmount`, `startDate`, `carriesAcrossMonths`
(default true = "Carry over"; false = "Start fresh") and `selectedAccountIDs`.
The daily base on a day is `monthlyAmount / daysInMonth(that day)` (never
`*12/365`; a month sums to exactly the monthly amount). Carry mode rolls surplus
and debt across months; reset mode zeroes carry on each 1st. There is no
revision history: the whole window from `startDate` is recomputed with the
budget's current settings, so edits apply as if they had always applied. A
transaction counts only if its `plaidAccountID` is in `selectedAccountIDs`, it
isn't fixed, and it is dated on/after `startDate` (manual and no-account rows
never count). The same transaction can also count toward a goal; budget account
selection never changes goal account associations. Start date range:
`[max(today - 730 days, earliest imported transaction of the selected accounts),
today]`. Unlinking an item removes its accounts from the selection; an empty
selection shows "Choose accounts", and while account backfill runs the budget
shows "Syncing account data...".

*Budget insights* (PR3), all month-local and identical in carry and reset mode:
`windowStart = max(1st of month, startDate)`; `spent` = counted spend from
`windowStart` through today; `budgetedToDate` = sum of daily bases over the same
days; `paceDelta = budgetedToDate - spent` (positive = under pace). Today's budget
hero shows only a progress sentence ("Day 14 of 31. You've spent $1,240, about $60
under pace."; variants for day 1 / no spend, mid-month start, over budget for the
month, and a carry/fresh clause on the 1st). The Plans card adds a projection
(`rate = spend through yesterday / completed days`; `projected = spent + rate *
days left`; "At this pace you'll finish about $180 under budget."; hidden before 7
completed days and on the last day of the month) and a per-account breakdown
(selected accounts, spend descending, zero rows kept, hidden for a single
account; "Unknown account"/"Removed account"/"Needs relink" states). Insights
follow the same syncing/"Choose accounts" gate as the cards. A `MonthResult`
(budgeted, spent, delta, endingCarry) is computed for the future widget and
month-end review but nothing is persisted.

**Day boundary**: a day starts/ends at the device's local midnight
(`Calendar.current`, not a fixed timezone). Time-zone travel shifts the
boundary with the device — acceptable for a single-user app.

## Data model

| Entity | Key fields |
|---|---|
| `SavingsGoal` | `targetAmount`, `targetDate`, `startDate`, `startingBalance`, derived `currentBalance`, derived `dailyBase` (fixed at creation/edit, see Core mechanic) |
| `Budget` | `monthlyAmount`, `startDate`, `carriesAcrossMonths`, `selectedAccountIDs`, `createdAt` (one app-wide row, `SchemaV9`; no relationship to `Transaction`) |
| `Transaction` | `amount`, `date`, `merchantName`, `type` (variable/fixed), `entryMethod` (manual/imported), `plaidTransactionID` (nil for manual entries), `plaidItemID` (linked item; nil for manual entries), `plaidAccountID` (Plaid account the row belongs to; nil for manual entries and not-yet-backfilled rows, never overwritten once set; `SchemaV8`), `isManualOverride`, `wasMergedFromManual` |
| `PendingTransactionMerge` | queued merge-prompt decision: `plaidTransactionID`, `incoming*` snapshot, `manualTransaction`, `plaidItemID`, `plaidAccountID` (`SchemaV8`) |
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
2. **Plans** (formerly Goals) — monthly budget card, then progress + "at current pace" projections per `SavingsGoal`
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
| Multi-account / multi-goal support | Useful once >1 goal exists | Landed. reservoir-loc.1: schema/storage foundation (SchemaV6's `SpendTransaction.plaidItemID`/`SavingsGoal.associatedItemIDs`, unbounded per-item Plaid storage, `GoalAccountAssociationService`). reservoir-loc.2: per-item dedup/import attribution. reservoir-loc.3: `SettingsView`'s unbounded linked-accounts list (independent relink/unlink/needsAttention per item) and `GoalFormView`'s multi-select account-association UI, both create and edit mode | **Phase 2 — done** |
| Monthly budget (account-level) | Spend tracking without a savings goal; reuses the carry-forward loop | Moderate — `SchemaV9` `Budget`, monthly base schedule, account picker, Plans tab (reservoir-j8t) | **Phase 2 — PR2 landed (core); PR3 insights landed** |
| Charts/trends | Satisfying, doesn't change daily behavior | Swift Charts, easy to add later | **Phase 2, low priority** |
| Widgets / Lock Screen | High usefulness — glanceable number is the point | Needs App Group + shared SwiftData container | **Phase 2** |
| Siri/Shortcuts | Low — single-user app | Nontrivial App Intents work for the value | **Cut** |

## Productionalize (Phase 3)

Infrastructure/ops hardening for wider real-world use, not product features — sequenced
after Phase 2, since none of it is needed for solo dev-machine usage:

- Move the Plaid OAuth universal link's redirect domain off `johnpease.github.io`
  (personal GitHub Pages) to a dedicated domain (reservoir-hka).

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
- **Tab bar**: Today / Plans / Transactions / Settings, in that order of expected use frequency.

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

- Unlink (reservoir-wo1): the unlink confirmation lets the user choose to delete the account's imported transactions (default; relinking starts fresh) or keep them (may duplicate on relink). Manual and merged-manual rows are always kept; the item's sync cursor and pending merge decisions are cleared either way.
