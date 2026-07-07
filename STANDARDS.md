# Development standards — finance app

## 1. Branching strategy: Git Flow

- `main` — always production-ready / sideloadable. No direct commits.
- `develop` — integration branch. Feature branches merge here.
- `feature/<short-name>` — one per story/bead. Branch from `develop`, merge back
  via PR into `develop`. Delete after merge.
- `release/<version>` — cut from `develop` when preparing a sideload build.
  Only bugfixes and doc updates land here. Merges into both `main` and `develop`.
- `hotfix/<short-name>` — branch from `main` for urgent fixes to a shipped build.
  Merges into both `main` and `develop`.

Branch naming: `feature/daily-limit-carry-forward`, `hotfix/negative-balance-crash`.

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
  place (see §4).
- Favor composition over inheritance; favor value types (`struct`) unless
  reference semantics are specifically needed.
- Follow Swift API Design Guidelines for naming (clear at the point of use,
  no abbreviations that aren't standard).

## 4. Testing standards

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

## 5. Documentation standards: README

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

## 6. Work tracking: beads

All work — features, tasks, bugs — is tracked in beads (`bd`), not markdown
TODO/BACKLOG files or ad hoc notes. This is the system of record:

- New work is filed with `bd create`, not written into a doc or mentioned only
  in conversation.
- Work in progress is claimed with `bd update <id> --claim` before starting.
- A bead is closed with `bd close <id>` only once every item in the Definition
  of Done (§7) is satisfied — not when the code compiles.
- Work discovered mid-task (a bug found while building a feature, a follow-up
  task) is filed as its own bead linked with `--deps discovered-from:<id>`,
  not left as a comment or dropped.
- Check real state before starting or reporting on work: `bd ready`,
  `bd list --json`, `bd show <id>`. Don't rely on memory of prior sessions.

## 7. Definition of done

A change is done when all of the following are true:
- [ ] Code has no duplicated logic (extracted per §3)
- [ ] Business logic covered by unit tests; overall business-logic coverage ≥ 80%
- [ ] Relevant UI flow covered by XCUITest, or manually verified and noted
- [ ] Commit(s) follow Conventional Commits format
- [ ] README updated if architecture, data model, features, or setup changed
- [ ] Merged via PR from `feature/*` into `develop` (or `hotfix/*` into `main`
      + `develop`), not committed directly
- [ ] Corresponding bead closed via `bd close <id>` (see §6)
