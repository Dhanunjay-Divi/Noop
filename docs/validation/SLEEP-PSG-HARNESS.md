# Sleep PSG validation harness

`SleepStagerRealPSGTests` is an opt-in measurement harness for comparing
NOOP's four sleep-stage labels with expert polysomnography (PSG). It is not a
clinical validation study and does not run in normal CI because the source
research data is not distributed with this repository.

## Data contract

Set `NOOP_WALCH_DIR` to a directory containing one JSON file per subject or
night. Each file must use this shape:

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
- Source data must be acquired and prepared under its own access, citation,
  and redistribution terms. Do not commit subject data or credentials.

## Run

```sh
cd Packages/StrandAnalytics
NOOP_WALCH_DIR=/absolute/path/to/prepared swift test \
  --filter SleepStagerRealPSGTests
```

Record the dataset revision, preparation code revision, selected nights,
exclusions, per-subject results, pooled confusion matrix, and command output in
a dated validation record. A passing harness only establishes behavior on that
fixed sample. It does not establish population performance, clinical validity,
or permission to make diagnostic claims.
