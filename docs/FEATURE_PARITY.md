# Noop and WHOOP feature map

Last reviewed: **2026-07-24**

This document is the honest answer to “does Noop have everything WHOOP has?”
Noop aims for **data ownership and useful independent equivalents**, not a
pixel-for-pixel clone or a reproduction of WHOOP's proprietary formulas. Product
names, membership tiers, hardware capabilities, and regional availability can
change; the source links at the bottom are the reference point for this review.

## Status key

| Status | Meaning |
|---|---|
| **Available** | A working Noop feature exists. It may use transparent, independent math rather than WHOOP's formula. |
| **Partial** | Useful support exists, but an important WHOOP capability or platform path is still missing. |
| **Reference import** | Noop preserves the official value from a WHOOP export for comparison; it does not calculate that proprietary value. |
| **Not available** | Noop does not currently claim this capability. |

## Core scores, sleep, and coaching

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Recovery | **Available + Reference import** | **Charge** is calculated locally from transparent HRV, resting-HR, respiratory, sleep, and baseline logic. Official Recovery can be imported and plotted beside it. Charge is not WHOOP Recovery. |
| Strain | **Available + Reference import** | **Effort** is calculated locally from heart-rate reserve and training-load methods. Official Strain can be imported beside it. Effort is not WHOOP Strain. |
| Sleep duration, need, performance, consistency, and stages | **Available + Reference import** | Noop detects sleep, estimates stages, shows debt/need/consistency, and preserves imported official sleep sessions separately. Stage inference is non-clinical and will not exactly match WHOOP. |
| Sleep Planner / bedtime guidance | **Partial** | Noop shows sleep need, debt, trends, and a firmware smart alarm. It does not yet reproduce every WHOOP Sleep Planner recommendation or schedule flow. |
| Journal and behavior effects | **Available** | A local journal plus effect sizes and correlations shows which behaviors move the user's own metrics. WHOOP journal rows can also be imported. |
| Recovery Insights | **Available, independently** | Compare and Insights show exact-day bias, error, correlations, lagged relationships, and behavior effects. They are transparent statistical analyses, not WHOOP's generated narrative. |
| WHOOP Coach | **Available, independently** | The optional Noop Coach uses a key/provider selected by the user, including a local model. It receives a bounded summary, not raw streams. It is not WHOOP Coach and does not call WHOOP services. |
| Weekly/monthly performance reports | **Available, independently** | Trends, long-range charts, and an on-device shareable PDF cover recovery, sleep, HRV, resting HR, and effort. Layout and conclusions differ from WHOOP reports. |

## Biometrics, activity, and training

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Continuous heart rate and resting heart rate | **Available** | Direct BLE collection, local history, live display, trends, and workout curves. Completeness depends on device/firmware support and connection time. |
| HRV | **Available** | RMSSD and SDNN from R-R intervals with documented filtering. It is an estimate, not a diagnostic measurement. |
| Respiratory rate | **Partial** | Decoded raw inputs and/or imported values are stored with provenance. Noop does not relabel an uncalibrated raw ADC channel as a clinical respiratory reading. |
| Blood oxygen (SpO₂) | **Partial** | Imported/calibrated readings can be shown; raw red/IR ADC values remain explicitly raw. Noop does not manufacture an SpO₂ percentage from an unvalidated channel. |
| Skin temperature | **Partial** | Imported/calibrated readings can be shown; raw device values remain explicitly raw until a device-specific conversion is validated. |
| Steps and calories | **Available, approximate** | Noop uses decoded device data where supported and transparent estimates or Apple Health/Health Connect references elsewhere. Values may differ from WHOOP. |
| Activity detection and workout logging | **Available** | Automatic and manual sessions, duration, heart-rate curves, zones, average/max HR, energy, and Effort. |
| Heart-rate zones | **Available** | Five documented zones from estimated or user-supplied maximum HR, with time in zone. |
| Strength Trainer / muscular load | **Partial** | Noop imports Hevy/Liftosaur sessions and reports weight × reps as training volume. It deliberately does not fold volume into HR-based Effort or claim WHOOP's muscular-load model. |
| GPS routes | **Partial** | Workout/location support varies by platform. Noop does not yet promise feature-identical route capture and presentation on every platform. |
| VO₂ max | **Available, approximate** | Noop can import VO₂ max and can produce a local estimate when the required profile and activity inputs exist. It is not a lab measurement. |
| Stress Monitor | **Available, independently** | A local 0–3 wellness/autonomic-load proxy with trends. It is not WHOOP's proprietary Stress Monitor and is not a mental-health assessment. |
| Health Monitor | **Available, independently** | A local dashboard for recent biometrics, trends, Fitness Age, Vitality, and data quality. It is not a medical dashboard or a replacement for care. |
| Healthspan / WHOOP Age / Pace of Aging | **Available, independently** | Noop provides transparent **Fitness Age**, **Vitality**, and **Body Age** estimates. It does not calculate or claim WHOOP Age or Pace of Aging. |
| Haptic alarm and on-wrist cues | **Available / experimental by device** | Firmware alarm, breathing cues, interval cues, HR-zone coaching, and test haptics are supported where the decoded command path works. |

## Hormonal and clinical-adjacent features

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Menstrual-cycle / hormonal insights | **Partial, opt-in** | Noop offers coarse on-device phase awareness and a probabilistic next-period window from temperature/history. It is awareness only: not contraception, fertility prediction, or diagnosis. |
| Pregnancy coaching | **Not available** | Noop does not currently provide pregnancy-specific coaching or normative comparisons. |
| Blood Pressure Insights | **Not available** | Blood-pressure values may be recorded manually in Lab Book, but Noop does not estimate daily systolic/diastolic pressure from the strap. |
| ECG / Heart Screener | **Not available** | Protocol notes and experimental command identifiers are not a validated ECG feature. Noop does not display or interpret a diagnostic ECG. |
| Irregular Heart Rhythm Notifications | **Not available** | R-R rhythm views are not atrial-fibrillation detection, an irregular-rhythm notification system, or a diagnosis. |
| Advanced Labs | **Partial** | Lab Book can keep user-entered results alongside trends. Noop does not order tests, interpret them clinically, or provide a clinician network. |

## Ownership, ecosystem, and device operations

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Cloud history and cross-device access | **Partial, self-hosted** | Optional FastAPI + TimescaleDB sync sends the supported v1 decoded/derived subset only to a server the user configures. Local collection works without it. It is an archival API/dashboard, not yet a complete clone of every local table or a two-way client restore service. |
| Data export | **Available** | Local backup/export, JSON server APIs, and server export/deletion routes keep data portable. |
| Apple Health / Health Connect | **Partial** | Apple Health import/export paths and Android Health Connect data are supported in platform-specific ways; parity is not identical on all platforms. |
| Teams, leaderboards, and social community | **Not available** | Noop has no hosted social graph, team rankings, or public leaderboard. |
| Official firmware updates and device servicing | **Not available** | Keep the official app available for firmware updates, account/service operations, and any regulated WHOOP MG features. Noop must not be used to flash unknown firmware. |
| Subscription and hardware replacement benefits | **Not applicable** | Noop is software for hardware the user owns or is authorized to use. It does not replace membership logistics, warranty, or hardware replacement programs. |

## Self-hosted sync v1 boundary

Self-hosted Sync is useful now, but “sync” does not mean every byte in the
Apple/Android database is mirrored.

| Area | v1 behavior |
|---|---|
| Uploaded measured rows | Heart rate, R-R intervals, battery, raw optical red/IR, raw temperature and respiration channels, steps/cumulative counter samples, and protocol events |
| Uploaded derived/import rows | Supported daily metrics, Apple/Health Connect daily aggregates, sleep summaries with canonical stage totals, workouts, and journal answers |
| Not uploaded in v1 | Gravity vectors, band sleep-state samples, PPG waveforms/derived PPG-HR storage, raw IMU blobs, compressed raw-frame batches, Oura raw API pages, arbitrary `metricSeries`, labs, nutrition, hydration, mood, and per-epoch sleep motion/state JSON |
| Identity and provenance | Server `device_id` values are scoped by platform and app installation. `logical_source_id`, `paired_device_id`, namespace, score provenance, and (for Noop-computed rows) the algorithm revision preserve the source users recognize. |
| Updates and deletion | Upload is an idempotent archival upsert. A later value for the same natural key replaces that server row. A local deletion does not emit a tombstone; use the authenticated server dashboard/API to delete server data. Disconnecting only stops future upload. |
| Scheduling | Apple clients catch up on launch/foreground activation and when the user taps **Run now**; this is not a guaranteed iOS background task. Android additionally uses best-effort WorkManager scheduling. |
| Replay | A destination change/replay resumes in bounded pages. Raw pending rows are drained; supported derived history is currently capped at ten years. |

Keep local `.noopbak`/database backups for the complete device record and for
restore. The server v1 API is currently an archive/read/export surface, not a
server-to-app restore protocol.

The server validates each role against its provenance label:
`strap_measured` → `strap_measured`, `official_reference` →
`user_imported_whoop_export`, `noop_computed` →
`noop_transparent_algorithm`, `noop_journal` →
`user_entered_noop_journal`, and the Apple Health, Health Connect, activity-file,
and wearable-import roles → their corresponding `user_imported_*` labels.
Every source also declares `privacy=explicit_opt_in`; Noop-computed sources carry
their algorithm revision.

## Parallel WHOOP comparison and personal calibration

A user with an active WHOOP subscription can keep an official reference series
without surrendering the independent Noop series:

1. Wear and sync the strap with the official app as required for the user's
   normal WHOOP account.
2. Periodically request/download the WHOOP CSV export and import it in Noop.
3. Locally, Noop keeps imported official rows under the logical
   **`whoop-official-reference`** source and independent calculations under a
   **`-noop`** source. On the self-hosted server those logical sources live inside
   installation-scoped producer IDs, with `logical_source_id` metadata preserving
   the readable name. The two series are never silently merged.
4. Compare uses exact overlapping calendar days to report bias, MAE, RMSE, and
   correlation.
5. Once enough paired history exists, Noop may fit a personal display calibration
   on earlier days and accept it only when it improves untouched chronological
   holdout days. The original official and independent values remain unchanged and
   visible.

The comparison is periodic, not a private WHOOP API integration. The official app
and Noop may also compete for the same BLE connection, so “parallel” means
parallel history over the same dates—not a promise that both apps can stream from
one strap simultaneously. Close or disconnect one app when pairing the other.

Personal calibration is a presentation aid, not proof that Noop recovered a
proprietary formula. Changing a Noop scoring revision invalidates the old fit and
requires fresh validation.

## Official reference pages used for this audit

- [WHOOP membership features and benefits](https://support.whoop.com/s/article/Membership-Features-Benefits?language=en_US)
- [How WHOOP works](https://www.whoop.com/us/en/how-it-works/)
- [WHOOP Healthspan](https://www.whoop.com/us/en/thelocker/healthspan/)
- [WHOOP hormonal insights](https://www.whoop.com/us/en/thelocker/womens-hormonal-insights/)
- [WHOOP 2026 product updates](https://www.whoop.com/us/en/thelocker/2026-whats-new/)
- [WHOOP Recovery Insights](https://support.whoop.com/s/article/Recovery-Insights)
- [WHOOP AI guidance](https://www.whoop.com/us/en/thelocker/new-ai-guidance-from-whoop/)

See also [NOOP's feature guide](FEATURES.md), [privacy and security
model](PRIVACY_SECURITY.md), and the [medical/legal disclaimer](../DISCLAIMER.md).
