# Device support — roadmap & protocol notes

Last reviewed: **2026-08-27**

NOOP keeps every device integration behind an evidence-scoped transport boundary. A model is supported
only for the signals and workflows that its validated direct, platform-exchange, or import lane actually
provides. A shared service UUID, successful build, or compatible protocol fixture does not establish
future-model support. This file records the current boundary and the protocol facts already verified.

| Source | Status | How |
|--------|--------|-----|
| **WHOOP 4** | ✅ Stable | Local BLE live data and history; established production transport |
| **WHOOP 5 / MG** | 🧪 Implemented, experimental | Local BLE discovery, secure-session opener, standard HR/battery, and experimental history; representative physical-device validation remains required |
| **Generic BLE heart-rate straps** (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio HR-broadcast) | ✅ Shipped (v3.8.0), live HR + RR | Standard HR service `0x180D` / `0x2A37` |
| **Foreground Live mode** | ✅ Shipped, explicit opt-in | User-started high-rate HR (plus R-R when the source exposes it) while the Live surface/session is active; higher battery use is disclosed and the foreground demand is released on exit |
| **Continuous HRV background mode** | 🧪 Advanced opt-in, off by default | Separate from Live: keeps the detailed stream armed with background connection enabled, either overnight-only (fresh-install default) or 24/7; OS/device limits still apply |
| **Apple Watch / Apple Health** | ✅ Shipped on iPhone, permission-gated | Native HealthKit read/write, observer-driven hourly background refresh plus foreground catch-up, and a Watch app for explicit workout/breathing/interval experiences. This is not direct proprietary Watch BLE and ordinary HealthKit delivery is not a guaranteed second-by-second live feed. |
| **Android watches and apps via Health Connect** | ✅ Shipped, permission-gated | Native Health Connect import/writeback for supported records (including HR/RHR/HRV, exercise, sleep/stages, steps, energy, SpO₂, respiration, VO₂ max, body composition, absolute body temperature, and basal body temperature where a source supplies them). This is an exchange layer, not direct control of every watch, and source/OS cadence applies. |
| **Gym equipment (FTMS)** | ✅ Shipped | Standard Bluetooth Fitness Machine Service `0x1826`; live machine metrics and HR when the machine exposes it |
| **Fitness Age / Vitality / Wellness Age** | 🧪 Experimental | On-device; coverage-gated, non-clinical, and not WHOOP Age |
| **Xiaomi Smart Band 8 / 9 / 10** (Mi Band) | ✅ Shipped, **import lane** | Read the Mi Fitness iOS app's own SQLite, on-device (below) |
| **Xiaomi Smart Band — live BLE sync** | 🔬 Protocol researched, decoder not built | Mi protobuf-v2 over BLE GATT + `encryptKey` handshake (below) — hardware-gated |
| **Polar deep streams** (ECG / PPG / ACC / PPI) | 🔬 Pure PPI decoder built (`Packages/PolarProtocol` + `com.noop.polar`, tests green both platforms); live `PolarPMDSource` + ECG/PPG decode still to build | PMD service (below) — alpha, hardware-gated |
| **Garmin** | ✅ Export import; 🧪 standard-HR Live | Garmin wellness JSON and FIT/GPX/TCX activity files import locally. A Garmin/HRM that advertises standard `0x180D` can use the experimental live-broadcast lane. Proprietary deep BLE history, Body Battery recreation, device control, and Garmin cloud sync are not implemented. |
| **Amazfit / Zepp / Helio** | 🧪 Best-effort live HR only | Experimental isolated Huami driver reads standard `0x180D` when exposed, then the documented readable Huami HR characteristic. Models requiring vendor authentication remain unsupported; there is no deep history/sleep sync and NOOP never logs into the vendor cloud. |
| **Oura cloud import** | ✅ Shipped, opt-in | Cloud API v2 OAuth backfill with source provenance; separate from direct ring control |
| **Oura Gen 3 local BLE** | 🧪 Experimental, physically exercised | Clean-room auth, live HR/IBI, durable history drain, battery, and raw on-device sleep staging on a real Gen 3 |
| **Oura Gen 4 / 5 local BLE** | 🔬 Software-compatible, unvalidated | Shared clean-room framing and generation-aware GATT are implemented; representative physical-device validation remains required before either generation is called supported |
| **RingConn Gen 3** | 🧭 Apple Health bridge only; direct BLE unavailable | Import standard records that the RingConn app writes to HealthKit, preserving its source and delay. No public BLE SDK/GATT or documented Health Connect lane; proprietary apnea/vascular/readiness outputs are not recreated. |
| **Hume Band 2.0** | 🧭 Apple Health bridge only; direct BLE unavailable | Import only verified HealthKit categories written by the Hume app. No public BLE SDK/GATT, stable export schema, or documented Health Connect lane; Hume Pod body composition is not attributed to the band. |
| **Fitbit / Google** | ✅ Fitbit export import; no direct live lane | Local Google Takeout/Fitbit JSON import for sleep and stages, resting HR, and steps. Missing Fitbit fields remain absent rather than inferred. Automatic Google Health/cloud integration and proprietary Fitbit BLE are not implemented. |

## What “supports a device” means

NOOP has three deliberately separate integration lanes. A checkmark in one lane does not imply the
other two:

1. **Direct live source:** the app connects to an open/decoded BLE service and receives what that service
   actually emits. Standard HR straps can provide HR and R-R; an FTMS machine can provide workout data;
   neither becomes a sleep/temperature/SpO₂ tracker by inference.
2. **Platform exchange:** Apple Health/HealthKit and Android Health Connect expose records another watch
   or app has already written, with user permission. Refresh timing and available metrics are controlled
   by the source platform, device, region, permissions, and OS scheduling.
3. **Owner-data import:** WHOOP CSV, Apple Health XML/Shortcuts, Xiaomi Mi Fitness SQLite, Oura/Fitbit/
   Garmin exports, and FIT/GPX/TCX files are parsed locally. This is historical import, not a persistent
   account connection or a live device driver.

If a device does not measure or export a required input, NOOP keeps that metric unavailable and marks
dependent outputs as not ready. It does not synthesize body temperature, calibrated SpO₂, HRV, sleep
stages, or another vendor's proprietary score from an unrelated signal. A wearable may bank readings
while the phone is away and upload them later **only when that device/protocol actually exposes a history
offload or its vendor/platform later writes the records**; NOOP cannot trigger unsupported sensors or
recover history that the device never exposes.

### Current direct-device boundary

- WHOOP 4 is the stable direct transport.
- WHOOP 5 and MG discovery, session opening, live HR, battery routing, and experimental history are
  implemented. They still require the physical overnight, reconnect, background, haptic, battery, and
  firmware matrix. A future WHOOP family is unsupported until its advertising, GATT, framing, and storage
  behavior are measured.
- Oura Gen 3 is the only direct Oura lane exercised on physical hardware. Gen 4 and Gen 5 retain
  generation-aware software paths but remain experimental until validated on those devices.
- Garmin support means local owner-data import and standard Bluetooth Heart Rate Service broadcast when a
  device exposes it. It does not mean proprietary Garmin history sync, Body Battery parity, cloud account
  integration, or control of every Garmin watch.

Platform references: [Apple HealthKit](https://developer.apple.com/documentation/healthkit),
[Apple Watch workout sessions](https://developer.apple.com/documentation/healthkit/running-workout-sessions),
and [Android Health Connect](https://developer.android.com/health-and-fitness/health-connect).

The device-by-device measured/derived feature comparison, validation gates, and current
WHOOP/Oura/RingConn/Hume source evidence are maintained in
[`COMPETITIVE_CAPABILITY_AUDIT.md`](COMPETITIVE_CAPABILITY_AUDIT.md).

### RingConn and Hume bridge boundary

- **RingConn Gen 3:** official support documents Apple Health writes for selected
  standard values, often after vendor-app processing/sync. Treat these as delayed
  HealthKit imports, not a live ring connection. Official material indicates about ten
  days of offline storage, but NOOP cannot drain that storage without the RingConn app.
- **Hume Band 2.0:** Hume documents an Apple Health integration but does not publish a
  stable list of exported HealthKit types. Enable a category only after a real device/app
  proves its type, units, source bundle, correction behavior, and cadence. Hume describes
  about seven days of local storage; NOOP cannot directly drain it.
- Neither vendor documents a public direct-BLE SDK/GATT service or Health Connect path.
  Google Fit is not interchangeable with Health Connect. A direct lane remains unavailable
  unless a vendor SDK or separately documented clean-room, hardware-validated protocol is
  completed.
- RingConn's vascular/BP and apnea outputs and Hume's metabolic/age/risk outputs are
  vendor-derived wellness products. They are not silently reconstructed from HR/HRV/SpO2.
  Hume's current official pages conflict on BP availability, battery duration, and export;
  the conservative state wins until shipping hardware resolves the conflict.
- HealthKit source metadata, measurement time, import time, last vendor sync, missing
  intervals, and staleness must remain visible. `Unsupported`, `not exported`, and
  `waiting for vendor sync` are valid states; none may render as `0`.

### Health Connect temperature and scheduling boundary

- The pinned Android SDK exposes separate `BodyTemperatureRecord` and
  `BasalBodyTemperatureRecord` types. NOOP stores them as absolute `body_temp` and
  `basal_body_temp` °C series under the `health-connect` source.
- That SDK does **not** expose a distinct skin-temperature or sleeping-wrist-temperature record type.
  A body-temperature record whose measurement-location metadata says wrist is therefore still body
  temperature; it is never relabelled as Apple `wrist_temp` or WHOOP `skin_temp`/temperature deviation.
- Manual import reads the available history. Automatic catch-up uses a bounded 35-day window. It runs
  on app open wherever Health Connect is available. Android 15+, and Android 14 once U extension 13 is
  installed, may additionally grant the dedicated background-health permission for best-effort periodic
  WorkManager runs. Earlier platform/provider versions remain foreground/on-open only, and OS scheduling
  is never guaranteed.
- Permissions remain granular: any already-granted record types continue importing. Existing users get
  an explicit in-app affordance to add body- and basal-temperature read access; NOOP does not treat a
  partial grant as consent to every Health Connect category.

## Polar Measurement Data (PMD) — verified protocol

Source: official `polarofficial/polar-ble-sdk` (cross-verified). Lets us read ECG/PPG/ACC/PPI from a
Polar H10 / Verity Sense / OH1 the user owns, account-free, on top of the standard HR service.

- **Service UUID:** `FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8`
  - **Control Point char:** `FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8` (write + indicate)
  - **Data (MTU) char:** `FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8` (notify)
- **Measurement-type codes (u8):** ECG `0`, PPG `1`, ACC `2`, PPI `3`, GYRO `5`, MAGNETOMETER `6` (mask `0x3F`).
- **Control-Point opcodes:** GET_MEASUREMENT_SETTINGS `1`, REQUEST_MEASUREMENT_START `2`, STOP_MEASUREMENT `3`.
  Start request byte = `(recordingType << 7) | measurementType`; settings are `[SettingType, len, data…]`
  blocks where SampleRate `0x00`, Resolution `0x01`, Range `0x02`.
- **Data frame:** `data[0]` = measurement type; `data[1..8]` = 64-bit little-endian timestamp (ns since
  2000-01-01 UTC); `data[9]` = frame type (`& 0x7F` = type, `& 0x80` = delta-compressed); payload from `data[10]`.
  - **ECG** type-0: 24-bit signed µV samples.
  - **ACC** type-0/1/2: 8/16/24-bit signed X/Y/Z (milli-g).
  - **PPI** type-0: `byte0` HR, `bytes1-2` peak-to-peak interval (ms), `bytes3-4` error estimate (ms),
    `byte5` flags (bit0 invalid, bit1 poor/no skin contact, bit2 contact unsupported).
  - **PPG** type-0: three 24-bit channels + ambient.
- **Per-model streams:** **H10** = ECG (130 Hz) + ACC + HR + RR (no PPG); **Verity Sense / OH1** =
  PPG + PPI + ACC + GYRO + HR (no ECG).

**Decoder status.** The pure PPI decoder is built and tested on both platforms
(`Packages/PolarProtocol` / `com.noop.polar.PmdDecoder`): frame header (type `& 0x3F`, ns timestamp,
frame-type/compressed bit) + PPI samples (HR + peak-to-peak interval + error estimate + flags). PPI is
the one NOOP needs — HR + inter-beat interval for HRV, no ECG peak detection required. **Still to build:**
the live `PolarPMDSource: LiveHRSource` (CoreBluetooth / android.bluetooth — hardware-gated, validate on
an H10/Verity), and ECG/PPG/ACC decode if ever needed. **Confirm on hardware:** the PPI flags' bit1/bit2
skin-contact polarity — the decoder names them per the Polar SDK, but this doc phrases them oppositely, so
no consumer should gate on them until a real device settles it.

**Open item — #421** ("Polar H10 paired, no live data", Android): the generic-HR plumbing is correct
(CCCD write + both notification callbacks); the leading theory is the WHOOP auto-reconnect reclaiming
the radio while the strap is active. Needs the reporter's detail + an H10 in hand to verify a fix.

## Xiaomi Smart Band (Mi Band) — shipped import lane

NOOP imports a Mi Band's full history **without Bluetooth, a Xiaomi account, or any
cloud** by reading the data the **Mi Fitness iOS app already stored on the phone**. This
is the same "import data you already own" model as the WHOOP-CSV and Apple-Health lanes,
and it's fully offline.

- **What the user does:** on the iPhone, *Files → On My iPhone → Mi Fitness*, long-press
  the folder → *Compress*, then bring that `.zip` to NOOP (*Data Sources → Xiaomi Smart
  Band*). The bare `<user_id>.db` or an unzipped folder (macOS) also work.
- **Where the data is:** `DataBase/<user_id>/de/<user_id>.db` — one SQLite row per sample
  with a JSON `value` column. NOOP opens it **read-only** (GRDB) and never writes to it.
- **Tables read** (`deleted = 0` only):
  - Day rollups → `dailyMetric` + `metricSeries`: `steps_day` (steps, distance),
    `calories_day` (active kcal), `heart_rate_day` (`avg_rhr` resting, avg/min/max + HR
    zones), `sleep_day` (total/deep/light/rem minutes, `sleep_score`), `stress_day`
    (`avg_stress`, 0–100), `spo2_day` (`avg_spo2`), `intensity_day`, `valid_stand_day`,
    `vitality` (`latest_accumulated_vitality`).
  - `sleep` (interval) → `sleepSession`: each row's `items[]` is the **real per-epoch
    hypnogram** (`{start_time, end_time, state}`), giving NOOP a native
    `[{start,end,stage}]` timeline rather than just stage totals.
- **Sleep-stage codes** (verified against a real Mi Band 10 export):
  `1 = awake, 2 = light, 3 = deep, 4 = REM, 5 = awake-in-bed` → NOOP `wake/light/deep/rem`.
- **Not present in the export** (left `nil`, NOOP derives what it can): HRV, recovery,
  respiration rate, skin temperature.
- **Partition:** all rows land under `deviceId = "xiaomi-band"`, so it appears as its own
  Data Source for the per-source pages and cross-source consensus/compare views.

**Code:** parser `Packages/StrandImport/Sources/StrandImport/XiaomiBandImporter.swift`
(pure, re-derived from the public `artyomxx/xiaomi-band-ios-export` tool — **not** copied
from any GPL source); app glue `Strand/Data/XiaomiImporter.swift`; detection in
`ImportCoordinator`. Verified end-to-end against a real **450-day / 545-sleep** export.

## Xiaomi Smart Band — live BLE sync (researched, not built)

The chosen-but-deferred path. The band **is** reachable over BLE (Gadgetbridge supports
Smart Band 8/9/10 this way, no Classic-SPP/MFi needed), so a CoreBluetooth implementation
is feasible *in principle* on iOS — but it's a Gadgetbridge-scale reverse-engineer that
must be **re-derived, never GPL-copied**, and can only be built/verified with the physical
band in an iterative BLE test loop. Verified facts to pick up from:

- **Stack:** "Xiaomi protobuf v2" — length-prefixed, chunked **protobuf** command/response
  frames over a vendor GATT service (the Mi ecosystem service is `0xFE95`; the data
  channel is a custom 128-bit service with write + notify characteristics — confirm the
  exact UUIDs by a GATT dump of *this* band).
- **Auth:** the per-device **`encryptKey`** (32 hex chars) the vendor app holds — the user
  already extracts it as `auth.key` via the same Mi Fitness export. Pairing is a
  nonce-exchange handshake (send phone nonce → receive watch nonce → derive session keys),
  after which traffic is **AES-CCM** encrypted with **HMAC** integrity. NOOP would take the
  key as a one-time **user-pasted value** (same stance as the Amazfit/Zepp lane) and never
  log into the Xiaomi cloud.
- **Data fetch:** once authenticated, request **activity sync** — the watch streams the same
  per-minute samples and sleep/stage records that the import lane reads from the DB, so the
  decode target (and the `xiaomi-band` store shape) is **already built and verified**. Live
  sync is "only" the transport + crypto + protobuf layer in front of it.
- **iOS caveat:** background BLE sync under a free signing identity is limited; treat live
  sync as a foreground "Sync now" action first.

This earns its place only if it stays tractable and never threatens WHOOP stability — it
will not ship blind.

## Oura Ring — BLE (experimental)

A clean-room BLE lane for a ring the user owns, alongside the shipped cloud import. **Experimental**
(`ExperimentalBrand`-gated, not a shipped supported strap). NOOP computes its **own** Charge/Rest from the
ring's raw signals and **never** reads Oura's encrypted readiness/sleep scores. Full byte-level spec:
[`OURA_PROTOCOL.md`](OURA_PROTOCOL.md); this is the where-we-stand summary.

**Working (validated on a live Gen 3):** app-auth handshake (nonce → AES-128 proof), live HR + IBI stream,
hardware-validated SyncTime (`0x12`/`0x13`) plus the ring-emitted `0x42` time-sync event as UTC anchors
(§6.11), hardware-generation correction from GetProductInfo, and a history drain aligned with open_oura
`drain_events` (per-batch cursor advance, `max=255`, quiet window → converges to `bytes_left 0`, no
re-serve loop). On both Apple and Android, terminal summaries request completion but keep the current
transport generation open for delayed TLVs. The barrier seals at the next real GetEvents request boundary,
and the durable cursor advances only after every associated stream write and sleep-session upsert succeeds.
A failed write, timeout, disconnect, stale callback, or unresolved time anchor leaves the cursor behind for
an idempotent retry. Unanchored history is never stamped with sync-arrival time. Teardown explicitly disables
and unsubscribes daytime HR. Decoded signals: HR/IBI, HRV
(`0x5D` + reconstructed), skin temp (`0x46`), SpO₂, battery. Own central/GATT — never the WHOOP path.

**Sleep — hypnogram persist (DRAFT PR #446).** The ring writes the whole night's SleepNet phase codes in one
burst after wake; NOOP reconstructs the time axis (30 s/code, end anchored by the `0x49` sleep-summary) and
banks it as a `CachedSleepSession` with a `[{start,end,stage}]` timeline under the ring's own deviceId, so
`SleepMerge`'s imported-over-computed rule surfaces Oura's staging (reusing the #988/HC stage-timeline path).
Cross-checks: **light** matches WHOOP/the Oura app well (±2–3 min); **deep/REM undercounted, awake over** vs
the Oura app — the raw on-device SleepNet stream ≠ the app's post-processed hypnogram (surfaced honestly with
an "Oura / raw on-device stages" badge). **Display-only** — traced: it does NOT feed the recovery score (Charge
is computed from the engine's own HR staging). **Open:** a main-night gate so junk daytime fragments don't win
a day (same class as the import-side fix **#375**); on-device multi-night validation.

**Activity / MET — `0x50` (DRAFT PR #447, Tier-B, never scored).** A plausible third-party MET decode
(PR #960): `state` byte + per-sample MET. Captured to a diagnostic JSONL corpus (`oura-activity-<id>.jsonl`),
never a durable/scoring row. **Validated:** MET tracks land-activity intensity — three walks read mean ≈ 4 MET
vs a ≈ 0.9 sleep floor, and per-minute MET vs a Suunto `.fit` speed profile correlates **r = 0.89**. It
underreads water, and the stream is sparse with **ring-side** cadence gaps (~86 % coverage) so daily totals
undercount. **NOOP has no MET field** in its HR/strain model, so `0x50` stays research only — the ring's path
into NOOP activity is HR, never MET, and it is never a step count.

**Banked IBI → HR — `0x80`.** The ring banks IBI records without a matching HR row. NOOP retains every
physiological IBI for R-R/HRV and materializes one conservative HR sample per record from the median valid
IBI (`round(60000 / median_ibi)`). Invalid intervals and implausible rates are omitted, never clamped.
Materialization is history-only, requires a real ring-time anchor, and participates in the same durable
cursor barrier as its R-R rows; live IBI and unanchored teardown fallbacks never mint historical HR.

**Analysis tooling:** `diagnostics/oura_met_crosscheck.py` cross-checks the MET + IBI-HR corpora against the
app SQLite (workouts/sleep) and, with `--suunto`, a `.fit` export — per-minute MET/HR profiles + correlations.

## Remaining deep/vendor lanes

The Garmin export and standard-HR-broadcast paths, the best-effort Huami live-HR path, and the Oura and
Fitbit import paths above already exist. What remains is materially different work: proprietary Garmin
deep-history sync, authenticated Amazfit/Xiaomi history, and automatic vendor-service connections. Those
lanes require a physical device or registered vendor application plus real consented test data. They stay
experimental or unavailable until validated end to end; a shallow HR/import lane must never be presented
as full-device parity.
