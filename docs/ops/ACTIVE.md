# Active NOOP handoff

Last updated: **2026-09-22**

## Authoritative context

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Protected branch: `main`
- Active worktree: dedicated NOOP Band SDK app-integration checkout
- Active branch: `codex/noop-band-sdk-app-integration-20260921`
- Branch base against protected `main`:
  `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1`
- Current round implementation started from protected `main` after PR `#16`
  merged and mainline trust was verified.
- Current state: `NoopBandSDK` PR `#16` is merged normally at
  `a486768efb873b57515926740d3efa19787de612`. Two independent clean exports
  were byte-identical; the ten-file export manifest SHA-256 is
  `703f7eff73298acbf4098b31a9e1a7b50b9a8579515cfd596476f00cace6755f`
  and their aggregate eleven-file export-tree SHA-256 is
  `fb1ec8080b2ddce6ceb1e2e56f8d855afbdbef80ca24de5172b5e3c5af306662`.
  The app-owned Swift wrapper SHA-256 is
  `2704fd896899bfca64de46ea8b10ef64a7ca7dff6ea6ebe6f30196ac8733d8c7`.
  Export-manifest schema `1` remains unchanged; the negotiated capability
  contract is schema `2`. It separates `liveStreams` from `historyStreams`,
  binds retained and first-lost overflow ranges through acceptance and durable
  receipt, blocks established authentication/security invalidation while
  persistence is unresolved, validates retained sample bounds and loss-range
  chronology, rejects advertised history with zero retention, and exposes a
  distinct terminal firmware-failure state. The SDK passed Swift 52/52,
  Kotlin 56/56 plus `installDist`, shared conformance 36/36, and the 52-file
  repository gate. Independent final review found no P0-P2 issue.
  The app artifact verifier and all 8 adversarial tests pass; the vendored
  Swift package passes 15/15; the real macOS app boundary passes 9/9; Android
  Full integration passes 10/10; and Android Demo plus Full instrumentation
  sources compile. The current unsigned iOS simulator graph builds and embeds
  validated Watch, Watch complication, and widget products. The complete
  317-test Tools wall, exact 203-test release-workflow matrix, 9/9 release
  controls, required-CI, trusted-main, calibration, terminology, claims,
  legal/distribution, private-data, shell, localization, operations, and diff
  gates pass locally. Supported translation catalogs have zero missing keys;
  the current 244 Android and 135 Apple hardcoded-literal inventory remains
  explicit debt. One consolidated push, replacement exact-SHA hosted checks,
  four review-thread resolutions, protected merge/main verification, and exact
  cleanup remain.
  WHOOP remains the default independent test transport and the first-party
  source factory remains disabled. No supplier binary, firmware, real adapter,
  flasher, physical BLE evidence, background evidence, battery evidence,
  haptic evidence, or physiological-accuracy evidence is included. Both
  repositories currently report `PUBLIC`; D-056 requires the SDK repository
  to be restored to `PRIVATE` before release.
- Current state: supplier-independent implementation and applicable local
  platform verification are green. Pull request `#16` candidate `e9b3a380`
  passed 32 hosted jobs, including every Android job (Review Sample,
  production shell, and build-and-test), policy, trust, server, Swift packages,
  and the macOS build/tests. The iOS build passed; its production shell
  completed 37 tests, skipped one intentional private case, and failed only
  `testTodayScrollPerformance`. The first timed scroll round trip completed,
  then XCTest invoked the simulator measurement closure for extra calibration
  gestures and its event-loop observer stopped becoming idle. The correction
  makes the simulator path execute exactly one wall-clock-bounded round trip
  while retaining Apple's five-iteration scrolling/deceleration metric on real
  devices. The corrected simulator test passed once and then 3/3 repeated
  iterations locally through the bounded runner. The exact Android command
  shape and 65 focused CI tests pass. After the test-only correction, 66
  focused terminology/required-CI/trust tests and the complete 305-test tool
  wall pass with one intentional skip. The reviewed active terminology
  allowlist is unchanged and the historical inventory has zero forbidden
  mappings. The exact Python 3.14 release-policy matrix is green; replacement
  commit/push, hosted exact-SHA checks, protected merge, and protected-main
  verification remain pending.
- Fresh September 20 independent Apple/Android and server/infrastructure review
  found no P0, but the replacement candidate is not yet release-ready. Local
  fixes now quiesce Friends work around account deletion, preserve scheduling
  after cancellation, reconcile Android encrypted outbox generations, restore
  `noop-charge-v2` reproducibility, bind installations to platform/plan limits,
  return truthful account privacy state, fail closed on migration-058 schema
  drift, bound deletion-worker lock attempts, verify real Friends account
  erasure, bind mobile App Check enrollment to platform, and emit bounded
  enrollment outcomes. Focused Android Full-debug tests, 29 Swift Recovery
  tests, 305 Tools tests with one intentional skip, 50 i18n tests, required-CI
  validation, 38 consolidated PostgreSQL cases, and 4 focused enrollment API
  cases pass. The GCP source now separates pinned migration authority from five
  workload-specific restricted runtime identities and database secrets; 13
  provisioning tests, 22 production-deployment contracts, and 20 plan-only
  OpenTofu tests pass. Failed secret publication or verification restores the
  previous password or quarantines a first-time runtime role. The final Friends
  localization/accessibility wall also passes on Android and Apple, the
  unreachable Apple/Android self-hosted Friends presentation has been removed,
  account-deletion copy is plan-neutral, and 33 focused Apple tests plus the
  29-task Android managed-only Friends build pass. The exact-current unsigned
  Release iOS graph builds with its embedded Watch app and widget validated.
  `NoopRemoteSync` passes 188/188 after a fail-safe legacy communication-field
  decoder correction, `WhoopStore` passes 539/539, and the complete Tools wall
  passes 305 tests plus 44 subtests with zero forbidden terminology mappings.
  The exact-current complete macOS wall passes 2,207 tests with one intentional
  skip and zero failures.
  Remaining blockers include live staging credential provisioning, the
  consolidated commit/push, hosted exact-SHA checks, and protected integration.
- The September 21 final closeout additionally preserves the terminal
  service-erasure account fence, makes managed import reachable on both phone
  platforms, prevents restored Apple preferences from creating an outbox echo,
  serializes all Android Friends communication permissions, completes
  destructive-flow localization, and removes only proven unreferenced
  self-hosted Friends presentation resources. Focused closeout evidence is
  green: Apple 13/13, Android localization 6/6, Android retention 19/19, Swift
  retention 6/6, managed-erasure unit 4 pass/3 PostgreSQL-gated skips, and
  changed-server Ruff check/format. The separately recorded disposable
  PostgreSQL terminal-fence test remains green.
- The same closeout now makes history-chunk credit callback-confirmed on Apple
  and Android, fences delayed persistence/callbacks across ended sessions, and
  treats local `strap_trim` only as a diagnostic watermark. Apple reconnects
  fail-closed if a watchdog expires with an acknowledgement in flight. The
  Apple focused suite passes 23/23. Exact-current broad evidence is green:
  `NoopRemoteSync` 191/191, `WhoopStore` 539/539, macOS 2,213 with one
  intentional skip, iOS simulator 39 with one intentional skip, unsigned
  Release iOS with embedded Watch/widget and zero compiler warnings/errors,
  Android Full and Demo 4,972 each with seven intentional skips across 175
  tasks, disposable PostgreSQL 784 with one intentional skip, and 20/20
  plan-only OpenTofu tests. The repository tool wall passes 305 tests with one
  intentional skip. Required-CI validates all ten contexts; the terminology
  ratchet records 17,837 classified occurrences across 1,583 groups with zero
  forbidden mappings. Remaining work is consolidated commit/push, hosted
  exact-SHA verification, protected integration, and round-owned cleanup.
- PR `#16` review remediation advanced the remote head to
  `149843c109ef85093f62965ac977263180bcc796` with an Apple formula-migration
  integration regression. The final local tree also omits unusable optional
  formula baselines without changing `noop-charge-v2`, serializes
  ownership-deletion claims with cancellation, removes the remaining
  unreferenced Android self-hosted Friends view model and server-address invite
  copy, and adds account-scope/localization/navigation regressions. Focused
  evidence is green: server 39 unit/contract plus 4 disposable-PostgreSQL
  cases, Apple 56 requested plus 10 archive and 10 formula cases, Android Full
  and Demo 62/62 each with app and instrumentation-source compilation, and the
  complete 305-test tool wall with one intentional skip. The terminology
  snapshot now records 17,840 occurrences across 1,585 groups with zero
  forbidden mappings. Final consolidated remediation commit/push, all ten
  exact-SHA hosted contexts, remaining reviewed-thread resolution, protected
  merge/main trust, and exact cleanup remain pending.
- The consolidated PR `#16` remediation is now remote at
  `1b61ebcac5c0803e6025c0491d1b36feb7aa7af1`. Two later Android review findings
  were confirmed and corrected locally: complete-history import retains an
  explicit cancel handle and localized canceled state, and an OS-disabled
  preferred Safety channel is blocked rather than routed through the standard
  channel. Full and Demo each passed 12/12 focused import/Safety cases while
  compiling app and instrumentation sources; after adding all-locale copy and
  its ratchet, each variant passed 18/18 focused cases. A narrow follow-up
  commit/push, exact-SHA hosted contexts, thread resolution, protected merge,
  protected-main verification, and cleanup remain.
- The late Android follow-up is remote at
  `ad936850d9094ac2c317095f979eebc3b26845ca`. The final two review findings are
  corrected and verified locally alongside two additional review closures.
  Formula civil-day UTC conversion rejects underflow/overflow through the
  existing input contract. Forward migration 059 targets only links created by
  migration 047 for identities/accounts already terminal at that timestamp,
  removes dependent authority state, preserves active ownership roots including
  a concurrent link, retires only true orphans, and restores ordinary guards.
  Apple and Android defer mixed Friends summaries until formula migration is
  complete, and complete-history restore/list paths explicitly select
  `server_readable` chunks while retaining client-encrypted storage. The
  canonical localization source and generated Apple/Android resources agree
  after retiring the stale invite key. Hosted Android production-shell runs now
  use a 1.5 GiB heap and one worker. The final migration repair also removes
  the historical migration-versus-erasure deadlock, preserves
  `deletion_pending` principals needed for cancellation, avoids global
  ownership-table locks, and uses one schema-bound security-definer lock
  function whose body, principal-table owner, search path, return type,
  arguments, and exact execute ACL are verified before runtime credentials can
  be published. Registration takes the principal lock before ownership writes
  and reconciles the ownership link in the same transaction; the restored link
  guard is schema-qualified so the hardened function search path cannot shadow
  or hide its control-plane tables. A final independent database review also
  unified registration/reconciliation/deletion on one privacy-safe advisory
  key, restored only tombstone-proven pre-059 erasure principals whose
  ownership roots predated retirement, and extended runtime verification to
  helper volatility and `pg_proc` ownership. Current evidence: the complete
  fresh-database server wall passed 800 tests with only the explicitly opt-in
  Twilio staging test skipped across 801 collected tests; the final late
  database/provisioning wall passes 19/19 after the earlier broad 21/21 wall;
  migration 059 is pinned at
  `f8fbc7171eaae23b6f5aa8c48c12613189a4ad2567e22c9807eea84c2e8ea1cd`;
  Ruff check and format pass on the seven final review files after the earlier
  101-file release-scoped wall; `NoopRemoteSync` passes 192/192; Apple formula
  contracts pass 12/12; and Android Full/Demo each pass 64/64 focused final
  cases. The final
  terminology snapshot records 17,846 occurrences across 1,585 groups with
  zero forbidden mappings; the complete repository wall passes 355 tests plus
  44 subtests, and required-CI, release, legal, private-data, health-claims,
  localization, operations, calibration, trusted-control, and diff gates are
  green. A final review then confirmed one Android-only parity gap: an empty
  formula-traversal segment could preserve prior-revision computed scores while
  recording migration completion. The local follow-up now threads traversal
  intent into Android scoring and atomically clears only that computed
  daily/managed-Rest window when no raw or imported evidence remains; ordinary
  transient empty passes still preserve the last complete scores. Its focused
  JVM regression passes 3/3 and the Full-debug app plus instrumentation source
  compile succeeds. The first 1.5 GiB local compile was bounded and stopped on
  Kotlin heap exhaustion; the repository-standard 4 GiB local rerun passed.
  Only the final narrow commit/push, exact-SHA hosted verification,
  review-thread resolution, protected merge/main trust, and exact cleanup
  remain.
- Initial hosted replacement commit `bec61a55c7e45fbb2b1563c891858e439049b9cb`
  reached run `35546684149`. Server source lint passed, but Ruff's format check
  identified seven files. Ruff 0.12.2 applied its canonical formatting to
  exactly those files; the complete server source check and format check now
  pass locally. The correction is formatting-only and does not invalidate the
  recorded server behavior wall. The corrected exact head still requires one
  replacement push and hosted verification.
- Exact PR head `825d015cd404433ac28f67ec7182520b123d48d5`
  passed every required Apple, server, package, policy, release, trust, and
  Android build wall. Its API 35 production shell passed the new eight-case
  stale-formula Room regression but failed two existing app-report tests before
  their sheets opened. The process-global report channel could hand a request
  to a retiring Activity collector. The local correction removes that mailbox
  and routes Test Centre through a compiler-required callback owned by the
  current `MainActivity`; shake and demo requests retain their direct
  controller path. Fixed-category `report.request` outcomes make the boundary
  observable without identifiers or payloads. The 4 GiB one-worker Full app,
  focused JVM test, and complete Full instrumentation-source compile pass; a
  deliberate 1.5 GiB local attempt stopped at the known Compose compiler heap
  boundary. One narrow commit/push, replacement exact-SHA checks, protected
  merge/main verification, and cleanup remain.
- Replacement PR head
  `e1eaa4deafbc1b986e933037acaaec3d4e7367da` proves that correction in the
  hosted API 35 production shell. Android production shell, Review Sample,
  build-and-test, and its required aggregate pass; iOS, macOS, server, Swift
  packages, operations, localization, health-claims, runtime-license, and trust
  checks also pass. The sole failure is the release-control terminology
  snapshot ratchet: source and operations edits moved existing line numbers and
  digests while occurrence count, category totals, and the active customer/core
  allowlist remained unchanged. The reviewed scan records 17,846 occurrences
  across 1,585 groups and zero forbidden mappings. The inventory has now been
  regenerated and its exact digest repinned; the 191-case release-control wall,
  standalone 9-check report, required-CI ten-context check, trusted self-check,
  shell entrypoints, calibration parity, distribution provenance, private-data
  guard, operations validation, terminology ratchet, and diff hygiene pass
  locally. One evidence-only push, final exact-SHA hosted verification,
  protected merge/main trust, and cleanup remain.
- The next exact-head review identified four P2 contract defects. Watch live-HR
  selection is remote at `3b69ee07`: freshness and plausible BPM are applied
  before selecting the newest sample, with invalid-newest/valid-earlier and
  no-valid-initial-batch ratchets. Local commits `e1e94c67` and `5778e2f0`
  make Android selected-file staging cancellation responsive without replacing
  prior durable import state, enforce the formula-shadow `+/-1e308` persistence
  bound through 422 validation, and reject skipped civil days such as
  `Pacific/Apia` 2011-12-30 before persistence. Focused evidence is green:
  Watch source/XCTest type-checks and two policy checks; two Android deterministic
  staging regressions by source review; 29 executor plus 9 model/API tests; and
  Ruff check/format. The Android Gradle attempt was stopped before compilation
  because free disk was 3.4-4.0 GiB with 8.7 GiB swap, below the unchanged
  10 GiB floor. Superseded heavy GitHub runs were canceled, exact worker-created
  Android/Watch outputs were removed, and the final combined push, exact-SHA
  hosted walls, four-thread resolution, protected merge/main trust, and cleanup
  remain.
- Xcode 27 is installed and `xcodebuild -license check` exits `0`; the former
  license blocker is resolved.
- Earlier broad local evidence before the late-review follow-up:
  `NoopRemoteSync` passed 191/191 and
  `WhoopStore` passes 539/539. The complete disposable-PostgreSQL server wall
  passes 784 cases with one intentional skip and two framework deprecation
  warnings. Android Full and Demo each execute 4,972 tests with seven intentional skips and zero
  failures/errors inside one 175-task compile, lint, APK, unit, and
  instrumentation-source wall; lint reports zero Error/Fatal findings. The
  complete macOS wall passed 2,213 tests with one intentional skip and zero
  failures. The unsigned Release iOS graph succeeds with zero compiler errors,
  zero `ManagedCloudService.swift` warnings, and its Watch, complications, and
  widget extensions embedded; the iOS simulator production shell passes 39
  tests with one intentional skip. That repository-tool wall passed 305 tests
  plus 44 subtests, and its then-current terminology inventory recorded 17,837
  classified occurrences across 1,583 groups with zero forbidden mappings. Thirteen
  database-role tests, 22 production-deployment contracts, and 20 plan-only
  OpenTofu tests pass without apply. Exact replacement-candidate API 35
  execution remains a required hosted context because the required local x86
  managed device is unavailable.
- Deterministic Safety paging capture passes a test-only user confirmation and
  two preselected dummy contact roles through the production token codec,
  managed push service, and FCM payload builder with 3/3 installations and 2/2
  contacts reached, zero provider traffic, and no sensitive payload values.
  Accepted-contact selection/revocation and precise-location lifecycle are
  separate PostgreSQL integration boundaries. The direct smoke test passes 1/1,
  Ruff passes, three focused PostgreSQL tests pass, the Apple Safety contract
  passes 51/51, and Android Full and Demo each pass 45/45 focused tests. The
  disposable database and test environment were removed after evidence.
- Execution safety now defaults bounded commands to discard unrequested child
  output, cap explicit private logs at 128 MiB, enforce 10% free-memory and
  10 GiB free-disk floors, and terminate runaway-output process groups. All 134
  bounded-runner, required-CI, and trusted-control regression tests pass. This
  directly guards the observed iTerm application-memory failure mode when
  repository heavy commands use the runner; it does not control unrelated apps
  or commands run outside that boundary.
- The hosted-candidate correction passes 77/77 focused macOS tests, including
  all 51 Safety contracts, and the exact Android Full app plus instrumentation
  APK preparation graph with Kotlin in-process. Candidate `e9b3a380` proves
  all three hosted Android jobs complete under the smaller execution heap and
  unchanged host guards. It also exposed the iOS simulator's extra XCTest
  measurement invocations; the corrected single-round-trip path passes four
  local executions while physical devices retain the real performance metric.
- The final policy wall passed all 301 tool tests with one intentional skip plus release, calibration, terminology, required-CI, trusted-control, provenance, privacy, medical-truth, localization, operations-record, and diff gates. The hosted disk-control and initial execution-memory corrections passed the complete 304-test wall with one intentional skip; the retry-hardening tree and corrected iOS simulator liveness path each pass the 305-test wall with one intentional skip. The exact 2 GiB daemon command, 65 focused Android CI tests, 66 focused terminology/required-CI/trust tests, and four iOS scroll executions also pass.
- Exact cleanup manifest
  `8080d7201bc9ec1ac940842c2aa8d0c0026b79fd8980275d8fe187f97583a62f`
  removed three closed completed review-session files totaling
  4,475,749,846 bytes. Manifest
  `991d0340c6e0d4cf61856c0c41b8135dfe059dec471b0646aaed69e84bffbfca`
  removed 62 exact round-owned `/private/tmp/noop-*` paths totaling
  16,566,458 bytes after preserving their results. Current agent-session files
  with open handles and the two cleanup manifests are deliberately retained.
  Later verification outputs were removed by the final closeout cleanup
  recorded below.
- Replacement candidate SHA, hosted `10/10`, protected merge SHA, and
  protected-main trusted result remain pending. No Docker image build,
  production runtime, signing, legal, carrier, physiology, or physical
  accessibility result is claimed without direct evidence.
- Current production behavior remains local-first and account-free for
  exploration. D-059 targets staged cloud authority for durable account
  history, canonical formulas, recommendations, and cross-device state while
  retaining the encrypted edge collector, bounded offline cache, immediate
  Safety initiation, and explicit per-data-class rollback gates.
- Managed portability now has v2 integrity, resumable export, complete
  prevalidation, and resumable idempotent import for selected chunks plus
  `day_ownership`. Ownership deletion now has cooling-off request, status,
  cancellation, session revocation, migration-045 durable target progress,
  restricted managed-data erasure coordination, and matched mobile flows.
  `DAT-170` remains open for live scale/expiry/isolation/physical evidence;
  `ACC-340` remains open for provider identity erasure, ownership control-plane
  final erasure, approved physical band retirement/wipe, and legal/operator
  evidence.
- The September 20 managed-Friends slice now separates account-only background
  work from health-backup and Safety enrollment, exposes account-only deletion
  and cancellation on Apple and Android, and completes the corresponding
  localized account lifecycle. Focused Apple tests pass 12/12; Android
  scheduler/localization tests and resource processing pass; the latest iPhone
  simulator graph builds with Watch and widgets validated; and the isolated
  PostgreSQL managed-Friends suite passes 8/8. Current routed source and 33
  focused Apple tests prove that macOS uses the managed read-only account
  route; the historical self-hosted screenshot is stale and is not accepted as
  current evidence. The legacy Apple/Android Friends presentation source is
  now removed, and Android managed-resource contracts pass. See
  [NOOP-hosted Friends and communications](rounds/2026-09-20-noop-hosted-friends-communications.md).
- Cleanup manifest
  `c302d957bcd169f7244512291cab3cbb9334690ee7d7d0baad5757b937d3ff09`
  removed 23 exact September 20 round-owned temporary paths totaling 7.170 GiB
  after evidence was recorded. Post-cleanup verification found no test
  PostgreSQL listener or candidate app process, with 20 GiB free and iTerm at
  approximately 330 MiB RSS.
- Final pause cleanup manifest
  `13f5560c7a39e340cd3c4d842a369fbd3dd979f0c01bec0868d7221d387c271c`
  removed 30 additional exact round-owned paths after the complete macOS and
  final policy evidence was recorded. No build or test process remained, 21
  GiB was free, and the unrelated pre-existing Homebrew PostgreSQL service was
  preserved.
- Final closeout cleanup manifest
  `a9380fba359496f22cf7ae977dbd95ee39b5eec420ff51876aecc5f17424e152`
  removed five exact regeneratable paths containing 118,883 files and
  approximately 6,111,817,728 bytes. Verification found no remaining build or
  test process, 22 GiB free, and iTerm2 at approximately 310 MiB RSS.

Resume from:

- [PR 16 final readiness closeout](rounds/2026-09-21-pr16-final-readiness-closeout.md)
- [Cloud authority, Safety paging, and live surfaces](rounds/2026-09-19-cloud-authority-safety-live-surfaces.md)
- [Current UI/cloud readiness review](rounds/2026-09-17-ui-cloud-readiness-review.md)
- [NOOP-hosted Friends and communications](rounds/2026-09-20-noop-hosted-friends-communications.md)
- [First production release checklist](../FIRST_PRODUCTION_RELEASE_CHECKLIST.md)
- [Release blockers](../handoff/RELEASE-BLOCKERS.md)
- [Band physical validation handoff](../handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
- [Claude final production review prompt](../handoff/CLAUDE-FINAL-PRODUCTION-REVIEW-PROMPT.md)
- [Agent entry point](../../AGENTS.md)
- [NOOP operations skill](../../.agents/skills/noop-ops/SKILL.md)

## Current scope

- Reconcile the owner's September 19 cloud-authoritative direction through a
  staged, versioned, dual-run migration. The phone remains the reliable edge
  collector and offline cache until per-metric and per-data-class authority
  gates pass.
- Implement and verify bounded pager-grade app Safety, independent live-HR
  presentation controls, managed Friends parity, macOS viewer foundations,
  evidence-backed UI refinements, and the supplier wrapper handoff.
- Preserve the current WHOOP compatibility path for physical regression
  testing. The private `NoopBandSDK` repository now contains the binary-free
  neutral core and virtual conformance surface, and the app pins that export
  behind a disabled factory. It still does not contain an executable supplier
  adapter or firmware flasher. Keep real scanning, possession proof, history,
  haptics, OTA, and flashing behind the supplier-artifact and physical-device
  gates.
- Validate every material external finding against current source.
- Inspect representative current and proposed renders directly.
- Correct only evidence-backed formula explanation, terminology, loading,
  accessibility, navigation, and account-journey defects.
- Preserve Apple/Android meaning and identify intentional macOS/Watch
  asymmetries.
- Run bounded verification and report external release gates without converting
  source checks into physical-device or production claims.

## Immediate next actions

1. Commit the protected-base artifact-authority correction and push one exact
   replacement candidate to PR `#17`.
2. Require all ten exact-SHA contexts and resolve only reviewed threads covered
   by matching protected SDK, app source, and tests.
3. Merge normally only after Apple and Android app compilers/tests are green,
   verify protected `main`, and remove exact round-owned outputs and logs.
4. Restore the SDK repository's D-056 private visibility before release.
5. Execute the supplier adapter and flashing round only after the exact
   supplier artifacts, firmware project, rights/SBOM/security evidence, and
   representative physical units are available.
