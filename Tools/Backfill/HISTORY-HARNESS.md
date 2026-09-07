# Long-history storage harness

`history-harness` creates deterministic synthetic 10-, 30-, 90-, and 365-day
stores through the production `WhoopStore` APIs. It measures the current
managed-storage candidate profile:

- raw auxiliary, optical, and motion detail: at most 7 days;
- essential heart-rate, R-R, activity, event, and battery detail: at most 30
  days;
- compact daily metrics, sleep, workouts, Journal, Apple aggregates, and metric
  series: the full requested history.

It also exercises the bounded transient raw outbox, calendar and metric reads,
day-level heart-rate aggregation, analysis fingerprints, storage attribution,
24-hour raw CSV export, WAL checkpointing, SQLite integrity verification, and
the cold restore handoff. Restore verification compares exact retained daily
metrics, generic metric-series values, sleep sessions, Journal entries,
workouts, Apple aggregates, battery samples, optical waveforms, raw-outbox
metadata and frame bytes, plus the exact 24-hour CSV bytes. The JSON report
lists every completed content check. Generated values are synthetic and
generated SQLite files are removed unless `--keep-databases` is explicitly
supplied.

Run:

```sh
cd Tools/Backfill
swift run history-harness \
  --days 10,30,90,365 \
  --output ../../docs/validation/HISTORY-HARNESS-2026-09-07.json
```

Host results do not prove physical-device memory, thermal, battery, background,
BLE, or sensor behavior. Local pruning remains conditional on an exact
server-validated, unchanged window.
