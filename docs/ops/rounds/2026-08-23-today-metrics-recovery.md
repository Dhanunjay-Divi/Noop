# Round: 2026-08-23 - Today metric catalog and Recovery color

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `cc2bd676`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Correct the muddy or inconsistent Moderate Recovery yellow and restore the
complete Today metric catalog without making the screen feel crowded.

Success requires matching state-safe Recovery color on Apple and Android, all
ten existing metrics visible in a stable grid, saved user choices preserved as
priority pins, regression coverage, visual evidence, and an updated agent
handoff.

## Scope

### In scope

- Recovery gauge and tile presentation for named score states.
- Today Key Metrics visibility, ordering, copy, localization, and tests.
- Apple and Android parity.
- Simulator captures and operations documentation.

### Non-goals

- Scoring, calibration, health-data resolution, or medical logic changes.
- Persistence schema changes or resetting an existing user's metric choices.
- Physical band, BLE, HealthKit, background, haptic, or sensor validation.
- Signing, store release, or physical-device validation.

## Starting evidence

- A Moderate Recovery gauge sampled its highlight 18 score points above the
  actual score, allowing a yellow state to end with a green tip.
- Today treated the saved three-to-five metric preference as a visibility
  filter, leaving only Recovery, Effort, and Sleep on the default dashboard.
- The existing ten-metric descriptor catalog and user pin preference were
  already present on both platforms.
- The deterministic iPhone demo fixture supplied visual values and compact
  history traces for comparison.

## Delivered

- Added state-bounded Recovery gauge color pairs on Apple and Android.
  Continuous history charts retain the continuous semantic scale, while a
  named-state gauge cannot cross into the next state.
- Kept Moderate Recovery warm yellow through score 69 and made the Recovery
  hero and tile use the same state base color.
- Restored all ten Today tiles: Recovery, Effort, Sleep, HRV, Resting HR, Blood
  Oxygen, Respiratory, Steps, Weight, and Calories.
- Reframed the saved three-to-five preference as pins. Pins lead the grid in
  the user's order; the remaining catalog follows in stable canonical order.
- Removed Android's temporary collapsed/expanded metric subset.
- Updated editor copy and accessibility from select/show/hide to pin/unpin in
  every existing Apple and Android locale resource.
- Added stable tile accessibility identifiers and regression coverage for the
  full catalog, pin ordering, and Moderate Recovery color boundary.
- Added tracked simulator evidence under `docs/assets/` and updated the release
  and agent handoffs.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none. The existing
  `today.keyMetrics` encoded values remain valid and now determine priority,
  not visibility.
- Source/provenance or formula impact: presentation only; no score,
  calibration, baseline, or health formula changed.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. UI color and catalog
  visibility do not validate measurement accuracy or health interpretation.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandDesign package tests | 44/44 passed | Recovery state and color contracts pass in the shared Apple palette | Runtime rendering on every display |
| macOS app suite | 1,390 executed: 1,389 passed, 1 intentional skip, 0 failures | The broad Apple source and behavior graph remains green | iOS hardware or wearable behavior |
| iOS production-shell UI suite | 17/17 passed | The complete ten-tile Today catalog and existing production-shell workflows pass in the simulator | Physical-device layout, BLE, background, or haptic behavior |
| Focused iOS editor/catalog regressions | 2/2 passed | Pin boundaries and all ten stable tile identifiers are reachable | Every accessibility configuration |
| Android Demo Debug unit suite | Passed | Android compiles and its palette and metric-order contracts pass | OEM runtime or physical-device behavior |
| iOS Debug simulator build | `BUILD SUCCEEDED` | The updated app and localization graph compile | Signing or store acceptance |
| `jq empty Strand/Resources/Localizable.xcstrings`; Android XML validation | Passed | Updated localization files are structurally valid | Native-speaker approval |
| Tracked iPhone 17 Pro demo captures | Reviewed | Moderate is clean yellow and all ten tiles form a readable two-column grid | Production data or physical-sensor validity |
| `git diff --check` | Passed | The implementation diff is whitespace-clean | Behavioral correctness |

The first broad Apple attempts exhausted local disk while Xcode wrote result
diagnostics. Only generated temporary DerivedData was removed; both full suites
were rerun successfully with valid result bundles. The failed writes were not
test failures.

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: iPhone 17 Pro simulator on iOS 26.5.
- Data-preservation result: no device container or application data was
  mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: iOS and Android physical layouts, band sync,
  overnight collection, reconnect, HealthKit, background work, haptics, and
  battery behavior.

## Git and release state

- Changed paths: shared Apple palette, Apple Today/editor/localization/tests,
  Android palette/Today/preferences/localization/tests, tracked visual evidence,
  and handoff/ops documents.
- Commits: one direct-to-`main` implementation and documentation commit.
- Branch and remote state: local `main` will be pushed to canonical
  `origin/main`; exact parity is verified after the push.
- Repository visibility verified: private at the preceding authenticated
  repository audit.
- Version/build impact: no marketing version or build number change.
- Release or distribution impact: no artifact published. The source-rights
  review active during this round was cleared on 2026-08-25.

## Decisions

- Today always shows the complete metric catalog. Saved three-to-five choices
  are priority pins, not a visibility filter.
- Named Recovery states use state-bounded gauge color pairs; continuous charts
  may still use continuous interpolation.
- Decision-log entry: D-012.

## Open risks and honest limitations

- Simulator and unit evidence does not establish physical-band behavior,
  measurement accuracy, clinical safety, or regulatory readiness.
- The complete grid depends on descriptors remaining in parity with the
  canonical metric catalog; tests must expand when a metric is added.
- Updated locale copy remains subject to the repository's native-speaker
  review requirement.
- The current release gate still requires the owner-rights record, NOOP license,
  and exact independent dependency notices.

## Next round

1. Validate the current app on representative physical Apple and Android
   devices without resetting existing user data.
2. Continue localization review, physical wearable testing, accuracy studies,
   safety-provider staging, store signing, and release metadata only under
   their existing release gates.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
