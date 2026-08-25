# Multi-dataset validation: verdicts

**Date:** 2026-08-25
**Datasets:** PhysioNet `sleep-accel` (Walch 2019: wrist motion + HR + expert PSG, 6 subjects, 5,720 epochs)
· PhysioNet `afdb`/`nsrdb` (real arrhythmia R-R) · **one wearer's real WHOOP export, 169 days**
**Harnesses:** `SleepStagerRealPSGTests`, `SleepDetectionGateDiagnosticTests`,
`SleepStagerCoverageDiagnosticTests`, `WhoopExportRecoveryComparisonTests`,
`RhythmScreenerRealDataTests`, `ExtremePhysiologyScenarioTests`
**Reproduce:** `Tools/validation/fetch_walch_sleep.py`, `Tools/validation/prepare_whoop_export.py`

All four verdicts below are **measurements, not accuracy claims**: single-wearer or six-subject samples with
no held-out split. They are sufficient to find systematic behaviour, not to license a clinical claim.

---

## Verdict 1 — Sleep staging is materially below the ceiling its own code cites · **NOT AS EXPECTED**

Measured over the full PSG window, every epoch scored (5,720 epochs, zero uncovered):

| Metric | Measured | Reference |
|---|---|---|
| 4-class epoch agreement | **46.8%** | `SleepStager.swift`: *"the EEG-free 4-class ceiling is ~65-73% (Walch 2019)"* |
| Sleep/wake agreement | **71.8%** | actigraphy convention 80-90% |
| **REM recall** | **3.7%** | — |
| **Deep recall** | **6.9%** | code says deep is *"the least reliable output"* |
| Light recall | 75.8% (precision 64.3%) | — |

Confusion (rows PSG, cols NOOP):

```
             wake   light    deep     rem
wake          143     236     114      28
light         468    2439     256      53
deep           60     482      41       8
rem           706     634       0      52
```

**The dominant error is REM → wake: 706 of 1,392 REM epochs (51%) are called wake.** Deep is second: 482 of
591 (82%) are called light.

**Verdict.** The code's honesty note is directionally right but **understates the problem and names the wrong
weakest link**. It says light/deep separation is the weakest; the data says REM is worse (3.7% vs 6.9%
recall), and the largest single error mass is REM being read as wake. At these recalls, **REM and deep
minutes are not measurements** — they are noise with a plausible shape.

**Material caveat, stated plainly:** Walch supplies motion + HR only. NOOP's Stage-1 features include RMSSD
from R-R intervals and respiratory rate + RRV, and **both were absent**. This is therefore the
worst-supported input case — exactly what a user with a HR-only wearable gives NOOP — not the band's own
capability. A NOOP Band with R-R and respiration may do materially better, and that hypothesis is untested
because no public dataset carries wrist R-R with concurrent PSG.

**Recommended action (honesty-consistent, cheap):** gate the stage breakdown on input availability. When
R-R and respiration are absent, show sleep/wake and duration, and either withhold REM/deep minutes or mark
them explicitly as unsupported estimates. The project already refuses to print a Recovery score without a
usable HRV baseline; printing REM minutes at 3.7% recall is the same category of claim and deserves the same
refusal. This is a UI/provenance change, not a model change.

---

## Verdict 2 — Sleep session detection behaves correctly on sparse data · **AS EXPECTED (good)**

Initially this looked like the headline defect: `detectSleep` accepted only **1h21m-2h30m of PSG-confirmed
8-hour nights** (mean 24% coverage). Four hypotheses were tested in order:

1. **Staging is broken** → *disproved.* `stageSession` covers **100%** of the PSG window on all six subjects.
2. **Input too noisy for the 0.01 g stillness threshold** → *disproved.* During PSG-scored sleep,
   **98.5-99.4%** of 1 Hz gravity deltas are below threshold (medians 0.0006-0.0026 g, 4-16× inside spec).
3. **Cold start — missing HR baseline or band sleep-state channel** → *disproved.* Supplying the wearer's own
   overnight HR median, and then a synthetic band sleep-state channel, changed coverage by **0.0%**
   (24% → 24% → 24%).
4. **The source motion stream is sparse** → **confirmed.** Samples exist for only 20.5-31.6% of the night's
   seconds, and the longest contiguous span without a >20 min hole is **98-150 min** — which matches the
   detected session lengths almost exactly.

**Verdict.** `maxGapMin = 20` did its job. The engine found the longest well-sampled span and **refused to
bridge a night it could not see**, rather than inventing an 8-hour session. That is the no-fabrication rule
holding under adversarial input, and it is the correct behaviour.

**Process note worth keeping:** the first framing of this finding ("76% of the night uncovered — engine
defect") was wrong, and only four rounds of falsification made that visible. A verdict written after
hypothesis 1 would have sent someone to fix code that was already right.

---

## Verdict 3 — Recovery tracks WHOOP's shape closely but is systematically ~14 points low · **PARTLY AS EXPECTED**

169-day export, 162 comparable days after baseline warm-up, zero declines:

| Metric | Result |
|---|---|
| **Pearson r** | **0.905** |
| **Day-over-day direction agreement** | **94.2%** (147/156 moves >2 points) |
| Bias | **−14.0** (WHOOP mean 67.7, NOOP 53.7) |
| MAE / RMSE | 15.4 / 18.8 |
| **Band agreement (red/yellow/green)** | **54.9%** |

Band confusion (rows WHOOP, cols NOOP) — the errors are **entirely one-directional**:

```
             red  yellow   green
red            6       0       0
yellow        35      24       1
green          1      36      59
```

**NOOP never rates a day higher than WHOOP, and downgrades 45% of days by one band.**

**The bias is not an artifact of my baseline reconstruction.** It survives every construction tested:

| Baseline | Bias | r |
|---|---|---|
| 30 d, mean-abs-dev | −14.3 | 0.885 |
| 30 d, stdev | −14.0 | 0.894 |
| 60 d, mean-abs-dev | −12.4 | 0.833 |
| 14 d, mean-abs-dev | −15.0 | 0.869 |
| 90 d, stdev | −10.1 | 0.823 |

Decomposing the mean z of each term explains it exactly:

```
hrv    mean z = +0.05   weight 0.55   weighted +0.026
rhr    mean z = +0.01   weight 0.20   weighted +0.002
resp   mean z = +0.09   weight 0.05   weighted +0.005
sleep  mean z = -0.73   weight 0.15   weighted -0.109   <-- the outlier
composite mean z = -0.080
score at z = 0   = 57.9      <-- the engine's built-in anchor
WHOOP mean       = 67.6
```

**Two distinct causes, both actionable:**

**(a) The anchor (~−10 points).** The logistic is centred so an average day reads **57.9**. This is the
`populationMean = 58` constant that was reclassified as *internal, uncited* when the false
"WHOOP-published" attribution was withdrawn (ROUND-13). This is the first evidence of what that choice
costs: for this wearer it sits ~10 points below the reference. Every switching user will perceive NOOP as
harsher than the app they came from — not because the model disagrees, but because the anchor was chosen
without data.

**(b) The sleep term is absolute while every other term is personal (~−3 points).** HRV, resting HR and
respiration are all z-scores against the wearer's own baseline, so they average ≈0 by construction (+0.05,
+0.01, +0.09 — confirmed). The sleep term is centred on a **fixed 0.85**. This wearer's median sleep
performance is 0.79, so they carry a permanent **−0.73 z** penalty. That is an architectural inconsistency:
Recovery is partly relative-to-you and partly relative-to-an-ideal, and anyone whose habitual sleep
efficiency differs from 85% is judged against a stranger forever rather than against themselves.

**Verdict.** The model is sound — r = 0.905 and 94% direction agreement mean the physiology is being read
correctly. What is wrong is **level, not shape**, and it is a two-constant fix rather than a modelling
problem. Recommended, in order:
1. Centre the sleep term on the wearer's own sleep-performance baseline like the other four terms, keeping
   the absolute reference only as a cold-start fallback.
2. Revisit the 58 anchor against a real population sample, or expose it through the existing
   `PersonalCalibrationModel` in `WhoopReferenceCalibration.swift` — which already exists for precisely this
   and is currently unused for the anchor.
3. Do **not** simply add +14. That would fit one wearer and is how a calibration becomes a superstition.

---

## Verdict 4 — WHOOP Day Strain → Effort scale conversion is monotonic · **AS EXPECTED**

168 days, **0 rank inversions** in the documented 0…21 → 0…100 conversion. The mapping never reorders which
days were hard. This is all that can be checked without raw HR, and it passes.

---

## Finding 5 — `sleepPerf` unit ambiguity is an API footgun

`RecoveryScorer.recovery(sleepPerf:)` expects a **fraction (0…1)**: `sleepPerfCenter = 0.85`,
`sleepPerfScale = 0.12`. Nothing in the signature says so, and the doc comment reads *"good night at ~85%
efficiency"*, which invites a percentage.

Passing WHOOP's `79` instead of `0.79` yields z = (79 − 0.85) / 0.12 = **651**, saturating **every one of 162
days at exactly 100.0** — every day green, silently. I made this mistake within minutes of touching real data.

**Production is correct** — `TodayScoring.kt` does `it / 100.0` with an explanatory comment — but the need
for that comment is the evidence. A `sleepPerfFraction:` label, or accepting a percentage and dividing
internally, removes a whole class of silent failure. Note the failure mode is *silent and plausible*: a
saturated 100 looks like a great night, not like a bug.

---

## Scope for improvement, ranked by value

1. **Gate REM/deep minutes on R-R availability** (Verdict 1). Highest honesty-per-line-of-code in this list;
   consistent with refusing Recovery without an HRV baseline.
2. **Fix the sleep term's absolute centring** (Verdict 3b). Removes a permanent per-user bias and makes
   Recovery coherently personal.
3. **Resolve the 58 anchor with data, or calibrate per person** (Verdict 3a). Decides whether switchers
   perceive NOOP as accurate or as harsh.
4. **Rename or normalise `sleepPerf`** (Finding 5). One-line change, removes a silent-saturation class.
5. **Find or record a wrist dataset with R-R + PSG.** Verdict 1's central caveat cannot be closed without
   one; a small in-house study against a consumer PSG would settle NOOP's real staging ceiling and is the
   single highest-value data investment available.
6. **Extend the rhythm corpus** to atrial flutter and pacemaker rhythms (`afdb` already contains `(AFL`
   spans).

## Standing caveats

* n = 1 wearer for Verdicts 3-4; n = 6 subjects for Verdicts 1-2. No held-out split, no demographic spread.
* WHOOP's Recovery is proprietary and itself an estimate. Agreement means "tracks the app users are
  switching from", not "correct".
* Sleep staging was measured **without R-R or respiration**, which the engine expects.
* Neither dataset is committed: Walch is third-party research data, the WHOOP export is personal health
  data. Both harnesses skip cleanly when their data is absent, matching the existing opt-in pattern in
  `server/tests/test_twilio_staging.py`.
