# Round: 2026-09-14 - PR 15 late review closeout

## Status

- State: `supplier-independent product, simulator, and generated-tree policy verification complete; final diff review, immutable commit, hosted checks, protected integration, privacy restoration, and final cleanup remain`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `f7350d6eb9cee1dd9a903e5ab73d16f049607bc6`
- Current committed head: `0ff1bf4657c45f836aaec32f920a8b528f6b552b`
- End implementation commit: pending final verified commit
- Record commit or PR: pull request `#15`
- Local verification finalized: supplier-independent product, simulator, and
  generated-tree policy walls complete on `2026-09-17`

## Objective

Close the final source-verifiable review findings before protected integration:

- record bounded local-only timezone provenance on Apple and Android, use the
  named zone's rules for historical civil days, represent 23-hour and 25-hour
  days exactly, and defer work whose capture zone is not supportable;
- migrate explicit legacy Apple hydration rows exactly when their retired
  scalar projection is equal or lower; preserve both representations when the
  scalar is higher and require one explicit choice before mutation; preserve
  an explicit empty list or scalar-only zero as a clear and converge a positive
  scalar-only day on one stable aggregate entry;
- re-arm opted-in daily-review and hydration reminders when notification
  permission returns while the app is already running;
- keep hydration reboot and wall-clock reconciliation behind the current Terms
  receipt before any WorkManager access, including the scheduler and worker
  boundaries;
- retain the hydration reminder opt-in while OS notification permission is
  unavailable without allowing an in-flight restore to undo a later opt-out;
  keep already-mounted Hydration and Automations toggles aligned with that
  retained intent; and
- require explicit, currently authorized Safety location sharing, reject stale
  or unusable fixes before transport, and keep the server's latest-only
  location inside the same five-minute freshness contract; and
- treat a matching request-id replay as the original accepted Safety incident
  without requiring the response to echo a newer retry location, while still
  rejecting a new non-duplicate incident that omits its accepted initial
  location; and
- do not report an Android feedback archive as queued until WorkManager has
  durably accepted the enqueue operation, and leave a rejected enqueue in one
  visible retryable state; and
- make managed-document restore monotonic so stale revisions cannot overwrite
  newer local rows, equal-revision divergence fails closed, and a legacy
  nullable deletion marker can be enriched exactly once; and
- make the local long-running-command guard atomic, resource-bounded, and
  interruption-safe so verification cannot become the source of an
  application-memory or orphan-process incident.

## Scope

### In scope

- Apple and Android analysis-zone history, civil-day selection, and focused
  planner tests.
- Apple hydration migration and focused persistence tests.
- Apple hydration aggregate presentation and localization.
- Apple notification lifecycle restoration and focused policy tests.
- Cross-platform managed Safety location consent, accuracy, freshness, and
  latest-only lifecycle tests.
- Android feedback scheduling and WorkManager instrumentation/source tests.
- Android diagnostic-report launch request delivery and API 35 shell tests.
- Managed-document remote-apply ordering and conflict tests.
- Limited independent-review corrections to workout-guidance presentation,
  civil-day fail-fast validation, accessibility, and localization.
- Exact affected platform verification, operations records, hosted checks,
  protected integration, privacy restoration, and round-owned cleanup.

### Non-goals

- Metric formula, threshold, or medical-inference changes. Corrected civil-day
  membership can legitimately change a transition-day aggregate without
  changing its formula. Narrow recommendation presentation, notification
  lifecycle, accessibility, and localization corrections found by independent
  review are in scope; a broader coaching-content rewrite is not.
- Enabling feedback ingress, managed health-data transfer, public traffic, or
  real Safety paging.
- Claiming physical-device delivery, BLE, background execution, battery,
  haptics, or clinical accuracy from simulator and automated tests.
- Supplier firmware, SDK loading, band pairing, calibration, or representative
  physical-device work; the owner deferred those items until the weekend.

## Starting evidence

- Historical scoring had epoch timestamps but no durable capture-zone
  provenance. Reusing the current zone can assign old data to the wrong local
  day after travel, while a fixed 86,400-second window can omit or duplicate
  part of a daylight-saving transition day.
- Apple retained both explicit legacy drink rows and a retired scalar
  projection. Old add and edit paths wrote those surfaces in opposite orders,
  so disagreement has no trustworthy direction. Scalar-only history also has
  no evidence for individual drink times.
- An explicit empty legacy drink list bypassed the managed ownership
  disposition used by non-empty rows. In a signed-in profile, that ownerless
  preference could therefore clear a saved scalar that belonged to the active
  managed account.
- The iOS scene-active handler restores only wind-down scheduling.
- Apple hydration reminder authorization maps `.denied` to permanent disable.
- An in-flight hydration restore or reschedule can outlive an explicit opt-out.
- Android's initial, retry, and cancellation feedback paths return before the
  asynchronous WorkManager enqueue operation completes. A rejected enqueue can
  leave staged work recoverable even after the UI says it was not queued.
- Android diagnostic-report launch requests used a zero-replay shared flow, so
  a request emitted before the Activity collector started could be silently
  discarded and leave the report screen waiting indefinitely.
- Managed-document restore mutated local rows before consistently deciding
  whether an incoming revision was stale, equal, or conflicting. That allowed
  stale data to regress a newer row and gave equal-revision divergence no
  uniform fail-closed contract.
- Managed Safety could silently downgrade a requested location-sharing
  incident when permission was absent, retry after authorization had been
  revoked, substitute a 10-kilometre accuracy value, and accept a fix whose
  timestamp was still near incident creation but no longer fresh at the
  server.
- The bounded command helper wrote status non-atomically, could accumulate
  timed-out resource-probe threads, and had interruption and completion races
  that weakened its process-group cleanup guarantee.

## Delivered

- Apple and Android durably retain at most 256 local-only timezone observations
  while preserving the first and latest point of each same-zone run. The first
  observation opens provenance support from that observation forward; earlier
  raw history and the first partial civil day are withheld rather than being
  assigned to the phone's current zone. Once retention discards evidence, the
  discarded interval also fails closed. The interval between the last
  observation in an old zone and the first observation in a new zone remains
  unresolved rather than being silently assigned to either side. The latest
  observed run stays open-ended for normal foreground planning.
- Both platforms use the selected named zone's calendar rules for each day, so
  spring and fall transition days are one exact 82,800-second or
  90,000-second window. Existing bounded finalization advances only covered
  work; a recorded travel gap is deferred. Raw sample formats still do not
  carry a capture-zone identifier, so exact recovery inside a historical
  travel gap requires future firmware, SDK, or import metadata.
- Apple persists the bounded timezone history as an atomic, file-protected,
  no-backup JSON document at
  `OpenWhoop/LocalState/analysis-timezone-history-v1.json`, rejects files above
  128 KiB, stages in the destination directory, applies protection and
  no-backup metadata before replacement, and fails closed without deleting a
  corrupt or future-schema document. Android preserves invalid/future bytes in
  its existing atomic no-backup storage. Recorded offsets remain historical
  evidence after a tzdata update instead of being invalidated by the host
  revision. Neither platform places this provenance in user defaults, managed
  backup, export, or diagnostics.
- Invalid civil-day bounds now produce a typed rejected result on both
  platforms. Callers do not persist or advance rejected work.
- Apple atomically converges an explicit retired hydration row list when its
  scalar projection is equal or lower. When the scalar is higher, old write
  order cannot distinguish an interrupted add from an interrupted
  decrease/delete, so the store changes neither representation and Hydration
  presents the saved daily total beside the drink-list total. `Keep daily
  total` creates one deterministic represented-day aggregate; `Use drink list`
  commits the exact explicit rows. Quick add, edit, and delete fail closed until
  that one-time choice commits. The store revalidates the scalar and managed
  ownership/deletion state inside the same transaction, supports the full
  bounded 512-row legacy payload, and rolls back both rows and projection on
  failure. An explicit empty list clears a stale projection. If no row list
  exists, scalar-only zero remains a clear; a positive scalar-only day becomes
  one aggregate labelled `Older daily total`, without claiming an actual drink
  timestamp. Its day-bound identity remains stable after an amount edit, so the
  aggregate provenance label is not silently lost. Canonical rows must agree
  with their projection and retire a stale UserDefaults payload left by process
  termination after SQLite commits, so deletion cannot resurrect old drinks.
  Empty legacy lists now enter the same managed ownership/deletion
  classification through a deterministic retirement identity. The store
  revalidates the expected scalar and absence of canonical rows in the write
  transaction; an unbound legacy clear can commit, while a signed-in profile
  defers without changing either the scalar or ownerless preference.
- Resolution of a higher retired scalar records SHA-256 linkage to the exact
  legacy and replacement rows in the local `hydrationLegacyResolution` table.
  A retry succeeds only when that evidence, the canonical rows, and the scalar
  projection still agree, so a later unrelated legacy list cannot be mistaken
  for interrupted cleanup. Migration `v63-hydration-legacy-resolution` is
  pinned in the shared schema oracle as `ios_only`: Android never stored
  hydration in the retired Apple `UserDefaults` list/scalar representation,
  while current hydration rows and managed-document wire behavior remain
  cross-platform.
- Hydration detail loading completes the one-time entry migration before
  reading the scalar and seven-day projections, preventing one published
  snapshot from mixing pre-migration totals with post-migration entries.
- The habitual-midsleep learner uses the selected historical scoring timezone,
  including its date-specific DST offsets, rather than falling back to the
  phone's current timezone for a historical catch-up window.
- iOS scene activation now re-arms daily-review, hydration, and wind-down
  schedules after notification authorization can change in Settings.
  Hydration restoration suppresses pending requests while authorization is
  unavailable without rewriting an already-enabled user's opt-in. Restore and
  reschedule tasks bind to the schedule generation and recheck the current
  preference across their asynchronous boundaries. The mounted Hydration and
  Automations toggles now read back the retained preference after a denied
  scheduling attempt instead of presenting a false OFF state.
- The hydration permission warning leaves its explanatory text and Open
  Settings button as separate accessibility elements so the action remains
  independently reachable with VoiceOver.
- Android hydration reconciliation now checks the current Terms receipt before
  a reboot or wall-clock receiver, scheduler reconciliation, chained
  scheduling, or an already-enqueued worker can touch WorkManager. A fresh
  Review Sample process therefore remains non-operational and leaves
  WorkManager uninitialized until the user accepts current Terms.
- Android feedback enqueue, retry, cancellation, and reconciliation are
  suspend boundaries. User-visible success is returned only after
  WorkManager's unique-work enqueue operation completes. A rejected operation
  clears its worker generation, persists `FAILED` or `CANCEL_FAILED`, clears
  the sensitive draft after successful staging, and presents that one record
  for retry instead of silently recovering or duplicating it.
- WorkManager acceptance and unfinished-work queries have a bounded 15-second
  wait without rewriting an enclosing coroutine timeout. Lifecycle
  cancellation propagates through send, retry, cancel, reconciliation, and
  worker-repair paths. If enqueue acceptance races with a worker, failure
  persistence either owns the attempted generation or returns the newer
  durable record; it cannot reopen Review after a send, revive a failed stale
  generation, or overwrite a valid successor. Repair failure becomes one
  visible retryable state with bounded `scheduler_repair_failed` evidence.
- Android diagnostic-report launch requests now use one conflated,
  single-consumer channel. One request emitted before Activity collection is
  retained and delivered exactly once; later bursts remain bounded to one
  pending request and are not replayed after consumption.
- Legacy Effort migration preserves existing strain and replaces only windows
  that can be attributed safely. It records completion only after the safe work
  succeeds.
- Managed-document remote apply now decides revision disposition before
  mutation. Lower revisions are processed as idempotent no-ops; equal revisions
  must match content and deletion state or fail closed; higher revisions apply
  normally. A legacy row with a nullable deletion state may replay once to
  enrich that state without weakening later monotonicity.
- Managed Safety now treats precise location as an explicit opt-in on every
  platform. Apple and Android refuse to create a location-sharing incident
  without current foreground authorization, recheck authorization before each
  retry, stop the sharing session after revocation, and reject missing,
  non-finite, negative, or over-10-kilometre accuracy rather than substituting a
  value. Both incident surfaces show accepted accuracy. The server defaults
  location sharing off, retains only the latest fix, rejects fixes older than
  five minutes at receipt or more than one minute in the future, and still
  deletes precise location on every terminal lifecycle path.
- The bounded command helper writes fixed-field status through a unique atomic
  replacement, permits at most one in-flight resource probe, polls completion
  before declaring timeout or pressure, normalizes signal exits, retries
  interruption cleanup under a temporary signal mask, and rejects non-finite,
  overflowing, or sub-byte disk limits before it launches a child. Its
  fork-free `posix_spawn` supervisor is created in a new process group behind a
  parent release gate, uses dynamically noncolliding descriptor mappings,
  reports the real target PID, follows a target into a new process group, and
  treats only a reaped supervisor plus vanished tracked groups as successful
  cleanup. Supervisor creation and target spawn share the hard deadline;
  deadline-unwind, setup-failure, late-status, exit-127, signal, and cleanup
  races are fail-closed. Verification targets receive `/dev/null` as stdin so
  a non-interactive command cannot stop its background process group by reading
  a controlling terminal. The runner is part of the protected release-control
  trust root.
- Independent review made the Android lighter-options sheet scrollable with
  navigation-bar padding and proper dismiss semantics, added the equivalent
  macOS lighter-workout presentation, made civil-day bound validation explicit
  and fail-fast on both platforms, and completed the Apple hydration warning
  translations for Italian, Russian, Simplified Chinese, and Traditional
  Chinese.
- Focused regression tests cover fail-closed pre-observation history,
  first/latest same-zone persistence, both DST directions, exact fall and spring
  transition-day windows, recorded travel-gap deferral, bounded-history
  truncation, explicit hydration rows above/below/at zero projection, both
  higher-scalar choices, unresolved mutation rejection, stale-scalar rejection,
  transaction rollback, maximum-row resolution, canonical projection
  consistency, scalar-only clear and deterministic migration, stable aggregate
  provenance, interrupted-migration retirement, ownerless empty-list profile
  isolation, detail-snapshot ordering, retained
  hydration intent, mounted-toggle consistency, a behavioral
  suspended-authorization opt-out race, all three iOS scene-active reminder
  restorations, historical habitual-midsleep timezone selection, awaited
  Android scheduling, durable retryable scheduler-failure states, safe Effort
  migration, and stale/equal/newer managed-document ordering.

## Data, privacy, and medical truth

- No metric formula, threshold, or health inference changes. Corrected
  civil-day membership can alter a transition-day total because the input day
  is now complete and correctly bounded.
- Hydration migration preserves already-confirmed local data and never invents
  a recommendation or clinical interpretation. A scalar-only aggregate is
  visibly distinguished from a timestamped drink.
- Reminder changes preserve explicit user intent but do not request permission
  without a user action.
- Feedback diagnostics remain bounded categorical events and do not include
  archive content, identity, tokens, URLs, or WorkManager identifiers.
- Managed-document conflict handling adds no payload logging or identifiers.

## Private reference disposition

- The supplied NOOP desktop, Bevel notification, and adaptive-day images are
  private interaction references only and are not committed.
- Current Apple and Android source already separates the Recovery-unavailable
  workout-coach state: live coaching is described as heart-rate based while
  today's Recovery is unavailable, rather than promising unavailable data.
- Useful principles retained are opt-in wind-down, journal, morning recap, and
  current-evidence planned-workout guidance with an explicit keep/lighter
  choice. NOOP does not copy third-party branding or assets, use categorical
  `poor`/`fair` health judgments, promise optimal performance, or silently
  rewrite a workout.

## Observability

- Timezone observations remain local-only in Apple and Android atomic no-backup
  storage outside every backup/export whitelist. They are not uploaded or
  included in diagnostics. Existing bounded `analysis.recent` evidence records
  only the categorical `timezone_provenance` deferral, never a zone identifier,
  offset, sample timestamp, or health value.
- Existing bounded hydration persistence and reminder suppression evidence
  covers the Apple boundaries. Hydration conflict detection and resolution add
  only fixed operation/outcome/failure categories such as `scalar_conflict`;
  neither total, row count, timestamp, identifier, nor choice payload is logged.
  Managed Safety location rejection adds only fixed `outcome`, `source`, and
  `failure_kind` categories for invalid or unauthorized fixes; coordinates,
  accuracy values, timestamps, incident identifiers, and platform errors are
  excluded.
  Android feedback records bounded
  `report.queue_failed`, `report.retry_failed`, and `report.cancel_failed`
  events with the fixed `scheduler` failure category, plus bounded
  reconciliation counts and fixed worker-repair outcomes.
- Diagnostic-report request delivery changes only the in-process trigger. The
  existing explicit review and opt-in boundaries still govern attachments and
  transfer; no report payload, screen capture, or identifier is added to logs.
- Managed-document ordering is diagnosed by typed apply outcomes and
  fail-closed errors already surfaced at the sync boundary; document payloads,
  keys, account identifiers, and revision values are not added to diagnostics.
- No raw health value, timestamp, report payload, account identifier,
  notification content, or arbitrary exception text is added.
- Physical OS delivery and OEM scheduling remain opaque until device testing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple focused, runtime, and regression evidence | All 75 hydration cases and the separate 181-case Safety, wind-down, notification-lifecycle, hydration-reminder, and accessibility matrix passed without failures or skips. The complete macOS app suite executed 2,083 tests with 2,082 passes, one intentional Xiaomi-fixture skip, and zero failures. After deterministic localization regenerated the Apple catalog, the bounded `NOOPiOS` Debug scheme ran on an iPhone 17 Pro simulator: 39 UI tests executed, 38 passed, one private-pilot case was intentionally skipped, and none failed. Its Today scroll case measured a 68,913.360 kB peak application-memory metric | The tested app launches, renders, navigates, scrolls, exercises report review, hydration/sleep controls, onboarding, trends, nutrition, settings, and strength-body-map interactions; the complete macOS wall covers the broader Apple source | Physical notifications, BLE, background lifetime, battery, haptics, hardware accessibility behavior, clinical accuracy, or unrelated host-process memory |
| Complete Swift package evidence | WhoopStore executed 536 tests with zero failures. NoopRemoteSync executed 131 tests with zero failures. StrandAnalytics executed 1,487 tests with 1,480 passes, seven documented fixture skips, and zero failures | The exact package wall covers storage migration, hydration resolution and retry evidence, managed-document behavior, shared schema drift protection, Safety policy, remote sync, and analytics contracts | Supplier firmware, skipped external fixtures, physical transport, or clinical accuracy |
| Complete Android variant matrices | Serialized Full and Demo runs each executed 4,819 tests with 4,812 passes, seven intentional skips, and zero failures or errors. Compile, APK assembly, lint, and instrumentation-source compilation passed for both variants. Both lint XML reports contained 77 hints and 1,171 warnings, with no Error or Fatal entry | The exact Android wall covers product logic, Safety defaults, atomic initial-location requests, authorization and location validation, generated resources, report-request lifecycle, navigation contracts, schema declaration, and both build graphs | OEM persistence, force-stop/background behavior, physical BLE, battery, haptics, hardware accessibility behavior, signed distribution, or future toolchain compatibility |
| Current Android API 35 shell | A clean disposable native-arm API 35 emulator ran 115 instrumentation tests: 113 passed, two intentional private-pilot cases were skipped, and none failed or errored. The exact Full APK cold-launched in 1,368 ms. Direct screenshot and UI-bounds inspection confirmed the Review Sample bottom labels end at y=2230 before the navigation frame begins at y=2274. `dumpsys meminfo` reported 142,440 kB PSS, 266,528 kB RSS, and zero swap | Real API 35 SQLite, WorkManager, migration, lifecycle, report-review, app-shell, APK installation, cold launch, final navigation layout, and bounded runtime memory pass on the exact worktree | Every OEM lifecycle, physical capture/share behavior, public feedback ingress, production operations, the private pilot, or representative-device frame pacing |
| Complete server matrix | An isolated pinned Python 3.12 environment with PostgreSQL 16.15 executed 600 cases: 599 passed, the explicitly opt-in real Twilio staging case was skipped, and none failed or errored. Ruff check/format passed over 81 files, runtime and development dependency audits found no known vulnerabilities, `pip check` passed, and six backup scripts passed syntax checks. Both synthetic databases and the disposable virtual environment were removed; a fresh shell confirmed the paths absent, port 55437 free, and no retained process | The exact server wall covers explicit location opt-in and freshness, latest-only replacement, duplicate replay, mobile storage classification, migrations, dependency health, and backup script syntax on the standard-PostgreSQL overlay | Hosted TimescaleDB/container execution, real Twilio delivery, public traffic, production secrets, or elapsed operation |
| Current bounded-command and trust evidence | The exact-current fork-free runner suite executed 57 tests with zero failures on Python 3.14 and the system Python 3.9. The added regressions prove the target receives EOF from `/dev/null`, a failed atomic status write invalidates stale terminal evidence and fails closed, and an owned process group is signaled before the supervisor is reaped so a recycled PID or PGID is not targeted after ownership release. A real failing Gradle invocation had previously left its supervisor and wrapper stopped after they inherited the interactive terminal; the corrected focused and complete Android runs exited normally with no retained runner, Gradle wrapper, or daemon process. Cases cover lifecycle, resistant descendants, target `setsid`, parent release gating, dynamic descriptor collisions, stale PID avoidance, completion/probe/deadline races, atomic status, interrupted and stalled supervisor/target spawn cleanup, deadline-context cleanup, second-signal resistance, exit-127 classification, cleanup failure, signal normalization, Linux parsing, finite arguments, and non-interactive stdin. The reviewed runner and terminology digests are pinned, and terminology, trusted-release, and required-CI checks pass | The resource guard fails closed across its tested creation, execution, pressure, interruption, deadline, cleanup, status-persistence, and terminal-input paths without unsafe `fork()` in a multithreaded Python process | A descendant that deliberately detaches and reparents beyond both tracked process groups, uninterruptible kernel behavior, or platform behavior outside the covered probes |
| Complete localization evidence | App-wide generation produced 813 shared strings and 45 Android-only resources across nine locales. Feedback generation covered 86 strings across nine locales. Two ordered generation passes produced byte-identical SHA manifests, the strict whole-tree audit passed, and all 52 top-level i18n tests passed | The exact localization wall covers deterministic generated Apple and Android catalogs, strict key/locale contracts, and feedback resources | Human linguistic review of every locale or physical large-text traversal |
| Complete static, infrastructure, privacy, and operations evidence | Interpreter-matched syntax passed for all 27 tracked shell scripts; ShellCheck passed for the 25 Bash/POSIX scripts it supports; the two Zsh visual-QA scripts passed `zsh -n`; Actionlint passed all workflows; all 111 tracked JSON files parsed; launch-gate configuration and isolation passed; 12 mocked, plan-only OpenTofu tests passed without creating cloud resources; the release-control high-confidence tracked-source secret scan found no match; private-data, health-claim, legal, distribution-provenance, calibration-parity, terminology, required-CI, trusted-release, strict localization, `git diff --check`, and all 73 operations-record gates passed | The exact-current policy wall covers scripts, workflows, JSON, default-off infrastructure plans, release trust roots, bounded private filenames, health-copy boundaries, and internally consistent round records | Exhaustive historical/runtime secret discovery, deployed-cloud drift, credentials, production traffic, or external approvals |
| Local resource retries | One combined two-flavor Gradle invocation exhausted the host Kotlin compiler heap; the same tasks passed when Full and Demo were serialized with one worker. A later Demo verification correctly stopped with `resource-disk` at the configured 0.5 GiB floor after its tests and APK completed; finalized XML and lint evidence was preserved, generated build trees were removed, and the complete Demo wall then passed with 2.2 GiB headroom. One mistakenly unpinned Gradle-cache invocation was interrupted through the runner, its descendants exited, and its 326 MiB startup-disk cache was removed before the corrected run. On the final rerun, one obsolete Android source-shape assertion failed after 4,815 tests and exposed the interactive-stdin stop described above; the assertion and runner were corrected, a nine-case focused test passed, and both complete variants then passed serially. The first final OpenTofu invocation stopped before tests because the cleaned local provider cache was absent; the pinned providers were restored only in a disposable data directory, all 12 mocked plans passed, and that cache was removed | The observed failures were bounded local resource-topology or exact regression-contract issues, the guard prevented disk exhaustion, interruption cleanup worked in real builds, no cloud resource was created, and every exact task passed after controlled correction and serial retry | Hosted runner capacity or future Kotlin/Gradle compatibility |
| Corrected shell-gate invocation | The first shell-list command let zsh retain the newline-delimited paths as one scalar; the corrected null-delimited attempt then exposed that two `.sh` visual-QA helpers intentionally use zsh syntax. The final interpreter-matched run passed bash syntax for 25 bash/POSIX scripts, zsh syntax for two zsh scripts, ShellCheck for the 25 applicable scripts, Actionlint, and `git diff --check` | Every tracked shell helper is parsed by its declared interpreter and applicable static checks pass; the two failed invocations changed no source | Execution against external tools, devices, credentials, or production services |
| Corrected server rerun invocations | The first full rerun incorrectly pointed canonical and PostgreSQL-overlay migrations at one database, producing 21 checksum conflicts. The second separated the databases but left the generic suite on the unavailable local TimescaleDB engine, producing 21 missing-extension failures. Two isolated databases plus the repository's existing `NOOP_TEST_DATABASE_ENGINE=postgresql` contract then produced 599 passes, one provider skip, and zero failures. A cleanup tail returned 127 only because its shell PATH still referenced the already-removed virtual environment; a fresh-shell audit proved the environment and databases absent, port 55437 free, and no retained server process | The failures were reproducible harness-topology or post-cleanup shell-environment issues; the corrected exact-current suite and cleanup are green | Hosted TimescaleDB behavior |
| Local command and Xcode invocation corrections | One unwrapped `xcodebuild -list` attempted automatic package resolution and exhausted local free space; the generated 779 MiB DerivedData tree was removed, and all later Apple work used the pinned wrapper and existing package graph. A first final iOS compile later stopped only when the external volume filled; after removing completed generated caches, the same exact graph succeeded. On September 17, the first exact-current iOS shell stopped before build with exit 74 because the `org.swift.swiftpm` user cache was a broken symlink to a removed round-owned RAM volume. Only that broken link and the failed 24 kB DerivedData/result residue were removed; a normal mode-700 cache directory was restored and the same bounded command passed. The stale terminology test failure is retained rather than rewritten as a product defect | Failed local setup attempts were bounded, understood, and cleaned without changing product behavior; the exact-current iOS runtime shell is green | Hosted runner capacity or unrelated user-process behavior |
| Local disk, memory, and cleanup evidence | Apple and Android work ran serially under bounded memory and disk guards. The API 35 shell used a disposable native-arm AVD on the external evidence volume with a sparse 2 GiB data image overriding the AVD manager's declared 6 GiB default; the emulator, data image, AVD, temporary homes, and device state were removed after the direct instrumentation log and APKs were retained. Earlier incomplete bundles were excluded. The final server rerun used disposable synthetic databases and a temporary virtual environment, both removed after evidence capture. Final Android logs and lint reports were retained before generated build output and Gradle caches were removed. The iOS scroll shell measured the app itself below 69 MiB; during final builds live system memory remained 44-53% free, so the older September 9 iTerm application-memory screenshot is historical and is not evidence of current app memory use | Finalized counts come from parseable artifacts, build concurrency was bounded, and completed temporary resources were removed without deleting user state | Hosted-runner or physical-device behavior, unrelated process memory, or final removal of the retained evidence volume and worktree after integration |
| Current repository policy wall | The exact-current repository-tool suite executed 281 tests with zero failures; the bounded-command subset also passed all 57 cases under Python 3.14 and macOS system Python 3.9. The generated terminology inventory records 17,702 classified occurrences across 1,563 path/category groups. Standalone release-control, required-CI, trusted-release, calibration-parity, terminology, legal, distribution-provenance, private-data, health-claim, strict localization, shell, workflow, JSON, launch-gate, mocked-infrastructure, operations-record, and diff gates pass | The current wall covers repository-owned release, localization, calibration, terminology, legal/provenance, private-data, health-claim, launch-isolation, process-lifecycle, and protected-control contracts | Hosted exact-SHA checks, protected integration, exhaustive historical/runtime secret discovery, physical devices, or external launch gates |
| September 17 continuation review and cleanup | Independent review found one P1 cross-layer mismatch: the server returns an unchanged duplicate incident for a matching idempotency key, but both clients required an active duplicate to echo the retry's location. Apple and Android now accept a missing retry location for any duplicate and retain the non-duplicate location requirement; both focused tests pass. A second independent tooling review found a stale terminology pin, that failed status persistence could leave stale evidence, and that reaping before signaling could target a recycled supervisor process group; all three findings are corrected and covered by the terminology/trust and dual-Python runner walls. No additional P0-P2 finding was reported. Complete Apple package/macOS/iPhone, Android Full/Demo/API 35, server, localization, and repository-policy walls pass with the counts above. API 35 visual bounds prove the final navigation labels are not clipped, and one pre-collector diagnostic-report request survives lifecycle startup exactly once. Both reviewers are closed. The AVD, PostgreSQL cluster, temporary virtual environment, provider cache, and completed build resources were removed after evidence capture. The repository and installed `noop-ops` skill copies include the exact-owner resource-pressure procedure and both pass the Python 3.11 skill validator | The product and tooling corrections, exact local product and policy walls, both simulator runtimes, independent review, and resource cleanup are recorded and recoverability-aware | Hosted exact-SHA checks, physical devices, or external launch gates |

## Physical device and deployment

- Simulator install/update action: the exact iOS Debug scheme launched on an
  iPhone 17 Pro simulator, and the exact Android Full debug APK was installed
  and cold-launched on a disposable native-arm API 35 emulator.
- Physical-device install/update action: not run.
- BLE/background/haptic/battery scenarios exercised: not run
- Public or production traffic enabled: no
- Owner direction on 2026-09-16: supplier hardware, firmware, SDK loading,
  pairing, physical calibration, and representative-device work are deferred
  until the weekend.

## Git and release state

- Changed paths: Apple and Android analysis planning and timezone provenance,
  Apple hydration migration/presentation, notification restoration and tests,
  Android feedback scheduling/diagnostics and tests, managed-document ordering,
  the reviewed App Check patch pin and regenerated legal notices, terminology
  and required CI inventories, and operations records.
- Commits: the final verified commit has not been created.
- Local product verification: complete Swift-package, macOS app, Android
  Full/Demo, API 35, local PostgreSQL server, localization, and final
  post-catalog iPhone 17 Pro simulator walls are green.
- Local repository-policy wall: 281 exact-current repository-tool tests pass.
  All exact-current static, localization, privacy, claims, legal, calibration,
  terminology, required-CI, trusted-release, launch-gate, mocked-infrastructure,
  operations-record, and diff gates pass.
- Hosted exact-SHA checks: the current remote head is `0ff1bf46`; its Apple
  Simulator and aggregate Apple required checks failed. Replacement-head checks
  remain pending.
- Protected integration and repository privacy restoration: pending.
- Version/build impact: none expected.
- Release or distribution impact: none.

## Decisions

- Historical analysis must use bounded capture-zone provenance. The first
  observed zone supports only complete civil windows contained by its observed
  segment; earlier history, the first partial day, a recorded travel gap, or
  discarded provenance must defer. A 23-hour or 25-hour transition day is one
  explicit civil window.
- A higher retired hydration scalar is ambiguous because old add and
  edit/delete paths committed scalar and rows in opposite orders. Neither
  representation is authoritative in that state: preserve both, block ordinary
  mutation, and require an explicit user choice inside one revalidated
  transaction. Equal or lower scalars converge to the explicit rows. Without
  rows, zero is a clear and a positive scalar is one deterministic aggregate,
  not a fabricated drink event.
- OS permission denial suppresses opted-in reminders but does not rewrite the
  user's preference. Schedule generation and a fresh preference check govern
  every asynchronous restore boundary.
- A feedback report is not presented as queued until WorkManager accepts the
  enqueue operation. Rejection must persist one visible retryable record and
  clear the generation that could otherwise be recovered in the background.
- Scheduling failure owns only the generation it attempted. A late or newer
  worker wins through the durable record, and parent/lifecycle cancellation is
  never converted into a scheduler failure.
- A diagnostic-report request must survive Activity collector startup without
  becoming an unbounded queue or replaying after it has been consumed.
- Hydration system receivers, schedulers, and workers are operational entry
  points and must reject stale or absent Terms before any WorkManager access.
- Managed remote state is monotonic by revision. A stale document is an
  idempotent processed no-op; equal-revision divergence is invalid state; and a
  legacy nullable deletion marker may replay only to enrich missing state.

## Open risks and honest limitations

- Physical notification permission round trips and Android WorkManager
  persistence remain representative-device gates.
- Raw historical samples do not contain capture-zone identifiers. NOOP cannot
  reconstruct the exact zone of a recorded travel gap without firmware, SDK,
  or import metadata and therefore defers that work.
- The API 35 shell proves real WorkManager execution and both modeled timeout
  orderings, but cannot force every OEM-specific WorkManager database or
  process-lifecycle failure.
- Hardware, supplier, calibration, legal, carrier, signing, store,
  participant, licensing, public-runtime, and elapsed-operation gates remain
  external.

## Next round

1. Complete the fresh final diff and secret review, then create the bounded
   local commit.
2. Generate and verify release evidence for that immutable commit, then push it
   once as one replacement head.
3. Wait for hosted exact-SHA checks, resolve only the proven review threads,
   integrate through protection, restore repository privacy, verify protected
   `main`, synchronize the canonical checkout, and clean only round-owned
   resources.

## Privacy check

- [x] No credentials, personal identifiers, health values, report contents,
      absolute owner paths, or private evidence are present.
