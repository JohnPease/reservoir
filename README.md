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
  `SchemaV2`) from day one so migrations don't require retrofitting. Bumping
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

**Data model** (current — `Models/Migrations/SchemaV2.swift`; the app-wide
type aliases in `Models/CurrentSchema.swift` always point at the current
version, so the rest of the app never references a `SchemaVN` directly):

| Entity | Key fields |
|---|---|
| `SavingsGoal` | `targetAmount`, `targetDate`, `startDate`, `startingBalance`, `dailyBase` (fixed at creation/edit), `dismissedAt` (set when the user dismisses the Today screen's completion banner — see below; added in `SchemaV2`) |
| `SpendTransaction` | `amount`, `date`, `merchantName`, `type` (variable/fixed), `entryMethod` (manual/imported), `plaidTransactionID`, `isManualOverride`, `createdAt` (record-creation time, distinct from the user-facing `date`; breaks ties when ordering same-day transactions; added in `SchemaV2`) |
| `MerchantRule` | `merchantName` (exact, case-insensitive match), `type` |

**Migrations**: `Models/Migrations/MigrationPlan.swift`'s
`ReservoirMigrationPlan` lists every `VersionedSchema` in order and the
`MigrationStage`s between them. `SchemaV1` -> `SchemaV2` is a lightweight
(inferred) stage — both new fields are optional, no renames or type changes.
Any change to a `@Model` type's shape (new/removed/retyped field) requires a
new `SchemaVN`, not an in-place edit to the current one — an in-place edit
means a store created from an older build no longer matches the version its
data was validated against, and `ModelContainer(for:migrationPlan:)` fails to
open it (see `ReservoirApp.makeModelContainer`'s corrupted-store fallback,
which deletes the on-disk store as a last resort — exactly what a missing
migration stage would trigger for real user data).

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
from each goal's `effectiveStartDate` (creation, or its most recent edit —
an edit resets carry-forward rather than drifting silently) forward; only
`.variable`-kind spend counts, `.fixed` is excluded. `totalDailyLimit(for
goals:)` sums each active goal's independent base + carry-forward — goals
are never pooled. Covered by `ReservoirTests/DailyLimitCalculatorTests.swift`.

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

The empty-state "no active goal" prompt only renders when there are truly no
goals at all — no active *and* no completed-undismissed goal. A
completed-undismissed goal (banner showing, no active goal) is a distinct
state from true emptiness, and shows its own compact "Spent today" card
instead: today's spend is still surfaced even with no active goal to attach a
daily limit to. Orphaned transactions (`savingsGoal == nil`) always count
toward spent/remaining, as does spend attributed to a completed-undismissed
goal — a goal's spend doesn't disappear from tracking the instant
`targetDate` passes, only once the user actually dismisses its banner.

"Add transaction", goal creation from the empty state, and Settings all
share one parameterized `StubSheet` (`Features/Today/TodayStubSheets.swift`)
for now — their real flows are separate stories (adq.3, adq.5/adq.7, and the
Settings tab respectively). Covered by
`ReservoirTests/TodayScreenCalculatorTests.swift` and
`ReservoirUITests/TodayScreenUITests.swift`.

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
- 🚧 Everything else is still in progress. Current state beyond the Today
  screen: the SwiftData data model (`SavingsGoal`, `SpendTransaction`,
  `MerchantRule`) and placeholder Goals/Transactions/Settings tabs.
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
