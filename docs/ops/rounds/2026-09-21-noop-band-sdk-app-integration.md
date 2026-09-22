# Round: 2026-09-21 — NOOP Band SDK app integration

## Status

- State: `ready for hosted resource-profile replacement push`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- End implementation commit: pending final hosted resource-profile correction
- Record commit or PR: PR `#17`; exact-SHA replacement evidence remains pending

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
  - private SDK final implementation merge
    `34028a2ab56feb90ae774b0ee0055529ce175723`;
  - private SDK runtime-authority hardening merge on `main`
    `dab6072eb2b69b07ee34221dbb649a0119547246`;
  - private SDK connection-lifecycle hardening merge on `main`
    `78c17cbd495353f33b5ef169bd1200ee9a0c35df`;
  - private SDK caller-ownership and security-terminal hardening merge on
    `main` `44559aeb4b1b50af9e6ab8b8dc786f87821c72d9`;
  - ten-file export manifest with
    `supplierArtifactsIncluded: false`;
  - standalone Swift 30-test, Kotlin 31-test, 33-scenario cross-platform
    conformance, and 41-file repository-gate evidence;
  - existing Apple and Android single-active-source coordinators.
- Unknowns that must remain unknown until measured: exact supplier APIs and
  callbacks, protocol/device identity, disconnected flash depth and overwrite
  behavior, background collection, power use, radio timing, haptic/alarm
  behavior, firmware update/recovery, physiological accuracy, and
  redistribution rights for any future supplier binary.

## Delivered

- Re-exported the exact ten-file source artifact from private SDK `main`
  revision `44559aeb4b1b50af9e6ab8b8dc786f87821c72d9` twice from a clean
  worktree. Both artifacts were byte-identical; the manifest SHA-256 is
  `cd640939de9ac2509a570081b62ed361314a25b19922d65371dfbec7a4269a14`.
  The verified artifact replaced `Vendor/NoopBandSDK` without supplier
  binaries or symlinks.
- Preserved the original seven private-SDK review corrections and consumed the
  additional fourteen protected-review fixes: generation-fenced capability
  callbacks, nonnegative device time, per-operation durable history receipts,
  firmware-specific diagnostics, nonadvancing-cursor rejection, UTF-8 byte
  limits with malformed-surrogate rejection, sampling capability enforcement,
  bounded deterministic identity caches, explicit cancel/fail terminals,
  disconnect generation invalidation, cross-platform cache restoration order,
  strict pre-insert eviction, and firmware-specific rejection diagnostics. The
  final protected remediation additionally provides explicit connection and
  authentication phases, generation-fenced connection completion, categorized
  connection/authentication terminals, and bounded pending-history busy
  diagnostics. The late protected remediation snapshots caller-owned Kotlin
  live/history collections once at the state-machine boundary and invalidates
  the authenticated session after an operation security failure on both
  platforms.
- Added a release-control verifier that pins the export manifest, source
  repository/revision, every exported file digest and size, the executable
  Swift package definition, and the package test wrapper. It rejects symlinks,
  including a symlink supplied as the artifact root, unexpected top-level
  files, tree drift, and supplier binary/archive payloads.
- Added the local Swift package to the macOS, iOS, and macOS test graphs. Its
  test target compiles the exported Apple virtual band and compares all 33
  automated results with the exported JSON contract.
- Added the exported Kotlin production sources to the Android main source set
  and its virtual band to the JVM test source set. The app test compares every
  event, final state, cursor, accepted count, and failure with the same
  33-case automated contract.
- Added app-owned Apple and Android boundaries that construct only the neutral
  session core, pin the consumed SDK revision, and may restore an explicitly
  supplied durable history checkpoint.
- Added app-boundary regressions for generation-fenced capability negotiation,
  per-operation history receipts, explicit cancellation, disconnected
  operation recovery, and fixed-category diagnostics.
- Added optional source factories to both source coordinators. Production
  composition roots use their nil/null defaults; WHOOP classification and
  transport behavior remain unchanged.
- Extended Apple/Android required-workflow applicability, ran the Swift package
  in the Apple workflow, and added the artifact verifier to release controls
  without adding a new hosted job.
- Updated the SDK handoff, first-release plan/checklist, decision ledger,
  active handoff, and terminology inventory.
- Diagnosed the final hosted Android production-shell failure from retained CI
  artifacts rather than retrying it blindly. The managed device started the
  complete shell wall and failed only two App Report presentation cases after
  an earlier WorkManager continuity class, so it was neither an emulator
  startup loss nor an SDK assertion.
- Hardened that continuity class's test-only teardown: it now waits for every
  generation of its exact unique work to reach a terminal state, every started
  upload worker to exit its outermost `doWork` frame, every started probe to
  finish `NonCancellable` unwind, and a stable no-new-generation resnapshot
  before deleting its exact feedback record. A focused regression proves that
  WorkManager can report `CANCELLED` while a worker remains blocked in cleanup.
  This preserves production feedback restoration while preventing a retiring
  test worker from leaking nonterminal outbox state into later UI tests.
- Reviewed the final hosted candidate rather than retrying failures blindly.
  The complete Apple wall, Android build/unit wall, and Android Review Sample
  shell passed. Release controls failed only because the final operations
  record shifted four reviewed terminology line numbers without changing
  counts, categories, groups, or the active allowlist. The Android production
  shell started zero tests because the bounded runner stopped on host memory
  pressure.
- Preserved the managed-device classifier's fail-closed resource behavior and
  moved both retry announcements behind an explicit `retry == true` condition.
  A resource-pressure stop no longer presents source text that says a retry is
  happening when the classifier correctly rejects it.
- Verified exact head `fbbb3b50` across every other hosted context: Android
  build/unit/lint, production shell, iOS, macOS, server, packages,
  localization, policy, release, and trust checks passed. Review Sample alone
  stopped twice under the bounded runner after emulator startup because the
  hosted runner crossed the unchanged 10% free-memory floor. Both retained
  artifacts contain a successful APK preparation, `resource-memory` status,
  emulator setup evidence, and zero test-result records.
- Reduced only the Review Sample managed-device Gradle envelope from a 2 GiB
  heap with two workers to the 1.5 GiB, one-worker profile already proven by
  the complete hosted production-shell job. The first run and approved retry
  now share that bounded profile. Release-control tests reject any return to
  the larger two-worker shape.

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
  command, firmware, and session events with fixed outcomes, failure categories,
  and count buckets.
  App source selection remains covered by the existing source-coordinator
  lifecycle and tests.
- Why existing evidence is sufficient, or why new evidence is required:
  this integration adds no enabled runtime transport. The deterministic
  contract proves that the neutral core preserves fixed outcomes without
  logging vendor errors, identifiers, payloads, or health values.
- Existing evidence reused: `AppDiagnosticsRecorder`, current band transport
  diagnostics, source-coordinator tests, and SDK bounded diagnostics.
- New bounded events or operation spans: no app event is emitted because the
  production factory remains disabled. Apple and Android boundary tests now
  prove that the injected SDK recorder exposes only the fixed
  `history/failed/storage`, `command/failed/disconnected`, and
  `reconnect/interrupted/disconnected` categories. A real adapter must bridge
  those bounded enums into the app recorder in its separately reviewed round.
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
| Private SDK final remediation | PR `#7` merged normally at `44559ae`; Swift 31/31, Kotlin 34/34, 33 shared scenarios, and the 42-file repository gate passed | The neutral runtime snapshots caller-owned Kotlin collections and treats operation security failures as terminal before final app ingestion | Supplier API compatibility or physical behavior |
| Independent clean exports | Two clean-worktree exports were byte-identical; manifest SHA-256 `cd640939de9ac2509a570081b62ed361314a25b19922d65371dfbec7a4269a14` | The vendored artifact is deterministic and traceable to `44559ae` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Artifact verifier plus unit tests | Exact ten-file export passed; 6/6 verifier tests passed, including rejection of a symlink artifact root; no supplier artifacts found | Source, manifest, package wrapper, exact layout, root/tree symlink policy, and no-binary policy are pinned | Physical compatibility |
| Exact Swift package workflow order | The vendored package completed 15/15 tests and checked all 33 automated exported scenarios, then its generated `.build` cache was removed and the exact artifact verifier passed | SwiftPM agrees with the shared contract without leaving generated files inside the verified source tree | App lifecycle, BLE, background, or hardware behavior |
| Android Full app boundary | `NoopBandSdkIntegrationTest` passed 5/5 under `testFullDebugUnitTest`, including all 33 automated shared scenarios | Full-variant app source, immutable capability authorization, connection/authentication generation fences, durable checkpoint restoration, explicit terminals, and bounded diagnostics compile and pass | Instrumentation, OEM background, BLE, or physical behavior |
| Android Demo compile | `compileDemoDebugKotlin` passed independently in 1m37s against the `44559ae` export | The Demo variant consumes the same final source successfully | Demo runtime rendering or device behavior |
| Android memory classification | One combined Full+Demo invocation let the two Compose compilers overlap and exhausted a 3 GiB Kotlin heap; separate no-daemon, no-parallel, two-worker commands passed | The failure was an avoidable verification command shape, not a source failure; variant walls must stay sequential | Every future machine configuration |
| Hosted production-shell diagnosis | PR `#17` run `35643099439` started 120 API 35 tests; 116 passed, two App Report cases timed out before their explanation sheets appeared, and the retained result protobuf contained real test cases | The red required context was a real cross-test state leak, not a zero-test infrastructure event or SDK behavior failure | The local correction until rerun on the protected exact SHA |
| Feedback cleanup instrumentation regression | Full instrumentation source compiled, then six continuity cases followed by all eight AppShell cases passed 14/14 on `pixel2Api35` in 1m42s | Terminal WorkInfo alone cannot release teardown; actual worker/probe unwind and a stable no-new-generation snapshot are required before deleting the exact record, and the report sheets still open afterward | The complete hosted production-shell wall or physical Android behavior |
| Apple app boundary | Xcode 27 focused macOS test passed 5/5 in the real app target, including WHOOP-default routing, source-scoped restore, explicit terminals, generation invalidation, and bounded failure categories. The unsigned iOS simulator graph then built successfully with its Watch app and widget embedded and validated. | macOS app-target behavior and the complete iOS compile graph consume the repinned Swift package successfully | Signed-device runtime, universal/macOS-15, BLE, background, or hardware behavior |
| Bounded disk exception and cleanup | The final Apple rerun reused its integration-only package cache with a 5.5 GiB hard floor after measuring 8.2 GiB free; the real app test passed 5/5, the exact DerivedData reached 2.8 GiB, and its removal restored free disk from 6.9 GiB to 9.3 GiB | The final Apple test ran under explicit memory/disk bounds without touching the concurrent UI worktree, while round-owned disk use returned immediately | Future host capacity without the same preflight and cleanup |
| Final repository policy wall | The first replacement Tools wall exposed only the expected stale terminology-inventory trust digest. After reviewing unchanged counts/categories and zero forbidden mappings, the inventory and protected digest were repinned; the complete wall then passed 312/312 with one intentional skip. Required-CI verifies 10 contexts, and trusted self-check, terminology, operations, artifact, bounded-runner, and diff gates pass. | The exact local candidate satisfies the repository-controlled release, trust, privacy, terminology, operations, and artifact contracts | Hosted exact-SHA enforcement or protected integration |
| Resource-floor correction | The first 312-test Tools wall had four bounded-runner failures because nested tests correctly enforced their 10 GiB default while the host had 9.3 GiB free. With no build processes active, deleting only generated Xcode precompiled-module and module caches restored 11 GiB; the unchanged wall then passed 312/312 with one skip | The failures were environmental and the runner remained fail-closed; generated cache cleanup restored the test precondition without source or test changes | Future host capacity without the same disk preflight |
| Final terminology and claims gates | 17,869 classified occurrences across 1,588 groups with unchanged category totals and zero forbidden mappings; health-claims scanned 1,299 files; complete localization audit passed with zero translated-key gaps in the supported Apple catalogs | The reviewed terminology snapshot, health wording guard, and localization catalogs remain coherent | Physical accessibility, every pre-existing hardcoded-literal debt item, or medical accuracy |
| Previous remote candidate | PR `#17` head `c16488d7` passed every applicable hosted app, policy, trust, package, server, and release context before review remediation | The pre-remediation integration graph was hosted-green | The unpushed remediation candidate; new exact-SHA checks remain required |
| Final pre-repin hosted candidate | PR `#17` head `abd54fbd` passed macOS, iOS production shell, Apple required, Android build/unit, Android Review Sample, server/package/policy/trust jobs, and automated review. Release controls failed only on four shifted inventory line numbers. Android production shell stopped before tests with bounded `resource-memory` and no result files. | The final SDK source and app graph compile and pass every hosted wall that executed tests; the two red jobs are precisely classified and retained | A passing replacement exact-SHA Android production shell or release-control job |
| Managed-device retry diagnostic correction | `test_android_managed_device_retry` passes 17/17, Actionlint passes, required-CI verifies all ten contexts, and trusted self-check passes | Resource-pressure stops remain fail-closed, while retry announcements occur only after classifier approval | Whether the next hosted runner has sufficient memory to execute the emulator wall |
| Exact-head hosted resource classification | PR `#17` head `fbbb3b50` passed every hosted context except Review Sample. Run `35681052415` attempt 1 job `106598021250` and attempt 2 job `106602308597` each completed APK preparation, entered the emulator task, then stopped with bounded `resource-memory`; retained evidence has no test-result records. | The two failures are reproducible hosted-runner resource stops, not hidden assertions or product failures | A passing Review Sample execution on the replacement profile |
| Review Sample resource-profile correction | Both Review Sample commands now use `-Xmx1536m` and `--max-workers=1`, matching the hosted-green production shell. Focused workflow/retry tests pass 66/66, Actionlint passes, and the complete bounded Tools wall passes 312/312 with one intentional skip. | Required workflow structure, fail-closed classification, memory envelope, and repository controls agree locally | Hosted exact-SHA execution of the corrected Review Sample job |

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
- Commits before this replacement: initial implementation
  `68fb9fd5cfd0f2731917cee8b14f84e391b9128e`; initial operations record
  `c16488d70001bb3257c7c0c4d6644ab7f88d1372`; review-remediation implementation
  `4fcc134240a542694c5acc51a4d1487b074064bd`; prior evidence update
  `ce09fa67038865a35bc32698730953bd379d726f`; final SDK-export replacement
  `d8028186898b934f34ec50a98614f7e67d06d947`; final runtime-authority
  adoption `68a855cc191f3ab2f8a2aad04594441357603393`; prior reviewed SDK repin
  `ab6c5540dc5a55f9bec883b8fe47a3722d7bc280`; prior evidence head
  `8a8960e557d6e5dfa34e8352c56884e1a87d5a53`; final `44559ae` repin and
  worker-exit fence
  `3a7ba9e56ade2d5f5d7561d877e19c6cde272c65`. This record update is the
  remaining local evidence commit.
- Branch and remote state: PR `#17` is open from the dedicated branch at remote
  head `fbbb3b50`. Every hosted context except Review Sample is green; that job
  stopped twice on bounded host memory without test results. The smaller
  resource-profile correction remains local and requires a replacement push
  plus all exact-SHA protected checks.
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

- Focused Apple and Android app-target verification is green, including an API
  35 regression that holds a canceled worker in `NonCancellable` cleanup and
  proves teardown remains blocked until actual unwind. The Review Sample
  resource-profile replacement must pass every required hosted context on one
  exact SHA.
- A source-only adapter seam cannot establish that a supplier band is
  compatible or flashable.

## Next round

1. Commit the Review Sample resource profile, tests, and this evidence update,
   then push one replacement exact head.
2. Require every exact-SHA protected context, including the full Apple and
   Android app walls, then resolve remaining review threads from matching
   evidence.
3. Merge normally, verify protected `main`, and remove exact round-owned logs,
   DerivedData, exports, package scratch data, and the dedicated worktree.
4. Keep the supplier adapter/flasher disabled until the exact SDK, firmware,
   tooling, keys, rights, and representative physical bands pass their
   acceptance matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
