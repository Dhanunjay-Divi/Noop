# Sleep PSG validation harness

`SleepStagerRealPSGTests` is an opt-in engineering harness that compares the
shipped default `SleepStagerV2` labels with expert polysomnography (PSG). The
first version of this harness called the legacy stager, so its reported figures
do not describe the shipped V2 implementation.

The fixture is PhysioNet `sleep-accel` (Walch 2019), using wrist motion, heart
rate, and expert-scored PSG. Research data is not distributed with this
repository.

## Corrected fixed-sample result

Six subjects and 5,720 scored epochs produced:

| Metric | Result |
|---|---:|
| 4-class epoch agreement | **61.6%** |
| Sleep/wake agreement | **91.6%** |
| Deep recall | **83.1%** |
| REM recall | **75.6%** |
| Wake recall | **10.0%** |

This is a measurement of one code revision on one fixed sample. It is not a
clinical validation study or a population accuracy claim.

The central limitation is wake recall. Overnight class imbalance allows high
sleep/wake agreement while only 10.0% of PSG wake epochs are detected. The
result must not be summarized as reliable wake or arousal detection.

Walch supplies motion and heart rate but no R-R intervals or respiration.
This exercises V2 under degraded inputs and does not establish performance with
the complete intended signal set.

## Why the harness bypasses session detection

The Walch motion stream contains long gaps. Running session detection first
would retain only the best-sampled part of each night and produce a biased
staging score. The harness therefore gives `SleepStagerV2.stageSession` the PSG
window directly and measures stage assignment inside that window.

`SleepDetectionGateDiagnosticTests` separately verifies that session detection
does not bridge source gaps beyond its configured limit. Staging agreement and
session-boundary detection are different questions and must remain separate.

## Data contract

Set `NOOP_WALCH_DIR` to a directory containing one JSON file per subject or
night:

```json
{
  "subject": "subject-id",
  "psgStart": 1700000000,
  "psgEnd": 1700028800,
  "labels": [[1700000000, 0], [1700000030, 1]],
  "hr": [[1700000000, 62], [1700000005, 63]],
  "grav": [[1700000000, 0.01, -0.03, 0.99]]
}
```

- Timestamps are Unix seconds.
- `labels` are 30-second PSG epochs: `0` wake, `1` N1, `2` N2, `3` N3,
  `4` N4, `5` REM, and `-1` unscored.
- `hr` contains heart rate in beats per minute.
- `grav` contains 1 Hz wrist acceleration as `x`, `y`, and `z` in g.
- Acquire and prepare source data under its own access, citation, and
  redistribution terms. Do not commit subject data or credentials.

## Exact reproduction

Run from the repository root:

```bash
python3 Tools/validation/fetch_walch_sleep.py \
  --subjects 6 \
  --raw /tmp/noop-walch/raw \
  --out /tmp/noop-walch/prepared

NOOP_WALCH_DIR=/tmp/noop-walch/prepared \
  swift test --package-path Packages/StrandAnalytics \
  --filter SleepStagerRealPSGTests
```

The downloader uses the standard library and the public PhysioNet dataset. The
test skips cleanly when `NOOP_WALCH_DIR` is absent. Preparation removes stale
JSON subjects from the output directory and writes `_manifest.json`; the test
requires that manifest and fails when the selected subject files differ from
it. Direct staging must cover 100% of scored PSG epochs, so uncovered epochs
cannot disappear from the agreement denominator.

For a new dated result, record the dataset version, preparation-script
revision, selected subjects, exclusions, code revision, pooled metrics,
per-subject metrics, and command output. Do not record raw health rows in git.

## Interpretation guardrails

- A passing XCTest means the harness contracts passed, not that a medical or
  accuracy threshold was certified.
- Do not compare a future result with 61.6% unless the fixture selection,
  mapping, and aggregation are unchanged.
- Do not use the 91.6% aggregate without also reporting 10.0% wake recall.
- Do not infer first-party band performance from a dataset without the complete
  intended signal set.
- Do not tune to these six subjects and report the same sample as validation.
