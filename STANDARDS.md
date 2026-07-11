# Development standards — finance app

## 1. Branching strategy: prefixed branches into main

- `main` — always production-ready / sideloadable. No direct commits.
- One branch per story/bead. Branch from `main`, merge back via PR directly
  into `main`. Delete after merge. Prefix by the kind of change:
  - `feat/<short-name>` — new functionality
  - `fix/<short-name>` — bug fixes
  - `chore/<short-name>` — docs, hygiene, tooling, other non-functional changes

Branch naming: `feat/daily-limit-carry-forward`, `fix/negative-balance-crash`,
`chore/update-readme`.

## 2. Commit standards: Conventional Commits

Format: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Examples:
```
feat(daily-limit): add rolling carry-forward calculation
fix(plaid): handle expired access token on relink
docs(readme): update architecture section for SwiftData migration
test(carry-forward): add edge case coverage for zero-balance days
```

Scope should match the feature area (e.g. `daily-limit`, `plaid`, `onboarding`,
`goal-progress`). Breaking changes get a `!` after the type/scope
(`feat(data-model)!: rename SavingsGoal.targetAmount to targetBalance`) with a
`BREAKING CHANGE:` footer explaining the migration.

## 3. Code quality

- **No copy-paste.** If logic is duplicated across two or more places, extract
  it — a function, a protocol extension, a reusable view. This applies during
  code review, not just at authoring time: if a PR introduces near-duplicate
  logic, that's a blocking comment, not a nit.
- **Business logic stays out of views.** The carry-forward math, goal
  projections, and any calculation belong in plain Swift types/functions that
  don't depend on SwiftUI — this is what makes them unit-testable in the first
  place (see §5).
- Favor composition over inheritance; favor value types (`struct`) unless
  reference semantics are specifically needed.
- Follow Swift API Design Guidelines for naming (clear at the point of use,
  no abbreviations that aren't standard).

## 4. Project structure

Organize by feature/domain, not by layer — avoid one giant `Views/`,
`Models/`, `ViewModels/` split. Suggested top-level layout:

```
App/                 — entry point, App/Scene setup, DI wiring
Features/
  Dashboard/         — DashboardView.swift, DashboardModel.swift
  Accounts/
  Goals/
Models/              — @Model SwiftData entities
  Migrations/        — VersionedSchema (SchemaV1, SchemaV2…) + MigrationPlan
Services/            — I/O and SDK boundaries (PlaidService, PersistenceController)
                        and pure business logic (DailyLimitCalculator, GoalProjector)
Shared/              — reusable views, extensions, styles
Resources/           — Assets.xcassets, Localizable.strings
ReservoirTests/      — XCTest, mirrors Features/ and Services/
ReservoirUITests/    — XCUITest
```

A flatter `Models/ Views/ Services/` split is acceptable while the app is
small — pick one layout and stay consistent as it grows.

**Naming**: suffix by role, not by pattern dogma — `*View` for SwiftUI
views, `*Calculator`/`*Projector` for pure business logic with no
SwiftUI/SwiftData import, `*Service` for I/O/third-party SDK wrappers.
Exception: a `*Calculator` may import SwiftData (never SwiftUI) when its whole
job is mapping `@Model` types into the plain value types a lower-level pure
calculator consumes (e.g. `TodayScreenCalculator` reading `SavingsGoal`/
`SpendTransaction` to build `DailyLimitCalculator.GoalCarryForwardInput`) —
that mapping still needs to live somewhere, doesn't belong in a view, and
splitting it into a separate file buys nothing when the `*Calculator` type
already has no SwiftUI dependency and is unit-testable via an in-memory
`ModelContainer`. The bar stays: never import SwiftUI, and never let
view-layer concerns leak in alongside the model mapping.
`@Model` SwiftData entities are named as plain domain nouns (`SavingsGoal`,
not `SavingsGoalModel`) — the `@Model` macro already marks them as entities,
so a redundant suffix doesn't earn its keep; match whatever name the
project's spec doc locks in. Only use `*ViewModel` where a screen has
enough transient UI state to justify MVVM for that screen specifically.
Where a domain name collides with a framework type (e.g. SwiftUI's own
`Transaction`), rename to disambiguate rather than force the collision.
Test files are named `<TypeName>Tests.swift`; a file covering several
closely-related types (e.g. persistence tests for a whole schema version)
may use a descriptive name instead.

**SwiftData models**: wrap schemas in a `VersionedSchema` from the start
(`SchemaV1` even for the first release) so later migrations don't require
retrofitting. Keep `@Model` types thin — storage and relationships only, no
calculation logic; that belongs in `Services/` per §3.

**Plaid LinkKit**: isolate behind a `Services/Plaid/PlaidService` protocol
that owns the Link session lifecycle and token exchange, and maps Plaid's
types into this app's own domain types. Views and business-logic code never
import `LinkKit` directly — this keeps calculators and view logic testable
without mocking a third-party SDK.

**Architecture pattern**: default to MV (plain `@Observable` models/services
bound directly from views), not MVVM or TCA — at this scope (solo, no
backend) the extra layer buys nothing. Reach for MVVM only on a specific
screen with heavy transient UI state. The testability goal is met by keeping
business logic in plain Swift types (§3), independent of View or Model,
regardless of which pattern a given screen uses.

## 5. Testing standards

- **Unit test coverage: 80% minimum**, measured on business logic and data
  model code (calculation logic, `SavingsGoal`/`Transaction`/`MerchantRule`
  logic, Plaid response parsing). This is the strict, enforced number.
- **UI code (SwiftUI views)** is covered by XCUITest functional tests for key
  flows (onboarding, daily limit view, goal progress view, Plaid Link) rather
  than held to the same unit-coverage percentage — unit-testing declarative
  view layout has poor cost/value and isn't required.
- **Every change is tested before it's considered done** — either a new/updated
  unit test or a functional test, whichever fits the change. No PR merges
  without one or the other.
- Measure coverage locally with:
  ```
  xcodebuild test -scheme <YourScheme> -enableCodeCoverage YES \
    -resultBundlePath TestResults.xcresult
  xcrun xccov view --report TestResults.xcresult
  ```
  Check the business-logic target's coverage number specifically, not the
  whole-app blended number, since that number will be diluted by view code.

## 6. Documentation standards: README

The README is treated as the backbone reference for the app, not a static
intro. It must always contain:

1. **Background** — what the app is, why it exists, who it's for (you).
2. **Architecture** — SwiftUI + SwiftData, no backend, Plaid LinkKit called
   directly from the app; current data model diagram or description.
3. **Technical details** — key frameworks, minimum iOS version, build/sideload
   instructions, environment setup (Plaid API keys, Xcode signing).
4. **Product features** — what's implemented, described from the user's
   perspective (daily limit view, goal progress view, onboarding).
5. **Testing** — how to run the test suite, current coverage expectations.

**Update cadence**: the README is updated in the same PR as any change that
affects architecture, data model, features, or setup steps — not batched into
a later "docs" pass. A PR that changes behavior the README describes is
incomplete without the corresponding README edit.

## 7. Work tracking: beads

All work — features, tasks, bugs — is tracked in beads (`bd`), not markdown
TODO/BACKLOG files or ad hoc notes. This is the system of record:

- New work is filed with `bd create`, not written into a doc or mentioned only
  in conversation.
- Work in progress is claimed with `bd update <id> --claim` before starting.
- A bead is closed with `bd close <id>` only once every item in the Definition
  of Done (§8) is satisfied — not when the code compiles.
- Work discovered mid-task (a bug found while building a feature, a follow-up
  task) is filed as its own bead linked with `--deps discovered-from:<id>`,
  not left as a comment or dropped.
- Check real state before starting or reporting on work: `bd ready`,
  `bd list --json`, `bd show <id>`. Don't rely on memory of prior sessions.

**Cross-clone sync**: beads' live database (Dolt) is local to each machine
and not shared automatically. `.beads/issues.jsonl` is the git-tracked
source of truth — a pre-commit hook exports the current database to it and
stages it on every commit, so it travels with the code. Consequences:
- A fresh clone gets current issue status immediately via
  `bd init --from-jsonl`.
- After pulling changes that touch `.beads/issues.jsonl` on an existing
  clone, refresh the local database with
  `bd init --force --from-jsonl --quiet` (safe — rebuilds the local cache
  from the file you just pulled; note this command itself creates a commit,
  so run it deliberately, not as an automatic hook).

## 8. Definition of done

A change is done when all of the following are true:
- [ ] Code has no duplicated logic (extracted per §3)
- [ ] Business logic covered by unit tests; overall business-logic coverage ≥ 80%
- [ ] Relevant UI flow covered by XCUITest, or manually verified and noted
- [ ] Commit(s) follow Conventional Commits format
- [ ] README updated if architecture, data model, features, or setup changed
- [ ] Merged via PR from `feat/*`, `fix/*`, or `chore/*` directly into `main`,
      not committed directly
- [ ] Corresponding bead closed via `bd close <id>` (see §7)
