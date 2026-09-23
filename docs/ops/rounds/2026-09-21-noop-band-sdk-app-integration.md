# Round: 2026-09-21 — NOOP Band SDK app integration

## Status

- State: `final public-source handoff locally green; push and hosted checks pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- Prior SDK PR `#16` repin implementation commit:
  `e6a932f5accd8c2fc01b1778b52c3d7c0d1b932f`
- Final SDK PR `#19` repin implementation commit:
  `90b6bbd021dea1621a17e554edda953619cd1c91`
- Final SDK PR `#20` app repin implementation commit:
  `9dd4698c647bb44286a895abad23084d6ea57431`
- Final SDK PR `#21` app repin implementation commit:
  `5da77db5d929df7cbce73d7e64a8eab935cc0103`
- Final SDK PR `#22`, `#23`, and `#24` app repin implementation commit:
  `0a8b3a7a17848ca5c2ee15228ef6e2726813c44c`
- SDK PR `#25` app repin implementation commit:
  `1be4062c054b210187f4c48f2ab99dd59873923e`.
- SDK PR `#26` final source replacement: included in the consolidated app PR
  `#17` closeout candidate.
- Pre-remediation PR `#17` evidence commit:
  `78eba788b337c3472d32f8bd789965f84ef67b8a`
- Final runtime and SDK-repin candidate:
  `e12b71fb55d620a642ef340c4503b4b15970091c`
- Record commit or PR: app PR `#17`, remote app head
  `6d3b54a01ed6fd7e741e721aa6ff467d3b6bfcb4`; SDK PR `#31` upstream merge
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`. The source-only app artifact
  and provenance pins consume that exact merge. Exact local app, simulator,
  and onboarding verification are green; final repository-control verification
  follows this documentation repin. Independent final review found no P0/P1
  blocker. The remote head passed every hosted context
  except one iOS profile-entry UI assertion; its narrow local correction passes
  three focused executions. One follow-up push, replacement hosted exact-SHA
  checks, protected integration, and protected-main verification remain.

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

- Repinned the app to SDK PR `#29`, merged normally at
  `38cf7de3b1c92dd30dad343af2adfa2cb61dea2e`. Two independent clean exports
  are byte-identical; the ten-file manifest SHA-256 is
  `5df5d94235f39ec806b6998581656cdf2f5c479451933fe8ebf95583ce8cad8e`,
  and the app-owned test-wrapper SHA-256 is
  `476582712df3456c142e4924e5d9aff30d7b430e33bb09dc96bb3d9020803ec5`.
  Upstream Swift passes 91/91, Kotlin/JVM passes 99/99 plus `installDist`, all
  50 shared conformance scenarios match, and the 67-file repository policy
  gate passes. Exact-current app evidence passes the 9-test artifact wall,
  vendored Swift 16/16, macOS app boundary 10/10, Android Full and Demo
  integration 15/15 each, both Android instrumentation source graphs, and the
  unsigned Release iPhone/Watch/complication/widget graph with zero source
  warnings/errors.
- Repinned the app to SDK PR `#28`, merged normally at
  `f8185b753b9e3672e78c7f3ee7596aeae7d53234`. Two independent clean exports
  are byte-identical; the ten-file manifest SHA-256 is
  `1346cce862a5ecbe6dd4b29060c7ed239c918fd332a0c49808b7eec3a8bbc98b`.
  Upstream Swift passes 83/83, Kotlin/JVM tests and `installDist` pass, all 50
  shared conformance scenarios match, and the 66-file repository policy gate
  passes. The app-owned revision/hash boundaries are updated; replacement app
  verification remains pending.
- Repinned the app to SDK PR `#27`, merged normally at
  `586a5c04bd3edbd445895a881c5d4faa78fb526e`. Two independent clean exports
  are byte-identical; the ten-file manifest SHA-256 is
  `f85eea6bd66bfe902d6ce89fef46f13a97d3621c1035bab537eca6cc95b35c73`.
  All 29 public synchronized Kotlin session entries reject while
  caller-owned supplier collections are being traversed, preventing
  reentrant close/disconnect mutation through JVM monitor reentrancy.
  Upstream Kotlin passes 86/86 plus `installDist`, Swift passes 75/75, all 46
  shared scenarios match, and the 64-file repository policy gate passes.
  The app artifact verifier passes 9/9 and the exact Android app integration
  class passes 15/15, including unchanged state, fixed bounded diagnostics,
  and continued live-session usability after reentrant close/disconnect
  rejection.
- Repinned the app to protected SDK PR `#26`, merged normally at
  `eb5d6d4c6171efaa87a8e36a3c4ba3906efbfb2c`. Two independent exports are
  byte-identical; the source-only manifest SHA-256 is
  `31a791b15fe3ffa5dea1a4416bd82a3b6e0eff0cfcb37c90d33732a2443f5b32`
  and the SDK artifact test-wrapper SHA-256 is
  `1d9f71d65fe7b9f4637c85645cecfd2187b8c8950aeceaa023c59bb85d821304`.
  Exact connection/live tokens, exact reconnect-interruption authority, opaque
  one-use reconnect authority, scan-only firmware recovery, and stale
  reconnect-token invalidation are exercised across 46 shared scenarios. The
  app-repository Swift package regression still suspends reconnect
  diagnostics, starts live collection while the session actor is reentrant,
  and proves the returned connection token remains usable.
- Current app evidence is green: artifact verifier and adversarial suite 9/9,
  vendored Swift package 16/16, macOS app boundary 10/10, complete macOS
  2,228 tests with one intentional skip, Android Full boundary 14/14 plus Demo
  and both instrumentation-source compiles, iOS production shell 39 tests with
  one intentional skip, and unsigned Release
  iPhone/Watch/complication/widget embedding validation. The complete Tools
  wall passes 318/318 with one intentional skip; required-CI, trusted
  self-verification, calibration, distribution, private-data, health-claims,
  localization, operations, workflow lint, and diff gates pass.
- Removed only generated round-owned caches after evidence capture: vendored
  SwiftPM output, 3.2 GiB macOS DerivedData, and 5.1 GiB iOS DerivedData.
  Separate UI-round cleanup removed 10 GiB of ignored build output without
  changing its dirty source paths.
- Historical PR `#25` app repin was committed at
  `1be4062c054b210187f4c48f2ab99dd59873923e` and pushed its final reviewed
  evidence at `b21d8b72288678668ff17d1e365b9abace42c0ef`. PR `#26` supersedes
  that source and requires one consolidated app commit/push plus replacement
  exact-head hosted checks and review before protected integration.
- Independent exact-diff review found no P0/P1. Its three P2 findings are
  corrected locally: the app package now directly exercises reconnect actor
  suspension, PR `#24` table rows are explicitly historical, and the pinned
  digest is labeled as the SDK artifact test wrapper.
- Final dirty-diff review found no P0/P1 and three P2s. The app now proves that
  a same-session field-identical forged Android reconnect token cannot resume
  recovery while the issued token remains usable. The release checklist also
  reopens `MOB-250` because Apple permission/unavailable states are incomplete,
  and reopens `DAT-020` because local-retention approval and per-data-class
  migration gates remain open. The Android integration class passed 14/14 in a
  fresh 29-task `--rerun-tasks` build.
- Final post-review evidence passes: vendored Swift package 16/16, artifact
  verifier 9/9, complete Tools wall 318/318 with one intentional skip, exact
  release-workflow matrix 204/204, nine release controls, ten required
  contexts, trusted self-verification, calibration parity, distribution
  provenance, private-data guard, operations validation, and diff hygiene.
- The first final Tools wall correctly failed because generated
  `Vendor/NoopBandSDK/.swiftpm` output violated the exact artifact shape.
  Removing only that generated directory made the focused artifact/trust wall
  pass 24/24 and the unchanged complete wall pass 318/318 with one intentional
  skip.
- The documentation-closeout rerun exposed the same fail-closed class through
  a transient generated `Vendor/NoopBandSDK/.build/debug` symlink: two trust
  tests stopped before assertions. After the generated cache disappeared, the
  focused trust suite passed 15/15, the unchanged `Tools/tests` wall passed
  318/318 with one intentional skip, and the separate top-level i18n suite
  passed 50/50.
- Packaged an unsigned local iOS test artifact after the successful Release
  graph as `NOOP-ios-unsigned-v9.2.1-b231-9095b6b04444.ipa`, SHA-256
  `57cdcc7b2a7d5300132c28a959b95c87976bdd2e329081f13be0b7b649021cc5`.
  It is not signed, uploaded, or presented as a release artifact.

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
- Repinned the final app candidate to SDK PR `#19`, merged normally at
  `823930fa16d30ea7849a557823215c913a36fb8b`. Two independent exports from
  the exact clean merge were byte-identical with ten-file manifest SHA-256
  `ed338ff50e026ce2f9326ef6b1aa854766c33f7f886177da21c776f6196719fc`
  and aggregate eleven-file export-tree SHA-256
  `ed08f2caf393649d9af106e8c8dd4878aab544e3e166231806da91634b0082fa`.
  The app-owned Swift test wrapper is independently pinned at
  `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3`.
  SDK verification passed Swift 55/55, Kotlin 62/62 plus distribution, shared
  conformance 38/38, and the clean 55-file repository gate. The final SDK
  additionally publishes each platform's ordered automated-scenario list and
  fails closed when either platform differs from the canonical contract.
- Fresh review of app PR `#17` found that a malformed delayed Kotlin capability
  snapshot could move an already ready session to `INCOMPATIBLE`, plus one
  release-plan paragraph that still called SDK PR `#16` current. The SDK defect
  was corrected and merged normally through SDK PR `#20` at
  `9bc2eedce34c61d49f68001a973fbbda793d04ed`; its exact regression preserves
  the ready snapshot, records the existing bounded
  `capability/rejected/invalidInput` diagnostic, and proves live collection can
  still begin. SDK verification passed Swift 55/55, Kotlin 63/63 plus
  distribution, shared conformance 38/38, and the clean 56-file repository
  gate.
- Exported SDK `9bc2eedc` twice from independent clean worktrees. The outputs
  were byte-identical, contained eleven regular files and no symlinks, and had
  manifest SHA-256
  `150c3d918b23a27fb49da701e0021f718fba6b2384943fa736cade08ac4b5c53`
  plus aggregate export-tree SHA-256
  `6f7707d3c45089ac2b3be3a0bce9991bb0a03cb12d168f4b27523934d44e4ef7`.
  The app-owned Swift wrapper remains independently pinned at
  `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3`.
- Repinned app PR `#17` to SDK `9bc2eedc` and added the upstream late-callback
  behavior as a direct Android app-module regression. The artifact verifier
  passes 9/9; the vendored Swift package passes 15/15; Android Full integration
  passes 12/12; Android Demo plus Full and Demo instrumentation sources compile;
  and the real macOS app target passes 10/10. The unsigned Release iOS simulator
  graph builds with `NOOPWatch.app` and `NOOPWidgets.appex` embedded.
- SDK PR `#21` merged normally at
  `a9d3f1a2a55b5436bf1b65b0299a27667241afa4` after exact-head review. It
  normalizes hostile Kotlin collection size failures, preserves a restored
  checkpoint across an intervening source, and adds generation-fenced graceful
  disconnect with bounded cancellation evidence for active live and history
  work. Upstream verification passed Swift 60/60, Kotlin 66/66 plus
  `installDist`, shared conformance 40/40, and the clean 57-file repository
  gate.
- Exported SDK `a9d3f1a2` twice from independent clean worktrees. The complete
  source trees are byte-identical, contain eleven regular files and no
  symlinks, and have manifest SHA-256
  `72e9a93f35f01ad9aa8d1975ec4a1beb76d96cf068e27553a08c0ceef01cc571`.
  The app-owned Swift wrapper remains independently pinned at
  `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3`.
- Repinned app PR `#17` to SDK `a9d3f1a2`. The artifact verifier and adversarial
  suite pass 9/9; the vendored Swift package passes 15/15 across all 40
  automated scenarios; Android Full integration passes 12/12 after correcting
  its stale 38-scenario assertion; Android Demo plus Full and Demo
  instrumentation sources compile; and the real macOS app target passes 10/10.
  The unsigned Release iOS simulator graph builds with `NOOPWatch.app` and
  `NOOPWidgets.appex` embedded.
- SDK PR `#22` merged normally at
  `1883ad33e840b1aa8b257f4f601f299f883678ca` after final independent review.
  It binds discovery callbacks to an opaque session-and-generation token,
  bounds hostile Kotlin set traversal by iterator steps, and rejects history
  operations unless retention and at least one history stream were
  negotiated. Upstream verification passed Swift 62/62, Kotlin/JVM tests plus
  `installDist`, shared conformance 41/41, the clean 58-file repository gate,
  JSON/diff/secret checks, and a corrected-diff review with no remaining P0-P2
  findings.
- Exported SDK `1883ad33` twice as complete source trees. Both 58-file exports
  contain no Git metadata and produce identical archive SHA-256
  `5eb3e30db3282907ba26432254d3bd2053349f645fe28549097ade3efb72ed8f`.
  The app's exact ten-file source export has manifest SHA-256
  `7299684795367f8e20c488777626ff5988abae72d2264d8ac081878d909ae973`;
  its app-owned Swift wrapper is independently pinned at
  `b24cb6b607710f867d96a3ea5d3c794b3d7517073b995acadfe750153d24d815`.
- Repinned app PR `#17` to SDK `1883ad33`. The artifact verifier and adversarial
  suite pass 9/9; the vendored Swift package passes 15/15 across all 41
  automated scenarios; Android Full integration passes 12/12; Android Demo and
  Full/Demo instrumentation sources compile; and the real macOS app target
  passes 10/10. The unsigned Release iOS simulator graph builds with
  `NOOPWatch.app`, `NOOPWatchComplications.appex`, and `NOOPWidgets.appex`
  embedded and validated. All heavy builds ran sequentially through the
  bounded runner. The 3.2 GiB macOS DerivedData, 5.1 GiB iOS DerivedData, and
  generated vendored SwiftPM caches were exact-deleted after evidence capture,
  restoring 22 GiB free disk; the artifact verifier passes after cleanup.
- Reviewed and repinned the current terminology inventory after the SDK and
  operations changes. It retains 17,872 occurrences across 1,588
  path/category groups, byte-identical category totals and active allowlist,
  and zero forbidden mappings; only eight historical/persisted line-position
  records changed. The current complete Tools wall passes 318/318 with one
  intentional skip, and the exact protected release matrix passes 204/204.
  Direct release controls, all ten required contexts, trusted self-check,
  artifact verification, calibration parity, terminology, distribution
  provenance, private-data, health-claims, localization, operations records,
  shell syntax/ShellCheck, Actionlint, Python compilation, and diff hygiene all
  pass.
- SDK PR `#23` merged normally at
  `1b4c614e180a58130c3d1c5967841affe754242d`. The correction retains the exact
  Kotlin scan token issued by `beginScan`, requires reference identity for
  every scan callback in addition to nonce and generation, and clears the
  retained authority after selection or a terminal scan path. This closes the
  same-module authority gap created by compiling the source-only SDK directly
  into the Android app module.
- Upstream PR `#23` verification passed Swift 62/62, complete Kotlin/JVM tests
  plus `installDist`, shared conformance 41/41, the clean 59-file repository
  gate, and diff hygiene.
- Exported the exact PR `#23` app-source artifact twice. The two ten-file
  source exports are byte-identical and have manifest SHA-256
  `539ec7ab2c5906ea64ab98bb1be0f5ceb70f5ffbf9e0911b5b91cbf0b56e7bc7`.
  The app-owned Swift wrapper remains independently pinned at
  `b24cb6b607710f867d96a3ea5d3c794b3d7517073b995acadfe750153d24d815`.
- Repinned app PR `#17` to SDK `1b4c614e`. The artifact verifier and
  adversarial suite pass 9/9; the vendored Swift package passes 15/15 across
  all 41 automated scenarios; Android Full integration passes 13/13, including
  a direct same-module forged-token rejection while the issued token remains
  usable; Android Demo and Full/Demo instrumentation sources compile; and the
  real macOS app target passes 10/10. The unsigned Release iOS simulator graph
  builds with `NOOPWatch.app`, `NOOPWatchComplications.appex`, and
  `NOOPWidgets.appex` embedded and validated. Heavy builds ran sequentially
  through the bounded runner. The vendored SwiftPM cache was exact-deleted and
  the artifact verifier passes again; isolated Apple DerivedData cleanup
  remains pending after the final evidence refresh.
- SDK PR `#24` merged normally at
  `f20f4ed552328a64a8a598aaac72befa1d481262` after corrected-diff review.
  Apple now consumes the exact issued scan token before the candidate-selection
  diagnostics suspension. A deterministic actor test pauses at that suspension
  boundary, proves late selection, cancellation, and failure callbacks are
  already stale before the original selection returns, then proves the issued
  connection token remains usable. Upstream verification passed Swift 64/64,
  Kotlin/JVM 71/71 plus `installDist`, shared conformance 42/42, the clean
  60-file repository gate, JSON/diff hygiene, and final review with no remaining
  P0-P2 finding. The first focused compile exposed a test-only nonexistent
  `.connection` diagnostic category; correcting it to the real `.timeout`
  category made the focused and complete suites pass without changing runtime
  behavior.
- Exported the exact SDK PR `#24` app-source artifact twice from independent
  clean exports. The ten source/contract files are byte-identical, contain no
  Git metadata or supplier payloads, and have manifest SHA-256
  `4801fd6ecbece36df653d91e0d0d975f2fea4c1f7d59f81c69a8b08d90f1b9cf`.
  The app-owned Swift wrapper is independently pinned at
  `31705f1ceb14f0d6eac686083b7012ff685403b0e01435c472e5a8fce3ca7943`.
- Repinned app PR `#17` to SDK `f20f4ed`. The artifact verifier and adversarial
  suite pass 9/9; the vendored Swift package passes 15/15 across all 42
  automated scenarios without compiler warnings; Android Full integration
  passes 13/13 and Demo plus Full/Demo instrumentation sources compile; and the
  real macOS app target passes 10/10. The unsigned Release iOS simulator graph
  builds with zero compiler warnings/errors and embeds `NOOPWatch.app`,
  `NOOPWatchComplications.appex`, and `NOOPWidgets.appex`. Heavy platform
  builds ran sequentially through the bounded runner. The 3.2 GiB macOS
  DerivedData, 5.1 GiB iOS DerivedData, and generated vendored SwiftPM caches
  were exact-deleted after evidence capture, restoring approximately 22 GiB
  free disk; artifact verification remains green after cleanup.
- Committed the source-only app repin at
  `5da77db5d929df7cbce73d7e64a8eab935cc0103`. The reviewed terminology
  inventory records 17,872 occurrences across 1,588 groups with zero forbidden
  mappings and no active-allowlist change. The complete Tools wall passes
  318/318 with one intentional skip, the exact protected release matrix passes
  204/204, and direct release, required-CI, trusted-self, calibration,
  distribution, private-data, health-claims, localization, operations, shell,
  Actionlint, Python compilation, and diff gates pass.
- The PR `#21` verification kept heavy Apple and Android work sequential under
  the bounded runner. The isolated macOS and iOS DerivedData directories each
  reached 3.2 GiB; after confirming no matching process or open file remained,
  both directories and generated SwiftPM caches were removed, restoring free
  disk to 17 GiB.
- Kept heavy Apple and Android verification sequential under the bounded
  runner. The isolated macOS and iOS DerivedData directories reached 3.2 GiB
  and 5.1 GiB respectively; after confirming no matching build process remained,
  both directories and the vendored Swift package's generated `.build` cache
  were removed. Free disk returned to approximately 22 GiB.
- Reviewed the terminology scan before regeneration. The semantic totals remain
  17,871 classified occurrences across 1,588 path/category groups, every
  category count is unchanged, the active customer/core allowlist is
  byte-identical, and forbidden mappings remain zero.
- The first complete 318-test Tools wall correctly failed five artifact/trust
  cases because Xcode had recreated an ignored
  `Vendor/NoopBandSDK/.swiftpm` directory. After confirming no matching Apple
  build process remained, removing only that generated package cache restored
  the exact artifact shape; the unchanged full wall then passed 318/318 with
  one intentional skip.
- Re-ran the exact 17-module protected release-controls matrix from
  `.github/workflows/release-controls.yml`; all 204 tests pass. Direct gates
  also pass: 9/9 release controls, all ten required contexts, trusted-main
  self-verification, exact SDK artifact verification, calibration parity,
  terminology, distribution provenance, private-data boundary, eight
  health-claims tests plus the 1,299-file claims scan, localization,
  operations validation, shell syntax/ShellCheck, Actionlint, Python
  compilation, and diff hygiene. The current localization baseline retains
  230 Android and 133 Apple hardcoded literals as explicit debt with no new
  finding.
- Verified the final PR `#19` app repin: the exact artifact verifier passes
  with a 9-test suite containing one positive and eight adversarial cases; the
  vendored Swift package passes 15/15 while checking all 38 shared scenarios;
  Android Full integration passes 11/11;
  Android Demo plus Full and Demo instrumentation sources compile; and the
  real macOS app target passes 10/10. The unsigned Release iOS simulator graph
  builds with `NOOPWatch.app` and `NOOPWidgets.appex` embedded.
- Closed the final independent app review findings before creating the
  replacement commit. The verifier now compares the exact stage-0 regular-file
  Git index against the manifest and app integration files, rejecting
  unmanifested mode-160000 gitlinks, special modes, conflict stages, missing
  paths, and extra tracked paths. Its fixtures use real temporary Git
  repositories, including direct protected-base rejection of both content
  tampering and a gitlink. Apple and Android now each prove that stopping and
  restarting live collection within the same session rejects the prior live
  token while the current token still persists and closes normally. No new
  runtime event was needed: both paths reuse the existing bounded
  `live/stale/staleCallback` diagnostic without identifiers, payloads, or
  health values. Focused evidence passes 9/9 verifier tests, 10/10 Apple app
  boundary tests, and 11/11 Android app boundary tests.
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
  trusted-release suite passes 78/78; trusted self-verification and all ten
  required contexts pass, and the then-current ten-file SDK artifact verified
  with supplier payloads absent. The exact-current
  complete Tools wall passes 318/318 under the bounded runner.
- Re-ran the workflow entrypoints directly. Release controls pass 9/9;
  the exact release-workflow unit matrix passes 204/204;
  calibration parity covers 12 metrics, 3 revisions, 13 thresholds, and 16
  guards; health-claims scans 1,299 files; legal inventory verifies 230 runtime
  components and 3 container inputs; distribution provenance, private-data,
  shell syntax/ShellCheck, workflow lint, Python compilation, operations
  records, and diff hygiene pass. The full localization audit confirms no
  translated-key gaps in supported catalogs while retaining the reviewed
  current inventory of 230 Android and 133 Apple hardcoded literals as explicit
  debt.
- Classified two final verification-environment failures without weakening the
  source gates. Xcode had recreated an empty ignored
  `Vendor/NoopBandSDK/.swiftpm/xcode` directory, so the artifact verifier
  correctly rejected the non-exact top-level layout; removing only that
  generated directory restored the verifier and the unchanged 78/78 focused
  matrix. A first direct-gate bundle used Xcode's Python 3.9 because a login
  shell rewrote `PATH` and stopped before trusted self-verification on the
  missing `sys.stdlib_module_names` API. The same bundle passed with the
  repository-pinned Homebrew Python 3.14.7. No source or test relaxation was
  made for either failure.
- Reviewed exact PR `#17` head
  `a54be2ae1df85fca956a869bd7a784c890948b46` after its terminal hosted
  result. Android, macOS, server, package, policy, localization, health-claim,
  license, operations, release-control, and trusted-control jobs passed. The
  iOS app built, then its 39-case production shell failed only
  `testRecoveryTrendSupportsExactDateScrubbing` in run `35854528703`, job
  `107159852090`.
- Retained failure hierarchy proved a product interaction defect rather than
  an assertion-only flake: releasing the hold-to-scrub gesture also satisfied
  the chart's simultaneous tap recognizer and opened Recovery detail, removing
  the chart before its selected-date value could be read. The shared
  `TrendChart` now latches a scrub release, consumes only that overlapping tap,
  expires an unconsumed latch after 300 ms without scheduled state mutation,
  and preserves an ordinary short tap for metric navigation. The UI test
  re-queries the stable accessibility identifier after SwiftUI replaces the
  selected chart node, without assuming that its runtime accessibility element
  type remains `Other`.
- The exact focused iOS journey passes 1/1 in 21.607 seconds and proves both
  outcomes in sequence: hold-and-drag keeps the chart visible with an exact
  selected-date value, then a short tap opens Recovery detail. `StrandDesign`
  passes 55/55. The complete local iOS production shell passes 39 tests with
  one intentional private-pilot skip and zero failures in 636.770 seconds.
  Xcode 27 then spent its documented 600-second diagnostic timeout in
  `simctl diagnose`; the bounded command remained under its output/resource
  caps and exited `0` after diagnostics completed.

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
| Prior PR `#19` independent clean exports | Two exact-merge exports were byte-identical; manifest SHA-256 `ed338ff50e026ce2f9326ef6b1aa854766c33f7f886177da21c776f6196719fc`, aggregate eleven-file export-tree SHA-256 `ed08f2caf393649d9af106e8c8dd4878aab544e3e166231806da91634b0082fa`, and app wrapper digest `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3` | The prior vendored artifact was deterministic and traceable to SDK PR `#19` merge `823930fa` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Prior PR `#20` independent clean exports | Two exact-merge exports were byte-identical; manifest SHA-256 `150c3d918b23a27fb49da701e0021f718fba6b2384943fa736cade08ac4b5c53`, aggregate eleven-file export-tree SHA-256 `6f7707d3c45089ac2b3be3a0bce9991bb0a03cb12d168f4b27523934d44e4ef7`, and unchanged app wrapper digest `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3` | The prior vendored artifact was deterministic and traceable to SDK PR `#20` merge `9bc2eedc` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Prior PR `#21` independent clean exports | Two exact-merge source trees are byte-identical; manifest SHA-256 `72e9a93f35f01ad9aa8d1975ec4a1beb76d96cf068e27553a08c0ceef01cc571`, eleven regular files, no symlinks, and app wrapper digest `6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3` | The prior vendored artifact was deterministic and traceable to SDK PR `#21` merge `a9d3f1a2` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Prior PR `#22` independent clean exports | Two complete 58-file source exports contain no Git metadata and have identical archive SHA-256 `5eb3e30db3282907ba26432254d3bd2053349f645fe28549097ade3efb72ed8f`; the exact app export manifest SHA-256 is `7299684795367f8e20c488777626ff5988abae72d2264d8ac081878d909ae973`, with app wrapper digest `b24cb6b607710f867d96a3ea5d3c794b3d7517073b995acadfe750153d24d815` | The prior vendored artifact was deterministic and traceable to SDK PR `#22` merge `1883ad33` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Prior PR `#23` independent app exports | Two exact-merge ten-file app-source exports are byte-identical; manifest SHA-256 is `539ec7ab2c5906ea64ab98bb1be0f5ceb70f5ffbf9e0911b5b91cbf0b56e7bc7`, with app wrapper digest `b24cb6b607710f867d96a3ea5d3c794b3d7517073b995acadfe750153d24d815` | The prior vendored artifact was deterministic and traceable to SDK PR `#23` merge `1b4c614e` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Historical PR `#24` independent app exports | Two independent exact-merge ten-file app-source exports are byte-identical; manifest SHA-256 is `4801fd6ecbece36df653d91e0d0d975f2fea4c1f7d59f81c69a8b08d90f1b9cf`, app wrapper digest is `31705f1ceb14f0d6eac686083b7012ff685403b0e01435c472e5a8fce3ca7943`, supplier payloads are absent, and both normalized file-digest lists match | The historical vendored artifact was deterministic and traceable to SDK PR `#24` merge `f20f4ed` | Legal rights or supplier provenance beyond the absent-artifact declaration |
| Prior protected SDK app repin | SDK Swift 55/55, Kotlin 63/63 plus distribution, shared conformance 38/38, and clean repository gate 56/56 passed before PR `#20` merged. The 9-test app verifier suite, vendored Swift 15/15, macOS app boundary 10/10, and Android Full app boundary 12/12 pass; Demo plus Full and Demo instrumentation sources compile. | Ordered conformance publication and the ready-session late-callback correction were consumed while WHOOP remained the default comparison transport and the first-party factory remained disabled | Supplier transport invocation or any physical-device behavior |
| Current protected SDK app repin | SDK PR `#31` merged at `9fd84ff6`; two clean exports are byte-identical with manifest SHA-256 `1290444d1e997a2e9bc4bcc025685f33e9bdd8cf147e49c716f8d7017bc56fa1` and app-owned wrapper SHA-256 `f2250d3a7f301c893c280fe091b0a46e32beadadd7938e1e4735dbaeb39e3149`. Upstream Swift passes 100/100, Kotlin/JVM 102/102 plus `installDist`, all 50 shared scenarios match, and the 71-file repository gate passes. The app artifact wall passes 9/9, vendored Swift 16/16, macOS boundary 10/10, Android Full and Demo 15/15 each with both instrumentation source graphs compiling, the unsigned Release iPhone graph embeds Watch, complications, and widgets, and the exact-current focused iOS profile regression passes 1/1. | Capability schema v3, privacy-safe public rendering, exact-generation history-acknowledgement authority, source provenance, default-off routing, and first-run account visibility are consumed while WHOOP remains the default comparison transport and the first-party factory remains disabled | Supplier transport invocation, signed-device behavior, live identity-provider operation, or any physical-device result |
| Artifact verifier plus unit tests | Exact ten-file export passed; all 9 verifier tests passed, including one positive case and eight adversarial cases covering symlink roots and ancestors, content drift, unexpected files, supplier payloads, and an unmanifested Git mode-160000 entry; no supplier artifacts found | Source, manifest, package wrapper, exact tracked-file layout, complete path/tree symlink policy, Git-index regular-file policy, and no-binary policy are pinned | Physical compatibility |
| Independent app review remediation | A real temporary-Git protected-base test rejects both source tampering and an unmanifested gitlink. Apple passes 10/10 and Android passes 11/11 after adding same-session stop/restart live-token replay regressions; the current token still persists and closes normally. | Candidate-controlled filesystem shape cannot hide a tracked gitlink, and a prior live operation cannot authorize a restarted collection within the same authenticated session | Supplier callback behavior, BLE transport timing, or physical persistence |
| Protected-base artifact authority | 70 focused release/trust tests pass; a copied artifact with a one-line source mutation is rejected by the protected verifier; non-owner `unittest` and standard-library shadow paths are rejected; the complete Tools wall passes 315 tests with one intentional skip | Future non-owner candidates cannot satisfy the SDK artifact gate by shadowing Python's test runner or by relying only on candidate-controlled tests | Owner authorization, hosted exact-SHA execution, supplier rights, or physical compatibility |
| Exact Swift package workflow order | The vendored package completed 15/15 tests and checked all 42 automated exported scenarios without compiler warnings; the exact artifact verifier then passed after generated package output was removed | SwiftPM agrees with the shared contract without leaving generated files inside the verified source tree | App lifecycle, BLE, background, or hardware behavior |
| Android Full app boundary | `NoopBandSdkIntegrationTest` passed 14/14 in a fresh 29-task `--rerun-tasks` build, including all 46 automated shared scenarios, direct same-module forged scan- and reconnect-token rejection with continued issued-token usability, early unsupported-history rejection, pending live-persistence fencing, same-session live-token replay rejection, malformed delayed capability rejection without ready-state loss, restored-checkpoint source mismatch, graceful disconnect, independent live/history stream authorization, overflow range receipt propagation, mutable stream-set snapshotting, retained-history bounds, terminal firmware failure, and all four invalid-history-token combinations | Full-variant app source and capability schema v2 compile and pass through the public application boundary | Instrumentation runtime, OEM background, BLE, or physical behavior |
| Android Demo and instrumentation compile | `compileDemoDebugKotlin`, `compileFullDebugAndroidTestKotlin`, and `compileDemoDebugAndroidTestKotlin` passed against the PR `#24` export at `f20f4ed` | Both Android source graphs consume capability schema v2 successfully | Runtime rendering, managed-device execution, or physical behavior |
| PR `#24` iOS, Watch, and widget graph | The unsigned Release `NOOPiOS` simulator graph built successfully with zero compiler warnings/errors under the bounded runner against SDK `f20f4ed`. Xcode embedded and validated `NOOP.app/Watch/NOOPWatch.app`, its `NOOPWatchComplications.appex`, and `NOOP.app/PlugIns/NOOPWidgets.appex`. | The historical PR `#24` SDK repin compiles across the iPhone, Watch, complication, and widget graph | Signed-device runtime, BLE, background execution, notification delivery, or physical behavior |
| Android memory classification | One combined Full+Demo invocation let the two Compose compilers overlap and exhausted a 3 GiB Kotlin heap; separate no-daemon, no-parallel, two-worker commands passed | The failure was an avoidable verification command shape, not a source failure; variant walls must stay sequential | Every future machine configuration |
| Hosted production-shell diagnosis | PR `#17` run `35643099439` started 120 API 35 tests; 116 passed, two App Report cases timed out before their explanation sheets appeared, and the retained result protobuf contained real test cases | The red required context was a real cross-test state leak, not a zero-test infrastructure event or SDK behavior failure | The local correction until rerun on the protected exact SHA |
| Feedback cleanup instrumentation regression | Full instrumentation source compiled, then six continuity cases followed by all eight AppShell cases passed 14/14 on `pixel2Api35` in 1m42s | Terminal WorkInfo alone cannot release teardown; actual worker/probe unwind and a stable no-new-generation snapshot are required before deleting the exact record, and the report sheets still open afterward | The complete hosted production-shell wall or physical Android behavior |
| Apple app boundary | Xcode 27 focused macOS test passed 10/10 in the real app target, including WHOOP-default routing, source-scoped restore, pending live persistence fencing, same-session live-token replay rejection, lane-specific stream authorization, overflow range receipt propagation, bounded failure categories, and all four invalid-history-token combinations. The vendored app package now directly exercises the scan-suspension race through test-only module access. | The real Apple app target consumes capability schema v2 without changing default routing, while the package proves reconnect authority survives actor reentrancy | Signed-device runtime, BLE, background, Watch/widget runtime, or hardware behavior |
| Bounded disk exception and cleanup | The final Apple rerun reused its integration-only package cache with a 5.5 GiB hard floor after measuring 8.2 GiB free; the real app test passed 5/5, the exact DerivedData reached 2.8 GiB, and its removal restored free disk from 6.9 GiB to 9.3 GiB | The final Apple test ran under explicit memory/disk bounds without touching the concurrent UI worktree, while round-owned disk use returned immediately | Future host capacity without the same preflight and cleanup |
| Final repository policy wall | The terminology inventory and protected digest were repinned after unchanged counts/categories and zero forbidden mappings were reviewed. The first post-repin complete Tools run then found one bounded-runner self-test timing transient: a 50 ms post-spawn deadline returned `126` instead of timeout `124`. The isolated case passed once plus five repeats with no leaked process, and the unchanged complete wall passed 312/312 with one intentional skip. Required-CI verifies 10 contexts, and trusted self-check, terminology, operations, artifact, bounded-runner, and diff gates pass. | The exact local candidate satisfies the repository-controlled release, trust, privacy, terminology, operations, artifact, and process-cleanup contracts | Hosted exact-SHA enforcement or protected integration |
| Resource-floor correction | The first 312-test Tools wall had four bounded-runner failures because nested tests correctly enforced their 10 GiB default while the host had 9.3 GiB free. With no build processes active, deleting only generated Xcode precompiled-module and module caches restored 11 GiB; the unchanged wall then passed 312/312 with one skip | The failures were environmental and the runner remained fail-closed; generated cache cleanup restored the test precondition without source or test changes | Future host capacity without the same disk preflight |
| Final terminology and claims gates | The regenerated inventory records 17,871 classified occurrences across 1,588 groups with unchanged category totals and zero forbidden mappings; health-claims scanned 1,299 files; complete localization audit passed with zero translated-key gaps in supported catalogs and retained the current 230 Android/133 Apple hardcoded-literal inventory | The reviewed terminology snapshot, health wording guard, and translation catalogs remain coherent without hiding the existing literal backlog | Physical accessibility, resolution of every pre-existing hardcoded literal, or medical accuracy |
| Previous remote candidate | PR `#17` head `c16488d7` passed every applicable hosted app, policy, trust, package, server, and release context before review remediation | The pre-remediation integration graph was hosted-green | The unpushed remediation candidate; new exact-SHA checks remain required |
| Final pre-repin hosted candidate | PR `#17` head `abd54fbd` passed macOS, iOS production shell, Apple required, Android build/unit, Android Review Sample, server/package/policy/trust jobs, and automated review. Release controls failed only on four shifted inventory line numbers. Android production shell stopped before tests with bounded `resource-memory` and no result files. | The final SDK source and app graph compile and pass every hosted wall that executed tests; the two red jobs are precisely classified and retained | A passing replacement exact-SHA Android production shell or release-control job |
| Managed-device retry diagnostic correction | `test_android_managed_device_retry` passes 17/17, Actionlint passes, required-CI verifies all ten contexts, and trusted self-check passes | Resource-pressure stops remain fail-closed, while retry announcements occur only after classifier approval | Whether the next hosted runner has sufficient memory to execute the emulator wall |
| Exact-head hosted resource classification | PR `#17` head `fbbb3b50` passed every hosted context except Review Sample. Run `35681052415` attempt 1 job `106598021250` and attempt 2 job `106602308597` each completed APK preparation, entered the emulator task, then stopped with bounded `resource-memory`; retained evidence has no test-result records. | The two failures are reproducible hosted-runner resource stops, not hidden assertions or product failures | A passing Review Sample execution on the replacement profile |
| Review Sample resource-profile correction | Both Review Sample commands now use `-Xmx1536m` and `--max-workers=1`, matching the hosted-green production shell. Focused workflow/retry tests pass 66/66, Actionlint passes, and the complete bounded Tools wall passes 312/312 with one intentional skip. | Required workflow structure, fail-closed classification, memory envelope, and repository controls agree locally | Hosted exact-SHA execution of the corrected Review Sample job |
| Hosted iOS app-report transition correction | Exact head `fe800e8e` passed every hosted context except the iOS production shell, whose only failing case retained the review page's scroll offset after entering the queued phase. The corrected exact case passes 1/1 in 16.098 seconds on a fresh iPhone 17e simulator and 1/1 in 15.841 seconds after the iOS 17 callback correction. The complete unsigned iOS graph then builds with zero source warnings and embeds Watch/widgets. | The queued status, cancellation control, and sheet dismissal are visibly reachable after a long review-page scroll; the correction compiles in the real iOS UI-test graph without a deprecated source API | Replacement exact-SHA hosted execution, physical shake behavior, or production feedback delivery |
| Hosted Recovery chart interaction correction | PR `#17` head `a54be2ae` passed every applicable hosted context except the iOS production shell. Its single failure retained an accessibility hierarchy showing Recovery detail already open after the hold-and-drag. The corrected focused journey passes 1/1 in 21.607 seconds, `StrandDesign` passes 55/55, and the complete local iOS shell passes 39 with one intentional skip and zero failures in 636.770 seconds. | A chart scrub no longer also navigates, the selected-date accessibility value survives SwiftUI node replacement, and a subsequent short chart tap still opens metric detail | Replacement exact-SHA hosted execution, physical touch behavior, or signed-device accessibility |
| PR `#24` local trust wall | The reviewed PR `#24` terminology snapshot retains 17,872 occurrences across 1,588 groups, unchanged category totals and active allowlist, and zero forbidden mappings. The complete Tools wall passes 318/318 with one intentional skip; the exact release-workflow matrix passes 204/204; and the direct wall passes 9/9 release controls, all ten required contexts, trusted self-check, exact artifact verification, calibration parity for 12 metrics/3 revisions/13 thresholds/16 guards, legal/distribution/private-data, eight health-claims tests plus a 1,299-file scan, localization, 83 operations records, shell/workflow lint, Python compilation, and diff hygiene. | The historical PR `#24` candidate satisfied the repository-controlled release, privacy, claims, metric, localization, artifact, and process-cleanup contracts locally | Hosted exact-SHA enforcement, physical accessibility, or protected integration |
| Final policy rerun classification | The first complete wall failed only three fail-closed trust checks because the newly reviewed terminology inventory had not yet been repinned in `RELEASE_SOURCE_DIGESTS`. The final post-review snapshot SHA-256 is `f5969d93f3d074dedd764e6eb8034827254bd3ff7799fcf105440514abeeeacf`; repinning the reviewed snapshot made the focused trust matrix and unchanged complete wall pass. One manual trusted-self invocation omitted the required `--root .` argument and exited on CLI usage; the correctly shaped invocation passed. | The protected evidence ratchet rejects an updated snapshot until its exact digest is reviewed, and the final commands execute rather than silently skip | Hosted exact-SHA execution or physical behavior |

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
- Branch and remote state: PR `#17` is open from the dedicated branch.
  SDK PR `#31` is merged at
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`. The source-only app artifact
  and app-owned provenance pins consume that exact merge locally. Exact app,
  simulator, and onboarding verification are green; repository controls are
  being rerun after the final documentation repin. Independent final review
  found no P0/P1 blocker. One consolidated push,
  exact-SHA hosted checks, matching review, applicable thread resolution,
  protected integration, and protected-main verification remain.
- Repository visibility verified again on 2026-09-23:
  `Dhanunjay-Divi/Noop` and `Dhanunjay-Divi/NoopBandSDK` both report `PUBLIC`
  with default branch `main`. The owner approved that public operating state
  for both repositories. D-056 now enforces the public-source exclusion
  boundary instead of a post-merge visibility change.
- Version/build impact: no customer version change planned.
- Release or distribution impact: no release or deployment until protected
  checks pass; supplier artifacts remain excluded.

## Decisions

- Durable decision changed: D-056 now keeps the app and SDK repositories
  public while preserving the strict source-only exclusion boundary.
- Decision-log entry: D-056 updated on 2026-09-23.

## Open risks and honest limitations

- Exact PR `#31` SDK and app-boundary verification is green, including
  Apple/Android app boundaries, the iPhone/Watch/widget build graph, and the
  focused hosted-failure regression. Independent final review found no P0/P1
  blocker; its two P2 evidence findings were corrected upstream. The final
  repository-control rerun, consolidated commit/push, and replacement
  exact-SHA hosted verification remain. Prior hosted heads do not prove the
  final candidate.
- A source-only adapter seam cannot establish that a supplier band is
  compatible or flashable.
- The separate iOS supplier adapter remains default-off with no production
  stream. The separate Android supplier adapter has two unresolved software
  findings around supplier exceptions and terminal diagnostic ordering, in
  addition to external SDK, rights, and physical-device gates. Neither adapter
  is part of this supplier-independent PR.

## Next round

1. Complete the exact reviewed PR `#31` repository-control wall, commit the
   replacement, and push once.
2. Require every exact-SHA protected context and matching review on that
   candidate, then resolve only threads proven fixed by matching evidence.
3. Merge normally, verify protected `main`, and remove exact round-owned logs,
   exports, package scratch data, and the dedicated worktree.
4. Keep both repositories public under D-056 and verify that no supplier
   binary, firmware, credential, signing material, private input, or user or
   health data enters either tree.
5. Keep the supplier adapters/flasher disabled until the exact SDK, firmware,
   tooling, keys, rights, and representative physical bands pass their
   acceptance matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.

## September 23 final local pre-push closeout

- A final source review removed the delayed scrub-latch mutation. The chart now
  uses a short expiry deadline, so a second hold started immediately after the
  first cannot be cleared by stale scheduled work. It also installs the
  explicit tap recognizer only when a caller supplies a tap action, preserving
  the behavior of non-navigating charts.
- Exact-current verification is green. `StrandDesign` passes 55/55. The
  focused Recovery scrub-then-tap journey passes 1/1 in 21.660 seconds. The
  complete iOS production shell passes 39 tests with one intentional private
  synthetic-pilot skip and zero failures in 628.915 seconds. Xcode's separate
  simulator diagnostic collection reached its documented 600-second timeout
  after the tests; the test result remained successful and `xcodebuild`
  exited `0`.
- Removed only regenerated round-owned output after preserving the results:
  the empty SDK `.swiftpm` directory, 175,152 KiB of `StrandDesign` build
  output, and 3,294,680 KiB of the exact iOS DerivedData directory. No build or
  test process remained, and free data-volume space increased to 101 GiB.
- The exact pre-commit repository wall passes 318/318 tests with one
  intentional Safety smoke skip. Direct entrypoints pass nine release
  controls, all ten required contexts, trusted self-verification, the exact
  ten-file SDK artifact contract with supplier payloads absent, calibration
  parity for 12 metrics, 3 revisions, 13 thresholds, and 16 guards,
  distribution provenance, private-data and health-claim guards, validation
  of all 84 operations records, complete translated-key coverage in every
  supported Apple catalog, shell syntax/ShellCheck, Actionlint, Python
  compilation, and diff hygiene. The reviewed terminology snapshot remains
  17,872 occurrences across 1,588 groups with unchanged category totals,
  unchanged active allowlist, zero forbidden mappings, and SHA-256
  `d96319e525e0297ab2c213a8d2b8aadc91b0c0a872d67efc32ebc492f676405e`.
  The localization report retains 244 Android hardcoded literals as explicit
  existing debt rather than hiding them.

## September 23 SDK PR 27 repin

- SDK PR `#27` merged normally at
  `586a5c04bd3edbd445895a881c5d4faa78fb526e`. Two independent clean exports
  are byte-identical; manifest SHA-256 is
  `f85eea6bd66bfe902d6ce89fef46f13a97d3621c1035bab537eca6cc95b35c73`.
- Upstream evidence passes Kotlin 86/86 plus `installDist`, Swift 75/75, all
  46 shared conformance scenarios, and the 64-file repository policy gate.
- App evidence passes the exact artifact verifier and its 9-test adversarial
  suite, vendored Swift 16/16, macOS app boundary 10/10, Android Full and Demo
  integration 15/15 each, and both Android instrumentation source compiles.
- The first Android focused invocation did not start Gradle because the
  bounded-runner path was relative to `android/`; the absolute-path rerun is
  the counted passing result.
- The terminology snapshot retains 17,872 occurrences across 1,588 groups,
  unchanged category totals and active allowlist, and zero forbidden mappings.
  Only reviewed line numbers and source hashes changed.

## September 23 SDK PR 28 repin

- SDK PR `#28` merged normally at
  `f8185b753b9e3672e78c7f3ee7596aeae7d53234`. Two independent clean exports
  are byte-identical; manifest SHA-256 is
  `1346cce862a5ecbe6dd4b29060c7ed239c918fd332a0c49808b7eec3a8bbc98b`.
- Upstream evidence passes Swift 83/83, Kotlin/JVM tests plus `installDist`,
  all 50 shared conformance scenarios, and the 66-file repository policy gate.
- The app vendored tree matches the clean export byte for byte. App-owned
  revision/hash boundaries now point to PR `#28`; replacement app verification
  and exact-head hosted checks remain pending.

## September 23 SDK PR 29 repin

- SDK PR `#29` merged normally at
  `38cf7de3b1c92dd30dad343af2adfa2cb61dea2e`. Two independent clean exports
  are byte-identical; manifest SHA-256 is
  `5df5d94235f39ec806b6998581656cdf2f5c479451933fe8ebf95583ce8cad8e`,
  and the app-owned test-wrapper SHA-256 is
  `476582712df3456c142e4924e5d9aff30d7b430e33bb09dc96bb3d9020803ec5`.
- Upstream evidence passes Swift 91/91, Kotlin/JVM 99/99 plus `installDist`,
  all 50 shared conformance scenarios, and the 67-file repository policy gate.
- Exact-current app evidence passes the artifact verifier and its 9-test
  adversarial suite, vendored Swift 16/16, macOS app boundary 10/10, Android
  Full and Demo integration 15/15 each, and both Android instrumentation
  source compiles.
- The unsigned Release `NOOPiOS` graph passes under the bounded runner with
  zero source warnings/errors and embeds `NOOPWatch.app`,
  `NOOPWatchComplications.appex`, and `NOOPWidgets.appex`.
- The complete exact-current repository wall passes 318 tests with one
  intentional Safety smoke skip, nine release controls, all ten required
  contexts, trusted-main self-verification, calibration parity, a reviewed
  terminology inventory with 17,874 occurrences across 1,588 groups and zero
  forbidden mappings, distribution provenance, private-data and health-claims
  guards, complete localization, all 84 operations records, the exact
  artifact verifier and its 9-test adversarial suite, and diff hygiene. The
  reviewed inventory SHA-256 is
  `8aefcbcdf6f9c10b36ebe8a6146cdec3f8b4299738f3297872b71967d9555cf8`.
- The first repository-wall command selected Xcode's bundled Python 3.9 from
  a login shell. It executed 302 tests and then reported two import errors for
  Python 3.11+ standard-library APIs. Repeating the unchanged wall with the
  project Python 3.14 interpreter passed; this was a command-environment
  correction, not a product or test change.
- WHOOP remains the default comparison transport. The first-party source
  factory remains disabled; no simulator/build result proves supplier BLE,
  background execution, disconnected history, haptics, battery, or
  physiological accuracy.

## September 23 final exact-head documentation review

- PR `#17` candidate `e12b71fb55d620a642ef340c4503b4b15970091c`
  reached 30 successful hosted checks with four intentional skips while its
  macOS and iOS jobs were still running.
- Exact-head automated review found no new runtime defect. It identified two
  durable-record mismatches: D-056 still named a superseded SDK revision, and
  the supplier handoff described schema v2 as current although the integrated
  validators and JSON contract require schema v3.
- The correction updates D-056 to SDK PR `#29` merge `38cf7de3`, documents
  schema v3 lane semantics and live-operation concurrency, and aligns the
  release plan/checklist. Runtime source, WHOOP routing, supplier-default-off
  behavior, and all physical gates are unchanged.

## September 23 SDK PR 30 final review repin

- SDK PR `#30` merged normally at
  `b027cbd9702936d4903f3293ca605650cdf5c413`. Two clean source-only exports
  are byte-identical; manifest SHA-256 is
  `d238c162d062d7b10eac6e205aba5b8abcfaff6057f2b8c34052756a5317be6c`,
  and the app-owned test-wrapper SHA-256 is
  `6712d8cffc23ccd4db2560a50b697cf868ec60f87aa6b59229ce5a4525ba1f8f`.
- Upstream evidence passes Swift 94/94, Kotlin/JVM tests plus `installDist`,
  all 50 shared conformance scenarios, and the 68-file repository policy gate.
- The app vendored tree, boundary constants, tests, verifier, release controls,
  and durable operations records now pin the exact merge. WHOOP remains the
  default transport and the first-party source factory remains disabled.
- Exact app evidence passes the artifact verifier and 9-test adversarial suite,
  vendored Swift 16/16, macOS app boundary 10/10, Android Full and Demo
  integration 15/15 each, both Android instrumentation source graphs, and the
  unsigned Release iPhone graph with embedded Watch, complication, and widget
  products. Account and ownership onboarding passes 13/13 on Apple and 14/14
  in each Android variant.
- The first complete Tools wall failed closed because SwiftPM regenerated the
  ignored vendor `.build` and `.swiftpm` paths and the reviewed documentation
  shifted the terminology inventory. Exact deletion of those generated paths,
  semantic inventory review, and protected-digest repinning made the focused
  trust wall pass 78/78 and the unchanged complete wall pass 318/318 with one
  intentional skip.
- Direct gates pass nine release controls, all ten required contexts, trusted
  self-verification, calibration parity for 12 metrics/3 revisions/13
  thresholds/16 guards, distribution provenance, private-data and
  health-claims guards across 1,299 files, 86 app-report strings across nine
  locales, all 84 operations records, shell syntax/ShellCheck, Python
  compilation, exact artifact verification, and diff hygiene. The reviewed
  terminology snapshot records 17,877 occurrences across 1,588 groups with an
  unchanged active allowlist, zero forbidden mappings, and SHA-256
  `51ef8da9020a44090f3c03499b1eddb616815e003e8073ae9ffe268111440576`.
- Independent final review found no P0/P1 blocker or runtime P2 regression.
  Its P2 evidence note is explicit: suspension and ordered live-interruption
  behavior are asserted in the upstream 94-test SDK suite rather than
  duplicated in the app wrapper suite.
- Separate Apple and Android supplier-adapter worktrees remain outside this PR.
  The Apple adapter is source-only/default-off and cannot publish a production
  stream. Android review found uncontained supplier exceptions and terminal
  diagnostic ordering defects. These software findings and all supplier
  rights/SDK/physical gates remain open without changing WHOOP-default routing.
- Hosted exact-head checks, protected integration, and protected-main
  verification remain. Physical BLE, background collection, history
  retention, battery, haptics, and physiological accuracy remain external
  hardware gates.

## September 23 hosted iOS profile-entry correction

- App PR `#17` head
  `6d3b54a01ed6fd7e741e721aa6ff467d3b6bfcb4` passed the hosted Android,
  macOS, package, server, release, policy, trust, and repository-control
  contexts. The iOS application built successfully; its production shell ran
  39 tests with one intentional skip and failed only
  `testProfileMeasurementsCanBeClearedAndRetyped`.
- Retained CI evidence showed that clearing the weight field removed keyboard
  focus before immediate re-entry. The correction keeps the cleared field
  focused synchronously and on the next main-queue turn, and exposes the
  weight and height clear affordances as native `Button` controls instead of
  gesture-backed accessibility pseudo-buttons.
- The UI regression now requires the cleared field to retain
  `hasKeyboardFocus == true` before typing. The exact focused case passed once
  in 16.994 seconds and then twice without rebuilding in 15.598 and 15.403
  seconds. A wrapper attempting a third repeat reached its outer timeout after
  the two recorded passes; the interrupted third build is not counted. Its
  orphaned simulator diagnostic collector was terminated, and no product or
  test process remains from that attempt.
- The narrow remediation is local and uncommitted. It still requires one
  follow-up commit/push, replacement exact-head hosted checks, normal protected
  integration, exact protected-main verification, and round-owned cleanup.

## September 23 SDK PR 31 authority and rendering repin

- SDK PR `#31` merged normally at
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`. Two clean source-only exports
  are byte-identical; the ten-file manifest SHA-256 is
  `1290444d1e997a2e9bc4bcc025685f33e9bdd8cf147e49c716f8d7017bc56fa1`,
  and the app-owned wrapper SHA-256 is
  `f2250d3a7f301c893c280fe091b0a46e32beadadd7938e1e4735dbaeb39e3149`.
- The protected SDK closes the reviewed history-acknowledgement race by
  retaining exact generation, token, state, and receipt-sequence authority
  across the awaited diagnostic boundary. Public identity, sample, batch,
  history, checkpoint, and session-snapshot rendering is type-only and does
  not expose health values or persistent identifiers.
- Upstream evidence passes Swift 100/100, Kotlin/JVM 102/102 plus
  `installDist`, all 50 shared conformance scenarios, and the 71-file
  repository policy gate. Independent review found no P0/P1 issue. Its two P2
  evidence findings were corrected before merge and the complete upstream
  gates were rerun.
- Exact-current app evidence passes the ten-file artifact verifier and its
  9-test adversarial suite, vendored Swift 16/16, the real macOS app boundary
  10/10, Android Full and Demo integration 15/15 each, both Android
  instrumentation source compiles, and the unsigned Release iPhone graph with
  embedded Watch, complication, and widget products. The focused iOS
  profile-clear regression passes 1/1 in 16.610 seconds on the same final
  source tree.
- WHOOP remains the default comparison transport. The first-party source
  factory remains disabled, supplier binaries remain absent, and no simulator
  or build result is treated as evidence for physical BLE, background
  collection, disconnected history, haptics, battery, firmware, or
  physiological accuracy.
- The final repository-control wall, one consolidated app commit/push,
  replacement exact-head hosted checks, protected integration, protected-main
  verification, and exact round-owned cleanup remain.
- The reviewed terminology snapshot now records 17,883 occurrences across
  1,589 groups with an unchanged active allowlist, zero forbidden mappings,
  and SHA-256
  `433d89784f464c4a44f423221cf989a05a09f87c1420a24a217ce64e95ac3005`.
  The protected digest is repinned; the replacement control wall passes
  318/318 with one intentional skip.
- Owner direction on 2026-09-23 keeps both repositories public. GitHub confirms
  both default branches are `main` and visibility is `PUBLIC`. D-056 and the
  physical-device handoff now treat public visibility as the intended state
  while preserving the strict source-only exclusion boundary.
- `AGENTS.md` now directs the next device-connected model to start from
  protected `main`, install exact signed iPhone and Android candidates, run the
  existing WHOOP path as the comparison baseline, and integrate/validate only
  the exact approved supplier adapter before expecting the first-party band to
  connect.
- Final post-decision controls pass: the complete 318-test repository wall
  with one intentional skip, all 84 operations records, exact artifact
  verification plus 9 adversarial cases, terminology ratchet, and diff
  hygiene. The remaining work is the consolidated commit/push, hosted
  exact-head checks, protected integration, protected-main verification, and
  exact cleanup.

## September 23 final public-repository handoff correction

- Live GitHub state and current D-056 both keep the app and SDK repositories
  public. A final handoff review found current-facing references in the iOS
  install guide, SDK wrapper handoff, supplier assessment, release checklist,
  and one historical paragraph in `ACTIVE.md` that still described the
  superseded private-repository gate.
- Those references now distinguish public source visibility from artifact
  approval and preserve the exclusion of supplier source/binaries, firmware,
  credentials, signing material, private inputs, and personal or health data.
  Archived operations records remain historical evidence and were not
  rewritten.
- The reviewed terminology snapshot now records 17,884 occurrences across
  1,589 groups with an unchanged active allowlist, zero forbidden mappings,
  and SHA-256
  `d266cf5458193d6e6d54fac1b9eb949438f537e7ee2a4866c284d04a91e9a529`.
- Runtime source, UI behavior, WHOOP routing, the disabled supplier source
  factory, health claims, and physical acceptance gates are unchanged. The
  replacement repository wall passes 318/318 with one intentional skip,
  focused trust checks pass 64/64, and all 84 operations records validate.
  Replacement exact-head hosted checks remain before protected integration.
