# NOOP Band supplier SDK assessment

**Reviewed:** 2026-09-12; read-only inventory revalidated 2026-09-19
**Input:** owner-supplied HBand/Veepoo Android and iOS SDK package
**Status:** usable as a candidate phone transport, not approved for production
distribution or treated as proof of any hardware capability

## Executive conclusion

The package is sufficient to start a quarantined native integration after the
exact band model and firmware project are identified. It provides documented
scan, connect, reconnect, device confirmation, four-digit device-password,
capability, live-data, historical-data, battery, haptic, weather, and OTA
interfaces on Android and iPhone.

It does **not** close the NOOP Band launch gates:

- the package does not identify which optional/custom capability set the
  production NOOP band uses;
- it does not prove that the printed band number maps to the SDK's
  `deviceNumber`;
- it does not provide NOOP's intended at-least-three-tap, challenge-bound
  possession proof;
- a four-digit device password is not a cryptographic ownership identity;
- the supplied iOS binary is iPhone device-only and cannot power the Mac app or
  iOS Simulator;
- redistribution, transitive notices, update support, privacy-manifest, runtime
  network, security, and physical-device evidence remain open.

The product topology therefore remains:

```text
NOOP Band <-> one active phone collector <-> local durable store
                                             |
                                      optional NOOP+ sync
                                             |
                                Mac and other signed-in viewers
```

The Mac app is useful as a large-screen viewer, planner, journal, export, and
analysis surface. It must not compete with the phone for the BLE link. A later
collector-handoff feature may explicitly flush, disconnect, lease, and resume
collection on another supported phone, but concurrent collectors are not
allowed.

The concrete app-integration contract is
[`handoff/NOOP-SDK-WRAPPER-INTEGRATION.md`](handoff/NOOP-SDK-WRAPPER-INTEGRATION.md).
The executable signed-device and hardware matrix is
[`handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`](handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md).

## Repository boundary

The NOOP-owned SDK contract targets the separate public
`Dhanunjay-Divi/NoopBandSDK` repository. Its initial `main` commit is
`ee82cc0`, and protected contract remediation is merged through
`9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`. The latest remediation retains
exact connection, live-operation, and opaque one-use reconnect authority;
preserves Swift actor authority across diagnostic suspension; invalidates
reconnect authority when recovery restarts; rejects every public Kotlin
session entry during caller-owned collection traversal; and completes the
reviewed lifecycle chronology, bounded diagnostics, JVM compatibility,
capability-report equivalence, exact UTF-8 byte-semantics contracts,
privacy-safe model rendering, and exact-generation history-acknowledgement
authority across suspension.
The repository
contains only
English NOOP-owned architecture, capability schema, conformance scenarios,
supplier-intake records, platform adapter requirements, and local validation.
It contains no vendor binary and no hosted GitHub Actions workflow. The
repository was verified public on 2026-09-23 by owner decision. D-056 requires
the public tree to remain binary-free and free of firmware, credentials,
signing material, private inputs, and personal or health data.

The 2026-09-23 local supplier-drop audit found Android Veepoo protocol and
Bluetooth AARs plus an arm64 iPhoneOS-only `VeepooBleSDK.framework`. Those
artifacts expose scan, connect, password confirmation, capability, battery,
live-heart-rate, history-reader, raw-sensor, and vendor-specific OTA entry
points, but they remain outside Git and are not production inputs. The drop
does not provide an approved exact-SKU capability contract, per-device
authentication lifecycle, device-origin timestamp/cursor semantics,
redistribution authorization and complete SBOM, iOS simulator/XCFramework
support and privacy manifest, firmware payload/signature compatibility data,
or physical reconnect/background/history/haptic/accuracy/recovery evidence.
It can support a separately gated experimental device bridge; it cannot yet
close the production supplier-adapter or flashing gates.

The original supplier package is not rewritten to remove Chinese comments or
documentation. It remains immutable and outside Git so its provenance and
hashes stay auditable. Customer-facing API names, wrapper source, samples,
errors, and SDK documentation are English-only, enforced by the separate
repository's local language gate. NOOP app localizations remain unaffected.

## Reviewed artifacts

The private 297 MB input remains outside Git. No vendor binary, demo
application, credential, device identifier, or private capture was copied into
the repository.

| Artifact | Reviewed identity |
|---|---|
| Android protocol AAR | `vpprotocol-2.3.81.15.aar`, SHA-256 `756514429b1b68328f2152d85126d1dccc9ae5f0ea2d398429bba01d53588c27` |
| Android transport AAR | `vpbluetooth-1.20.aar`, SHA-256 `26d7037238d18a28ac373a511b7a2abdfac2a405e01564f90a89c926b5b48bd8` |
| iOS framework | `VeepooBleSDK.framework` under `2.2.XX.15`, SHA-256 `22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35` |
| iOS binary form | static archive, `arm64`, iPhoneOS only; no simulator, Catalyst, or macOS slice |
| Owner-supplied Android ZIP snapshot | SHA-256 `e72615e48f7339b96dca26a10acc303b19be26a0bbf073a27c9eec7e7e9ed091` |
| Owner-supplied iOS ZIP snapshot | SHA-256 `44be9299f8ec075091c84c3a843184128448438ea69bb694a30eb16405b665f5` |
| Top-level license files | Apache License 2.0 text is present for Android and iOS |

The 2026-09-19 read-only revalidation found 2,708 files, 20 Android AARs
across required and optional chipset/DFU lanes, multiple iOS framework
variants, JNI libraries, demos, generated API documentation, and zero
`PrivacyInfo.xcprivacy` files. This is an inventory observation, not a complete
SBOM or a statement that every component is required for the production band.
The extracted directories contained no usable Git commit metadata, so the
hashes above, the supplier contract, and a future restricted artifact manifest
must identify the reviewed input.

The Android README also says the SDK is available only to cooperative
customers. The Apache files alone therefore do not establish that NOOP may
redistribute every compiled binary and transitive component. Written supplier
authority, a complete dependency/SBOM inventory, notices, and update/support
terms are required before import.

## Confirmed SDK surface

### Connection and confirmation

- Both platforms expose scan, connect, disconnect, connection-state, and
  automatic-reconnect APIs.
- Device-side connection confirmation is supported on some devices. The first
  connection can require a user tap; reconnect can suppress the prompt.
- Both platforms expose four-digit password verification and password change.
  Documentation identifies `0000` as the default.
- Password verification returns a device number, firmware versions, history
  depth, and model-specific capability flags.

NOOP may rotate the default device password to an app-generated random value
after an atomic ownership claim and store it only in protected local/account
recovery state. This is defense in depth, not the ownership authority. The
server-side single-owner claim and firmware-backed possession proof remain
authoritative.

### Serialized operations

The Android documentation explicitly warns that the device does not support
concurrent time-consuming operations and that overlapping operations can
produce anomalous data. Both native integrations must therefore use one
serialized command queue per active band. History categories, capability
reads, clock, settings, live mode, and OTA cannot independently issue commands
against the device.

### History and gap recovery

- Android reports model-specific `watchday` and `sportmodelday` capacities.
- iOS reports model-specific `saveDays`.
- Both platforms can request historical days and resume from a record
  position. The general daily data path can expose up to 288 five-minute rows
  per day.
- The available categories include steps/activity, sleep, heart rate, HRV/R-R,
  SpO2, respiration, temperature, stress, sport history, battery, and other
  model-gated values.

This gives NOOP a plausible foreground catch-up path after suspension or
disconnect. It does not establish the retention depth, overflow policy,
acknowledgement semantics, clock integrity, or off-phone collection behavior of
the production band. Those must be measured on the exact model and firmware.

The required production behavior is a bounded circular flash history: the band
continues autonomous sampling while disconnected, retains as much recent data
as its measured capacity permits, and overwrites only the oldest retained
records after that capacity is full. The firmware or accepted SDK contract must
expose oldest/newest retained bounds and a cursor generation, overflow marker,
or equivalent signal. Without that signal NOOP cannot distinguish a complete
catch-up from history that was overwritten while the phone was absent, so the
model is not launch-eligible.

### Optional and custom capabilities

The headers/docs contain project-specific raw PPG, accelerometer/IMU, GPS,
packet-loss retransmission, and custom vibration APIs, including JH58 and QX17
families. These are not general SDK guarantees. NOOP must build its capability
matrix from the connected band's returned function report and supplier
contract, then fail closed when a capability is absent.

The SDK also exposes vendor-named apnea, blood-pressure, disease-risk, body
composition, and similar outputs. NOOP must not present those as sleep-apnea
detection, diagnosis, validated body composition, or another medical result
without an independently reviewed intended use and clinical evidence.
Vendor naming is not validation.

## Capability disposition

| Surface seen in the package | Current disposition |
|---|---|
| Scan, connect, reconnect, confirmation, and four-digit password | Candidate transport input; physical behavior and recovery remain unproven |
| Device number and printed-label discovery | Mapping is unknown; neither value is ownership proof |
| Live and historical health/activity data | Candidate parser input; exact model support, units, quality, retention, and accuracy remain unproven |
| Battery, charging, wear, haptic, alarm, weather, and settings | Capability-gated only; unsupported actions must fail closed |
| Raw PPG, acceleration/IMU, GPS, and retransmission families | Project-specific; unavailable unless the exact production function report and supplier contract approve them |
| Device confirmation and password | Defense in depth only; not the required challenge-bound possession proof |
| OTA/DFU libraries and APIs | Disabled until image signing, board matching, anti-rollback, interruption, fallback, rescue, and artifact rights pass |
| Vendor medical labels or analyses | Not exposed to product code or users without separate intended-use and validation approval |
| Vendor database, weather, dial, and network helpers | Not adopted; NOOP owns persistence, policy, weather source, artifact delivery, and egress controls |

## Firmware, wrapper, app, and cloud boundary

- Firmware must own unique identity/key material, authenticated tap proof,
  wear/autonomous sampling, off-wrist power behavior, flash history, device
  time, command acknowledgement, secure boot, signed update, and recovery.
- The supplier SDK may transport and parse only the exact accepted model
  surface.
- The NOOP wrapper serializes operations, rejects stale callbacks, negotiates
  capabilities, normalizes units/provenance, and hands data to NOOP storage.
- The phone app owns permissions, one active collector, activation UX,
  freshness, durable receipt, bounded diagnostics, and the managed outbox.
- The ownership service owns the atomic account claim. The managed service may
  own durable account history and versioned canonical formulas only after each
  D-059 gate passes.
- No app or cloud workaround can prove or replace missing firmware retention,
  possession, sensor, battery, or OTA behavior.

## Runtime and security findings

The demos are references only and must not be copied into production:

- the Android demo enables cleartext traffic, broad/background permissions,
  foreground services, a hard-coded map key, low-latency scans, and logging
  that includes device names, addresses, and RSSI;
- the iOS demo enables arbitrary network loads and Bluetooth central/peripheral
  background modes;
- the iOS static library contains hard-coded HTTP/HTTPS service endpoints;
- no current iOS privacy manifest was found;
- no explicit CoreBluetooth state-restoration identifier or
  `willRestoreState` implementation was found in the demo;
- the iOS documentation warns that multiple apps connected to the same
  peripheral can enter repeated data reads and fail.

The production integration must deny or detect unexpected vendor egress, use
NOOP-owned weather and OTA policy, request only justified permissions, and
route all persistence through NOOP's provenance-aware store. The vendor SDK is
an untrusted transport/parser dependency, not an application architecture.

## Required integration boundary

1. Add an Apple and Android `SupplierBandTransport` behind the existing neutral
   single-active-source/session boundary.
2. Keep all vendor types, callbacks, database behavior, and errors inside that
   adapter. Screens, analytics, storage, and cloud code receive only neutral
   NOOP models.
3. Serialize every device operation and give each operation a timeout,
   cancellation, stale-callback guard, and fixed failure category.
4. Read and persist the exact capability report before enabling a sensor,
   history category, haptic, alarm, or OTA action.
5. Normalize units, quality, device time, source provenance, and stable
   deduplication identity before durable storage.
6. Commit data before advancing NOOP's resume position. Treat live and
   historical delivery as two paths into the same idempotent store.
7. Keep ordinary app use interactive while catch-up continues in an
   OS-permitted background lane. Never show fake progress or promise execution
   after force-quit.
8. Rotate the default device password only after claim commit, with tested
   recovery for a replacement phone and operator-only return/RMA release.
9. Block vendor network access by default and prove the signed app's actual
   egress before enabling the adapter.
10. Do not add the binaries to Git until distribution authority, notices, SBOM,
    security review, privacy disclosures, exact versions, and update ownership
    are approved.
11. Publish the neutral SDK from the separate public, source-only repository as
    pinned Apple and Android artifacts. The NOOP app repository consumes an
    exact version and digest; neither public repository hosts supplier source,
    binaries, firmware, credentials, signing material, or private inputs.
12. Keep the existing WHOOP adapter selectable for controlled regression and
    comparison until every applicable `PHY-*` supplier row passes. WHOOP and
    supplier rows, cursors, diagnostics, and provenance must never be merged.
13. Keep supplier binaries out of simulator, macOS, Watch, widget, pure Swift
    package, Android Demo, and JVM-test targets. Those targets use a virtual
    neutral transport.

## Bounded observability

Diagnostics may record only fixed categories and bounded counts/durations:

- discovery started/completed/timed out;
- confirmation required/accepted/rejected/timed out;
- password verify/rotate outcome;
- capability report accepted/rejected and supported-capability count;
- command queued/started/completed/timed out/cancelled by command class;
- live progress, disconnect class, reconnect outcome;
- history requested, records accepted, durable commits, empty completion,
  interruption, retry, and no-durable-progress stall;
- background deferral/resume and storage-pressure bucket.

Never record the band name, address, printed number, SDK device number,
password, firmware payload, raw error text, raw frame, sensor timestamp/value,
health row, account identity, or callback URL.

## Physical and supplier acceptance matrix

Production work remains blocked until all applicable rows pass on the exact
hardware and firmware:

- supplier project/model code and complete function-support report;
- written binary/dependency redistribution and support authority;
- printed label to SDK/provisioned identity mapping;
- first-connect confirmation, reconnect, timeout, cancel, and competing-phone
  behavior;
- default-password rotation, replacement-phone recovery, return/RMA wipe, and
  wrong-account rejection;
- actual history days, full-flash circular overwrite of oldest-only data,
  retained oldest/newest bounds, explicit overflow/gap signaling, partial
  resume, duplicate delivery, clock reset, timezone/DST, and multi-day phone
  absence;
- foreground, screen-off, background, process death, force-quit, reboot, low
  storage, Android OEM restriction, and iOS restoration behavior;
- live plus catch-up sequencing under the one-command queue;
- step-count ground truth on the exact firmware, including false-positive
  stationary wrist-motion scenarios (bed/seated arm movement, typing, washing
  dishes, brushing teeth, driving, and cycling) and true-positive walking
  scenarios (slow/normal/fast pace, stairs, treadmill, carrying an object, both
  wrists, and dominant/non-dominant wear). Compare firmware totals with
  synchronized video/manual counts and a pre-approved error budget. The app
  cannot reliably remove false steps after receiving only an aggregate
  firmware total; a failing result requires supplier pedometer tuning or an
  approved high-rate raw-IMU gait classifier;
- battery, charging, off-wrist, haptics, alarms, raw PPG/IMU, and every claimed
  sensor;
- OTA eligibility, interruption, resume, wrong image, rollback/recovery, and
  power loss;
- signed-app network egress, privacy manifest/disclosures, vulnerability scan,
  SBOM, and independent mobile/firmware security review.

Until those gates pass, the SDK is a promising integration input, not evidence
that the NOOP Band or any customer-facing metric works.
