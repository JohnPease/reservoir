# Design standards — visual system

Status: living document. Captures the general design decisions established
during the Today screen redesign (see `docs/TODAY_SCREEN_REDESIGN_REQUIREMENTS.md`
for that specific spec) so future screens stay consistent without re-deriving
these calls from scratch. When a new screen's requirements doc makes a design
decision that generalizes beyond that screen, promote it here.

## 1. Color system

- **Asset Catalog color sets only.** All app colors are defined as Any/Dark
  color set assets, never hardcoded hex values or `UIColor`/`Color` literals
  in view code, and never runtime `colorScheme ==` branching to pick a color.
  Light/dark switching is the Asset Catalog's job, not the view's.
- **Source of truth is the app icon.** Palette values are sampled from the
  app icon (`design_3_droplet`), not chosen independently per screen — this
  keeps the whole app visually tied back to one reference asset instead of
  drifting screen by screen.
- **Naming convention**: `Reservoir<Role>`, where role is a semantic purpose
  (`ReservoirBackground`, `ReservoirSurface`, `ReservoirAccent`,
  `ReservoirDeficit`), never a raw color name (`ReservoirTeal`,
  `ReservoirRed`). New screens should reuse an existing semantic role before
  proposing a new one.
- **Two-tier tokens for status colors.** A status like "deficit" gets two
  tokens, not one, because text and decoration have different contrast
  requirements:
  - A **text token** (e.g. `ReservoirDeficit`) used anywhere the color
    conveys information via text and must clear WCAG AA on its background.
  - A **decorative token** (e.g. `ReservoirDropletDeficit`) used only for
    large fills, icon glyphs, or gauge regions where looser contrast is
    acceptable, and which may reuse a lighter/brighter value than the text
    token would allow.
  - Do not substitute one for the other to save an asset — that's what
    caused the split in the first place.

## 2. Contrast requirements

- Any token used for **text** must meet WCAG AA (4.5:1) against every
  background/surface token it's plausibly painted on, in both light and
  dark appearance. Verify this whenever a new text token or new
  background/surface pairing is introduced.
- Decorative-only tokens (icon glyphs, gauge fills, backdrops) are exempt
  from the 4.5:1 bar but should still be checked for basic legibility against
  their backdrop.

## 3. Iconography

- Icons must represent the actual semantics of what they're attached to, not
  a generic category glyph. (E.g. a shopping-cart icon on every transaction
  row was wrong because not every transaction is a purchase — payroll
  deposits and transfers aren't "shopping.") Prefer direction/action glyphs
  derived from data already in the model (e.g. `arrow.down.right` /
  `arrow.up.right` from a transaction's signed amount) over a static icon set
  that has to be manually mapped per category.
- Status icons sit on a circular backdrop using the surface token for that
  status (e.g. deficit glyph on `ReservoirSurfaceDeficit`), tinted with that
  status's text token — this pairing (backdrop = surface token, glyph =
  text token) is the standard pattern for any future status-driven icon.

## 4. Data-driven visual elements (gauges, progress indicators)

- Prefer a formula derived from **existing persisted fields** over adding a
  new persisted "capacity"/"target" value purely to support a visual element.
  A new field is justified only when the visual accuracy gain clearly
  outweighs the added onboarding step and schema surface — default to no.
- Precedent: the Today screen fill-gauge uses
  `fillPercent = clamp(currentBalance / (7 * baseDailyAmount), -1, 1)` — a
  rolling window over an existing field — rather than a user-configured tank
  capacity. Reuse this "derive a reference window from an existing rate
  field" pattern before introducing a new settable constant.
- Any formula-driven visual value must clamp to a sane display range and
  define a floor/ceiling so it never renders as a false "empty" or "full"
  state when the underlying number is near zero or extreme — this is a
  correctness requirement, not polish, and needs a unit test covering the
  boundary and clamp/floor behavior (see `STANDARDS.md` §5 for general test
  standards).
- Animation on data-driven visual transitions is a Phase 2 nice-to-have, not
  required for initial delivery of a new visual element.

## 5. Definition of done addendum for visual/design-system work

In addition to `STANDARDS.md` §9, a visual change is done when:
- [ ] No hardcoded hex or `Color(...)` literals in view code — all colors
      come from named Asset Catalog color sets.
- [ ] No `colorScheme ==` branching used to select a color.
- [ ] Light and dark mode both verified (on-device or Xcode preview).
- [ ] Any new text token checked against WCAG AA (4.5:1) on every background
      it's used with, in both appearances.
- [ ] Any formula-driven visual value (gauge fill, progress bar, etc.) has a
      unit test covering its boundary/clamp/floor cases.
