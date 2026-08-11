# Fitness Age

Last reviewed: **2026-08-11**

**Status:** shipped as an independent, non-clinical estimate. A weekly number you can read at a glance.

## What it is

Fitness Age is a **fitness comparison**, not a biological or clinical age and not WHOOP Age. It answers one question:
*"How does my cardiorespiratory fitness compare to the typical person, expressed in years?"* If your
Fitness Age is below your real age, your estimated fitness is better than average for someone your age;
if it's above, it's worse. That's the whole claim — it is **not** a measure of how old your body, cells,
or organs are, and it carries no medical meaning.

It is computed **on-device**, weekly, from data NOOP already has. Nothing is sent anywhere.

## Where the number comes from

The estimate is built on the **Nes 2011 non-exercise VO₂max model** from the HUNT3 fitness study — the
same family of equations behind the Fitness Calculator described by NTNU/CERG. NOOP independently turns
that estimate into an age comparison; it does not reproduce NTNU's current service or WHOOP's proprietary
Healthspan model. We use the
**waist-circumference variant** (confirmed coefficients):

```
Men:    VO₂max = 100.27 − 0.296·age + 0.226·PA − 0.369·waist(cm) − 0.155·RHR     SEE 5.70
Women:  VO₂max =  74.74 − 0.247·age + 0.198·PA − 0.259·waist(cm) − 0.114·RHR     SEE 5.14
```

- **RHR** is resting heart rate (a rolling 7-day median from the strap).
- **PA** is a physical-activity index (see below).
- **waist** is waist circumference in cm, from the profile if the user enters it.
- **SEE** is the model's standard error of estimate — roughly ±5.7 (men) / ±5.1 (women) ml/kg/min on the
  VO₂max itself. This is large. The number is a useful trend, not a lab measurement.

These coefficients were reproduced independently in **JAHA / Ball State 2020 (PMC7428991)** and are
corroborated by the **CERG/NTNU** group that authored the original work.

### The PA-index (a transparent local proxy, not the questionnaire)

The Nes model takes a **physical-activity index** that, in HUNT, came from the **HUNT1 PA-Q**
questionnaire (Kurtze 2008) — a short self-report of weekly exercise frequency, duration and intensity
whose multiplicative index spans **0–15**. NOOP does not administer that questionnaire. Its shipped
orchestrator instead uses a deliberately simple, documented reconstruction from its own seven-day data:

```
frequency factor = 0, 0.5, 1, 2.5, or 5 from active-day count
intensity-duration proxy = clamp(mean active-day Effort / 30, 0, 3)
local PA proxy = frequency factor × intensity-duration proxy  // 0...15
```

For this calculation, an active day has local Effort of at least 30. This preserves the published input's
numeric range without pretending that measured Effort is the same construct as a person's questionnaire
answers. The mapping is a **custom reconstruction**, not a validated substitute for HUNT1 PA-Q, and it can
systematically differ from the index the published model was trained on. The app therefore treats the
result as a trend-level estimate and exposes the method rather than presenting it as a calibrated survey.

### The Fitness Age itself needs no body measurement

The headline Fitness Age is computed by a **self-consistent inversion** of the same Nes equation. We
solve for the age at which a *population-reference* person — fixed at **RHR = 65** and **PA-index = 5** —
would have your estimated VO₂max. Because both the forward estimate and the inversion use the same
fixed reference body term, the **body/waist term cancels out** of the comparison. The result: the
headline Fitness Age is driven by your **resting HR and reconstructed activity** alone, and is shown
**without requiring any weight, height or waist entry**.

Waist circumference is used only to **unlock the explicit VO₂max estimate** (the ml/kg/min figure),
because this implementation uses the published waist-variant equation. Height and weight are not inputs
to that variant. Waist never sharpens, gates, or changes the Fitness Age number — the readiness UI groups
it under *"Unlocks your VO₂max"*, never under the age itself.

## Cadence and gating

- **One Saturday-keyed point per weekly bucket.** An analytics refresh may refine the current weekly
  point by upserting the same Saturday key; it does not create a new age point every day.
- **Trailing seven-day inputs.** RHR uses the median of observed values. Activity uses the number of
  qualifying active days and the mean Effort across those days, as shown in the PA-proxy formula above.
- **Two ≥4-of-7 coverage gates.** A week needs both resting-HR data and an observed activity value on at
  least 4 of its 7 days before a number is produced. Missing activity is never treated as sedentary.
- **Published-population gate.** The current coefficients are used only for a confirmed male/female
  profile aged 20–80. Unsupported or unconfirmed profile inputs produce no value instead of being routed
  through another coefficient set.
- **Model-error band.** The published VO₂max SEE translates onto this equation's age axis to roughly
  **±19 years for men / ±21 years for women**. This is a model-level communication aid, not a personal
  confidence interval; it is intentionally much wider than the old, unjustified ±5-year display.

The weekly results are stored in `metricSeries` under two keys, written to the computed `-noop` source:

| Key            | Unit       | Meaning                                              |
|----------------|------------|-----------------------------------------------------|
| `fitness_age`  | years      | the headline number (drives the UI)                 |
| `vo2max_est`   | ml/kg/min  | the explicit VO₂max estimate (only when waist given) |

The UI reads the latest `fitness_age` value only when its stored profile-provenance token still matches
the current profile. Age and sex are stamped beside Fitness Age; age, sex, and waist are stamped beside
the optional VO₂max estimate. Changing a stamped input marks older values stale, purges/recomputes the
computed-source copies, and the read path hides any unmatched row rather than briefly showing a number
calculated for the previous profile. Date of birth is the source of chronological age, so age advances
automatically instead of depending on a manually updated age field.

## Honesty disclaimer

- This is a **fitness comparison expressed in years**, not a biological age, a clinical assessment, or a
  diagnosis. It says nothing about disease, longevity, or how old your body "really" is.
- The underlying VO₂max model has a **large standard error of estimate** (SEE ≈ 5 ml/kg/min). Treat the number
  as a **direction of travel over weeks**, not a precise readout — which is why the app shows the broad
  model-error translation and presents one Saturday-keyed point per weekly bucket.
- It is a **non-exercise estimate**. A real graded exercise test on a treadmill or bike is the gold
  standard; this is a convenient proxy, nothing more.

## References

- **Nes BM, et al.** [*Estimating V̇O₂peak from a nonexercise prediction model: the HUNT Study,
  Norway*](https://pubmed.ncbi.nlm.nih.gov/21502897/). Med Sci Sports Exerc.
  2011;43(11):2024–2030. — the source model.
- **Kurtze N, et al.** [*Reliability and validity of self-reported physical activity in the
  Nord-Trøndelag Health Study: HUNT 1*](https://pubmed.ncbi.nlm.nih.gov/18426785/) (2008) — validation
  of the questionnaire behind the published PA input. It does **not** validate NOOP's measured proxy.
- **Ball State / JAHA 2020.** [*Accuracy of Nonexercise Estimated Cardiorespiratory Fitness in
  Americans*](https://pmc.ncbi.nlm.nih.gov/articles/PMC7428991/) — published reproduction of the Nes
  waist-variant coefficients used here.
- **CERG / NTNU.** [The Fitness Calculator](https://www.ntnu.edu/cerg/vo2max) — the research group's
  explanation of the model inputs and Fitness Age concept.
