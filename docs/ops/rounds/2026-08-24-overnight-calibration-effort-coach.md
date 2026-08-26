# Round: 2026-08-24 - Overnight calibration, Daily Effort, and grounded Coach

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `c5b771fd`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Make overnight calibration advance from durable score-bearing history, add a
conservative recovery-aware Daily Effort experience, ground Coach in bounded
local evidence, complete metric education parity, and verify the accumulated
Apple/Android work before consolidating it on canonical `main`.

## Scope

### In scope

- Apple and Android scoring fingerprints, post-backfill analysis, source
  binding, cancellation, retry, and restart behavior.
- Shared Daily Effort range/progress semantics and opt-in notifications.
- Typed Coach evidence, nutrition availability, coverage, and prompt bounds.
- Android metric education parity.
- App-wide/Daily Plan localization, compact-device visual QA, builds, tests,
  safety/legal gates, and durable handoff.
- Preservation and validation of the uncommitted Round 16 work.

### Non-goals

- Clinical validation, medical detection, diagnosis, treatment, emergency
  monitoring, or training clearance.
- Physical-device BLE, overnight, background, haptic, battery, or accuracy
  validation.
- Store signing, public release, or changing NOOP's license and dependency
  inventory.

## Starting evidence

- A persisted PPG-only night could fail to change the scoring fingerprint, so
  calibration could remain at `0/4`.
- A timeout, disconnect, new commit during analysis, device switch, transient
  failure, or service restart could leave post-backfill work without a durable,
  source-bound retry path.
- The existing Effort target notification trusted the supplied row day as
  today, allowing a historical row to satisfy notification policy.
- Coach could render a failed nutrition read as though the user had no entries,
  and its coverage count was not a strict distinct-day calendar window.
- Several Android metric detail routes reused generic explanations.
- The visual harness rejected valid 750x1334 iPhone SE images and could capture
  its first cold-seed launch frame before the fixture was ready.

## Delivered

- Included PPG-derived HR, R-R, gravity, respiration, skin temperature, SpO2,
  steps, sleep state, events, and waveform history in score-bearing change
  detection and persisted-history publication.
- Re-armed forced analysis after delayed durable inserts and ensured active or
  re-added source history writes to the canonical computed source.
- Added an Android source-revision queue with one worker owner, per-source
  coalescing, bounded exponential retry, durable pending-source storage,
  cancellation recovery, and service-start resume.
- Kept fingerprint watermarks success-only and ran dependent report, workout,
  and optional Health Connect work before the pass is considered complete.
- Added shared Daily Effort guidance states and current progress UI. The
  planner withholds the range for stale/thin evidence, missing same-day
  self-check, or recovery/unwell states.
- Made the Daily Effort notification explicit opt-in, current-local-day only,
  at most once daily, localized, and routed to Today.
- Added a typed Coach evidence envelope that separates observed facts,
  planning cues, unavailable/empty/observed nutrition, and evidence limits.
  Distinct-day coverage excludes duplicate, future, and out-of-window rows.
- Sanitized user nutrition goals and malformed date fields before model
  context, and prevented missing values from becoming zero or invented trends.
- Added specific localized Android education for heart-rate summaries,
  nutrition totals, mood, and body/basal-body temperature.
- Expanded generated app-wide copy to 278 keys and Daily Plan copy to 59 keys,
  each with exact nine-locale parity. Removed prohibited em dashes from the new
  Russian strings.
- Restored one measured scroll-content margin for the floating iPhone bar so
  final content remains reachable without opaque page bands.
- Updated visual QA to support true iPhone SE pixel dimensions and to wait for
  the first cold nutrition fixture to report `mixed=true`.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: no app container, profile, cycle log,
  biometric history, workout, nutrition, or device registration is deleted.
- Source/provenance impact: imported and measured source identity remains
  intact. Canonical NOOP-computed outputs remain separate.
- Permissions/network impact: notification authorization is requested only
  when the user enables the Effort nudge. Coach still requires its existing
  consent and sends bounded text, not raw sensor streams.
- Health claim impact: Daily Effort and Coach explicitly remain wellness
  planning aids. Missing data is unknown, and neither path grants clearance,
  diagnoses, changes medication, or prescribes supplements.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Nine Swift packages | 2,596 tests, 0 failures, 2 skips | Shared protocol, storage, analytics, import, design, and sync contracts pass | Hardware or clinical validity |
| StrandAnalytics | 1,360 tests passed | Shared guidance, evidence, cycle, and analytics contracts pass | Participant accuracy |
| macOS app suite | 1,410 tests, 0 failures, 1 skip | Broad Apple app graph and source contracts pass | iPhone hardware behavior |
| Generic iOS simulator build | Passed | Final Apple source/resources compile | Signing or App Review |
| iOS production-shell suite | 21/21 tests passed | Navigation and UI automation on production shell | Physical phone behavior |
| SE and 14 Pro visual matrix | 40/40 scenarios validated | Compact/current layouts, Dynamic Type, keyboard, contrast, bottom reachability | Every device or assistive setting |
| Android Full Debug unit suite | 3,627 tests, 0 failures, 6 skips | Broad Android source, retry, localization, and UI contracts pass | OEM runtime behavior |
| Android Full Debug APK and androidTest compile | Passed | Final app and instrumentation source assemble | Play signing |
| Managed Pixel API 35 | 4/4 passed | Production-shell instrumentation executes | Physical OEM behavior |
| Localization generators | 278 app-wide and 59 Daily Plan keys, nine locales, stable rerun | Generated parity and reproducibility | Translation quality |
| i18n gate | Passed; no new debt | No baseline regression | Baseline debt is resolved |
| Health-claims gate | Clear across 1,049 files | Prohibited release claims were not introduced | Regulatory approval |
| Legal inventory | 152 runtime components and 3 container inputs verified | Runtime dependency inventory remains exact | Signing, store, or physical-device readiness |
| Distribution gate | Current gate passes under the 2026-08-25 NOOP owner declaration | The NOOP license, owner record, and dependency notices are coherent | Current signing, store, or physical-device readiness |
| Hosted GitHub Actions | No job scheduled; push run `32784344944` and manual run `32784502269` ended in `startup_failure` because the account Actions budget prevents further use | The hosted failure is external to test execution | Hosted CI passes |
| Private-data and ops gates | Passed | No tracked private filename and valid round structure | Full privacy audit |
| `git diff --check` | Passed | Whitespace-clean final diff | Runtime behavior |

## Physical device and deployment

- Install/update action: not run.
- Devices exercised: Apple simulators and Android managed Pixel API 35 only.
- Data preservation: no physical app container or band data was touched.
- Unrun hardware gates: overnight Noop Band/WHOOP 5/MG offload, reconnect,
  HealthKit/Health Connect device reads, background collection, haptics, battery,
  Android OEM behavior, and accuracy studies.

## Git and release state

- Changed paths: shared analytics/storage, Apple and Android app logic/UI,
  localization, test harnesses, tests, and operations/handoff records.
- Commits: one reviewed direct-to-`main` consolidation commit.
- Version/build impact: no marketing version or build-number change.
- Artifact publication: none.
- Distribution: no artifact was published; the current NOOP owner declaration
  governs source rights.

## Decisions

- Persisted score-bearing history is durable dirty work until source-bound
  analysis reaches its success boundary.
- Daily Effort is a same-day, opt-in wellness planning cue and never training
  clearance.
- Coach model context uses a typed evidence boundary where missing,
  unavailable, empty, and observed states remain distinct.
- Decision-log entries: D-017, D-018, and D-019.

## Open risks and honest limitations

- Synthetic persisted fixtures prove software progression, not physical-band
  completeness or physiological accuracy.
- No physical vibration, background delivery, battery, or overnight path was
  validated.
- Nutrition and health coaching still require users to judge symptoms and seek
  qualified care where appropriate.
- New translated copy requires native-speaker review.
- The current release gate still requires the owner-rights record, NOOP license,
  and exact independent dependency notices.

## Next round

1. Run overnight offload, reconnect, background, haptic, and battery scenarios
   on representative physical devices without resetting local data.
2. Run participant/device studies for sleep, workouts, temperature, SpO2, and
   wellness score calibration before stronger claims.
3. Obtain native-speaker review for new cycle, Daily Plan, metric education,
   and Coach-adjacent copy.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
