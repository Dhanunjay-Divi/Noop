# NOOP — On-Device Data Model

NOOP is a standalone, local-first companion app for WHOOP straps (4.0 and 5.0). It talks to
the user's own strap directly over Bluetooth Low Energy—no WHOOP cloud or account
is involved—and stores everything it decodes locally in a SQLite database. The
optional self-hosted service can receive a documented subset; it does not replace
this on-device database or turn it into a two-way cloud store.
This document describes the core on-device tables, their natural keys, and the
full migration map. `Database.swift` remains authoritative for every column and
index.

> **Scope note.** Interacting with the strap here means interoperating with the user's *own*
> device and the data it has already recorded. NOOP is **not affiliated with, endorsed by, or
> connected to WHOOP**, and it is **not a medical device** — none of the stored values are
> intended for diagnosis or treatment.

---

## Where the database lives

The persistence layer is the `WhoopStore` Swift package
(`Packages/WhoopStore`), built on [GRDB](https://github.com/groue/GRDB.swift) over SQLite. Like
every package in the repo, it declares both platforms — `.iOS(.v16)` and `.macOS(.v13)`
(`Packages/WhoopStore/Package.swift`) — and is UI-framework agnostic, so the same schema and
storage code back both the macOS app and the iOS app (the latter build-from-source only — see
`docs/IOS.md`).

The macOS app target opens the database at a fixed, per-user location
(`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

```swift
// Strand/Collect/StorePaths.swift
static func defaultDatabasePath() throws -> String {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                          appropriateFor: nil, create: true)
        .appendingPathComponent("OpenWhoop", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("whoop.sqlite").path
}
```

On a typical macOS install that resolves to
`~/Library/Application Support/OpenWhoop/whoop.sqlite`. Tests use an in-memory database via
`WhoopStore.inMemory()`.

### Connection configuration

`WhoopStore.init(path:)` (`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`) opens a
`DatabasePool` (a `DatabaseQueue` is used for in-memory tests) and applies these
settings before any query runs:

| PRAGMA | Value | Why |
| --- | --- | --- |
| `journal_mode` | `WAL` | Two handles to the same file (the BLE collector and the metrics repository) can read/write without deadlocking. |
| `synchronous` | `NORMAL` | Durable pairing with WAL — only an OS crash or power loss can lose the last transaction. |
| `cache_size` | `-16000` | ~16 MB page cache for multi-thousand-row import/backfill writes. |
| `mmap_size` | `268435456` | 256 MB memory-mapped I/O. |
| `temp_store` | `MEMORY` | In-memory temp tables. |
| `busyMode` | `.timeout(5)` | 5-second busy timeout under write contention. |

`WhoopStore` is an `actor`: GRDB calls enter through the actor, while the pool can
serve committed WAL read snapshots alongside the single writer. The migrator
(`makeMigrator()`, below) is the source of truth for what tables/columns exist and
currently runs through **v57** (`v57-analysis-dirty-source`).

---

## Schema at a glance

The schema falls into these groups:

| Group | Tables | Origin |
| --- | --- | --- |
| **Device/source registry** | `device`, `pairedDevice`, `dayOwnership` | BLE pairing, source capabilities, active/day ownership |
| **Decoded streams** (durable) | `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, `stepSample`, `ppgHrSample`, `sleepStateSample`, `ppgWaveformSample`, `rawImuSample` | Decoded from strap frames on-device |
| **Raw outbox** (transient) | `rawBatch` | Compressed raw BLE frames, prunable |
| **Bookkeeping** | `cursors`, `analysisDirtySource` | Highwater/read cursors and durable O(1) scoring invalidation |
| **Metric and user-data stores** | `sleepSession`, `dailyMetric`, `journal`, `workout`, `appleDaily`, `metricSeries`, `labMarker`, `liveSession` | Derived metrics, imports, user-entered labs, coaching sessions |
| **Body, nutrition, strength, and hydration** | `bodyMeasurement`, `nutritionEntry`, nutrition catalog tables, strength planning/session tables, `hydrationEntry` | Confirmed/imported body measurements and explicit user records |
| **Managed-sync bookkeeping** | Managed upload windows, dirty windows, restore checkpoints, document state, and document outbox tables | Optional NOOP+ transfer state; not evidence that a document was uploaded |
| **Oura raw archive** (durable, v25) | `ouraRaw` | Verbatim Oura API payloads behind the opt-in cloud import — see below |

All timestamp columns named `ts`, `startTs`, `endTs`, `capturedAt`, etc. are **unix seconds**
(integers). Day-keyed cache tables use a `day` text column in `YYYY-MM-DD` form and compare it
lexicographically.

---

## Migration history

Migrations are registered in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
(`makeMigrator()`) and run in order on every open.

| Version | What it adds |
| --- | --- |
| **v1** | Core tables: `device`, the four original decoded streams (`hrSample`, `rrInterval`, `event`, `battery`), and the raw outbox `rawBatch`. |
| **v2** | `cursors` key/value table for highwater bookkeeping. |
| **v3** | Type-47 biometric streams: `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`. |
| **v4** | Local metric caches: `sleepSession` (one row per session) and `dailyMetric` (one row per calendar day). |
| **v5** | Adds a `synced` integer delivery marker (default `0`) to the original eight decoded-stream tables. |
| **v6** | Adds nullable `charging` boolean to `battery` for the dense BATTERY_LEVEL series. |
| **v7** | Adds in-sleep signal aggregates to `dailyMetric`: `spo2Pct`, `skinTempDevC`, `respRateBpm` (all nullable). |
| **v8** | Adds `journal`, `workout`, and `appleDaily` (Apple-Health daily aggregates). |
| **v9** | Adds the generic long-format `metricSeries` table and its `(deviceId, key, day)` index. |
| **v10** | Adds the cumulative `stepSample` stream. |
| **v11** | Adds daily steps and estimated active calories. |
| **v12** | Adds PPG-derived `ppgHrSample`, kept separate from measured HR. |
| **v13–v14** | Add user-edited sleep-bound metadata without changing the detected natural key. |
| **v15–v16** | Add the paired-device/day-ownership registry and stable BLE peripheral identity. |
| **v17** | Adds user-entered `labMarker` records. |
| **v18** | Adds per-session sleep motion/state JSON columns. |
| **v19** | Adds the optional activity class to `stepSample`. |
| **v20** | Adds numeric journal values. |
| **v21** | Adds raw `sleepStateSample` rows. |
| **v22** | Adds `liveSession` coaching records. |
| **v23** | Adds daily raw optical red/IR aggregates. |
| **v24** | Adds R-R `seq` and widens the natural key to preserve equal same-second beats. |
| **v25** | Adds the opt-in Oura raw-payload archive. |
| **v26** | Normalizes legacy sleep-efficiency values to the canonical fraction. |
| **v27–v28** | Add packed PPG waveform and raw IMU sample stores. |
| **v29** | Adds the durable self-host delivery marker to `stepSample`. |
| **v30** | Adds partial indexes over pending self-hosted-sync rows. |
| **v31–v33** | Quarantine implausible future R-R rows and add stable R-R ordering/source-channel identity. |
| **v34–v38** | Add body measurements, workout steps, corrected device capability state, HealthKit sync state, and nullable sleep motion-quality evidence. |
| **v39–v43** | Add nutrition entries/catalog data, strength-training and set-rest state, and bounded Coach history memory. |
| **v44–v46** | Add exact sleep R-R evidence, daily HRV method provenance, and adaptive strength/gym planning. |
| **v47–v49** | Add on-demand remote-sync indexes plus durable sleep-state and PPG delivery outboxes. |
| **v50–v54** | Add managed-sync state, upload-window state, dirty-window tracking, snapshot restore checkpoints, and document synchronization state. |
| **v55** | Adds editable hydration entries and migrates the legacy scalar into a row projection. |
| **v56** | Adds managed-document tracking for hydration rows while retaining the client-encrypted/local-first transfer gate. |
| **v57** | Adds the per-source `analysisDirtySource` generation ledger and score-bearing stream triggers. Android carries the matching schema as Room v48. |

### Decoded-row remote-delivery markers

Migration v5 added `synced INTEGER NOT NULL DEFAULT 0` to the original eight
decoded streams, and v29 added it to `stepSample`. For the streams in the v1
wire contract (HR, R-R, event, battery, raw optical, raw temperature, raw
respiration, and steps), new rows start pending (`0`). The optional self-hosted
uploader changes exactly the uploaded natural keys to `1` only after the server
returns a matching accepted acknowledgement. A destination replay resets those
supported rows to `0`. `gravitySample` retains its v5 column but is outside the
current v1 upload contract.

These flags are delivery bookkeeping, not evidence that the complete local
database exists remotely. The v1 API omits several tables, including gravity,
sleep-state, PPG waveform, raw IMU, `rawBatch`, Oura raw pages, arbitrary
`metricSeries`, and lab/live-session records. Local deletion also does not send a
server tombstone.

---

## Device registry

### `device` *(v1)*

One row per strap the app has seen. Natural key is the device `id`.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | TEXT | **Primary key.** Stable device identifier. |
| `mac` | TEXT | BLE MAC address (nullable). |
| `name` | TEXT | Advertised/device name (nullable). |
| `firstSeen` | INTEGER | Unix seconds, set on first insert. |
| `lastSeen` | INTEGER | Unix seconds, bumped on every upsert. |

`upsertDevice(id:mac:name:)` (`StreamStore.swift`) inserts or, on `id` conflict, updates `mac`,
`name`, and `lastSeen` (it does not touch `firstSeen`). Every other table references the strap via
a `deviceId` text column, scoping all data per device.

---

## Decoded streams (durable record)

These eight tables are the **durable, compact local record** of what the strap measured. They are
decoded on-device from BLE frames by the `WhoopProtocol` package and written by
`WhoopStore.insert(_ streams:deviceId:)` (`StreamStore.swift`). The in-memory shapes are the
`WhoopProtocol` stream structs (`Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift`):
`HRSample`, `RRInterval`, `WhoopEvent`, `BatterySample`, `SpO2Sample`, `SkinTempSample`,
`RespSample`, `GravitySample`, aggregated into `Streams`.

All inserts are **idempotent by natural key** — they use `ON CONFLICT(...) DO NOTHING`, so
re-decoding overlapping frames (the common case during BLE backfill) never duplicates rows.
`insert(...)` returns the count of rows *actually* inserted per stream. Range reads live in
`Reads.swift` and follow a uniform shape: `WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts
ASC LIMIT ?`.

> The biometric stream structs carry a constant `unit` field (`"raw_adc"` / `"g"`) for JSON
> parity with golden fixtures, but `unit` is **not** a database column — only the numeric fields
> below are persisted.

### `hrSample` *(v1)* — heart rate

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `bpm` | INTEGER NOT NULL | Beats per minute. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts)`. HR is taken only from `REALTIME_DATA` (type 40) frames.
`latestHRSampleTs(deviceId:)` returns `MAX(ts)` here — the biometric "data frontier" used by the
stuck-strap watchdog.

### `rrInterval` *(v1)* — R-R intervals (HRV source)

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `rrMs` | INTEGER NOT NULL | Beat-to-beat interval, milliseconds. Part of PK. |
| `seq` | INTEGER NOT NULL DEFAULT 0 | *(v24)* Disambiguates equal intervals in the same timestamp bucket. Part of PK. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts, rrMs, seq)`. `seq` prevents a second equal R-R
interval in the same `REALTIME_DATA` timestamp bucket from colliding with the
first. Rows created before v24 were migrated with `seq = 0`.

### `event` *(v1)* — strap events

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Real RTC unix seconds (never offset). Part of PK. |
| `kind` | TEXT NOT NULL | Event name (e.g. `BATTERY_LEVEL(3)`). Part of PK. |
| `payloadJSON` | TEXT NOT NULL | Decoded payload as JSON. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts, kind)`. `payloadJSON` is serialized with `JSONEncoder`'s
`.sortedKeys` so the same payload is byte-identical every time — important for the natural-key
dedupe. Reads decode it back into `[String: ParsedValue]` with a shared, reused decoder.

### `battery` *(v1, +charging in v6)*

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Event RTC for BATTERY_LEVEL events, else `wallClockRef`. Part of PK. |
| `soc` | DOUBLE | State of charge (%), nullable. |
| `mv` | INTEGER | Millivolts, nullable. |
| `charging` | BOOLEAN | *(v6)* Nullable — only the dense BATTERY_LEVEL event series reports it; the command-response path leaves it `NULL`. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts)`. (Note: `batterySamples(...)` reads back only `ts, soc, mv`.)

### Type-47 biometric streams *(v3)*

These four mirror the original streams (per-row natural key `(deviceId, ts)`, `DO NOTHING`
inserts, identical range-read shape).

#### `spo2Sample` — pulse oximetry raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `red` | INTEGER NOT NULL | Red LED raw ADC. |
| `ir` | INTEGER NOT NULL | IR LED raw ADC. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts)`.

#### `skinTempSample` — skin temperature raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts)`.

#### `respSample` — respiration raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Self-hosted delivery marker: `0` pending, `1` accepted. |

**Primary key:** `(deviceId, ts)`.

#### `gravitySample` — accelerometer / gravity vector

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `x` | DOUBLE NOT NULL | Gravity vector X (g). |
| `y` | DOUBLE NOT NULL | Gravity vector Y (g). |
| `z` | DOUBLE NOT NULL | Gravity vector Z (g). |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5)* Legacy marker; gravity is not in the current v1 upload contract. |

**Primary key:** `(deviceId, ts)`.

---

## Raw outbox (transient, prunable)

### `rawBatch` *(v1)*

The raw outbox stores the strap's original BLE frames — compressed and batched — so the exact
bytes survive even for frames NOOP can't yet fully decode. Whereas the decoded streams are durable,
raw batches are **transient and prunable**. Implementation in `RawOutbox.swift`.

| Column | Type | Notes |
| --- | --- | --- |
| `batchId` | TEXT | **Primary key.** |
| `deviceId` | TEXT NOT NULL | Owning strap. |
| `capturedAt` | INTEGER NOT NULL | Unix seconds the batch was captured; pending reads order by this. |
| `deviceClockRef` | INTEGER NOT NULL | Strap-clock reference for the wall-clock offset. |
| `wallClockRef` | INTEGER NOT NULL | Wall-clock reference, unix seconds. |
| `startTs` | INTEGER NOT NULL | First frame timestamp in the batch. |
| `endTs` | INTEGER NOT NULL | Last frame timestamp in the batch. |
| `frameCount` | INTEGER NOT NULL | Number of frames packed. |
| `byteSize` | INTEGER NOT NULL | Size used for `storageStats()` totals. |
| `framesBlob` | BLOB NOT NULL | zlib-compressed packed frames (length-prefixed). |
| `syncedAt` | INTEGER | Legacy/pruning marker timestamp; `NULL` until explicitly marked. This is not a v1 self-host upload receipt. |

**Primary key:** `batchId`. Frames are packed as `[count u32 LE]{[len u32 LE][bytes]}×count`,
then zlib-compressed with a 4-byte uncompressed-length prefix.

`rawBatch` is not part of the self-hosted v1 payload. Its historical
`syncedAt` field is used by the local prune policy, while decoded sample tables
use their integer `synced` flags for remote delivery.

**Pruning policy** (`pruneRaw(now:keepWindowSeconds:maxUnsyncedBytes:)`): only batches with a
non-null `syncedAt` older than `now - keepWindowSeconds` are deleted — safe because the decoded
streams persist separately. Unsynced raw is **never** dropped (it is the sole copy of the strap's
not-yet-decoded bytes after a chunk is trimmed). `maxUnsyncedBytes` is accepted for call-site
compatibility but intentionally unused.

---

## Bookkeeping

### `cursors` *(v2)*

A simple key/value table for incremental-processing highwater marks (`Cursors.swift`).

| Column | Type | Notes |
| --- | --- | --- |
| `name` | TEXT | **Primary key.** |
| `value` | INTEGER | Stored cursor value (typically a timestamp). |

Helpers namespace the `name`: `highwater:<stream>` (upload/forward-only highwater) and
`read:<stream>` (pull cursor). The distinct prefixes keep the two cursor families from colliding
for the same stream.

### `analysisDirtySource` *(Apple v57 / Android Room v48)*

One row per nonblank source with score-bearing raw input. Inserts, deletes, and
score-column updates on `hrSample`, `ppgHrSample`, `rrInterval`,
`gravitySample`, `respSample`, `skinTempSample`, `spo2Sample`, `stepSample`,
`sleepStateSample`, and `event` advance `generation`. Transport-only `synced`
updates, battery rows, and raw waveform rows do not.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | **Primary key.** Source whose scoring input changed. |
| `generation` | INTEGER NOT NULL | Monotonic input generation advanced by triggers. |
| `acknowledgedGeneration` | INTEGER NOT NULL | Exact generation completed by the last successful analysis pass. |

Analysis reads a generation snapshot without clearing it, persists all required
derived output, then acknowledges only that snapshot. A crash or cancellation
before acknowledgement remains pending after restart. A concurrent raw write
advances beyond the snapshot and therefore remains dirty. Existing databases
seed one pending generation from the ten score-bearing tables; deleting all
data for a source removes this marker last, after raw-row delete triggers run.
The trigger insert path uses guarded `INSERT ... SELECT ... WHERE NOT EXISTS`
rather than a trigger-level conflict clause, so an outer SQLite UPSERT or
REPLACE cannot override the marker's conflict behavior.

---

## Metric caches

These tables hold **derived metrics and imported aggregates** rather than raw measurements.
Recovery / strain / HRV / sleep math is computed locally by the `StrandAnalytics` package, and
CSV / Apple-Health data arrives through `StrandImport`. Every cache table follows the same
contract: a `Codable` struct, an idempotent `ON CONFLICT(...) DO UPDATE` upsert keyed by its
natural key (latest value wins), and range-read accessors that run off-main.

### `sleepSession` *(v4)*

One row per sleep session (`MetricsCache.swift`, `struct CachedSleepSession`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Session start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | Session end, unix seconds. |
| `efficiency` | DOUBLE | Sleep efficiency, nullable. |
| `restingHr` | INTEGER | Resting HR, nullable. |
| `avgHrv` | DOUBLE | Average HRV, nullable. |
| `stagesJSON` | TEXT | Verbatim JSON array of stage segments (`[{start,end,stage}]`), nullable — stored as a string so the cache stays schema-agnostic about staging shape. |

**Primary key:** `(deviceId, startTs)`. Read by `startTs` range, oldest first.

### `dailyMetric` *(v4, +v7 columns)*

One row per calendar day (`MetricsCache.swift`, `struct DailyMetric`). This is the central
per-day rollup behind the dashboard. **Natural key `(deviceId, day)`** where `day` is
`YYYY-MM-DD`. All metric columns are nullable.

| Column | Type | Migration | Notes |
| --- | --- | --- | --- |
| `deviceId` | TEXT NOT NULL | v4 | Part of PK. |
| `day` | TEXT NOT NULL | v4 | `YYYY-MM-DD`. Part of PK. |
| `totalSleepMin` | DOUBLE | v4 | Total sleep, minutes. |
| `efficiency` | DOUBLE | v4 | Sleep efficiency. |
| `deepMin` | DOUBLE | v4 | Deep sleep, minutes. |
| `remMin` | DOUBLE | v4 | REM sleep, minutes. |
| `lightMin` | DOUBLE | v4 | Light sleep, minutes. |
| `disturbances` | INTEGER | v4 | Disturbance count. |
| `restingHr` | INTEGER | v4 | Resting heart rate. |
| `avgHrv` | DOUBLE | v4 | Average HRV. |
| `recovery` | DOUBLE | v4 | Recovery score. |
| `strain` | DOUBLE | v4 | Day strain. |
| `exerciseCount` | INTEGER | v4 | Number of exercises. |
| `spo2Pct` | DOUBLE | v7 | Mean SpO2 (%) during sleep. |
| `skinTempDevC` | DOUBLE | v7 | Skin-temperature deviation (°C) from baseline. |
| `respRateBpm` | DOUBLE | v7 | Mean respiration rate (breaths/min) during sleep. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first. The
`DailyMetric` struct's `init` defaults the three v7 fields to `nil` so older callers stay
source-compatible.

### `journal` *(v8)*

One user-answered daily prompt (`JournalWorkoutAppleCache.swift`, `struct JournalEntry`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `question` | TEXT NOT NULL | Prompt text. Part of PK. |
| `answeredYes` | INTEGER NOT NULL | `0`/`1`, mapped to/from `Bool`. |
| `notes` | TEXT | Free-text note, nullable. |

**Primary key:** `(deviceId, day, question)`. Read by `day` range, ordered `day ASC, question
ASC`.

### `workout` *(v8)*

One workout (`JournalWorkoutAppleCache.swift`, `struct WorkoutRow`). All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | End, unix seconds. |
| `sport` | TEXT NOT NULL | Sport/activity name. Part of PK. |
| `source` | TEXT NOT NULL | Origin of the row (e.g. import source). |
| `durationS` | DOUBLE | Duration, seconds. |
| `energyKcal` | DOUBLE | Energy, kcal. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `strain` | DOUBLE | Workout strain. |
| `distanceM` | DOUBLE | Distance, meters. |
| `zonesJSON` | TEXT | Verbatim JSON of HR-zone percentages — stored as a string so the cache stays schema-agnostic about zone shape. |
| `notes` | TEXT | Free-text note. |

**Primary key:** `(deviceId, startTs, sport)`. Read by `startTs` range, oldest first.

### `appleDaily` *(v8)*

Apple-Health-specific daily aggregates (`JournalWorkoutAppleCache.swift`, `struct AppleDaily`),
imported from an Apple Health `export.xml`. All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `steps` | INTEGER | Step count. |
| `activeKcal` | DOUBLE | Active energy, kcal. |
| `basalKcal` | DOUBLE | Basal energy, kcal. |
| `vo2max` | DOUBLE | VO₂max estimate. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `walkingHr` | INTEGER | Walking HR average. |
| `weightKg` | DOUBLE | Body weight, kilograms. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first.

### `metricSeries` *(v9)*

A generic **long-format / EAV** metric store (`MetricSeriesStore.swift`, `struct MetricPoint`).
Where the tables above use a wide column-per-metric layout, this is the tall counterpart: one row
per `(deviceId, day, key)` with a single REAL `value`. Any scalar metric — server-derived,
Apple-Health, journal-encoded, etc. — can be projected into this one table and read back uniformly
by key, which is the substrate for a metric explorer that lists and compares metrics without
knowing each source's schema.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `key` | TEXT NOT NULL | Metric identifier (e.g. `"restingHr"`, `"steps"`, `"recovery"`). Part of PK. |
| `value` | DOUBLE NOT NULL | The scalar value. |

**Primary key:** `(deviceId, day, key)`.

**Index** — `idx_metricSeries_device_key_day` on `(deviceId, key, day)`. The primary key orders by
`day` before `key`, so it can't efficiently serve per-metric range reads (`metricSeries(key:from:
to:)`) or `metricDays(key:)`, which scan `(deviceId, key)` and then walk days. This index makes
those reads index-only. Accessors: `upsertMetricSeries(...)`, `metricSeries(...)`,
`metricKeys(...)` (distinct keys for a device), and `metricDays(...)` (`MIN`/`MAX` day per key).

---

## Oura raw-payload archive

This section documents the lossless backstop behind the opt-in Oura history import
(off by default; user-initiated OAuth backfill — `docs/PRIVACY_SECURITY.md` §1.1b). It is
**not** a metric cache like the tables above — it stores verbatim API responses, not decoded
values, so any field Oura returns can be re-derived later without re-fetching.

### `ouraRaw` *(v25)*

One row per fetched PAGE of an Oura API endpoint response — not one row per Oura document; a
single page's `data` array can carry many documents (`OuraRawStore.swift`, `struct OuraRawRow`).
Written by `OuraSyncCoordinator.fetchRaw(_:dateParam:)` in the app target (`Strand/Oura/`).
Natural key `(deviceId, endpoint, documentId)`. Migration `v25-oura-raw`
(`Packages/WhoopStore/Sources/WhoopStore/Database.swift`) — additive only, a new table, no
existing row touched.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. `"oura-api"` for the live cloud-import lane. |
| `endpoint` | TEXT NOT NULL | Part of PK. Oura endpoint name, e.g. `"sleep"`, `"daily_readiness"`, `"heartrate"`. |
| `documentId` | TEXT NOT NULL | Part of PK. A SYNTHESIZED page key, `"<endpoint>-<startDate>-<pageIndex>"` (`startDate` is the backfill window's start date, `pageIndex` the fetched page's 0-based position) — never Oura's own document `id`, for any endpoint. |
| `day` | TEXT | `YYYY-MM-DD`, nullable. Currently always NULL — the coordinator never sets it. Reserved for a future per-document (rather than per-page) keying scheme. |
| `payloadJSON` | TEXT NOT NULL | Verbatim JSON body of the fetched page (the raw HTTP response, including its `data` array of documents) — losslessness holds at the page level, not the individual-document level. |
| `fetchedAt` | INTEGER NOT NULL | Unix seconds. |

**Primary key:** `(deviceId, endpoint, documentId)`. `upsertOuraRaw(...)` is idempotent on this
key via `ON CONFLICT(...) DO UPDATE` — re-pulling the SAME window (same `startDate`, so the same
`pageIndex` synthesizes the same `documentId`) overwrites that page's `day`/`payloadJSON`/
`fetchedAt` in place rather than duplicating.

**Index** — `idx_ouraRaw_device_endpoint_day` on `(deviceId, endpoint, day)`, so per-endpoint
reads (`ouraRaw(deviceId:endpoint:)`) scan `(deviceId, endpoint)` and walk `day` in order
without a table scan.

**Not covered by `deleteAllData(deviceId:)`.** Unlike the metric-cache tables above, `ouraRaw`
is not in `DeviceRegistryStore.deviceScopedTables`, so the general per-device wipe skips it by
construction. Disconnecting Oura calls the dedicated `deleteOuraRaw(deviceId:)` alongside
`deleteAllData(deviceId:)` (`Strand/Oura/OuraConnectModel.swift`) so the raw archive is purged
too, not left behind.

---

## Index summary

| Index | Table | Columns | Purpose |
| --- | --- | --- | --- |
| *(implicit PK)* | every table above | (its natural key) | Dedupe + primary lookup. |
| `idx_metricSeries_device_key_day` | `metricSeries` | `deviceId, key, day` | Index-only per-metric range reads. |
| `idx_ouraRaw_device_endpoint_day` | `ouraRaw` | `deviceId, endpoint, day` | Index-only per-endpoint range reads. |
| `idx_remoteSync_*_pending` | supported decoded streams | Natural-key prefix, partial `WHERE synced = 0` | Keeps v1 outbox scans proportional to pending rows. |

Most range reads start with the corresponding natural-key prefix. Additional
registry, lab, live-session, and pending-delivery indexes are listed
authoritatively in `Database.swift`.

---

## Provenance

NOOP's strap interoperability implementation is owner-controlled source in the
canonical repository and is based on observed wire behavior.

The frame parsing, CRC, and command/event/packet decode that feed the decoded-stream tables above
live in the `WhoopProtocol` package; persistence is `WhoopStore`; the local recovery / strain /
HRV / sleep math is `StrandAnalytics`; and the CSV / Apple-Health importers are `StrandImport`.

> **Reminder.** NOOP is not affiliated with WHOOP and is not a medical device. The
> local database remains on the user's device. A user who explicitly enables
> Self-hosted Sync sends the documented v1 subset to their configured server.
