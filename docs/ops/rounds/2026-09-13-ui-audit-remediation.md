# Round: 2026-09-13 - Cross-platform UI audit remediation

## Status

- State: `historical UI-audit implementation complete; its late residuals and
  review corrections passed the exact-current Apple, Android, and server
  product walls and repository policy wall in the PR 15 data-integrity round;
  staged review, replacement hosted checks, and protected integration remain
  pending`
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
- A fresh independent reconciliation after the first closeout found three
  residual mounted-surface defects: Recovery banding used the raw decimal while
  the UI showed a rounded integer, two Apple log headings still said `STRAP
  LOG`, and classic Today rendered missing HRV as `- ms`. Recovery presentation
  now classifies the same rounded integer it displays on Apple and Android, the
  mounted headings use the existing localized `BAND LOG` key, and missing HRV
  uses the shared em-dash token. Boundary and source-contract tests pin all
  three corrections.
- Historical release-note entries retain the terminology that shipped in those
  releases. They remain an explicit non-goal of the terminology closeout and
  are not treated as current mounted product vocabulary.
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
- Excluded stale macOS WindowServer surfaces from evidence. A later
  source-to-capture reconciliation also excluded the earlier scored-state
  capture that showed Recovery 34 as `Low`: the pinned scoring engine defines
  values below 34 as Low and 34 through 66 as Steady. Current Apple and Android
  boundary tests agree with that engine contract. The retained exact-current
  window-only capture proves the unavailable-Recovery coach state: it is
  neutral, asks the user to connect and wear a band, and does not promise that
  missing Recovery guides the session.
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
  focused path passed. The final exact-current API 35 production shell now
  records 103 passes, two intentional private-pilot skips, and zero failures.
- Pushed correction `b3659ddc` passed the hosted server and Android matrices.
  Hosted Apple run `34736975319` built the macOS app and then found two stale
  test-only expectations: the committed generated catalog contains 728 keys,
  and the localized breathing haptic help is mounted by key rather than an
  English Swift literal. The corrected contracts pass focused tests and the
  final exact-current 1,988-test macOS suite with 1,987 passes, one expected
  external-fixture skip, and zero failures.
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
- Exact hosted head `0aa7c86c` passed all 35 executed checks with three
  intentional skips. Branch protection then correctly withheld merge because
  twelve review conversations remained unresolved. Their findings cover
  historical-day hydration timestamps, cross-day hydration failure state,
  Apple hydration bounds and BMI confirmation, feedback startup retry,
  Android operational startup and settings-restore failure handling,
  analysis-claim progress, Trends timeout cancellation, Safety migration
  expand/rollback compatibility, feedback object retention, and
  account-scoped managed-document generation. These are treated as release
  defects, not administratively resolved.
- The final source-to-reference pass also found three defects outside the
  original twenty-item matrix. Android's Coupled surface still had one raw
  missing token and one hard-coded Sleep label; the notification capacity
  selector could evict hydration phone fallbacks; and morning recap
  eligibility ignored quiet hours. The mounted Android strings now use the
  shared missing token and localized Sleep key, hydration fallback occurrences
  retain capacity priority, and morning recaps suppress with bounded
  categorical evidence during quiet hours before becoming eligible later.
- One new morning-recap test initially inspected only the latest bounded-ledger
  item even though an earlier valid suppression remained in the ledger. The
  assertion was corrected to inspect the matching bounded event rather than
  weakening product behavior; the focused rerun passed.

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
| Fresh residual presentation checks | Apple `ScreenStateContractTests` and `WeeklyDigestChipStyleTests`: 22 passed; Android `RecoveryBandPresentationTest`: Full and Demo passed | Display rounding and Recovery banding agree at both 34 and 67 boundaries; mounted Apple log labels and missing HRV remain corrected | Physical-device rendering or accessibility traversal |
| Shared analytics | 1,479 tests passed | Recovery, Daily Signal, adaptive-day, planned-workout, and formatting contracts pass together | Clinical validity or individual physiology |
| Complete Apple app suite | 1,988 tests total: 1,987 passed, one external Xiaomi-fixture skip, and zero failures | Current macOS/Apple source, persistence, UI contracts, accessibility, guidance, diagnostics, and lifecycle behavior pass together | Physical iOS background execution, BLE, haptics, or notification presentation |
| Complete iPhone UI suite | The final exact-current-tree run executed 39 tests with 38 passes, one intentional private-pilot skip, and zero failures. Its three-iteration simulator Today-scroll sample averaged 4.487 seconds, CPU 0.152 seconds, and about 65.4 MiB peak physical memory. | Current simulator navigation, reporting, accessibility, loading, planner, and scrolling paths are responsive and reachable, and the fixed swipe workload remains repeatable across one measured launch | VoiceOver traversal, physical-device frame pacing, thermal pressure, memory pressure, or a production performance baseline |
| Android exact-source matrix | Full and Demo each executed 4,742 unit cases with 4,735 passes, seven intentional skips, and zero failures/errors; both lint variants, both APK assemblies, and both instrumentation Kotlin compilations passed in a 137-task wall. The authoritative API 35 XML records 107 production-shell cases with 105 passes, two intentional private-pilot skips, and zero failures/errors. | Both Android variants compile and retain the matched UI, accessibility, loading, privacy, screenshot-consent, guidance, and production scheduler graph contracts | OEM rendering, TalkBack traversal, process-death recovery, background delivery, or signed physical installs |
| Additive demo-fixture repair | `AppleDemoSeederTests` executed 6 tests with zero failures after the repair was changed to use a caller-supplied synthetic device key | Existing screenshot databases receive missing age series and profile markers on one coherent device namespace, and a second repair is idempotent | Participant data migration, physical collection, or non-DEBUG runtime behavior |
| Deterministic visual captures | Eleven nonblank iPhone states generated; collapsed planned-workout normal and accessibility captures manually reviewed. The retained exact-current window-only macOS capture shows a neutral unavailable-Recovery state and the evidence-aware connect-and-wear-band coach row. | Current planner states preserve hierarchy, readable text, and stable controls at tested simulator sizes; the mounted unavailable-Recovery coach copy does not claim a missing score guides the session. | Scored-state physical rendering, accessibility traversal, or hardware behavior |
| Repository policy wall | Feedback localization for 86 strings across nine locales, whole-tree i18n, 230 Tools tests, 49 top-level i18n tests, the 1,252-file health-claims scan, calibration parity, private-data, 17,631 classified terminology occurrences with zero forbidden mappings, required-CI, release-control, legal/distribution, 109 tracked JSON files, syntax for 27 shell scripts, ShellCheck for 25 POSIX/bash scripts, Actionlint, Ruff over 81 server files, 64 operations records, 12 OpenTofu tests, and diff gates pass on the final tree | The implementation remains localized, canonically formatted, claim-bounded, privacy-checked, and release-controlled | Corrected hosted exact-SHA status or legal/clinical approval |

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
- Branch and remote state: isolated pull request `#15`; its remote head remains
  historical. The corrected exact-current local Apple, Android, and server
  product walls and repository policy wall pass; staged review, one
  consolidated replacement push, fresh exact-SHA checks, and protected
  integration remain required.
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
- Stale macOS WindowServer and pre-boundary-correction scored-state captures
  cannot prove the current Today surface; they are retained only as tooling
  evidence and will not be shipped or cited as product results.
- The late review and residual UI findings passed the exact-current local wall
  recorded in `2026-09-13-pr15-late-data-integrity-review.md`. One consolidated
  replacement push, fresh exact-head checks, and normal PR integration remain.

## Next round

1. Push the locally verified replacement head once, require fresh hosted
   exact-SHA checks, resolve only demonstrably addressed conversations, and
   integrate through the normal protected path.
2. Run the recorded VoiceOver/TalkBack, background, BLE, notification, haptic,
   battery, and memory-pressure matrix on representative signed physical builds.

## Privacy check

- [x] Private audit images and absolute owner paths are not committed.
- [x] No credentials, health values, raw sensor data, dynamic identifiers, or
      arbitrary exception text are added to diagnostics.
