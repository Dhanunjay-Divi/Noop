# Round 17 - Overnight calibration, Daily Effort, and grounded Coach

**Date:** 2026-08-24
**Status:** complete and locally verified

## Scope

This round closes four reliability gaps across Apple and Android:

1. A real overnight offload could persist PPG or other score-bearing history
   without advancing the visible calibration count.
2. Daily Effort needed a recovery-aware range and an optional notification
   without turning a wellness estimate into training clearance.
3. Coach context could blur unavailable nutrition data with an empty log and
   did not state bounded metric coverage.
4. Android metric education lacked the same specific interpretation and limits
   for several displayed values.

The uncommitted Round 16 cycle, age-metric reconciliation, imported Sleep
source, and Daily Signal sync work is retained in the same validated mainline
change.

## Product Contract

- Calibration advances only from persisted, score-bearing history. Heart rate
  derived from PPG participates in fingerprinting, and rows committed near
  timeout or disconnect remain durable work for a later scoring pass.
- Post-backfill analysis is bound to the immutable source revision that
  triggered it. A device switch, cancellation, transient failure, or process
  restart cannot silently discard the pending source.
- A completion watermark advances only after scoring and its required
  post-analysis work succeed. New commits during a pass produce one trailing
  pass instead of being lost or spawning unbounded work.
- Daily Effort is a personal 0-100 planning range derived only when current
  readiness, enough recent scored Effort, and a same-day self-check are
  available. Pain, feeling unwell, stale evidence, or missing evidence withhold
  the range.
- The Effort notification is disabled by default, requests permission only
  when enabled, describes only the current local calendar day, and fires at
  most once that day. It is a planning cue, not a limit or permission to train.
- Coach receives a typed evidence envelope. Missing values are unknown, failed
  reads are unavailable, and a successful empty nutrition read is an empty
  log. Coverage is distinct-day, bounded, and restricted to the stated
  calendar window.
- Personalized food discussion requires explicit logged intake and a
  user-stated goal. User text and dates are bounded before model context.
- Metric education states what each value is, why it matters, how to interpret
  it, what can affect it, its limitations, and a conservative next action.

## Implementation Map

- `WhoopStore/Reads.swift`, `WhoopStore/StreamStore.swift`, Apple
  `Backfiller`, `IntelligenceEngine`, and active-source tests
  - Include PPG-derived heart rate and every score-bearing stream in change
    detection; publish durable history revisions and re-arm forced rescoring.
- Android `Backfiller`, `WhoopBleClient`,
  `BackfillAnalysisRevisionLatch`, and `WhoopConnectionService`
  - Bind work to source revisions, coalesce commits, persist dirty sources,
    retry failures, recover cancellation, and resume after service recreation.
- `DailyEffortGuidance.swift` and `DailyEffortGuidance.kt`
  - Provide the shared unavailable/below/in-range/above contract.
- Apple and Android Daily Plan UI plus `StrainTargetNotifier`
  - Show current progress, expose the opt-in, route notifications to Today, and
    enforce current-day and once-per-day policy.
- `CoachEvidenceEnvelope.swift` and `CoachEvidenceEnvelope.kt`
  - Separate observations, planning cues, nutrition states, and evidence
    limits; sanitize user goals and nutrition dates.
- Apple and Android `AICoach`
  - Build the same bounded evidence context from consented local data.
- Android `MetricEducation`
  - Add specific localized education for average/maximum heart rate,
    calories/macronutrients, mood, and body/basal-body temperature.
- App-wide and Daily Plan localization generators
  - Produce 278 app-wide keys and 59 Daily Plan keys in all nine locales.
- `ios-tab-shell-visual-qa.sh`
  - Accept real 750x1334 iPhone SE captures and wait for the cold nutrition
    fixture state instead of recording a launch frame.

## Verification

- All nine Swift packages: **2,596 tests**, 0 failures, 2 intentional skips.
- StrandAnalytics: **1,360 tests**, 0 failures.
- macOS app suite: **1,410 tests**, 0 failures, 1 intentional skip.
- iOS generic simulator Debug build: **passed**.
- iOS production-shell suite: **21/21 tests passed**.
- iPhone SE and iPhone 14 Pro visual matrix: **40/40 scenarios
  validated**, including compact/current layouts, Dynamic Type, keyboard,
  contrast, and bottom reachability.
- Android Full Debug unit suite: **3,627 tests**, 0 failures, 6 skips.
- Android Full Debug APK and instrumentation-test compilation: **passed**.
- Android managed Pixel API 35 instrumentation: **4/4 passed**.
- Focused calibration/backfill runtime coverage includes PPG-only overnight
  advancement from `0/4` to `1/4`, delayed inserts, forced-rescore re-arming,
  active/re-added sources, device switching, cancellation, retry, and restart.
- App-wide localization: **278 keys in 9 locales**; Daily Plan:
  **59 keys in 9 locales**. Canonical generator reruns are idempotent.
- i18n regression gate: **passed** with no new baseline debt.
- Health-claims gate: **clear across 1,049 files**.
- Runtime legal inventory: **152 components and 3 container inputs verified**.
- The source-rights review recorded during this round was superseded by the
  2026-08-25 owner-controlled consolidation declaration.
- Hosted GitHub Actions did not execute. Push run `32784344944` and manual
  health-claims run `32784502269` both ended in `startup_failure` with no jobs;
  GitHub's existing job annotation identifies the account Actions budget as
  preventing further use.
- Private-data filename guard and ops-record validation: **passed**.
- `git diff --check`: **passed**.

## Calibration Answer

The calibration display is backed by scoring logic; it is not a timer or a
show-only counter. A qualifying persisted overnight session must produce a
canonical computed daily result before the count advances. The regression
suite now builds a PPG-only overnight session, runs the same backfill and
analysis path, and verifies the count changes from `0/4` to `1/4`.

This proves the software path for the synthetic persisted fixture. It does not
prove that a physical band delivered a complete night, that HealthKit or an
Android OEM kept the process alive, or that the resulting wellness score is
clinically accurate.

## Limitations

- No physical Noop Band/WHOOP 5/MG overnight, reconnect, haptic, background,
  battery, or HealthKit/Health Connect matrix was run in this round.
- Simulator and synthetic-fixture evidence does not establish sensor accuracy,
  sleep-stage accuracy, medical detection, or clinical safety.
- Daily Effort and Coach output are wellness planning support, not diagnosis,
  prescription, treatment, safety clearance, or emergency monitoring.
- Machine-translated copy still requires native-speaker review.
- NOOP's project license and independent dependency notices remain mandatory
  after the source-rights review was cleared.
