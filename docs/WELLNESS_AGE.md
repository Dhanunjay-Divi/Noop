# Wellness Age and Vitality

Last reviewed: **2026-08-22**

**Status:** experimental wellness context. Not a biological age, clinical score, diagnosis, mortality
prediction, or WHOOP Age.

## Product claim

Vitality is a 0-100 lifestyle composite. Wellness Age expresses the same composite as an age-shaped
comparison because that is easier to interpret than a log-hazard value. It must only answer:

> Are the available long-window wellness signals broadly more or less favorable than their references?

It must not claim to measure cellular, phenotypic, organ, or biological age. It has not been trained or
validated against mortality, disease, epigenetic clocks, blood biomarkers, or a clinical biological-age
endpoint.

## Production inputs

The app builds the result from the latest 21 merged daily rows. Each physiological input needs at least
14 valid observations before it can contribute.

| Signal | Production summary | Neutral reference |
|---|---|---|
| Resting heart rate | median | 65 bpm |
| Sleep duration | mean | 7.0-8.0 h |
| Sleep-duration consistency | `1 - coefficient of variation` | 0.75 |
| Nocturnal RMSSD | median | age-interpolated local reference |

The engine can also represent estimated VO2max and measured steps, but the current production
orchestrator does not supply them. The old provenance-free motion-derived `steps` value was removed in
v2 because it was not a validated pedometer measurement.

A result requires at least three factors spanning three domains. Sleep duration and sleep consistency
remain one domain, so they cannot satisfy readiness by themselves.

## Calculation

Each available signal is converted to a signed, clamped log-hazard contribution. Negative values are
favorable and positive values are unfavorable. The engine then applies:

```text
combined log hazard = 0.75 * sum(factor log hazards)
age offset          = combined log hazard / (ln(2) / 8)
Wellness Age        = clamp(real age + age offset, 20, 90)
Vitality            = clamp(50 + (real age - Wellness Age) * 2.5, 0, 100)
```

The per-signal direction and approximate scale are literature-inspired, but the complete formula is an
internal NOOP model. In particular:

- `0.75` is an internal overlap shrink chosen to reduce double-counting among correlated wearable
  signals. It was not fitted from a NOOP cohort.
- The eight-year mortality-rate doubling time is a population-level demographic approximation, not an
  individual conversion rule.
- The RMSSD age references, clamps, and the 2.5-point Vitality presentation scale are internal choices.
- Hazard ratios from separate observational studies are not automatically additive or causal.

For those reasons, correct arithmetic does not make the output a calibrated biological age.

## Approximate range

Wellness Age displays a fixed model-level honesty range of approximately **+/-8 years**. It does not
tighten when more factors are present: sleep duration and consistency are correlated, and NOOP has no
fitted covariance/error model showing that another wearable input improves individual precision.

This is not a confidence interval and does not promise statistical coverage. It replaces the old
zero-year band, which falsely implied point precision. It must not be narrowed until a held-out,
representative validation study supports a different range.

## What improved from v1

- Removed unverified motion-derived steps from the calculation.
- Requires 14 observations per supplied physiological signal and three physiological domains.
- Uses a strict v2 provenance marker so a legacy score is invalidated on upgrade.
- Shows an approximate range and an explicit non-biological, non-medical disclaimer.
- Keeps Apple and Android equations and contract tests aligned.

## Validation required before stronger claims

1. Freeze a versioned protocol, inclusion criteria, missing-data policy, and reference endpoints.
2. Collect a representative multi-device cohort with repeated wearable windows.
3. Compare against prespecified outcomes; do not tune and report on the same participants.
4. Measure calibration-in-the-large, calibration slope, MAE, test-retest reliability, subgroup error,
   device error, and sensitivity to missing nights.
5. Fit correlation handling from data instead of retaining the internal `0.75` shrink.
6. Externally validate on a held-out site and publish model/version cards.
7. Treat any medical, risk, longevity, or emergency use as a separate clinical and regulatory program.

Until that work exists, product copy must use **Wellness Age** or **lifestyle estimate**, never
**biological age**, and must not say the value is clinically accurate.

## Implementation

- Apple engine: `Packages/StrandAnalytics/Sources/StrandAnalytics/VitalityEngine.swift`
- Android engine: `android/app/src/main/java/com/noop/analytics/VitalityEngine.kt`
- Apple orchestration: `Strand/Data/IntelligenceEngine.swift`
- Android orchestration: `android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt`
