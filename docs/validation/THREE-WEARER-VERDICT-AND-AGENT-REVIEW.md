# Three-wearer validation + reasoning for the parallel agent

**Date:** 2026-08-25 · **New data:** three WHOOP exports, confirmed **three different wearers**
**Total:** 904 comparable days · **Verdict 3 of `MULTI-DATASET-VERDICTS.md` is now replicated at n=3**

---

## Part 1 — The three exports are three different people

Verified before drawing any conclusion: on overlapping calendar dates, **0% of values match**.

| Date | Wearer A | Wearer B | Wearer C |
|---|---|---|---|
| 2025-12-03 | Recovery 46, RHR 66, HRV 47 | Recovery 96, RHR 62, HRV 74 | Recovery 55, RHR 69, HRV 41 |

Different physiology, not different export windows of one person. That is what makes the next section
possible: the open question in Verdict 3 was *"is the −14 bias personal or population-wide?"* and n=3
answers it.

---

## Part 2 — Replicated results

| Wearer | Days | WHOOP mean | NOOP mean | Bias | MAE | Pearson r | Band agree | Direction |
|---|---|---|---|---|---|---|---|---|
| A | 162 | 67.7 | 53.7 | **−14.0** | 15.4 | **0.905** | 54.9% | 94.2% |
| B | 406 | 59.7 | 53.2 | **−6.5** | 10.5 | **0.905** | 72.2% | 93.8% |
| C | 336 | 60.6 | 49.7 | **−10.9** | 13.7 | **0.867** | 65.8% | 87.9% |

### Finding A — the physiology read is sound, and this now replicates
`r = 0.867–0.905` and day-over-day direction agreement `87.9–94.2%` across **904 days and three unrelated
wearers**. Whatever else is wrong, NOOP is tracking the same underlying signal WHOOP is. This is the finding
to protect: it is the hard part, and it works.

### Finding B — the pessimism is systematic, not personal
Bias is negative for **all three** wearers and never positive. So the −14 seen at n=1 was not that wearer
being unusual.

### Finding C — the real mechanism is *between-person compression*, not a fixed offset

This is the important correction to my earlier n=1 verdict:

```
WHOOP  per-wearer means: 68.2, 60.5, 62.2   -> range 7.6
NOOP   per-wearer means: 53.8, 53.7, 51.9   -> range 1.9      (4x compression)

within-person SD ratio (NOOP / WHOOP): 1.37, 1.23, 1.32      (NOOP is MORE dynamic, not less)
```

NOOP collapses three different people onto effectively the same mean while remaining *more* reactive
day-to-day than WHOOP. That is not a tuning error — it is the direct consequence of the architecture: HRV,
resting HR and respiration are all z-scored against **the wearer's own baseline**, so every person's mean z
is ≈ 0 by construction and everyone lands on the same anchor.

**NOOP answers "how are you versus your own normal". It does not, and structurally cannot, answer "how
recovered are you compared with other people".**

Two consequences that matter to the product:

1. **Switchers with high scores feel the most penalised.** Wearer A, whom WHOOP averages at 68, is pulled
   down 14 points. Wearer B at 60 is pulled down 6.5. The better WHOOP said you were, the harsher NOOP
   looks. That is the worst possible distribution of a first impression.
2. **Raw Recovery is not comparable between people.** Anywhere the product shows one person's Recovery
   next to another's — Friends most obviously — the numbers are not on a shared scale. Either compare
   *deltas versus each person's own baseline*, or say plainly that the number is personal.

### Finding D — the 0.85 sleep centre is set above where real wearers live

```
wearer   mean sleep performance   mean sleep-term z
  A            76.3%                  -0.73
  B            74.4%                  -0.88
  C            73.1%                  -0.99
```

All three sit at **73–76%**, while `sleepPerfCenter = 0.85`. Every one of them therefore carries a permanent
negative penalty from the single term that is **not** baseline-relative. At n=1 this looked like one wearer
with poor sleep; at n=3 it looks like the constant is simply mis-set against real users.

This is the cheapest meaningful fix available: either centre the sleep term on the wearer's own baseline like
the other four drivers, or move the constant to the observed norm. The first is more coherent — it makes
Recovery consistently personal instead of four-fifths personal.

### Standing caveats
n = 3 wearers is enough to show a systematic direction; it is **not** a population calibration. WHOOP's
Recovery is proprietary and itself an estimate. My baselines are a 30-day rolling reconstruction, not
NOOP's own `Baselines` engine — though the bias survived 14/30/60/90-day windows and both spread estimators,
so it is not an artifact of that choice.

---

## Part 3 — Reasoning for the parallel agent

### What it did well, and why it matters

Since `c5b771fd` (the productionisation plan) it has shipped, in order: durable safety escalation, shared
server tenancy hardening, delivery visibility + notification diagnostics, production gate documentation, and
vendor abstraction on customer surfaces. That maps almost item-for-item onto the plan's "Next" list, and it
did the two things I would have prioritised first:

* **`82dcc042` delivery visibility.** `safety.page.delivery_counts_format` now exists, so the user can see
  what actually landed. This was the single highest-trust-per-line item in the plan, and it is the difference
  between a safety feature and a hope.
* **`ac66de4b` hiding the transport vendor.** Correct instinct: users should never read "Twilio", and
  abstracting the provider keeps a second carrier possible without touching UI. Note this is *not* in tension
  with the glass-box ethos — provenance means being honest about **where a number came from**, not about
  which SMS vendor carried a message.
* It kept `pagingEnabled` / `pagingConfigured` as first-class states, which is the kill-switch shape the plan
  asked for.
* **It did not flip the rights gate.** `distribution` still returns BLOCKED, and the three blockers are
  intact. Under pressure to ship, that restraint is the most valuable thing on this list.

Tree state on review: **iOS builds, macOS 1435 tests / 0 failures, engines 1367 / 0 failures.** No regressions
introduced.

### Where I'd push back

1. **`7918fc63` is called "Complete calibration" but the calibration constants never moved.**
   `logisticZ0 = −0.20`, `populationMean = 58.0`, `sleepPerfCenter = 0.85`, `sleepPerfScale = 0.12` are all
   unchanged, and the commit's diff is two documents. Calibration work that does not touch a calibration
   constant, and is not accompanied by a measurement, should not be called complete — the word closes an
   issue that is still open. The data in Part 2 is exactly the measurement that was missing; it now exists,
   so the honest next step is either to move a constant with evidence or to rename the round.

2. **Do not "fix" the bias with an offset.** With n=3 it is tempting to add ~+10. Finding C shows why that
   would be wrong: the gap is not a constant, it scales with how well the reference rates the wearer. An
   offset would fit the mean and leave the compression untouched, and compression is the part with product
   consequences (Friends comparability, switcher first impressions).

3. **The one change I would make first** is Finding D — centre the sleep term on the wearer's own baseline.
   It is small, it is architecturally consistent with the other four drivers, it removes a penalty that all
   three wearers carry, and unlike the anchor it does not require population data to justify.

4. **`PersonalCalibrationModel` in `WhoopReferenceCalibration.swift` already exists and is unused for the
   anchor.** Three wearers' worth of paired days is exactly its input. Before inventing a new mechanism,
   drive the one that is already there.

5. **A gate that would have caught this earlier.** A test asserting Recovery's between-person spread on
   synthetic wearers with different baselines would have shown the 4× compression without any real data.
   Worth adding, because compression is invisible to every single-wearer test.

### What I would not touch

The rights blockers, the inert `FallResponse`, and the sleep-stage honesty gating. All three are correctly
conservative, and the temptation to relax any of them for launch should be resisted — the distribution gate
in particular is doing exactly what it was built to do.

---

## Reproducing

```bash
for z in 2026_07_26 2026_08_25-1 2026_08_25; do
  python3 Tools/validation/prepare_whoop_export.py ~/Downloads/my_whoop_data_$z.zip \
    --out /tmp/whoop_multi/W_$z.json
  (cd Packages/StrandAnalytics && NOOP_WHOOP_CYCLES=/tmp/whoop_multi/W_$z.json \
    swift test --filter WhoopExportRecoveryComparisonTests)
done
```

No export is committed. All three remain personal health data.
