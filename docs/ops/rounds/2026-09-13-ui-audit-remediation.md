# Round: 2026-09-13 - Cross-platform UI audit remediation

## Status

- State: `implementation and exact-current-tree local verification complete;
  all three consolidated hosted cycles reviewed and locally corrected; final
  hosted exact-SHA checks and protected integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `ca79cc9c76b194691f93e8f2334ce38200639bde`
- End implementation commit: `156937fc642980286355cb663b9f3840af7e4923`
- Record commit or PR: pull request `#15`

## Objective

Treat the read-only UI audit at commit `2efd5e89` as an acceptance gate for
the active product-safety-quality round. Close every actionable P1 and P2
finding across Apple and Android, with particular attention to Recovery
semantics, Dynamic Type, Trends loading and refresh reliability, missing-data
honesty, imported-sleep disclosure, current product vocabulary, and readable
Stress presentation.

The supplied NOOP, notification, and adaptive-day images are interaction
references only. They do not authorize copying third-party branding, copy,
assets, event details, fixed timing, or unsupported performance or clinical
claims.

## Scope

### In scope

- Recovery word, threshold, colour, and direction consistency.
- Daily Signal vocabulary independent of Recovery/readiness vocabulary.
- Dynamic Type, Large Content Viewer, TalkBack, and truncation behavior.
- Explicit Trends loading, success, partial-fallback, error, retry, refresh,
  cancellation, and imported-sleep states.
- Week-over-week comparisons with undefined zero baselines.
- Current user-facing Recovery and Noop Band terminology.
- Missing-value glyph, Stress denominator, and audited P2 presentation fixes.
- Focused and complete Apple/Android verification plus deterministic captures.

### Non-goals

- Changing Recovery formulas or threshold constants.
- Mixing imported provider scores into NOOP's locally computed sleep formula.
- Copying competitor notification text, branding, layouts, or imagery.
- Claiming physical-device background delivery, BLE, haptics, or collection
  reliability from simulator evidence.
- Enabling public traffic, real health-data transfer, or automatic medical
  inference.

## Starting evidence

- Audit report: private local read-only report retained outside the repository.
- Evidence set: 61 private local files beside the report; none are committed.
- Audit source commit: `2efd5e89999bd54b3fd6e316322b39d7e953ee8f`.
- Current branch base: the same audit source commit, plus the active isolated
  product-quality work.
- Initial focused Apple result on the current tree: 60 of 61 tests passed. The
  remaining failure proves a fixed 11-point font still exists in the iPhone
  tab-shell source.

## Delivered

- Closed all four P1 and all sixteen P2 findings in the private audit without
  changing pinned Recovery thresholds or mixing imported provider scores into
  NOOP's local sleep composite.
- Centralized Recovery word, colour, threshold, and direction presentation so
  Today, Calendar, Trends, and both phone implementations use one semantic
  contract. Daily Signal now keeps its own vocabulary instead of borrowing
  Recovery/readiness words.
- Replaced the fixed Apple tab-label size with Dynamic Type-aware typography and
  Large Content Viewer support. Android retains scalable labels with explicit
  ellipsis and TalkBack semantics instead of silent clipping.
- Added explicit Trends loading, loaded, partial-fallback, failure, retry,
  refresh, supersession, and cancellation states. Aggregate preparation is
  bounded and asynchronous so the screen does not present a blank canvas during
  a long calculation.
- Corrected malformed sub-one-percent deltas, directional chip treatment,
  imported-sleep disclosure, shared missing-value formatting, evidence-aware
  workout-coach copy, duplicate device subtitles, visible capability footnotes,
  labelled age, current Recovery/Noop Band vocabulary, Stress polarity and
  denominator readability, Charge-breakdown labels and units, Journal margins,
  NOOP+ benefit hierarchy, Health Monitor copy, and Sleep naming/tone.
- Added an adaptive collapsed planned-workout summary with accessibility-size
  vertical composition on both phones. Notification guidance remains concise,
  private, evidence-gated, optional, and neutral rather than copying the fixed
  times, branding, wording, or performance promise in the supplied references.
- Added the debug-only `--demo-daily-plan-collapsed` visual-QA state and
  generated an eleven-state deterministic iPhone matrix. The normal and
  accessibility collapsed-planned-workout captures were manually checked for
  clipping, overlap, hidden actions, and unstable layout.
- Integrated the audited Apple content correction, Android parity correction,
  bounded Trends preparation, and deterministic primary-tab test as commits
  `0672d6f8`, `80ca5875`, `c04ec57c`, and `d3da4e58` after the
  calibration/empty-state correction in `b37a0a3d`.
- Made additive DEBUG-fixture repair honor the caller's fixture-device key for
  both metric rows and profile markers. The regression test uses a neutral
  synthetic key, catches the prior hard-coded-key split, and passes
  idempotently.
- Excluded stale macOS WindowServer surfaces from evidence. A fresh window-only
  capture from the exact current build, kept outside Git, shows Recovery 34 as
  amber `Low`, Sleep 94, Effort 73, and the matching 34% Recovery key metric.
  Source, object, built-resource, fixture, and presentation tests establish the
  calibrating and unavailable-Recovery coach states that are not visible in
  that scored-state capture.
- Hosted head `48eec068` found one Apple tooltip and one Android
  workout-zone explanation outside the shared localization catalog. Both now
  use generated app-wide keys across all nine supported locales. The same
  hosted cycle required canonical Ruff formatting in two feedback tests; that
  formatting-only correction is included with this record.
- Pushed correction `6cd1a932` closed those findings. Hosted Android run
  `34736217114` then exposed a deterministic timing defect in the screenshot
  instrumentation test, not the product flow: the product keeps **Build
  report** disabled while explicit-opt-in capture is active and decodes the
  review preview asynchronously. The test now waits for both boundaries. Its
  focused path and the complete API 35 production shell pass locally with 95
  passes and two intentional private-pilot skips.
- Pushed correction `b3659ddc` passed the hosted server and Android matrices.
  Hosted Apple run `34736975319` built the macOS app and then found two stale
  test-only expectations: the committed generated catalog contains 728 keys,
  and the localized breathing haptic help is mounted by key rather than an
  English Swift literal. The corrected contracts pass focused tests and the
  complete local 1,919-test macOS suite with one expected external-fixture skip
  and zero failures.
- Hosted Apple run `34743871046` then built the complete iOS production shell
  and executed all 39 UI cases. Its only failures were six assertions
  concentrated in two test-harness paths: the report-snapshot switch was below
  the visible viewport when the test issued a raw tap, and the iOS 26 simulator
  starved XCTest's event-loop observer after four consecutive measured scroll
  round trips. The product report flow, Today rendering, and scroll gestures
  completed before those assertions failed.
- The UI harness now scrolls interactive report controls into a hittable
  position, taps the visible trailing switch control, waits for review/removal
  state transitions, and uses three simulator process-metric iterations while
  retaining five scrolling-signpost iterations on physical devices. Both
  corrected paths pass together, and the complete exact-current-tree iPhone UI
  suite passes 39 tests with one intentional private-pilot skip and zero
  failures.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: display and loading-state changes only;
  imported sleep remains disclosed and excluded from NOOP's local composite.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: guidance remains optional,
  private, evidence-gated, non-prescriptive, and cannot imply sleep-apnea,
  disease, emergency, or optimal-performance detection.

## Observability

- Apple and Android Trends aggregate and digest preparation use bounded
  `AppDiagnosticsRecorder` operation spans.
- The spans distinguish completed, canceled, superseded, and failed
  preparation without recording dates, metric values, source identifiers,
  exception strings, or user content.
- User-visible error and retry states are deterministic. Physical-device
  collection and OS background behavior remain outside this UI evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Audit acceptance matrix | 20 of 20 actionable findings closed: 4 P1 and 16 P2 | Every reported misleading, inaccessible, blank, duplicated, malformed, or inconsistent state has a scoped cross-platform correction | That subjective redesign suggestions or external hardware behavior are complete |
| Shared analytics | 1,479 tests passed | Recovery, Daily Signal, adaptive-day, planned-workout, and formatting contracts pass together | Clinical validity or individual physiology |
| Complete Apple app suite | 1,919 tests passed, one external Xiaomi-fixture skip, zero failures | Current macOS/Apple source, persistence, UI contracts, accessibility, guidance, diagnostics, and lifecycle behavior pass together | Physical iOS background execution, BLE, haptics, or notification presentation |
| Complete iPhone UI suite | The final exact-current-tree run executed 39 tests with one intentional private-pilot skip and zero failures. Its three-iteration simulator Today-scroll sample averaged 5.286 seconds, CPU 0.157 seconds, and about 38.9 MB peak physical memory. The prior complete run and three isolated five-iteration runs also passed; those independent samples averaged 5.313 and 5.099 seconds respectively. | Current simulator navigation, reporting, accessibility, loading, planner, and scrolling paths are responsive and reachable, and the fixed swipe workload remains repeatable across independent launches | VoiceOver traversal, physical-device frame pacing, thermal pressure, or memory pressure |
| Android exact-source matrix | Full and Demo unit suites, both lint variants, both APK assemblies, and both instrumentation Kotlin compilations passed; Gradle finished 137 tasks successfully. The authoritative final API 35 XML records 97 production-shell cases with 95 passes, two intentional private-pilot skips, and zero failures. | Both Android variants compile and retain the matched UI, accessibility, loading, privacy, screenshot-consent, and guidance contracts | OEM rendering, TalkBack traversal, background delivery, or signed physical installs |
| Additive demo-fixture repair | `AppleDemoSeederTests` executed 6 tests with zero failures after the repair was changed to use a caller-supplied synthetic device key | Existing screenshot databases receive missing age series and profile markers on one coherent device namespace, and a second repair is idempotent | Participant data migration, physical collection, or non-DEBUG runtime behavior |
| Deterministic visual captures | Eleven nonblank iPhone states generated; collapsed planned-workout normal and accessibility captures manually reviewed. A fresh window-only exact-build macOS capture shows Recovery 34 as amber `Low`, Sleep 94, Effort 73, and the matching 34% Recovery key metric. | Current planner states preserve hierarchy, readable text, and stable controls at tested simulator sizes; the current scored macOS Today state agrees across hero and key metric. | Calibrating-state macOS rendering, physical display behavior, or hardware |
| Repository policy wall | After the first hosted-head correction, feedback localization, differential and full strict i18n, Ruff check and format, 230 Tools tests, 57 operations records, the 1,246-file health-claims scan, calibration parity, private-data, terminology, required-CI, release-control, legal, distribution, and diff gates pass locally | The implementation remains localized, canonically formatted, claim-bounded, privacy-checked, and release-controlled | Corrected hosted exact-SHA status or legal/clinical approval |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: simulators and local macOS only
- Data-preservation result: no participant or owner health data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical collection, background execution, BLE,
  haptics, battery, notification timing, and wearable firmware behavior

## Git and release state

- Changed paths: shared Apple/Android presentation, Trends lifecycle,
  notification/guidance copy, accessibility, localization, visual-QA tooling,
  focused tests, and these operations records
- Commits: implementation `156937fc`; first consolidated record head
  `48eec068`; pushed i18n/Ruff correction `6cd1a932`; pushed server/Android
  correction `b3659ddc`; Apple contract correction `f7baaddc`; calibration and
  empty-state correction `b37a0a3d`; Apple content correction `0672d6f8`;
  Android parity correction `80ca5875`; bounded Trends preparation
  `c04ec57c`; deterministic tab test `d3da4e58`; fixture/policy/record closeout
  included in this final local commit
- Branch and remote state: isolated pull request `#15`; hosted head `d8d0c315`
  passes every required job except Apple, where run `34743871046` built the
  complete iOS shell and exposed only the two deterministic UI-harness defects
  recorded above. The corrected focused and complete local UI suites pass;
  final exact-SHA checks and protected integration remain required.
- Repository visibility verified: not changed by this round
- Version/build impact: no schema or marketing-version change
- Release or distribution impact: no artifact released

## Decisions

- Durable decision added or changed: the UI audit is a release acceptance gate;
  Recovery semantics, missing-data truth, loading/error behavior, accessibility,
  and current product terminology must agree across Apple and Android before
  protected integration.
- Decision-log entry: no new global decision number; this applies the existing
  parity, local-first, medical-truth, observability, and protected-release
  contracts.

## Open risks and honest limitations

- Android physical TalkBack, process-death, and Room failure behavior cannot be
  claimed from source and JVM tests alone.
- Apple physical VoiceOver, background execution, notification presentation,
  BLE, haptics, battery, and memory-pressure behavior remain external.
- The stale macOS WindowServer capture cannot prove the current Today surface;
  it is retained only as tooling evidence and will not be shipped or cited as a
  product result.
- Protected exact-head checks and normal PR integration remain required after
  the local verification wall.

## Next round

1. Create the bounded replacement commit, push once, require fresh hosted
   exact-SHA checks, and integrate through the normal protected path.
2. Run the recorded VoiceOver/TalkBack, background, BLE, notification, haptic,
   battery, and memory-pressure matrix on representative signed physical builds.

## Privacy check

- [x] Private audit images and absolute owner paths are not committed.
- [x] No credentials, health values, raw sensor data, dynamic identifiers, or
      arbitrary exception text are added to diagnostics.
