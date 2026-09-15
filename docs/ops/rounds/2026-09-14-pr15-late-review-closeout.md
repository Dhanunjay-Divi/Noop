# Round: 2026-09-14 - PR 15 late review closeout

## Status

- State: `all supplier-independent local verification complete; hosted checks, protected integration, privacy restoration, and final cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `f7350d6eb9cee1dd9a903e5ab73d16f049607bc6`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`
- Local verification finalized: `2026-09-15`

## Objective

Close the final source-verifiable review findings before protected integration:

- record bounded local-only timezone provenance on Apple and Android, use the
  named zone's rules for historical civil days, represent 23-hour and 25-hour
  days exactly, and defer work whose capture zone is not supportable;
- migrate explicit legacy Apple hydration rows exactly despite a disagreeing
  retired scalar projection, while preserving an explicit empty list or
  scalar-only zero as a clear and converging scalar-only migration on one
  stable aggregate entry;
- re-arm opted-in daily-review and hydration reminders when notification
  permission returns while the app is already running;
- keep hydration reboot and wall-clock reconciliation behind the current Terms
  receipt before any WorkManager access, including the scheduler and worker
  boundaries;
- retain the hydration reminder opt-in while OS notification permission is
  unavailable without allowing an in-flight restore to undo a later opt-out;
  keep already-mounted Hydration and Automations toggles aligned with that
  retained intent; and
- do not report an Android feedback archive as queued until WorkManager has
  durably accepted the enqueue operation, and leave a rejected enqueue in one
  visible retryable state; and
- make managed-document restore monotonic so stale revisions cannot overwrite
  newer local rows, equal-revision divergence fails closed, and a legacy
  nullable deletion marker can be enriched exactly once.

## Scope

### In scope

- Apple and Android analysis-zone history, civil-day selection, and focused
  planner tests.
- Apple hydration migration and focused persistence tests.
- Apple hydration aggregate presentation and localization.
- Apple notification lifecycle restoration and focused policy tests.
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

## Starting evidence

- Historical scoring had epoch timestamps but no durable capture-zone
  provenance. Reusing the current zone can assign old data to the wrong local
  day after travel, while a fixed 86,400-second window can omit or duplicate
  part of a daylight-saving transition day.
- Apple retained both explicit legacy drink rows and a retired scalar
  projection. Old add and edit paths wrote those surfaces in opposite orders,
  so disagreement has no trustworthy direction. Scalar-only history also has
  no evidence for individual drink times.
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
- Apple treats an explicit retired hydration row list as the user-authored
  source and atomically converges its scalar projection to that exact list,
  whether the stale scalar is higher, lower, or zero. An explicit empty list
  clears a stale projection. If no row list exists, a scalar-only zero remains
  a clear; a positive scalar-only day becomes one deterministic represented-day
  aggregate labelled `Older daily total`, without claiming an actual drink
  timestamp. Its day-bound identity remains stable after an amount edit, so the
  aggregate provenance label is not silently lost. Reentrant and concurrent
  readers converge on the same entry. Canonical rows also retire a stale
  UserDefaults payload left by process termination after the SQLite commit, so
  deleting the canonical row cannot resurrect old drinks.
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
- Independent review made the Android lighter-options sheet scrollable with
  navigation-bar padding and proper dismiss semantics, added the equivalent
  macOS lighter-workout presentation, made civil-day bound validation explicit
  and fail-fast on both platforms, and completed the Apple hydration warning
  translations for Italian, Russian, Simplified Chinese, and Traditional
  Chinese.
- Focused regression tests cover fail-closed pre-observation history,
  first/latest same-zone persistence, both DST directions, exact fall and spring
  transition-day windows, recorded travel-gap deferral, bounded-history
  truncation, explicit hydration rows above/below/at zero projection,
  scalar-only clear and deterministic migration, stable aggregate provenance,
  interrupted-migration retirement, detail-snapshot ordering, retained
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
  covers the Apple boundaries. Android feedback records bounded
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
| Current Apple focused and app evidence | The exact-current post-managed-sync slice executed 62 focused app tests with zero failures or skips. The arm64 iOS Simulator Release graph was refreshed successfully after canonical localization generation. That graph pins reviewed App Check `11.3.2`, whose unchanged Apache-2.0 license and token-TTL suspension fix were reviewed before regenerating the legal inventory. The immediately preceding complete macOS app suite executed 2,057 tests with 2,056 passes, one intentional external-fixture skip, and zero failures; the unchanged iPhone UI shell executed 39 tests with 38 passes, one intentional private-pilot skip, and zero failures | The latest timezone, hydration, reminder, presentation, localization, managed-sync, and authentication-integrity integration compiles and passes its owning app tests; the broad unchanged app and UI surfaces retain finalized evidence | A fresh full macOS/UI rerun after the package-only managed-sync correction, physical notification delivery, background lifetime, BLE, battery, accessibility hardware behavior, or participant-data migration |
| Current Swift package and harness evidence | Exact-current WhoopStore passed 512/512 tests. Exact-current StrandAnalytics executed 1,486 tests with seven documented fixture skips and zero failures. The preceding complete nine-package wall executed 2,978 tests with ten documented skips; unchanged packages remain covered, and Backfill plus StudyHarness executed 14 tests with zero failures | The changed storage, sync, analytics, protocol, design, import, and harness contracts integrate without relying on a narrow managed-sync test alone | Supplier firmware, skipped external fixtures, clinical accuracy, or physical transport |
| Current Android variant matrices | Full and Demo each executed 4,811 tests with 4,804 passes, seven intentional skips, and zero failures; lint, APK assembly, and instrumentation-source compilation passed for both variants | Exact-current Android product logic, timezone provenance, Effort migration, hydration, feedback, presentation, and build graphs integrate in both variants | OEM persistence, force-stop/background behavior, physical BLE, battery, haptics, accessibility hardware behavior, or signed distribution |
| Current Android API 35 shells | The exact-current fresh-process Review Sample executed one test with zero failures while requiring WorkManager to remain uninitialized before Activity launch. The subsequent connected production shell executed 112 tests with 110 passes, two intentional private-pilot skips, and zero failures. Finalized results are preserved privately | The disclosed pre-Terms path remains non-operational, while real API 35 WorkManager, SQLite, lifecycle, migration, notification, diagnostic-report, and app-shell integration passes after the gate | Every OEM process lifecycle, physical capture/share behavior, public feedback ingress, or production operation |
| Current server matrix | The isolated pinned Python 3.11 environment passed Ruff over 81 files and collected 598 pytest cases: 463 passed, 135 were documented dependency/configuration skips, and none failed or errored | Exact-current pure and configured server behavior available in the local environment remains green | PostgreSQL/external-provider paths skipped without their required services, public traffic, production secrets, or elapsed operation |
| Current localization and diff checks | App-wide generation produced 803 strings and 45 Android-only resources across nine locales and was byte-for-byte idempotent. Feedback catalog generation, strict differential i18n, catalog JSON parsing, and `git diff --check` passed | The hydration aggregate and warning copy are present across supported locales and the current patch is structurally clean | Physical runtime rendering or native accessibility traversal |
| Local resource retry | One combined two-flavor Gradle invocation exhausted the host Kotlin compiler heap; the same tasks passed when Full and Demo were serialized with one worker | The observed failure was concurrent local compiler pressure rather than a product or test defect | Hosted runner capacity or future Kotlin/Gradle compatibility |
| Local disk-pressure retry and cleanup | Gradle's generated Pixel profile required more storage than the host had free. After preserving finalized evidence and deleting only completed NOOP build outputs, a temporary RAM-backed API 35 AVD ran the fresh Review Sample and current production shell. Their results were archived, and the emulator plus RAM disk were removed. Android build outputs were regenerated for the final Full/Demo wall and removed after evidence capture. The final localization-sensitive iOS Release refresh ran on a separate temporary RAM volume, whose build products and package cache were removed by ejecting that volume after success. Earlier incomplete bundles were not counted | Recorded Apple and Android runtime counts come from finalized parseable artifacts, and transient build and virtual-device state was removed after evidence capture | Hosted-runner behavior, physical-device behavior, or final removal of the active worktree before integration |
| Repository policy wall | The final exact-source wall passed app-wide and feedback localization, differential i18n, 230 Tools unit tests, the 1,253-file health-claims scan, calibration parity across 12 metrics, three revisions, 13 thresholds, and 16 guards, terminology inventory with 17,676 classified occurrences and zero forbidden mappings, five conditional plus five universal required-CI contexts, release controls, trusted self-verification, legal inventory over 230 runtime components and three container inputs, distribution provenance, private-data guard, 73 operations records, 27 shell syntax checks, ShellCheck over 25 scripts, two zsh checks, actionlint, 111 tracked JSON files, `git diff --check`, bounded added-line secret scanning, and 12 OpenTofu tests | The final current operations record and covered source satisfy the complete local repository-policy contract | Hosted exact-SHA execution, clinical/legal approval, physical-device behavior, or production operation |

## Physical device and deployment

- Install/update action: not run
- BLE/background/haptic/battery scenarios exercised: not run
- Public or production traffic enabled: no

## Git and release state

- Changed paths: Apple and Android analysis planning and timezone provenance,
  Apple hydration migration/presentation, notification restoration and tests,
  Android feedback scheduling/diagnostics and tests, managed-document ordering,
  the reviewed App Check patch pin and regenerated legal notices, terminology
  and required CI inventories, and operations records.
- Commits: this record is included in the bounded final commit.
- Local repository-policy wall: final exact-source wall passed.
- Hosted exact-SHA checks: pending for the replacement commit.
- Protected integration and repository privacy restoration: pending.
- Version/build impact: none expected.
- Release or distribution impact: none.

## Decisions

- Historical analysis must use bounded capture-zone provenance. The first
  observed zone supports only complete civil windows contained by its observed
  segment; earlier history, the first partial day, a recorded travel gap, or
  discarded provenance must defer. A 23-hour or 25-hour transition day is one
  explicit civil window.
- Explicit legacy hydration rows are authoritative over their retired scalar
  projection because old write order makes disagreement direction unknowable.
  Without rows, zero is a clear and a positive scalar is one deterministic
  aggregate, not a fabricated drink event.
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

1. Push the bounded final commit as one exact replacement head.
2. Wait for hosted exact-SHA checks, resolve only the proven review threads,
   integrate through protection, restore repository privacy, verify protected
   `main`, synchronize the canonical checkout, and clean only round-owned
   resources.

## Privacy check

- [x] No credentials, personal identifiers, health values, report contents,
      absolute owner paths, or private evidence are present.
