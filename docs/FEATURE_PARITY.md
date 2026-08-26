# Noop and WHOOP feature map

Last reviewed: **2026-08-22**

This document is the honest answer to “does Noop have everything WHOOP has?”
Noop aims for **data ownership and useful independent equivalents**, not a
pixel-for-pixel clone or a reproduction of WHOOP's proprietary formulas. Product
names, membership tiers, hardware capabilities, and regional availability can
change; the source links at the bottom are the reference point for this review.
The cross-vendor measured/derived/regulatory comparison and completion gates live in
[`COMPETITIVE_CAPABILITY_AUDIT.md`](COMPETITIVE_CAPABILITY_AUDIT.md).

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
| **P0** | WHOOP 5/MG hardware gate | The exact physical validation requirements are tracked in [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md); overnight history, reconnect, battery, and background behavior remain hardware-pending until that evidence is complete. |
| **P0** | Cross-source capability and freshness contract | WHOOP, Oura, RingConn, Hume, Apple Health, and Health Connect expose different signals and delays. Each value must preserve source, measured/derived/imported class, event/receipt time, coverage, and explicit unsupported/stale states; a missing input must never become zero or an inferred sensor reading. |
| **P1** | Validate advanced Strength analysis | The cross-platform trainer now includes an exercise catalog, routines, live set/reps/load/time/RPE entry, rest timer, editing, per-exercise history and all-time PRs, weekly session/set goals, factual muscle exposure, portable backup, and a Watch-to-iPhone routine handoff. Confidence-labelled automatic reps and an independently validated muscular-load model remain research programs. |
| **P1** | Finish advanced Sleep guidance | The cross-platform planner has Target, Balance, and Extra Opportunity goal modes, wake time, wind-down buffer, bounded debt recovery, confidence, reminders, per-day wake overrides, and recent behavioral timing context. Comparative stage/planner validation, a true chronotype model, In-the-Green parity, and physical travel/time-zone testing remain. |
| **P1** | Expand confirmed Coach actions | NOOP Coach now has durable user-managed memory, opt-in scheduled check-ins, voice/text Journal drafts, and reviewed Journal/routine writes on Apple and Android. Chat-driven workout/activity editing and broader structured actions remain; no model response may mutate records without explicit confirmation. |
| **P1** | Service integrations and complete restore | File imports are broad, and the cross-platform portable archive now restores validated nutrition entries/library items plus the normalized strength graph. Automatic Strava/Garmin/Fitbit sync and a server-to-device restore/tombstone protocol for every local dataset remain absent. |
| **P1** | Unified weekly goals and plans | Strength exposes weekly session and set goals and weekly digest/reporting exists. A cohesive planner spanning Sleep, Effort, steps, and strength still does not. |
| **P2** | Pregnancy trend companion, public teams/leaderboards, and clinician services | A private, opt-in educational pregnancy trend view can be built from user-entered dates and personal trends after clinical copy review. Risk assessment, diagnosis, fertility/contraception, public competition, team administration, and clinician services are separate product, safety, and regulatory investments. |
| **Research-only** | ECG/AFib classification, cuff-calibrated BP inference, apnea, and fall response | These require the appropriate sensors and references, prospective hardware/clinical validation, governance, regional handling, and potentially an independent regulatory path. Protocol clues or a detector prototype are not safe shipped medical/emergency features. |

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
| Sleep Planner / bedtime guidance | **Available / advanced guidance partial** | Noop builds tonight's plan from Target, Balance, or Extra Opportunity mode, wake time, wind-down buffer, and bounded recent-debt recovery. It shows calibration confidence and recent behavioral timing, supports per-day wake overrides, and schedules best-effort local-wall-clock reminders. Android re-arms after reboot and clock/date/time-zone changes. This is not a biological chronotype; comparative validation, In-the-Green parity, and physical travel/DST testing remain. |
| Journal and behavior effects | **Available / catalog breadth partial** | A local journal plus effect sizes and correlations shows which behaviors move the user's metrics, and WHOOP rows can be imported. Coach accepts voice or text, maps only recognized phrases into a reviewable draft, and writes selected Journal rows only after confirmation. WHOOP's full preset catalog and suggestion breadth remain larger. |
| Nutrition logging and insights | **Available / hosted services partial** | Noop supports editable per-meal calories/macros, nullable nutrients, meal metadata, CSV imports, recent repeats, barcode scanning/manual entry, Open Food Facts lookup, and a local saved food/meal library on Apple and Android. Imported daily summaries win per nutrient while manual meals fill only absent fields, avoiding silent double counting. Product data must be reviewed before save; image recognition, diet prescription, and hosted Cronometer-style sync remain absent. |
| Recovery Insights | **Available, independently** | Compare and Insights show exact-day bias, error, correlations, lagged relationships, and behavior effects. They are transparent statistical analyses, not WHOOP's generated narrative. |
| WHOOP Coach | **Available / action breadth partial, independently** | The optional Noop Coach uses a user-selected provider, including a local model, and receives a bounded summary rather than raw streams. Conversation history and user-managed memory are local and editable; opt-in check-ins are local notifications. Voice/text Journal and strength-routine drafts require review and confirmation. Chat-driven activity mutation and broader model-generated actions remain unavailable. |
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
| Activity detection and workout logging | **Partial, independent** | NOOP offers **Off / Ask**. Its local detector requires at least 10 minutes at personal resting HR + 30 bpm, a >90-second quiet tail, dense/plausible HR, no saved overlap, and motion confirmation when sufficiently observed; only short fragments up to **5 minutes** apart merge. Ask always waits for approval before writing a workout. A legacy Auto-save preference migrates to Ask because the detector exposes only uncalibrated event confidence; unattended saving remains unavailable until participant/device-held-out validation produces calibrated confidence. Its five broad type hints (walk, run, strength, cycle, ski) remain heuristic and synthetic-fixture-tested, not population-validated. WHOOP's classifier uses proprietary large-scale and contextual/personal-history signals; NOOP does not claim parity. |
| Heart-rate zones | **Available** | Five documented zones from estimated or user-supplied maximum HR, with time in zone. |
| Strength Trainer / muscular load | **Available / sensor analysis partial** | Noop imports Hevy/Liftosaur and provides a local manual trainer on Apple and Android: exercise catalog, routines, active sessions, editable sets/reps/load/time/RPE, rest timer, completed and per-exercise history, all-time PRs, weekly session/set goals, factual muscle exposure, portable backup/export, and external load × reps volume. Apple also supports a Watch-to-iPhone routine start handoff. Manual truth stays editable. Automatic rep recognition and a validated muscular-load model remain unavailable. |
| GPS routes | **Partial** | Manual distance workouts can capture a real route on iOS and Android when location permission is granted. Both platforms checkpoint an active route and restore an unfinished workout after process recreation; Android resumes its foreground location service, while iOS resumes its validated Core Location route anchor. Retrospectively detected/imported workouts do not manufacture a route. |
| VO₂ max | **Available, approximate** | Noop can import VO₂ max and can produce a local estimate when the required profile and activity inputs exist. It is not a lab measurement. |
| Stress Monitor | **Available, independently** | A local 0–3 wellness/autonomic-load proxy with trends. It is not WHOOP's proprietary Stress Monitor and is not a mental-health assessment. |
| Health Monitor | **Available, independently** | A local dashboard for recent biometrics, trends, Fitness Age, Vitality, and data quality. It is not a medical dashboard or a replacement for care. |
| Healthspan / WHOOP Age / Pace of Aging | **Partial, independent experiment** | Noop provides **Fitness Age**, **Vitality**, and an experimental **Wellness Age**. It does not calculate or claim WHOOP Age, biological age, or Pace of Aging. |
| Haptic alarm and on-wrist cues | **Available / experimental by device** | Firmware alarm, breathing cues, interval cues, HR-zone coaching, and test haptics are supported where the decoded command path works. |
| Weekly plans and goals | **Partial** | Weekly digest/reporting, notification targets, and editable strength session/set goals exist. NOOP does not yet expose one cohesive weekly Sleep, Effort, steps, and strength-goal planner. |
| Activity editing and merging | **Partial** | Manual/detected sessions can be reviewed, edited, relabeled, dismissed, and deduplicated. The local suggestion detector merges only candidate fragments separated by **up to and including 5 minutes** before presenting one window, avoiding accidental combination of separate workouts. NOOP still does not match WHOOP's chat-driven add/edit/delete workflow, graph-scrubbing time trim, or server-trained/personalized activity processing. |
| Safety Network / personal check-in | **Available, explicit SOS and non-emergency** | Onboarding and Safety invite two to five trusted contacts and keep a private reminder active until at least two have accepted. App confirmation or a configured repeated band SOS gesture creates one durable incident. Bounded SMS and voice rounds continue until acknowledgement, resolution, cancellation, failure, or expiry; acknowledgement cancels every unsent round. A signed responder page exposes only the newest location fix for the selected 8 or 12 hours, never a route. Idempotency, leases, retries, provider receipts, signed links, and DTMF prevent a single transient failure from becoming silent loss. Wellness/anomaly values never page, NOOP never dispatches emergency services, and carrier delivery or human response is not guaranteed. |
| Fall detection / emergency response | **Preparatory infrastructure; transport unavailable** | The API models a fail-closed possible-fall origin, but authenticated detector attestation is not implemented and the route always refuses new automatic fall incidents. The flag and allowlist are preparatory metadata, not an activation mechanism. Shipping clients construct no fall candidate. Physical staged-fall and hard-negative studies, participant/device-held-out performance, firmware authentication, background/haptic reliability, human-factors, carrier, legal, and regulatory evidence remain release gates. |

## Hormonal and clinical-adjacent features

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Menstrual-cycle / hormonal insights | **Partial, opt-in** | Noop offers coarse on-device phase awareness and a probabilistic next-period window from temperature/history. It is awareness only: not contraception, fertility prediction, or diagnosis. |
| Pregnancy coaching | **Not available; wellness companion feasible** | Noop does not currently provide pregnancy-specific coaching or normative comparisons. A future opt-in view may provide user-entered gestational context and personal seven-day trends with clinician-reviewed educational copy; it must not diagnose maternal/fetal conditions, predict complications, or delay care. |
| Blood Pressure Insights | **Not available** | Blood-pressure values may be recorded manually in Lab Book, but Noop does not estimate daily systolic/diastolic pressure from the strap. |
| ECG / Heart Screener | **Not available** | Protocol notes and experimental command identifiers are not a validated ECG feature. Noop does not display or interpret a diagnostic ECG. |
| Irregular Heart Rhythm Notifications | **Not available** | R-R rhythm views are not atrial-fibrillation detection, an irregular-rhythm notification system, or a diagnosis. |
| Advanced Labs | **Partial** | Lab Book can keep user-entered results alongside trends. Noop does not order tests, interpret them clinically, or provide a clinician network. |

## Ownership, ecosystem, and device operations

| WHOOP capability | Noop status | What Noop does, and what it does not claim |
|---|---|---|
| Cloud history and cross-device access | **Partial, self-hosted** | Optional FastAPI + TimescaleDB sync sends the supported v1 decoded/derived subset only to a server the user configures. Local collection works without it. A separate portable archive can move validated nutrition/library and strength records between Apple and Android, but the server remains an archive rather than a complete clone or two-way restore service. |
| Data export | **Available** | Local backup/export, JSON server APIs, and server export/deletion routes keep data portable. |
| Apple Health / Health Connect | **Partial** | Apple Health import/export paths and Android Health Connect data are supported in platform-specific ways; parity is not identical on all platforms. |
| Strava and training-service integrations | **Not available as live services** | FIT/GPX/TCX and several vendor exports can be imported, but NOOP does not currently provide Strava OAuth/two-way automatic sync, Withings, TrainingPeaks, Cronometer, or equivalent hosted connection management. |
| Widgets, Live Activities, and Watch | **Available, independently** | iOS provides Daily Signal, Vitals, and Sleep Home/Lock Screen widgets with destination-aware taps, plus a workout Live Activity, App Intents, Watch workout/breathing/interval surfaces, and complications. Android provides compact, standard, and wide Daily Signal widgets. Widget values are cached private snapshots, not guaranteed second-by-second streams. These are NOOP-native experiences, not copies of WHOOP's presentation. |
| Teams, leaderboards, and social community | **Partial, private and self-hosted** | Apple and Android Friends surfaces share accepted members' daily Charge, Effort, and Rest, with sleep duration, HRV, and resting HR controlled independently per friend. They upload no biometric summary values before acceptance and expose no history before the friendship's acceptance date. Friends is not end-to-end encrypted: the chosen server operator can inspect summary fields sent. There is no public discovery, follower model, team administration, ranking, or challenge product. |
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
| Friends scheduling, deletion, and trust | Apple foreground catch-up and Android WorkManager refresh are best effort; both also provide a user-driven refresh. Android retries retriable summary uploads with a stable batch identity, and an interrupted first join remains recoverable or can be deleted through its exact enrollment credential. **Leave & delete profile** removes the profile, credential, social graph, and dedicated Friends summary copy while preserving local data and a separate full backup. Friends is not end-to-end encrypted, so the chosen server operator can inspect fields actually sent. |

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
