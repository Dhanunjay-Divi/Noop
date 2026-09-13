# Apple UI Audit Content Follow-up

Date: 2026-09-13
Base: `f7baaddc0818b238b86962e60c5664eb6b746d34`
Branch: `codex/apple-ui-audit-content-20260913`

## Scope

- Recheck Apple/shared P1-1, P1-2, P1-3 and P2-1 through P2-16 from
  `/tmp/audit_shots/UI-AUDIT-REPORT.md`.
- Exclude P1-4 Trends loading/performance, Android sources, and
  `NOOPiOSUITests.swift`.
- Preserve metric thresholds, missing-data honesty, localization, and
  product-health safety.

## Findings

- The supplied base already contains the requested Recovery-band, Daily
  Signal, tab accessibility, digest, device, stress, Journal layout, NOOP+,
  Health copy, and Sleep naming remediations.
- Four Apple placeholders still used a raw hyphen instead of the shared
  missing-value token: three in the Health live-HR card and one in the
  Journal numeric field.
- The supplied macOS screenshot shows an older workout-coach sentence that is
  absent from this source. The current entry uses the unavailable-Recovery copy
  unless the selected day has its own scored Recovery; carried, calibrating,
  baseline-ready, and no-data states cannot select the scored copy.

## Changes

- Route the remaining Health and Journal placeholders through
  `StrandFormat.missing`.
- Extend focused source contracts to pin the missing token and the audited
  Recovery, Daily Signal, and workout-coach call sites.

## Intentionally unchanged

- P1-4 Trends loading/performance and `NOOPiOSUITests.swift` were excluded by
  the task.
- Android files remain untouched.
- Unreferenced legacy literal keys remain in the Apple string catalog, and
  legitimate `heart-rate strap`, `strap log`, and low-level protocol wording
  remains where it names a distinct device type or diagnostic artifact. The
  cited product UI no longer mounts the legacy Charge/strap copy; bulk-deleting
  translation history or renaming protocol terminology would add unrelated
  localization risk.

## Verification

- `xcodebuild` focused Apple/shared selection: 21 tests passed, 0 failures.
  This covered localization, Recovery presentation, Daily Signal copy,
  Dynamic Type/Large Content Viewer contracts, weekly digest presentation,
  Charge breakdown formatting, device naming, and the changed missing-value
  call sites.
- `LiquidChargeCarryTests/testOnlyTodaysOwnScoreCanShapeLiveSessionCopy`:
  1 test passed, 0 failures.
- `git diff --check`: passed.
- Scope check: no Android source, Trends implementation, or
  `NOOPiOSUITests.swift` change.
- Full suites were intentionally not run.
