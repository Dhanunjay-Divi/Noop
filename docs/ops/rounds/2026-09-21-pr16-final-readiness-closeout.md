# Round: 2026-09-21 - PR 16 final readiness closeout

## Status

- State: `four late review defects are corrected with focused evidence; final terminology refresh, exact-SHA hosted walls, and protected integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `84ee85eeb4aa711e2762591fe0a52dc2ba9cb4f3`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`

## Objective

Close the final source-verifiable review findings on the September 17-21
candidate:

1. preserve the terminal account fence after an ownership-led managed-data
   erasure;
2. make Apple managed-history import reachable and prevent restored preferences
   from creating an upload echo;
3. complete Android import, social-permission serialization, and deletion
   localization parity;
4. preserve formula, Safety repeat, and provider-dedup contracts;
5. remove proven unreferenced self-hosted Friends presentation copy without
   deleting the separate compatibility backup subsystem;
6. revalidate acknowledgement-before-prune retention behavior;
7. leave a complete independent-review prompt covering the customer journey,
   cloud migration, performance, dead code, competitor-pattern research, and
   external release gates;
8. reject local formula days whose civil window cannot be represented in UTC;
9. keep mixed Friends metric summaries unpublished until the canonical formula
   migration is complete;
10. make complete-history totals and chunk enumeration consistently select only
    server-readable chunks while retaining client-encrypted storage; and
11. reduce the hosted Android production-shell resource profile without
    weakening its tests; and
12. repair unified managed-account links created for identities or accounts that
   were already terminal when migration 047 ran; and
13. remove the Activity-lifecycle race from the Android app-report entrypoint
    without weakening review, screenshot consent, or delivery continuity;
14. make Android managed-history staging cancellation responsive during the
    initial selected-file copy while preserving prior durable state;
15. select the newest usable Watch heart-rate sample rather than allowing an
    implausible newest sample to hide an earlier valid reading;
16. reject formula-shadow client values outside the database persistence bound
    through the request contract instead of a database error; and
17. reject civil days skipped by a timezone transition before persistence.

## Scope

### In scope

- Apple and Android managed import, preferences, communication fields,
  localization, and retired presentation resources.
- Managed erasure, formula input, push collapse, Safety repeat, and plan-only
  infrastructure contracts.
- Bounded local retention and exact acknowledgement-before-prune behavior.
- Operations evidence, release handoff, and independent-review instructions.

### Non-goals

- Abruptly enabling cloud authority or deleting all local data.
- Removing the separate self-hosted backup compatibility path without an
  existing-user migration and deletion plan.
- Public deployment, production traffic, real paging, real identities, real
  health transfer, billing, signing, store submission, or hardware claims.

## Architecture boundary

- D-059 remains the authority contract. Durable account history, canonical
  versioned formulas, recommendations, and cross-device state move toward the
  managed service only through explicit per-data-class gates.
- One phone remains the BLE collector and keeps a bounded encrypted edge
  working set. A literal zero-local-data design would break offline collection,
  interrupted uploads, immediate Safety initiation, and rollback.
- Local pruning is allowed only after exact server acknowledgement and proven
  restore. Unacknowledged, dirty, changed, or unvalidated data remains local.
- Current retention tests cover the reviewed seven-day raw and 30-day essential
  client policy plus exact per-class cutoffs. These are policy contracts, not
  evidence of production cloud enablement.
- Friends is one NOOP-hosted account service under D-060. No routed Friends UI
  offers provider choice, local-server setup, or self-hosting. The separate
  optional decoded-data backup compatibility subsystem remains outside Friends
  and cannot be removed without an existing-user migration and deletion plan.
- Server-side canonical computation is staged and versioned. Client formulas
  remain deterministic fallbacks and parity shadows until each formula passes
  migration, provenance, restore, rollback, performance, security, and
  physical-device gates.

## Starting evidence

- Pull request `#16` still pointed to commit
  `84ee85eeb4aa711e2762591fe0a52dc2ba9cb4f3`.
- Independent review threads identified managed import reachability, preference
  upload echo, Android communication fields, ownership-led erasure completion,
  optional unusable formula baselines, Safety repeat/collapse, and localization
  gaps.
- The current routed Friends screens were already managed-only, but the Apple
  catalog and Android default resources still contained presentation entries
  with zero authored-code references from the retired self-hosted Friends UI.
- Prior complete Apple, Android, package, server, infrastructure, and policy
  walls were green on the recorded branch state. This closeout rechecks the
  changed boundaries rather than treating those old results as proof.

## Delivered

- Service-created `all_managed_data` erasure jobs now carry a durable
  service-origin marker. Completion keeps the account in `erasure_pending`,
  invalidates existing sessions, and rejects subsequent managed writes.
- Apple managed preference restore commits the remote document before applying
  defaults and rejects stale revisions, preventing restored or replayed values
  from becoming a new dirty outbox generation.
- Android exposes managed-history import through the document picker and sends
  all directional Friends communication permission fields. Android managed
  document restore also rejects stale document and preference revisions before
  applying local state.
- Published `noop-charge-v2` behavior remains unchanged; the review did not
  alter formula inputs or revision semantics. Android Safety payloads use
  incident collapse, the managed push path no longer depends on the legacy
  worker flag, and the GCP source explicitly configures minute-level bounded
  repeat evaluation while provider delivery and public traffic remain disabled.
- Server formula-shadow execution now omits optional RHR, respiration, and
  prior-effort baselines when their explicit usability flag is false, matching
  the existing client behavior without changing the published
  `noop-charge-v2` revision. Ownership-deletion managed-data claims now acquire
  the same account advisory lock used by cancellation and recheck the request
  after that lock, preventing an accepted pre-deadline cancellation from racing
  a post-deadline destructive claim.
- Formula civil-day construction now translates UTC conversion underflow or
  overflow into the existing input-contract rejection instead of allowing a
  schema-valid boundary date to escape as a server error.
- Apple and Android now defer the complete Friends summary document while
  canonical formula migration is incomplete. The document mixes Recovery,
  Effort, Rest, and non-derived fields, so partial publication would expose
  internally inconsistent social metrics.
- Complete-history restore creation and snapshot chunk enumeration now use the
  explicit `server_readable` content mode on the server, Apple, and Android.
  Existing client-encrypted chunks remain stored and replay-compatible, but are
  not counted or listed by a restore contract that has no chunk-key/decryption
  metadata.
- Forward migration 059 leaves immutable migration 047 byte-identical, removes
  only links created at migration 047's recorded timestamp for identities or
  accounts already terminal at that time, deletes their dependent managed
  authority rows, preserves matching active ownership roots, retires only true
  orphans, and restores all ordinary delete guards before commit. It avoids
  global ownership-table locks, follows the same deletion order as managed
  erasure, and preserves `deletion_pending` principals required for
  cancellation. Live regressions prove the former migration-versus-erasure
  deadlock no longer occurs and an ownership link created while the repair is
  blocked remains active and linked.
- Ownership registration serializes against unified-principal retirement
  through one schema-qualified security-definer function. Registration first
  establishes the principal lock order, then reconciles the ownership link
  after account/identity creation in the same transaction. Migration 059
  restores a schema-qualified ordinary link guard, so the helper's hardened
  `pg_catalog, pg_temp` search path cannot hide or shadow its control-plane
  tables. Migration 059 revokes public execution; runtime readiness and the
  credential provisioner verify the exact function signature, body, language,
  return type, principal-table owner, configuration, and non-grantable
  API-role-only execute ACL. Runtime roles also require database `TEMPORARY` to
  be revoked, and regressions cover temporary shadow tables, owner mismatch,
  registration-first preservation, and retirement-first rollback.
- A final independent database review closed four additional exactness gaps.
  Registration, authority reconciliation, and ownership deletion now derive
  the same privacy-safe advisory-lock key, so either no-principal race order
  converges without creating a second lock domain. Migration 059 can restore a
  principal retired by a completed pre-059 managed erasure only when an
  ownership identity and account already existed before retirement and the
  immutable erasure tombstone proves a managed identity link was deleted; it
  preserves the historical retirement timestamp as evidence. Runtime and
  provisioning checks now reject helper volatility drift and any runtime-owned
  ordinary PostgreSQL function, rather than checking table and sequence
  ownership alone.
- Apple and Android formula traversal now remove stale computed daily and
  managed Rest evidence when the exact historical window no longer has raw or
  imported inputs to rebuild it. Android threads the explicit traversal intent
  into the scorer and permits an atomic empty-window replacement only for that
  migration path; ordinary transient empty passes still preserve the last
  complete score window.
- Apple and Android historical-offload progress now advances only after the
  platform confirms the exact acknowledged write. Both stacks fence delayed
  persistence and callbacks across ended sessions; Apple reconnects
  fail-closed when a watchdog expires with a history acknowledgement in
  flight. The local `strap_trim` value is documented as a diagnostic watermark,
  while firmware-retained state remains the resume authority.
- Completed Apple and Android account-deletion localization parity.
- Removed 38 Apple localization entries and one Android resource family member
  that had zero authored-code references and belonged only to the retired
  self-hosted Friends presentation. Added platform ratchets that reject their
  return.
- Removed the remaining unreferenced Android self-hosted Friends view model and
  server-address invitation copy from all nine Android locales. The routed
  Friends destination remains the managed NOOP account service, and focused
  navigation/localization tests reject restoration of the retired source or
  copy. The separate compatibility backup subsystem remains unchanged.
- Android complete-history import now retains a cancellable coroutine handle,
  turns the import action into an enabled cancel command while work is active,
  cancels when the sheet leaves composition, preserves resumable checkpoints,
  and surfaces a localized canceled status. Managed Safety now treats an
  existing but OS-disabled preferred channel as blocked; standard-channel
  fallback is allowed only when the optional urgent channel is genuinely
  absent, so registration and delivery do not route around the setting the
  user disabled.
- The canonical app-wide localization source no longer contains the retired
  Friends invite-instructions key. Regenerated Apple and all nine Android
  locale outputs now agree exactly, and both platforms retain absence ratchets.
- Hosted Android production-shell execution now uses one Gradle worker and a
  1.5 GiB heap for both the primary run and its bounded retry. Review Sample
  isolation keeps its existing 2 GiB/two-worker profile, and all existing
  memory, disk, retry, and test-selection guards remain enabled.
- Updated the final independent-review prompt with the authority pipeline,
  storage/retention rules, dead-code criteria, performance and memory checks,
  end-to-end customer flow, and competitor-research safety boundary.
- Recorded the disconnected-band requirement as a firmware/SDK acceptance
  contract: bounded circular flash, oldest-only overwrite at capacity,
  retained-range and wrap/gap signaling, resumable durable-before-ack offload,
  and physical full-flash validation. Current WHOOP comparison paths already
  preserve durable-before-trim ordering; supplier behavior remains unproven.
- Reviewed the supplier handoff against current source. WHOOP discovery,
  connection, live collection, and history remain intact for physical
  regression testing. The separate private `NoopBandSDK` repository remains a
  binary-free scaffold plus integration documentation; this app does not yet
  contain an executable neutral supplier adapter or firmware flasher.
- Hosted candidate `825d015c` passed every required Apple, server, package,
  policy, release, and Android build wall except the API 35 production shell.
  Its new stale-formula Room regression passed all eight cases. Two existing
  app-report tests timed out before the sheet opened; their direct-controller
  screenshot test passed, isolating the failure to request delivery rather than
  report assembly.
- The process-global conflated report channel could deliver one request to an
  Activity collector that was retiring. Test Centre now receives a
  compiler-required callback from the current `MainActivity` through
  `NoopRoot` and `AppRoot`; shake and debug-demo requests continue to call the
  same Activity-owned controller directly. There is no global report mailbox,
  stale collector, replay buffer, or timeout increase. The content,
  attachment-consent, outbox, and delivery state machines are unchanged.
- Exact hosted candidate
  `e1eaa4deafbc1b986e933037acaaec3d4e7367da` proves the correction in the
  API 35 production shell. Android production shell, Review Sample shell,
  build-and-test, and the aggregate Android context pass; iOS, macOS, server,
  Swift packages, operations, localization, health-claims, runtime-license,
  and trust checks also pass. The sole hosted failure is the fail-closed
  release-control snapshot test because the reviewed Android source and
  operations records moved existing terminology line numbers and file
  digests. Counts remain 17,846 occurrences across 1,585 groups, category
  totals are unchanged, the active customer/core allowlist is byte-identical,
  and the audit reports zero forbidden mappings.
- The reviewed inventory was regenerated and its exact SHA-256 was repinned in
  the required-CI trust root. The exact 191-case release-control unit wall then
  passed, as did the standalone 9-check release-control report, required-CI
  ten-context check, trusted self-verification, shell entrypoints, calibration
  parity, distribution provenance, private-data filename guard, terminology
  ratchet, operations validation, and diff hygiene.
- A fresh exact-head review then identified four P2 contract defects. Android
  managed-history staging now checks coroutine cancellation around every copied
  chunk, removes the temporary archive, and leaves the previous committed
  archive and checkpoint untouched. Apple already used a chunked,
  cancellation-aware copy with an equivalent regression, so no Apple source
  change was needed.
- Watch live heart rate now filters each candidate by freshness and plausible
  BPM before choosing the newest usable sample. An invalid newest sample no
  longer hides an earlier valid sample, and an initial batch with no usable
  sample enters the existing no-readable-sample state.
- Formula-shadow request validation now enforces the migration-049 finite
  persistence bound of plus or minus `1e308`; adjacent out-of-range floats
  receive the existing 422 contract response. Formula execution independently
  applies the same bound. Missing and not-supplied observation semantics remain
  unchanged.
- Formula civil-day construction now rejects a converted UTC interval whose end
  is not strictly after its start. The skipped `2011-12-30` day in
  `Pacific/Apia` therefore fails with `FormulaInputContractError` before any
  repository write, while adjacent days remain valid.
- Superseded Apple, Android, server, and package workflows for `1d475d21` and
  `3b69ee07` were canceled after the review defects were known, avoiding
  unnecessary Actions spend. The host had only 3.4-4.0 GiB free and 8.7 GiB
  swap in use, so no heavy local wall was run below the unchanged 10 GiB floor.
  Exact worker-created Android build and temporary Watch/typecheck outputs were
  removed after the workers stopped.

## Data, privacy, and medical truth

- Schema or migration impact: forward migration 059 repairs only unified
  identity-control rows created by the historical migration-047 backfill.
  Migration 047 remains byte-identical. The repair removes terminal managed
  links and retires only resulting orphan principals; it adds no health-data
  table or payload.
- Existing-data retention impact: no local or cloud health row is deleted by
  this slice. The retention contract remains exact acknowledgement plus proven
  restore before pruning.
- Performance impact: no dashboard, scrolling, or high-frequency render path
  changed. The BLE history acknowledgement path changed only at chunk
  boundaries and callback/session bookkeeping; focused tests support no known
  regression in the exercised paths, not an absolute claim about physical
  throughput, battery, or radio behavior.
- Dead-code impact: only exact unreferenced presentation resources were
  removed. Historical migrations, protocol compatibility, export/import
  provenance, and existing-user cleanup paths are not classified as dead merely
  because a current screen does not call them.
- Permissions/network impact: no public ingress, production health transfer,
  provider paging, or telemetry was enabled.
- Formula/medical impact: no physiological formula or claim was strengthened.
  Simulator, unit, and synthetic results do not establish metric accuracy.

## Observability

- Existing mobile managed-import/export, sync, account deletion, Safety, and
  server request/lifecycle events already expose fixed success, retry,
  rejection, and failure outcomes with bounded counts and durations.
- The preference-restore ordering and localization cleanup are deterministic
  local boundaries; no new event is warranted.
- The erasure fence is observable through the existing bounded lifecycle state
  and direct write rejection. Tests use synthetic identities and inspect
  database/account state without logging identifiers, payloads, health values,
  tokens, contact data, or arbitrary exception text.
- Existing bounded band diagnostics distinguish a queued acknowledgement,
  confirmed acknowledgement, watchdog expiry, callback failure, disconnect,
  and session end using fixed outcomes and aggregate counts. No address,
  serial, raw frame, sensor timestamp, health value, or platform error text was
  added.
- Managed-history cancellation continues to use the existing bounded
  `managed_import` terminal outcome and now adds only a localized UI status.
  Safety channel selection continues to record the fixed
  `managed_safety.channel_readiness` category; no channel names, incident
  identifiers, contact data, or notification payloads enter diagnostics.
- Formula day-bound validation and migration-059 repair are deterministic
  request/schema boundaries with direct contract and database-state tests.
  Existing request status and migration-ledger evidence is sufficient; adding
  payload-bearing or per-row logs would increase privacy and volume risk
  without improving diagnosis.
- Managed-import cancellation continues through the existing bounded
  `managed_import` operation outcome; the new checks add no sample, path,
  account, or archive data. Watch selection and formula validation are
  deterministic input filters whose existing state/HTTP outcomes identify
  rejection without logging heart-rate or formula values.
- Android report requests now emit one bounded `report.request` event with only
  fixed `source` and `outcome` categories. It distinguishes `opened`,
  `already_open`, `debounced`, and `existing_delivery` without recording an
  Activity, request token, note, screenshot, report payload, or identifier.
- Remaining blind spots are physical BLE/background behavior, provider
  delivery, production cloud latency/load, and real-device performance.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple managed lifecycle contract | 13 passed, 0 failed | Managed deletion, import/restore, localization, and retired-copy ratchets compile and pass on macOS | iPhone physical behavior, live service access, or notification delivery |
| Android localization contract | 6 passed, 0 failed | Complete/partial locale parity remains valid and the retired self-hosted Friends source label is absent | Physical locale switching or TalkBack |
| Android managed retention coordinator | 19 passed, 0 failed | Per-class cutoffs, resumable upload/restore, document ordering, and acknowledgement/prune contracts pass | Low-storage/process-death behavior on a physical phone |
| Swift remote-retention store | 6 passed, 0 failed | Only acknowledged rows older than the cutoff are deleted and a validated managed window is marked locally pruned | Production cloud restore or large-account soak |
| Managed erasure service unit suite | 4 passed, 3 PostgreSQL-gated skips | The consolidated service-erasure helper preserves unit contracts | The separately recorded live PostgreSQL terminal-fence result or production contention |
| Changed server Ruff wall | 7 files pass check and format | The final server source is linted and canonically formatted | Runtime behavior |
| Earlier focused terminal-fence PostgreSQL test | Passed against a disposable local PostgreSQL cluster; exact cluster and dependency target removed afterward | Service-owned erasure completion leaves the account fenced and a refreshed identity cannot write managed data | Production Cloud SQL or elapsed deletion operations |
| Earlier managed client walls | Swift adapter 12/12; Android managed/account/storage/localization 72/72 | Reachable import, preference-echo prevention, social fields, account scope, and scheduler contracts pass | Signed-device, provider, or physical behavior |
| Earlier server/infrastructure walls | Focused server suite, Ruff, OpenTofu 20/20, and deployment contracts passed | Formula, Safety repeat/collapse, erasure, and plan-only runtime wiring remain coherent | Applied infrastructure or provider delivery |
| Final server review remediation | 39 focused unit/contract cases passed; 4 focused disposable-PostgreSQL race/erasure cases passed; Ruff 0.12.2 check and format passed on all 5 changed files | Unusable optional baselines are omitted and renormalized; cancellation and managed deletion claims serialize on the account fence | Production Cloud SQL contention, elapsed deletion operations, or formula accuracy |
| Final formula and unified-principal remediation | The earlier broad database/provisioning wall passed 21/21. After the final independent review, the exact late focused wall passed 19/19 for the shared no-principal advisory key, pre-059 completed-erasure ownership restoration, negative late-ownership case, helper volatility, `pg_proc` ownership, manifests, and provisioning contracts. Migration 047 retained SHA-256 `3159e5f01eff093e7048bae091f19e2128ae6f436e7fa14e33a4e8d56703d324`, and both manifests pin migration 059 at `f8fbc7171eaae23b6f5aa8c48c12613189a4ad2567e22c9807eea84c2e8ea1cd` | UTC-underflowing formula days fail with the contract error; only historically proven terminal managed links or exact pre-059 erasure cases are repaired; active and cancellation-relevant principals are preserved; schema qualification, runtime privilege, function ownership/volatility, ownership-link creation, and lock ordering are exact in the tested database | Production Cloud SQL lock duration, live deployment contention, or physiological formula accuracy |
| Exact-current complete server wall | 800 passed, 1 explicitly opt-in Twilio staging skip, 0 failures/errors across 801 collected tests on a separate fresh PostgreSQL database; one known Starlette deprecation warning | All applicable synthetic server, migration, account, Friends, Safety, formula, lifecycle, history-mode, least-privilege, and deployment contracts pass with migrations through the final 059 repair | Production load, provider delivery, real identities/data, or elapsed lifecycle operations |
| Exact-current server Ruff wall | Earlier check and format passed across 100 server application/test files plus the ownership provisioner, 101 release-scoped Python files; final check and format also pass on the seven files changed by the independent database review | The final server/provisioning Python files changed by this round are linted and canonically formatted | SQL behavior or runtime correctness |
| Late cross-platform review closure | Apple formula 12/12, screen-state 15/15, and app-wide localization 3/3; `NoopRemoteSync` 192/192; Android Full and Demo each 64/64 focused final cases | Formula-gated Friends summaries, checkpoint-v2 restore fencing, server-readable complete-history selection, regenerated localization, and both Android variants compile and pass together | Full hosted platform walls, physical devices, live cloud transfer, or metric accuracy |
| Final Apple review remediation | 56/56 requested focused cases, 10/10 managed-archive cases, and 10/10 formula cases passed; hosted macOS build passed on candidate `149843c1` | Import reachability, formula migration invalidation, BLE re-arm recovery, macOS viewer transport, and account-task cancellation regressions remain covered | Physical iPhone/macOS behavior, live managed service access, or hardware reconnect timing |
| Final Android review remediation | Full and Demo each passed 62/62 selected unit cases; Full completed 41 tasks and Demo 58 tasks; app Kotlin and instrumentation-source compilation passed for both variants | Managed account-scope compatibility, managed storage/social serialization, localization/navigation, and removal of the retired Friends presentation compile together | The new account-scope instrumentation case executing on an emulator or physical phone |
| Late Android review remediation | Full and Demo each passed 12/12 import/Safety cases while compiling app and instrumentation sources; after the localization ratchet each variant passed 18/18 focused cases. Full completed 41 tasks, Demo 58 tasks, and the combined locale rerun 57 tasks | Long managed-history imports have an explicit cancel path and localized terminal status; disabling the active Safety channel blocks registration/delivery while a missing urgent channel may still use the enabled standard fallback | Physical notification-settings behavior, process death during import, or emulator execution of instrumentation cases |
| Android stale-formula follow-up | `ChargeFormulaUpgradeGateTest` passed 3/3; the Full-debug app and complete instrumentation test source compiled in a 41-task bounded Gradle run. The new Room regression is included in the hosted production-shell suite | Formula traversal selects an empty score-window reconciliation, that reconciliation deletes only the computed daily and managed Rest rows, and imported owners plus unrelated series remain untouched | API 35 execution of the new Room regression, physical-device behavior, or formula accuracy |
| Hosted `825d015c` candidate | 29 hosted checks passed, three were intentionally skipped, and the final Apple and Android build jobs passed. The API 35 production shell alone failed two existing app-report tests at their initial sheet-open waits; the new Room formula regression passed all 8 cases | The candidate is coherent across every other protected wall and the failure is isolated to Activity-bound report request delivery | The corrected report entrypoint or protected integration |
| Android app-report lifecycle correction | The repository-standard 4 GiB one-worker run passed `AppDiagnosticReportEntryPointTest`, compiled the Full app, and compiled all Full instrumentation source across 41 tasks. A deliberate 1.5 GiB local attempt stopped in the Compose compiler with heap exhaustion before tests. On exact hosted SHA `e1eaa4de`, Android production shell, Review Sample shell, build-and-test, and the required Android aggregate all pass | The current Activity owns Test Centre invocation, no global replay state remains, callback wiring compiles through production navigation, and the API 35 report tests execute successfully against the new entrypoint | Physical shake delivery or report upload service behavior |
| Android managed-import staging cancellation | Commit `e1e94c67` adds two deterministic regressions for mid-copy cancellation and matching/different checkpoint replacement. Lightweight source and diff checks pass; the bounded Gradle run was stopped before Kotlin compilation when host storage remained below the 10 GiB floor | Cancellation is checked around each copy chunk, partial staging is removed, and the previously committed archive/checkpoint remains unchanged in the focused contract | Android compilation/execution, blocked content-provider reads, process death, or physical document-provider behavior; these remain in hosted/physical gates |
| Watch live-HR sample selection | Commit `3b69ee07` passed Watch source type-check, XCTest source type-check, two deterministic selection-policy checks, and diff hygiene | Freshness and plausible BPM are applied before newest-sample selection; invalid-newest/valid-earlier and no-valid-initial-batch cases are ratcheted | HealthKit delivery, authorization, sensor accuracy, or physical Watch behavior |
| Formula persistence-bound and skipped-day validation | Commit `5778e2f0` passes 29 executor tests, 9 focused model/API cases, and Ruff check/format. Exact `+/-1e308` boundaries pass; adjacent floats receive 422; `Pacific/Apia` 2011-12-30 is rejected and adjacent days remain valid | Request and executor validation match the database numeric bound, preserve absence semantics, and reject zero/non-positive UTC civil windows before persistence | The broad PostgreSQL/server wall, production timezone database drift, load, or physiological formula accuracy |
| Final terminology and policy wall | 17,846 occurrences across 1,585 groups with zero forbidden mappings and a byte-identical active allowlist; the reviewed inventory digest is repinned. The exact 191-case release-control unit wall, standalone 9-check release-control report, required-CI 10-context check, trusted self-verification, shell entrypoints, calibration parity, distribution provenance, private-data guard, operations validation across 82 records, and diff hygiene pass. The earlier complete repository wall passed 355 tests plus 44 subtests, legal inventory verified 230 runtime components and 3 container inputs, and health-claims scanned 1,297 files | The reviewed terminology snapshot, localization catalogs, ten-context release-control contract, operations records, privacy/claims guards, and repository policy tests match the final local tree | Replacement hosted exact-SHA release controls, protected-main trust, physical localization/accessibility, or removal of the separately baselined hardcoded-literal debt |
| Apple history acknowledgement and generation fence | 23 passed, 0 failed after the final watchdog correction | FIFO callback correlation, callback-only trim credit, and delayed persistence rejection compile and pass in the macOS app target | CoreBluetooth callback timing or firmware trim behavior on a physical band |
| Android history acknowledgement and generation fence | Expanded six-class Full-debug selector wall passed; Gradle build succeeded | Callback-only acknowledgement, write single-delivery, drain gates, continuation, burst progress, and delayed-session fencing compile and pass | Android GATT timing, process death, or firmware behavior on a physical phone and band |
| Android Full instrumentation source compile | 33 tasks completed; build succeeded | The changed Room managed-document instrumentation test and Full app instrumentation source compile together | Emulator execution or physical-device behavior |
| Repository policy/tool wall | 355 passed plus 44 subtests after the completed Apple DerivedData was removed and the required 10 GiB bounded-runner test floor was restored; all standalone gates listed above pass | The exact dirty candidate satisfies current local release-control contracts; the earlier six failures were fully explained by stale generated terminology evidence and the host being below the bounded-runner disk floor | Hosted exact-SHA checks or protected-branch enforcement |
| Exact-current Swift package walls | `NoopRemoteSync` 192/192; `WhoopStore` 539/539 | Managed document revision monotonicity, preference replay, checkpoint-version fencing, account/Friends/Safety, retention, storage, and metric contracts pass together | App lifecycle, BLE, live service, or physical-device behavior |
| Exact-current complete macOS wall | 2,213 executed; 1 intentional skip; 0 failures | The complete shared Apple app and contract source passes with the final managed and BLE changes integrated | Signed distribution, live service access, BLE hardware, or physical accessibility |
| Exact-current unsigned Release iOS graph | Build succeeded with 0 compiler warnings and 0 errors; Watch app and widget extension embedded and validated | iPhone, Watch, complications, widget, managed-account, localization, and shared app source compile together in Release | Signing, App Store distribution, background suspension, or physical-device behavior |
| Exact-current iOS simulator production shell | 39 executed; 1 intentional skip; 0 failures | First-run, Today, Trends loading/retry, compact copy, updates inbox, and the bounded scroll path pass on the required simulator | Physical performance, Bluetooth, push presentation, haptics, or accessibility hardware |
| Exact-current Android Full and Demo wall | 175 tasks succeeded in 6m 4s; each variant executed 4,972 tests with 7 intentional skips and 0 failures/errors; app and instrumentation APKs, lint, and unit tests passed | Both Android variants compile and pass with managed restore, localization, and callback-confirmed BLE history integrated | API 35 managed-device execution, physical GATT/background behavior, push, TalkBack, or battery |
| Earlier exact-current disposable PostgreSQL 14 server wall | 784 passed; 1 intentional skip; 2 framework deprecation warnings before migration 059 and its tests were added | The earlier complete synthetic server suite passed with terminal erasure fencing, Safety cadence/push, formula preservation, deployment contracts, and account/Friends behavior | The final migration-059 tree, Cloud SQL, production load, provider delivery, or real identities/data |
| Exact-current GCP plan-only wall | Formatting and validation passed; 20 OpenTofu tests passed, 0 failed; temporary provider data removed | Changed runtime identities, pinned database secrets, disabled defaults, and fail-closed plan contracts are coherent without apply | Deployed IAM, secrets, drift, public traffic, or production runtime behavior |

One machine-readable diagnostic rerun was invalid because its test environment
omitted `NOOP_TEST_DATABASE_ENGINE=postgresql`; TimescaleDB-default test modules
therefore rejected the PostgreSQL migration-001 checksum. That run collected
801 tests and reported 29 manifest-mismatch failures, 771 passes, and one skip.
The disposable database was removed. A fresh database with the explicit
PostgreSQL engine produced the exact-current 800-pass/one-skip result above.

The first local Android stale-formula compile and the later app-report
entrypoint compile each used the hosted production-shell 1.5 GiB heap and
stopped with Kotlin/Compose compiler heap exhaustion before tests ran. The
repository-standard 4 GiB local heap completed both focused unit tests and
Full-debug instrumentation-source compiles successfully. This is a local
resource-profile distinction, not a source-test failure; hosted Linux retains
its separately proven 1.5 GiB production-shell contract.

A matching local Demo-flavor rerun was attempted only after deleting the
recorded Full build outputs, but the bounded runner again stopped before tests
when free disk crossed the unchanged 10 GiB floor. The floor was not weakened.
Demo compilation/execution for this final shared-source follow-up therefore
remains part of the required exact-SHA hosted Android jobs.

Before the rerun, the disposable `noop_pr16_final_r10` PostgreSQL database and
the exact completed `/private/tmp/noop-pr16-*` logs, artifacts, and virtual
environment were removed. The active review-thread snapshot and the two new
Android follow-up log/status pairs were retained until protected integration
evidence is durable. No unrelated worktree, process, cache, simulator, user
data, or cloud resource was removed.

## Physical device and deployment

- Install/update action: not run in this closeout.
- Real health data: not used.
- Public traffic or provider delivery: not enabled.
- Physical BLE, background collection, Watch connectivity, haptics, battery,
  notification sound/presentation, step accuracy, workout detection accuracy,
  and physiological accuracy remain external gates.

## Git and release state

- Pull request: `#16`
- Current remote PR head:
  `3b69ee07e778fac3ca2e64676352c0fdcfb008cf`
- Current local head:
  `5778e2f0432286c8f78ccfb8bcee17fa8f8c7f48`
- Local unpublished commits `e1e94c67` and `5778e2f0` contain the Android
  cancellation and server formula corrections. The remote Watch-only heavy
  workflows and the preceding evidence-only heavy workflows were canceled once
  their SHAs became non-mergeable; completed policy evidence remains retained.
- Required next state: regenerate and repin terminology evidence for this final
  source/document state, create one narrow operations/evidence commit, push the
  combined candidate, require all ten protected contexts green on that exact
  SHA, resolve the four corrected review threads, merge normally, verify
  protected `main`, and perform exact round-owned cleanup.

## Open risks and honest limitations

- No source review can prove zero lag, zero dead code across every conditional
  platform branch, or physiological accuracy. Claims stay bounded to the
  compiled and exercised surfaces.
- Application-level SQLCipher encryption is not implemented. Current mobile
  stores rely on Apple file protection/platform disk encryption and Android
  device encryption; stronger database encryption needs a separately reviewed
  key-recovery, migration, performance, backup, and rollback design.
- Existing-user authority migration, production identity/App Check, public
  ingress, Cloud SQL role provisioning, restore/load/soak, signed push,
  billing, legal, carrier, store, supplier SDK, firmware, and physical-device
  evidence remain open.
- WHOOP remains the only executable comparison transport currently wired into
  the app. The supplier-neutral SDK boundary, virtual adapter, and app
  integration still require a separate implementation round; real supplier
  scanning, possession proof, history, haptics, OTA, and flashing additionally
  require the exact supplier artifacts and physical bands.
- No source-only test can prove the supplier band's autonomous disconnected
  sampling, actual flash depth, oldest-only overwrite, wrap/gap report, or
  power-loss behavior. Those remain explicit per-model firmware and physical
  acceptance gates.

## Decisions

- No new authority flip is approved. D-059 remains staged and fail-closed.
- D-060 continues to prohibit self-hosted Friends UI. Proven orphan
  presentation resources are removed, while the separate backup compatibility
  subsystem remains until an explicit migration decision closes it safely.
- A bounded edge cache with exact acknowledgement and restore before prune is
  required. "Zero local data" is rejected as unsafe for BLE/offline/Safety
  behavior.

## Next round

1. Regenerate the reviewed terminology inventory from the final documentation
   state, repin its digest, and rerun the lightweight release-control wall.
2. Commit and push the combined late-review correction to pull request `#16`.
3. Require all ten hosted contexts on the exact candidate SHA.
4. Resolve the four review threads only after the exact source and hosted
   evidence prove their corrections.
5. Merge normally, verify protected `main`, synchronize the canonical
   worktree, and remove exact round-owned generated outputs and logs.
6. Open a separate SDK-boundary round from protected `main`; implement and test
   the binary-free neutral core/virtual adapter without replacing the WHOOP
   default, then add any supplier adapter only after artifact and physical
   acceptance gates are available.

## Privacy check

- [x] No credentials, customer identifiers, health values, contact details,
      precise locations, signing identities, or private reference inputs are
      present.
