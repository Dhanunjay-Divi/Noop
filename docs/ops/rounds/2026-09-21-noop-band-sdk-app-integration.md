# Round: 2026-09-21 — NOOP Band SDK app integration

## Status

- State: `protected SDK PR 16 repin locally verified; exact-SHA hosted gates pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- Final SDK PR `#16` repin implementation commit:
  `e6a932f5accd8c2fc01b1778b52c3d7c0d1b932f`
- Record commit or PR: PR `#17`; final evidence commit and exact-SHA hosted
  verification remain pending

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
    `main` `277c628d5a1fd9e747871e777d908e41460802fa`;
  - protected SDK durability and terminal closeout through PR `#12` on `main`
    `bdeddf876af4a83c1f9607ea3b6345b969152ab4`;
  - ten-file export manifest with
    `supplierArtifactsIncluded: false`;
  - standalone Swift 39-test, Kotlin 44-test, 35-scenario cross-platform
    conformance, and 47-file repository-gate evidence;
  - existing Apple and Android single-active-source coordinators.
- Unknowns that must remain unknown until measured: exact supplier APIs and
  callbacks, protocol/device identity, disconnected flash depth and overwrite
  behavior, background collection, power use, radio timing, haptic/alarm
  behavior, firmware update/recovery, physiological accuracy, and
  redistribution rights for any future supplier binary.

## Delivered

- Re-exported the exact ten-file source artifact from private SDK `main`
  revision `277c628d5a1fd9e747871e777d908e41460802fa` twice from a clean
  worktree. Both artifacts were byte-identical; the manifest SHA-256 is
  `eb8ef2cf5b819f937732c7415c3618a42c5024d4325746e1ac7ac5ed3fd0ac7c`.
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
  platforms. The final protected correction makes `securityFailure` terminal
  to that session object and requires a newly constructed session before scan
  can restart.
- Added a release-control verifier that pins the export manifest, source
  repository/revision, every exported file digest and size, the executable
  Swift package definition, and the package test wrapper. It rejects symlinks,
  including a symlink supplied as the artifact root, unexpected top-level
  files, tree drift, and supplier binary/archive payloads.
- Closed the final P1 release-control bypass found on exact head `bdd8fe34`.
  Protected-base pull-request validation now executes the protected SDK
  artifact verifier against the isolated candidate checkout, independently of
  candidate-controlled test discovery. It also classifies Python standard
  library and startup-module shadows at the repository, `Tools`, and
  `Tools/tests` execution roots as protected trust paths, so a non-owner
  candidate cannot replace `unittest`, `json`, `pathlib`, `sitecustomize`, or
  an equivalent runtime module to suppress release tests.
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
- Repinned the app to protected SDK PR `#8` merge `277c628d`. Two independent
  clean exports were byte-identical with manifest SHA-256
  `eb8ef2cf5b819f937732c7415c3618a42c5024d4325746e1ac7ac5ed3fd0ac7c`.
  The artifact verifier and six adversarial tests pass, the vendored Swift
  package passes 15/15, and Android Full integration, Demo compilation, and
  Full instrumentation-source compilation pass.
- The first complete Tools rerun correctly rejected SwiftPM's generated
  `Vendor/NoopBandSDK/.build` symlink and the stale terminology snapshot.
  Removing only that generated cache restored all six artifact tests. A
  temporary terminology snapshot proved unchanged 17,869 occurrence and
  category totals, 1,588 path/category groups, and zero forbidden mappings;
  only six documentation line numbers changed. The reviewed snapshot and its
  trusted digest were repinned, the focused trust matrix passes 72/72, and the
  unchanged complete Tools wall passes 312/312 with one intentional skip.
- Repinned the final candidate to protected SDK PR `#9` merge `55fdd891`.
  Two independent clean exports are byte-identical with manifest SHA-256
  `2224b7543e0d74acd39214c8b84fd490e95917e95f564d96e9e621b7c9e422d0`
  and whole-tree digest
  `f57d62bf1313810382ec9b7ca8589765bea2244177b7f855f57f502a1fa7864a`.
  Invalid staging and acknowledgement tokens now emit one fixed
  `history/rejected/<typed category>` event on Apple and Android while leaving
  the current history operation intact.
- Added mirrored app-repository regressions for superseded same-session and
  foreign-session tokens across both history APIs. Android Full integration
  passes 6/6 and the real macOS app target passes 6/6; each permits the valid
  token to finish normally. Demo and Full instrumentation-source compiles also
  pass.
- Strengthened the API 35 feedback continuity execution probe to count attempts
  per WorkManager UUID. A retry that reuses the same UUID can no longer be
  mistaken for a quiescent worker; the managed-device class passes 7/7.
- Repinned the final application candidate to protected SDK PRs `#10` and
  `#11`, merged at `c254cb3`. The final SDK adds bounded collection snapshots,
  distinct staged-versus-durable history diagnostics, integral step counts,
  lifecycle-first malformed-input rejection, and direct iterator-failure
  coverage. Two clean exports are byte-identical; the manifest SHA-256 is
  `2224b7543e0d74acd39214c8b84fd490e95917e95f564d96e9e621b7c9e422d0`
  and the whole-tree digest is
  `f57d62bf1313810382ec9b7ca8589765bea2244177b7f855f57f502a1fa7864a`.
  The app verifier passes 6/6, the vendored Swift package passes 15/15 across
  all 34 automated scenarios, Android Full integration passes 6/6 with Demo
  and instrumentation sources compiled, and the final API 35 feedback class
  passes 8/8.
- Repinned the closeout candidate to protected SDK PR `#12`, merged at
  `bdeddf876af4a83c1f9607ea3b6345b969152ab4`. Two independent clean exports
  were byte-identical with manifest SHA-256
  `31f4a8fef6ad500d445bf8804a22a57b61b6b0409fc589c39db5c472fece2553`
  and whole-tree digest
  `a98be76838877520ee8f5e9b5ef97b85ded592025129fa7c2df6525be51dd041`.
  The closeout serializes live/history durable receipts, adds
  generation-fenced capability cancellation and failure, blocks destructive
  lifecycle transitions while persistence is unresolved, and invalidates
  authenticated state after operation authentication failure. The exact
  artifact verifier passes 21 focused tests; the vendored Swift package passes
  15/15 across all 35 automated scenarios; Android Full integration passes
  6/6; Demo and Full instrumentation sources compile; and the real macOS app
  target passes 6/6 with WHOOP still the default transport.
- Repinned the final candidate to protected SDK PR `#13`, merged normally at
  `8fb464471fdd4ae09d5750feedcc25d50bdb1c20`. The protected SDK now returns
  exact provenance-bearing accepted history rows, exposes immutable accepted
  live/history collections on Android, bounds restored checkpoint traversal
  before iteration, and validates live/history durable receipts against an
  independent staged count. Swift passed 40/40, Kotlin passed 47/47 plus
  distribution, shared conformance passed 35/35, and the 48-file repository
  gate passed before merge.
- Exported protected SDK `8fb4644` twice from independent clean worktrees. The
  outputs were byte-identical with manifest SHA-256
  `abc87fb3a6bb91e013af7dc458a49710bfa9fb56cb8e19013b4ab7cb67571cf9`
  and source-tree digest
  `cd371c1e2ff91a0981182208a7520fc11340e6ffcbaf3121359eb9961e92da4e`.
  The app-owned Swift wrapper is separately pinned at
  `e335df14a588ac080de13ab98a4fe77802eb4e9610e6f4d4bd554e8310fa5f28`.
- Repinned the then-current candidate to protected SDK PR `#14`, merged normally at
  `7794bae631c1704e18ae5c341fbc32e89c9dc647`. Two independent clean exports
  were byte-identical with manifest SHA-256
  `57be20aafa317e2d846521ab54c91bd109fadd27911336b503a44bfad6e15eb0`.
  The app-owned Swift wrapper is independently pinned at
  `571637a0f0458155aae1166b875ae42f30c2bc3a63bc3cc95e2180b5cb24a365`.
  The closeout binds callbacks to the exact selected candidate, records
  connection completion before authentication, coalesces routine successful
  live evidence, revalidates Swift operation ownership after actor suspension,
  terminates established authentication/security failures, and retains a
  durable cursor across a terminal nil-cursor chunk.
- Repinned the current candidate to protected SDK PR `#15`, merged normally at
  `a8f94b5cbda329eaf7793c5a2cece94fb568acc0`. Two independent clean exports
  were byte-identical with ten-file manifest SHA-256
  `670919a8009d41bd1ee9e8ddd141eb918c09dff8cd7a9d225f3202f3d6076e2e`.
  The app-owned Swift wrapper is independently pinned at
  `b0a315f1c62107ed8c079ee6dcd3c6ab6efa549300642b18caf2840913a8425c`.
  Export-manifest schema `1` remains unchanged while capability schema `2`
  separates `liveStreams` from `historyStreams`, carries retained and
  first-lost overflow ranges through the exact durable receipt, preserves
  pending persistence across established-session failures, and revalidates
  scan authority after the Apple diagnostics suspension. SDK verification
  passed Swift 51/51, Kotlin 55/55 plus distribution, shared conformance 35/35,
  and the 51-file repository gate.
- Repinned the replacement candidate to SDK PR `#16`, merged normally at
  `a486768efb873b57515926740d3efa19787de612`. Two independent clean exports
  were byte-identical with ten-file manifest SHA-256
  `703f7eff73298acbf4098b31a9e1a7b50b9a8579515cfd596476f00cace6755f`
  and aggregate eleven-file export-tree SHA-256
  `fb1ec8080b2ddce6ceb1e2e56f8d855afbdbef80ca24de5172b5e3c5af306662`.
  The closeout validates retained sample bounds and circular-loss chronology,
  rejects history streams with zero retained history, and distinguishes
  recoverable from terminal firmware failure. SDK verification passed Swift
  52/52, Kotlin 56/56 plus distribution, shared conformance 36/36, and the
  52-file repository/schema gate. Independent final review found no P0-P2
  issue.
- Hardened the app artifact verifier so a symlink in any supplied artifact
  path ancestor is rejected before resolution. All 8 adversarial verifier
  tests pass, including symlinked `Vendor` and parent-directory cases.
- Verified the final app repin: the vendored Swift package passes 15/15 while
  checking all 36 shared scenarios; Android Full integration passes 10/10;
  Android Demo plus Full and Demo instrumentation sources compile; and the
  real macOS app target passes 9/9. The unsigned Release iOS simulator graph
  builds with `NOOPWatch.app` and `NOOPWidgets.appex` embedded.
- Reviewed exact hosted PR `#17` head `fe800e8e` after its final Apple job
  completed. Every Android, macOS, server, package, policy, localization,
  claims, license, operations, and trust job passed. The iOS production shell
  executed 39 tests and failed only
  `testAppReportRequiresConsentAndBuildsPrivateAttachmentReview`: after the
  long review page scrolled to its send button, the shorter queued page kept
  that stale scroll offset, leaving its queued title and cancel control
  off-screen. The sheet now scrolls to a stable top anchor on every phase
  transition, and the UI test waits for the existing delivery identifier plus
  asynchronous dismissal. The exact previously failing test passes 1/1 on a
  fresh iPhone 17e simulator in 16.098 seconds.
- Re-ran that exact UI journey after replacing the deprecated iOS 17
  `onChange` callback shape. It passes 1/1 in 15.841 seconds, and a subsequent
  complete unsigned iOS graph succeeds with no source warnings while retaining
  the embedded Watch and widget products.
- Reviewed and repinned the final generated terminology inventory after this
  evidence update. The semantic totals and categories remain unchanged with
  zero forbidden mappings. The focused artifact, required-CI, terminology, and
  trusted-release suite passes 77/77; trusted self-verification and all ten
  required contexts pass, and the then-current ten-file SDK artifact verified
  with supplier payloads absent. The exact-current
  complete Tools wall passes 317/317 under the bounded runner.
- Re-ran the workflow entrypoints directly. Release controls pass 9/9;
  the exact release-workflow unit matrix passes 203/203;
  calibration parity covers 12 metrics, 3 revisions, 13 thresholds, and 16
  guards; health-claims scans 1,299 files; legal inventory verifies 230 runtime
  components and 3 container inputs; distribution provenance, private-data,
  shell syntax/ShellCheck, workflow lint, Python compilation, operations
  records, and diff hygiene pass. The full localization audit confirms no
  translated-key gaps in supported catalogs while retaining the reviewed
  current inventory of 244 Android and 135 Apple hardcoded literals as explicit
  debt.

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
| Private SDK final remediation | PR `#8` merged normally at `277c628d`; Swift 32/32, Kotlin 35/35, 33 shared scenarios, and the 43-file repository gate passed | Security failure is terminal to the issuing session object and recovery requires a replacement session | Supplier API compatibility or physical behavior |
| Independent clean exports | Two clean-worktree exports were byte-identical; manifest SHA-256 `eb8ef2cf5b819f937732c7415c3618a42c5024d4325746e1ac7ac5ed3fd0ac7c` | The vendored artifact is deterministic and traceable to `277c628d` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Protected SDK history observability | PR `#9` merged normally at `55fdd891`; Swift 33/33, Kotlin 36/36 plus distribution, 33 shared scenarios, and the 44-file repository gate passed | Invalid history tokens fail closed with bounded typed diagnostics on both SDK implementations | Supplier API compatibility or physical behavior |
| Current independent clean exports | Two clean-worktree exports were byte-identical; manifest SHA-256 `703f7eff73298acbf4098b31a9e1a7b50b9a8579515cfd596476f00cace6755f`, aggregate eleven-file export-tree SHA-256 `fb1ec8080b2ddce6ceb1e2e56f8d855afbdbef80ca24de5172b5e3c5af306662`, and app wrapper digest `2704fd896899bfca64de46ea8b10ef64a7ca7dff6ea6ebe6f30196ac8733d8c7` | The current vendored artifact is deterministic and traceable to protected SDK `a486768e` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Current protected SDK app repin | SDK Swift 52/52, Kotlin 56/56 plus distribution, shared conformance 36/36, and repository/schema gate 52/52 passed before PR `#16` merged. App verifier 8/8, vendored Swift 15/15, macOS app boundary 9/9, and Android Full app boundary 10/10 pass; Demo plus Full and Demo instrumentation sources compile. | Scan ownership, pending-persistence fencing, lane-specific stream authorization, mutable capability snapshotting, overflow-gap durability, retained-history bounds, and terminal firmware failure are consumed while WHOOP remains the default comparison transport | Supplier transport invocation or any physical-device behavior |
| Artifact verifier plus unit tests | Exact ten-file export passed; 8/8 verifier tests passed, including rejection of a symlink artifact root and symlinked path ancestors; no supplier artifacts found | Source, manifest, package wrapper, exact layout, complete path/tree symlink policy, and no-binary policy are pinned | Physical compatibility |
| Protected-base artifact authority | 70 focused release/trust tests pass; a copied artifact with a one-line source mutation is rejected by the protected verifier; non-owner `unittest` and standard-library shadow paths are rejected; the complete Tools wall passes 315 tests with one intentional skip | Future non-owner candidates cannot satisfy the SDK artifact gate by shadowing Python's test runner or by relying only on candidate-controlled tests | Owner authorization, hosted exact-SHA execution, supplier rights, or physical compatibility |
| Exact Swift package workflow order | The vendored package completed 15/15 tests and checked all 36 automated exported scenarios; the exact artifact verifier then passed after generated package output was removed | SwiftPM agrees with the shared contract without leaving generated files inside the verified source tree | App lifecycle, BLE, background, or hardware behavior |
| Android Full app boundary | `NoopBandSdkIntegrationTest` passed 10/10 under `testFullDebugUnitTest`, including all 36 automated shared scenarios, pending live-persistence fencing, independent live/history stream authorization, overflow range receipt propagation, mutable stream-set snapshotting, retained-history bounds, terminal firmware failure, and all four invalid-history-token combinations | Full-variant app source and capability schema v2 compile and pass through the public application boundary | Instrumentation runtime, OEM background, BLE, or physical behavior |
| Android Demo and instrumentation compile | `compileDemoDebugKotlin`, `compileFullDebugAndroidTestKotlin`, and `compileDemoDebugAndroidTestKotlin` passed against the PR `#16` export | Both Android source graphs consume capability schema v2 successfully | Runtime rendering, managed-device execution, or physical behavior |
| Current iOS, Watch, and widget graph | The unsigned Release `NOOPiOS` simulator graph built successfully under the bounded runner. Xcode embedded and validated `NOOP.app/Watch/NOOPWatch.app` and `NOOP.app/PlugIns/NOOPWidgets.appex`. | The current PR `#16` SDK repin compiles across the iPhone, Watch, complication, and widget graph | Signed-device runtime, BLE, background execution, notification delivery, or physical behavior |
| Android memory classification | One combined Full+Demo invocation let the two Compose compilers overlap and exhausted a 3 GiB Kotlin heap; separate no-daemon, no-parallel, two-worker commands passed | The failure was an avoidable verification command shape, not a source failure; variant walls must stay sequential | Every future machine configuration |
| Hosted production-shell diagnosis | PR `#17` run `35643099439` started 120 API 35 tests; 116 passed, two App Report cases timed out before their explanation sheets appeared, and the retained result protobuf contained real test cases | The red required context was a real cross-test state leak, not a zero-test infrastructure event or SDK behavior failure | The local correction until rerun on the protected exact SHA |
| Feedback cleanup instrumentation regression | Full instrumentation source compiled, then six continuity cases followed by all eight AppShell cases passed 14/14 on `pixel2Api35` in 1m42s | Terminal WorkInfo alone cannot release teardown; actual worker/probe unwind and a stable no-new-generation snapshot are required before deleting the exact record, and the report sheets still open afterward | The complete hosted production-shell wall or physical Android behavior |
| Apple app boundary | Xcode 27 focused macOS test passed 9/9 in the real app target, including WHOOP-default routing, source-scoped restore, pending live persistence fencing, lane-specific stream authorization, overflow range receipt propagation, bounded failure categories, and all four invalid-history-token combinations. The scan-suspension race is directly covered by the SDK's deterministic actor test because its suspension hook is intentionally internal to the SDK module. | The real Apple app target consumes capability schema v2 without changing default routing | Signed-device runtime, BLE, background, Watch/widget runtime, or hardware behavior |
| Bounded disk exception and cleanup | The final Apple rerun reused its integration-only package cache with a 5.5 GiB hard floor after measuring 8.2 GiB free; the real app test passed 5/5, the exact DerivedData reached 2.8 GiB, and its removal restored free disk from 6.9 GiB to 9.3 GiB | The final Apple test ran under explicit memory/disk bounds without touching the concurrent UI worktree, while round-owned disk use returned immediately | Future host capacity without the same preflight and cleanup |
| Final repository policy wall | The terminology inventory and protected digest were repinned after unchanged counts/categories and zero forbidden mappings were reviewed. The first post-repin complete Tools run then found one bounded-runner self-test timing transient: a 50 ms post-spawn deadline returned `126` instead of timeout `124`. The isolated case passed once plus five repeats with no leaked process, and the unchanged complete wall passed 312/312 with one intentional skip. Required-CI verifies 10 contexts, and trusted self-check, terminology, operations, artifact, bounded-runner, and diff gates pass. | The exact local candidate satisfies the repository-controlled release, trust, privacy, terminology, operations, artifact, and process-cleanup contracts | Hosted exact-SHA enforcement or protected integration |
| Resource-floor correction | The first 312-test Tools wall had four bounded-runner failures because nested tests correctly enforced their 10 GiB default while the host had 9.3 GiB free. With no build processes active, deleting only generated Xcode precompiled-module and module caches restored 11 GiB; the unchanged wall then passed 312/312 with one skip | The failures were environmental and the runner remained fail-closed; generated cache cleanup restored the test precondition without source or test changes | Future host capacity without the same disk preflight |
| Final terminology and claims gates | 17,871 classified occurrences across 1,588 groups with unchanged category totals and zero forbidden mappings; health-claims scanned 1,299 files; complete localization audit passed with zero translated-key gaps in supported catalogs and retained the current 244 Android/135 Apple hardcoded-literal inventory | The reviewed terminology snapshot, health wording guard, and translation catalogs remain coherent without hiding the existing literal backlog | Physical accessibility, resolution of every pre-existing hardcoded literal, or medical accuracy |
| Previous remote candidate | PR `#17` head `c16488d7` passed every applicable hosted app, policy, trust, package, server, and release context before review remediation | The pre-remediation integration graph was hosted-green | The unpushed remediation candidate; new exact-SHA checks remain required |
| Final pre-repin hosted candidate | PR `#17` head `abd54fbd` passed macOS, iOS production shell, Apple required, Android build/unit, Android Review Sample, server/package/policy/trust jobs, and automated review. Release controls failed only on four shifted inventory line numbers. Android production shell stopped before tests with bounded `resource-memory` and no result files. | The final SDK source and app graph compile and pass every hosted wall that executed tests; the two red jobs are precisely classified and retained | A passing replacement exact-SHA Android production shell or release-control job |
| Managed-device retry diagnostic correction | `test_android_managed_device_retry` passes 17/17, Actionlint passes, required-CI verifies all ten contexts, and trusted self-check passes | Resource-pressure stops remain fail-closed, while retry announcements occur only after classifier approval | Whether the next hosted runner has sufficient memory to execute the emulator wall |
| Exact-head hosted resource classification | PR `#17` head `fbbb3b50` passed every hosted context except Review Sample. Run `35681052415` attempt 1 job `106598021250` and attempt 2 job `106602308597` each completed APK preparation, entered the emulator task, then stopped with bounded `resource-memory`; retained evidence has no test-result records. | The two failures are reproducible hosted-runner resource stops, not hidden assertions or product failures | A passing Review Sample execution on the replacement profile |
| Review Sample resource-profile correction | Both Review Sample commands now use `-Xmx1536m` and `--max-workers=1`, matching the hosted-green production shell. Focused workflow/retry tests pass 66/66, Actionlint passes, and the complete bounded Tools wall passes 312/312 with one intentional skip. | Required workflow structure, fail-closed classification, memory envelope, and repository controls agree locally | Hosted exact-SHA execution of the corrected Review Sample job |
| Hosted iOS app-report transition correction | Exact head `fe800e8e` passed every hosted context except the iOS production shell, whose only failing case retained the review page's scroll offset after entering the queued phase. The corrected exact case passes 1/1 in 16.098 seconds on a fresh iPhone 17e simulator and 1/1 in 15.841 seconds after the iOS 17 callback correction. The complete unsigned iOS graph then builds with zero source warnings and embeds Watch/widgets. | The queued status, cancellation control, and sheet dismissal are visibly reachable after a long review-page scroll; the correction compiles in the real iOS UI-test graph without a deprecated source API | Replacement exact-SHA hosted execution, physical shake behavior, or production feedback delivery |
| Final app-report trust wall | The reviewed terminology snapshot is repinned with unchanged semantic totals and zero forbidden mappings. Focused artifact, required-CI, terminology, and trust tests pass 77/77; the exact-current complete Tools wall passes 317/317; the exact release-workflow matrix passes 203/203; trusted self-check, ten required contexts, operations validation, diff hygiene, exact SDK artifact verification, 9/9 release controls, legal/distribution/private-data, calibration, health-claims, shell, and localization gates pass. | The SDK repin, verifier hardening, and narrow UI correction did not weaken protected release, privacy, claims, metric, localization, or artifact contracts | Hosted exact-SHA enforcement, physical accessibility, or protected integration |

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
  `3a7ba9e56ade2d5f5d7561d877e19c6cde272c65`; protected SDK `bdeddf8`
  repin and release-control update
  `8fb07e3179ebb314b570da56784586552eb1e465`; Android boundary provenance
  alignment `4388058c09130d371c05d86a725c3bddb1354524`; final protected SDK PR `#16`
  repin, verifier hardening, callback correction, and reviewed evidence
  `e6a932f5accd8c2fc01b1778b52c3d7c0d1b932f`.
- Branch and remote state: PR `#17` is open from the dedicated branch. Remote
  head `44e48a7d377918ff93772983ded53bd252120016` predates SDK PR `#16`.
  Its superseded Apple workflow was deliberately canceled after the new SDK
  findings were confirmed. The replacement artifact,
  complete path-symlink
  defense, app-boundary regressions, and iOS callback correction are locally
  green and require one replacement push plus all exact-SHA protected checks.
- Repository visibility verified on 2026-09-22:
  `Dhanunjay-Divi/Noop` and `Dhanunjay-Divi/NoopBandSDK` both report `PUBLIC`
  with default branch `main`. D-056 still requires the SDK repository to be
  private before release.
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
  proves teardown remains blocked until actual unwind. The final
  protected-base release-control correction passes 77 focused tests and the
  complete 317-test Tools wall. The consolidated
  replacement candidate must still pass every required hosted context on one
  exact SHA.
- A source-only adapter seam cannot establish that a supplier band is
  compatible or flashable.

## Next round

1. Regenerate and review the terminology snapshot after this final evidence
   edit, rerun its focused trust gates, commit the final evidence update, then
   push one final exact head.
2. Require every exact-SHA protected context, including the full Apple and
   Android app walls, then resolve remaining review threads from matching
   evidence.
3. Merge normally, verify protected `main`, and remove exact round-owned logs,
   DerivedData, exports, package scratch data, and the dedicated worktree.
4. Restore the SDK repository to the D-056 private visibility before release.
5. Keep the supplier adapter/flasher disabled until the exact SDK, firmware,
   tooling, keys, rights, and representative physical bands pass their
   acceptance matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
