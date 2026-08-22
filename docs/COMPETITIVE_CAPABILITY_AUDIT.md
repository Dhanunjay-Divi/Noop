# Wearable capability and evidence audit

Last reviewed: **2026-08-22**

This audit compares NOOP with the current public capabilities of Apple Watch, WHOOP,
Oura Ring 4, RingConn Gen 3, and Hume Band 2.0. It is a product and engineering contract, not a
marketing checklist. A feature is not "done" merely because a screen or formula exists:
the required sensor must be available, the acquisition path must be reliable, missing
inputs must remain missing, and the claim must match the evidence.

The source pages change. Re-check the official links in [Sources](#sources) before a
release that changes device support or health-related copy.

## Evidence vocabulary

Every value shown by NOOP must fit one of these classes:

| Class | Meaning | Required UI/provenance |
|---|---|---|
| **Measured signal** | A physical sensor produced the underlying observation: PPG, ECG voltage, accelerometer, peripheral temperature, or a cuff reading. | Source device, timestamp, unit, quality, and sensor/transport lane. |
| **Device-derived** | Firmware converted a measured signal into HR, R-R/IBI, SpO2, sleep stages, steps, or another output. | Name the device and preserve that the value was derived there. |
| **Vendor-derived** | A vendor app/cloud produced a score or prediction using a proprietary model. | Keep the vendor name and original score; never relabel it as NOOP-computed. |
| **NOOP-derived** | NOOP used a documented algorithm over declared inputs. | Algorithm revision, required-input coverage, uncertainty/calibration state, and an explanation. |
| **Imported/bridged** | Apple Health, Health Connect, a vendor API, or an owner export carried the value. | Original source app/device where available, event time, receipt time, and freshness. |
| **Regulated interpretation** | Software interprets a signal as a medical condition or clinical measurement. | Not shipped without the corresponding quality system, clinical validation, authorization, labeling, and post-market process. |

An unavailable input is not zero. A plausible estimate is not a measurement. A wellness
trend is not a diagnosis.

## Executive decision: can the remaining limitations be completed?

| Limitation | Can engineering complete it? | Honest completion gate |
|---|---|---|
| **Physical WHOOP/Oura validation** | **Yes, conditionally.** The software harness and fixtures exist; the missing input is representative hardware and repeatable wear sessions. | Test each supported model/firmware/OS combination for pairing, reconnect, live stream, overnight history, offline backlog, battery, time-zone/DST, app termination, and data quality. Publish the signed matrix and keep untested combinations experimental. |
| **Exact proprietary WHOOP score parity** | **No, not as an honest guarantee.** WHOOP does not publish its production transforms, weights, training data, or every input-quality rule. | Preserve official imported scores beside transparent NOOP scores; report bias/MAE/RMSE/correlation on overlapping days and allow only holdout-improving personal display calibration. Never call Charge, Effort, or Rest a recovered WHOOP formula. |
| **Fall detection** | **A research detector can be built; a dependable emergency feature cannot be declared from code alone.** | Multisensor real-device capture, staged falls and hard negatives, participant/device-held-out evaluation, sensitivity/false-alert/latency targets, cancellation UX, emergency-delivery testing, ethics review, and platform/regulatory review. Until then: research recorder only, no emergency promise. |
| **ECG / AFib** | **Raw MG ECG acquisition can be researched. Clinical classification cannot ship from protocol decoding alone.** | Validate waveform scale, lead/contact quality, sampling and loss against a reference; then undertake medical-device software, clinical, regional, labeling, and post-market work. R-R/Poincare views remain nonclinical and must not produce an AFib conclusion. |
| **Blood pressure** | **Not from the current NOOP sensor inputs.** A cuff-calibrated research model is possible but is not a substitute for clinical validation. | Use a compatible sensor or prospective cuff-ground-truth protocol, follow current cuffless-BP guidance, quantify calibration drift and subgroup error, and obtain any required authorization. Do not infer mmHg from HR/HRV/PPG alone in the consumer build. |
| **Pregnancy coaching** | **A careful educational trend companion is buildable. Clinical coaching is not currently justified.** | User-entered pregnancy dates/phase, explicit opt-in, seven-day personal trends, uncertainty and symptom-escalation copy reviewed by qualified clinicians, deletion/export, and no fetal/maternal diagnosis or normative verdicts. |
| **Full Strength Trainer** | **The manual product loop is implemented; sensor-derived load is not.** | NOOP has an exercise library, routines, live set/reps/load/time/RPE entry, editing, rest timer, completed/per-exercise history, all-time PRs, weekly goals, muscle exposure, Watch-to-iPhone handoff, import/export, portable backup, and transparent loaded volume. Manual truth remains editable. Automatic rep recognition and muscular-load claims require confidence UX and participant/device-held-out validation. |
| **Guaranteed background delivery** | **No on general-purpose iOS/Android.** The operating system and wearable decide when work runs and may suspend or terminate it. | Provide state restoration, bounded backlog replay, foreground catch-up, HealthKit/Health Connect observer paths, Android foreground service where justified, freshness/completeness UI, and explicit stale-data alerts. Say **best effort**, never guaranteed. |

## Capability landscape

The table distinguishes advertised outputs from what the hardware directly senses. A
check does not imply that a public API exposes the raw signal.

| Area | WHOOP 5 / MG | Oura Ring 4 | RingConn Gen 3 | Hume Band 2.0 | NOOP position |
|---|---|---|---|---|---|
| Optical/motion/temperature inputs | PPG, accelerometer, peripheral temperature; SpO2 derived. MG adds single-lead ECG contact hardware. | Green/red/IR optical sensing, accelerometer, digital peripheral-temperature sensor. | Public material supports optical pulse/SpO2, motion, and temperature trends but does not publish a complete sensor BOM. | Vendor states 5 LEDs, 4 photodiodes, accelerometer, and skin-temperature tracking. | Store only decoded/exposed signals with device, units, quality, and provenance. Raw ADC is not calibrated SpO2 or temperature. |
| Daily readiness/recovery | Proprietary Recovery. | Proprietary Readiness. | Proprietary wellness/readiness summaries. | Proprietary recovery/metabolic/longevity summaries. | Transparent **Charge** plus separately imported vendor references; no name or formula parity claim. |
| Activity/training load | Strain, HR zones, auto-detection, Strength Trainer. | Activity Score, goals, 40+ auto-detected activities; phone GPS for live route. | Steps, calories, activity intensity, limited workout modes. | Activity, strain, coaching. | **Effort**, zones, manual/GPS workouts, conservative five-class Ask detector, broad imports. Activity breadth and held-out validation remain gaps. |
| Sleep | Proprietary four-state staging, need/debt/planner, haptic alarm. | Four-state staging, Sleep Score, bedtime, chronotype/body clock. | Staging, score, vitals, breathing-interruption/apnea-risk wellness output. | Staging, score/efficiency, recovery debt. | Duration/stages/need/debt/consistency, three explicit planner goal modes, per-day wake overrides, behavioral timing context, wind-down reminders, and alarms exist. Staging/planner accuracy, biological chronotype, and physical travel/DST behavior still need validation. |
| Stress/resilience/illness | Stress Monitor, Health Monitor, Recovery drivers. | Daytime Stress, Resilience, Cumulative Stress, Symptom Radar. | HRV-derived stress and wellness summaries. | Stress/recovery/chronic-risk marketing outputs. | Local stress/autonomic proxy, illness-change patterns, cross-metric briefs, and explanations. Do not infer emotion, cause, disease, or diagnosis. |
| Haptics and behavior nudges | Strap haptics support alarms; WHOOP also offers guided breathwork, but public material does not establish every prompt as a strap vibration. | No haptic motor or on-ring vibration is documented in the Ring 4 specifications. | Gen 3 advertises configurable vibration for health shifts, sedentary reminders, and low battery. | No documented Band 2.0 haptic-reminder contract was found. | Guided breathing can pace the WHOOP strap or Apple Watch; opt-in stress, inactivity, and hydration nudges use privacy-safe gates. OS reminders are durable; a WHOOP buzz is best effort only while a fresh encrypted link is active. |
| Fitness/vascular age | WHOOP Age/Pace of Aging from nine documented contributor families but proprietary transforms. | Cardiovascular Age from PPG morphology; Cardio Capacity/VO2 estimate. | Vascular-load/BP trends, not an absolute BP sensor. | Physiological/biological-age and lifespan marketing outputs. | Fitness Age, Vitality, and experimental Wellness Age are transparent, coverage-gated, and nonclinical. Do not call them WHOOP Age or whole-body biological age. |
| Women’s health | Cycle/hormonal and pregnancy guidance; hormones are not measured. | Cycle and pregnancy trends; separate regulated fertile-window constraints and partner integrations. | Cycle/period/fertility predictions. | Limited public evidence for a mature women’s-health system. | Opt-in coarse cycle awareness exists. A pregnancy trend companion is feasible; contraception/fertility or risk claims are not. |
| ECG / rhythm | MG can record a 30-second ECG and, where authorized, classify certain rhythms. WHOOP 5 without MG has no ECG hardware. | No ECG or AFib diagnosis. | No documented ECG. | No documented ECG. | MG packet decoder and nonclinical R-R visualization exist; no diagnostic ECG display, AFib classifier, or irregular-rhythm notification is shipped. |
| Blood pressure | MG/Life provides cuff-calibrated wellness estimates with limitations; not real-time diagnosis. | No cuff-equivalent mmHg; selected-market nighttime pattern categories are not BP measurement. | Explicitly calls its output vascular/BP trends, not BP measurement. | Product copy conflicts: it advertises cuffless BP while its FAQ says a future update pending FDA review. | Manual cuff values may be logged. NOOP does not estimate systolic/diastolic pressure. |
| Sleep apnea | No diagnosis from the consumer sleep score. | SpO2/breathing regularity does not diagnose apnea. | Markets nonmedical sleep-apnea risk; public materials contain version inconsistencies. | No substantiated diagnostic lane found. | May show measured/imported SpO2 and breathing changes. No AHI or apnea conclusion without a validated, regulated program. |
| Fall response | No documented current WHOOP fall-detection product. | No documented fall detection. | No documented fall detection. | No documented fall detection. | Research-only until the emergency-feature gate above is met. |
| Offline memory and sync | Device banks data; exact behavior depends on model/firmware and official/direct protocol paths. | Up to 7 days on-ring; official API is cloud/app-sync dependent. | Official manual/support indicates about 10 days. | FAQ indicates about 7 days. | Show event time, last wearable sync, receipt time, completeness, stale status, and estimated retention deadline separately. |
| Battery claims | WHOOP advertises 14+ days for WHOOP 5. | Oura advertises 5–8 days. | Advertises 11–14 days under feature-dependent conditions. | Main page advertises up to 14 days; FAQ says typical continuous-use life can be 4–5 days. | Treat every battery figure as model/configuration-specific vendor data until measured in NOOP’s hardware matrix. |

## Integration truth by source

### Apple Watch

- The supported phone-side lane is **Apple Watch → Apple Health → permissioned HealthKit → NOOP**.
  NOOP does not pair to Apple's private Watch BLE protocol, and an iPhone HealthKit bridge is not a
  second-by-second Live substitute. The existing NOOP watch app owns only explicit experiences such as
  workouts; it does not grant the phone blanket access to every Watch sensor.
- Read availability is conditional on Watch model/region/settings, the category actually being recorded,
  the user's per-type Health permission, and a signed build carrying the HealthKit entitlement. NOOP may
  receive HR, Apple SDNN HRV, resting/walking HR, sleep/stages, workouts, steps/energy, respiration,
  VO2 max, and—on compatible Watch models—sleeping wrist temperature or SpO2. Missing categories remain
  unavailable; NOOP never substitutes WHOOP RMSSD for Apple's SDNN.
- HealthKit observer delivery is system scheduled. An entitled build can request background delivery and
  NOOP performs foreground catch-up, but neither the app nor the Watch can promise a fixed delivery time.
- A free/re-signed sideload that lacks Apple's Health entitlement cannot directly read HealthKit. The
  owner-data fallback is Health → **Export All Health Data** and local import. Imported XML remains a
  historical snapshot until the user exports again.
- Source metadata and event/receipt times stay attached, and Apple/WHOOP values remain separate series.
  Comparison can report overlap, coverage, bias, and disagreement; it must not average unlike HRV
  statistics or silently let one device overwrite the other.

### WHOOP

- WHOOP 4 direct BLE is the stable primary lane.
- WHOOP 5/MG remains experimental until the firmware/device matrix proves live and
  overnight history, reconnect, background recovery, haptics, and data integrity.
- The 2026-08-11 iPhone field session positively identified a WHOOP Life/MG as the 5-generation
  GATT family plus the standard DIS `WS50` MG board prefix (and a second MG serial-prefix family).
  Live HR, R-R, optical, steps, and sleep-state rows landed in the existing database without
  integrity loss. This closes the stale "WHOOP 4.0" label bug and supplies one real MG fixture; it
  does **not** close the multi-firmware overnight/backlog/background/haptics validation matrix.
- Model reconciliation now keeps the canonical paired-device row and legacy stream-owner row in
  one transaction. Known `WS50`/`WG50` or serial evidence can refine the display to exact
  **WHOOP MG**/**WHOOP 5.0**; missing or contradictory evidence stays generic and MG-only controls
  remain disabled.
- WHOOP's public export/API offers processed summaries, not every raw PPG,
  accelerometer, or MG medical stream. Official reference values must stay under a
  distinct source namespace.
- MG ECG and blood-pressure products have device, membership, age, geography,
  calibration, and contraindication boundaries. NOOP must not inherit WHOOP's medical
  authorization simply because it can parse a packet.

### Oura Ring 4

- The official scalable lane is Oura API v2 OAuth plus historical backfill,
  create/update/delete webhooks, encrypted token storage, idempotency, and freshness.
- The API exposes processed sleep/activity/readiness/stress/resilience, SpO2, HR,
  workouts, VO2 max, cardiovascular age, tags/sessions, battery, and configuration. It
  does not expose raw PPG/accelerometer/temperature, R-R series, women’s-health outputs,
  ECG, or a true live ring stream.
- Apple Health/Health Connect are privacy-friendly fallbacks but omit important Oura
  scores and signals. They must not be presented as full Oura parity.
- NOOP's clean-room direct BLE lane has live Gen 3 evidence; Gen 4/5 stay experimental
  until actual devices prove authentication, time anchoring, history, and integrity.
- Add a source-health card with last ring sync, last cloud receipt, missing nights, and
  the on-ring retention horizon. Never imply cloud receipt time is measurement time.

### RingConn Gen 3

- The currently supportable automated iOS lane is records RingConn writes to Apple
  Health, with original HealthKit source metadata and vendor-app delay disclosed.
- Official support describes roughly 30-minute writes for some standard values and
  post-generation sleep writes. This is not a live stream and proprietary readiness,
  apnea, vascular, stress, or cycle outputs may not be exported.
- No documented public BLE SDK/GATT protocol or Health Connect integration was found.
  Direct BLE and Android claims therefore remain unavailable unless the vendor supplies
  an SDK or a separately documented, hardware-validated clean-room lane is completed.
- Do not repeat RingConn's internal/vendor accuracy percentages as independent truth.
  Resolve the official compatibility and Gen 3 apnea-documentation inconsistencies on
  shipping hardware before broad support copy.

### Hume Band 2.0

- Apple Health is the only documented practical bridge found; Hume says processed
  values may appear after vendor sync. The exact exported categories and source IDs
  require on-device verification. Google Fit must not be called Health Connect.
- No public direct-BLE SDK/protocol, stable export schema, or official Health Connect
  lane was found.
- Hume Band alone does not measure body composition; that comes from the separate Hume
  Pod. NOOP must not attribute Pod values to the band.
- Hume's official pages conflict on BP availability, battery life, and direct export.
  Treat BP as unavailable, 14 days as best-case marketing rather than an operational
  guarantee, and export as unsupported until a real versioned sample is validated.
- Do not reproduce "medical-grade," disease-risk, personal-doctor, or lifespan language.
  The vendor's own safety material says the product is not a medical device.

## NOOP implementation order

### P0 — trustworthy inputs and validation

1. Make the cross-platform wearable capability catalog the release source of truth for
   acquisition lane, supported metrics, vendor-only outputs, and explicit absence.
2. Finish the physical WHOOP 5/MG and Oura 4 matrix. Archive only consented,
   de-identified diagnostic fixtures; never commit personal exports.
3. Surface sync health everywhere a delayed source is used: measurement timestamp,
   source-device timestamp if supplied, phone receipt, freshness, coverage, gaps, and
   retention risk.
4. Keep official/vendor scores, NOOP scores, and calibrated display projections as
   separate immutable series.
5. Enforce health-claim copy in CI so a later UI change cannot silently turn a wellness
   visualization into an AFib, BP, fall, clinical-grade, or guaranteed-background claim.
6. Keep source preference rank separate from evidence class. A preferred WHOOP export
   remains labelled as an import, device-firmware output as device-derived, and HealthKit
   or Health Connect values as health-data imports; winning a fusion tier never turns a
   processed or imported value into a "direct sensor" reading.

### P1 — high-value product parity

1. **Strength:** retain the shipped manual editor, per-exercise history/PRs, weekly
   session/set goals, factual muscle exposure, Watch-to-iPhone routine handoff,
   import/export, and transparent external-load volume. Keep automatic reps and
   muscular load unavailable until confidence UX and held-out validation are complete.
2. **Activity:** expand beyond five labels, add user-confirm/edit/dismiss feedback,
   preserve detector/firmware revision, and train/tune only on participant/device-held-out
   data with per-class precision/recall and false-prompts-per-day.
3. **Sleep:** build on the shipped Target/Balance/Extra Opportunity modes, wake and
   wind-down planning, debt bounds, per-day overrides, behavioral timing context, and
   local-wall-clock rescheduling. Add physical travel/DST tests, nap/main-sleep rules,
   source-by-source staging comparison, and any evidence-backed chronotype education.
4. **Women’s health:** local cycle/pregnancy logging and trend context with opt-in privacy,
   uncertainty, delete/export, and clinician-reviewed educational copy. Keep fertile
   window, contraception, complication, fetal-health, and diagnosis claims out.
5. **Coach/plans:** build on local user-managed memory, opt-in dismissible check-ins,
   voice/text Journal drafts, and confirmed Journal/routine writes. Add broader
   explainable goals and activity actions only with preview, confirmation, undo, and
   deterministic audit history.
6. **Oura cloud completeness:** ingest the supported v2 endpoints, deletes, backfill,
   webhooks, stale-source states, and per-endpoint provenance.
7. **Social expansion:** retain the shipped invitation-only Apple/Android Friends
   experience, directional summary privacy, retry-safe enrollment, and deletion. Treat
   teams, challenges, rankings, moderation, abuse handling, and product-scale load as a
   separate program rather than weakening the private-circle trust boundary.

### Wellness-nudge delivery contract

- **Breathe:** manual paced breathing is available on phone, WHOOP strap, and the NOOP
  Apple Watch app. The pattern distinguishes inhale/exhale and stops haptics when the
  session ends. It is a relaxation aid, not respiratory treatment.
- **Stress check-in:** disabled by default. A fresh personal HRV dip may offer one
  dismissible breath session only after stillness/exercise, quiet-hour, replay, and
  rate-limit gates pass. It describes an autonomic pattern, never a diagnosis or cause.
- **Water:** disabled by default. Generic OS reminders use a chosen interval and active
  window and may mirror to Apple Watch according to system settings. An additional WHOOP
  buzz is separately opt-in, de-duplicated, and only attempted while NOOP has fresh live
  data over a bonded encrypted link; it is not a background-delivery promise.
- **Inactivity:** disabled by default and rate-limited. The UI must disclose when it is
  based on delayed offloaded motion instead of true live posture.
- Every nudge remains independently controllable, respects the master wrist-alert gate,
  contains no health value in notification text, and never escalates itself into an
  emergency or medical alert.

### P2 — research programs, not release promises

1. Fall-event data capture and detector validation.
2. MG ECG waveform validation; any clinical rhythm classification is a separate regulated
   project.
3. Cuffless BP research only under an approved reference-cuff protocol.
4. Sleep-breathing research with polysomnography/reference oximetry; no apnea diagnosis
   in the ordinary wellness app.
5. Direct RingConn/Hume lanes only with a vendor SDK/partnership or clean-room hardware
   program that records protocol provenance and survives firmware changes.

## Accuracy and release gates

### Distribution provenance

The checked dependency inventory passes, but the release distribution gate
intentionally fails closed: inherited WHOOP 4 protocol/store and collection
expression is attributed to `johnmiddleton12/my-whoop` / `wearable`, whose pinned
source has no explicit software license. Attribution is not redistribution
permission. External source or binary publication requires either an explicit
rights-holder license or an independently implemented replacement with a
reviewed clean-room provenance audit.

### Device/transport matrix

For every direct device/model/firmware/OS row, record:

- first pair and re-pair; official-app ownership conflicts; permission denial/revocation;
- foreground live HR/R-R and quality flags; disconnect/reconnect; app background,
  suspension, force-quit, phone reboot, and wearable reboot;
- 12-hour overnight wear and 24–72-hour backlog; oldest-first drain; duplicate and missing
  packets; clock drift, travel, DST, and midnight boundaries;
- worn/not-worn transitions, low battery, charging, firmware update, and storage horizon;
- battery impact for Live, overnight-only, and 24/7 modes;
- export/bridge deletion, correction, duplicate-source, and delayed-sync reconciliation.

An untested row stays experimental even when a related model passes.

### Algorithm validation

- Freeze the algorithm revision before evaluation.
- Split by participant and device, not random windows from the same person.
- Publish missing-data and exclusion rules before reading results.
- Report calibration, coverage, bias, MAE/RMSE and failure rates; for classification,
  report per-class precision/recall, confusion matrix, false prompts per day, and latency.
- Test skin tone, fit/contact, motion, age, sex, sleep regularity, fitness, medication and
  relevant comorbidity subgroups where the claim could be affected.
- Never optimize on the final chronological/person-held-out set.
- Revalidate after sensor, firmware, filtering, scoring, or threshold changes.

### Safety boundary

- SpO2 variation is not sleep-apnea diagnosis.
- Peripheral temperature deviation is not core temperature or pregnancy confirmation.
- PPG/R-R irregularity is not ECG or AFib diagnosis.
- A vascular/BP trend is not systolic/diastolic mmHg.
- Fitness, cardiovascular, wellness, or vendor "biological" age is an estimate, not a
  measure of whole-body aging or lifespan.
- A fall candidate without validated dispatch is not an emergency service.
- Pregnancy insights must never delay urgent care. Present warning symptoms and local
  emergency guidance without attempting to diagnose their cause.

## Sources

### WHOOP

- [How WHOOP works](https://www.whoop.com/us/en/how-it-works/)
- [Membership features and benefits](https://support.whoop.com/s/article/Membership-Features-Benefits?language=en_US)
- [WHOOP 5.0 capabilities](https://support.whoop.com/s/article/Unlock-New-with-WHOOP-5-0?language=en_US)
- [Recovery](https://support.whoop.com/s/article/WHOOP-Recovery)
- [Sleep](https://support.whoop.com/s/article/WHOOP-Sleep?language=en_US)
- [Automatic and manual activity detection](https://support.whoop.com/s/article/Automatic-and-Manual-Activity-Detection)
- [Healthspan / WHOOP Age](https://support.whoop.com/s/article/Healthspan-WHOOP-Age-Pace-of-Aging-Guide?language=en_US)
- [Menstrual Cycle Coaching](https://support.whoop.com/s/article/Menstrual-Cycle-Coaching)
- [WHOOP Life blood-pressure insights](https://support.whoop.com/s/article/WHOOP-Life-Blood-Pressure-Insights)
- [WHOOP data export](https://support.whoop.com/s/article/How-to-Export-Your-Data)
- [WHOOP developer API](https://developer.whoop.com/api/)
- [Independent measured WHOOP 5/MG board-prefix table](https://github.com/tanarchytan/whoop-rs/blob/main/crates/whoop-protocol/src/variant.rs)

### Oura

- [Oura Ring 4](https://ouraring.com/store/rings/oura-ring-4)
- [Oura Ring 4 specifications](https://support.ouraring.com/hc/en-us/articles/33045011508115-Oura-Ring-4)
- [Automatic Activity Detection](https://support.ouraring.com/hc/en-us/articles/360063022993-Automatic-Activity-Detection)
- [Cardiovascular Age](https://support.ouraring.com/hc/en-us/articles/28451491040019-Cardiovascular-Age)
- [Cycle Insights](https://support.ouraring.com/hc/en-us/articles/4410663885331-Cycle-Insights)
- [Pregnancy Insights](https://support.ouraring.com/hc/en-us/articles/25889225853587-Pregnancy-Insights)
- [Symptom Radar](https://support.ouraring.com/hc/en-us/articles/35593651188115-Symptom-Radar)
- [Product safety and offline memory](https://support.ouraring.com/hc/en-us/articles/43395388251283-Product-Safety-Use)
- [Oura API v2](https://cloud.ouraring.com/v2/docs)

### RingConn and Hume

- [RingConn Gen 3](https://ringconn.com/pages/ringconn-gen-3)
- [RingConn Gen 3 support](https://support.ringconn.com/product-support/gen3)
- [RingConn app features](https://ringconn.com/pages/app-features)
- [RingConn Gen 3 manual](https://cdn.shopify.com/s/files/1/0850/1769/0420/files/RingConn_Gen_3_Manual_Instruction_English.pdf?v=1779691635)
- [Hume Band 2.0](https://humehealth.com/pages/hume-bandv2)
- [Hume FAQ](https://humehealth.com/pages/faq)
- [Hume Band safety](https://humehealth.com/pages/humeband-quickstart)
- [Hume Band and Pod bundle boundary](https://humehealth.com/pages/hume-health-bundle)

### Regulatory, validation, and operating-system limits

- [Apple Health data access and export](https://support.apple.com/guide/iphone/share-health-and-fitness-data-iph5ede58c3d/ios)
- [Apple Watch health-data source management](https://support.apple.com/en-mide/108779)
- [Apple Watch cardio fitness / VO2 max](https://support.apple.com/en-us/108790)
- [Apple Watch wrist temperature](https://support.apple.com/en-ca/102674)
- [Apple Watch Blood Oxygen availability and limits](https://support.apple.com/en-mide/120358)
- [HealthKit observer and background delivery](https://developer.apple.com/documentation/healthkit/executing-observer-queries)
- [Configuring HealthKit access](https://developer.apple.com/documentation/Xcode/configuring-healthkit-access)

- [FDA WHOOP ECG clearance K243236](https://www.accessdata.fda.gov/scripts/cdrh/cfdocs/cfPMN/pmn.cfm?ID=K243236)
- [FDA 2025 WHOOP blood-pressure warning letter](https://www.fda.gov/inspections-compliance-enforcement-and-criminal-investigations/warning-letters/whoop-inc-709755-07142025)
- [FDA 2026 WHOOP warning-letter closeout](https://www.fda.gov/inspections-compliance-enforcement-and-criminal-investigations/warning-letters/whoop-inc-709755-06172026)
- [FDA cuffless blood-pressure device guidance](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/cuffless-non-invasive-blood-pressure-measuring-devices-clinical-performance-testing-and-evaluation)
- [FDA warning on unauthorized BP devices](https://www.fda.gov/medical-devices/safety-communications/do-not-use-unauthorized-devices-measuring-blood-pressure-fda-safety-communication)
- [Apple background-task strategy](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app)
- [Apple Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Android Health Connect synchronization](https://developer.android.com/health-and-fitness/health-connect/sync-data)
- [Oura Ring Gen 3 sleep staging versus polysomnography](https://pubmed.ncbi.nlm.nih.gov/38382312/)
- [Consumer wearable sleep-stage comparison](https://pubmed.ncbi.nlm.nih.gov/36016077/)
- [Nocturnal resting-HR/HRV wearable comparison](https://pubmed.ncbi.nlm.nih.gov/40834291/)
- [RingConn sleep/SpO2 study registry](https://clinicaltrials.gov/study/NCT05746338)

Related internal contracts: [WHOOP parity](FEATURE_PARITY.md), [device support](DEVICE_SUPPORT_ROADMAP.md),
[detection validation](DETECTION_VALIDATION_PLAN.md), [fitness age](FITNESS_AGE.md), and
[reference study](REFERENCE_STUDY.md).
