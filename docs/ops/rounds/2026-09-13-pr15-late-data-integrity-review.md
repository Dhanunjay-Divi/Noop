# Round: 2026-09-13 - PR 15 late data-integrity review

## Status

- State: `implementation and exact-current Apple, Android, and server product
  verification plus the final repository policy wall complete; staged review,
  exact-SHA hosted checks, protected integration, privacy restoration, and
  cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `6766b30c28162f82b649f50deeb385692ab4407b`
- End implementation commit: pending
- Record commit or PR: pull request `#15`

## Objective

Close the late data-integrity findings added after replacement head `6766b30c`
passed its complete hosted matrix, then harden user-initiated feedback delivery
against process death, clock changes, ambiguous remote reservations, and
idempotency-key reuse before re-running the complete local and repository walls.
Integrate only the exact verified revision through normal protected `main`.

Success requires:

- managed hydration document application to reject or roll back a merged day
  above the shared 10,000 ml current-day limit on Apple and Android;
- hydration band-first reminders to retain a durable phone occurrence unless a
  live cue and its bounded tap-window fallback were both accepted;
- a newly reserved feedback report to retain an authorization identity for its
  full 28-day lifecycle without breaking operations for reports already bound
  to another identity;
- capability-upgrade and cursor-recovery snapshots to preserve remote deletion
  tombstones on Apple and Android before advancing the local change cursor;
- Apple and Android feedback queues to serialize identity authorization, keep
  delivery and deletion retries durable and separately bounded, and recover an
  ambiguous reservation without creating a duplicate report;
- Android WorkManager retries to consume only the persisted outbox attempt
  budget rather than scheduler run attempts;
- server cleanup to retain a bounded idempotency tombstone for the complete
  client recovery horizon without retaining report content or extending the
  key lifetime after late cleanup;
- focused tests, complete affected-platform verification, exact-SHA hosted
  checks, review resolution, protected integration, repository privacy
  restoration, and round-owned cleanup.

## Scope

### In scope

- Apple and Android managed hydration document aggregation and rollback tests.
- Apple and Android hydration band-first phone-fallback policy, direct tests,
  and honest setting copy.
- Apple and Android feedback anonymous-identity lifetime policy and tests.
- Apple and Android managed snapshot transport/coordinator tombstone handling
  and tests.
- Apple and Android feedback authorization, recovery, retention, retry, and
  cancellation continuity.
- Server feedback reservation recovery, lifecycle cleanup, and idempotency
  tombstones.
- Android WorkManager instrumentation proof for durable report continuity.
- The supplied notification and adaptive-day images as interaction references,
  without copying branding, assets, fixed claims, or unsupported health
  judgments.
- Operations records, release controls, exact-SHA hosted evidence, merge,
  privacy restoration, canonical sync, and round-owned cleanup.

### Non-goals

- Enabling feedback ingestion, public traffic, real health-data transfer, or
  production deployment.
- Changing hydration goals, recommendation formulas, notification behavior
  outside the bounded hydration phone-fallback repair, unrelated UI
  presentation, or health claims.
- Claiming physical-device, BLE, background, notification, haptic, battery, or
  sensor behavior from simulator or unit-test evidence.

## Starting evidence

- Reproduction or observed symptom: pull-request review threads
  `PRRT_kwDOTiE28c6h6dCa`, `PRRT_kwDOTiE28c6h6dCb`, and
  `PRRT_kwDOTiE28c6h6dCd` identify an unchecked post-merge hydration total,
  anonymous identities whose remaining lifetime may be shorter than a report,
  and snapshot requests that exclude tombstones before cursor advancement.
- Relevant source/device/OS/firmware class: shared Apple storage and managed
  sync packages, iOS feedback authorization, Android managed sync and feedback
  authorization, and default-off GCP identity configuration.
- Existing tests, logs, exports, screenshots, or documents: exact head
  `6766b30c` passed all 35 executed hosted checks with three intentional skips;
  all sixteen preceding review threads were resolved before these three later
  findings appeared.
- Private UI audit evidence:
  `$HOME/Documents/NOOP-private-audit-2026-09-14/UI-AUDIT-REPORT.md` plus 61
  adjacent evidence files records zero P0 findings, four P1 findings, and
  sixteen P2 findings at source commit `2efd5e89`. All twenty actionable
  findings are closed in the current cross-platform source; the evidence stays
  outside Git.
- Unknowns that must remain unknown until measured: production Identity
  Platform cleanup timing, physical-phone background upload, real network
  interruption behavior, and participant-data merge frequency.

## Delivered

### Hydration phone-fallback follow-up

- Apple band-first mode now schedules a bounded horizon of 24 exact,
  non-repeating phone occurrences. A live cue replaces only its matching phone
  occurrence after Notification Center accepts the delayed tap-window request;
  a failed replacement leaves the original phone occurrence available.
- Apple confirmation cancels only the matching exact occurrence and matching
  tap-window request. A stale confirmation cannot remove a newer reminder.
- Android now serializes the worker and live-band paths per process. Worker
  first posts once and prevents a later buzz; cue first owns one tap window;
  buzz, tap-arm, or escalation-scheduling failure leaves the phone worker
  eligible.
- Android reads durable worker/cue state inside the serialized decision instead
  of passing potentially stale values into it.
- Routine phone fallbacks remain priority candidates under Notification Center
  capacity, but quiet-hour occurrences are omitted. Optional missed-response
  escalation is separately marked, capacity-bounded, and quiet-hour suppressed.
- Apple and Android settings now say that the phone fallback stays scheduled
  and that only a successful live cue starts the tap window. Alarms and Safety
  behavior is unchanged.

### Feedback authorization and continuity

- Apple and Android now serialize feedback work through one identity
  authorization gate. A report is bound before remote reservation, identity
  rotation fails closed, and legacy local-only records can migrate once without
  relabeling a remotely bound report.
- A single automatic delivery attempt covers reservation, object upload, and
  completion. Waiting for reservation continuity refunds the attempt, while
  remote cancellation has its own retry budget and remains durable until the
  server confirms deletion.
- Never-attempted local reports expire after 14 days. A server-bound report
  retains a bounded remote continuity window based on the server's 28-day
  retention, one-day local ambiguity allowance, one-hour lease, and
  five-minute clock-skew tolerance, capped at 29 days and five minutes.
- A materially future local clock records one bounded anomaly observation. A
  second material rollback does not extend the deadline, but it also cannot
  erase an unconfirmed remote reservation or deletion capability before the
  actual continuity deadline. Its future retry wake is clamped to the current
  clock so cancellation can continue immediately.
- Reservation recovery uses the report capability to read the existing server
  status. Gone reservations resolve as terminal; unknown reservations remain
  fail-closed and cannot silently create a second report.
- Reservation recovery now distinguishes an unknown or not-yet-committed key
  from a proven retired key. A `404` remains retryable because a concurrent
  reservation may still commit and does not consume the delivery or
  cancellation attempt budget; an active tombstone returns `410`, allowing
  Apple and Android to finish cancellation without replaying a payload.
- A bound Android cancellation that cannot read status now proceeds directly
  to the idempotent `DELETE` using its persisted report capability. It no longer
  enters the no-capability continuity scheduler, so a temporary status absence
  cannot consume the cancellation budget without a deletion attempt.
- When local continuity finally expires without an authoritative server
  response, both clients remove the local archive but preserve the scoped
  report capability and identity binding in an explicit unconfirmed-deletion
  failure. A later user retry can still seek authoritative deletion; the app
  never records local expiry as remote deletion success.
- Android WorkManager scheduling is awaited. Scheduler `runAttemptCount` no
  longer consumes the product's delivery budget; only the persisted outbox
  attempt advances it. Android now rejects forbidden identity replacement
  before invoking Firebase sign-in. A debug-only blocking worker and API 35
  instrumentation test exercise replacement-work persistence and ordering.

### Server idempotency retention

- Migration `042_feedback_idempotency_tombstones.sql` adds content-free
  tombstones keyed by client application, principal version/hash, and
  idempotency hash.
- Report deletion and optional tombstone insertion occur in one PostgreSQL
  transaction. A replay during the retained key lifetime returns `410 Gone`
  instead of reserving a new object.
- Recovery by idempotency key returns `410 Gone` only while a matching
  content-free tombstone is active. A genuinely unknown key remains `404`, so
  client cancellation cannot misclassify a reservation-commit race as proof of
  deletion.
- The key lifetime is capped at 45 days total from server reservation, covering
  the client's maximum 29-day, five-minute automatic continuity horizon without
  adding 45 more days after deletion. Cleanup after that horizon creates no
  tombstone.
- A lingering report row no longer reserves the key beyond that total
  lifetime. Its old hash is retired without deleting the row, allowing a new
  reservation while ensuring later cleanup cannot steal the replacement
  mapping or tombstone.
- Tombstones contain no archive hash, request body hash, object key, user text,
  screenshot, health value, token, or direct account identifier.
- Each tombstone-retention pass now reports the purged count, remaining expired
  count, and oldest expired age. Count and age are clamped to fixed
  observability ceilings with saturation flags, and the PostgreSQL count query
  itself reads at most the saturation ceiling plus one row. No app, principal,
  key, report, receipt, object, or timestamp identifier is emitted.
- Restore application smoke now requires migration `042`, the tombstone table,
  all five validated check constraints, the exact four-column primary key, and
  the valid/readied four-column expiry index. A matching migration ledger alone
  no longer proves the restored application contract.
- A database trigger preserves the same bounded content-free tombstone when an
  older application version deletes a report without using the current
  repository transaction. Current-version deletes remain idempotent.
- Restore validation binds index lookup to the public application schema, so an
  identically named index in an upgrade-shadow schema cannot satisfy the smoke
  test.

### Release-tool closeout

- The release artifact script now fails immediately if its source directory
  cannot be entered instead of continuing in an arbitrary directory, resolves
  the repository relative to the script, removes stale versioned outputs before
  each build, and returns nonzero unless all three artifacts were freshly made.
- The signed-bundle contract script no longer combines declaration and command
  substitution where a failed command status could be masked.
- All 27 tracked shell scripts pass their declared interpreter syntax check;
  all 25 POSIX/bash scripts pass ShellCheck at warning/error severity, and the
  two zsh scripts are syntax-checked by zsh.

### Product-copy and reference-image disposition

- The audited workout-coach row now uses a separate localized subtitle when
  current Recovery is unavailable. It says live coaching uses heart rate; it
  does not promise that missing Recovery shapes the session.
- Existing opt-in wind-down, journal, morning recap, and planned-workout
  guidance cover the useful behavior shown in the supplied references on both
  phones.
- NOOP keeps those interactions private, evidence-gated, optional, and
  user-controlled. It does not copy third-party branding or assets, label a
  night categorically `poor` or `fair`, promise `optimal performance`, or
  silently reduce a scheduled workout.
- Android stored-Stress explanation text is now generic and non-diagnostic.
  It does not imply a condition from a persisted categorical value.
- Mounted Apple and Android wearable copy now uses `band`, Android Health uses
  the shared missing-value token, and the Android Sleep Score heading uses the
  localized catalog rather than hard-coded English.
- The final independent UI reconciliation found mounted Android Stress,
  Recovery-breakdown accessibility, and late-added Health Monitor strings that
  still fell back to English in some supported locales. Those are release
  defects rather than acceptable translation gaps; their exact-current
  correction and complete Android rerun are part of this closeout.
- Android already stores a canonical date of birth, derives whole-year age at
  the current local date, migrates the legacy age field, and round-trips the
  exact civil birthday in backups. No additional age-storage migration is
  required by this review.
- A final source-to-reference pass found and closed three additional
  presentation and notification-policy defects: Android Coupled used a raw
  missing token and hard-coded Sleep label, hydration phone fallbacks could be
  evicted by notification capacity selection, and morning recap eligibility
  did not honor quiet hours. The fixes use the shared missing/localization
  contracts, preserve hydration fallback capacity, and suppress recaps with
  bounded categorical evidence until quiet hours end.
- Morning recap now persists one privacy-safe deferred one-shot until quiet
  hours end instead of losing the eligible day. Post-workout reporting is
  suppressed without advancing its frontier during quiet hours. Android uses
  the same policy through WorkManager without persisting metric values.
- The stale desktop image supplied with the audit is retained only as evidence
  of the old contradiction. Current source branches the workout-coach subtitle
  when Recovery is unavailable, and the exact-current window-only capture
  shows neutral connect-and-wear-band guidance instead of claiming that a
  missing Recovery score guides the session.

## Data, privacy, and medical truth

- Schema or migration impact: migration `042` adds only bounded feedback
  idempotency tombstones. The hydration repair adds bounded local
  reminder-state keys.
- Existing-data retention impact: fixes must preserve valid hydration entries,
  report lifecycle access, and remote deletion semantics without fabricating
  records or silently normalizing health data.
- Source/provenance or formula impact: no health formula change.
- Permissions/network disclosure impact: feedback remains explicit,
  user-initiated, redacted, bounded, and default-off for public ingestion.
- Health/medical claim impact and limitations: none; hydration remains a
  user-entered record and does not imply dehydration or treatment.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing typed
  managed-document transaction failures, bounded feedback queue stages, and
  snapshot checkpoint/cursor state.
- Why existing evidence is sufficient, or why new evidence is required:
  existing notification lifecycle ledgers already record bounded
  scheduled/post/suppressed/cancelled outcomes under the stable hydration
  category. The occurrence coordinator persists only local categorical state,
  so no new high-frequency event was added.
- Existing evidence reused: `AppDiagnosticsRecorder`, durable feedback outbox
  state, managed snapshot checkpoints, and typed sync/storage errors.
- New bounded evidence: feedback diagnostics expose fixed categories and
  statuses only. Tombstone cleanup additionally emits one aggregate event per
  purge with the batch count, remaining expired count capped at 1,000,000,
  oldest expired age capped at 366 days, and saturation flags. The Android
  WorkManager test uses a debug-only marker and no participant data.
- Redaction, retention, and high-frequency controls: no health values, user
  text, credentials, tokens, URLs, object payloads, or persistent identifiers
  may enter diagnostics.
- Cross-platform/backend correlation: existing report reservation correlation
  and managed change sequence.
- Remaining blind spots: provider-side anonymous cleanup timing and
  physical-device network/background behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-SHA hosted matrix for `6766b30c` | 35 successful, three intentional skips, zero failures | The pre-follow-up source passed every protected hosted job | The three later review findings |
| `ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:testFullDebugUnitTest --tests 'com.noop.notif.HydrationReminderPolicyTest'` | Passed, `BUILD SUCCESSFUL` | Full variant worker-first, cue-first, trust-gate, dedupe, and buzz-failure policy | Physical WorkManager/OEM timing or band vibration |
| `ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:testDemoDebugUnitTest --tests 'com.noop.notif.HydrationReminderPolicyTest'` | Passed, `BUILD SUCCESSFUL` | Demo variant compiles and passes the same focused policy/integration tests | Physical device behavior |
| Exact-current focused Apple feedback and terminology XCTest | Passed with zero failures | Feedback continuity, active leases, cancellation, clock rollback, retention, and mounted band vocabulary execute on Apple | Complete Apple integration or physical background upload, notification presentation, and band haptics |
| Complete macOS app suite | 1,988 tests total: 1,987 passed, zero failures, and one expected external Xiaomi-fixture skip | The complete Apple app, storage, notification, accessibility, performance-contract, feedback, and retired-reservation graph pass together on the exact product source | Physical iPhone behavior |
| Generic iOS Simulator Release graph | Dual-architecture `NOOPiOS` Release build succeeded with signing disabled, including the app, widgets, Watch companion, App Intents metadata, and launch gate | The complete production-configuration Apple graph compiles and validates its embedded products | Signed distribution, physical-device execution, background behavior, BLE, notifications, or haptics |
| Complete exact-current iPhone UI suite | 39 tests total: 38 passed, zero failures, and one intentional private-pilot skip | Current simulator navigation, reporting, accessibility, loading, planner, and scrolling paths remain reachable after the feedback correction | VoiceOver traversal, physical frame pacing, thermal pressure, or background transfer |
| Focused Android feedback tests | Full and Demo `FeedbackProtocolTest`, `FeedbackUploadPolicyTest`, and `FeedbackOutboxTest` passed; the final independent re-review reported no findings | Unknown reservation recovery stays retryable, a bound status miss issues one idempotent delete, active tombstones finish cancellation, and payload reservation/deletion is not replayed | OEM WorkManager timing or physical process death |
| Complete exact-current Android Full/Demo wall | Passed in 137 tasks: each variant executed 4,742 unit cases with 4,735 passes, seven intentional skips, and zero failures/errors; APKs, lint variants, and instrumentation-source compilation also passed | Both product variants compile and the complete local source contract passes together | OEM rendering, physical background behavior, or BLE |
| API 35 managed-device production shell | Authoritative XML: 107 tests total, 105 passed, zero failures/errors, and two intentional private-pilot skips; the feedback WorkManager graph-ordering test passed | The production scheduler persists an `APPEND_OR_REPLACE` successor behind an active predecessor on the pinned managed emulator | Actual process death, outbox execution after restart, OEM scheduling, or physical-device behavior |
| Focused feedback reviewer wall | The final backup/migration/feedback wall passed 42 tests; the complete PostgreSQL feedback file passed 27 tests after canonical formatting | Pre-tombstone expiry remains retryable `404`, active tombstones remain terminal `410`, mixed-version deletion retains a bounded tombstone, reservation is serialized with retention finalization, and reservation/recovery remain safe at the tombstone-purge boundary | The complete server suite, Cloud SQL IAM, live object storage, or production traffic |
| Fresh restore application smoke | Passed after all 42 migrations against a freshly migrated disposable PostgreSQL database | The SQL proves `feedback_reports` and its complete runtime column/type/nullability contract, then validates migration `042`, tombstone `timestamptz` columns, five checks, exact primary key, and ready expiry index | Encrypted backup media, `pg_restore`, TimescaleDB post-restore hooks, or production data |
| Current PostgreSQL feedback overlay | All 22 tests passed against a fresh extension-free database | Migration `042`, atomic report deletion/tombstone insertion, 45-day bounded expiry, post-purge backlog visibility, elapsed-horizon release, lingering-row key retirement, `404`/`410` semantics, and both requested transaction races execute in PostgreSQL | Cloud SQL IAM, live object storage, or production traffic |
| Complete server suite plus Ruff | 597 tests passed, one intentional provider/environment skip, zero failures/errors, and one dependency deprecation warning; Ruff check and canonical format passed over 81 files | The feedback, migration, restore, lifecycle, API, and supporting server contracts pass together on the exact current source | Cloud SQL IAM, live object storage, public traffic, or production containers |
| OpenTofu validation and tests | 12 passed, zero failed | Feedback lifecycle bounds, default-off ingestion, abuse-gate, public-readiness, ownership, and migration-image guards remain intact | Cloud plan/apply or live IAM |
| Exact-current repository policy wall | Feedback localization for 86 strings across nine locales, whole-tree i18n, 230 Tools tests, 49 top-level i18n tests, the 1,252-file health-claims scan, calibration parity, private-data, 17,631 classified terminology occurrences with zero forbidden mappings, required-CI, release-control, legal/distribution, 109 tracked JSON files, syntax for 27 shell scripts, ShellCheck for 25 POSIX/bash scripts, Actionlint, Ruff over 81 server files, 64 operations records, 12 OpenTofu tests, and diff gates passed | The final source and operations records remain localized, claim-bounded, privacy-checked, release-controlled, and mechanically valid | Hosted exact-SHA status, legal/clinical approval, or production runtime behavior |
| Repository tooling suites | `Tools/tests`: 230 passed plus 34 subtests; top-level i18n suite: 49 passed; OpenTofu: 12 passed | Repository policy implementations and default-off infrastructure guards execute on the exact current tree | Cloud plan/apply, public ingress, or production runtime behavior |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS, iOS Simulator, Android build
  toolchain, and synthetic backend tests
- Data-preservation result: no participant, owner, production, or real health
  data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical iPhone and Android upload/background behavior,
  BLE, band history, haptics, battery, VoiceOver, TalkBack, and sensor accuracy

## Git and release state

- Changed paths: feedback outbox/coordinator/worker source and tests on Apple
  and Android; Android debug/instrumentation WorkManager proof; server feedback
  API/lifecycle/repository, migration, backup smoke and tests; canonical
  feedback/decision documentation; Apple BLE vocabulary; Android Health, Sleep,
  Stress, and Recovery-breakdown presentation; supported Android locale
  catalogs; Apple and Android UI contracts; generated terminology ratchet;
  release-control source; two release-script reliability fixes; formatter-only
  server lines; and operations records.
- Commits: implementation commit pending exact-current closeout
- Branch and remote state: isolated branch is ahead of its remote; no
  replacement push has been performed for this final slice
- Repository visibility verified: public at round start; must return to private
  immediately after protected integration
- Version/build impact: no product version or build-number change
- Release or distribution impact: no artifact released or distributed

## Decisions

- Durable decision changed: app-feedback idempotency retirement is explicitly
  capped at 45 days total from original reservation. Deletion may retain only
  scoped hashes and reservation/expiry timestamps for the remaining window;
  unknown recovery stays retryable `404`, while only an active deletion
  tombstone returns `410`.
- Decision-log entry: `D-057`

## Open risks and honest limitations

- Exact-current Android source and managed-device walls, complete macOS suite,
  dual-architecture iOS Release graph, iPhone UI suite, PostgreSQL-backed server
  suite, and repository policy wall pass on the unchanged final tree. The
  complete staged review remains required before the replacement commit.
- The first 2026-09-14 server command omitted
  `NOOP_TEST_DATABASE_ENGINE=postgresql`, so 21 database tests attempted the
  unavailable TimescaleDB extension. Fresh general and overlay databases with
  the explicit PostgreSQL engine produced the earlier 585-test result. The
  final unchanged-source rerun produced the authoritative 597-pass result
  recorded above.
- The first combined Android focused compile exhausted the 4 GB Kotlin daemon
  while compiling both variants concurrently. Serial Full and Demo reruns with
  an 8 GB bounded daemon heap passed, followed by the complete 137-task wall and
  API 35 device shell.
- The first final managed-device setup started zero tests because the generated
  AVD requested a 6 GiB data partition with only 2.1 GiB free. Removing the
  disposable 14 GiB Gradle build cache and the 12 KiB broken managed-AVD shell,
  then restarting ADB, left 16 GiB free; the exact retry booted and passed.
- The first Apple closeout compile exposed that the new recovery policy lived
  in the iOS-only target while its regression test was shared. Moving the pure
  status policy into the shared feedback model closed that target boundary; the
  complete Apple wall then passed.
- The first final repository-tool rerun correctly failed after the reviewed
  i18n baseline changed and the terminology snapshot had been generated before
  that change. The two removed baseline entries were inspected, the terminology
  snapshot was regenerated afterward, and both reviewed-source SHA-256 values
  were repinned in the fail-closed required-CI contract. The authoritative
  complete tool and policy reruns then passed.
- The first final top-level i18n unit command omitted `Tools` from
  `PYTHONPATH`, and the first shell-matrix loop used zsh scalar splitting for a
  newline-separated file list. Corrected invocations produced 49 passing i18n
  tests, syntax checks for all 27 tracked scripts, ShellCheck for all 25
  POSIX/bash scripts, and two zsh syntax passes.
- The first post-format PostgreSQL command selected system Python without
  `asyncpg`; the same 27-case file passed in the pinned project Python 3.11
  environment.
- The first final iOS Release attempt and the isolated PostgreSQL cluster both
  encountered the host's earlier disk exhaustion. After removing only
  round-owned DerivedData/cache output, the dual-architecture build succeeded,
  PostgreSQL recovered, and the fresh 597-pass server wall completed.
- A replacement push is necessary because these findings were created only
  after the previous exact-SHA matrix had completed.
- All physical-device and external launch gates remain unchanged.
- iOS can keep accepted local notifications available while the app is
  suspended or terminated, but cannot guarantee that app code will run to issue
  a BLE haptic in those states. The 24 exact occurrences are refreshed on app
  launch/settings changes and cover at least 24 hours at the minimum interval.
- Android WorkManager timing remains subject to OS/OEM scheduling, and neither
  platform's physical band vibration was verified in this round.
- Docker is not installed on this host, so production and encrypted-backup
  container builds and the disposable encrypted restore drill remain hosted-CI
  evidence rather than local evidence.
- The first commands in this corrective pass used system Python 3.14, which had
  neither `pytest` nor `ruff`; Python compilation passed, and all authoritative
  tests/lint then ran in the existing project Python 3.11 environment.
- The restore application smoke ran against a fresh migrated PostgreSQL
  database, not an encrypted dump restored through the production container.
- Independent UI re-review reported no findings. Feedback re-review found the
  bound-cancellation status-miss defect above; its direct regression test,
  focused Full/Demo suites, complete Android wall, and a second read-only review
  all passed after the repair.
- The first managed-device closeout attempt could not create the requested
  6 GiB data partition with only 2.1 GiB free. Removing only disposable Gradle
  cache/build output and the broken managed AVD, then restarting ADB, allowed
  the exact API 35 task to boot and produce the authoritative 107-case XML.

## Next round

1. Review the complete staged change and create one bounded commit.
2. Push one replacement head, wait for exact-SHA hosted checks, resolve only
   proven threads, and integrate through branch protection.
3. Immediately restore repository privacy, synchronize canonical `main`, and
   remove only round-owned build/test resources while preserving the private UI
   audit evidence.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
