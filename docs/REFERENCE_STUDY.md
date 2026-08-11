# WHOOP reference study

## Purpose

This workflow lets NOOP learn from multiple owner-authorized WHOOP exports
without mixing people, leaking future observations into earlier predictions, or
mistaking a WHOOP-processed export for raw device data.

It supports two distinct questions:

1. **Export-feature exploration:** Given WHOOP-processed non-outcome physiology
   and sleep summaries, how does NOOP's transparent Charge/Rest shape compare
   with the official outcomes?
2. **Paired on-device validation:** Given a real NOOP raw-device scoring run and
   the later official export for the same person/days, did NOOP produce the
   expected daily outputs?

Only the second is end-to-end device-pipeline evidence. WHOOP exports do not
contain the raw BLE heart-rate, R-R, PPG, accelerometer, or temperature streams.

## Non-negotiable isolation

- Never import two study participants into the normal app database. The current
  app is a single-person product namespace.
- Never use `Tools/Backfill` for cohort work.
- Use random pseudonyms such as `P-7K4M`; never use an email, name, account ID,
  device serial, or an unsalted hash of one.
- Keep the vault outside git and outside cloud-synced folders. FileVault or an
  encrypted external volume is strongly recommended.
- Owners supply their own exports. Do not collect or retain WHOOP passwords.
- Free-text journals are out of scope by default. The harness counts journal
  rows for schema QA, then discards them immediately.

The default vault is:

```text
~/Library/Application Support/NOOP-Private/whoop-study/
  subjects/P-7K4M/whoop-export.zip
  subjects/P-7K4M/noop-daily.json
  manifests/study.json
  locks/split-v1.lock.json
  reports/
  audit/
```

Create it privately:

```bash
install -d -m 700 \
  "$HOME/Library/Application Support/NOOP-Private/whoop-study/subjects" \
  "$HOME/Library/Application Support/NOOP-Private/whoop-study/manifests" \
  "$HOME/Library/Application Support/NOOP-Private/whoop-study/locks" \
  "$HOME/Library/Application Support/NOOP-Private/whoop-study/reports" \
  "$HOME/Library/Application Support/NOOP-Private/whoop-study/audit"
```

Files should be mode `0600`; participant directories should be `0700`.

## Split before inspecting outcomes

Put the first agreed participants in `discovery` and the remaining participants
in `validation`. Every export from the same participant stays in the same role.
Add all participants before locking; adding people later requires a new study
revision and split.

Copy
`Tools/StudyHarness/Examples/manifest.example.json` into the private
`manifests/` directory and replace only pseudonyms and relative paths.

Seal the split:

```bash
swift run --package-path Tools/StudyHarness noop-study lock \
  --manifest manifests/study.json \
  --output locks/split-v1.lock.json
```

The command creates a 256-bit HMAC key outside the study directory, signs the
participant allocation, and hashes each reference export. Editing the split or
reference archive then fails closed.

## Audit, discovery, and holdout

```bash
swift run --package-path Tools/StudyHarness noop-study audit \
  --manifest manifests/study.json \
  --lock locks/split-v1.lock.json \
  --output reports/schema-audit.json

swift run --package-path Tools/StudyHarness noop-study discover \
  --manifest manifests/study.json \
  --lock locks/split-v1.lock.json \
  --output reports/discovery.json \
  --audit-output audit/discovery.private.json
```

The pre-freeze audit parses discovery subjects only. Validation schema and
coverage are intentionally withheld until the signed reveal.

Fit and HMAC-sign a conservative discovery-only candidate before revealing the
holdout. The current candidate is a bounded, equal-subject bias correction:
each discovery participant has equal influence regardless of history length,
and the raw transparent NOOP score remains available separately.

```bash
swift run --package-path Tools/StudyHarness noop-study fit \
  --manifest manifests/study.json \
  --lock locks/split-v1.lock.json \
  --candidate-id candidate-v1 \
  --output candidates/candidate-v1.json

swift run --package-path Tools/StudyHarness noop-study discover \
  --manifest manifests/study.json \
  --lock locks/split-v1.lock.json \
  --candidate candidates/candidate-v1.json \
  --output reports/discovery-candidate-v1.json \
  --audit-output audit/discovery-candidate-v1.private.json
```

Then reveal the holdout:

```bash
swift run --package-path Tools/StudyHarness noop-study validate \
  --manifest manifests/study.json \
  --lock locks/split-v1.lock.json \
  --candidate candidates/candidate-v1.json \
  --reveal-lock locks/validation-reveal-v1.lock.json \
  --output reports/validation.json \
  --audit-output audit/validation.private.json \
  --acknowledge-holdout-reveal
```

The reveal receipt binds that split to the first signed candidate and the exact
validation reference/device-output hashes. Re-running the same candidate and
inputs is reproducible; changing either fails closed. Validation reports omit
post-hoc calibration coefficients so the holdout cannot become a tuning hint.
If the holdout result causes a formula change, that holdout has become discovery
data. Use new unseen participants for the next final claim.

## When only an export is available

If `noopDailyOutput` is absent, the harness runs the
`export-feature-emulator`:

- official Recovery, Day Strain, Sleep Performance, Sleep Need, Sleep
  Consistency, and journals never enter the candidate inputs;
- Charge uses HRV, resting HR, respiratory rate, and NOOP Rest;
- Rest uses sleep duration, efficiency, deep/REM share, a fixed eight-hour need,
  and neutral consistency;
- each day's baseline is computed strictly from earlier days, then the current
  day is folded after prediction;
- Charge stays unavailable for the honest cold-start period.

This is useful for discovering score-shape differences. It is explicitly not a
test of BLE decoding, raw-signal cleaning, sleep staging, or sensor calibration.

## Paired on-device daily file

For true validation, record NOOP from the same wearer and dates, then supply a
daily aggregate matching
`Tools/StudyHarness/Examples/noop-daily.example.json`.

The loader rejects:

- a subject ID that does not match the manifest;
- duplicate or malformed days;
- unknown metrics;
- impossible values;
- missing score/pipeline revisions;
- any source label other than `noop-on-device`.

Official values and NOOP values remain separate. Exact-day pairs are compared
without writing either series into the app database.

## What can be evaluated

Direct export targets:

- Charge versus Recovery score;
- Effort versus Day Strain after the documented `100/21` conversion;
- Rest versus Sleep Performance;
- resting HR, HRV RMSSD, respiratory rate;
- total, light, deep, and REM sleep minutes;
- sleep efficiency;
- with later event-matching support: sleep onset/wake timing and workout
  duration, HR, zones, energy, strain, and distance.

Reference-only or external-label metrics:

- Fitness Age, Vitality/Wellness Age, stress, readiness, recovery forecasts, and
  cross-metric patterns have no direct WHOOP-export target.
- Cycle phase needs opt-in, user-confirmed period starts. It must never be
  presented as fertility, ovulation, pregnancy, or contraception guidance.
- Illness-pattern evaluation needs dated symptom/test labels and remains
  non-diagnostic.

Impossible from exports alone:

- raw BLE/PPG/R-R/IMU replay;
- epoch-by-epoch sleep-stage accuracy;
- raw optical ADC to calibrated SpO₂;
- WHOOP Age/Pace of Aging, Stress Monitor, proprietary alerts, or MG medical
  features.

Skin temperature is intentionally excluded from comparison for now. The parser
normalizes explicit Fahrenheit fields to Celsius, but WHOOP exports an absolute
skin temperature while NOOP's live recovery formula consumes a personal
deviation; those semantics must not be conflated.

## Report interpretation

The aggregate report contains no participant IDs, dates, paths, daily pairs,
raw values, journal content, or archive hashes.

Primary statistics give every participant equal weight:

- macro bias, MAE, and RMSE;
- subject median error and IQR;
- participant-bootstrap MAE confidence interval;
- equal-subject Fisher correlation.

Secondary pooled diagnostics include MAE, median/p90/p95 error, RMSE, Pearson
and Spearman correlation, concordance, Bland–Altman limits, calibration
slope/intercept, coverage, and Recovery band confusion.

With fewer than five participants, the report is labeled
`private-exploratory-do-not-share`; it can guide local debugging but cannot
support a population claim. The adjacent private audit receipt records
pseudonyms and input hashes for reproducibility and must remain in the vault.
