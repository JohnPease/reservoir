# Foldable layout designs (reservoir-h2k)

Static HTML mockups (open them in a browser) with full-page PNG renders beside each (`layouts.png`,
`concepts.png`, rendered at 2x in dark mode). All figures on the pages are examples.

- `layouts.html`: Today drawn for the foldable's cover (466 x 678 pt) and inner (626 x 890 pt) displays in
  portrait and landscape, with the layout rules. This is the design the adaptive layouts follow.
- `concepts.html`: four further concepts (the tank, the month strip, now and next, the ledger spread).
  Only the month strip was built (Plans tab); the other three are unbuilt ideas.

Not built from `layouts.html`: the side rail replacing the tab bar in wide landscape.

The shipped layout rule is `ScreenLayout` (`Reservoir/Shared/ScreenLayout.swift`); see the README section
"Wide screens, landscape and the month strip".
