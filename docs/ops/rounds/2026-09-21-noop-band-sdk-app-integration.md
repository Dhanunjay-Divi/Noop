# Round: 2026-09-21 — NOOP Band SDK app integration

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- End implementation commit: `4fcc134240a542694c5acc51a4d1487b074064bd`
- Record commit or PR: PR `#17`; evidence follow-up pending

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
  - private `NoopBandSDK` neutral-core merge
    `e166773c5d3efd68dc5fa24488c9bbdf3ab6e97b`;
  - private SDK review-hardening merge
    `f32633a9fc63a9edd273f38e97b48c216a798234`;
  - exported implementation revision
    `f2c1e189d6e703ceecea3502e1ba9ea77d8e2bd7`;
  - ten-file export manifest with
    `supplierArtifactsIncluded: false`;
  - standalone Swift 15-test, Kotlin 16-test, and 18-scenario cross-platform
    conformance evidence;
  - existing Apple and Android single-active-source coordinators.
- Unknowns that must remain unknown until measured: exact supplier APIs and
  callbacks, protocol/device identity, disconnected flash depth and overwrite
  behavior, background collection, power use, radio timing, haptic/alarm
  behavior, firmware update/recovery, physiological accuracy, and
  redistribution rights for any future supplier binary.

## Delivered

- Re-exported the exact ten-file source artifact from private SDK implementation
  revision `f2c1e189d6e703ceecea3502e1ba9ea77d8e2bd7` twice from a detached clean
  worktree. Both artifacts were byte-identical; the manifest SHA-256 is
  `c33bdf82133b4fa7320b6974258de01dd3b049247e31831264902cbdfe91d735`.
  The verified artifact replaced `Vendor/NoopBandSDK` without supplier
  binaries or symlinks.
- Closed all seven independent private-SDK review findings: external SwiftPM
  scratch isolation, truthful absent-firmware eligibility, durable
  source-scoped history restore, one signed 64-bit sequence domain,
  capability enforcement for live/history streams, firmware exclusion while
  live collection is active, and exact history completion/overflow/commit
  receipts.
- Added a release-control verifier that pins the export manifest, source
  repository/revision, every exported file digest and size, the executable
  Swift package definition, and the package test wrapper. It rejects symlinks,
  unexpected top-level files, tree drift, and supplier binary/archive
  payloads.
- Added the local Swift package to the macOS, iOS, and macOS test graphs. Its
  test target compiles the exported Apple virtual band and compares all 18
  automated results with the exported JSON contract.
- Added the exported Kotlin production sources to the Android main source set
  and its virtual band to the JVM test source set. The app test compares every
  event, final state, cursor, accepted count, and failure with the same 18-case
  contract.
- Added app-owned Apple and Android boundaries that construct only the neutral
  session core, pin the consumed SDK revision, and may restore an explicitly
  supplied durable history checkpoint.
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
| Starting app context snapshot | Clean dedicated branch at `9c514175`; concurrent UI work remains in its own worktree | Work is isolated from protected `main` and concurrent changes | Build correctness or hardware behavior |
| Private SDK hardening | PR `#2` merged normally at `f32633a9`; Swift 15/15, Kotlin 16/16, 18 shared scenarios, and the 38-file repository gate passed | Review findings are corrected in source authority before app ingestion | Supplier API compatibility or physical behavior |
| Independent clean exports | Two detached-worktree exports were byte-identical; manifest SHA-256 `c33bdf82133b4fa7320b6974258de01dd3b049247e31831264902cbdfe91d735` | The vendored artifact is deterministic and traceable to `f2c1e189` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Artifact verifier plus required-CI unit tests | Exact ten-file export passed; 54/54 tests passed; no symlinks found | Source, manifest, package wrapper, workflow scratch path, layout, and no-binary policy are pinned | Physical compatibility |
| Exact Swift package workflow order | External scratch path completed 4/4 tests and all 18 exported scenarios, then the verifier still passed | SwiftPM does not mutate the vendored source and the exported Apple core agrees with the shared contract | App lifecycle, BLE, background, or hardware behavior |
| Android Full app boundary | `NoopBandSdkIntegrationTest` passed under `testFullDebugUnitTest`; build succeeded in 2m36s | Full-variant app source, durable checkpoint restoration, and all 18 shared scenarios compile and pass | Instrumentation, OEM background, BLE, or physical behavior |
| Android Demo compile | `compileDemoDebugKotlin` passed independently in 1m19s | The Demo variant consumes the same hardened source successfully | Demo runtime rendering or device behavior |
| Android memory classification | A combined parallel Full+Demo compile exhausted the Kotlin heap; the repository-standard in-process, no-parallel, two-worker runs passed independently with healthy host memory | The failure was an avoidable verification command shape, not a source failure; sequential bounded builds prevent the spike | Every future machine configuration |
| Apple app boundary | Xcode 27 focused macOS test passed 4/4 in the real hosted app target, including WHOOP-default routing and source-scoped checkpoint restore | App-target compilation and Apple boundary behavior are green on the current host | Universal/macOS-15, iOS simulator, BLE, or physical behavior |
| Local package-metadata cleanup | The focused Xcode run created ignored `Vendor/NoopBandSDK/.swiftpm`; the exact generated directory had no open process, was removed, and the artifact verifier passed afterward | Local Xcode metadata cannot contaminate the pinned artifact or its copied tamper tests | Future Xcode behavior unless the same exact-layout verifier is run |
| Final release-control wall | 196/196 tests; 9 release checks; required-CI 10 contexts; trusted self-check; shell syntax/static checks; calibration parity; distribution provenance; private-data guard; 83 operations records; and diff hygiene passed | The exact local candidate satisfies the repository-controlled release and trust contracts | Hosted exact-SHA enforcement or protected integration |
| Final terminology and claims gates | 17,869 classified occurrences across 1,588 groups with unchanged category totals and zero forbidden mappings; health-claims scanned 1,299 files; complete localization audit passed with zero translated-key gaps in the supported Apple catalogs | The reviewed terminology snapshot, health wording guard, and localization catalogs remain coherent | Physical accessibility, every pre-existing hardcoded-literal debt item, or medical accuracy |
| Previous remote candidate | PR `#17` head `c16488d7` passed every applicable hosted app, policy, trust, package, server, and release context before review remediation | The pre-remediation integration graph was hosted-green | The unpushed remediation candidate; new exact-SHA checks remain required |

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
- Commits: initial implementation
  `68fb9fd5cfd0f2731917cee8b14f84e391b9128e`; initial operations record
  `c16488d70001bb3257c7c0c4d6644ab7f88d1372`; review-remediation implementation
  `4fcc134240a542694c5acc51a4d1487b074064bd`.
- Branch and remote state: PR `#17` is open from the dedicated branch; the
  remote head remains `c16488d7` until one consolidated remediation push.
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

- Focused Apple and Android app-target verification is green, but the complete
  protected Apple/Android walls must rerun on the final exact SHA.
- A source-only adapter seam cannot establish that a supplier band is
  compatible or flashable.

## Next round

1. Run the final local release, policy, operations, terminology, and diff gates.
2. Commit and push the consolidated review-remediation candidate once.
3. Require every exact-SHA protected context, including the full Apple and
   Android app walls, then resolve the seven review threads from matching
   evidence.
4. Merge normally, verify protected `main`, and remove exact round-owned logs,
   DerivedData, exports, package scratch data, and the dedicated worktree.
5. Keep the supplier adapter/flasher disabled until the exact SDK, firmware,
   tooling, keys, rights, and representative physical bands pass their
   acceptance matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
