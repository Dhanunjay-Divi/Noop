# Multi-dataset validation: corrected verdicts

**Date:** 2026-08-25
**Status:** corrected for the shipped `SleepStagerV2` and leakage-safe Recovery inputs

This record supersedes the earlier sleep verdict. That run exercised the legacy
stager, not the `SleepStagerV2` recipe shipped by the app.

The evidence in this record comes from:

- PhysioNet `sleep-accel` (Walch 2019): wrist motion, heart rate, and
  expert-scored PSG for 6 subjects and 5,720 epochs.
- Three separate private wearable-export cohorts. Only aggregate validation
  results are recorded here; source archives and prepared fixtures stay outside
  the repository.

Provider-specific type, test, and environment-variable names remain in the
repository where required for format compatibility and truthful provenance.
They are not customer-facing product labels.

These are fixed-sample engineering measurements, not clinical validation,
diagnostic evidence, or population accuracy claims.

## Verdict 1: the shipped sleep stager is materially better than the legacy result

`SleepStagerRealPSGTests` now calls `SleepStagerV2.stageSession` directly.

| Metric | Shipped V2 result |
|---|---:|
| 4-class epoch agreement | **61.6%** |
| Sleep/wake agreement | **91.6%** |
| Deep recall | **83.1%** |
| REM recall | **75.6%** |
| Wake recall | **10.0%** |

The 61.6% result is 3.4 percentage points below the lower edge of the
65-73% ceiling cited in the legacy source comment. It rejects the earlier
low-agreement conclusion for the shipped model, but it does not establish that
V2 reaches the cited range in a broader population.

The main limitation on this sample is wake detection. A 91.6% binary
sleep/wake agreement can coexist with 10.0% wake recall because overnight PSG
epochs are dominated by sleep. The high aggregate agreement must not be used
to imply reliable wake or arousal detection.

The Walch fixture supplies motion and heart rate, but no R-R intervals or
respiration. V2 is therefore being measured in a degraded sensor condition.
The result does not establish performance with the complete intended signal
set, and it does not justify a claim about first-party band accuracy.

The staging harness intentionally receives the PSG session window. The source
motion stream contains long gaps, so using session detection first would score
only the best-sampled portion of each night and bias the staging result.
Session detection is assessed separately.

## Verdict 2: session detection refuses to bridge missing source data

The existing sparse-stream investigation remains valid and separate from the
V2 staging correction:

1. Direct staging covered the requested PSG window.
2. Motion deltas during scored sleep were generally inside the stillness
   threshold.
3. Supplying cold-start baselines and a synthetic sleep-state channel did not
   recover the missing night.
4. The longest gap-free spans matched the detected session lengths.

`maxGapMin = 20` therefore prevented the detector from inventing continuity
across source gaps. This is evidence for fail-closed handling of sparse input,
not evidence for night-boundary accuracy on continuously sampled hardware.

## Verdict 3: three-wearer Recovery comparison is leakage-safe

The corrected harness uses the production EWMA baseline implementation with
strictly preceding days. It derives NOOP Rest from raw sleep aggregates and
never feeds the reference provider's Sleep Performance outcome into NOOP
Recovery.

| Cohort | Comparable days | Bias | MAE | Pearson r | Band agreement | Direction agreement |
|---|---:|---:|---:|---:|---:|---:|
| A | 165 | **-10.0** | 12.1 | **0.869** | 63.0% | 95.0% |
| B | 409 | **-3.2** | 9.3 | **0.898** | 72.9% | 93.9% |
| C | 339 | **-6.8** | 11.1 | **0.850** | 71.1% | 88.3% |

Across 913 comparable days, the association and day-to-day direction are
consistent in all three cohorts. This means NOOP moves similarly to the
proprietary reference outcome on these histories. It does not prove that
either score measures physiological recovery correctly.

Bias remains negative in all three cohorts, but it is neither constant nor a
basis for adding a provider-matching offset. No coefficient was fit to these
three wearers. The fixed personal-baseline logistic mapping remains unchanged
and must not be tuned to a three-person sample.

## Verdict 4: Rest associates with the reference outcome without direct target reuse

The Rest comparison does not feed proprietary Sleep Performance into NOOP.
It does use exported asleep duration, in-bed duration or efficiency, and
deep/REM aggregates. Those are provider-processed outputs, not independent raw
sensor evidence. The result is therefore an association and migration
compatibility check, not independent physiological validation.

| Cohort | Bias | MAE | Pearson r |
|---|---:|---:|---:|
| A | **+4.9** | 6.5 | **0.807** |
| B | **+3.4** | 6.1 | **0.775** |
| C | **+6.1** | 6.8 | **0.858** |

The positive Rest bias is consistent across this small sample. It should be
investigated with a larger cohort, not removed by fitting NOOP to a proprietary
provider score.

Recovery now centers Rest on each wearer's own usable `rest_quality` baseline.
The fixed `0.85` center is a cold-start fallback only. Rest sensitivity remains
`0.12`, and the fixed personal-baseline logistic mapping remains unchanged.

## Input and confidence safeguards

- Import boundaries normalize sleep efficiency to a `0...1` fraction.
- Non-finite or out-of-range Rest fractions are treated as missing rather than
  saturating Recovery.
- Historical percentage-scale efficiency rows receive an idempotent
  compatibility repair.
- Missing trustworthy R-R or respiration evidence lowers Rest confidence. It
  does not silently alter stage labels or manufacture a score.
- Reference-provider outcomes are comparison targets only. They are not
  training labels or production scoring inputs.

## What this evidence does not establish

- The PSG sample has only 6 subjects, no held-out split, limited demographic
  breadth, and no wrist R-R or respiration.
- Wake recall is 10.0%; V2 must not be described as reliable for awakenings or
  arousals on this evidence.
- Three wearers are not a population calibration or a basis for cross-person
  score comparability.
- The reference Recovery and Sleep Performance values are proprietary
  estimates, not ground truth.
- Retrospective exports do not validate live collection, background sync,
  sensor quality, physical-device behavior, or prospective outcomes.
- No result here supports diagnosis, emergency detection, or medical claims.

## Highest-value next evidence

1. Validate V2 on wrist data containing R-R, respiration, and concurrent PSG.
2. Measure wake sensitivity and false-wake behavior prospectively on complete
   overnight streams.
3. Expand Recovery and Rest evaluation with a preregistered, diverse cohort and
   independently defined outcomes.
4. Keep provider comparison as migration/interoperability evidence, not as a
   tuning objective.
5. Validate full import, migration, and scoring parity on both Apple and
   Android before release.

## Reproduction

The exact preparation and test commands are recorded in
`docs/validation/SLEEP-PSG-HARNESS.md`,
`docs/validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md`, and
`docs/handoff/ROUND-21-validation-calibration-import-integrity.md`.
Research fixtures and personal health exports must remain outside the
repository.
