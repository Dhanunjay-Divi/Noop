# Agent handoff - 2026-08-26

## Authority

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Work directly from canonical `main`.
- Preserve NOOP's PolyForm Noncommercial License 1.0.0, Required Notice, and
  exact independent dependency notices.
- The repository owner has recorded control of NOOP source and contribution
  rights in
  [`../provenance/OWNER-RIGHTS-DECLARATION.md`](../provenance/OWNER-RIGHTS-DECLARATION.md).

## Product constraints

- Local-first and account-free by default.
- Missing, stale, corrupt, or unsupported physiology remains missing.
- Wellness metrics are not diagnosis, injury prediction, or permission to train.
- Medical/anomaly/Rhythm paging and unvalidated automatic fall paging remain
  unavailable.
- Existing app identity and local data must survive in-place upgrades.

## Round 22 metric boundaries

The complete implementation and evidence are in
[`../ops/rounds/2026-08-26-metric-evidence-boundaries.md`](../ops/rounds/2026-08-26-metric-evidence-boundaries.md).

Preserve these decisions:

- Local detailed sleep stages require persisted sustained R-R evidence for the
  exact source, wake day, and canonical main-sleep group. Same-day naps cannot
  borrow that verdict. Independently classified imports retain provenance in
  NOOP and portable exports; HealthKit/Health Connect receive stage-free sleep
  so third-party labels are not re-authored as NOOP data. Total sleep is not gated.
- Raw local stage estimates remain stored. Publication fails closed.
- HealthKit and Health Connect run a permission-gated, retryable full-history
  replacement once per active device so records published before the gate do
  not retain unsupported stage detail.
- ACWR is removed. Bounded Effort cannot affect readiness or enter additive
  ATL/CTL/TSB math.
- The fixed Recovery logistic is a personal-baseline display mapping, not a
  population mean or cold-start value. Cold start remains nil.
- Do not fit Recovery to proprietary reference outcomes or wire
  `PersonalCalibrationModel` into production scoring.
- Apple Health SDNN and strap RMSSD use source-and-method-isolated baselines.

## Interrupted Today follow-up closed

- Today pull-to-sync remains a pink circular indicator. On iOS 26, a
  top-gated vertical drag fallback now drives the same refresh state when
  elastic ScrollView bounce does not publish a usable offset.
- Fast refreshes keep the indicator observable for at least two seconds.
  A disconnected band reports `Refreshing local data`; it does not claim that
  band history synced.
- The focused iPhone 14 Pro simulator UI test passed after the fallback and
  accessibility-copy assertion were updated.

## Active Minutes closed

- Apple and Android now persist a conservative seven-day moderate/vigorous
  activity total against the 150-minute WHO/AHA weekly guideline.
- Zone 3 earns one minute of credit; Zones 4 and 5 earn two. Zones 1 and 2 do
  not earn credit. This deliberately under-counts the 64-70% HRmax boundary
  instead of inflating a public-health total.
- Only plausible HR intervals no more than ten seconds apart count as observed.
  Long gaps, missing wear, corrupt timestamps, and the final sample's unknown
  tail remain unmeasured.
- Daytime activity is persisted even when overnight HR cannot support sleep
  scoring. A one-time 21-day in-place backfill upgrades existing installs
  without replacing user history.
- Workouts shows weekly progress, moderate/vigorous detail, measured HR
  coverage, and explicit missing-wear language. All nine locales are generated
  from the shared catalog.
- Large-text UI evidence passed on iPhone SE and iPhone 14 Pro. The SE test
  separately proves the final note can scroll clear of floating navigation.

## Repository provenance migration is not complete

- Future commits use `Dhanunjay Divi` with the GitHub private noreply address;
  do not introduce `divii@amazon.com`.
- The owner identifies `ryanbr` and `Fanboynz` as prior personal identities.
- No history rewrite or replacement repository has been performed yet.
- A new root alone does not establish code ownership. Before calling a
  replacement repository provenance-clean, inventory unrelated contributor
  code and retain a grant, compatible license, or independently documented
  replacement for each surviving contribution. Preserve mandatory dependency
  notices.

## Verified local evidence

- StrandAnalytics: 1,419 total, 7 skipped, 0 failures.
- macOS app: 1,495 total, 1 skipped, 0 failures.
- Android Full Debug: 3,791 total, 3,784 passed, 7 skipped, 0 failures.
- Android Demo Debug: 3,791 total, 3,784 passed, 7 skipped, 0 failures.
- Focused Apple stage/Watch integration: 27 executed, 0 failures.
- Focused iOS pull-to-sync UI: 1 executed, 0 failures.
- Focused iOS Active Minutes UI: iPhone SE and iPhone 14 Pro, 0 failures.
- Full localization inventory completed with no missing shipped Apple
  translations; the Android localization policy passes both variants.
- Health-claims scan is clear across 1,068 files.

## External release gates

Code completion does not provide signing, store approval, production
infrastructure, controlled carrier delivery, representative physical-device
validation, prospective accuracy studies, native-speaker approval, or a
regulatory program. Keep those items open in
[`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md).
