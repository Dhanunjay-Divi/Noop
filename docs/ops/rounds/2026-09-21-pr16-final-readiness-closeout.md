# Round: 2026-09-21 - PR 16 final readiness closeout

## Status

- State: `review remediation and supplier-independent local verification complete; final consolidated commit, hosted checks, and protected integration pending`
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
6. revalidate acknowledgement-before-prune retention behavior; and
7. leave a complete independent-review prompt covering the customer journey,
   cloud migration, performance, dead code, competitor-pattern research, and
   external release gates.

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
- Added an integration regression proving formula migration removes stale
  computed daily and Rest evidence when retained raw HR is unavailable before
  marking the traversal complete.
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
- Updated the final independent-review prompt with the authority pipeline,
  storage/retention rules, dead-code criteria, performance and memory checks,
  end-to-end customer flow, and competitor-research safety boundary.
- Recorded the disconnected-band requirement as a firmware/SDK acceptance
  contract: bounded circular flash, oldest-only overwrite at capacity,
  retained-range and wrap/gap signaling, resumable durable-before-ack offload,
  and physical full-flash validation. Current WHOOP comparison paths already
  preserve durable-before-trim ordering; supplier behavior remains unproven.

## Data, privacy, and medical truth

- Schema or migration impact: none in this closeout slice.
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
| Final Apple review remediation | 56/56 requested focused cases, 10/10 managed-archive cases, and 10/10 formula cases passed; hosted macOS build passed on candidate `149843c1` | Import reachability, formula migration invalidation, BLE re-arm recovery, macOS viewer transport, and account-task cancellation regressions remain covered | Physical iPhone/macOS behavior, live managed service access, or hardware reconnect timing |
| Final Android review remediation | Full and Demo each passed 62/62 selected unit cases; Full completed 41 tasks and Demo 58 tasks; app Kotlin and instrumentation-source compilation passed for both variants | Managed account-scope compatibility, managed storage/social serialization, localization/navigation, and removal of the retired Friends presentation compile together | The new account-scope instrumentation case executing on an emulator or physical phone |
| Late Android review remediation | Full and Demo each passed 12/12 import/Safety cases while compiling app and instrumentation sources; after the localization ratchet each variant passed 18/18 focused cases. Full completed 41 tasks, Demo 58 tasks, and the combined locale rerun 57 tasks | Long managed-history imports have an explicit cancel path and localized terminal status; disabling the active Safety channel blocks registration/delivery while a missing urgent channel may still use the enabled standard fallback | Physical notification-settings behavior, process death during import, or emulator execution of instrumentation cases |
| Final terminology and policy wall | 17,840 occurrences across 1,585 groups with zero forbidden mappings; 54 focused terminology/required-CI tests and the complete 305-test tool wall passed with one intentional skip | The reviewed terminology snapshot, ten-context release-control contract, and repository policy tests match the final local tree | Hosted exact-SHA results or protected-main trust |
| Apple history acknowledgement and generation fence | 23 passed, 0 failed after the final watchdog correction | FIFO callback correlation, callback-only trim credit, and delayed persistence rejection compile and pass in the macOS app target | CoreBluetooth callback timing or firmware trim behavior on a physical band |
| Android history acknowledgement and generation fence | Expanded six-class Full-debug selector wall passed; Gradle build succeeded | Callback-only acknowledgement, write single-delivery, drain gates, continuation, burst progress, and delayed-session fencing compile and pass | Android GATT timing, process death, or firmware behavior on a physical phone and band |
| Android Full instrumentation source compile | 33 tasks completed; build succeeded | The changed Room managed-document instrumentation test and Full app instrumentation source compile together | Emulator execution or physical-device behavior |
| Repository policy/tool wall | 305 passed, 1 intentional skip; required-CI 10-context contract, operations records, terminology ratchet, and diff checks pass | The exact dirty candidate satisfies current local release-control contracts | Hosted exact-SHA checks or protected-branch enforcement |
| Exact-current Swift package walls | `NoopRemoteSync` 190/190; `WhoopStore` 539/539 | Managed document revision monotonicity, preference replay, account/Friends/Safety, retention, storage, and metric contracts pass together | App lifecycle, BLE, live service, or physical-device behavior |
| Exact-current complete macOS wall | 2,213 executed; 1 intentional skip; 0 failures | The complete shared Apple app and contract source passes with the final managed and BLE changes integrated | Signed distribution, live service access, BLE hardware, or physical accessibility |
| Exact-current unsigned Release iOS graph | Build succeeded with 0 compiler warnings and 0 errors; Watch app and widget extension embedded and validated | iPhone, Watch, complications, widget, managed-account, localization, and shared app source compile together in Release | Signing, App Store distribution, background suspension, or physical-device behavior |
| Exact-current iOS simulator production shell | 39 executed; 1 intentional skip; 0 failures | First-run, Today, Trends loading/retry, compact copy, updates inbox, and the bounded scroll path pass on the required simulator | Physical performance, Bluetooth, push presentation, haptics, or accessibility hardware |
| Exact-current Android Full and Demo wall | 175 tasks succeeded in 6m 4s; each variant executed 4,972 tests with 7 intentional skips and 0 failures/errors; app and instrumentation APKs, lint, and unit tests passed | Both Android variants compile and pass with managed restore, localization, and callback-confirmed BLE history integrated | API 35 managed-device execution, physical GATT/background behavior, push, TalkBack, or battery |
| Exact-current disposable PostgreSQL 14 server wall | 784 passed; 1 intentional skip; 2 framework deprecation warnings | The complete synthetic server suite passes with terminal erasure fencing, Safety cadence/push, formula preservation, deployment contracts, and account/Friends behavior | Cloud SQL, production load, provider delivery, or real identities/data |
| Exact-current GCP plan-only wall | Formatting and validation passed; 20 OpenTofu tests passed, 0 failed; temporary provider data removed | Changed runtime identities, pinned database secrets, disabled defaults, and fail-closed plan contracts are coherent without apply | Deployed IAM, secrets, drift, public traffic, or production runtime behavior |

## Physical device and deployment

- Install/update action: not run in this closeout.
- Real health data: not used.
- Public traffic or provider delivery: not enabled.
- Physical BLE, background collection, Watch connectivity, haptics, battery,
  notification sound/presentation, step accuracy, workout detection accuracy,
  and physiological accuracy remain external gates.

## Git and release state

- Pull request: `#16`
- Remote PR head after the consolidated review remediation:
  `1b61ebcac5c0803e6025c0491d1b36feb7aa7af1`
- Local tree: two newly confirmed Android review corrections, their localized
  copy and tests, the regenerated terminology snapshot/release-control digest,
  and updated operations evidence remain to be committed.
- Required next state: one narrow follow-up commit and push, all ten protected
  contexts green on the exact SHA, every proven review thread resolved, normal
  protected merge, protected-main verification, and exact round-owned cleanup.

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

1. Review the exact late Android remediation diff and create its follow-up
   commit.
2. Push that reviewed follow-up to pull request `#16`.
3. Require all ten hosted contexts on the exact candidate SHA.
4. Resolve only review threads proven by the final source and evidence.
5. Merge normally, verify protected `main`, synchronize the canonical
   worktree, and remove exact round-owned generated outputs and logs.

## Privacy check

- [x] No credentials, customer identifiers, health values, contact details,
      precise locations, signing identities, or private reference inputs are
      present.
