# Today screen redesign — requirements

Status: ready for agent handoff, with one open decision flagged below (see "Open decision").
Supersedes: the Today screen visual treatment described in `PROJECT_SPEC.md`'s UX design section (data/layout decisions there are unchanged — this doc only changes color tokens, iconography, and adds the fill-gauge element).

## 1. Purpose

Replace the current default-iOS visual treatment (system blue accent, pure white/black surfaces, system red for negative amounts, shopping-cart glyph on every transaction row) with a treatment derived from the Reservoir app icon, and add a fill-gauge element that visually ties the hero number to the reservoir/tank metaphor the app is named for.

Source icon: `design_3_droplet` (droplet split into an unfilled upper region and a filled lower region by a waterline). Colors below are sampled directly from that asset.

## 2. Design tokens

Implement as **Asset Catalog color sets** (Any/Dark appearance variants), not runtime `colorScheme` branching — this is the idiomatic SwiftUI approach and keeps color logic out of view code. Suggested asset names in the `Reservoir` prefix column.

| Token | Asset name | Light | Dark | Usage |
|---|---|---|---|---|
| Page background | `ReservoirBackground` | `#F5FBF9` | `#0A2A36` | Today screen root background |
| Card surface | `ReservoirSurface` | `#FFFFFF` | `#123847` | Stat cards, neutral rows |
| Deficit surface | `ReservoirSurfaceDeficit` | `#FBEAE4` | `#3A241D` | "Remaining" card when negative, deficit icon bg |
| Accent pill surface | `ReservoirSurfaceAccent` | `#C7EEE4` | `#123847` | Active tab bar pill |
| Text primary | `ReservoirTextPrimary` | `#0A2A36` | `#EAF6F2` | Headings, hero label, row titles |
| Text secondary | `ReservoirTextSecondary` | `#5B7A78` | `#7FA39D` | Carry-forward subtitle, card labels |
| Text muted | `ReservoirTextMuted` | `#8A9C99` | `#5E827D` | Timestamps |
| Text/icon accent (teal) | `ReservoirAccent` | `#0A5C64` | `#3FA8A0` | Primary button fill, active tab icon/label |
| Text/icon deficit (terracotta) | `ReservoirDeficit` | `#993C1D` | `#E8967A` | Negative amounts, deficit icon glyph |
| Droplet track (unfilled) | `ReservoirDropletTrack` | `#F1DCD3` | `#3A2620` | Gauge background region |
| Droplet fill — healthy | `ReservoirDropletHealthy` | `#0A5C64` | `#3FA8A0` | Gauge fill when balance ≥ 0 |
| Droplet fill — deficit | `ReservoirDropletDeficit` | `#C65D3E` | `#E8967A` | Gauge fill when balance < 0 |
| Button label on accent | `ReservoirOnAccent` | `#FFFFFF` | `#0A2A36` | Text on the accent button (dark mode uses dark text on lighter teal per icon contrast) |

Note: `ReservoirDeficit` (text token, `#993C1D`/`#E8967A`) is used for all deficit *text* for AA contrast. `ReservoirDropletDeficit` (`#C65D3E` light / same `#E8967A` dark) is used only for the gauge fill and small icon glyphs, where contrast requirements are looser. Do not substitute one for the other.

## 3. Component specs

### 3.1 Hero fill-gauge (new element)
- A small droplet-shaped gauge (~24×28pt) sits to the left of the hero dollar amount.
- Shape: teardrop, matching the app icon's silhouette (rounded bottom, pointed top).
- Fill is a horizontal split: the bottom portion up to `fillPercent` uses the droplet-fill color (healthy or deficit per §2); the remainder uses `ReservoirDropletTrack`.
- `fillPercent` clamps to [0, 1] for rendering — see §4 for how it's computed.
- No animation required for MVP; instantaneous fill on data change is acceptable. Animating the fill level on transitions is a reasonable Phase 2 polish item, not required for this pass.

### 3.2 Hero number
- Font/size/weight unchanged from current implementation.
- Color: `ReservoirTextPrimary` when balance ≥ 0, `ReservoirDeficit` when balance < 0.
- Subtitle ("$X base + $Y carried forward") stays `ReservoirTextSecondary`, no other change.

### 3.3 Stat cards (Spent today / Remaining)
- Background: `ReservoirSurface` normally; `Remaining` card switches to `ReservoirSurfaceDeficit` when its value is negative.
- Label text: `ReservoirTextSecondary` normally; when a card is in deficit state, label uses a dimmed version of `ReservoirDeficit` (same token, no separate asset needed — SwiftUI's default text handles this via the existing card label style).
- Value text: `ReservoirTextPrimary` normally, `ReservoirDeficit` when negative.

### 3.4 Transaction rows
- Remove the shopping-cart glyph entirely — it misrepresents non-purchase transactions (payroll deposits, transfers, bank-initiated debits).
- Replace with a 30×30pt circular icon backdrop:
  - Debit (amount removes from balance): backdrop `ReservoirSurfaceDeficit`, glyph `arrow.down.right` (SF Symbol) or Tabler `ti-arrow-down-right` equivalent, tinted `ReservoirDeficit`.
  - Credit (amount adds to balance): backdrop `ReservoirSurfaceAccent`, glyph `arrow.up.right`, tinted `ReservoirAccent`.
- Direction is derived from the existing Plaid transaction amount sign already in the data model — no schema change needed.
- Row title/timestamp/amount text colors otherwise unchanged from current layout.

### 3.5 Primary button ("Add transaction")
- Background: `ReservoirAccent`. Label: `ReservoirOnAccent`.
- Corner radius, height, placement unchanged.

### 3.6 Tab bar
- Active tab ("Today"): icon + label tinted `ReservoirAccent`, sitting on a pill-shaped `ReservoirSurfaceAccent` background.
- Inactive tabs: icon + label tinted `ReservoirTextMuted`, no background.

## 4. Open decision — fill-gauge percentage source

**This must be resolved before Engineer builds §3.1.** The gauge needs a numeric `fillPercent` and none of the current data model fields define what "full" means.

**Recommendation:** define `fillPercent = clamp(currentBalance / (7 * baseDailyAmount), -1, 1)`, then map to a display value:
- If `currentBalance >= 0`: display fill = `min(fillPercent, 1.0)`, use healthy color.
- If `currentBalance < 0`: display fill = `min(abs(fillPercent), 1.0)`, use deficit color, with a floor of `0.06` so the gauge never renders fully empty (a zero-height fill reads as a rendering bug, not a data state).

Rationale: `7 * baseDailyAmount` (a week's worth of the current base daily rate) is derivable from existing fields with no new persistence, scales naturally as income/expenses change, and gives a meaningful reference point without asking the user to define an arbitrary "tank capacity" during onboarding. This can be promoted to a user-configurable constant in Settings in a later phase if the fixed 7-day window doesn't feel right in practice.

**Alternative considered and deprioritized:** a user-set "tank capacity" value at onboarding. More precise, but adds an onboarding step and a new persisted field for a visual-only feature — not worth the cost for MVP.

If you want a different basis (e.g., rolling 30-day average spend, or a fixed dollar ceiling), swap the denominator in the formula above; nothing else in this spec depends on which reference point you choose.

## 5. Definition of Done

- [ ] All six color tokens in §2 exist as Asset Catalog color sets with correct Any/Dark values, no hardcoded hex in view code.
- [ ] Fill-gauge renders on the Today screen, using the formula in §4 (or an explicitly approved alternative), with correct color switching at the zero-balance boundary.
- [ ] Shopping-cart glyph removed from all transaction rows; direction glyph correctly reflects Plaid transaction sign for every row in the current dataset.
- [ ] Light and dark mode both verified on-device (or via Xcode preview in both appearances) — no leftover system blue, system red, or pure black/white surfaces.
- [ ] Contrast check: `ReservoirDeficit` text on `ReservoirBackground`/`ReservoirSurface` meets WCAG AA (4.5:1) in both modes.
- [ ] Unit test on the `fillPercent` calculation covering: positive balance, negative balance, zero balance, and the display-floor behavior for large deficits.
- [ ] README updated per `STANDARDS.md`'s living-README requirement if this introduces new files/patterns worth documenting.

## 6. Sequencing

This is a visual-layer change only — no SwiftData schema changes, no new Plaid calls. It can be picked up any time after the Today screen exists per the build order in `PROJECT_SPEC.md`; it does not block or get blocked by Plaid integration work.
