# Noop and WHOOP feature map

Last reviewed: **2026-08-11**

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

## Current parity priorities

NOOP already covers most of the daily product loop. The remaining work is not one
flat checklist: reliable sensor access has to come before matching downstream
screens that depend on those signals.

| Priority | Gap | Why it comes next |
|---|---|---|
| **P0** | WHOOP 5/MG deep history and overnight inputs | Live HR works, but firmware-dependent sleep, motion, temperature, SpO₂, overnight R-R/HRV, and respiratory inputs remain incomplete. Scores cannot honestly fill a missing measurement. |
| **P0** | Real-iPhone BLE validation | The Simulator verifies rendering and navigation, not CoreBluetooth. Bonding, background reconnect/offload, haptics, and overnight reliability need a physical iPhone and strap. |
| **P0** | WHOOP 5/MG v9.3.1 hardware gate | Software backports and the exact physical validation checklist are tracked in [`UPSTREAM_V9_3_1_AUDIT.md`](UPSTREAM_V9_3_1_AUDIT.md); #1154 remains hardware-pending until that report is complete. |
| **P1** | Full Strength Trainer | Imports and training volume exist; live sets/reps, exercise history and PRs, plans, muscle maps, and independently validated muscular-load logic do not. |
| **P1** | Complete Sleep Planner | Sleep need/debt, schedules, wind-down reminders, and alarms exist in parts. Goal-based wake modes, In-the-Green behavior, richer planning, and time-zone flows remain incomplete. |
| **P1** | Persistent, action-taking Coach and faster Journal entry | NOOP Coach is private/BYO-provider and useful, but does not yet keep user-managed long-term memory, initiate check-ins, mutate activities, build linked strength workouts, or turn free-form voice/text into journal rows. |
| **P1** | Service integrations and complete restore | File imports are broad, but automatic Strava/two-way service sync is absent. Self-hosted sync v1 is an archive, not yet a full device-to-device restore with tombstones for every local dataset. |
| **P1** | Weekly goals and plans | Weekly digest/reporting exists; a surfaced system for Sleep, Effort, steps, and strength goals does not. |
| **P2** | Pregnancy coaching, public teams/leaderboards, and clinician services | Private friend summaries now exist on a self-hosted server, but public competition, team administration, and clinical services are separate product/service investments. |
| **Research-only** | ECG/AFib classification and cuff-calibrated BP inference | These require validated MG acquisition, clinical governance, regional handling, and an independent regulatory path. Protocol clues are not a safe shipped medical feature. |

### Where NOOP is already ahead

- Direct BLE collection and an owner-controlled local/raw record for the signals each source actually
  exposes, without requiring a NOOP-hosted account.
- Transparent independent scores, provenance, paired WHOOP-export comparison, and
  holdout-validated personal display calibration.
- Optional self-hosted FastAPI + TimescaleDB archive under the user's control.
- Invitation-only, per-friend daily-summary sharing without a public directory or
  Noop-operated social graph.
- Native macOS, iOS, Android, widgets/Live Activity, and a Watch app with
  complications; WHOOP's current consumer experience does not list a native
  watchOS app.
- Broader owner-controlled imports and exports, including raw/protocol diagnostics.

## Core scores, sleep, and coaching

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Recovery | **Available + Reference import** | **Charge** is calculated locally from transparent HRV, resting-HR, respiratory, sleep, and baseline logic. Official Recovery can be imported and plotted beside it. Charge is not WHOOP Recovery. |
| Strain | **Available + Reference import** | **Effort** is calculated locally from heart-rate reserve and training-load methods. Official Strain can be imported beside it. Effort is not WHOOP Strain. |
| Sleep duration, need, performance, consistency, and stages | **Available + Reference import** | Noop detects sleep, estimates stages, shows debt/need/consistency, and preserves imported official sleep sessions separately. Stage inference is non-clinical and will not exactly match WHOOP. |
| Sleep Planner / bedtime guidance | **Partial** | Noop shows sleep need, debt, trends, and a firmware smart alarm. It does not yet reproduce every WHOOP Sleep Planner recommendation or schedule flow. |
| Journal and behavior effects | **Available / workflow partial** | A local journal plus effect sizes and correlations shows which behaviors move the user's own metrics, and WHOOP journal rows can be imported. WHOOP currently offers 160+ preset behaviors plus voice/text entry and suggestions; NOOP does not yet match that capture workflow. |
| Recovery Insights | **Available, independently** | Compare and Insights show exact-day bias, error, correlations, lagged relationships, and behavior effects. They are transparent statistical analyses, not WHOOP's generated narrative. |
| WHOOP Coach | **Partial, independently** | The optional Noop Coach uses a key/provider selected by the user, including a local model. It receives a bounded summary, not raw streams. It does not yet provide WHOOP's user-managed My Memory, proactive check-ins, activity mutations, voice Journal capture, or linked Strength Trainer generation. |
| Weekly/monthly performance reports | **Available, independently** | Trends, long-range charts, and an on-device shareable PDF cover recovery, sleep, HRV, resting HR, and effort. Layout and conclusions differ from WHOOP reports. |

## Biometrics, activity, and training

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Continuous heart rate and resting heart rate | **Available, with explicit power modes** | **Live** is an explicit foreground, high-rate HR session (plus R-R when the active source exposes it): the user starts it, the app keeps the stream armed only while that live surface/session is active, and the UI warns that it uses more phone and wearable battery. The separate advanced **Continuous HRV capture** switch is off by default and may hold the detailed stream in the background, either overnight-only (the fresh-install default) or 24/7; it also requires the background connection setting and remains subject to OS/device delivery limits. Stored-history completeness still depends on device and firmware support. |
| HRV | **Available** | RMSSD and SDNN from R-R intervals with documented filtering. It is an estimate, not a diagnostic measurement. |
| Respiratory rate | **Partial** | Decoded raw inputs and/or imported values are stored with provenance. Noop does not relabel an uncalibrated raw ADC channel as a clinical respiratory reading. |
| Blood oxygen (SpO₂) | **Partial** | Imported/calibrated readings can be shown; raw red/IR ADC values remain explicitly raw. Noop does not manufacture an SpO₂ percentage from an unvalidated channel. |
| Skin temperature | **Partial** | Imported/calibrated readings can be shown; raw device values remain explicitly raw until a device-specific conversion is validated. |
| Steps and calories | **Available, approximate** | Noop uses decoded device data where supported and transparent estimates or Apple Health/Health Connect references elsewhere. Values may differ from WHOOP. |
| Activity detection and workout logging | **Partial, independent** | NOOP offers **Off / Ask / Auto-save**. Its local detector requires at least 10 minutes at personal resting HR + 30 bpm, a >90-second quiet tail, dense/plausible HR, no saved overlap, and motion confirmation when sufficiently observed; nearby fragments up to **60 minutes** apart merge. Ask always waits for approval. Auto-save adds a 15-minute floor, stores the row as **Detected/NOOP**, posts a privacy-safe review notification when permission already exists, and exposes Keep / Not a workout plus normal edit/relabel/dismiss controls. Fresh installs default to Auto-save; existing on/off choices migrate to Ask/Off. Its five broad type hints (walk, run, strength, cycle, ski) remain heuristic and synthetic-fixture-tested, not population-validated. WHOOP's classifier uses proprietary large-scale and contextual/personal-history signals; NOOP does not claim parity. |
| Heart-rate zones | **Available** | Five documented zones from estimated or user-supplied maximum HR, with time in zone. |
| Strength Trainer / muscular load | **Partial** | Noop imports Hevy/Liftosaur sessions and reports weight × reps as training volume. It does not yet provide live set/rep/exercise tracking, per-exercise history and PRs, strength plans/goals, or an independently validated muscular-load model. |
| GPS routes | **Partial** | Workout/location support varies by platform. Noop does not yet promise feature-identical route capture and presentation on every platform. |
| VO₂ max | **Available, approximate** | Noop can import VO₂ max and can produce a local estimate when the required profile and activity inputs exist. It is not a lab measurement. |
| Stress Monitor | **Available, independently** | A local 0–3 wellness/autonomic-load proxy with trends. It is not WHOOP's proprietary Stress Monitor and is not a mental-health assessment. |
| Health Monitor | **Available, independently** | A local dashboard for recent biometrics, trends, Fitness Age, Vitality, and data quality. It is not a medical dashboard or a replacement for care. |
| Healthspan / WHOOP Age / Pace of Aging | **Partial, independent experiment** | Noop provides **Fitness Age**, **Vitality**, and an experimental **Wellness Age**. It does not calculate or claim WHOOP Age, biological age, or Pace of Aging. |
| Haptic alarm and on-wrist cues | **Available / experimental by device** | Firmware alarm, breathing cues, interval cues, HR-zone coaching, and test haptics are supported where the decoded command path works. |
| Weekly plans and goals | **Partial** | Weekly digest/reporting and several notification targets exist. NOOP does not yet expose one cohesive weekly Sleep, Effort, steps, and strength-goal planner. |
| Activity editing and merging | **Partial** | Manual/detected sessions can be reviewed, edited, relabeled, dismissed, and deduplicated. The local suggestion detector now merges candidate fragments separated by **up to and including 60 minutes** before presenting one window. NOOP still does not match WHOOP's chat-driven add/edit/delete workflow, graph-scrubbing time trim, or server-trained/personalized activity processing. |

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
| Strava and training-service integrations | **Not available as live services** | FIT/GPX/TCX and several vendor exports can be imported, but NOOP does not currently provide Strava OAuth/two-way automatic sync, Withings, TrainingPeaks, Cronometer, or equivalent hosted connection management. |
| Widgets, Live Activities, and Watch | **Available, independently** | iOS widgets, a workout Live Activity, App Intents, Watch workout/breathing/interval surfaces, and complications are present. These are NOOP-native experiences, not copies of WHOOP's presentation. |
| Teams, leaderboards, and social community | **Partial, private and self-hosted** | The iPhone and Mac Friends surface shares accepted members' daily Charge, Effort, and Rest, with sleep duration, HRV, and resting HR controlled independently per friend. It uploads no biometric summary values before acceptance and exposes no history before the friendship's acceptance date. It is not end-to-end encrypted: the chosen server operator can inspect summary fields sent. There is no public discovery, follower model, team administration, ranking, challenge, or Android Friends UI. |
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
| Friends consent and minimization | The client uploads no biometric summary values until at least one friend is accepted; empty replacement maps may still clear an older Friends window. It then uploads only the union of fields currently enabled for accepted friends, from six allowlisted, range-checked `noop_computed` daily values. Each friend reads only their own directional allowlist. Member credentials cannot read raw, export, workout, journal, sleep-stage, route, device, or admin APIs. |
| Friends storage and history | Friends writes through a dedicated logical `*-noop-friends` producer, separate from the full archive producer. A friend's feed begins on the friendship's acceptance date; earlier daily history is not projected. |
| Friends scheduling, deletion, and trust | Apple foreground catch-up is best effort and throttled to one automatic attempt per 15 minutes; it is not guaranteed background delivery. **Leave & delete profile** removes the profile, credential, social graph, and dedicated Friends summary copy while preserving local data and a separate full backup. Friends is not end-to-end encrypted, so the chosen server operator can inspect fields actually sent. |

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
- [WHOOP Activity and Sleep Detection](https://support.whoop.com/s/article/Automatic-and-Manual-Activity-Detection?language=en_US)
- [How WHOOP Detects and Labels Your Activities](https://www.whoop.com/us/en/thelocker/how-whoop-detects-and-labels-your-workouts-activities/)
- [WHOOP Recovery Insights](https://support.whoop.com/s/article/Recovery-Insights)
- [WHOOP AI guidance](https://www.whoop.com/us/en/thelocker/new-ai-guidance-from-whoop/)

See also [NOOP's feature guide](FEATURES.md), [privacy and security
model](PRIVACY_SECURITY.md), and the [medical/legal disclaimer](../DISCLAIMER.md).
