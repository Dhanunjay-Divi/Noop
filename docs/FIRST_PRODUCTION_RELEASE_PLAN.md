# NOOP first production release master plan

- **Plan date:** 2026-09-05
- **Last evidence update:** 2026-09-07
- **Target:** first public production release of the NOOP mobile apps and the
  first-party NOOP Band
- **Launch sequence:** India first, then the USA
- **Public beta:** none
- **Required validation:** private release-candidate testing before storefront
  submission
- **Editable ordered checklist:**
  [`FIRST_PRODUCTION_RELEASE_CHECKLIST.md`](FIRST_PRODUCTION_RELEASE_CHECKLIST.md)

This is the execution plan for reaching an actual public release. It is not a
claim that the release is ready today. Code, simulator, staging, physical
hardware, certification, signing, store, and production-operation evidence are
separate gates.

Use the checklist for day-to-day additions and completion. Keep this document
for architecture, dependencies, rationale, and release boundaries.

## 1. Release definition

The first release is complete only when:

1. A production NOOP Band runs signed, rollback-capable firmware and preserves
   data while the phone is unavailable.
2. Signed iOS and Android applications pair, authenticate, collect, backfill,
   update, diagnose, export, and recover against representative production
   bands.
3. Existing NOOP user data survives an in-place upgrade. No rename, migration,
   retention policy, account flow, or device change may silently erase it.
4. Every displayed sensor value and derived metric has the evidence required
   for its exact claim. Missing or unvalidated input remains unavailable.
5. Apple and Android provide the same product contract except for documented
   platform capabilities such as HealthKit, Health Connect, and Watch.
6. Every enabled network feature has production identity, privacy, security,
   capacity, recovery, monitoring, support, and deletion evidence.
7. Mainline, signed artifacts, physical-device matrices, legal gates, store
   records, and launch operations are green at the same release commit.

Private TestFlight, Play internal testing, and controlled engineering hardware
are release-candidate validation, not a customer-facing beta. Store release
remains manual until the final go/no-go review.

## 2. Product invariants

- App exploration, imports, local metrics, user-authored records, and exports
  remain account-free. A first-party NOOP Band requires a one-time ownership
  account and network claim, but an activated band keeps collecting, scoring,
  exporting, and accepting supported local controls without NOOP+,
  subscription, or continuous network access.
- Core scoring stays on device. Cloud availability cannot decide whether a
  user can see local metrics.
- Band ownership and NOOP+ entitlement are separate. Payment failure,
  cancellation, or downgrade cannot deactivate a claimed band or remove core
  local capability.
- NOOP+ is explicit opt-in managed storage and network functionality. It never
  silently uploads an existing local history.
- A production band must collect to local flash while the app is suspended or
  terminated, then resume an idempotent history drain. Keeping the app alive is
  not a data-integrity strategy.
- Off-wrist power saving is primarily a firmware responsibility. The app may
  request a mode, but firmware owns wear detection, sampling reduction, safe
  wake-up, buffering, and battery protection when the phone is absent.
- A build or simulator cannot prove BLE, background collection, battery,
  haptics, sensor quality, firmware update, or physiological accuracy.
- Automatic medical, anomaly, Rhythm, SpO2, temperature, stress, or fall
  paging remains unavailable without its separate validated and regulatory
  program.
- The first release targets explicit, user-confirmed app SOS paging to accepted
  trusted contacts. The app initiates the incident; the server performs
  acknowledged SMS/voice delivery. Responder links expose only the latest
  location during the selected 8- or 12-hour incident window and no route
  history.
- Mobile diagnostics remain bounded, local, and user-reviewed. Backend events
  remain payload-free. Neither may contain health values, user text,
  credentials, dynamic identifiers, raw frames, or arbitrary errors.

## 3. Current baseline

### Reusable foundations

- Cross-platform CRC, framing, reassembly, history acknowledgment, clock
  correlation, storage, analytics, backup, export, and diagnostic patterns
  already exist.
- Apple and Android already have pluggable live-source abstractions and
  additive database migrations.
- NOOP+ phone identity, explicit consent, immutable chunk sync, restore,
  erasure, seven-day raw plus 30-day essential hot retention, Friends, and
  private synthetic staging exist.
- Local app reports already cover bounded lifecycle, responsiveness, storage,
  navigation, database, analysis, device connection, history, and managed sync
  evidence.
- A default-off supplier-independent ownership foundation now provides an
  isolated account/control schema and service, verified email/password
  mechanics with optional phone linking, immutable remote-terms verification,
  secure installation credentials, atomic single-owner claim and
  replacement-installation primitives, resumable Apple/Android onboarding,
  and a NOOP/NOOP+ preference without enabling payment or upload.

### Missing or unproven foundations

- There is no first-party NOOP firmware, GATT contract, packet schema, device
  identity, provisioning flow, secure boot, DFU contract, manufacturing test
  interface, or NOOP Band SDK in this repository.
- There is no supplier-backed printed-label discovery, identify haptic,
  cryptographically authenticated tap confirmation, owner-key provisioning,
  approved operator release/return workflow, production ownership deployment,
  or physical-band evidence. The production possession provider therefore
  remains deliberately unavailable.
- The current `Noop Band` presentation can label a legacy third-party source
  with the persisted ID `my-whoop`. This false identity must not reach the
  first-party hardware release.
- Production signed physical-device collection, background execution, history,
  battery, haptics, storage pressure, firmware update, and upgrade preservation
  remain unverified.
- NOOP+ is private synthetic staging. Public mobile ingress, physical
  attestation, carrier delivery, production links and push, production
  monitoring, load, restore, and support operations remain open.
- App Store and Play signing, final store records, current release media,
  reviewer sample mode, and public-release approval remain open.
- External sensor and metric accuracy evidence remains incomplete.

### Current mainline health

At commit `1443acb1` on 2026-09-06:

- The exact-main Apple matrix passes the universal macOS app build and tests,
  the complete iOS simulator build, launch-gate isolation, and the iOS
  production-shell tests.
- Android build, unit, lint, instrumentation compilation, and the API 35
  managed-emulator production-shell matrix pass with retained diagnostics.
- Server legal lock, lint, dependency audits, extension-free PostgreSQL
  overlay, complete database/API suite, Compose validation, production and
  backup container builds, encrypted backup, and disposable restore pass.
- Swift packages and the study harness, localization, health claims, runtime
  license inventory, private-data rejection, and operations-record workflows
  pass.
- Phase-R1 source/workflow defects are closed without waivers. `main` remains
  unprotected and reviewed environments, production credentials, signed
  artifacts, and external launch evidence remain open.
- Exact-main commit `b5caec52` passes the new `Release Controls` workflow.
  Its retained evidence artifact contains a deterministic 216-component
  CycloneDX SBOM and a commit/tree-bound manifest that was independently
  reverified after download. Branch protection, reviewed environments,
  credential rotation, signing, and production release approval remain open.
- Source versions are iOS `9.2.1 (231)` and Android `9.2.1 (304)`. The owner
  must choose and validate the first storefront version. `1.0.0` is the
  recommended public product version, but existing installed-build upgrade
  behavior and store build-number availability decide the final values.

### Terminology footprint

The tracked repository currently contains 15,451 matching lines across 1,313
files for `WHOOP`, `Whoop`, `whoop`, `OpenWhoop`, or `my-whoop`. The largest
areas are Android, Swift packages, Apple application source, tests, and
documentation. The footprint includes:

- active third-party protocol and transport implementation;
- general storage and analytics types named after that transport;
- persisted source IDs, database names, paths, Room schema identities, backup
  contracts, and cloud namespace inputs;
- import/export provenance and comparison tooling;
- customer localization keys and Android resources;
- legal attribution, historical release records, fixtures, and tests.

A bulk replacement would corrupt compatibility and provenance. The release
target is zero unapproved terminology in customer and core product surfaces,
not dishonest deletion of legal, historical, migration, or import facts.

## 4. Required owner decisions

Some directions are now owner-confirmed; unresolved rows remain phase-zero
blockers:

| Decision | Current direction | Why it blocks work |
|---|---|---|
| First launch markets | **Confirmed:** India first, then USA | Certification, privacy, carrier, tax, store, locale, and support requirements differ. |
| First-party band activation | **Confirmed:** one ownership account and network claim; ongoing local operation remains subscription-independent | Single-account enforcement needs a durable authority without moving scoring or health history behind cloud availability. |
| Pairing confirmation | **Confirmed intent:** match the printed band number, identify by vibration, then confirm from the worn band with at least three taps; exact firmware event and proof remain supplier-dependent | A printed number or unauthenticated motion event is not secure possession proof. |
| v1 transfer | **Confirmed:** no user-facing unpair or transfer; ordinary ownership remains bound for the band's life and consumer release appears only with an eligible successor-band upgrade. Operator-only return, RMA, recovery, deletion, dispute, legal, and security exits remain required. | Internal exits must protect customer rights and returned hardware without creating a resale feature. |
| Return window | **Pending:** choose 14 or 30 calendar days and its start event | Store copy, fulfillment, inspection, refund, support, and accounting must use one enforceable rule. |
| Return condition | **Pending:** approve objective grades and lawful refund deductions for marked or damaged units | An arbitrary post-return charge creates consumer, payment, and support risk. |
| Terms delivery | **Confirmed:** canonical terms load from NOOP-controlled remote storage and the full document is not persisted in the app | Claim must bind to one immutable verified version while remaining auditable and publicly accessible. |
| Pre-home plan choice | **Confirmed:** show NOOP and an accessible gold NOOP+ option before Home | Both platforms need one honest, non-coercive product boundary. |
| Payment | **Pending:** show no working checkout until India gateway, store billing, tax, refund, and receipt behavior are approved | A placeholder cannot charge, grant entitlement, or imply production billing. |
| First release network scope | Band ownership claim and manual app SOS trusted-contact paging are targeted; enable NOOP+ data services only after every production gate passes | Ownership identity must not silently become managed health-data consent, and provider credentials cannot live in a mobile client. |
| Legacy direct-band support | Keep during bring-up; remove from the public first-party release after NOOP Band physical parity, while preserving old data and import provenance | Removing it earlier destroys the only hardware development path; retaining it as `Noop Band` is false. |
| Public version | Validate `1.0.0` with monotonic platform build numbers | Current source version is an internal development sequence, not necessarily the correct first storefront identity. |
| Launch languages | English plus professionally reviewed launch-market locales | Machine completeness does not establish native-speaker quality. |
| Safety paging at launch | **Confirmed target:** manual, user-confirmed app SOS with latest-only location; provider delivery remains unavailable until carrier, operations, legal, and physical evidence all pass | App initiation does not remove the need for reliable server delivery, acknowledgement, and an honest failure path. |
| Medical posture | General wellness only | Clinical claims trigger separate evidence, quality-system, and regulatory work. |

## 5. First-party NOOP Band input dossier

The hardware and firmware owners must provide this versioned dossier before the
host protocol is implemented. Engineering must not infer production behavior
from a sample device or another vendor's protocol.

| Required input | Minimum artifact |
|---|---|
| Hardware identity | MCU/chipset, BLE controller and stack, board revisions, radio/module identity, memory map, flash capacity, secure-element use, battery and charger design |
| Physical label and claim mapping | Public printed identifier format and uniqueness; mapping to the opaque provisioned identity and hardware revision; manufacturing, replacement, and privacy rules |
| Sensor bill of materials | Exact PPG/SpO2, accelerometer/gyro, temperature, contact, battery, and optional sensor parts with datasheets |
| Sampling contract | Supported rates, resolutions, ranges, units, channels, LED currents, timestamps, batching, quality flags, calibration coefficients, and expected power per mode |
| GATT contract | Assigned service and characteristic UUIDs, properties, permissions, MTU assumptions, notification ordering, connection parameters, and bonding requirements |
| Wire schema | Envelope, version, length, type, sequence, flags, device time, payload, checksum or authentication tag, fragmentation, and maximum sizes |
| Security | Device identity, per-unit key provisioning, phone authentication, replay protection, key rotation/revocation, debug-lock policy, secure boot, image signing, and threat model |
| Pairing and possession | Pairing-mode entry/expiry/cancel, discovery eligibility, identify haptic, firmware-debounced at-least-three-tap confirmation event, challenge binding, timeout, retry, and simultaneous-phone behavior |
| History | Flash layout, capacity by sampling mode, immutable chunk identity, cursors, read windows, checksums, acknowledgment rules, retry behavior, overflow policy, and factory reset |
| Clock | Device epoch or monotonic ticks, oscillator tolerance, UTC anchors, drift correction, reboot/reset behavior, timezone independence, and invalid-clock state |
| Commands | Capability discovery, sampling modes, live stream, history, battery, wear state, haptics, alarms, safe reset, diagnostics, and command idempotency |
| Power | On-wrist and off-wrist states, charger behavior, low-battery thresholds, wake sources, thermal limits, brownout recovery, and target battery life |
| OTA/DFU | Transport, signed manifest, version policy, A/B or recovery partition, anti-rollback policy, resume, rollback, recovery mode, and power-loss behavior |
| Manufacturing | Factory test protocol, calibration stations, serial/device identity injection, key custody, yield data, end-of-line records, and RMA diagnostics |
| Regulatory | Product/radio/battery identifiers and planned BIS, WPC/ETA, FCC, Bluetooth SIG, UN38.3, IEC 62133, RoHS/REACH, and market-specific evidence |
| Samples and access | Representative engineering units for both platforms, firmware builds and symbols, debug interface policy, current limits, reference instruments, and named firmware owner |

Store secrets, fleet keys, signing keys, personal data, and production
credentials in approved key or secret systems, never in Git, tickets,
diagnostic reports, or chat.

## 6. NOOP Band SDK architecture

The SDK is a versioned product boundary, not BLE calls embedded in screens.
Exact UUIDs and byte layouts remain pending the input dossier.

### 6.1 Repository boundaries

Create the following neutral structure:

```text
band/
  spec/                 Canonical versioned protocol and capability schema
  fixtures/             Synthetic golden frames and failure vectors
  simulator/            Deterministic virtual band and fault injection
  conformance/          Host and firmware compliance scenarios
firmware/
  app/                  Production band application
  bootloader/           Secure boot and recovery/DFU
  boards/               Board-revision configuration
  manufacturing/        End-of-line test protocol and tools
Packages/
  NoopBandProtocol/     Pure Swift values, framing, state machines
  NoopStore/            Device-neutral persistence API
android/app/src/main/java/com/noop/band/
  protocol/             Pure Kotlin protocol implementation
  transport/            Android BLE lifecycle
Tools/noop-band-cli/    Development, fixture, and conformance tool
```

Firmware may live in a separate access-controlled repository if the
manufacturer, export, signing-key, or build-system boundary requires it. If so,
`band/spec`, synthetic fixtures, conformance tests, release manifests, and the
mobile SDK interfaces remain versioned here without private keys or restricted
vendor material.

### 6.2 Canonical layers

1. **Sensor model:** device-neutral measured samples, units, quality, device
   ticks, sequence, calibration revision, and provenance. It contains no UI,
   database, Bluetooth, or score logic.
2. **Wire protocol:** framing, integrity/authentication, capability negotiation,
   commands, events, live stream, history, clock, haptics, and DFU messages.
3. **Session state machine:** discovery, encrypted link, device
   authentication, capability read, clock correlation, subscription, live
   collection, history drain, command execution, firmware update, disconnect,
   and recovery.
4. **Platform transport:** CoreBluetooth and Android BLE adapters. Platform
   callbacks enter one serialized state machine; screens never own a GATT
   object.
5. **Storage adapter:** converts accepted SDK samples into the neutral store.
   History is acknowledged only after one durable, idempotent transaction.
6. **Product adapter:** exposes connection, freshness, sync progress, battery,
   wear, firmware, and supported capabilities to the app.
7. **Test kit:** virtual clock, virtual band, malformed frames, disconnects,
   packet loss, duplicates, stale callbacks, full flash, bad clock, low
   battery, failed OTA, rollback, and incompatible-version scenarios.

### 6.3 Protocol requirements

- Version every envelope and capability. Unknown optional fields are ignored;
  unknown required capability versions fail closed.
- Use one stable per-record or per-chunk identity so retries do not duplicate
  data.
- Use device monotonic time plus explicit wall-clock anchors. Never bake a
  phone timezone into band storage.
- Separate live notifications from durable history. Live receipt does not
  advance a history cursor.
- Acknowledge only a verified, durably committed range. Reconnect resumes from
  the last acknowledged range.
- Expose flash used, flash capacity, oldest/newest range, overflow, and
  completion so the app can distinguish an empty history from a failed drain.
- Use per-device identity and keys. Do not use one shared fleet credential.
- Treat the printed identifier as a locator, not a secret. A claim requires a
  fresh app challenge and authenticated response from the selected physical
  band.
- Firmware, not the phone, converts at least three deliberate taps within the
  possession window into one debounced confirmation event. Extra motion must
  not create multiple confirmations.
- Bind pairing mode, identify haptic, possession confirmation, provisioning,
  and ownership claim to one expiring session and reject replay, stale
  responses, wrong-band responses, and concurrent claim races.
- Authenticate state-changing commands and reject replay, downgrade, stale
  sequence, wrong-device, and wrong-firmware messages.
- Haptic, alarm, sampling, reset, and DFU commands are bounded, idempotent, and
  explicitly acknowledged.
- Production firmware accepts only signed images, survives power loss, and has
  a tested rollback or rescue path.
- Capability negotiation decides which metrics exist. App model names or a
  matching UUID never imply sensor support.

### 6.4 SDK public contract

Both native implementations must expose equivalent concepts:

- `BandPairingCandidate`: privacy-safe printed-label match, compatibility,
  pairing eligibility, and identify state without exposing a Bluetooth address;
- `BandPossessionChallenge`: an expiring challenge and fixed result categories
  without exposing challenge bytes to diagnostics;
- `BandIdentity`: opaque local handle, hardware revision, firmware version,
  protocol version, and capability set;
- `BandSessionState`: fixed lifecycle states and fixed failure categories;
- `BandFreshness`: last live progress, last durable history progress, and
  completion state without exposing health values to diagnostics;
- `BandHistoryProgress`: bounded counts/ranges and acknowledged cursor;
- `BandCommand`: capability read, clock, sampling mode, haptic, alarm, and
  firmware-update operations;
- `BandSampleBatch`: typed measured rows with unit, quality, device time,
  sequence, and calibration revision;
- `BandFirmwareUpdate`: eligibility, signed manifest, progress, interruption,
  verification, activation, and rollback result.

Do not make raw Bluetooth addresses, serial numbers, keys, health payloads, or
arbitrary platform errors part of the diagnostic-facing API.

### 6.5 Observability requirements

Apple and Android must record bounded, fixed-category evidence for:

- discovery start/end and no-result timeout;
- candidate selected, identify haptic accepted/rejected, possession window,
  confirmation accepted/rejected/timed out, and concurrent-claim conflict;
- connection, encryption, authentication, capability negotiation, and
  subscription;
- live stream start, durable-progress stall, notification repair, reconnect,
  and disconnect category;
- history request, verified chunk count, durable commit count, acknowledgment,
  completion-empty, completion-with-data, interruption, retry, and stall;
- clock anchor accepted, drift bucket, invalid clock, and correction result;
- command accepted/rejected/timed out by command category;
- firmware update eligibility, download availability, transfer, verification,
  activation, rollback, and terminal outcome;
- database operation duration/outcome, storage pressure bucket, memory
  pressure, and app responsiveness summaries.

Evidence is aggregate and throttled. It excludes identifiers, raw frames,
sensor timestamps/values, health rows, firmware payloads, credentials, and
arbitrary errors.

### 6.6 SDK readiness gates

- Swift and Kotlin decode the same synthetic golden corpus byte-for-byte.
- Firmware and both clients pass the same conformance scenarios.
- Parsers pass truncation, corruption, bounds, replay, duplicate, ordering, and
  fuzz/property tests.
- A deterministic simulator proves every lifecycle and error transition.
- Hardware-in-loop proves reconnect, backlog, clock drift, power loss, full
  flash, haptics, and OTA recovery.
- Public SDK symbols and protocol versions are documented and compatibility
  tested.
- No band capability is marked production-supported until its physical matrix
  passes.

### 6.7 Ownership and onboarding contract

The first-party release target uses this sequence on Apple and Android:

1. Show the existing initial education needed before hardware setup.
2. Ask the user to wear the band and place it in an explicitly time-bounded
   pairing mode.
3. Scan only eligible NOOP Bands and show the minimum characters needed to
   match the number printed on the selected physical band.
4. Send an identify vibration to that exact candidate.
5. Ask for at least three deliberate taps. Firmware emits one authenticated,
   debounced confirmation bound to the app challenge; the app does not infer
   raw taps from motion.
6. Fetch the exact versioned Terms and Conditions from NOOP-controlled object
   storage, render it without persistent local document storage, explain that
   a successful claim binds the band to one account, list the supported
   recovery and release paths, and require a versioned explicit `I agree`.
7. Create or sign in to a managed account using verified email and password.
   Mobile number is optional and receives an OTP only when provided. NOOP never
   stores plaintext passwords or OTPs.
8. Atomically claim the band using app attestation plus fresh physical-band
   proof, then provision owner-scoped credentials. A partial failure remains
   resumable and cannot create two owners.
9. Continue the remaining profile, permission, goal, notification, and product
   education pages from an idempotent checkpoint.
10. Before Home, offer NOOP and NOOP+. NOOP continues without payment. NOOP+
    uses an accessible gold identity, but payment remains clearly unavailable
    until billing is production-ready.
11. A replacement phone signs in to the same account, proves physical
    possession again, and authorizes a new installation without changing
    ownership.
12. V1 exposes no user-facing unpair or transfer. The band remains bound to the
    account for its ordinary lifetime. Operator-only return, RMA, recovery,
    deletion, verified dispute, legal, and security release paths must exist.
    Only after an eligible successor band is released can the product expose a
    reauthenticated upgrade release, after owner keys and personal band state
    are removed.

Discovery, identify vibration, and physical confirmation form a provisional
session, not a completed ownership bond. The product must not say the band is
paired, persist owner credentials, or permit ordinary collection/control until
the account claim commits. If the supplier stack requires an earlier platform
bond, it must use a bounded provisional credential that expires and cannot
establish ownership by itself.

The ownership account is not NOOP+ consent. Claim records contain identity and
control state, not health samples. Enrolling in NOOP+ requires its own plan,
health-data disclosure, consent, entitlement, retention, export, and erasure
flow. Cancelling NOOP+ never releases or deactivates the band.

### 6.8 Remote terms and returns

Terms and Conditions are canonical remote documents, not bundled app assets:

- each version is immutable, content-addressed, locale-specific, and referenced
  by a signed manifest with policy version, effective date, and digest;
- the app uses an ephemeral no-persistent-cache fetch and sanitized static
  renderer, and does not write the full document to its container, database,
  preferences, diagnostics, or report archive;
- claim fails closed if the selected version is unavailable, altered, expired,
  or does not match the manifest;
- the server retains account-scoped acceptance evidence for document
  version/hash, locale, policy version, and server time, while diagnostics
  retain no account, contact, band, document-content, or challenge data;
- every accepted historical version remains available at an immutable public
  URL, and reacceptance follows an approved version/effective-date policy;
- remote content contains no arbitrary script, third-party tracker,
  advertising, fingerprinting, or credential capture.

The voluntary return window is not yet selected. The owner must choose 14 or
30 calendar days and define whether it starts at order, shipment, delivery,
activation, or another approved event. Before sale, the public policy must
define unopened, opened, paired, worn, defective, transit-damaged, warranty,
and change-of-mind eligibility.

Any condition deduction must use a published objective inspection and refund
schedule. Marks, structural damage, missing accessories, hygiene, battery,
radio, sensor, and tamper state require repeatable privacy-safe evidence.
Ordinary inspection, manufacturing defect, transit damage, customer damage,
and normal wear must remain distinct. Where lawful, a disclosed amount may be
deducted from the refund through the original payment rail with an itemized
decision and appeal path; NOOP must not create an undisclosed later charge.

An accepted return or RMA invokes an operator-only release. It revokes owner
credentials, wipes personal band state, removes the account link, and places
the unit into quarantine for approved refurbishment, reprovisioning, or
destruction. This internal path is not a user-facing v1 unpair or resale
feature.

## 7. Safe terminology and data migration

### 7.1 End state

The first-party release must have:

- NOOP-native customer text, app routes, source labels, product models, package
  boundaries, diagnostics categories, active docs, and band SDK;
- no false mapping of a legacy source to `Noop Band`;
- neutral core types such as `NoopStore`, `BandDevice`, `BandProtocol`,
  `BandRepository`, and `BandConnectionService`;
- truthful old-source provenance for imported or existing records;
- additive upgrade compatibility for old local databases, backups, exports,
  managed snapshots, widgets, Watch data, and source arbitration;
- an automated zero-unallowlisted-match gate.

### 7.2 Allowed exceptions

The legacy name may remain only in a reviewed machine-readable allowlist for:

1. required legal notices and non-affiliation language;
2. truthful import/export provenance and explicit external format names;
3. immutable migrations, old schema fixtures, old source IDs, and compatibility
   aliases needed to read existing data;
4. an intentionally retained, isolated legacy hardware adapter while it is
   supported;
5. historical operations records, changelog entries, and archived research
   evidence.

Every allowlist entry needs path, category, reason, owner, and removal condition.
New matches fail CI. Historical records are not rewritten to pretend the work
never occurred.

### 7.3 Migration order

1. **Inventory and classify:** generate a tracked manifest of customer,
   active-core, persisted, import/provenance, compatibility, legal, fixture,
   generated, and historical matches.
2. **Correct identity first:** stop calling the current seeded legacy row a
   first-party band. Existing records display as a compatible or legacy source
   until an actual NOOP Band is paired.
3. **Add neutral core modules:** introduce neutral stream, store, repository,
   and source abstractions while the current adapter still compiles.
4. **Add the NOOP-native identity:** first-party bands get a new opaque local
   source ID and explicit protocol family. Never reuse `my-whoop`.
5. **Dual-read old data:** neutral repositories read old and new source keys,
   old database locations, old backups, old managed namespaces, and old widget
   payloads.
6. **Write only new identities for new hardware:** no new first-party row,
   export, backup, or cloud object uses a legacy key.
7. **Migrate paths safely:** move Apple
   `Application Support/OpenWhoop/whoop.sqlite` to a neutral NOOP path and
   Android `noop_whoop.db` to a neutral name only through cold-open,
   checksum/integrity-verified, rollback-capable migration. Include SQLite
   sidecars and never replace a non-empty destination.
8. **Version portable contracts:** bump backup/export manifests, retain old
   readers, preserve source provenance, and prove old-to-new restore.
9. **Rename active code:** migrate package, type, file, class, resource, test,
   generated-schema, and build references in bounded layers. Temporary
   forwarding aliases stay internal and deprecated.
10. **Isolate or remove direct compatibility:** after NOOP Band physical parity,
    either keep the legacy adapter in an explicitly named compatibility module
    with its own evidence or remove it from public builds. Do not leave its
    protocol as the core product architecture.
11. **Close the gate:** customer and active-core categories reach zero;
    exceptions match the reviewed allowlist exactly; backup, upgrade,
    provenance, legal, and full cross-platform gates pass.

### 7.4 Required migration fixtures

- oldest supported Apple database and current Apple database;
- every exported Android Room schema still supported;
- current and old `.noopbak` archives;
- portable and managed-history exports;
- widgets, Live Activity, Watch, and app-group payloads;
- local and managed source IDs, namespace identifiers, and restore snapshots;
- imports that truthfully name an external source;
- interrupted database move, low storage, corrupt candidate, process death,
  rollback, and retry.

No destructive fallback, empty-store replacement, silent source relabel, or
one-way schema rewrite is acceptable.

## 8. Ordered execution plan

Statuses:

- `DONE`: evidence already exists for the stated scope.
- `PARTIAL`: implementation exists, but release evidence is incomplete.
- `OPEN`: code or documentation work remains.
- `EXTERNAL`: requires hardware, accounts, labs, contracts, people, or legal
  action.

### Phase 0 - scope, ownership, and safety boundary

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| R0.1 | PARTIAL | India-first, USA-second, and manual app SOS trusted-contact paging are recorded; territories, languages, pricing, and NOOP+ enablement remain open. | Signed product scope in the release record |
| R0.2 | OPEN | Name accountable owners for firmware, hardware, mobile, backend, security, privacy, metric validation, manufacturing, support, and release. | Owner/RACI table with backups |
| R0.3 | OPEN | Decide the legacy direct-band compatibility end state. | Written migration and support policy |
| R0.4 | OPEN | Select public marketing version and monotonic Apple/Android build numbers. | Upgrade-tested version map |
| R0.5 | PARTIAL | Freeze general-wellness and automatic-emergency boundaries. | Claims matrix approved for app, packaging, and stores |
| R0.6 | PARTIAL | Preserve the confirmed ownership-account, physical-confirmation, and pre-home plan flow while completing privacy, legal, support, and payment decisions. | Approved customer and operations contract |
| R0.7 | OPEN | Approve the v1 no-self-service-transfer policy and every required return, RMA, recovery, deletion, dispute, and future-upgrade exit. | India/USA legal and support sign-off |

**Exit:** no unresolved product decision changes the architecture, data
contract, certification plan, or store disclosure.

### Phase 1 - restore a green and controlled mainline

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| R1.1 | DONE | The iOS production-shell defect is fixed without suppressing the test. | Exact-main Apple run `34080116658` |
| R1.2 | DONE | Android production-shell instrumentation is deterministic in hosted CI and retains managed-device diagnostics. | Exact-main Android run `34079190997` |
| R1.3 | DONE | PostgreSQL fixtures are isolated; the plain lane starts from `template0` and rejects inherited extensions. | Exact-main server run `34078811154` |
| R1.4 | PARTIAL | Apple, Android, Swift, server, localization, claims, legal, dependency, privacy, and operations gates pass on current main; protected-main required-check policy remains open. | Protected main or equivalent reviewed release control |
| R1.5 | OPEN | Create staging and production environments with least-privilege secrets and approvals. Rotate any credential previously pasted into chat or logs. | Secret inventory and rotation evidence |
| R1.6 | OPEN | Establish clean build reproducibility, dependency lock review, SBOM, artifact provenance, and vulnerability policy. | Signed/checksummed artifacts tied to commit |
| R1.7 | OPEN | Measure cold launch, scrolling, database work, sync, memory, storage, and battery on representative release devices. | Versioned performance budgets and baselines |

**Exit:** `main` is green, protected by the agreed release controls, and every
artifact can be traced to one reviewed commit.

### Phase 2 - hardware and firmware foundation

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| B2.1 | EXTERNAL | Obtain and approve the complete input dossier in section 5. | Versioned hardware/firmware contract |
| B2.2 | OPEN | Create firmware/spec/conformance boundaries or the linked private firmware repository. | Reproducible firmware build and ownership record |
| B2.3 | OPEN | Implement secure boot, per-unit identity, authenticated provisioning, debug lock, signed OTA, rollback/recovery, and anti-downgrade policy. | Security tests and key-ceremony record |
| B2.4 | OPEN | Implement calibrated sensor scheduling, wear detection, off-wrist power mode, battery/thermal safety, and local flash buffering. | Bench power, thermal, wear, and retention results |
| B2.5 | OPEN | Implement history, clock, haptics, alarms, capability negotiation, and manufacturing diagnostics. | Firmware conformance and hardware-in-loop results |
| B2.6 | EXTERNAL | Build factory fixtures, calibration, identity injection, key custody, yield, traceability, and RMA diagnostics. | Pilot-run manufacturing records |
| B2.7 | EXTERNAL | Complete battery, radio, Bluetooth, safety, and market certifications. | Certificates tied to production design |
| B2.8 | OPEN | Implement pairing-mode expiry, identify vibration, authenticated at-least-three-tap possession confirmation, and owner-key provisioning. | Firmware/phone claim conformance and physical matrix |

**Exit:** a production-representative band can collect without a phone, survive
power loss, authenticate, offload exactly once, update safely, and be produced
with traceable calibration and identity.

### Phase 3 - first-party SDK and simulator

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| S3.1 | OPEN | Check in the versioned canonical protocol and capability schema after dossier approval. | Reviewed spec with change policy |
| S3.2 | OPEN | Build pure Swift and Kotlin models, framing, parser, clock, history, command, and update state machines. | Shared golden and negative corpus green |
| S3.3 | OPEN | Build CoreBluetooth and Android BLE transports around one serialized session state machine. | Lifecycle tests and platform builds |
| S3.4 | OPEN | Build deterministic virtual band, fault injection, CLI, and packet/manifest inspector. | CI scenarios for every state and failure |
| S3.5 | OPEN | Bind accepted batches to additive neutral storage and durable acknowledgment. | Crash/retry/idempotency database tests |
| S3.6 | OPEN | Add bounded cross-platform diagnostics and report coverage. | Redaction, bounding, stall, and failure tests |
| S3.7 | OPEN | Publish internal SDK integration docs, API compatibility policy, and examples. | A new client can integrate without transport internals |
| S3.8 | OPEN | Run firmware/Swift/Kotlin conformance in CI and hardware-in-loop. | Version-pair compatibility matrix |
| S3.9 | OPEN | Model printed-label matching, identify, possession challenge, confirmation, and claim-proof results without exposing identifiers. | Shared fixtures, redaction tests, and supplier conformance |

**Exit:** mobile integration uses the SDK, not duplicated screen-level GATT
logic, and both clients agree with firmware on every supported protocol version.

### Phase 3A - ownership account, claim, and onboarding

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| A3A.1 | OPEN | Implement managed email/password identity, verified email, optional phone OTP, recovery, reauthentication, session rotation, and abuse controls. | Signed-client identity and recovery matrix |
| A3A.2 | OPEN | Add isolated account, band, claim, installation, challenge, release, and ownership-event schemas with no health payloads. | Migration, tenant-isolation, backup, restore, and erasure tests |
| A3A.3 | OPEN | Implement an attested, fresh, band-proven, atomic, idempotent single-owner claim transaction. | Two-phone/two-account race and replay matrix |
| A3A.4 | OPEN | Make account, claim, band provisioning, local persistence, and final acknowledgement recover from every partial-success boundary. | Fault-injection state-machine evidence |
| A3A.5 | OPEN | Keep post-activation collection, metrics, export, and local controls working through identity-service and network outages. | Physical offline and outage matrix |
| A3A.6 | OPEN | Implement same-account replacement-phone authorization and old-installation revocation without changing ownership or losing data. | Signed physical replacement-phone journey |
| A3A.7 | OPEN | Implement support-controlled return, RMA, recovery, deletion, dispute, and eligible-upgrade release with owner-key revocation and band wipe. | Legal approval, operator exercise, and physical reclaim |
| A3A.8 | OPEN | Build matched Apple/Android disclosure, `I agree`, account, remaining onboarding, NOOP/NOOP+ choice, and resumable progress. | Accessibility trees, visual states, and end-to-end tests |
| A3A.9 | OPEN | Keep billing and NOOP+ consent separate from band ownership; leave checkout unavailable until gateway and store billing pass. | Entitlement, cancellation, downgrade, and no-charge tests |
| A3A.10 | OPEN | Add bounded local/backend claim evidence without band, account, contact, challenge, credential, or health identifiers. | Redaction, retention, and outcome tests |
| A3A.11 | OPEN | Serve immutable signed remote terms, record exact acceptance metadata, retain historical versions, and persist no full terms document in the app. | Tamper, outage, version-race, accessibility, privacy, and publication tests |
| A3A.12 | OPEN | Implement the approved 14- or 30-day return policy, condition inspection, lawful refund deduction, appeal, and operator-only wipe/release. | India/USA approval and end-to-end returns exercise |

**Exit:** a legitimate owner can identify, prove possession of, claim, recover,
and continue using one band without a subscription; another account cannot
claim it; and controlled release paths do not expose the previous owner.

### Phase 4 - terminology, identity, and data migration

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| T4.1 | PARTIAL | Retain the existing customer text scrubber until native naming is complete. | Customer-facing audit remains green |
| T4.2 | OPEN | Generate the classified terminology manifest and reviewed exception allowlist. | New-match CI gate |
| T4.3 | OPEN | Remove the false legacy-to-`Noop Band` display mapping. | Existing source renders truthfully |
| T4.4 | OPEN | Add neutral packages/types and a distinct NOOP Band source identity. | New hardware writes only neutral identities |
| T4.5 | OPEN | Implement dual-read, new-write database/path/backup/cloud migration in the order in section 7. | Old-install upgrade and rollback matrix |
| T4.6 | OPEN | Rename active Apple, Android, package, resource, generated-schema, build, and current-doc surfaces. | Zero unallowlisted customer/core matches |
| T4.7 | OPEN | Isolate or remove the legacy direct adapter only after first-party physical parity. | Support policy and no core dependency |
| T4.8 | OPEN | Preserve legal, provenance, migration, and historical truth. | Distribution and import/export tests |

**Exit:** the product and core architecture are NOOP-native, existing data is
readable, old imports remain truthful, and only reviewed exceptions retain the
legacy name.

### Phase 5 - mobile first-party band experience

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| M5.1 | OPEN | Build the matched printed-number, identify-vibration, physical-confirmation, consent, account, claim, remaining-onboarding, plan-choice, reconnect, and recovery journey. | Fresh, denied, failed, retry, conflict, offline, and replacement-device journeys on both platforms |
| M5.2 | OPEN | Show live state, freshness, battery, wear, storage/backlog, firmware, sync stage, progress, last completion, and actionable failures. | Matched screenshots and accessibility trees |
| M5.3 | OPEN | Keep foreground waits short while durable history continues in OS-permitted background work with truthful status. | Long-backlog physical tests |
| M5.4 | OPEN | Integrate live and history samples through one provenance-aware store path. | No duplicate, gap, source, or clock regression |
| M5.5 | OPEN | Implement signed firmware update, eligibility, deferral, interruption, retry, activation, and rollback UI. | Physical failed-update and recovery matrix |
| M5.6 | OPEN | Integrate haptics, alarms, workout caution, wear state, and low-battery behavior behind explicit capabilities. | Physical command/acknowledgment matrix |
| M5.7 | OPEN | Audit every screen, calendar detail, metric route, bottom navigation, empty/error state, notification setting, and onboarding page for Apple/Android parity. | Complete route capture and behavior checklist |
| M5.8 | PARTIAL | Retain shake-to-report and add SDK operation evidence without payloads. | Reports from lag, collection, history, OTA, and managed sync reviewed on real phones |
| M5.9 | OPEN | Complete VoiceOver/TalkBack, Dynamic Type/font scale, contrast, reduced motion, touch target, localization, RTL, and orientation review. | Accessibility acceptance record |

**Exit:** a user can install, pair, wear, leave, return, update, diagnose, and
export without understanding BLE or waiting on an unexplained blocking screen.

### Phase 6 - storage, performance, backup, and recovery

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| D6.1 | PARTIAL | Keep compact derived and user-authored records local; bound raw frame/sample retention by explicit policy. | Retention tests and UI disclosure |
| D6.2 | PARTIAL | For validated NOOP+ windows, keep seven days of high-rate raw and 30 days of essential local time series; never prune dirty or unverified data. | Physical long-history prune/restore evidence |
| D6.3 | OPEN | Reproduce 10, 30, 90, and 365 days at worst-case cadence and measure DB size, WAL, memory, scroll, analysis, sync, startup, backup, and battery. | Device-specific budgets with no hang or collection dropout |
| D6.4 | OPEN | Add compaction/index/query work only from measured profiles and preserve write throughput under backfill. | Before/after traces and regression tests |
| D6.5 | OPEN | Prove low-storage, full-disk, WAL growth, corrupt DB, failed migration, restore, process death, and concurrent read/write recovery. | Fault matrix with no silent loss |
| D6.6 | PARTIAL | Complete same-platform and portable backup/import coverage for the final schema and NOOP Band provenance. | Old/new/cross-platform restore fixtures |
| D6.7 | PARTIAL | Prove complete managed-history export, interruption/resume, corruption rejection, snapshot expiry, and documented import. | Large live synthetic account evidence |

**Exit:** storage remains bounded and responsive, and every destructive or
space-reclaiming action has a verified backup, exact eligibility, and rollback.

### Phase 7 - sensor and metric evidence

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| V7.1 | OPEN | Validate timestamps, units, calibration, quality flags, wear detection, gaps, duplicates, and loss for every production sensor and firmware revision. | Bench and participant-held-out sensor report |
| V7.2 | OPEN | Validate HR and R-R against reference devices across rest, sleep, motion, skin tone, fit, sweat, temperature, and battery states. | Error, coverage, and failure distributions |
| V7.3 | OPEN | Validate SpO2 and temperature only against an approved protocol; otherwise keep them raw/unavailable and make no clinical claim. | Frozen claim-specific report |
| V7.4 | OPEN | Validate sleep interval/staging, workout detection, steps/activity, respiration, Charge, Effort, Rest, stress, and age metrics with participant/device-held-out data. | Preregistered methods, revisions, confidence, subgroup and failure results |
| V7.5 | OPEN | Stabilize longitudinal metrics with minimum evidence windows, bounded weekly movement, provenance changes, and no abrupt unsupported age jumps. | Synthetic and longitudinal cohort tests |
| V7.6 | OPEN | Audit every metric dependency so a new band capability or missing signal propagates honestly through related metrics, calendar detail, Coach, notifications, and exports. | Dependency matrix and missing-data tests |
| V7.7 | OPEN | Freeze algorithm and calibration revisions for release; record reprocessing and rollback rules. | Signed metric release manifest |

**Exit:** each release claim maps to a frozen implementation, known inputs,
reference protocol, confidence/coverage rule, and honest failure state.

### Phase 8 - NOOP+ and production cloud, if enabled

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| C8.1 | PARTIAL | Promote the synthetic Mumbai foundation into separately controlled staging and production projects/cells. | Reviewed IaC, zero drift, digest-pinned deploys |
| C8.2 | OPEN | Establish production domain, DNS, TLS, WAF/rate limits, public authenticated ingress, App Check/attestation, identity recovery, and least-privilege IAM. | Signed physical-client enrollment and abuse tests |
| C8.3 | PARTIAL | Operate HA PostgreSQL, immutable objects, queues, KMS, secrets, lifecycle, retention, quotas, and erasure. | PITR/object restore, secret rotation, and deletion drills |
| C8.4 | OPEN | Define data region, consent, privacy notice, retention, support access, audit, breach, and cross-border policy for each market. | Legal/privacy approval and operator runbooks |
| C8.5 | OPEN | Add dashboards, SLOs, alerts, bounded log retention/access, cost budgets, on-call, incident response, and status/support procedures. | Alert and incident game-day evidence |
| C8.6 | OPEN | Load-test enrollment, reconnect bursts, chunk upload, processing, restore, export, Friends, and mixed workloads to the launch and 10,000-user targets. | Capacity limits and scaling/rollback plan |
| C8.7 | OPEN | Add production HTTPS universal/app links and opaque minimal APNs/FCM wake delivery with token lifecycle and abuse controls. | Closed-app physical delivery matrix |
| C8.8 | PARTIAL | Migrate the current phone-OTP-only staging identity to the approved release account: verified email/password plus optional linked phone, without embedding provider credentials. | Email, optional controlled-number, rate-limit, recovery, and support evidence |
| C8.9 | PARTIAL | Complete Friends invite, consent, removal, block, badge, poke, haptic, deletion, and abuse/support operations. | Two-user physical and backend matrix |
| C8.10 | OPEN | Complete country-specific sender registration, dual-provider strategy, SMS/voice/DTMF/callback/retry/cancel evidence, and 24/7 operations for manual app SOS paging. | Carrier IDs, latency, failover, and on-call evidence |

**Exit:** every enabled managed feature is production-operated and disclosed.
Otherwise its enrollment and store claims stay disabled.

### Phase 9 - security, privacy, legal, and certification

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| G9.1 | OPEN | Complete hardware, firmware, BLE, mobile, cloud, update, manufacturing, account, Friends, and Safety threat models. | Reviewed mitigations and residual risks |
| G9.2 | OPEN | Run independent mobile/API/cloud and band/firmware security assessments; remediate launch-severity findings. | Final reports and retest |
| G9.3 | PARTIAL | Keep dependency notices, owner-rights declaration, SBOM, licenses, and source distribution gates current. | Distribution gate on exact release commit |
| G9.4 | EXTERNAL | Complete trademark and final product-name review in launch markets. | Counsel/filing record |
| G9.5 | EXTERNAL | Complete DPDP and applicable US/state privacy analysis, consent, rights, grievance, breach, deletion, processor, and data-transfer documents. | Approved public policies and contracts |
| G9.6 | EXTERNAL | Complete BIS, WPC/ETA, FCC, Bluetooth SIG, UN38.3, IEC 62133, and other required market certification for the exact production design. | Certificate pack and labeling |
| G9.7 | OPEN | Review packaging, app/store copy, metric education, notifications, Safety, and support language for general-wellness accuracy. | Claims/legal sign-off |
| G9.8 | OPEN | Define vulnerability intake, coordinated disclosure, security updates, key compromise, firmware revocation, and end-of-support policy. | Public policy and internal runbooks |

**Exit:** the exact hardware, firmware, binaries, backend, packaging, and claims
have the required approvals and no unresolved release-severity finding.

### Phase 10 - manufacturing and customer operations

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| O10.1 | EXTERNAL | Qualify pilot and production manufacturing, component substitutions, test limits, calibration, yield, traceability, and golden units. | Approved pilot build and change-control record |
| O10.2 | EXTERNAL | Complete packaging, labels, regulatory inserts, battery shipping, customs/import, SKU, inventory, fulfillment, and returns. | Shipment-ready operations |
| O10.3 | OPEN | Publish setup, fit, charging, cleaning, troubleshooting, data recovery, firmware update, privacy, export, and deletion support material. | Reviewed support center |
| O10.4 | OPEN | Define warranty, RMA, replacement pairing/data continuity, lost/stolen band, recycling, and support escalation. | Tested customer and operator runbooks |
| O10.5 | OPEN | Train support using privacy-safe reports and fixed escalation categories; prohibit requests for raw databases or credentials. | Support acceptance exercise |
| O10.6 | OPEN | Establish firmware rings, staged rollout, halt criteria, rollback, minimum supported version, and critical-update process. | Pilot rollout and rollback drill |

**Exit:** a manufactured unit can be sold, shipped, supported, replaced,
updated, and recalled without improvising around user data or keys.

### Phase 11 - signing, stores, and release candidate

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| A11.1 | PARTIAL | Keep the existing Apple bundle/App Group identities and prove paid distribution capabilities for app, widgets, Watch, and complications. | Valid signed archive and in-place upgrade |
| A11.2 | OPEN | Create and protect Android upload key, Play App Signing identity, production package record, and recovery custody. | Signed AAB and key runbook |
| A11.3 | OPEN | Implement a disclosed isolated Review Sample Mode that never touches production data, BLE, health stores, notifications, Friends, cloud, or Safety. | Release-build review journey |
| A11.4 | OPEN | Complete App Privacy/Data Safety, export/encryption, medical/wellness, age/content, territory, trader, contact, pricing, tax/banking, and review answers. | Owner-approved store records |
| A11.5 | OPEN | Capture final iPhone, iPad, Watch, and Android media from the exact signed release candidate using fictional data. | Validated, rights-reviewed media |
| A11.6 | OPEN | Complete native-speaker review for every shipped locale and final accessibility acceptance. | Locale/accessibility sign-off |
| A11.7 | OPEN | Install signed RCs on the physical device matrix without clearing data and execute fresh install, upgrade, denial, offline, background, history, low storage, notification, Watch/Health, export, restore, and deletion journeys. | Signed RC matrix |
| A11.8 | OPEN | Use private TestFlight and Play internal testing for RC evidence; fix every release-blocking report and repeat affected matrices. | Zero open release-severity defects |
| A11.9 | OPEN | Validate Organizer/Play pre-launch results, attach the exact artifacts, and keep first release manual. | Submission-ready go/no-go pack |

**Exit:** the exact signed artifacts submitted to Apple and Google passed the
same upgrade, physical, privacy, and product evidence used for approval.

### Phase 12 - go-live and post-launch

| ID | Status | Work | Exit evidence |
|---|---|---|---|
| L12.1 | OPEN | Hold final go/no-go with every gate in section 10 and no undocumented waiver. | Signed release decision |
| L12.2 | OPEN | Tag the exact commit, archive manifests/SBOM/checksums, firmware and app compatibility, schemas, policies, evidence links, and rollback versions. | Immutable release pack |
| L12.3 | OPEN | Release manually, preferably with staged storefront and firmware rollout while treating it as production. | Store and firmware rollout record |
| L12.4 | OPEN | Monitor crashes, ANRs, hangs, collection freshness, history stalls, OTA, API SLOs, support volume, battery, and manufacturing/RMA signals within privacy limits. | Daily launch review |
| L12.5 | OPEN | Exercise app, backend, firmware, key, and communications rollback criteria. | Operators can halt and recover |
| L12.6 | OPEN | Publish accurate release notes and known limitations; never promote an experimental capability because submission succeeded. | Public release notes match evidence |
| L12.7 | OPEN | Run 24-hour, 7-day, and 30-day reviews and feed verified defects into a new operations round. | Closed launch review records |

## 9. Physical validation matrix

The final matrix must cover at least:

- multiple production bands from different pilot/manufacturing lots and every
  hardware revision;
- current and oldest-supported iPhone/iOS plus representative memory/storage
  classes;
- current and oldest-supported Android plus Pixel, Samsung, and at least one
  aggressive background-policy OEM in each launch market;
- clean install, in-place upgrade from every supported pre-release schema,
  app update during backlog, phone replacement, band replacement, and
  multi-device ownership;
- printed-number match, multiple nearby bands, identify vibration,
  at-least-three-tap confirmation, expiry, replay, simultaneous accounts,
  partial claim failure, already-claimed privacy, replacement phone, support
  release, and eligible-upgrade release;
- foreground, screen off, locked, app backgrounded, process killed by OS, app
  force-stopped, phone rebooted, Bluetooth toggled, airplane mode, low-power
  mode, low storage, thermal pressure, and timezone/DST travel;
- on wrist, off wrist, loose fit, charging, low battery, band reboot, flash
  near full/full, clock invalid/drifting, connection loss, duplicate and
  corrupt history;
- live HR/R-R, all supported sensors, history backlog, concurrent analytics,
  backup/export, HealthKit/Health Connect, Watch, notifications, haptics,
  workouts, alarms, and firmware update;
- OTA normal, paused, disconnected, low battery, app killed, phone reboot,
  corrupt image, wrong hardware, signature failure, activation failure, and
  rollback/recovery;
- at least 24-hour continuous collection, multi-day phone absence, 30-day
  soak, battery-life, and storage-growth runs.

Record firmware, hardware revision, app version/build, generalized phone/OS,
scenario, expected result, actual result, report/evidence location, and defect.
Do not record a participant's raw health values in the release ledger.

## 10. Final go/no-go gates

| Gate | Required evidence |
|---|---|
| Scope and claims | Approved market, feature, pricing, wellness, Safety, and legacy-support decisions |
| Source and CI | Clean release commit; all required hosted/local gates green; no open release-severity defect |
| SDK and firmware | Cross-language conformance, signed firmware, secure provisioning, history integrity, OTA rollback, hardware-in-loop |
| Account and band ownership | Verified identity, optional phone, attestation, physical possession proof, atomic single-owner claim, remote immutable terms acceptance, offline post-activation use, no user-facing v1 unpair, recovery, operator-only release, deletion, successor-upgrade release, and transfer-policy approval |
| Returns | Approved 14- or 30-day clock, eligibility, condition grades, disclosed lawful deductions, original-rail refund, appeal, operator wipe/release, quarantine, and support evidence |
| Data continuity | Old-to-new upgrade, backup, restore, source/provenance, interrupted migration, and rollback pass |
| Terminology | Zero unallowlisted customer/core matches; reviewed legal/provenance/migration exceptions only |
| Mobile product | Signed Apple/Android feature, parity, accessibility, localization, performance, and physical matrices pass |
| Sensor and metrics | Claim-specific reference evidence, frozen revisions, missing-data behavior, and known limitations |
| Cloud, if enabled | Production identity, ingress, attestation, isolation, retention, restore, load, SLO, on-call, privacy, support, and deletion pass |
| Safety, if enabled | Country/provider registration, dual-path delivery, acknowledgment, cancellation, failover, physical haptic, legal, and on-call pass |
| Security and privacy | Threat models, independent assessment, remediations, SBOM, secrets/keys, policies, consent, rights, breach and support controls |
| Hardware compliance | Production-design certifications, labeling, battery shipping, manufacturing traceability, warranty/RMA |
| Stores | Distribution signing, store disclosures/media/review mode, exact artifact validation, manual release |
| Operations | Dashboards, alerts, incident/rollback, firmware rollout, support, status and launch staffing rehearsed |

No gate is closed by a plan, a screenshot, a simulator, a synthetic staging
run, or a successful store upload alone.

## 11. Inputs needed from the owner

Provide these through the appropriate secure or account-owned channel:

1. The band input dossier, supplier SDK and license, printed-label mapping,
   pairing/identify/gesture/claim contract, firmware owner contact, firmware
   source/toolchain access, and at least three representative engineering bands
   per hardware revision for cross-platform and destructive OTA testing.
2. Written launch-market, launch-language, NOOP+, Safety, pricing, public
   version, and legacy-support decisions.
3. Legal entity, trademark owner, manufacturing agreement, certification lab,
   privacy/legal reviewers, warranty owner, and launch-country operations.
4. Apple organization/App Store Connect authority and Google Play organization
   authority. Signing keys and certificates stay in platform or approved key
   systems, not chat or Git.
5. Production domain/DNS, GCP organization/billing/production-project control,
   Firebase production apps, messaging provider accounts, and on-call owners if
   NOOP+ or paging ships.
6. Controlled test phone numbers and country/carrier coverage for OTP or
   Safety. India paging additionally needs DLT entity, header, and approved
   templates.
7. Reference instruments, study protocol, participant recruitment/consent,
   statistical owner, and budget for sensor and metric validation.
8. Final support contact, privacy/support website ownership, storefront
   content, fulfillment/RMA process, and launch staffing.
9. India and USA counsel review of the single-account ownership lock, v1
   no-self-service-transfer policy, return/RMA/recovery/deletion/dispute exits,
   and future eligible-upgrade release.
10. The India hardware checkout and digital subscription billing decision,
    including gateway, IAP, GST/tax, renewal, cancellation, refund, receipt,
    chargeback, and support ownership.
11. The 14- or 30-day return decision, clock start, eligibility rules,
    condition-grade/deduction schedule, inspection owner, return logistics,
    refund SLA, and appeal owner.

## 12. Immediate next rounds

Work can start before bands arrive:

1. Preserve the green hosted source matrix and establish protected release
   controls, reviewed environments, credential rotation, and artifact
   provenance.
2. Finish the remaining phase-zero owner, legal, transfer, support, and payment
   decisions now that India-first, USA-second, and the ownership flow are
   recorded.
3. Complete the supplier-backed label, identify, cryptographic-possession,
   owner-key, return/release, legal, and signed physical-client gates for the
   implemented ownership foundation without guessing supplier bytes.
4. Build the terminology classifier/allowlist and remove the false
   legacy-to-first-party display mapping.
5. Introduce neutral core stream/store/source boundaries and old-data
   migration fixtures without removing the working hardware adapter.
6. Create the protocol-spec template, neutral SDK interfaces, deterministic
   virtual band, synthetic conformance corpus, and observability categories.
7. Start signing, store, privacy, certification, manufacturing, and metric
   validation work because their lead times are independent of mobile code.

When the hardware dossier and engineering bands arrive, freeze protocol v1,
complete firmware and native transports, then execute the physical and
production phases in dependency order. Direct legacy transport is removed or
isolated only after NOOP Band reaches verified parity and existing data remains
readable.
