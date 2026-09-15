# NOOP Band supplier SDK assessment

**Reviewed:** 2026-09-12
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

## Repository boundary

The NOOP-owned SDK contract now lives in the separate private
`Dhanunjay-Divi/NoopBandSDK` repository. Its initial `main` commit is
`ee82cc0`. The repository contains only English NOOP-owned architecture,
capability schema, conformance scenarios, supplier-intake records, platform
adapter requirements, and local validation. It contains no vendor binary and
no hosted GitHub Actions workflow.

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
| Android transport AAR | `vpbluetooth-1.20.aar` |
| iOS framework | `VeepooBleSDK.framework` under `2.2.XX.15`, SHA-256 `22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35` |
| iOS binary form | static archive, `arm64`, iPhoneOS only; no simulator, Catalyst, or macOS slice |
| Top-level license files | Apache License 2.0 text is present for Android and iOS |

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
11. Publish the neutral SDK from the separate private repository as pinned
    Apple and Android artifacts. The NOOP app repository consumes an exact
    version and digest; it does not host supplier source or binaries.

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
- actual history days, overflow, partial resume, duplicate delivery, clock
  reset, timezone/DST, and multi-day phone absence;
- foreground, screen-off, background, process death, force-quit, reboot, low
  storage, Android OEM restriction, and iOS restoration behavior;
- live plus catch-up sequencing under the one-command queue;
- battery, charging, off-wrist, haptics, alarms, raw PPG/IMU, and every claimed
  sensor;
- OTA eligibility, interruption, resume, wrong image, rollback/recovery, and
  power loss;
- signed-app network egress, privacy manifest/disclosures, vulnerability scan,
  SBOM, and independent mobile/firmware security review.

Until those gates pass, the SDK is a promising integration input, not evidence
that the NOOP Band or any customer-facing metric works.
