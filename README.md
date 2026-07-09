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

"Add transaction" and Settings share one parameterized `StubSheet`
(`Features/Today/TodayStubSheets.swift`) for now — their real flows are
separate stories (adq.3 and the Settings tab respectively). Goal creation
from the empty state opens the real `GoalFormView` (see "Goals screen"
below), not a stub — `CreateGoalStubSheet` was retired in adq.5. Covered by
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
same states doesn't duplicate copy or logic (STANDARDS.md §3).

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
inline error copy). `startDate` is now user-backdatable at creation — see the
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

## Technical details

- **Minimum iOS version**: 17.0 (required for SwiftData and `@Observable`)
- **Project generation**: the Xcode project is generated from
  [`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  rather than committing `Reservoir.xcodeproj` directly — see "Running
  locally" above for setup steps.
- **Signing/distribution**: sideloaded via Xcode, not App Store — set your
  own development team in Xcode's Signing & Capabilities before running on
  a device.
- **Plaid setup**: not yet integrated (planned — see `docs/PROJECT_SPEC.md`
  build order). API keys will be required and the Plaid `access_token` will
  be stored in Keychain, never committed to the repo.

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
- 🚧 Everything else is still in progress. Current state beyond the Today
  and Goals screens: the SwiftData data model (`SavingsGoal`,
  `SpendTransaction`, `MerchantRule`) and placeholder Transactions/Settings
  tabs.
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
