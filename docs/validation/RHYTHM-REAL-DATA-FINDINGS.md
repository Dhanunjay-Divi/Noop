# Real-data validation: findings

**Date:** 2026-08-24 · **Data:** PhysioNet MIT-BIH Atrial Fibrillation Database (`afdb`) + MIT-BIH Normal
Sinus Rhythm Database (`nsrdb`) · **Harnesses:** `RhythmScreenerRealDataTests`,
`ExtremePhysiologyScenarioTests`

## Why this was done

`RhythmScreener.swift` says its thresholds were **"tuned only on synthetic fixtures"**. Synthetic data
cannot tell you whether a threshold survives a real arrhythmia, because the generator and the detector share
the same assumptions. Separately, no test walked the scoring engines across the full range a real body — or a
failing sensor — can produce.

**What is NOT claimed here:** none of this is clinical validation, and NOOP has no cardiac alerting to test.
`docs/PRODUCTION_READINESS.md` states automatic anomaly/fall/medical SOS is *intentionally unavailable*, and
`RhythmScreener` deliberately emits neutral words ("looked steady", "varied a lot") with no condition name,
no probability, and no alarm. These harnesses test **robustness and self-consistency**: does the software
degrade honestly, and does it ever fabricate. Sensitivity/specificity on held-out patients belongs to the
accuracy-validation programme, not a unit test.

---

## The corpus

R-R intervals extracted from **inside annotated rhythm episodes**, not from raw record starts. This mattered:
a naive first-600-beats slice of `afdb/04043` measured RMSSD 13 ms — that segment is in normal rhythm, so
labelling it "AF" would have made every assertion against it meaningless.

| Fixture | Rhythm | Mean HR | RMSSD |
|---|---|---|---|
| `AF_04015` | AF (annotated `(AFIB`) | 131.9 | 128.3 |
| `AF_04043` | AF (annotated `(AFIB`) | 115.5 | 149.0 |
| `AF_04936` | AF (annotated `(AFIB`) | 86.9 | 235.0 |
| `NSRinAFDB_08455` | normal (annotated `(N`) | 75.1 | 56.7 |
| `NSR_16265` / `16273` / `19090` | normal (healthy volunteers) | 64–89 | 27.6–54.3 |

**Excluded:** `NSRinAFDB_04015` — labelled `(N` but measured RMSSD 161.5 ms, which is AF-like. Most likely
episode-boundary contamination. A fixture whose label contradicts its own statistics would weaken every
assertion made against it, so it is excluded and the exclusion recorded in the fixture file.

After exclusion the populations do not overlap (AF ≥ 128 ms, normal ≤ 57 ms), so a screener that cannot
separate them is genuinely failing rather than facing a hard case.

---

## Finding 1 — the screener is blind to rapid AF *(product decision needed, not fixed)*

`restingHrMaxBpm = 110`, and any window faster than that returns `unreadable` regardless of signal quality.
**Two of the three real AF episodes (132 and 115 bpm) were invisible to the screener.**

AF with a rapid ventricular response typically runs 110–160 bpm, so the feature is silent on the most common
salient presentation. This is exactly what synthetic resting fixtures cannot reveal — they never exceed 110.

**Why it was not simply "fixed":** the gate is defensible. A regularity read at 130 bpm may be exercise the
motion gate missed, and describing that as "varied" would be worse than saying nothing. Raising the ceiling
would admit exercise windows for real users and needs validation, not a one-line edit.

**Pinned instead:** `testRapidAtrialFibrillationIsOutsideTheRestingBandAndSaysSoRatherThanGuessing` asserts
the current honest behaviour and states that if the band is ever widened this test must fail and be
re-argued with real data. The blind spot is now visible in the suite rather than undocumented.

**Options for the owner:** (a) widen the band with validation; (b) keep the band but distinguish "not
assessed at this heart rate" from "signal too poor to read" — today both are `unreadable`, and those deserve
different words to a user; (c) leave as-is and document the limit in-product.

## Finding 2 — declined windows carried solid confidence *(not user-visible; documented)*

A window rejected by the rate gate still reports `confidence = .solid`, because gates 3–4 pass
`confidence(for: clean.count)` through. Read literally that is "couldn't read · solid confidence".

**Not a user-facing bug:** `RhythmView` builds `headlineWindow` from `windows.filter { $0.label != .unreadable }`,
so a declined window can never become the headline whose confidence pill is drawn. The UI is correctly
defensive. The invariant worth protecting is that filter, so it is now asserted via the night summary
(`testANightOfDeclinedWindowsReportsNoReadableWindows`), and declined windows are asserted to publish no
statistics and no point cloud.

## Finding 3 — `VitalityEngine` restingHR was unclamped and unguarded *(FIXED, both platforms)*

Five of six hazard contributions clamp their input. `restingHR` did not:

```swift
lnHazard: ((rhr - 65) / 10) * 0.100        // before
lnHazard: clamp((rhr - 65) / 10, -4, 4) * 0.100   // after, and only when rhr.isFinite
```

* `restingHR = 1e6` → log-hazard **9999.35**
* `restingHR = .infinity` → log-hazard **infinity**

Either poisons the hazard sum and therefore the user-facing **wellness age**. Reachable from a corrupt
import or a glitching sensor. The ±4 clamp gives an effective 25–105 bpm window, matching the ±4 convention
the VO₂max and steps terms already use.

**Also fixed:** `clamp` maps NaN to its *lower* bound, so a corrupt reading was being silently converted
into a *protective* factor — fabrication by arithmetic. All optional inputs now treat non-finite values as
**missing** (no contribution) rather than clamping them into a hazard direction. Mirrored in
`android/.../analytics/VitalityEngine.kt`.

## Finding 4 — three in-flight breakages fixed while verifying

Not from this work; found because every gate was run end to end.

* `StrainTargetNotifier.swift` and `StrainTargetPolicyTests.swift` referenced `DailyActionPlanner` /
  `DailyEffortGuidance` without `import StrandAnalytics` → iOS and macOS both failed to build.
* Eight new Russian `metric_education` strings contained U+2014, which `AndroidLocalizationPolicyTest` and
  `UserVisiblePunctuationPolicyTests` forbid. Fixed at the JSON source and regenerated.
* `TodayScreen.kt` composed an accessibility description with a string template
  (`"$accessibility $status"`), which the i18n audit correctly reads as un-extracted copy. Moved into a
  `joinLocalizedFragments` helper, mirroring the Swift `descriptorScopeHint` fix.
* 48 `metric_education` keys existed in the JSON but had never been generated into `appwide.xml`, so the
  Android main source set did not compile. Ran the generator and corrected four localization count pins that
  had drifted (appwide 183→236, nutrition 236→103).

---

## What the engines survived

Everything below now runs in CI on every commit.

* **Hydration**: full sweep of 5 sexes × 12 weights × 10 efforts × 8 skin temperatures, including `nil`,
  `0`, negatives, `1e6`, `NaN`, `±infinity`. Goal always positive, always < 20 L, always rounded to 50 ml,
  and monotonic in effort with the documented cap respected.
* **Recovery**: a five-rung ladder worse on HRV *and* resting HR *and* breathing *and* sleep never scores
  higher going down. Degenerate baselines (spread `0`, `-1`, `1e-12`, `NaN`, `±infinity`) never produce a
  non-finite or out-of-range score. Without a usable HRV baseline the engine returns `nil` rather than
  estimating. Bands sweep red → yellow → green in one direction only across −50…150.
* **Vitality**: every contribution finite and bounded across all 15 scenarios, from "elite athlete at deep
  rest" to "severe strain + fever" to fully corrupt sensors. No inputs → no contributions, never an invented
  age. Sleep consistency stays in 0…1, refuses fewer than three nights, and refuses all-zero nights.
* **Rhythm**: 14 pathological R-R shapes — empty, single beat, all-identical, 25 bpm, 240 bpm, bigeminy,
  an 8-second asystolic gap, alternating extremes, zeros, negatives, injected `NaN`/`infinity`, `1e9` —
  produce no non-finite statistic and no non-finite Poincaré point. Below `windowMinBeats` the answer is
  always `unreadable`, never a confident label off a handful of beats.
* **Stress heatmap**: empty input yields no grid; hostile hour keys (`-5`, `99`) and levels
  (`NaN`, `infinity`, `-10`, `99`) never escape 0…23 or produce a non-finite cell.

---

## Reproducing the corpus

Fixtures are checked in (`Resources/rhythm_real_rr.json`, 46 KB, R-R intervals only — no waveform, no
identifiers). To regenerate or extend:

```bash
python3 -m venv /tmp/physio-venv && /tmp/physio-venv/bin/pip install wfdb
# then read .atr rhythm annotations, select spans inside (AFIB / (N episodes,
# and convert beat samples to ms: rr = diff(samples) / fs * 1000
```

Records used: `afdb/04015`, `afdb/04043`, `afdb/04936`, `afdb/08455`, `nsrdb/16265`, `nsrdb/16273`,
`nsrdb/19090`.

## Next, if this line is worth pushing further

1. **Decide Finding 1** — it is the only one needing a product call.
2. **Widen the corpus** to atrial flutter (`(AFL`), ventricular tachycardia and pacemaker rhythms; the
   `afdb` records contain `(AFL` spans already.
3. **Sleep staging against `sleep-edf`** — the same treatment for the sleep engine, which has the same
   "validated only against itself" exposure.
4. Once a reference protocol exists, this harness is the natural place to add held-out
   sensitivity/specificity, which is the published-accuracy moat in `docs/handoff/FOUNDER-REVIEW-20260823.md`.
