# Three-wearer leakage-safe Recovery and Rest verdict

**Date:** 2026-08-25
**Scope:** three independent private wearable-export cohorts, reported only as
aggregate results

This record supersedes the earlier comparison. The corrected harness uses
production EWMA baselines and independently derives NOOP Rest instead of
feeding the reference Sleep Performance outcome into Recovery.

## Method

- Each archive is processed as a separate wearer cohort.
- Baselines use only observations strictly before the scored day.
- HRV, resting heart rate, respiration, and independently derived Rest are
  NOOP Recovery inputs.
- NOOP Rest is derived from raw sleep aggregates: asleep duration, in-bed
  duration or efficiency, and restorative-stage duration.
- The reference provider's Recovery and Sleep Performance fields are outcomes
  used only after NOOP scores have been computed.
- No per-wearer offset, global offset, or provider-targeted coefficient fitting
  is performed.
- Raw archives, prepared JSON, dates, and row-level values are not committed or
  reproduced in documentation.

The internal harness and export parser retain provider-specific names where
needed to identify the source format. That provenance does not imply a
customer-facing provider label or endorsement.

## Recovery results

| Cohort | Comparable days | Bias | MAE | Pearson r | Band agreement | Direction agreement |
|---|---:|---:|---:|---:|---:|---:|
| A | 165 | **-10.0** | 12.1 | **0.869** | 63.0% | 95.0% |
| B | 409 | **-3.2** | 9.3 | **0.898** | 72.9% | 93.9% |
| C | 339 | **-6.8** | 11.1 | **0.850** | 71.1% | 88.3% |

The correlations and direction agreement replicate across 913 comparable days.
They show that NOOP and the proprietary reference outcome tend to move
together on these three histories. They do not establish physiological
accuracy or prove that the reference score is correct.

All three Recovery biases are negative, but their magnitude differs. A fixed
positive offset would fit the provider rather than validate NOOP, and it would
not be justified by three wearers. The global Recovery anchor remains
unchanged.

## Rest results without target leakage

| Cohort | Bias | MAE | Pearson r |
|---|---:|---:|---:|
| A | **+4.9** | 6.5 | **0.807** |
| B | **+3.4** | 6.1 | **0.775** |
| C | **+6.1** | 6.8 | **0.858** |

The reference Sleep Performance value is not an input to these NOOP Rest
scores. It is joined only after scoring to calculate the table above.

The consistent positive bias is a measurement to investigate, not a reason to
fit NOOP to a proprietary outcome. Recovery now centers its Rest-quality input
on each wearer's usable `rest_quality` baseline; the fixed `0.85` center is
retained only for Recovery cold start. That input's sensitivity remains `0.12`.

## Product interpretation

- Recovery is a personal, baseline-relative signal. This sample does not
  validate comparisons between different people.
- Provider agreement is useful for migration continuity, but it is not NOOP's
  optimization target.
- Invalid Rest units are omitted instead of clamped into plausible scores.
- Missing R-R or respiration evidence lowers confidence rather than changing
  the score to imitate the reference provider.
- The internal `populationMean = 58` anchor remains uncited and unchanged. It
  requires population evidence or an independently justified calibration
  design, not a three-wearer patch.

## Limitations

- `n = 3` can expose repeated behavior but cannot characterize a population.
- The histories are retrospective convenience samples with no preregistration,
  randomization, or demographic balance.
- The reference scores are proprietary estimates, not ground truth.
- Exported daily aggregates cannot validate raw-sensor processing, sync
  completeness, live device behavior, or causal health outcomes.
- Correlation does not establish calibration, and shared upstream signals can
  inflate agreement.
- No result supports diagnosis, treatment, emergency decisions, or medical
  claims.

## Reproduce without exposing private data

Run from the repository root. Replace the generic archive paths with local
files outside the repository:

```bash
python3 Tools/validation/audit_wearable_exports.py \
  /absolute/path/to/cohort-a.zip \
  /absolute/path/to/cohort-b.zip \
  /absolute/path/to/cohort-c.zip

python3 Tools/validation/prepare_whoop_export.py \
  /absolute/path/to/cohort-a.zip \
  /absolute/path/to/cohort-b.zip \
  /absolute/path/to/cohort-c.zip \
  --out-dir /tmp/noop-validation/cohorts

for cohort in /tmp/noop-validation/cohorts/export-*.json; do
  NOOP_WHOOP_CYCLES="$cohort" \
    swift test --package-path Packages/StrandAnalytics \
    --filter WhoopExportRecoveryComparisonTests
done
```

`NOOP_WHOOP_CYCLES` and `WhoopExportRecoveryComparisonTests` are retained
internal compatibility/provenance identifiers. Prepared files contain personal
health data even after field reduction. Keep them in temporary storage, do not
attach them to logs or tickets, and delete them when validation is complete.
