# reservoir

> Single place to track finances with an emphasis on daily spending tracking

---

## Background

A personal, single-user iOS app for tracking spending against a rolling
daily limit derived from savings goals. There's no backend and no other
users — it's sideloaded via Xcode for one person's own finances. See
[`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md) for the full product spec,
including the core carry-forward mechanic and UX design.

## Running locally

**Prerequisites**: Xcode 16+ (iOS 17 SDK or later) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen
```

**Open in Xcode**:

```
git clone https://github.com/JohnPease/reservoir.git
cd reservoir
xcodegen generate   # generates Reservoir.xcodeproj from project.yml — not committed, see Technical details
open Reservoir.xcodeproj
```

In Xcode, select the `Reservoir` scheme and an iOS Simulator (e.g. iPhone
16) from the destination picker, then hit **⌘R** to build and run, or
**⌘U** to run the test suite.

**Re-run `xcodegen generate`** any time you pull changes to `project.yml`
or add/remove source files — the `.xcodeproj` is a build artifact, not
tracked in git, so it can go stale otherwise.

**Command line**, as an alternative to the Xcode GUI:

```
xcodebuild -project Reservoir.xcodeproj -scheme Reservoir \
  -destination 'platform=iOS Simulator,name=<device>,OS=<version>' build
```

Substitute an available simulator name/OS from `xcrun simctl list devices`.
No signing setup or Apple ID is needed to run in the Simulator; a
development team is only required to run on a physical device (see
Technical details below).

## Architecture

- **Platform**: iOS 17+, Swift + SwiftUI
- **Persistence**: SwiftData, wrapped in a `VersionedSchema` (currently
  `SchemaV3`) from day one so migrations don't require retrofitting. Bumping
  the schema version (rather than editing the current `VersionedSchema` in
  place) is required any time a `@Model` type's shape changes — see "Data
  model" below
- **Bank integration**: Plaid iOS LinkKit SDK, called directly from the app
  — no backend, no hosted infrastructure
- **Pattern**: MV (plain `@Observable` models/services bound directly from
  views), not MVVM or TCA — see `STANDARDS.md` §4 for rationale

Project layout:

```
Reservoir/
  App/            — entry point, RootTabView, ModelContainer setup
  Features/       — one folder per tab (Today, Goals, Transactions, Settings)
  Models/         — SwiftData @Model types
    Migrations/   — VersionedSchema (SchemaV1, SchemaV2, …) + SchemaMigrationPlan
  Services/       — I/O boundaries (Plaid, persistence) and business logic
  Shared/         — reusable views, extensions
  Resources/      — assets
ReservoirTests/    — XCTest
ReservoirUITests/  — XCUITest
```

**Data model** (current — `Models/Migrations/SchemaV3.swift`; the app-wide
type aliases in `Models/CurrentSchema.swift` always point at the current
version, so the rest of the app never references a `SchemaVN` directly):

| Entity | Key fields |
|---|---|
| `SavingsGoal` | `targetAmount`, `targetDate`, `startDate` (user-editable/backdatable at creation — see "Goals screen" below), `startingBalance`, `dailyBase` (fixed at creation/edit), `dismissedAt` (set when the user dismisses a completion banner; added in `SchemaV2`), `createdAt` (real creation timestamp, never user-editable; added in `SchemaV3` — see "Goals screen" below) |
| `SpendTransaction` | `amount`, `date`, `merchantName`, `type` (variable/fixed), `entryMethod` (manual/imported), `plaidTransactionID`, `isManualOverride`, `createdAt` (record-creation time, distinct from the user-facing `date`; breaks ties when ordering same-day transactions; added in `SchemaV2`) |
| `MerchantRule` | `merchantName` (exact, case-insensitive match), `type` |

**Migrations**: `Models/Migrations/MigrationPlan.swift`'s
`ReservoirMigrationPlan` lists every `VersionedSchema` in order and the
`MigrationStage`s between them. `SchemaV1` -> `SchemaV2` and `SchemaV2` ->
`SchemaV3` are both lightweight (inferred) stages — every new field is
optional, or non-optional with a property-level default (see `SchemaV3`'s
`createdAt` note below). Any change to a `@Model` type's shape (new/removed/
retyped field) requires a new `SchemaVN`, not an in-place edit to the current
one — an in-place edit means a store created from an older build no longer
matches the version its data was validated against, and
`ModelContainer(for:migrationPlan:)` fails to open it (see
`ReservoirApp.makeModelContainer`'s corrupted-store fallback, which deletes
the on-disk store as a last resort — exactly what a missing migration stage
would trigger for real user data).

A **non-optional** new field (like `SchemaV3.SavingsGoal.createdAt`) needs its
default declared directly on the stored property (`var createdAt: Date =
Date.now`), not only as an `init` parameter default — SwiftData's lightweight
migration reads the property-level default to backfill existing rows; an
`init`-only default has no effect on migration, only on newly constructed
Swift objects. Any goal that existed before the `SchemaV3` migration lands
gets `createdAt` backfilled to the migration run's timestamp, which — under
the `effectiveStartDate = max(startDate, createdAt)` mapping below —
retroactively zeroes that goal's carry-forward history the moment the app
updates. Accepted as a one-time, flagged consequence: this is pre-release,
single-device, personal use with no installed base to protect.

`SavingsGoal.currentBalance` (per `docs/PROJECT_SPEC.md`'s data model) is
intentionally **not** a stored field — it's derived from `startingBalance`
and the goal's transactions, so it's computed on demand by the daily-limit
calculator (`Services/`) rather than persisted and kept in sync.

**Daily limit / carry-forward**: `Services/DailyLimitCalculator.swift`
implements the core mechanic (see `docs/PROJECT_SPEC.md` "Core mechanic") as
plain Swift — no `SwiftUI`/`SwiftData` imports, so it's unit-testable without
a `ModelContainer` or the simulator. `SavingsGoal`/`SpendTransaction` are
mapped into its `GoalCarryForwardInput` value type by the calling layer.
Carry-forward is summed per complete calendar day (device-local midnight)
from each goal's `effectiveStartDate` forward; only `.variable`-kind spend
counts, `.fixed` is excluded. `totalDailyLimit(for goals:)` sums each active
goal's independent base + carry-forward — goals are never pooled. Covered by
`ReservoirTests/DailyLimitCalculatorTests.swift`.

`effectiveStartDate` is `lastEditedDate ?? max(startDate, createdAt)`
(`Services/TodayScreenCalculator.carryForwardInput(for:)`) — not
`lastEditedDate ?? startDate` alone. An edit still wins outright and resets
carry-forward from the edit date, per PROJECT_SPEC's "Core mechanic". The
`max(startDate, createdAt)` floor exists because `startDate` is user-editable/
backdatable at creation (see "Goals screen" below): `SpendTransaction
.savingsGoal` is only ever set at transaction-entry time — there's no
retroactive-attribution UI — so days before a goal's real `createdAt`
genuinely have zero attributable transactions, not zero real spend. Without
the floor, backdating `startDate` 14 days at a $10/day base would hand the
user an immediate, fabricated $140 "banked surplus" the moment the goal is
created. `dailyBase` itself is unaffected by the floor and still reflects the
full backdated-to-target day count (`totalDaysFromStart` uses the raw
`startDate`) — a softer, not harsher, daily number for a backdated goal.

No `User` entity — single-user, single-device, no auth. App-wide settings
live outside SwiftData (`UserDefaults`/a settings singleton).

**Today screen**: `Features/Today/TodayView.swift` is the app's launch tab
(see `docs/PROJECT_SPEC.md` "UX design — Today screen"). All calculation —
which goals are "active" (`targetDate >= today`), which have completed but
not been dismissed, the `SavingsGoal`/`SpendTransaction` ->
`GoalCarryForwardInput` mapping, and the spent/remaining summary — lives in
`Services/TodayScreenCalculator.swift`, not the view, so it's unit-testable
without driving the UI. A goal stays active through `targetDate` inclusive;
the day after, if `dismissedAt` is still nil, the Today screen shows a
completion banner instead of a daily-limit hero for that goal. Dismissing the
banner sets `dismissedAt`, which permanently excludes the goal from both
"active" and "completed."

The completion banner's copy is keyed off `DailyLimitCalculator.isGoalMet`
(wrapped for SwiftData by `TodayScreenCalculator.isGoalMet`), not merely
whether `targetDate` has passed: it's an end-state check on the goal's
cumulative carry-forward balance through `targetDate` inclusive
(`carryForward(asOf: targetDate + 1 day) >= 0`), so a day where the user
overspent but recovered later still counts as met — carry-forward is
designed to absorb exactly that. The banner shows celebratory copy ("You
reached your goal — nice work!") when met, or factual, non-punitive copy
("Your target date has arrived" / "You spent more than planned along the
way.") when not — no shortfall amount is shown in either case.

The empty-state "no active goal" prompt only renders when there are truly no
goals at all — no active *and* no completed-undismissed goal. A
completed-undismissed goal (banner showing, no active goal) is a distinct
state from true emptiness, and shows its own compact "Spent today" card
instead: today's spend is still surfaced even with no active goal to attach a
daily limit to. Orphaned transactions (`savingsGoal == nil`) always count
toward spent/remaining, as does spend attributed to a completed-undismissed
goal — a goal's spend doesn't disappear from tracking the instant
`targetDate` passes, only once the user actually dismisses its banner.

Settings still uses the parameterized `StubSheet`
(`Features/Today/TodayStubSheets.swift`) — its real flow is a separate,
future story. "Add transaction" now opens the real `TransactionEntryView`
(see "Transactions tab" below) — `AddTransactionStubSheet` was retired in
adq.3, same as `CreateGoalStubSheet` was retired in adq.5 when goal creation
started opening the real `GoalFormView`. Covered by
`ReservoirTests/TodayScreenCalculatorTests.swift` and
`ReservoirUITests/TodayScreenUITests.swift`.

**Goals screen**: `Features/Goals/GoalsView.swift` lists every goal in three
sections — active (sorted by `targetDate` ascending), completed-but-
undismissed, and (never shown) dismissed — reusing
`TodayScreenCalculator.activeGoals`/`completedUndismissedGoals` as the single
source of truth for goal lifecycle; no second lifecycle model. The
zero-goals empty state and the completed-goal card both reuse shared views
(`Shared/NoActiveGoalPromptView.swift`, `Shared/CompletionBannerView.swift`)
extracted out of `TodayView` so the Goals tab's second entry point to the
same states doesn't duplicate copy or logic (STANDARDS.md §3), as does the
`hasNoGoalsAtAll` predicate itself, now on `TodayScreenCalculator`.

`TodayView` and `GoalsView` both read the app's single "now" from
`Shared/TodayClock.swift`, an `@Observable` holder injected into the
environment once by `RootTabView` (`.environment(todayClock)`) and kept
current there by the one shared `Shared/ReferenceDateKeeper.swift` view
modifier (`.keepingReferenceDateCurrent(_:calendar:)`): refreshed on first
appearance, on foreground resume (`scenePhase == .active`), and at each
midnight boundary via a long-lived `.task`, so a goal's active/completed
status and the Today screen's daily limit both roll over without requiring a
relaunch. This used to be two independent per-tab clocks — `TodayView` and
`GoalsView` each held their own `@State private var referenceDate` and each
applied `.keepingReferenceDateCurrent(...)` themselves, meaning two
concurrent midnight-sleep `Task`s and two `scenePhase` observers running for
the app's lifetime (since `TabView` keeps both tabs' content mounted once
visited). Consolidating to one `TodayClock` owned by `RootTabView` collapses
that to a single `Task`/observer pair with identical refresh behavior.

Goal-specific math — `currentBalance`, progress percentage, and the two
pace-projection reads — lives in `Services/GoalsScreenCalculator.swift`, a
second SwiftData-aware mapping layer alongside `TodayScreenCalculator` (see
STANDARDS.md §4's `*Calculator` exception): lifecycle primitives stay in
`TodayScreenCalculator`, and `GoalsScreenCalculator` calls into those rather
than duplicating them. Each active goal's card (`GoalCardView.swift`) shows a
progress bar (`(currentBalance - startingBalance) / (targetAmount -
startingBalance)`, clamped to `[0, 1]` for the bar fill only — the percentage
text can show negative/over-100% truthfully) and a per-card "Pace"/
"Simulation" segmented control (local `@State`, resets to "Pace" each time
the screen opens, not persisted):

- **Pace** — the light, `carryForward`-sign-based read already used
  elsewhere: on pace by `targetDate` if `carryForward >= 0`, else "~N days
  behind schedule" (`N = ceil(abs(carryForward) / dailyBase)`).
- **Simulation** — a heavier extrapolation: `avgDailyNet` is the average of
  `dailyBase - variableSpendThatDay` over a trailing 14-calendar-day window
  (or fewer, if the goal is younger than 14 days — truncated to
  `daysSince(effectiveStartDate, today)`; 14, not 7, so the read isn't skewed
  by which weekday "today" happens to be). Outputs a projected dollar
  surplus/shortfall at `targetDate` (`avgDailyNet * daysRemaining`) and a
  projected completion date. A goal with zero data in the window (created
  today, or genuinely no spend logged) shows "Not enough spending history
  yet" rather than fabricating a zero-average read — the control stays
  enabled, no silent redirect to Pace.

Both segments show "Pace unavailable" if `dailyBase == 0` (same-day start/
target) — defensive; not reachable through the validated creation/edit flow,
since `targetDate > startDate` is always enforced.

**Goal creation/edit/delete** all go through `Features/Goals/GoalFormView.swift`
(one form, reached from both `TodayView`'s empty-state button and the Goals
tab's own "+" button) and `GoalsView.swift`'s delete confirmation, validated
by `Services/GoalFormValidator.swift` (pure, unit-tested — targetAmount >
startingBalance, targetDate after today/startDate, startingBalance >= 0, and
`startDate` bounded to `[today - 90 days, today]`, both bounds with exact
inline error copy). `targetAmount`/`startingBalance` are non-optional
`Decimal` (matching `GoalFormView`'s bound `@State`, which is never actually
empty/unparsable) — there is no "field is required" case to validate. `startDate` is now user-backdatable at creation — see the
`createdAt` floor above. Editing is limited to `targetAmount`/`targetDate`
(`startingBalance`/`startDate`/`createdAt` are shown read-only) and requires
an explicit confirmation dialog before saving, since it resets the
carry-forward baseline (`lastEditedDate = .now`, `dailyBase` recomputed).
Deletion is an explicit trash-icon button (goal cards render in a
`ScrollView`/`VStack`/`ForEach`, not a `List`, so `.swipeActions` isn't
available without a layout change) with a confirmation naming the count of
attributed transactions, which are orphaned (`savingsGoal = nil`), not
deleted, via the existing `.nullify` delete rule — no calculator change
needed for that part.

All four flows (create, edit, delete, and the completion-banner dismiss
shared with `TodayView`) go through one shared `modelContext.save()` +
rollback-on-failure + error-alert helper, `Services/PersistenceSaveHelper.swift`
— extracted from `TodayView.dismiss(_:)`'s original inline implementation so
the pattern isn't duplicated four times (STANDARDS.md §3).

**Transactions tab** (adq.3): `Features/Transactions/TransactionsView.swift`
lists every `SpendTransaction`, day-grouped into `List` `Section`s ("Today,"
"Yesterday," then full dates) and sorted date-descending (`createdAt`-desc
same-day tiebreak, matching `TodayView`'s `@Query` convention), with an All/
Variable/Fixed filter segmented control. Grouping/filtering/section-title
logic lives in `Services/TransactionsScreenCalculator.swift`, not the view.
Each row shows the same type icon/muted-fixed-styling convention as
`TodayView.TransactionRow`, plus a goal-attribution caption (goal label or
"Unattributed") — `SavingsGoal` has no `name` field, so
`Shared/SavingsGoalDisplayName.swift` derives a short display label
(`$1,000 by Mar 1`) from existing fields rather than adding one. A toolbar
"+" and tapping a row both open `Features/Transactions/TransactionEntryView.swift`
(create/edit, shared with `TodayView`'s "Add transaction" sheet); swipe-to-
delete requires a confirmation.

`TransactionEntryView` validates amount > 0, date <= today (no lower bound —
backdating is a legitimate fallback), and non-empty trimmed merchant name via
`Services/TransactionEntryValidator.swift` (pure, unit-tested). Typing a
merchant name that case-insensitively matches a `MerchantRule`
(`Services/MerchantMatcher.swift`) auto-suggests that rule's `type` until the
user directly edits the type control themselves; if the final saved `type`
diverges from the rule's suggestion, `isManualOverride = true` is set,
protecting that transaction from future retag passes. No match (or the user
accepting the suggestion as-is) means `isManualOverride = false`. Goal
attribution auto-selects the sole active goal when exactly one exists;
otherwise (zero or 2+ active goals) it defaults to "Unattributed" and — only
when 2+ active goals exist — requires an explicit pick or confirm before save
is enabled (`TransactionEntryValidator.goalAttributionRequirement`, reusing
`TodayScreenCalculator.activeGoals` as the sole "active goal" source of
truth, not a second lifecycle model).

**Merchant rules** (adq.3): `Features/Transactions/MerchantRulesView.swift`
(reachable via a toolbar link from the Transactions tab, not its own tab —
the spec's 4-tab IA is locked) lists/creates/edits/deletes `MerchantRule`s
through `Features/Transactions/MerchantRuleEntryView.swift`, validated by
`Services/MerchantRuleValidator.swift` (non-empty merchant name, required
type with no silent default, case-insensitive duplicate-name rejection).
Creating or editing a rule such that its `merchantName`/`type` actually
changes immediately retags every existing, non-manually-overridden
`SpendTransaction` with a case-insensitively matching `merchantName` to the
rule's `type` — the diff (does this edit even need to retag) and the
match/mutation logic live in `Services/MerchantRuleRetagCalculator.swift`
(pure, unit-tested), and the rule mutation + retag mutation are combined into
one atomic `modelContext.save()` via `PersistenceSaveHelper`, not two
sequential saves. A no-op edit (same name/type) never refires the retag.
Deleting a rule is inert with respect to existing transactions — no
retroactive untagging.

`MerchantMatcher` is the single shared matching engine behind both the entry
form's auto-suggest and the retag pass, exposed as a standalone `Services/`
type (not private to a view) so reservoir-adq.4's Plaid import-time
auto-tagging can call it directly without reimplementing the match rule.

**Plaid Link + Keychain token storage** (adq.6.1, foundation only —
transaction import is a separate story, adq.6.3): `Services/Plaid/` is a new
architectural boundary isolating the Plaid LinkKit SDK per STANDARDS §4.
`PlaidService` (`Services/Plaid/PlaidService.swift`) is a LinkKit-free
protocol — no `LinkKit` type appears in its public surface — exposing
`startLink()`, `handleLinkSuccess`/`handleLinkExit`, and observable
`isPresentingLink`/`linkToken`/`isExchangingToken`/`linkedItem`/
`presentedError` state. `PlaidServiceLive` is the concrete implementation and,
together with `PlaidLinkPresentationView`, the only place `import LinkKit`
appears anywhere in the app. It owns two responsibilities:
  - The LinkKit 7.x session lifecycle (`Plaid.createPlaidLinkSession`,
    session-based, not the older `Handler` API), presented via
    `PlaidLinkPresentationView`'s `.sheet()` modifier.
  - Direct-from-device REST calls to Plaid's Sandbox or Production API
    (`/link/token/create`, `/item/public_token/exchange`) — no backend/proxy,
    consistent with this app's no-backend architecture; `client_id`,
    `PLAID_SANDBOX_SECRET`, and `PLAID_PRODUCTION_SECRET` are embedded via
    `Config/Plaid.xcconfig` (committed, safe placeholder defaults — see
    "Plaid setup" under Technical details below for how real credentials get
    layered in via the gitignored `Config/Plaid.local.xcconfig`) into the
    app's Info.plist at build time. `client_id` is a single value shared
    across both environments (Plaid's own account model) — only the
    `secret` differs.

  **Sandbox/Production environment switching** (adq.6.2): `PlaidEnvironment`
  (`Services/Plaid/PlaidEnvironment.swift`) is a `.sandbox`/`.production`
  enum resolving each environment's base URL. `PlaidEnvironmentStore` (also
  in that file, behind a `PlaidEnvironmentStoring` protocol) persists the
  chosen environment in `UserDefaults` — a mode flag, not a secret, so it
  is deliberately not Keychain — and defaults to `.sandbox`. `PlaidServiceLive`
  reads `environmentStore.current` at the top of every Link/token call
  (`createLinkToken()`, `exchangePublicToken(_:)`), not once at init, so
  flipping the in-app toggle takes effect on the next call with no rebuild
  or relaunch. The toggle lives in the same `#if DEBUG` `PlaidDebugLinkView`
  standing in for Settings (below): a segmented Sandbox/Production picker
  whose binding intercepts any attempt to select Production and routes it
  through a confirmation dialog ("This will use real bank data...") before
  applying — selecting Sandbox applies immediately, given the asymmetric
  real-money risk. Settings (adq.7) will host the real control; this is
  temporary scaffolding like the rest of `PlaidDebugLinkView`.

  OAuth-institution redirects are handled by LinkKit itself
  (`ASWebAuthenticationSession` under the hood) once the app has the
  Associated Domains entitlement (`Reservoir.entitlements`, generated from
  `project.yml`'s `targets.Reservoir.entitlements` —
  `applinks:johnpease.github.io`) and an `apple-app-site-association` file is
  hosted at `https://johnpease.github.io/.well-known/apple-app-site-association`
  (a separate `johnpease.github.io` GitHub Pages repo, not part of this repo)
  naming this app's `appID` and the `/oauth` path. The redirect URI passed to
  `/link/token/create` (`PlaidOAuthRedirect.url` in `PlaidServiceLive.swift`,
  `https://johnpease.github.io/oauth`) must also be registered as an allowed
  redirect URI in the Plaid dashboard. Plaid's dashboard now requires an
  `https` redirect URI — the custom URL scheme this app originally used
  (`com.johnpease.reservoir.plaid://oauth`) is no longer accepted. No
  app-side URL-handling code (`onOpenURL`, `application(_:continue:)`, or any
  LinkKit continuation call) is needed: LinkKit's session-based `.sheet()`
  presentation resumes automatically once the system completes the
  associated-domains-backed `ASWebAuthenticationSession` — confirmed against
  LinkKit 7.0.2's public interface (no `continue`/`resume`-style API exists)
  and Plaid's own `LinkDemo-SwiftUI` sample app, which has no URL-handling
  code anywhere in its `App` entry point or session example view.

  `KeychainService` (`Services/Plaid/KeychainService.swift`) wraps the
  `Security` framework's generic-password APIs directly — no third-party
  dependency, since iOS ships no SwiftData/Keychain bridge. The Plaid
  `access_token` is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (survives background refresh, never iCloud-synced/exportable), keyed by a
  single fixed identifier — one linked item for now, multi-account linking is
  deferred (see `docs/PROJECT_SPEC.md`/adq.6 breakdown). Non-secret linked-item
  metadata (institution name, item ID) lives in `UserDefaults`, consistent
  with PROJECT_SPEC's "no `User` entity" note that app-wide settings outside
  SwiftData belong there — not a storage decision for Settings' eventual real
  account list (adq.7/adq.6.3), which may need a SwiftData model once more
  than metadata display is needed.

  `PlaidErrorClassifier` (`Services/Plaid/PlaidErrorClassifier.swift`) is a
  pure function classifying any Link or exchange failure into `.network` vs
  `.plaidSide`, driving the two distinct user-facing messages the product
  spec calls for (raw Plaid `errorCode`/`errorType` strings are never shown to
  the user). It takes a LinkKit-free `PlaidFailureInput` so it stays reusable
  without pulling in the SDK — reservoir-adq.6.5 (item relink / connection-
  status UX) reuses this same classifier for `ITEM_LOGIN_REQUIRED`-style
  import-time errors rather than duplicating the logic.

  There's no permanent UI yet — a `#if DEBUG`-gated `PlaidDebugLinkView`
  stands in for the "Settings" tab (reachable via the Settings tab item in
  DEBUG builds only) so the flow can be driven and Keychain storage verified
  end to end. Settings (adq.7) owns the real entry point and this debug view
  is removed once that story ships.

## Technical details

- **Minimum iOS version**: 17.0 (required for SwiftData and `@Observable`)
- **Project generation**: the Xcode project is generated from
  [`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  rather than committing `Reservoir.xcodeproj` directly — see "Running
  locally" above for setup steps.
- **Signing/distribution**: sideloaded via Xcode, not App Store — set your
  own development team in Xcode's Signing & Capabilities before running on
  a device.
- **Plaid setup**: `Config/Plaid.xcconfig` is committed with safe empty
  placeholder defaults, so `xcodegen generate` and a plain build work on a
  fresh clone with no setup at all (Plaid calls just fail until configured).
  To develop against real Plaid credentials, copy
  `Config/Plaid.local.xcconfig.example` to `Config/Plaid.local.xcconfig`
  (gitignored — never commit real credentials) and fill in `PLAID_CLIENT_ID`,
  `PLAID_SANDBOX_SECRET`, and `PLAID_PRODUCTION_SECRET` (from the
  [Plaid dashboard](https://dashboard.plaid.com/team-settings/keys) —
  `client_id` is shared across environments; each environment has its own
  secret). `Config/Plaid.xcconfig` `#include?`s this file, so its values
  override the placeholder defaults when present. `PLAID_PRODUCTION_SECRET`
  only needs a real value once you're ready to link a real account — the app
  defaults to Sandbox and only calls Production once you flip the in-app
  Sandbox/Production toggle (see "Sandbox/Production environment switching"
  under Architecture above), which is gated by a confirmation step. These
  are embedded into the built app's Info.plist and readable from the `.app`
  bundle — acceptable only under this app's accepted risk posture for
  in-app API keys (personal, sideloaded, single-user, not distributed). The
  Plaid `access_token` itself is stored in Keychain, never `UserDefaults` or
  committed to the repo — see "Plaid Link + Keychain token storage" under
  Architecture above. OAuth-institution support also requires: the
  Associated Domains entitlement (already configured in
  `project.yml`, no per-developer setup), the `johnpease.github.io`
  GitHub Pages repo hosting `apple-app-site-association` staying live, and
  `https://johnpease.github.io/oauth` registered as an allowed redirect URI
  in the Plaid dashboard — see "Plaid Link + Keychain token storage" above
  for details.

## Product features

- **Today screen** (implemented): date header, hero daily-limit number
  (`$base + $carried forward`), spent-today/remaining stat row, last-3
  recent transactions (fixed expenses shown muted, "excluded from limit"),
  and a single "Add transaction" action. Empty state prompts goal creation
  when there's no active goal; a completion banner appears once a goal's
  `targetDate` passes, and dismissing it resets to the empty state. See
  "Today screen" under Architecture above.
- **Goals screen** (implemented): active-goal cards with a progress bar,
  target/start dates, and a per-card Pace/Simulation toggle for "at current
  pace" projections; completed-but-undismissed goals with the same banner as
  Today; a shared zero-goals empty state; and full goal create/edit/delete,
  including backdatable `startDate` at creation. See "Goals screen" under
  Architecture above.
- **Transactions tab** (implemented): day-grouped, date-descending list of
  every transaction with an All/Variable/Fixed filter, goal-attribution
  indicator per row, tap-to-edit/swipe-to-delete, and a "+" that opens the
  same manual entry form as Today's "Add transaction" button (amount/date/
  merchant/type validation, merchant-rule auto-suggest with manual-override
  protection, goal-attribution picker). Merchant rule management
  (create/edit/delete, duplicate-name rejection, retroactive retag of
  matching transactions on rule create/edit) is reachable from this tab. See
  "Transactions tab" under Architecture above.
- **Plaid Link + Keychain token storage** (adq.6.1, foundation only): behind
  a `#if DEBUG` entry point standing in for Settings (see Architecture
  above) — links an institution (including OAuth institutions) via LinkKit,
  exchanges the resulting token directly from the device, and stores it in
  Keychain. Transaction import itself is not built yet (adq.6.3).
- **Sandbox/Production environment switching** (adq.6.2): an in-app toggle
  (currently on the same `#if DEBUG` entry point above) switches which
  Plaid credential set/API host `PlaidServiceLive` uses, with no rebuild —
  see "Sandbox/Production environment switching" under Architecture above.
- 🚧 Everything else is still in progress. Current state beyond Today,
  Goals, and Transactions: the placeholder Settings tab (linked accounts,
  starting balances, goal management) and Plaid transaction import.
- Planned MVP scope and build order are tracked in
  [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md) and as beads under the
  `reservoir-adq` epic (`bd show reservoir-adq`).

## Testing

- Unit tests: `ReservoirTests/` (XCTest) — run via Xcode (⌘U) or:
  ```
  xcodebuild -project Reservoir.xcodeproj -scheme Reservoir \
    -destination 'platform=iOS Simulator,name=<device>,OS=<version>' test
  ```
- UI tests: `ReservoirUITests/` (XCUITest) — run in the same `test` invocation.
- Coverage target: 80% minimum on business logic and data model code (see
  `STANDARDS.md` §5). Measure with:
  ```
  xcodebuild test -scheme Reservoir -enableCodeCoverage YES \
    -resultBundlePath TestResults.xcresult
  xcrun xccov view --report TestResults.xcresult
  ```
  `Services/Plaid/`'s pure logic is held to the same bar: `KeychainService`,
  `PlaidErrorClassifier`, and `PlaidEnvironment`/`PlaidEnvironmentStore` are
  all directly unit tested (no LinkKit/network dependency needed).
  `PlaidServiceLive`'s LinkKit session creation and its direct-to-Plaid REST
  calls are integration-level boundaries and intentionally excluded from the
  coverage bar (consistent with how `PlaidService` is designed to isolate
  them) — its pure mapping logic (`errorType(for:)`, `handleLinkExit`'s
  cancel-vs-error branching) is still unit tested, as is the environment-
  resolution behavior added in adq.6.2: `PlaidEnvironmentTests` stubs
  `PlaidEnvironmentStoring` and intercepts outgoing requests via a test
  `URLProtocol` to assert `PlaidServiceLive` dials the Sandbox vs. Production
  host matching the current flag, re-read on every call (flipping the flag
  between two calls on the same instance changes the second call's host with
  no new instance required). Driving an actual Sandbox Link session
  (including the OAuth-institution redirect and Sandbox's error-simulation
  institutions) is manual verification, noted in the relevant PR rather than
  automated.
