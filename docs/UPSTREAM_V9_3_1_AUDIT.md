# Upstream v9.3.1 integration and hardware validation

**Audit snapshot:** 2026-08-11
**Reference upstream:** [`ryanbr/noop` v9.3.1](https://github.com/ryanbr/noop/releases/tag/v9.3.1)

This is the release gate for the upstream fixes carried by this fork. A checked software row means the
code path has mirrored regression coverage and compiles in this repository. It does **not** substitute
for a real-phone/real-strap run where CoreBluetooth, Android GATT, locked-device storage, radio timing,
or firmware behavior is the thing under test.

As of this snapshot, every PR named below is merged upstream. “Hardware pending” refers to this fork's
physical-device release evidence, not to an open upstream pull request.

## Named upstream fixes

| Upstream | Local requirement | Software status | Hardware status |
|---|---|---:|---:|
| [#1066](https://github.com/ryanbr/noop/pull/1066) | Android MTU callback is telemetry-only; one generation/GATT-bound discovery follows the bounded settle interval | Implemented + sequencing tests | Upstream validated on WHOOP 5.0; repeat on this APK before release |
| [#1123](https://github.com/ryanbr/noop/pull/1123), [#1125](https://github.com/ryanbr/noop/pull/1125) | Empty completed **and stalled** offloads feed a dedicated backoff streak on Android and Apple | Implemented + policy/client tests | Re-capture battery/offload cadence on both phones |
| [#1145](https://github.com/ryanbr/noop/pull/1145) | An offload that persisted zero sensor rows never auto-continues, even across a reported frontier gap | Implemented + phantom-gap tests | Reproduce an empty-gap strap and confirm one attempt, not a 24-pass storm |
| [#1138](https://github.com/ryanbr/noop/pull/1138) | iOS raw-history archive directory/file use after-first-unlock protection, including after atomic rewrites | Implemented + attribute test where the OS exposes it | Validate a locked background offload on a physical iPhone |
| [#1107](https://github.com/ryanbr/noop/pull/1107) | Oura sample timestamps reject `> now + 300s`; existing future R-R rows are marked, retained, and excluded from scoring | Implemented on Swift + Android with additive migrations and tests | Drain a real ring and verify the unflagged future-row count remains zero |
| [#1108](https://github.com/ryanbr/noop/pull/1108) | SDNN is withheld when beat timestamps do not track the R-R values, even when aggregate coverage looks plausible | Implemented on Swift + Android with mirrored trust tests | Compare against a labeled live/banked Oura capture |
| [#1154](https://github.com/ryanbr/noop/pull/1154) | iOS 5/MG battery GATT reads are no more frequent than 60s; known-empty 5/MG history uses at least a 45-minute floor | Implemented + cross-platform throttle tests | **Pending a physical WHOOP 5/MG validation run** |

## Additional v9.3.1 parity gates completed in this fork

| Area | Local requirement | Verification |
|---|---|---|
| WHOOP 5/MG ECG research probe | CRC-valid Labrador packet decoding, bounded 30-second collection, positive MG identity gate, explicit opt-in/start, wrist selection, and best-effort stop | Swift protocol tests (59), Android decoder/probe/variant tests (66), iOS simulator + macOS compile; real MG validation remains mandatory |
| Custom AI gateway | Selectable `Authorization`/`x-api-key`, OpenAI and gateway catalog envelopes, and one bounded modern-parameter retry after HTTP 400 | Swift model-list tests (9) and Android catalog tests (2) pass |
| Respiratory evidence integrity | Five explicit evidence states keep measured-mid-band, unmeasured, irregular, and degenerate bars from collapsing into the same sleep-stage signal | Mirrored exhaustive Swift/Android tests pass |
| Health Connect energy | Source-aware active and total energy range scan, total-minus-basal fallback, and deterministic input ordering | Android kcal-index and active-kcal tests (12) pass |
| Import memory bounds | One shared stream cap is used by large activity, lab, lifting, nutrition, and wearable importers | Android cap/import tests pass |
| Encrypted preferences | Android encrypted preferences are created through one synchronized singleton instead of racing multiple instances | Android app compile and focused tests pass |
| Cross-platform schema oracle | Room and GRDB schemas are compared against one checked fixture, including the future-R-R quarantine and step-sync columns; GRDB-only partial indexes are recorded as intentional performance-only differences | Clean Android oracle and Swift oracle suites pass |

The software gate for this table is green on the 2026-08-11 audit: the full iOS simulator and macOS
applications build, the focused Android suite passes 93/93, and the focused Swift custom-provider suite
passes 9/9. These counts are evidence for this snapshot, not a replacement for the hardware checklist.

## Other material v9.3.1 behavior carried here

- Effective Effort chooses the freshest valid live/stored value instead of flashing a stale score.
- Nap asleep-minutes credit sleep debt without changing the main-night Rest/headline totals; stage-less
  naps add no guessed sleep.
- `wake` and `awake` are one canonical semantic stage across imports, efficiency, WASO, and timelines.
- Respiration/RSA windows crossing an R-R timestamp splice are rejected instead of producing a number.
- HealthKit writes newly scored data after offload and never opens a new permission sheet in background.
- Health Connect imports use each record's zone offset and merge manual-workout HR with canonical HR.
- Continuous overnight HRV defaults on for fresh installs and migrates legacy installs deliberately.
- Connected-with-no-data is a distinct state rather than being presented as an active stream.
- Large exports run off the UI thread and always release their busy state.
- Sideloaded iOS builds resolve the alternate app group and widgets show unavailable data honestly rather
  than demo values.

## Automatic activity detection contract

NOOP's detector is local, retrospective, and controlled by **Off / Ask**:

1. A candidate needs at least 10 minutes at `resting HR + 30 bpm`, enough real HR observations, a
   post-session quiet tail so an ongoing workout is never prompted, and no
   gap over 60 seconds. Fitness Age has its own separate four-of-seven RHR/activity coverage gates.
2. Brief HR dips (up to 90 seconds) are bridged; nearby qualifying windows merge.
3. Sufficiently covered motion may reject a still window. Sparse/missing motion never masquerades as
   evidence that the person was still.
4. Saved and dismissed spans are excluded/deduplicated; notification delivery is also token-deduplicated.
5. A completed backfill triggers the same scan in background. A local notification is posted only when
   notification access was already granted; detection never requests permission by itself.
6. **Ask** requires the user to tap Save or dismiss before any workout is written. **Off** performs no
   scan. Existing explicit Boolean choices migrate true → Ask and false → Off. A legacy Auto-save value
   also migrates to Ask: the detector currently produces only uncalibrated event confidence, so its
   unattended-save policy intentionally rejects every candidate. Auto-save must not return to the UI
   until participant/device-held-out validation demonstrates calibrated confidence and acceptable false
   starts per wear-hour.
7. The broad type hint (walk/run/strength/cycle/ski) is explicitly experimental. It is shown only when
   decoded activity-class ticks cover the detected window and the advisory classifier clears its score
   and confidence gates. Otherwise the label remains `Workout`. The saved label is always editable.

This intentionally differs from WHOOP's proprietary classifier: NOOP can match the useful capture and
review loop, but must not claim identical sport labels or scores without a labeled validation study.

## Physical WHOOP 5/MG release checklist

Run on both a physical iPhone and Android phone, with identifiers/personal values redacted from the report:

1. **Pair/reconnect:** clean install, fresh bond, cold restart, airplane-mode recovery, and reconnect after
   the official WHOOP app releases the one-app BLE connection.
2. **Live stream:** worn/off-wrist transitions, live HR, disconnect state, background/foreground changes,
   and no crash after repeated connect/disconnect cycles.
3. **MTU/services (Android):** exactly one service-discovery attempt for the current GATT generation,
   CLIENT_HELLO acknowledged, notifications subscribed.
4. **Battery polling:** first connection read arrives promptly; subsequent 5/MG reads are at least 60s
   apart; WHOOP 4's command-based battery path is unchanged.
5. **Empty history:** after the known-empty threshold, periodic history work respects the 45-minute floor;
   manual/foreground/reconnect sync still runs immediately.
6. **Deep backlog:** productive chunks continue while rows/frontier advance; a zero-row phantom gap stops
   after one pass; no loss after disconnect/reconnect.
7. **Locked iPhone:** lock after first unlock, allow background history delivery, verify archive write and
   trim acknowledgement complete, then inspect the file/directory protection class.
8. **Activity suggestion:** perform a 15–25 minute walk/run, then a non-workout elevated-HR control. Verify
   coverage gating, notification routing, Save/dismiss behavior, relabeling, and no duplicate suggestion.
9. **Side-by-side study:** export WHOOP and NOOP only by explicit user action, import both into the local
   Study Harness, and compare raw coverage/provenance before comparing derived daily values. Never tune
   against one person's score or call a correlation formula parity.

Record firmware, phone/OS, strap model, start/end timestamps, relevant redacted log lines, and pass/fail
for every step. Until this checklist is attached to a release report, #1154 remains hardware-pending.

## Deliberately unresolved, not hidden

- [#1146](https://github.com/ryanbr/noop/issues/1146) concerns bounded raw-row retention. This fork does
  **not** silently delete user-owned history merely to close an issue. Retention needs an explicit policy,
  an export/backup guarantee, a storage forecast, and a user-controlled setting before destructive pruning.
- WHOOP's proprietary Recovery/Strain/Sleep/Healthspan algorithms and sport classifier are not public.
  NOOP labels independent estimates and provenance; passing tests proves internal consistency, not formula
  identity with WHOOP.
- Simulator/emulator builds cannot validate CoreBluetooth/GATT timing or a strap's firmware behavior.
