# Deployability review + metric accuracy audit

**Date:** 2026-08-25 · **Reviewed:** the parallel agent's work through `ac66de4b` plus 141 uncommitted files
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
| Engines | 1,383 tests, 0 failures (8 opt-in skips) |
| macOS app | 1,435 tests, 0 failures |
| Legal inventory | 152 runtime components verified |
| i18n strict | PASS |
| Health-claims scan | clear, 1,059 files |

Caveat on that: **141 files are uncommitted and the tree was being written during this review** (newest
write 19:48, one minute before I looked). Those numbers have a shelf life measured in minutes.

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

* **The anchor is still open.** `logisticZ0 = −0.20` and `populationMean = 58.0` are unchanged, and residual
  bias is −3.4 to −9.7 — still negative for every wearer. This is now the single largest remaining
  calibration gap, and `PersonalCalibrationModel` in `WhoopReferenceCalibration.swift` still exists unused
  for it.
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

**Minor:** `WatchRecovery.swift` drives its baseline from `sdnnHistory`/`todaySDNN` while the phone uses
RMSSD. If the watch's usable window varies night to night, watch and phone can disagree for a reason that is
purely methodological. Worth either aligning on RMSSD or documenting why the watch differs.

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

`ReadinessEngine` does compute an ACWR, and handles it about as well as it can be handled:

```swift
// This ratio has no validated universal "good", "bad", or injury-risk bands. Keep the legacy
// Signal/Flag API shape, but always emit `.neutral` … `synthesize` also excludes this key so the
// number cannot change readiness or prescribe training.
```

Always `.neutral`, excluded from the score, disclosed as a limitation, and no bands. That is the correct
posture for a discredited metric that users still expect to see.

**Two defects remain:**

1. **The ratio is coupled.** `acuteWindow = 7`, `chronicWindow = 28`, both ending on the same day — so the
   acute window is a *subset* of the chronic window. This is precisely the mathematical coupling BJSM
   identified as the source of spurious correlation; the literature's fix is the **uncoupled** form
   (chronic computed over days 8–28). Because NOOP presents it as pure arithmetic this matters less than it
   would for a risk metric, but the number is partly self-correlated, which makes it less meaningful than it
   looks. Cheap fix.
2. **It uses bounded Effort/strain as the load unit**, which `TrainingLoadModel`'s own documentation forbids
   for impulse load. Averaging is milder than summing, but it is the same category error, and the two
   engines in this codebase currently disagree with each other about it.

Foster monotony (mean/SD of weekly load, flagged at ≥ 2.0) is a real published metric used as a `.watch`
hint rather than a risk claim. Acceptable.

### Sleep staging — **the weakest metric, and the honest gap** ⚠️

Measured against expert PSG (`MULTI-DATASET-VERDICTS.md`): 4-class agreement **46.8%** against the
**65–73%** ceiling the engine's own header cites, with **REM recall 3.7%** and **deep recall 6.9%** — and
51% of REM epochs classified as *wake*.

The caveat is real: the dataset carries no R-R intervals and no respiration, both of which the engine's
Stage-1 features expect. But the product consequence stands: **when R-R is unavailable, REM and deep minutes
are not measurements and should not be presented as if they were.** That remains my top open recommendation,
and it is a provenance change, not a model change.

### Notification integrity — **architecture is right** ✅

I checked whether nudges can fire on weak data. The gating lives **upstream in the engines**, not in the
notifiers — which is the correct design: notifiers are dumb presenters, engines decide.

`IllnessSignalPipeline` gates on `state.usable` (baseline must be established), signal freshness
(`maximumSignalAgeDays`), finite values, and per-metric range bounds. The illness nudge fires only on a
clear→raised transition, once per calendar day. `StrainTargetNotifier` requires *"a current solid
multi-signal readiness read plus today's explicit self-check"*.

All 13 notification producers check authorization before scheduling and use stable identifiers, so `add()`
replaces rather than duplicates. No silent failures, no duplicates found.

---

## 4. Ranked recommendations

1. **Gate REM/deep minutes on R-R availability.** Highest honesty-per-line item outstanding.
2. **Resolve the 58 anchor** — the last ~3–10 points of systematic pessimism. Drive
   `PersonalCalibrationModel`, which already exists for this.
3. **Uncouple the ACWR** (chronic over days 8–28) or drop it. Also reconcile the strain-as-load
   disagreement between `ReadinessEngine` and `TrainingLoadModel`.
4. **Align watch HRV with the phone** (RMSSD) or document why SDNN differs there.
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
