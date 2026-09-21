# Round: 2026-09-21 — NOOP Band SDK app integration

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- End implementation commit: `68fb9fd5cfd0f2731917cee8b14f84e391b9128e`
- Record commit or PR: pending

## Objective

Consume the reviewed, binary-free `NoopBandSDK` export in the Apple and
Android application builds, prove its neutral state-machine contract through
app-repository tests, and add an explicit default-off source-factory seam for a
future supplier adapter without changing the existing WHOOP transport.

Success means:

- the app pins and verifies one exact private-SDK source revision and file
  digest set;
- Apple and Android compile the neutral production contract;
- deterministic tests exercise the neutral session and app source-selection
  boundary on both platforms;
- production composition roots do not register a first-party transport until
  the supplier artifacts and physical acceptance gates exist;
- WHOOP remains the default comparison and regression transport; and
- the branch passes applicable protected checks before normal integration to
  `main`.

## Scope

### In scope

- Digest-pinned, source-only SDK artifact ingestion.
- Apple and Android build wiring.
- Default-off, dependency-injected source-factory seams.
- Cross-platform unit and contract tests.
- Bounded, privacy-safe integration diagnostics review.
- SDK/app handoff and physical-gate documentation.

### Non-goals

- Supplier binaries, SDK jars/aars/frameworks, firmware images, bootloader
  utilities, signing keys, or flashing credentials.
- Real first-party scanning, pairing, ownership proof, history offload,
  haptics, alarms, OTA, or firmware flashing.
- Removing, renaming, or routing the WHOOP implementation through the new SDK.
- Claims about BLE reliability, background execution, battery, physiology, or
  production-band accuracy.

## Starting evidence

- Reproduction or observed symptom: the neutral SDK repository is implemented
  and merged, while the app still records its wrapper as not implemented.
- Relevant source/device/OS/firmware class: shared Apple source coordinator,
  Android source coordinator, source-only SDK export; no supplier hardware or
  firmware is part of this round.
- Existing tests, logs, exports, screenshots, or documents:
  - protected app `main` at `9c514175`;
  - private `NoopBandSDK` `main` at merge commit
    `e166773c5d3efd68dc5fa24488c9bbdf3ab6e97b`;
  - exported implementation revision
    `0abd9a3ce4f808b51bdc93ad28504ac810914631`;
  - ten-file export manifest with
    `supplierArtifactsIncluded: false`;
  - standalone Swift 9-test, Kotlin 10-test, and 13-scenario cross-platform
    conformance evidence;
  - existing Apple and Android single-active-source coordinators.
- Unknowns that must remain unknown until measured: exact supplier APIs and
  callbacks, protocol/device identity, disconnected flash depth and overwrite
  behavior, background collection, power use, radio timing, haptic/alarm
  behavior, firmware update/recovery, physiological accuracy, and
  redistribution rights for any future supplier binary.

## Delivered

- Copied the exact ten-file source export from private SDK implementation
  revision `0abd9a3ce4f808b51bdc93ad28504ac810914631` into
  `Vendor/NoopBandSDK` with its original manifest unchanged.
- Added a release-control verifier that pins the export manifest, source
  repository/revision, every exported file digest and size, the executable
  Swift package definition, and the package test wrapper. It rejects symlinks,
  unexpected top-level files, tree drift, and supplier binary/archive
  payloads.
- Added the local Swift package to the macOS, iOS, and macOS test graphs. Its
  test target compiles the exported Apple virtual band and compares all 13
  automated results with the exported JSON contract.
- Added the exported Kotlin production sources to the Android main source set
  and its virtual band to the JVM test source set. The app test compares every
  event, final state, cursor, accepted count, and failure with the same 13-case
  contract.
- Added app-owned Apple and Android boundaries that construct only the neutral
  session core and pin the consumed SDK revision.
- Added optional source factories to both source coordinators. Production
  composition roots use their nil/null defaults; WHOOP classification and
  transport behavior remain unchanged.
- Extended Apple/Android required-workflow applicability, ran the Swift package
  in the Apple workflow, and added the artifact verifier to release controls
  without adding a new hosted job.
- Updated the SDK handoff, first-release plan/checklist, decision ledger,
  active handoff, and terminology inventory.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: no sample source, formula, or authority
  switch occurs.
- Permissions/network disclosure impact: no new permission, endpoint, upload,
  telemetry, or public traffic.
- Health/medical claim impact and limitations: none; synthetic values exercise
  software contracts only.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the neutral
  SDK already emits bounded discovery, connection, capability, live, history,
  command, firmware, and session events with fixed outcomes and count buckets.
  App source selection remains covered by the existing source-coordinator
  lifecycle and tests.
- Why existing evidence is sufficient, or why new evidence is required:
  this integration adds no enabled runtime transport. The deterministic
  contract proves that the neutral core preserves fixed outcomes without
  logging vendor errors, identifiers, payloads, or health values.
- Existing evidence reused: `AppDiagnosticsRecorder`, current band transport
  diagnostics, source-coordinator tests, and SDK bounded diagnostics.
- New bounded events or operation spans: none. A disabled dependency-injection
  seam and compile-time artifact verification do not add a user-visible
  lifecycle; a real adapter must add its bounded app boundary in its own
  reviewed round.
- Redaction, retention, and high-frequency controls: no per-sample app log;
  no address, serial, source identity, callback token, cursor, raw error,
  health value, or frame may enter the report.
- Cross-platform/backend correlation: not applicable before a real adapter or
  managed upload path exists.
- Remaining blind spots: all supplier and physical-device behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Starting app context snapshot | Clean dedicated branch at `9c514175`; 4.0 GiB free | Work is isolated from protected `main` and concurrent worktrees | Build correctness or hardware behavior |
| Standalone SDK export evidence | Previously green in the private SDK repository | The source export is deterministic and cross-platform before ingestion | App build wiring or supplier behavior |
| `verify-noop-band-sdk-artifact.py` plus focused unit tests | Exact ten-file export passed; 5/5 verifier tests passed | Source, manifest, executable package wrapper, layout, and no-binary policy are pinned | Supplier provenance or physical compatibility |
| `swift test --package-path Vendor/NoopBandSDK` | 4/4 passed; all 13 automated scenarios matched the exported expectations | Apple production core and virtual conformance compile and agree with the contract | App-target compile, BLE, background, or hardware behavior |
| Focused cached Kotlin compiler plus JUnit | Exact production/test-support/app-boundary source set compiled; 2/2 tests passed and all 13 scenarios matched | Android SDK integration syntax and deterministic contract behavior | Full Gradle app graph, instrumentation, or device behavior |
| XcodeGen and Gradle configuration | XcodeGen accepted the local package graph; offline `:app:tasks` succeeded | Project/package and Android source-set configuration are structurally accepted | Full app compilation |
| Independent read-only review | Found package-wrapper pinning and incomplete conformance assertions; both corrected and reverified; no WHOOP routing regression found | Fresh review findings were resolved before commit | Hosted app compilation or physical behavior |
| Release-control wall | 196/196 tests; 9 release checks; required-CI 10 contexts; trusted self-check passed | Workflow applicability, integrity ratchets, and protected-check contracts remain valid | Hosted exact-SHA result |
| Product/policy gates | Terminology 17,869 occurrences/1,588 groups/zero forbidden; health claims, provenance, private-data, operations, calibration, and diff checks passed | The source-only integration preserves current policy boundaries | Legal approval for future supplier artifacts |
| Local app-build attempt | Xcode package resolution was stopped by the disk watchdog; no full local Apple or Android app wall run | The resource floor prevented an unsafe build | App-target correctness; protected CI remains required |
| Resource cleanup | Removed exact round-owned 1.9 GiB Strand DerivedData, generated Xcode files except the restored tracked lockfile, Swift build state, and Android project cache | No known heavy round-owned local build remains | Unrelated/shared machine storage |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not applicable.
- Data-preservation result: no user data will be opened or mutated by this
  source-only round.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party BLE, pairing/ownership, disconnected
  history, haptics/alarms, OTA/flashing/recovery, battery, background, radio,
  and accuracy scenarios.

## Git and release state

- Changed paths: exact vendored SDK source/manifest/package wrapper; Apple and
  Android app boundaries, source coordinators, build inputs, and tests;
  protected workflow applicability and release controls; terminology and
  release/handoff/operations documents.
- Commits: implementation `68fb9fd5cfd0f2731917cee8b14f84e391b9128e`;
  operations-record commit pending.
- Branch and remote state: local dedicated branch from protected `main`.
- Repository visibility verified: `Dhanunjay-Divi/Noop` and
  `Dhanunjay-Divi/NoopBandSDK` both report `PRIVATE` with default branch
  `main`.
- Version/build impact: no customer version change planned.
- Release or distribution impact: no release or deployment until protected
  checks pass; supplier artifacts remain excluded.

## Decisions

- Durable decision added or changed: none. D-043, D-055, D-056, and D-059
  remain controlling.
- Decision-log entry: none planned unless implementation changes one of those
  contracts.

## Open risks and honest limitations

- The host is below the repository's 10 GiB heavy-build floor. Full local
  Xcode/Gradle walls did not run. Free disk reached 1.3 GiB after an Xcode graph
  probe and returned to 2.4 GiB after exact cleanup; one consolidated
  protected-CI candidate is the required heavy verification.
- A source-only adapter seam cannot establish that a supplier band is
  compatible or flashable.

## Next round

1. Commit and push the consolidated candidate once.
2. Require every exact-SHA protected context, including the full Apple and
   Android app walls.
3. Merge normally, verify protected `main`, and remove exact round-owned logs,
   temporary compilers, and the dedicated worktree.
4. Keep the supplier adapter/flasher disabled until the exact SDK, firmware,
   tooling, keys, rights, and representative physical bands pass their
   acceptance matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
