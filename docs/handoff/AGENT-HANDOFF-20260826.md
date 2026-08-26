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

## Verified local evidence

- StrandAnalytics: 1,402 total, 7 skipped, 0 failures.
- macOS app: 1,490 total, 1 skipped, 0 failures.
- Android Full Debug: 3,775 total, 3,768 passed, 7 skipped, 0 failures.
- Android Demo Debug: 3,775 total, 3,768 passed, 7 skipped, 0 failures.
- Focused Apple stage/Watch integration: 27 executed, 0 failures.
- Focused iOS pull-to-sync UI: 1 executed, 0 failures.
- Full localization inventory completed with no missing shipped Apple
  translations; the Android localization policy passes both variants.
- Health-claims scan is clear across 1,066 files.

## External release gates

Code completion does not provide signing, store approval, production
infrastructure, controlled carrier delivery, representative physical-device
validation, prospective accuracy studies, native-speaker approval, or a
regulatory program. Keep those items open in
[`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md).
