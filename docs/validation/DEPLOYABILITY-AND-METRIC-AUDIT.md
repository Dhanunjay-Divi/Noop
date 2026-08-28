# Deployability review + metric accuracy audit

**Date:** 2026-08-26 · **Reviewed:** the Round 22 working tree based on `8b733c15`
**Audited against:** Task Force of the ESC/NASPE 1996 (HRV) · Impellizzeri 2020 / BJSM 2019 (ACWR) ·
Foster 1998 (monotony) · Banister/Coggan impulse-response (ATL/CTL/TSB) · Walch 2019 (sleep staging ceiling)

---

## 1. Is it good to deploy? **Not yet.**

The NOOP owner declaration records source and contribution rights. The legal
inventory and distribution modes validate NOOP's license, the owner record, and
independent dependency notices. Deployment still requires signing, store,
infrastructure, carrier, physical-device, accuracy, localization, and
regulatory evidence.

**Code readiness, assessed separately, is good:**

| Gate | Result |
|---|---|
| StrandAnalytics | 1,402 tests, 0 failures (7 opt-in skips) |
| macOS app | 1,490 tests, 0 failures (1 opt-in skip) |
| Android Full + Demo | 3,775 tests per variant, 0 failures (7 opt-in skips each) |
| iOS pull-to-sync UI | 1 focused simulator test, 0 failures |
| Legal inventory | 152 runtime components verified |
| i18n strict | PASS |
| Health-claims scan | clear, 1,066 files |

The complete local evidence and the remaining external gates are recorded in
`docs/ops/rounds/2026-08-26-metric-evidence-boundaries.md`.

---

## 2. The agent's work — verdict: good, and one recommendation landed correctly

### It implemented Finding D properly, and the data confirms it

I recommended centring the sleep term on the wearer's own baseline instead of a fixed `0.85`. It did exactly
that, with care I want to name:

```swift
static func validRestQuality(_ value: Double?) -> Double? {
    guard let value, value.isFinite, (0.0...1.0).contains(value) else { return nil }
    return value          // percent-scale or non-finite is MISSING DATA, not exceptional recovery
}
static func restQualityCenter(_ baseline: DriverBaseline?) -> Double {
    guard let center = baseline?.mean, center.isFinite,
          (0.0...1.0).contains(center) else { return sleepPerfCenter }   // 0.85 is cold-start only
    return center
}
```

Two things right here that I did not ask for: the percent-scale guard closes the `sleepPerf` unit footgun
(Finding 5) by treating `79` as **missing** rather than clamping it, and the cold-start fallback means a new
user is not scored against a baseline that does not exist yet.

**Re-measured on all three real wearers:**

| Wearer | Bias before | Bias after | Band agreement |
|---|---|---|---|
| A | −14.0 | **−9.7** | 54.9% → **60.6%** |
| B | −6.5 | **−3.4** | 72.2% → 69.4% |
| C | −10.9 | **−6.7** | 65.8% → **68.1%** |
| **mean** | **−10.5** | **−6.6** | |

~4 points of systematic pessimism removed, matching the 5.2-point penalty
`RecoveryBetweenPersonScaleTests` predicted. **The fix is validated against real data, not just asserted.**

### What remains from my earlier review

* **The mapping terminology is resolved without changing calibration.** The unused
  population-mean fallback symbol was removed, while the fixed logistic parameters
  remain `slope = 1.6` and `midpoint z = −0.20`. They map a personal-baseline
  composite onto the display scale; they are not a population statistic or a
  cold-start fallback. Residual reference bias of −3.4 to −9.7 remains a validation
  observation, not a production fitting target. `PersonalCalibrationModel` remains
  isolated to comparison tooling under D-025.
* **My earlier pushback on the "Complete calibration" commit stands**, but is now partly answered: that
  commit moved no constant, whereas *this* work did. The naming was ahead of the substance; the substance
  has since arrived.

### Also good, and worth protecting
Delivery visibility (`safety.page.delivery_counts_format`), transport-vendor abstraction, and
`pagingEnabled` / `pagingConfigured` as first-class states are worth protecting.

---

## 3. Metric accuracy audit

### HRV — **correct** ✅

Checked against Task Force 1996 (Circulation 93:1043–65), the canonical standard:

| Requirement | NOOP |
|---|---|
| `RMSSD = sqrt(mean(ΔNN²))` | exact |
| `SDNN` = sample SD, ddof = 1 | exact |
| NN = normal-to-normal (ectopy excluded) | range filter [300, 2000] ms, then Malik 20% local-median |
| Short-term window | **5-minute** windows, the Task Force short-term standard |
| Headline metric choice | **RMSSD**, not SDNN |

Two things here are better than typical consumer implementations:

1. **RMSSD as the headline is the right choice.** SDNN is strongly recording-duration dependent, so SDNN
   compared across nights with different usable windows produces spurious trends. RMSSD is far less
   duration-sensitive. NOOP picked correctly.
2. **`rmssdGapAware(_ nn:, _ contiguous:)` exists.** Differencing across a data gap fabricates variability;
   this refuses to. Most implementations get this wrong silently.

The Kubios/Lipponen–Tarvainen substitution is disclosed honestly in the header rather than hidden.

**Resolved method boundary:** Apple Health supplies SDNN while the strap path computes RMSSD. They remain
separate because they are different statistics. `WatchRecovery.HRVSample` now carries source and method,
baseline construction accepts only exact provenance matches, the result exposes that provenance, and the
Apple Watch explanation names the difference. A source or method switch starts a fresh baseline instead of
mixing numerically plausible millisecond values.

### Training load — **correct, and it dodged a trap the industry fell into** ✅

The 2020–21 literature is decisive against ACWR: Impellizzeri et al. (IJSPP 2020) — *"There is no evidence
supporting the use of ACWR in training-load-management systems… the statistical properties of the ratio make
the ACWR an inaccurate metric"* — and a 2021 paper titled *"Time to Dismiss ACWR and Its Underlying Theory"*
found it adds no predictive value over an intercept-only model (c-statistic 0.574 vs 0.5). The
"sweet spot" figure is separately documented as methodologically flawed.

`TrainingLoadModel` avoids all of it: it uses **ATL/CTL/TSB** where TSB is the *difference* `CTL − ATL`, not
a ratio, which sidesteps the mathematical coupling that produces ACWR's spurious correlation. It states
plainly that the values *"do not directly measure fatigue, fitness, readiness, injury risk, or permission to
train"*, and it warns that a bounded nonlinear score **must not be summed as impulse load** — a subtlety most
implementations miss.

`ReadinessEngine` no longer computes or publishes ACWR. It also no longer treats bounded nonlinear Effort
as additive load. A calendar-bounded weekly mean/SD can surface only as an **Effort variety** observation;
it is excluded from readiness synthesis and framed as an association, never an injury or overtraining
inference. `TrainingLoadModel` is now the only ATL/CTL/TSB path and accepts explicit additive entries such
as session-RPE minutes, TRIMP, or MET-minutes.

### Sleep staging — **the remaining accuracy gap** ⚠️

The corrected harness directly exercises shipped `SleepStagerV2` against
expert PSG (`MULTI-DATASET-VERDICTS.md`): 4-class agreement is **61.6%**,
sleep/wake agreement **91.6%**, Deep recall **83.1%**, REM recall **75.6%**,
and Wake recall only **10.0%**. The earlier 46.8% / 3.7% result exercised the
legacy stager and is superseded. High aggregate sleep/wake agreement does not
make the weak wake sensitivity acceptable for an arousal or wake-accuracy
claim.

The caveat is real: the dataset carries no R-R intervals and no respiration, both of which the engine's
Stage-1 features expect. The product now handles that limitation explicitly: locally classified Deep, REM,
Light, awake, and restorative figures require persisted sustained R-R evidence for the exact source, wake
day, and canonical main-sleep group. A same-day nap cannot borrow the main night's verdict. Without it,
the detailed split is withheld while total sleep remains available. Independently classified imports
remain publishable with disclosed provenance inside NOOP and portable exports; NOOP-authored HealthKit
and Health Connect writes keep those imported labels stage-free. Raw local estimates stay stored for
diagnostics and future reprocessing; the gate changes publication, not the model.

### Notification integrity — **architecture is right** ✅

I checked whether nudges can fire on weak data. The gating lives **upstream in the engines**, not in the
notifiers — which is the correct design: notifiers are dumb presenters, engines decide.

`IllnessSignalPipeline` gates on `state.usable` (baseline must be established), signal freshness
(`maximumSignalAgeDays`), finite values, and per-metric range bounds. The illness nudge fires only on a
clear→raised transition, once per calendar day. `StrainTargetNotifier` requires *"a current solid
multi-signal readiness read plus today's explicit self-check"*.

The audited notification producers check authorization before scheduling and use stable identifiers, so
repeat scheduling replaces rather than duplicates. The post-sync workout summary advances its workout
frontier only after Notification Center accepts the request, leaving a failed attempt retryable.

---

## 4. Ranked recommendations

1. **Preserve the detailed-stage evidence gate.** Local Deep, REM, Light, awake, restorative history,
   and comparisons require persisted sustained R-R evidence. Independently classified imports retain
   their disclosed provenance; total sleep remains available.
2. **Preserve the D-025 scoring boundary.** Keep the fixed personal-baseline
   logistic explicit, keep cold start nil, and keep `PersonalCalibrationModel`
   and proprietary reference outcomes out of production Recovery scoring.
3. **Preserve additive-load isolation.** ACWR is retired, bounded Effort never enters ATL/CTL/TSB,
   and only explicit additive load entries may reach `TrainingLoadModel`.
4. **Preserve HRV method provenance.** Apple Health SDNN and strap RMSSD keep source-isolated baselines.
5. **Carrier delivery evidence.** Still no real SMS has been sent; A2P/10DLC registration is the long-lead
   item.

## 5. Do I want another dataset pass?

I just ran one, and it was worth it: it turned "the agent implemented my recommendation" into "the
recommendation removed 4 points of measured bias across three wearers." **That is the pattern worth keeping**
— every calibration change should be re-measured against the three exports before it is called done, because
a constant that improves one wearer can worsen another (wearer B's band agreement fell 2.8 points even as
its bias improved).

What would make the next pass materially better is data I do not have: **a wrist recording with R-R
intervals and concurrent PSG.** That single gap is what stands between the sleep verdict and a real accuracy
number.
