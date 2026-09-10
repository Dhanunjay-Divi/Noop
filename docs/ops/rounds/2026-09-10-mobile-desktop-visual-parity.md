# Round: 2026-09-10 - Mobile and desktop Today visual parity

## Status

- State: `implementation complete and locally verified; protected integration pending`
- Owner: project team
- Branch: `codex/mobile-desktop-visual-parity-20260910`
- Start commit: `beb0e88f70141766c32a0bcd270f5f8889c6f10d`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Use the approved desktop Today screen as the visual reference for both phone
apps while preserving mobile navigation, touch ergonomics, accessibility, and
all existing data behavior. Success requires one quiet obsidian canvas, a
single dominant Daily Signal hierarchy with integrated Fitness Age, compact
secondary rows, matched iOS and Android screenshots, and clean platform builds.

## Scope

### In scope

- Align the iOS and Android Today masthead, Daily Signal surface, spacing,
  surface treatment, and immediate post-hero hierarchy with the desktop
  reference.
- Reuse the existing static obsidian background and semantic status colors.
- Preserve mobile bottom navigation, day gestures, accessibility labels,
  section ordering, metric navigation, and responsive layout.
- Capture matched simulator/emulator evidence and run focused plus app build
  gates.

### Non-goals

- Change metric formulas, source selection, calibration, storage, sync, BLE,
  notification, account, cloud, or health-data behavior.
- Claim physical-device frame pacing, background collection, haptics, battery,
  or sensor correctness from simulator evidence.
- Redesign every app screen in this one reviewable change.

## Starting evidence

- Reproduction or observed symptom: the current desktop Today hierarchy was
  explicitly preferred over the busier mobile style.
- Relevant source/device/OS/firmware class: shared Apple Today implementation
  and Android Compose Today implementation; simulator/emulator evidence only.
- Existing tests, logs, exports, screenshots, or documents: the provided
  desktop screenshot, existing iOS Today screenshot harness, retained-screen
  performance tests, and bounded `ui.scroll.summary` diagnostics.
- Unknowns that must remain unknown until measured: physical OLED appearance,
  OEM rendering differences, physical-device frame pacing, and accessibility
  behavior outside the tested simulator matrix.

## Delivered

- Apple and Android phone Today now preserve the desktop reference's dense
  first-viewport hierarchy: compact masthead, one dominant Daily Signal
  surface, centered Recovery instrument, paired Sleep and Effort satellites,
  integrated Fitness Age, and the workout-coach row immediately below.
- Fixed-format score instruments scale down together on ordinary phone text
  sizes, while large Dynamic Type keeps the roomier dimensions so labels do
  not clip.
- The narrow Daily Signal header keeps the status beside the title and moves
  provenance to a quieter trailing line. Wider layouts retain the established
  single-row presentation.
- Card radius, padding, spacing, weather control dimensions, and shadow depth
  now match across the two phone implementations without changing source
  selection, formulas, navigation, gestures, accessibility labels, or stored
  data.
- Matched synthetic Today captures were reviewed at 1080 x 2400 on Android and
  1170 x 2532 on iOS. Both preserve native system chrome and mobile navigation
  while using the desktop visual hierarchy.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: visual hierarchy only; no
  metric or medical behavior is validated by this work.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `ui.scroll.summary`, severe-hitch reporting, app build logs, UI-test
  screenshots, and accessibility identifiers.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes static composition and styling without adding a new fallible
  operation or state transition.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  simulator/emulator screenshots, source contract tests, and app build gates.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: screenshots use synthetic
  fixtures; diagnostics retain no health values, identifiers, payloads, or
  user-authored content.
- Cross-platform/backend correlation: backend correlation is not applicable to
  a local visual-only change; Apple and Android evidence will be paired.
- Remaining blind spots: physical devices and hardware-dependent behavior.

## Evidence

Record exact commands and results. Distinguish unit, integration, simulator,
physical-device, and external-service evidence.

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source preflight | Desktop reference and both Today implementations inspected | Existing hierarchy and parity points are understood before edits | Final appearance or device performance |
| Android focused and app gates | `:app:assembleFullDebug`, `:app:lintFullDebug`, `:app:compileFullDebugAndroidTestKotlin`, and 19 focused Today/performance contracts passed in one Gradle invocation | The full Android variant compiles, lint is clean, instrumentation sources compile, and the retained-screen/runtime/Today source contracts still hold | Physical-device frame pacing, OEM rendering, collection, or BLE behavior |
| Apple focused contracts | 80 tests across `TodayExplainabilityTests`, `TodayHeroRingLayoutTests`, `LiquidTodayFeatureMountTests`, and `RetainedScreenPerformanceContractTests` passed with zero failures or skips | The shared Today source retains its explainability, layout, feature-mount, and retained-screen contracts | iOS-only runtime behavior or physical-device smoothness |
| iOS app build | `NOOPiOS` built for an arm64 iOS 26.5 simulator with signing disabled after regenerating the ignored XcodeGen project from `project.yml` | The changed shared Swift source and complete iOS dependency graph compile together | Signing, installation on a physical phone, or store acceptance |
| Android runtime capture | Demo Today route launched on an isolated API 35 arm64 emulator; 1080 x 2400 screenshot reviewed; captured error log contained no NOOP fatal exception or ANR | The current APK renders the intended hierarchy and remains running in the exercised synthetic state | Physical OLED appearance, OEM variance, sensor data, or sustained frame pacing |
| iOS runtime capture | Synthetic Today route launched on an iOS 26.5 phone simulator; 1170 x 2532 screenshot reviewed | The current iOS app renders the intended hierarchy at phone size | Physical-device frame pacing, background execution, BLE, battery, or haptics |
| Visual parity review | Desktop, Android, and iOS first viewports compared directly | Both phones share the approved hierarchy, visual weight, section order, and compact score geometry while preserving native chrome | Pixel identity across rendering engines or every non-Today screen |
| Terminology snapshot review | Regenerated inventory retains 17,367 classified occurrences across 1,511 groups with identical category totals, a byte-identical active allowlist, and zero forbidden mappings; only source line locations changed | The UI edit introduces no new or modified active customer/core legacy terminology and the fail-closed inventory matches the source tree | Independent provenance review of pre-existing compatibility terminology |
| Repository policy matrix | All 227 Tools tests passed; required CI verified 5 conditional workflows, 5 universal workflows, and 10 contexts; 9 release controls, 12-metric calibration parity, no-new-copy localization, 1,203-file health-claims scan, 230-component legal inventory, distribution provenance, private-data, 50 operations records, terminology, and diff checks passed | The exact local tree preserves release, metric, localization, claims, provenance, privacy, and durable-evidence contracts | Hosted exact-SHA checks, external legal approval, or physical behavior |
| Resource cleanup | Isolated API 35 emulator stopped, Gradle daemon stopped, temporary AVD root removed, and both temporary DerivedData roots removed; no Android emulator remains attached | Temporary runtime and build resources created by this round are no longer consuming device or daemon resources | Pre-existing repository build products or unrelated user resources |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no persistence changes
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device and band-dependent scenarios

## Git and release state

- Changed paths: `Strand/Liquid/LiquidTodayView.swift`,
  `android/app/src/main/java/com/noop/ui/TodayScreen.kt`,
  `release/terminology/legacy-inventory.json`,
  `Tools/required-ci-gate.py`, this record, `docs/ops/rounds/INDEX.md`, and
  `docs/ops/ACTIVE.md`
- Commits: pending
- Branch and remote state: local branch from exact protected `main`; push and
  hosted checks pending
- Repository visibility verified: standalone GitHub repository relationship
  inherited from the current active handoff; exact protected integration
  remains pending
- Version/build impact: no version change
- Release or distribution impact: no artifact published

## Decisions

- Durable decision added or changed: desktop Today is the shared visual
  reference while mobile platform navigation and ergonomics remain native.
- Decision-log entry: none; the existing architecture already defines the
  macOS app as the reference implementation and this round applies that rule
  to one screen.

## Open risks and honest limitations

- A matched simulator/emulator image does not establish physical-device
  smoothness or sensor reliability.
- The wider mobile screen audit remains a separate checklist item; this round
  does not claim that every non-Today screen matches the desktop visual
  language.
- The iOS simulator fixture was still calibrating while the Android fixture
  contained scored values. That difference validates responsive content
  states, not numerical parity between fixtures.

## Next round

1. Extend the approved visual language to the next highest-traffic mobile
   surface after this focused Today change is reviewed.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
