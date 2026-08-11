# Detection validation plan

Audit date: 2026-08-11

NOOP already has retrospective HR/motion workout detection, an opt-in suggestion
or auto-save flow, type suggestions, manual correction, and Swift/Kotlin parity
fixtures. It does **not** currently have a validated fall detector, and the app
must not imply that it can summon help or replace Apple Watch emergency features.

## Workout Detection V2

The next detector should be one versioned pipeline rather than a collection of
independent thresholds:

1. A low-power HR/motion gate finds candidate periods without keeping a radio in
   an expensive high-rate mode all day.
2. A retrospective segmenter joins short dips, rejects data gaps, and estimates
   start/end uncertainty.
3. A feature layer derives acceleration energy, jerk, rotation, cadence, HR
   reserve, HR slope, recovery slope and signal coverage. Missing channels remain
   missing; they are never filled with a neutral-looking zero.
4. A temporal model emits `workout`, `daily activity`, `unknown`, and calibrated
   sport suggestions. `Unknown` is a required result, not a failure.
5. Accepted, rejected, relabelled and boundary-edited suggestions become local
   feedback records tied to detector version and source capability.
6. A release model is promoted only after participant-, day- and device-held-out
   evaluation. A random window split is insufficient because adjacent windows
   from the same person leak identity and routine.

Every decision should retain detector version, available sensors, window
coverage, confidence/calibration and the top alternatives. The UI should say
`detected`, `suggested`, or `unknown`; it should not present an inferred sport as
a measured fact.

## Evidence and datasets

- [CAPTURE-24](https://www.nature.com/articles/s41597-024-03960-3) provides 2,562
  annotated hours from 151 participants in free-living conditions and explicitly
  highlights the generalization gap in small scripted datasets. It is the better
  starting point for the everyday-activity rejection class.
- [Self-supervised learning from 700,000 person-days](https://www.nature.com/articles/s41746-024-01062-3)
  shows a practical route for learning wrist-accelerometer representations from
  large unlabelled free-living data before a smaller labelled fine-tune. Its
  published benchmark uses 30 Hz, ten-second windows; NOOP should benchmark that
  recipe rather than assume its 100 Hz diagnostic stream must remain 100 Hz.
- [WEAR](https://arxiv.org/abs/2304.05088) supplies synchronized outdoor-sport
  inertial labels and temporal localization tasks. It is useful for boundaries
  and outdoor sport confusion, subject to its own dataset terms.
- [WEEE](https://www.nature.com/articles/s41597-022-01643-5) includes multiple
  devices, HR, IMU and indirect-calorimetry ground truth. It is useful for energy
  estimation research, not permission to claim consumer-calorie accuracy.

These datasets are research inputs, not app assets. Dataset licenses, participant
consent terms, sensor placement and label compatibility must be reviewed before
any download enters a training pipeline.

## Acceptance measurements

Report all of the following by device family and activity, not one accuracy
number:

- event precision/recall and false starts per wear-hour;
- median and 90th-percentile start/end boundary error;
- sport macro-F1 plus an explicit unknown-rejection curve;
- probability calibration (ECE/Brier), not just top-1 accuracy;
- performance for low/high HR responders and by held-out participant;
- performance with HR only, motion only, both, sparse streams and data gaps;
- CPU, memory, radio-on time and measured battery cost;
- change versus the currently shipped detector on a frozen replay corpus.

A detector update must be replayable by version and must never silently rewrite a
user-corrected workout.

### Proposed release gates

Before data collection, freeze the model, matching rules, primary endpoints and subgroup analysis in
a dated protocol. The numbers below are product-quality starting gates, not published clinical
standards, and may be made stricter after a blinded pilot; they must never be relaxed after looking at
the final test set.

- Keep a participant-held-out test set sealed until the model and thresholds are frozen. No window,
  day, workout or near-duplicate from a test participant may enter training or tuning.
- Include at least 50 held-out participants overall and at least 15 participants plus 30 positive
  events for every device family/activity combination NOOP labels as supported. Combinations below
  that floor remain `experimental` or `unknown`, even when their point estimate looks strong.
- Require event precision and recall of at least 0.85 overall, macro-F1 of at least 0.75 across the
  supported activity labels, and no supported device/activity stratum more than 0.10 below the overall
  event recall. Report confidence intervals rather than rounding a near miss upward.
- Require no more than 0.05 false workout starts per wear-hour, median boundary error no greater than
  two minutes, 90th-percentile boundary error no greater than five minutes, and expected calibration
  error no greater than 0.08 on the frozen set.
- Require measured incremental battery cost no greater than three percentage points over 24 hours on
  every supported phone/device pairing, with thermal state, radio time and background wake count
  reported. A failing pairing disables the high-rate path rather than borrowing another device's result.
- Two independent annotators adjudicate event type and boundaries; publish agreement and resolve
  disagreements without access to model output. Missing ground truth is `unknown`, not a negative.
- Any material feature, threshold, firmware parser or sensor-cadence change creates a new detector
  version and repeats the frozen replay plus a prospective shadow-mode check before auto-save expands.

## Fall detection boundary

Fall detection is a safety feature, not another workout label. Published results
show why a lab demo is not enough:

- A study using 143 real-world falls reported its best model above 80% sensitivity
  but about 0.56 false alarms per hour and an F-measure of 64.6%
  ([study](https://pubmed.ncbi.nlm.nih.gov/33202738/)).
- A real-world systematic review notes that rapid ordinary movements are often
  mistaken for falls and that controlled simulated-fall results do not transfer
  cleanly ([review](https://pmc.ncbi.nlm.nih.gov/articles/PMC11399740/)).
- An umbrella review found sensor placement materially changes performance, with
  trunk/foot/leg locations generally outperforming a single wrist sensor
  ([review](https://pmc.ncbi.nlm.nih.gov/articles/PMC8591794/)).

Therefore NOOP should add only a clearly labelled **impact research recorder**
before it adds any user-facing fall claim. A production emergency feature needs:

- ethically collected, consented owned-device data from opportunistically observed real falls and hard
  non-fall activities; NOOP must never ask a participant to induce a real fall;
- prior IRB/REC or equivalent independent ethics review where applicable, with a documented consent,
  withdrawal, adverse-event and emergency-response protocol;
- supervised simulated-fall sessions only when the study protocol, environment, spotters and participant
  eligibility make them acceptably safe; simulation must never be presented as real-world validation;
- data minimization, de-identification, retention/deletion limits and a participant-access/export policy;
- a multi-phase sequence (impact, orientation change, post-impact stillness), not
  a single acceleration threshold;
- an on-device cancel countdown, accessibility, local emergency contacts and
  independently tested delivery/failure handling;
- sensitivity, false alarms per wear-hour and time-to-alert measured prospectively;
- explicit unsupported states when the active device cannot provide continuous
  calibrated IMU data;
- legal, privacy and human-factors review.

Until those gates pass, NOOP should direct users who need fall alerts to a
validated platform feature and must never display “fall detection active.”

## Order of work

1. Freeze an anonymized, consented replay format and detector-version contract.
2. Add feature extraction from the already captured WHOOP 5/MG IMU stream behind
   the current opt-in diagnostics gate.
3. Evaluate the current rules as the baseline, then add calibrated V2 suggestions
   without changing auto-save defaults.
4. Ship local correction capture and a user-exportable validation bundle.
5. Only then consider an impact-research mode; do not combine it with emergency
   messaging in the same release.
