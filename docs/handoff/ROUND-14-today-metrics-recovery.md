# Round 14 - Today metrics and Recovery color

**Date:** 2026-08-23
**Status:** complete and locally verified

## Scope

This round closes two Today-screen regressions:

1. A Moderate Recovery score used a yellow base but sampled its highlight 18
   points higher, crossing into the green Primed range.
2. Key Metrics rendered only the saved three-to-five choices even though the
   product contract was to keep the complete metric catalog visible.

No scoring, health-data resolution, or persistence format changed.

## Product contract

- Today always renders all ten Key Metrics: Recovery, Effort, Sleep, HRV,
  Resting HR, Blood Oxygen, Respiratory, Steps, Weight, and Calories.
- The saved three-to-five preference is a **pin order**, not a visibility
  filter. Pinned metrics lead; every unpinned metric follows in canonical order.
- Recovery charts may use the continuous red-to-green scale. A gauge shown with
  a named state must use `recoveryGaugeColors`, which cannot cross into the next
  named state. Moderate therefore remains warm yellow through score 69.
- The Recovery hero and Recovery tile use the same score-state base color.
- The editor says pin/unpin and keeps its existing accessible three-to-five
  boundary. The stored key and encoded values remain backward compatible.

Apple and Android implement the same rules.

## Implementation map

- `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`
  - Adds the state-bounded gauge color pair.
- `Strand/Liquid/LiquidTodayView.swift`
  - Uses the bounded hero pair, state-colors the Recovery tile, and renders the
    complete catalog with pins first.
- `Strand/Screens/TodayView.swift`
  - Applies the same complete-catalog and Recovery-color behavior to classic
    Today.
- `Strand/Screens/KeyMetricsEditorSheet.swift`
  - Reframes selection as pinning and updates accessibility copy.
- `android/app/src/main/java/com/noop/ui/Theme.kt`
  - Mirrors the state-bounded Recovery color helper.
- `android/app/src/main/java/com/noop/ui/TodayScreen.kt`
  - Removes the collapsed metric subset and always renders the complete catalog.

The user-visible pin copy was updated in all existing Apple and Android locale
resources. It still requires the same native-speaker review expected for the
repository's broader localization baseline.

## Visual evidence

- [`round-14-recovery-moderate.png`](../assets/round-14-recovery-moderate.png)
  shows the clean Moderate yellow without a green tip.
- [`round-14-key-metrics-catalog.png`](../assets/round-14-key-metrics-catalog.png)
  shows all ten tiles in the two-column iPhone grid, with Recovery yellow and
  the saved core metrics first.

Both captures use the deterministic iPhone 17 Pro demo seed in Black mode.

## Verification

- StrandDesign package: **44 tests passed**.
- macOS app suite: **1,390 tests**, 0 failures, 1 intentional skip.
- iOS production-shell suite: **17 tests**, 0 failures.
- New focused iOS regressions: editor pin limits and complete ten-tile catalog,
  **2 tests passed**.
- Android Demo Debug unit suite: **passed**.
- Android focused palette and metric-order tests: **passed**.
- iOS Debug simulator build: **BUILD SUCCEEDED**.
- Apple String Catalog JSON, all Android string XML, and `git diff --check`:
  **passed**.

The first broad Apple attempt exhausted the disk while Xcode wrote diagnostic
archives. Generated temporary DerivedData was removed, then both full suites
were rerun against the incremental cache and produced valid passing result
bundles. This was an artifact-write failure, not a test failure.

## Continuation notes

- Do not replace `catalogOrder(startingWith:)` with the decoded pin list in a
  Today grid.
- Do not use `recoveryColor(score + offset)` for a state-labelled gauge.
- Add new metrics to the canonical catalog and descriptor map on both platforms;
  the complete-catalog tests should then be extended.
- Commercial distribution and physical-device/clinical validation remain
  governed by [`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md).
