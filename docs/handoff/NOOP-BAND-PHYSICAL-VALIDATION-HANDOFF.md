# NOOP Band physical validation handoff

**Updated:** 2026-09-23
**Purpose:** give the next hardware agent an executable, evidence-bounded plan
for closing only the supplier, firmware, signed-device, and physical-behavior
gates that source, unit, simulator, emulator, and synthetic cloud tests cannot
prove.

## 1. Current boundary

- Keep the existing WHOOP 4.0, 5.0, and MG transport available as a distinct
  comparison and regression adapter until the production NOOP Band path passes
  this matrix. Never relabel WHOOP rows as first-party-band data.
- The binary-free, NOOP-owned neutral contract remains in the separate public
  `Dhanunjay-Divi/NoopBandSDK` repository. The original supplier drop and every
  supplier binary remain outside this repository, as do firmware, credentials,
  signing material, private reference inputs, and user or health data.
- The current compatible-device path is local-authoritative. D-059 targets
  staged cloud authority for durable account history, canonical versioned
  metrics, recommendations, and cross-device state. The active phone still
  owns BLE receipt, an encrypted short-lived journal, a bounded offline working
  set, freshness, and immediate Safety initiation.
- First-party band activation requires a minimal ownership account and one
  network-backed atomic claim. Ownership, NOOP+ entitlement, and managed-health
  consent are separate. After activation, a cloud outage must not stop local
  collection, export, immediate Safety initiation, or supported band control.
- Managed Safety has deterministic synthetic routing evidence. That does not
  prove APNs/FCM receipt, background wake, sound, haptics, location delivery,
  Mac presentation, SMS/voice fallback, or carrier behavior.
- The supplier wrapper is not implemented or production-approved merely
  because the candidate SDK exposes an API or the app compiles.
- App PR `#17` consumes the supplier-neutral SDK at protected merge
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4` while retaining WHOOP as the
  default comparison transport and leaving the first-party source factory
  disabled. A device-connected agent must not expect a supplier band to pair
  until the quarantined exact-model adapter and approved supplier artifacts are
  integrated and enabled for that test build.

## 1.1 Immediate device-connected continuation

After app PR `#17` is merged and protected `main` is verified:

1. Create a new operations round from clean protected `main`; do not continue
   from a stale SDK or adapter worktree.
2. Build and install one exact signed candidate on a clean supported iPhone and
   Android phone. Complete first-run account and onboarding rather than
   injecting a preconfigured state.
3. Run the existing WHOOP transport first to establish a comparison baseline:
   discovery, connection, battery, live heart rate, available history,
   disconnect/reconnect, background recovery, and diagnostics export.
4. Integrate the approved Apple and Android supplier adapters only from the
   exact hardware/firmware intake. Keep the adapter default-off until its
   focused source, artifact, network, and signed-build gates pass.
5. Run the same scenarios against the supplier band, then execute
   `PHY-CON-007` to switch sources and prove isolation.
6. Record the exact generalized phone/OS/band/firmware classes, failures,
   blocked supplier inputs, diagnostics categories, and preserved data. Do not
   include serials, printed identifiers, addresses, credentials, or health
   values in Git.

## 2. Inputs required before testing

Do not begin a release-significant physical run until the test lead has:

1. Exact production model, project code, board revision, MCU, BLE controller,
   bootloader, firmware build, protocol revision, and supplier capability
   report.
2. Immutable hashes for the exact Apple and Android wrapper artifacts and every
   transitive binary. Do not commit those binaries here.
3. Written redistribution, update, support, vulnerability-response, and
   end-of-life authority for every supplied component.
4. At least three bands per hardware revision:
   - one ordinary-use unit;
   - one destructive OTA, reset, and recovery unit; and
   - one retained control unit that is not modified during destructive tests.
5. Two supported iPhones and at least three Android classes: Pixel, Samsung,
   and one OEM with aggressive background restrictions. Include the oldest and
   current supported OS releases.
6. Supplier procedures for pairing mode, identify vibration, confirmation,
   device-password recovery, hard reset, owner credential removal, RMA,
   firmware update, rollback, and rescue.
7. The printed-label format and an approved mapping to the provisioned opaque
   band identity. A Bluetooth address, advertised name, SDK `deviceNumber`, or
   four-digit password is not ownership proof.
8. A firmware-backed, challenge-bound possession protocol. The target flow
   requires at least three deliberate taps, firmware debounce, freshness,
   selected-band binding, replay rejection, and an opaque response.
9. Approved test accounts, fictional accepted Safety contacts, controlled
   phone numbers if carrier tests are in scope, and a non-production cloud
   environment that permits only synthetic data.
10. Pre-approved metric, step, battery, latency, thermal, and reliability
    budgets. A test cannot invent its pass threshold after seeing the result.

If any input is missing, record the scenario as `BLOCKED`, name the missing
owner or supplier artifact, and do not substitute a guess.

## 3. End-to-end activation and use flow

The physical agent must exercise this sequence without skipping directly to a
prepaired development state:

1. Install the exact signed release candidate on a clean phone.
2. Put one charged, worn band into a time-bounded pairing mode.
3. Enter or select only the minimum printed-label characters approved for
   discovery.
4. Scan eligible candidates, select one, and trigger identify vibration.
5. Confirm the worn band vibrated. This creates only a provisional session; it
   must not create ownership or start ordinary collection.
6. Fetch and verify the exact immutable remote Terms document. Show the
   one-account rule, recovery path, no general v1 transfer, and separate NOOP+
   consent. Record explicit versioned acceptance.
7. Create or sign in to the verified email/password ownership account.
   Optional phone verification remains optional and is not health-data consent.
8. Request a fresh server possession challenge. Send it through the wrapper,
   perform the required taps on the selected band, and receive only an opaque,
   expiring, challenge-bound proof.
9. Submit the proof to the atomic server claim. Exactly one account wins under
   concurrent claims; losing accounts receive the same privacy-preserving
   rejection and learn no owner identity.
10. Only after claim commit, provision owner-scoped credentials. If supported,
    rotate the vendor default password to an app-generated random value as
    defense in depth. The password is not the ownership authority.
11. Negotiate and persist the exact hardware, firmware, protocol, wrapper, and
    capability report. Unsupported or unknown required revisions fail closed.
12. Establish the clock anchor, read battery/wear/history bounds, start only
    supported live streams, and resume history from the last durable cursor.
    Publish `ready` only after required state is committed.
13. Keep the app interactive while catch-up continues. Progress is based on
    durable commits, not callback count or animation time.
14. If the user chooses NOOP without managed health sync, local activated use
    continues. If the user separately consents to managed sync, upload only
    normalized committed rows through the managed outbox.
15. A signed-in Mac, Watch, or second phone is a viewer or companion. It must
    not open a competing supplier BLE session.
16. Replacement-phone recovery requires the same owner account plus fresh
    physical possession. A different account cannot claim or discover the
    owner.
17. Return, RMA, verified dispute, deletion, and eligible future upgrade use an
    operator-controlled revoke, wipe, verify, unlink, and quarantine path.
    Local disconnect or app deletion must not silently release ownership.

## 4. Responsibility split

| Layer | Must own | Must not be used as proof for |
|---|---|---|
| Band firmware/bootloader | unique identity and key, challenge response, tap debounce, wear state, autonomous sampling, off-wrist power mode, flash retention, monotonic time, command acknowledgements, signed OTA, rollback/rescue | account authorization, cloud consent, metric accuracy without validation |
| Supplier SDK | reviewed BLE transport/parser surface for the exact project | product architecture, storage, diagnostics policy, medical claims, ownership authority |
| NOOP wrapper | one serialized session, generation-bound callbacks, fixed errors, capability negotiation, normalized units/provenance, durable-before-ack handoff | UI policy, account decisions, direct cloud upload, formula authority |
| NOOP phone app | permissions, one active collector, ownership UX, local durability, freshness, safe offline state, diagnostics, managed outbox | firmware retention, force-quit execution, sensor accuracy |
| Ownership/cloud services | atomic single-owner claim, installation authorization, optional managed history, canonical formula publication after D-059 gates, viewer state | repairing a dropped BLE link, making stale data fresh, possession without band proof |
| Operator/supplier | artifact rights, provisioning, manufacturing records, RMA/wipe, firmware signing, support, security response | silent waivers or undocumented production exceptions |

## 5. Test topology and execution rules

- Execute each applicable row on Apple and Android unless the row is explicitly
  platform-specific.
- Run each accepted hardware/firmware pair, not just one representative name.
- Use both dominant and non-dominant wrist where motion or wear can affect the
  result.
- Use a synchronized UTC clock for phone, camera, power monitor, and test log.
- Reset only the state named by the scenario. Record whether the app, account,
  platform bond, band, firmware, cloud state, or all of them were reset.
- Run destructive scenarios only on the destructive unit.
- A retry does not erase the first failure. Link the defect and retest evidence.
- Never use a simulator result to close a `PHY-*` row.

Result values are `PASS`, `FAIL`, `BLOCKED`, or `NOT_APPLICABLE`. `PASS` needs
the named evidence and the exact pass condition. `NOT_APPLICABLE` needs a
reviewed capability or platform reason.

## 6. Exact physical validation matrix

### 6.1 Supplier and artifact intake

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-SUP-001 | Match model, board, bootloader, firmware, protocol, function report, wrapper, and binary hashes to the test unit. | Every identifier maps to one approved compatibility row; no wildcard or guessed revision. |
| PHY-SUP-002 | Build signed Apple and Android apps from the pinned wrapper artifacts. | Release artifact manifest contains exact digests; supplier binaries are absent from this Git repository. |
| PHY-SUP-003 | Produce dependency inventory, notices, SBOM, vulnerability report, privacy declarations, and support contacts. | Every shipped binary and native library has an owner, license disposition, and response path. |
| PHY-SUP-004 | Capture signed-app network egress during setup, idle, live, history, weather, haptic, and OTA paths. | Only reviewed destinations and purposes occur; unexpected supplier egress is denied or the test fails. |

### 6.2 Discovery, pairing, account, and ownership

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-ID-001 | Clean install with Bluetooth denied, then grant later and retry. | No false connected state; setup resumes without reinstall or leaked provisional claim. |
| PHY-ID-002 | Scan with no band, one band, several nearby bands, and a wrong printed number. | Only eligible pairing-mode candidates are considered; no owner or full identifier is disclosed. |
| PHY-ID-003 | Select one of several candidates and request identify vibration. | Only the selected worn band vibrates; timeout/cancel leaves no ownership. |
| PHY-ID-004 | Let pairing mode and provisional confirmation expire, then retry. | Old callbacks and proof are rejected; a new session generation succeeds. |
| PHY-ID-005 | Attempt claim with one tap, taps outside the window, phone motion, and replayed proof. | Every invalid attempt is rejected without creating an owner. |
| PHY-ID-006 | Complete the approved three-or-more-tap challenge on the selected band. | Proof is fresh, challenge-bound, band-bound, opaque, single-use, and accepted exactly once. |
| PHY-ID-007 | Submit simultaneous claims from two phones and two accounts. | One atomic owner is recorded; all losers receive privacy-preserving rejection. |
| PHY-ID-008 | Interrupt after account creation, Terms acceptance, proof, claim commit, and credential provisioning in separate runs. | Resume is idempotent; no dual owner, orphan claim, or unusable claimed band results. |
| PHY-ID-009 | Verify default-password rotation, app reinstall, lost phone, revoked installation, and approved recovery. | Credentials are protected and recoverable only through the approved owner path; ownership remains server-authoritative. |
| PHY-ID-010 | Sign in on a replacement phone and prove possession; repeat with a different account. | Same owner is authorized and old installation policy applies; different account learns no owner identity and cannot claim. |
| PHY-ID-011 | Exercise approved return/RMA wipe and quarantine on the destructive unit. | Owner credentials and personal band state are removed and verified before unlink; hardware is quarantined until approved reprovisioning. |

### 6.3 Connection, background, and source isolation

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-CON-001 | First connect, ordinary reconnect, remembered direct reconnect, and scan fallback. | One session reaches ready with bounded retries and no unbounded scan. |
| PHY-CON-002 | Reject and time out device confirmation, then accept on retry. | Each outcome is explicit; stale callbacks cannot complete the later session. |
| PHY-CON-003 | Toggle Bluetooth and airplane mode; revoke/restore permission; reset the radio. | Local data remains durable and reconnect resumes without duplicate collector or ownership change. |
| PHY-CON-004 | Compete with another phone or app for the peripheral. | NOOP reports a bounded unavailable/recovery state and never claims simultaneous collection. |
| PHY-CON-005 | Test foreground, locked screen, background, OS process death, user force-quit/force-stop, reboot, low-power mode, and battery saver. | Observed behavior matches platform truth; no promise of collection while the OS forbids execution. Recovery uses retained band history where supported. |
| PHY-CON-006 | Test iOS restoration and Android foreground-service/Doze/OEM task-kill paths. | No reconnect storm, hidden permanent service, or false freshness; deferral and recovery are diagnosable. |
| PHY-CON-007 | Switch WHOOP -> supplier band -> WHOOP using test accounts/data. | Only one source is active; rows retain correct source provenance; no samples or cursors cross adapters. |
| PHY-CON-008 | Keep Mac, Watch, and a second signed-in phone open during collection. | They display authorized state without opening a supplier BLE session or disrupting the collector. |

### 6.4 Live data, history, and storage

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-DAT-001 | Exercise every claimed live stream and history category. | Unit, cadence, quality, calibration, timestamp, source, and missing-state contracts match the approved capability row. |
| PHY-DAT-002 | Inject or induce duplicate, out-of-order, truncated, corrupt, stale, and unsupported records. | Invalid data is rejected/quarantined; accepted data is idempotent; no cursor advances on rejection. |
| PHY-DAT-003 | Collect live data while draining history. | One serialized command policy holds; live and history retain distinct lanes and converge without duplicate rows. |
| PHY-DAT-004 | Kill the app before local commit, after commit, before band acknowledgement, and after acknowledgement. | Resume starts at the last durable point; no acknowledged-but-missing range occurs. |
| PHY-DAT-005 | Read empty, partial, near-full, full, and overflowed flash after increasing phone absence. | Exact retention and overflow behavior are measured; complete-empty is distinct from timeout or failure. |
| PHY-DAT-006 | Change timezone, cross DST, change phone time, reset band time, and measure clock drift. | Event time remains explainable and monotonic rules hold; ambiguous windows are withheld rather than silently rebucketed. |
| PHY-DAT-007 | Run catch-up under low storage, full disk, memory pressure, thermal pressure, and slow database conditions. | App remains interactive, no fake completion appears, and uncommitted history is not acknowledged or pruned. |
| PHY-DAT-008 | Leave the phone away for the maximum supported absence and reconnect. | Available history backfills within the approved budget; any irrecoverable gap is explicit and matches measured flash limits. |
| PHY-DAT-009 | Export and restore the collected test window on both platforms. | Source provenance, gaps, quality, and durable cursors remain consistent; no supplier object or identifier enters export. |

### 6.5 Steps, sensors, and derived metrics

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-MET-001 | Compare firmware step totals with synchronized video/manual counts for slow, normal, and fast walking, stairs, treadmill, carrying an object, short/long sessions, both wrists, and dominant/non-dominant wear. | Every cohort and scenario meets the pre-approved error budget. |
| PHY-MET-002 | Measure false steps during seated/bed wrist motion, typing, dishes, brushing teeth, driving, cycling, and ordinary gestures. | False-positive budget passes. If aggregate firmware totals fail, block release pending firmware tuning or a separately validated raw-IMU classifier. |
| PHY-MET-003 | Verify each enabled sensor on-wrist, loose, off-wrist, charging, low battery, sweat, temperature variation, rest, sleep, and exercise. | Quality/wear/missing states prevent unsupported values from entering metrics. |
| PHY-MET-004 | Compare enabled raw and normalized signals with approved reference instruments and held-out participants. | Each signal meets its pre-registered method, error, subgroup, and missing-data criteria. |
| PHY-MET-005 | Run client/server formula parity with the same accepted physical source window. | Formula revision, inputs, missingness, provenance, and output match the approved tolerance before any D-059 authority change. |
| PHY-MET-006 | Inspect all vendor-labelled apnea, blood pressure, disease risk, body composition, fall, and emergency outputs. | None is exposed or used unless a separate intended-use, regulatory, clinical, and product validation record approves it. |

### 6.6 Battery, haptics, workouts, and Safety

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-PWR-001 | Measure band and phone drain during idle worn, off-wrist, disconnected retry, live, catch-up, workout, haptic, and cloud upload states. | Every state meets the approved budget and reports the exact app/firmware/phone conditions. |
| PHY-PWR-002 | Leave the band off-wrist with the phone absent, then wear it again. | Firmware reduces power and restores sampling autonomously; the app does not need to stay alive. |
| PHY-HAP-001 | Send each supported haptic/alarm pattern, cancel it, disconnect mid-command, and repeat duplicate commands. | Physical behavior and acknowledgment match; unknown outcome is never displayed as delivered. |
| PHY-HAP-002 | Run workout guidance under high HR, signal loss, pause, stop, low battery, and user override. | Guidance is cancellable, bounded, non-emergency, and cannot hide the source signal's uncertainty. |
| PHY-SOS-001 | Test the approved physical SOS gesture, debounce, warning/cancel window, offline state, reconnect, duplicate suppression, and hard negative motions. | Only the approved deliberate gesture creates one pending Safety action; automatic medical/fall inference remains disabled. |
| PHY-SOS-002 | With fictional accepted contacts, test owner page, two contact pages, latest-only location, acknowledge, expiry, cancel, and resolve. | Pager stops on terminal state; location is consented, bounded, and deleted according to policy. |
| PHY-SOS-003 | Test foreground/background APNs and FCM, sound settings, notification tap, Mac viewer where supported, worn-band haptic, and failed delivery. | Actual platform presentation is recorded; the app never claims Amber Alert behavior, emergency dispatch, or mute/DND bypass without approved entitlement. |

### 6.7 Firmware update and recovery

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-OTA-001 | Evaluate good, bad-signature, wrong-hardware, downgrade, expired, and revoked manifests. | Only the exact approved image becomes eligible; all others fail before transfer. |
| PHY-OTA-002 | Interrupt transfer with disconnect, app death, phone reboot, low battery, thermal limit, and band power loss. | Band returns to a known running, resumable, fallback, rescue, or quarantined state without silent success. |
| PHY-OTA-003 | Complete update, activation, reconnect, capability renegotiation, and history continuation. | Running revision is verified and no committed history or ownership is lost. |
| PHY-OTA-004 | Exercise rollback/rescue and signing-key compromise procedures. | Recovery works on the destructive unit, rollout can halt, and revoked artifacts cannot activate. |

### 6.8 Managed cloud, viewers, accessibility, and support

| ID | Procedure | Pass condition |
|---|---|---|
| PHY-CLD-001 | Activate NOOP without managed health consent and operate through a network outage. | No health upload occurs; local collection, current safe state, export, Safety initiation, and supported control continue. |
| PHY-CLD-002 | Separately consent to managed sync, interrupt upload, revoke access, restore on another signed device, and erase the test account. | Upload is resumable/idempotent; tenancy, provenance, restore, revocation, and documented deletion behavior pass. |
| PHY-CLD-003 | Test cloud outage while live collection and catch-up run. | BLE and local commits continue; cloud status cannot mark stale local data fresh. |
| PHY-ACC-001 | Complete setup, errors, recovery, device controls, Safety, and firmware UI with physical VoiceOver and TalkBack. | All controls, progress, errors, and confirmation states are operable and understandable without sight. |
| PHY-ACC-002 | Test large text, reduced motion, contrast, switch/keyboard access where applicable, and haptic alternatives. | No clipped critical text, inaccessible action, motion-only meaning, or haptic-only safety state remains. |
| PHY-SUP-005 | Generate a report during discovery timeout, reconnect loop, live stall, history stall, storage failure, and failed OTA. | Report creation stays responsive and contains only fixed categories, bounded counts/durations, and approved version buckets. |
| PHY-SUP-006 | Inspect each report and backend operational event. | No name, address, RSSI, printed number, SDK number, serial, account/contact/installation identity, token, URL, raw error, frame, timestamp, health value, location, or user text is present. |

### 6.9 Release-checklist traceability

| Physical family | Primary checklist families |
|---|---|
| `PHY-SUP-*` | hardware intake, SDK artifact, security/privacy, signed RC, and launch evidence |
| `PHY-ID-*` | band claim, account, Terms, possession, installation, return/RMA, and deletion |
| `PHY-CON-*` | device transport, platform background lifecycle, one collector, and signed RC |
| `PHY-DAT-*` | flash history, durable acknowledgement, storage, restore, portability, and performance |
| `PHY-MET-*` | sensor provenance, calibration, steps, metric validation, formula parity, and claims |
| `PHY-PWR-*` | firmware power modes, phone/band battery, thermal, and soak budgets |
| `PHY-HAP-*` | haptic/alarm capability, workout interaction, acknowledgement, and accessibility |
| `PHY-SOS-*` | explicit Safety gesture, accepted-contact paging, location lifecycle, delivery, and operations |
| `PHY-OTA-*` | secure boot, signing, compatibility, update interruption, rollback, rescue, and revocation |
| `PHY-CLD-*` | consent, managed upload/restore/erasure, outage behavior, tenancy, and viewers |
| `PHY-ACC-*` | physical VoiceOver/TalkBack, large text, reduced motion, contrast, and alternate cues |

The release checklist remains the authority for ownership and status. This
table tells the physical agent where to attach evidence; it does not mark any
checklist item complete.

## 7. Soak and release runs

After all focused rows pass:

1. Run at least one uninterrupted 24-hour collection on each platform.
2. Run a multi-day phone-absence and full catch-up test.
3. Run the approved 30-day storage, battery, reconnect, history, and cloud-sync
   soak on representative phones and bands.
4. Repeat affected rows after every firmware, supplier SDK, wrapper, BLE,
   storage, ownership, or formula revision.
5. Freeze one exact app, wrapper, firmware, protocol, schema, and formula set
   for the signed release candidate.

## 8. Evidence package

Create one record per scenario with:

```text
scenario_id:
result: PASS | FAIL | BLOCKED | NOT_APPLICABLE
app_commit:
signed_build:
wrapper_version_and_digest:
phone_class_and_os:
band_model_hardware_firmware:
capability_profile_revision:
preconditions_and_reset_scope:
start_utc:
end_utc:
expected_result:
observed_result:
bounded_diagnostic_report_reference:
sanitized_media_reference:
durability_or_export_check:
battery_timing_resource_summary:
defect_and_retest_reference:
reviewer:
```

Use generalized unit labels inside the shared package, such as `band-A-normal`
or `android-aggressive-oem`. Keep the private serial-to-label mapping in the
approved restricted hardware inventory.

Never include real health data, phone numbers, names, email addresses, precise
locations, credentials, tokens, Bluetooth addresses, printed numbers, serials,
raw frames, vendor endpoints, arbitrary exception text, or supplier secrets in
the shared evidence package.

## 9. What source and simulators cannot prove

The following remain unproven until the applicable physical row passes:

- exact model and firmware capability truth;
- printed-label to provisioned identity mapping;
- authenticated tap possession and atomic two-phone behavior;
- on-band retention, overflow, acknowledgments, wear, charging, and power;
- sensor, step, sleep, HR/HRV, SpO2, temperature, motion, and metric accuracy;
- iOS/Android background execution, reconnect, process-death recovery, sound,
  haptics, Watch/Mac delivery, and physical accessibility;
- firmware update, rollback, rescue, and signing operations;
- signed-app egress, mobile/BLE/firmware security, distribution rights,
  certification, legal, store, carrier, manufacturing, support, and production
  operations approval.

## 10. Exit condition

Physical validation is complete only when:

- every applicable `PHY-*` row has named evidence and no unresolved
  release-severity defect;
- the matching `HW-*`, `FW-*`, `SDK-*`, `ACC-*`, `DAT-*`, `CLD-*`, `SEC-*`,
  `RC-*`, and `LCH-*` release-checklist gates are closed or have an approved,
  documented `NOT_APPLICABLE` rationale;
- the exact signed release candidate, wrapper, firmware, and backend revisions
  are pinned;
- independent mobile, BLE, firmware, cloud, privacy, legal, and accessibility
  reviews are complete; and
- no simulator, mock, synthetic cloud result, API surface, or connected-looking
  UI state is used as a substitute for physical evidence.
