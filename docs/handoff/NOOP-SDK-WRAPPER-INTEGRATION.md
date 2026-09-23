# NOOP Band SDK wrapper integration

**Status:** implementation handoff; supplier transport and physical validation
remain gated

**Last reviewed:** 2026-09-19

## 1. Purpose

This document defines how the candidate supplier SDK enters NOOP without
letting vendor types, callbacks, storage, network behavior, or health claims
become application architecture. It covers the complete path from local band
discovery through ownership, live and historical collection, reconnect,
staged managed upload, diagnostics, firmware handling, physical validation,
and rollback.

The supplier package is a candidate transport dependency. It is not evidence
that the production band supports a capability, produces an accurate metric,
survives background execution, preserves history, or can be redistributed.
The exact model, firmware project, binary rights, and physical behavior remain
external gates.

The current source already provides important seams:

- one active wearable source through Apple and Android source coordinators;
- a durable device registry and source-specific sample identity;
- a phone-edge collection and offline working path that does not require the
  supplier SDK or a continuously available network, with at-rest encryption
  still an open D-059 security gate;
- bounded diagnostics;
- a default-off ownership account and atomic claim foundation whose physical
  possession provider deliberately remains unavailable;
- separately consented managed-history and canonical-formula foundations for
  the staged D-059 migration; and
- the existing WHOOP transport used for development and regression testing.

This integration must preserve those seams. It must not rename the WHOOP
transport as first-party hardware, route supplier bytes through WHOOP protocol
decoders, or remove WHOOP support as part of wrapper integration. WHOOP remains
the distinct comparison and regression transport through supplier acceptance
and the physical validation program.

Related source-of-truth documents:

- [Supplier SDK assessment](../NOOP_BAND_SUPPLIER_SDK_ASSESSMENT.md)
- [Band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
- [First production release plan](../FIRST_PRODUCTION_RELEASE_PLAN.md)
- [Device-driver architecture](../DEVICE_DRIVER_ARCHITECTURE.md)
- [Platform architecture](../PLATFORM_ARCHITECTURE.md)
- [Cloud architecture](../CLOUD_ARCHITECTURE.md)
- [Durable decisions](../ops/DECISIONS.md)
- [Release blockers](RELEASE-BLOCKERS.md)
- [Observability contract](../OBSERVABILITY.md)

The companion [band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
is the authoritative cross-feature physical matrix. Section 15 below is the
wrapper-specific subset and must be executed with that companion handoff; this
document does not replace it. Current architecture decisions, especially
D-059, govern cloud-authority interpretation; the companion remains
authoritative for the physical scenarios and evidence package.

### 1.1 Decision alignment

- D-043 keeps first-party device identity, protocol, offline history,
  acknowledgements, and OTA support capability-gated until representative
  physical evidence exists.
- D-055 permits exactly one phone collector. Mac, Watch, and additional
  signed-in devices are viewers or companions unless a future collector
  handoff is separately validated.
- D-056 keeps the NOOP-owned neutral SDK in the private `NoopBandSDK`
  repository and consumes only approved, pinned platform artifacts. Supplier
  binaries and the original supplier drop remain outside this repository.
- D-059 targets cloud authority for durable account history, canonical
  versioned metric publication, recommendations, and cross-device state
  through per-data-class and per-formula gates. The phone remains the encrypted
  edge collector and bounded offline working set until those gates pass.
- Existing WHOOP 4.0, 5.0, and MG support remains a separate test transport.
  Supplier integration must not relabel, rewrite, or delete WHOOP provenance.

## 2. Non-negotiable product and engineering rules

1. Exactly one phone is the active BLE collector for one band. Mac, Watch, and
   additional signed-in devices are viewers or companions, not competing BLE
   collectors.
2. WHOOP remains an independent test transport until the supplier transport
   passes representative Apple and Android physical validation.
3. The printed band number is a discovery locator, not a password, owner key,
   or possession proof.
4. A platform bond, a four-digit vendor password, a device number, or a single
   tap does not establish ownership.
5. Ownership requires an authenticated account request, fresh server
   challenge, challenge-bound proof from the selected physical band, and one
   atomic single-owner server transaction.
6. Supplier callbacks enter one serialized session state machine. Screens,
   analytics, storage, cloud, and ownership code never receive vendor objects.
7. A history cursor or band acknowledgment advances only after normalized
   rows are durably and idempotently committed.
8. Live delivery and historical delivery converge into the same normalized
   store, but live delivery never advances a historical cursor.
9. Capabilities are accepted from the connected model and firmware report.
   Product names, advertised services, SDK documentation, or vendor demo
   screens do not imply support.
10. Unknown required protocol or capability revisions fail closed. Unknown
    optional fields may be ignored only when the versioned contract says they
    are optional.
11. Off-wrist sampling reduction, wear detection, autonomous collection, and
    flash retention are firmware responsibilities. While disconnected, the band
    must continue sampling into a documented bounded circular history. At full
    capacity it may overwrite only the oldest retained records, must preserve
    the newest data, and must expose retained bounds plus an explicit
    wrap/overflow signal so the app can identify an unrecoverable gap. A phone
    request or SDK claim cannot substitute for firmware and physical evidence.
12. Collection, immediate Safety initiation, export, local band control, and a
    bounded safe offline working state remain usable after activation without
    NOOP+, payment, or a continuously available network. History and formulas
    move to cloud authority only through the staged D-059 gates; until a gate
    passes, the current verified implementation remains authoritative.
13. Managed upload is opt-in and reads only committed NOOP records. The
    supplier SDK never uploads health data or calls NOOP cloud services
    directly.
14. Vendor-named apnea, blood-pressure, disease-risk, body-composition, or
    similar outputs remain unavailable unless NOOP separately validates their
    intended use, accuracy, safety, and regulatory position.
15. Builds, simulators, mocks, and synthetic fixtures do not prove BLE,
    background execution, haptics, battery life, sensor accuracy, firmware
    recovery, or physical accessibility.

## 3. Current implementation versus remaining gates

| Boundary | Current source state | Still required |
|---|---|---|
| Single active source | Implemented by `SourceCoordinator` on Apple and Android | Supplier adapter registration and physical source-switch tests |
| Neutral SDK core | Digest-pinned Swift and Kotlin state machines, bounded diagnostics, virtual fixtures, conformance scenarios, and app build boundaries are integrated default-off | Supplier-specific transport mapping and physical validation |
| WHOOP transport | Implemented and retained | Continue regression coverage until supplier acceptance completes |
| Device registry | Implemented with one active source and source-specific provenance | First-party identity mapping and migration fixtures |
| Live persistence | Implemented for current transports | Supplier sample normalization, units, quality, deduplication, and physical comparison |
| Historical persistence | Durable-before-ack invariant implemented for current WHOOP path | Supplier cursor/ack semantics, interruption behavior, flash retention, and physical tests |
| Ownership account | Supplier-independent account, terms, claim, and replacement-phone state machines exist default-off | Approved possession provider, owner-key provisioning, production identity/abuse controls, and physical two-phone tests |
| Possession proof | Interface exists; production provider returns unavailable | Firmware-backed, challenge-bound, debounced confirmation and supplier mapping |
| Capability display | Device capability models exist | Exact supplier function report, firmware compatibility matrix, and fail-closed adapter |
| Managed history and formulas | Source foundations exist behind explicit configuration and consent; authority remains staged per D-059 | Dual-run parity, signed-client, production, load, retention, restore, rollback, security, and physical lifecycle evidence before each authority switch |
| Diagnostics | `AppDiagnosticsRecorder` and user report paths exist on both platforms | Supplier lifecycle events, redaction tests, and reports from real stalls |
| Firmware update | Product requirements exist | Signed manifest, trusted transport, interruption/resume, anti-rollback, rescue, and hardware evidence |
| Supplier binaries | Reviewed outside Git; separate SDK repository is documented | Written redistribution rights, dependency inventory, SBOM, security review, privacy manifest, artifact hosting, and pinned release |
| Apple supplier runtime | Candidate iPhoneOS arm64 binary reviewed | Signed iPhone integration and physical runs; no simulator, Catalyst, or macOS claim |
| Android supplier runtime | Candidate AARs reviewed | Signed Android integration, OEM/background matrix, and physical runs |
| Production band accuracy | Not established | Bench and participant validation for every shipped signal and firmware revision |

The binary-free neutral SDK core is integrated in this app repository through
one exact source manifest. Apple consumes the pinned Swift package, Android
compiles the pinned Kotlin sources, and both source coordinators expose an
optional factory that every production composition root leaves disabled. The
supplier-specific wrapper described below is not implemented: no vendor
binary, real scan, identity mapping, possession proof, history offload,
haptic/alarm command, OTA, or firmware flasher is registered. The integrated
core and virtual evidence do not close any supplier or hardware gate.

## 4. Target topology

```text
                          ownership control plane
                         (identity and claim only)
                                   ^
                                   |
NOOP Band <-> supplier wrapper <-> active phone collector
                                   |
                                   +-> encrypted edge journal and bounded
                                   |   offline normalized working store
                                   |       |
                                   |       +-> current/shadow analytics and UI
                                   |       +-> export
                                   |
                                   +-> consented D-059 managed outbox
                                             |
                                             +-> durable account history
                                             +-> canonical formulas/read models
                                             +-> managed viewers

Mac / second phone / Watch:
  viewer or companion through approved account/sync paths
  no competing supplier BLE session in the first release
```

The active phone owns connection state, history durability, immediate
freshness, and the decision to present locally relevant guidance. Cloud
storage cannot repair a dropped BLE link or make a stale local signal fresh.
The managed service becomes authoritative only for a data class or formula
after its migration, parity, provenance, restore/deletion, rollback,
performance, security, and signed physical-device gates pass.

## 5. Wrapper layers

The wrapper is split into layers so each trust boundary can be tested and
replaced independently.

### 5.1 Supplier binary quarantine

- Supplier binaries remain outside Git.
- Approved binaries are stored in a restricted artifact registry only after
  distribution, security, dependency, privacy, and support review.
- The original supplier drop remains immutable for provenance.
- The app consumes one exact wrapper version and digest.
- Vendor callbacks, models, errors, databases, URLs, and optional network
  behavior stop at this layer.
- Unexpected supplier network egress is denied by default and verified in the
  signed application.

### 5.2 Native supplier adapter

One Apple adapter and one Android adapter translate the reviewed supplier
surface into the neutral contract in section 6. They:

- serialize every command for one band;
- bind callbacks to one session generation;
- reject callbacks from a closed or superseded session;
- impose timeout and cancellation at the wrapper boundary;
- map arbitrary vendor failures to fixed NOOP categories;
- expose opaque operation and cursor tokens only to the owning coordinator;
- never persist through a vendor database; and
- never expose vendor medical labels to product code.

### 5.3 Session state machine

The session owns:

- discovery and candidate selection;
- provisional connection and device confirmation;
- link authentication and optional password rotation;
- identity and capability negotiation;
- clock correlation;
- live subscription;
- history draining and acknowledgment;
- battery, wear, haptic, alarm, and other capability-gated commands;
- firmware eligibility and update exclusivity; and
- disconnect, reconnect, and recovery.

Only one time-consuming operation may run at once. Live notifications may
continue during an allowed operation, but history, settings, clock, haptic,
alarm, capability, and firmware commands cannot race each other unless the
exact firmware contract explicitly permits it.

### 5.4 NOOP product adapter

The app-facing adapter converts neutral events into:

- connection and freshness state;
- pairing and ownership progress;
- accepted capabilities;
- normalized live and history batches;
- battery, charging, and wear state;
- sync progress based on durable commits;
- fixed actionable failure states; and
- bounded diagnostics.

The app-facing adapter does not contain supplier method names or types. It is
the only layer referenced by onboarding, the device screen, ownership,
collection, history, and firmware UI.

### 5.5 Storage adapter

The storage adapter:

1. validates bounds, units, quality, identity, ordering, and timestamps;
2. correlates device time to a trusted wall-clock anchor;
3. derives one stable deduplication identity per record or chunk;
4. writes normalized rows under the first-party NOOP device source;
5. commits source provenance and cursor state atomically where required;
6. emits a durable receipt; and
7. only then permits the session to acknowledge or advance the band cursor.

Supplier payloads must not be passed through `WhoopProtocol` or
`com.noop.protocol`. The wrapper maps accepted supplier values directly into
the neutral store models used by the platform.

### 5.6 Repository and artifact boundary

The separate private `Dhanunjay-Divi/NoopBandSDK` repository is the only home
for the NOOP-owned neutral wrapper contract. At this review its binary-free
scaffold is pinned at `ee82cc0`; its local gate reports 14 repository files
passing language, binary, and JSON checks. That proves only repository hygiene,
not an implemented adapter or hardware behavior.

The intended module split is:

```text
NoopBandSDK/
  spec/                 versioned capabilities, units, failures, compatibility
  conformance/          platform-neutral scenarios and golden expectations
  apple/
    NoopBandCore        neutral Swift models and state machines
    NoopBandVendor      device-only adapter that links the approved framework
  android/
    noop-band-core      neutral Kotlin models and state machines
    noop-band-vendor    adapter that resolves the approved AARs
  tools/                binary-free fixture and conformance validation
  vendor/               hashes and reviewed metadata only, never binaries
```

These names describe the target ownership boundary; they are not a claim that
the modules are already implemented.

Artifact flow is one-way:

1. Preserve the original supplier drop read-only and record its hashes.
2. Review rights, dependencies, SBOM, vulnerabilities, privacy, egress, exact
   model support, and update ownership.
3. Publish approved supplier binaries only to a restricted artifact registry.
4. Build signed NOOP-owned Apple and Android wrapper artifacts against those
   exact inputs.
5. Pin wrapper version, supplier version, and digests in the app build.
6. Keep simulator/JVM conformance independent of supplier binaries.
7. Never copy vendor demos, databases, logs, URLs, UI, medical labels, or
   multilingual source into app architecture.

### 5.7 Responsibility and trust matrix

| Layer | Owns | Must not own |
|---|---|---|
| Firmware/bootloader | band identity/key, tap proof, wear and autonomous collection, flash history, clock, acknowledgements, low-power mode, signed OTA and recovery | account authorization, cloud consent, NOOP formulas |
| Supplier transport | reviewed BLE/parser calls for the exact project | product storage, UI, diagnostics policy, medical truth |
| NOOP wrapper | serialized session, callback generation, capability negotiation, neutral models, fixed failures, durable receipt boundary | account state, direct cloud calls, formulas, user-facing claims |
| NOOP phone app | permissions, one collector, activation UX, durable store, freshness, managed outbox, bounded diagnostics | claiming force-quit execution, repairing firmware gaps |
| Ownership/cloud | atomic owner, installations, optional managed history/viewers, gated canonical publication | physical possession without band proof, live BLE freshness |
| Operator/supplier | provisioning, rights, signing, manufacturing, RMA/wipe, support and security response | undocumented waivers or hidden production exceptions |

## 6. Platform-neutral wrapper contract

The following is NOOP-owned pseudocode. Names describe the wrapper contract;
they are not claims about names in the supplier SDK.

```text
interface NoopBandTransportFactory {
    create(environment, artifactIdentity) -> NoopBandTransport
}

interface NoopBandTransport {
    states() -> Stream<BandTransportState>
    events() -> Stream<BandTransportEvent>

    scan(request: BandScanRequest) -> CancellableOperation<BandDiscoveryResult>
    open(candidate: BandPairingCandidate) -> BandSession
    stopScanning()
    close()
}

interface BandSession {
    state() -> BandSessionState

    connect(intent: ConnectionIntent) -> BandIdentity
    identify(request: IdentifyRequest) -> CommandReceipt
    provePossession(challenge: BandPossessionChallenge) -> BandPossessionProof

    negotiateCapabilities() -> BandCapabilityReport
    establishClockAnchor(request: ClockAnchorRequest) -> ClockAnchorReceipt

    startLive(request: LiveCollectionRequest) -> Stream<BandSampleBatch>
    stopLive() -> CommandReceipt

    readHistory(request: BandHistoryRequest) -> Stream<BandHistoryChunk>
    acknowledgeHistory(receipt: DurableHistoryReceipt) -> CommandReceipt

    readBattery() -> BandBatteryState
    readWearState() -> BandWearState
    performHaptic(request: BandHapticRequest) -> CommandReceipt
    configureAlarm(request: BandAlarmRequest) -> CommandReceipt
    requestSamplingMode(request: BandSamplingModeRequest) -> CommandReceipt

    readFirmwareState() -> BandFirmwareState
    evaluateFirmwareUpdate(manifest: VerifiedFirmwareManifest)
        -> FirmwareEligibility
    performFirmwareUpdate(plan: ApprovedFirmwareUpdatePlan)
        -> Stream<BandFirmwareUpdateState>

    cancel(operation: OperationToken)
    disconnect(reason: DisconnectReason)
    close()
}
```

### 6.1 Required neutral models

`BandPairingCandidate`

- wrapper-local candidate handle;
- compatibility category;
- minimum printed-label match representation approved by product and privacy;
- identify eligibility;
- provisional confirmation state; and
- no raw Bluetooth address in UI or diagnostics.

`BandIdentity`

- stable NOOP source identity or a provisional local identity before claim;
- hardware revision;
- firmware revision;
- protocol revision;
- supplier-wrapper artifact revision; and
- no assumption that a vendor device number equals the printed number.

`BandCapabilityReport`

- report revision and required protocol range;
- supported live streams and history categories;
- units, cadence, quality semantics, and calibration revision;
- history capacity, cursor type, completion, and overflow semantics;
- oldest/newest retained bounds and cursor generation or equivalent wrap
  marker;
- battery, charging, wear, haptic, alarm, sampling, and OTA support;
- command concurrency restrictions; and
- accepted, unsupported, or incompatible result.

`BandSampleBatch`

- source identity;
- stream kind;
- device time and sequence;
- normalized unit and quality;
- calibration and parser revisions;
- provenance lane (`live` or `history`); and
- typed sample rows, never an unbounded arbitrary object.

`BandHistoryChunk`

- opaque chunk identity;
- ordered sample batches;
- previous/next opaque resume cursor;
- completion and overflow state;
- oldest/newest retained bounds plus the first range lost to circular
  overwrite, when any;
- an acknowledgment token that has no effect until returned with a durable
  storage receipt; and
- bounded count/range metadata for progress without health values.

`BandPossessionProof`

- opaque, expiring, challenge-bound proof generated from firmware-authenticated
  confirmation;
- band/session binding;
- result category;
- no raw tap samples; and
- no reusable password or owner key.

`BandFirmwareState`

- running and fallback firmware revisions;
- hardware compatibility;
- boot/recovery state;
- signed-update eligibility;
- minimum battery/charging requirements; and
- rollback/rescue availability.

`BandTransportFailure`

- one fixed category such as unavailable, permission, noResult, timeout,
  rejected, incompatible, authentication, staleCallback, disconnected,
  storage, historyStalled, lowBattery, updateNotEligible, updateInterrupted,
  updateVerification, or internal;
- retryability and user-action classification; and
- no arbitrary vendor exception string.

### 6.2 Lifecycle states

```text
idle
  -> scanning
  -> candidateSelected
  -> connecting
  -> provisionalConfirmation
  -> authenticating
  -> negotiatingCapabilities
  -> ready
       -> liveCollecting
       -> historyCollecting
       -> executingCommand
       -> updatingFirmware
  -> disconnecting
  -> idle
```

Any state may enter a bounded `recovering` state after a retryable failure.
`closed`, incompatible firmware, rejected ownership, security failure, and
unrecoverable update failure are terminal for that session. Every asynchronous
callback carries a session generation; older generations are ignored.

### 6.3 Cross-platform conformance contract

Swift and Kotlin implementations must consume the same scenario definitions
and produce semantically equivalent state, normalized records, durable
receipts, and fixed failure categories. The minimum binary-free suite is:

| Scenario | Required result |
|---|---|
| discovery success, no result, cancel, timeout | one terminal result; no stale candidate reuse |
| selected-band identify success/reject/timeout | provisional state only; no ownership side effect |
| callback after close or reconnect | old session generation ignored |
| overlapping history, settings, haptic, and OTA requests | one serialized order or explicit busy rejection |
| unknown required capability revision | fail closed before collection |
| unknown optional field | ignored only when the schema marks it optional |
| duplicate/out-of-order/corrupt samples | deterministic reject or idempotent commit |
| process interruption before/after durable commit | cursor and acknowledgement resume from the durable point |
| complete-empty history versus silence | distinct success and timeout outcomes |
| low battery, storage pressure, thermal deferral | bounded state with no lost acknowledgement |
| ownership proof unavailable/replay/wrong band | no claim and no reusable proof |
| firmware bad signature/wrong hardware/interruption | no activation; known retry, fallback, rescue, or terminal state |
| diagnostic export | fixed categories and bounded counts with prohibited fields absent |

Conformance fixtures contain fictional bounded values. They do not contain a
real serial, account, health history, supplier capture, credential, or firmware
image.

## 7. Apple mapping

| Neutral boundary | Existing Apple seam | Integration rule |
|---|---|---|
| One active source | [`SourceCoordinator`](../../Strand/BLE/SourceCoordinator.swift) | Supplier source participates as one source; it never runs beside the WHOOP collector |
| Minimal lifecycle | [`LiveHRSource`](../../Strand/BLE/LiveHRSource.swift) | Supplier product adapter may conform for `scan`, direct `connect`, and `stop`; richer state remains on its typed session |
| Registry | [`DeviceRegistry`](../../Strand/Data/DeviceRegistry.swift) and `WhoopStore` registry | Store NOOP device identity, accepted capabilities, status, and a protected platform-local locator |
| Live persistence | [`Collector`](../../Strand/Collect/Collector.swift) durable cadence and store-writing seam | Reuse the durability pattern, not WHOOP decoding; supplier batches become neutral store streams |
| History durability | [`Backfiller`](../../Strand/Collect/Backfiller.swift) durable-before-ack invariant | Implement a supplier-specific history coordinator with the same ordering; do not feed supplier chunks into WHOOP history parsing |
| Ownership proof | `OwnershipBandPossessionProviding` in [`OwnershipFlowState`](../../Strand/System/OwnershipFlowState.swift) | Approved wrapper provider returns only fresh opaque proof; unavailable remains the production default until physical acceptance |
| Ownership service | [`OwnershipService`](../../StrandiOS/System/OwnershipService.swift) | Account, terms, challenge, claim, replacement-phone, and revocation remain outside the SDK |
| Diagnostics | [`AppDiagnosticsRecorder`](../../Strand/System/AppDiagnosticsRecorder.swift) | Record fixed operation classes, counts, durations, and outcomes only |
| Managed cloud | [`ManagedCloudService`](../../StrandiOS/System/ManagedCloudService.swift) and managed sync adapters | Upload only committed normalized data after separate consent and D-059 gating; SDK never calls cloud |

Apple-specific constraints:

- The reviewed supplier binary is iPhoneOS arm64 only. It cannot support the
  iOS Simulator, Catalyst, or the macOS app.
- The supplier framework belongs behind the iOS app composition root and must
  not leak into shared Swift packages, macOS compilation, widgets, Watch
  targets, or analytics.
- Simulator tests use a deterministic virtual transport that implements the
  neutral contract without linking the supplier binary.
- CoreBluetooth background modes and state restoration are enabled only for
  the exact justified collector path. Their presence does not establish
  force-quit relaunch or uninterrupted background collection.
- Mac remains a viewer, planner, journal, export, and analysis surface through
  local files or approved managed sync. It does not open the supplier BLE
  session.
- Watch reflects phone-authorized state and supported companion actions. It
  does not become a second collector unless a future, separately validated
  Watch transport is approved.

Apple composition order:

1. `NOOPiOS` selects the internal supplier source behind a default-off,
   exact-compatibility gate.
2. The iOS composition root loads the pinned device-only wrapper artifact.
3. The wrapper creates one supplier session and exposes only neutral models.
4. `SourceCoordinator` stops the active WHOOP/non-WHOOP source before starting
   the supplier source.
5. The supplier history coordinator writes through the existing durable store
   boundary and returns receipts before any band acknowledgement.
6. Widgets, Watch, macOS, shared packages, analytics, and UI targets link only
   neutral NOOP models and never link the supplier framework.

## 8. Android mapping

| Neutral boundary | Existing Android seam | Integration rule |
|---|---|---|
| One active source | [`SourceCoordinator`](../../android/app/src/main/java/com/noop/ble/SourceCoordinator.kt) | Supplier source replaces the active collector; it never runs beside `WhoopBleClient` |
| Minimal lifecycle | [`LiveHrSource`](../../android/app/src/main/java/com/noop/ble/LiveHrSource.kt) | Supplier product adapter may implement `scan`, direct `connect`, and `stop`; typed state stays outside the coordinator interface |
| Registry | [`DeviceRegistry`](../../android/app/src/main/java/com/noop/data/DeviceRegistry.kt) | Store the same logical identity/capability meaning as Apple and one protected local locator |
| Normalized storage | [`WhoopRepository`](../../android/app/src/main/java/com/noop/data/WhoopRepository.kt) | Convert supplier batches into `StreamBatch`; never pass supplier bytes to WHOOP framing |
| Runtime lifecycle | [`WhoopConnectionService`](../../android/app/src/main/java/com/noop/ble/WhoopConnectionService.kt) | Follow connected-device foreground-service and reconnect policy only when Android requires and permits it |
| Ownership proof | `OwnershipBandPossessionProvider` in [`OwnershipModels`](../../android/app/src/main/java/com/noop/ownership/OwnershipModels.kt) | Approved wrapper provider returns fresh opaque proof; unavailable remains default until accepted |
| Diagnostics | [`AppDiagnosticsRecorder`](../../android/app/src/main/java/com/noop/AppDiagnosticsRecorder.kt) | Use fixed categories and bounded fields; never Logcat health values or identifiers |
| Managed cloud | `ManagedSyncCoordinator`, `ManagedCloudService`, and Room adapters | Upload committed normalized rows through the managed outbox only after separate consent and D-059 gating |

Android-specific constraints:

- The AARs remain outside source control and are resolved by exact approved
  artifact identity.
- The adapter requests only permissions justified by the exact Android and
  hardware path. Vendor demo permissions are not copied.
- Scanning starts from explicit setup or bounded reconnect intent, not an
  unbounded always-on scan.
- A foreground service is used only when platform policy requires an ongoing
  connected-device operation. WorkManager handles deferred sync or analysis,
  not a continuous BLE socket.
- Connection priority or preferred PHY is elevated only for a measured,
  bounded transfer and released afterward.
- OEM background, process-death, reboot, permission, battery-saver, and
  force-stop behavior require representative physical testing. The wrapper
  reports deferral honestly instead of claiming continuous collection.

Android composition order:

1. The Full flavor selects the internal supplier source behind a default-off,
   exact-compatibility gate; Demo uses the virtual transport.
2. The app resolves pinned wrapper/AAR artifacts from the approved restricted
   repository, never from a checked-in `libs` directory.
3. One adapter instance owns supplier callbacks and emits neutral state.
4. `SourceCoordinator` stops `WhoopBleClient` or another active source before
   starting the supplier source.
5. The adapter writes normalized batches through `WhoopRepository` and returns
   a durable receipt before history acknowledgement.
6. Compose UI, Room entities, analytics, cloud, widgets, and tests never import
   vendor packages.

## 9. End-to-end user flow

### 9.1 Explore and begin setup

1. A new user may explore account-free product education and supported local
   import features.
2. Selecting `Set up NOOP Band` explains that the band must be worn, charged,
   and in a time-bounded pairing mode.
3. The app requests only the platform permissions needed for the current
   setup step. Denial keeps setup recoverable and does not show a connected
   state.

### 9.2 Find and provisionally confirm the physical band

1. The user enters or selects the minimum printed number needed to locate the
   band.
2. The wrapper scans only eligible candidates and locally filters candidates
   through the approved printed-label mapping.
3. The app selects one candidate and asks it to perform an identify vibration.
4. The user confirms that the worn band vibrated.
5. This creates a provisional setup session only. It is not ownership and does
   not authorize ordinary data collection.
6. If the platform or supplier stack requires a bond before account claim, the
   bond uses a bounded provisional credential and remains replaceable. It does
   not become the owner authority.

### 9.3 Terms, account, and ownership

1. The app fetches the exact immutable remote Terms version through the
   existing verified no-persistent-document-cache path.
2. The user is shown the one-account ownership rule, available recovery paths,
   absence of a v1 user transfer action, and separate NOOP+ consent.
3. The user explicitly accepts the versioned Terms.
4. The user creates or signs in to a verified email/password ownership
   account. Optional phone verification remains optional.
5. The authenticated server issues a short-lived possession challenge for the
   provisional band.
6. The app sends the challenge through the wrapper and asks for at least three
   deliberate taps.
7. Firmware, not phone motion inference, debounces the taps and produces one
   authenticated response bound to the challenge and selected band.
8. The wrapper returns only the opaque proof to the ownership service.
9. The server atomically accepts one owner or rejects stale, replayed,
   wrong-band, wrong-firmware, or concurrent claims.
10. After claim commit, the app provisions owner-scoped credentials. A
    supplier four-digit password may be rotated to an app-generated random
    value as defense in depth, but it remains subordinate to ownership.
11. Ownership records contain no health samples and do not imply NOOP+
    consent.

Until steps 5-10 have a supplier-backed implementation and physical evidence,
the existing unavailable possession provider remains in place.

### 9.4 Activation bootstrap

After an atomic claim:

1. Persist the NOOP source identity and protected local locator.
2. Connect through the serialized session.
3. verify hardware, firmware, protocol, and wrapper compatibility;
4. accept and persist the exact capability report;
5. establish a trusted device-time/wall-time anchor;
6. read battery, charging, wear, and available history bounds;
7. subscribe only to supported live streams;
8. start bounded historical catch-up from the last durable cursor; and
9. publish `ready` only after required setup state is durably stored.

If a required capability or protocol is incompatible, setup fails closed with
an actionable message. It does not silently downgrade to a different product
claim.

### 9.5 Live collection

1. The wrapper receives supplier callbacks and binds them to the current
   session generation.
2. The adapter validates type, bounds, unit, quality, sequence, and clock.
3. Accepted batches are normalized and durably written under the NOOP band
   source.
4. UI freshness advances from accepted local progress, not callback arrival
   alone.
5. Local analytics read committed records and keep missing inputs missing.
6. High-frequency writes are batched within a bounded memory and time budget.
7. A disconnect flushes accepted pending data before teardown when the OS
   permits, then leaves the remainder retryable.

### 9.6 Historical catch-up

1. Read the capability-reported history range and last acknowledged cursor.
2. Request one bounded history operation through the serialized queue.
3. Validate each chunk and reject or quarantine malformed or unsupported
   content without advancing its cursor.
4. Normalize and commit idempotently.
5. Create a durable receipt containing the accepted chunk identity and cursor.
6. Return the receipt to the wrapper and acknowledge only that committed
   range.
7. Persist the next resume cursor.
8. Continue within OS, thermal, battery, memory, storage, and time budgets.
9. Distinguish complete-empty, complete-with-data, interrupted, deferred,
   storage-stalled, cursor-stalled, and transport-failed states.
10. Resume from the last durable point after reconnect or process restart.
11. If firmware reports a circular-buffer wrap beyond the last acknowledged
    point, persist the new retained bounds, publish a bounded history-gap state,
    and continue from the oldest still-retained record. Never relabel the
    remaining range as complete or fabricate the overwritten interval.

If the supplier SDK automatically deletes or acknowledges history before NOOP
can commit it, that behavior is launch-blocking. The supplier must expose
safe acknowledgment semantics, a non-destructive read mode, or another
auditable recovery contract.

### 9.7 Reconnect and background behavior

1. A remembered active band permits bounded direct reconnect before scanning.
2. Reconnect uses exponential backoff with jitter and stops on permission,
   ownership, incompatible firmware, or explicit user pause.
3. An active foreground workout or catch-up may temporarily request a faster
   link; idle operation returns to the measured low-power mode.
4. The app records background deferral and resumes when the OS allows it.
5. The UI may briefly show that catch-up started, then remain interactive
   while durable background work continues.
6. The app never claims collection while force-quit or after Android
   force-stop unless the exact platform and signed physical build prove it.
7. A cloud outage never disconnects the band or blocks local collection.

### 9.8 Replacement phone

1. The user signs in to the same ownership account.
2. The server confirms the account owns the band without exposing owner
   identity to other accounts.
3. The new phone creates a short-lived installation authorization challenge.
4. The user repeats physical possession proof on the worn band.
5. The server authorizes the new installation and revokes or limits the old
   installation according to approved policy.
6. Owner keys and any rotated supplier credential are recovered through the
   approved protected path.
7. Local collection starts; managed history restore remains a separately
   consented, staged D-059 action.
8. A different account cannot claim or learn the owner's identity.

### 9.9 Mac and additional viewers

- The active phone remains the collector.
- An approved signed-in Mac or second device may restore or view data through
  explicit managed sync.
- Viewers do not scan for or connect to the band.
- A future collector handoff must pause new commands, commit pending data,
  checkpoint history, release a collector lease, disconnect, and then let the
  new phone resume. Silent or concurrent handoff is not supported.

### 9.10 Return, RMA, deletion, and future upgrade

- V1 has no user-facing unpair or transfer.
- Ordinary local disconnect or app deletion does not release ownership.
- Return, RMA, verified dispute, recovery, account deletion, fraud, legal,
  recycling, and security exits are operator-controlled and require approved
  policy.
- A release flow must revoke owner credentials, wipe personal band state,
  verify the wipe, unlink the server record, and quarantine the hardware
  before another account can claim it.
- A future eligible successor-band upgrade may expose a reauthenticated
  release only after the approved old-band wipe and account transition.

## 10. Capability and firmware negotiation

### 10.1 Capability acceptance

The first accepted session for each hardware/firmware pair persists:

- wrapper artifact version and digest;
- model and hardware revision;
- firmware and protocol revision;
- capability report revision;
- capability schema version;
- supported live stream set;
- supported history stream set and limits;
- timestamp, quality, and calibration semantics; and
- incompatibility or degradation state.

Capability schema v3 treats live and stored-history support as independent,
binds every lane/stream pair to its negotiated unit, cadence, quality,
timestamp, parser, and calibration semantics, and declares which bounded
operation classes may run while live collection is active. A stream advertised
only in `historyStreams` does not authorize live delivery, and a stream
advertised only in `liveStreams` does not authorize history offload. Schema v1
and v2 reports are superseded and fail closed at this boundary; they are not
silently expanded or upgraded.

When circular history has overwritten data, an overflow chunk carries both the
retained device-time range and the first lost device-time range. Those ranges
must survive the accepted chunk and match the exact durable receipt before the
cursor advances. They are storage/provenance metadata and never enter
diagnostics.

The app compares every later report with the accepted report:

- an additive, known optional capability may become available after explicit
  product support;
- removal of a capability immediately hides or disables dependent collection
  and actions;
- an unknown required version blocks the session;
- a changed unit, cadence, quality, timestamp, or calibration contract requires
  a new parser/calibration revision and revalidation; and
- a firmware downgrade or identity mismatch is a security event, not a normal
  reconnect.

Capability-gated UI includes live metrics, history categories, battery detail,
wear state, haptics, alarms, sampling modes, raw research streams, and
firmware update. Unsupported actions are absent or explicitly unavailable;
they are never optimistically sent.

### 10.2 Firmware update boundary

Firmware update is exclusive: live/history commands are paused, committed,
and checkpointed before update begins.

An update may start only when:

- the manifest is NOOP-approved and cryptographically verified;
- hardware, bootloader, current firmware, protocol, and wrapper versions are
  compatible;
- battery, charging, thermal, storage, and network preconditions pass;
- rollback or rescue is available for the exact hardware revision;
- the band is owned by the current account and installation;
- no Safety or workout-critical operation is active; and
- the rollout cohort and halt policy permit it.

The wrapper reports eligibility, transfer, verification, activation,
reconnect, rollback, and terminal outcome. It never logs firmware bytes,
signing material, device identity, or arbitrary updater errors.

Production acceptance requires interrupted transfer, disconnect, app death,
phone reboot, low battery, power loss, wrong image, bad signature, failed boot,
rollback, rescue, and post-update history-continuity tests. Supplier OTA
availability alone does not satisfy these requirements.

## 11. Battery and performance policy

### 11.1 Band power

- Firmware owns wear detection, off-wrist sampling reduction, wake behavior,
  flash buffering, low-battery thresholds, charging safety, and thermal
  protection.
- The app may request a documented sampling mode only when the capability
  report permits it.
- A missing acknowledgment leaves the previous mode unknown; the app does not
  claim the request succeeded.
- Off-wrist battery preservation must work with the phone absent and requires
  bench measurement on exact firmware.

### 11.2 Phone power

- Scan only during setup, explicit recovery, or a bounded reconnect need.
- Prefer direct reconnect to a protected remembered locator.
- Subscribe to notifications instead of polling.
- Batch database writes and UI publication.
- Drain history in bounded pages and yield between pages.
- Elevate Android connection priority/PHY only for measured transfers and
  release it afterward.
- Avoid continuous timers when callbacks or OS scheduling can represent the
  same state.
- Pause or defer nonessential catch-up under low phone battery, thermal
  pressure, storage pressure, or OS battery restrictions.
- Keep firmware download, cloud upload, analytics, and BLE queues separate so
  one backlog cannot block live collection.
- Bound pending callbacks, sample batches, diagnostics, and retry queues.
- Measure memory, CPU, radio, thermal state, battery drain, database/WAL
  growth, launch, scrolling, and catch-up on representative release phones.

Battery optimization must not discard uncommitted history, fabricate
continuity, or suppress a user-visible failure.

## 12. Diagnostics and support evidence

The supplier path uses the existing platform `AppDiagnosticsRecorder`.
Diagnostics are best-effort and must not change session success.

### 12.1 Required events

- discovery begin, result-count bucket, completed, cancelled, and timed out;
- candidate selected and identify accepted, rejected, or timed out;
- possession window opened, accepted, rejected, expired, or unavailable;
- connect begin/end, provisional confirmation, authentication, and capability
  negotiation outcome;
- session state transition and disconnect category;
- command queued, started, completed, cancelled, or timed out by fixed command
  class;
- live start/stop, accepted-batch count, durable-commit count, stale callback,
  and no-durable-progress stall;
- history request, chunk accepted/rejected, durable commit, acknowledgment,
  complete-empty, complete-with-data, interrupted, retry, and cursor stall;
- reconnect attempt bucket and terminal outcome;
- background deferred/resumed;
- battery/thermal/storage pressure bucket;
- firmware eligibility, transfer bucket, verification, activation, reconnect,
  rollback, and terminal result; and
- managed outbox queued, uploaded, acknowledged, deferred, rejected, or
  failed by fixed category.

### 12.2 Prohibited diagnostic content

Never record:

- band name, Bluetooth address, printed number, vendor device number, serial,
  account identity, installation identity, or owner identity;
- password, owner key, possession challenge/proof bytes, tokens, credentials,
  cookies, URLs, or signed capabilities;
- sensor value, health row, raw frame, payload, sample timestamp, journal text,
  or screenshot;
- firmware image or manifest content;
- arbitrary vendor/platform exception text; or
- unbounded per-sample or per-callback events.

Reports may include fixed wrapper/app/OS version categories, operation
classes, bounded counts, duration buckets, state transitions, and redacted
failure categories. A user-initiated report remains local unless separately
consented for upload.

### 12.3 Release hardening and proprietary boundary

- Assume mobile binaries can be inspected. Do not place a fleet secret,
  firmware signing key, reusable owner key, cloud service credential, or
  privileged support capability in the wrapper or app.
- Security comes from per-band cryptographic identity, fresh challenges,
  server authorization, scoped installation credentials, signed artifacts,
  least privilege, revocation, and audited operations.
- Pin and verify the wrapper and supplier artifacts by digest. Sign release
  builds and retain symbol/mapping files only in restricted crash and release
  systems.
- Symbol stripping and platform obfuscation may raise reverse-engineering cost,
  but they are defense in depth and must not be described as encryption or an
  irreversible protection.
- The wrapper contains transport and normalization logic only. A formula that
  has passed the D-059 authority gates belongs in the canonical server engine,
  not in the supplier wrapper. Client shadow logic remains only while parity,
  rollback, and offline-transition gates require it.
- Never weaken diagnostic redaction to compensate for stripped symbols.
  Operator-facing correlation uses bounded version, operation, state, and
  failure categories rather than raw exceptions or identifiers.

## 13. Staged managed-cloud upload

The wrapper never uploads directly.

```text
supplier callback
  -> neutral validation
  -> durable local transaction
  -> local analytics/read models
  -> explicit managed-sync outbox
  -> authenticated resumable upload
  -> server validation and immutable availability
```

Rules:

1. Ownership claim and health-data consent are separate.
2. Managed-health transfer remains an explicit, versioned choice while the
   D-059 migration is gated. NOOP versus NOOP+ packaging must not weaken
   Safety, export, restore, deletion, or the bounded safe offline experience.
3. Only normalized, committed rows enter a managed export snapshot.
4. High-rate history uses compressed, checksummed, immutable chunks. Server
   metadata stores authorization, manifests, cursors, quotas, provenance, and
   lifecycle state rather than an unbounded duplicate of every raw row.
5. Upload is resumable and idempotent. Network loss leaves local collection
   and the outbox intact.
6. A server acknowledgment cannot advance or erase the band's own history
   cursor. Band durability and cloud durability are independent.
7. Managed pruning applies only after the exact data class has passed its
   D-059 authority gate and only to server-acknowledged, restore-proven clean
   windows. It never applies to dirty, unacknowledged, unsupported, or pending
   edge data.
8. Mac and additional viewers consume approved managed read models or restored
   history; they never invoke the supplier SDK.
9. Revoking managed access stops future upload. Account export, retention, and
   erasure follow the managed lifecycle, while edge-pending data remains
   recoverable and band ownership remains a separate control plane.
10. Production health upload remains disabled until signed-client,
    attestation, tenancy, restore, erasure, security, load, regional recovery,
    physical lifecycle, legal, and privacy gates pass.
11. A server formula or read model remains shadow-only until deterministic
    client/server parity, provenance, rollback, performance, security, and
    signed physical-device evidence authorize that exact authority switch.

## 14. Health and Safety limits

- Supplier data is an input, not a medical conclusion.
- Missing or unsupported inputs remain missing.
- Quality, wear, freshness, calibration, and provenance gates run before a
  signal reaches a metric or recommendation.
- Vendor apnea or disease labels are not shown as NOOP diagnoses or screening
  results.
- Body composition is not inferred from unsupported optical or vendor outputs.
- Workout caution requires validated evidence and conservative product policy;
  it is not emergency detection.
- Explicit app SOS and accepted-contact paging remain separate from wellness
  metrics. Automatic fall/emergency behavior stays disabled until its own
  detector, firmware, legal, physical, push, monitoring, and operations gates
  pass.
- Band haptics for Safety, workout, hydration, breathing, alarm, or social
  features are sent only when the exact capability and acknowledgment contract
  is supported.
- A failed or unknown haptic acknowledgment must not be displayed as delivered.
- No wrapper operation may delay an explicit SOS action or hide access to
  emergency services.

## 15. Wrapper-specific physical validation matrix

The companion [band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
is authoritative for the complete hardware, phone, Safety, accuracy, battery,
accessibility, OTA, and release matrix. This section adds the wrapper-specific
supplier and transport rows. A result closes a gate only when both documents'
applicable rows have named evidence.

Every result identifies the generalized phone/OS class, hardware revision,
firmware revision, wrapper/app build, scenario, expected result, observed
result, and evidence location without recording a serial number or personal
health values.

### 15.1 Supplier, legal, and artifact intake

- exact production model/project code and complete function report;
- written binary and dependency redistribution authority;
- complete dependency inventory, notices, SBOM, vulnerability review, privacy
  manifest, and update/support terms;
- immutable artifact hashes and restricted registry publication;
- runtime network-egress inventory and signed-app verification;
- named supplier firmware/security escalation owners; and
- India/USA legal, privacy, certification, store, and support approval.

### 15.2 Identity, pairing, and ownership

- printed-label format, uniqueness, and mapping to provisioned identity;
- multiple nearby bands and wrong printed-number rejection;
- identify vibration on only the selected band;
- pairing-mode entry, expiry, cancellation, and retry;
- provisional platform bond cleanup;
- at-least-three-tap firmware debounce;
- fresh challenge binding, replay rejection, wrong-band/wrong-firmware
  rejection, and stale-response rejection;
- simultaneous phones and simultaneous accounts;
- atomic single-owner outcome;
- default password rotation and recovery;
- replacement-phone authorization;
- wrong-account privacy;
- lost-phone and revoked-installation behavior; and
- operator return/RMA/recovery/wipe/quarantine paths.

### 15.3 Connection and reconnect

- first connection, ordinary reconnect, direct reconnect, and scan fallback;
- connection confirmation accepted, rejected, and timed out;
- Bluetooth off/on, permission revoke/restore, airplane mode, and radio reset;
- competing-phone and competing-app behavior;
- screen off, background, process death, force-quit/force-stop, reboot, and OS
  update;
- iOS restoration where supported;
- Android API/OEM/battery-saver variants;
- no reconnect storm, duplicate collector, or unbounded scan; and
- WHOOP -> supplier -> WHOOP source switching without data misattribution.

### 15.4 Live and historical data

- every claimed live stream and history category;
- documented units, cadence, quality, calibration, sequence, and clock;
- rest, sleep, motion, exercise, skin tone, fit, sweat, temperature, charging,
  low battery, loose fit, and off-wrist conditions where applicable;
- duplicate, out-of-order, truncated, corrupt, stale, and unsupported records;
- live plus catch-up sequencing;
- actual history depth, flash utilization, overflow, partial range, empty
  completion, and full flash;
- circular-buffer wrap that overwrites only the oldest retained records,
  preserves the newest records, advances its generation/bounds monotonically,
  and reports the exact unrecoverable gap;
- durable-before-ack behavior;
- interrupted commit, interrupted acknowledgment, resume, and duplicate
  delivery;
- phone absence for multiple days;
- timezone, daylight-saving, clock reset, clock drift, phone-time change, and
  firmware update continuity; and
- comparison against approved reference instruments and held-out subjects.

### 15.5 Battery, haptics, alarms, and commands

- on-wrist and off-wrist band power;
- phone absent, disconnected, and low-battery behavior;
- charger transitions, thermal limits, and brownout recovery;
- measured band and phone battery budgets;
- each haptic/alarm pattern, acknowledgment, timeout, cancellation, and
  duplicate-command protection;
- command serialization under simultaneous UI requests;
- unsupported capability rejection; and
- no high-priority Android link retained after bounded transfer.

### 15.6 Firmware update and recovery

- eligibility and hardware compatibility;
- good signature, bad signature, wrong hardware, downgrade, and expired
  manifest;
- normal transfer, pause, disconnect, retry, app death, phone reboot, band
  power loss, and low battery;
- verification, activation, reconnect, and history continuity;
- fallback boot, rollback, rescue mode, and unrecoverable quarantine;
- staged rollout halt and fleet-version visibility; and
- signing-key compromise and revocation drill.

### 15.7 Diagnostics and privacy

- user report from discovery timeout, connect loop, live stall, history stall,
  storage failure, low battery, background deferral, and failed firmware
  update;
- fixed category and bounded-count validation;
- redaction of every identifier, health value, raw payload, credential, URL,
  and vendor exception;
- no vendor network egress outside the approved inventory; and
- report creation remains responsive during a transport stall.

No capability moves to production-supported until its applicable matrix passes
on both signed phone platforms and the exact hardware/firmware revision.

## 16. Rollback and staged rollout

### 16.1 App and transport rollback

- Ship the supplier adapter default-off until the physical matrix passes.
- Keep WHOOP as a distinct selectable internal test transport.
- Pin the wrapper and supplier artifacts by version and digest.
- Roll out by signed app build, region, cohort, model, hardware revision, and
  firmware compatibility.
- A local compatibility block must work without network access.
- A signed server configuration may halt new activations or updates, but
  already activated local collection must not depend on that server to remain
  usable.
- Disabling the supplier adapter stops new sessions safely, flushes committed
  data, preserves registry/history, and does not relabel or delete rows.
- Reverting the app must retain readable schema and source provenance or use an
  explicit rollback-capable migration.

### 16.2 Data rollback

- Every parser, unit, calibration, and formula revision is explicit.
- Suspect supplier rows are quarantined or excluded by revision/range; they
  are not silently rewritten as valid.
- Reprocessing is deterministic, bounded, and reversible from retained
  normalized/source data.
- Rollback never advances a band cursor or deletes unacknowledged history.
- WHOOP data and supplier-band data keep distinct source identities.

### 16.3 Ownership rollback

- A failed provisional setup expires without creating ownership.
- A failed claim is retryable and cannot create two owners.
- App rollback does not release a claimed band.
- Operator-only release requires credential revocation, verified wipe, unlink,
  and quarantine.
- NOOP+ cancellation or cloud rollback does not release or deactivate the
  band.

### 16.4 Firmware rollback

- Firmware rollback is available only when the bootloader, image-signing, data
  compatibility, and rescue contracts are physically validated.
- The app never invents a rollback action when firmware reports none.
- A failed update leaves the band in a known running, fallback, rescue, or
  quarantine state and records a bounded terminal outcome.

## 17. Ordered implementation plan

### 17.1 Supplier-independent software work

These steps can be completed and verified without claiming access to the
production band, supplier binary behavior, or firmware capability:

1. Complete the binary-free neutral contract, synthetic fixtures, virtual
   band, and conformance scenarios in the private `NoopBandSDK` repository.
2. Define Apple and Android adapter composition points without exposing
   supplier types in public NOOP APIs or linking a supplier binary into
   simulator, macOS, Watch, widget, or pure-package targets.
3. Add virtual-transport stale-callback guards, serialized operation queues,
   timeouts, cancellation, fixed failure mapping, and redaction tests.
4. Register the neutral supplier source behind a default-off internal
   capability while preserving WHOOP as a distinct test transport.
5. Add neutral sample normalization and durable storage adapters with matched
   cross-platform golden fixtures.
6. Add a virtual supplier-history coordinator with durable-before-ack,
   interruption, duplicate, empty-completion, and cursor-resume tests.
7. Define versioned capability and compatibility models that fail closed for
   unknown required revisions.
8. Keep the existing ownership flow wired to the unavailable possession
   provider and test replay, race, wrong-band, expiry, and failure states with
   synthetic proofs only.
9. Add bounded supplier-lifecycle observability and redaction tests without
   identifiers, payloads, health values, or arbitrary errors.
10. Route only committed normalized records into the separately consented
    managed outbox and keep every D-059 authority switch disabled.
11. Compile all unaffected Apple and Android targets and run virtual
    conformance while leaving every physical claim open.

### 17.2 Supplier SDK and firmware integration

These steps require the exact supplier inputs and cannot be represented as
complete by neutral contracts or virtual-band tests:

1. Freeze the exact supplier input hashes, model/project code, rights status,
   dependency inventory, supported firmware matrix, and named firmware owner.
2. Approve and pin the Apple and Android wrapper artifacts and their
   transitive dependencies without committing supplier binaries here.
3. Implement the native Apple and Android supplier adapters against the exact
   reviewed SDK revision.
4. Confirm the real capability report, identity mapping, units, clock,
   quality, history cursor, and acknowledgment contracts.
5. Implement Apple and Android possession providers only after firmware
   supplies approved challenge-bound, debounced physical proof.
6. Add battery, wear, haptic, alarm, and sampling controls one accepted
   capability at a time.
7. Implement firmware update last, after bootloader, signing, anti-rollback,
   recovery, and rescue contracts are approved.

### 17.3 Physical evidence and staged release

1. Build signed device targets with the pinned artifacts.
2. Execute this document's section 15 together with the complete
   [band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md).
3. Run independent mobile, BLE, firmware, privacy, and security review and
   correct every launch-severity finding.
4. Stage activation and firmware rollout with halt, rollback, rescue, and
   support drills.
5. Remove the default-off gate only for exact accepted
   hardware/firmware/app combinations.

## 18. Definition of ready for hardware review

The software may enter hardware review when all of the following are true:

- supplier artifact identity and legal status are recorded without committing
  the binaries;
- neutral Swift and Kotlin contracts are versioned and semantically matched;
- virtual-band success, timeout, corruption, duplicate, reconnect, cursor,
  low-battery, and firmware-failure scenarios pass;
- supplier adapters compile in signed device targets behind a default-off
  gate;
- simulator/JVM tests use fakes and do not require the device-only binary;
- one active source and WHOOP regression tests pass, with WHOOP still
  available as a distinct controlled comparison transport;
- sample normalization and history durability tests pass with the same golden
  fixtures on both platforms;
- ownership still fails closed when no physical proof is available;
- diagnostics redaction and bounds tests pass;
- managed upload remains separate and disabled without consent/configuration;
- unsupported vendor health claims are absent; and
- this document and the companion
  [band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
  name every still-unproven behavior.

Hardware review then proves the behavior. It does not merely confirm that the
app built or displayed a connected state.

## 19. Final handoff boundary

Source work can deliver the wrapper contracts, adapters, fixtures, storage
ordering, ownership wiring, diagnostics, default-off controls, and build/test
evidence.

The following cannot be completed from source or simulators alone:

- exact supplier model and firmware capability truth;
- printed-label identity mapping;
- authenticated tap-based possession;
- sensor and metric accuracy;
- autonomous/off-wrist collection and battery life;
- real history retention, overflow, and acknowledgment;
- background/reconnect behavior on physical iOS and Android devices;
- haptic, alarm, wear, charging, and low-battery behavior;
- signed firmware update, rollback, and rescue;
- binary redistribution, privacy, security, signing, certification, legal,
  store, carrier, manufacturing, support, and production operations approval.

Until those gates pass, NOOP must describe the supplier SDK as a candidate
transport and retain the existing WHOOP path for controlled comparison. The
authoritative execution checklist for those gates is the companion
[band physical validation handoff](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md).
