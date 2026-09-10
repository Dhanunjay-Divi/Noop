# Round: 2026-09-10 - Calendar-aware daily guidance

## Status

- State: `complete local verification; exact-head hosted review, protected merge, and physical-device evidence pending`
- Owner: project team
- Branch: `codex/calendar-aware-daily-guidance-20260910`
- Start commit: `67ffd848094bbc3e7cbab682feed592c68a10f88`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#14`

## Objective

Connect NOOP's measured sleep and readiness to an optional same-day planned
workout so Today can explain when keeping a future session lighter is supported.
The result must be cross-platform, local-only, explicitly permissioned, fail
closed on thin or stale evidence, available in the existing daily plan, and
eligible for one bounded pre-workout prompt without exposing calendar content.

## Scope

### In scope

- Extend the shared Swift/Kotlin planner with a deterministic sleep-plus-planned-
  workout adjustment.
- Add opt-in iOS and Android calendar readers that retain only generic workout
  timing, never event content or identifiers.
- Surface the adjustment in both Today experiences and adaptive coaching
  settings.
- Add one privacy-safe, cooldown-aware prompt and bounded diagnostics.
- Update localization, privacy documentation, tests, builds, visual evidence,
  and protected source-control state.

### Non-goals

- Medical, injury, or training clearance.
- Inferring work, parties, alcohol, illness, or the cause of a changed routine.
- Uploading calendar or health data.
- Claiming background delivery guarantees or physical-device permission,
  notification, battery, BLE, or haptic validation from simulator evidence.

## Starting evidence

- Reproduction or observed symptom: the supplied comparison shows measured sleep
  combined with a future calendar workout and an advisory lighter-day prompt;
  NOOP already has morning recap, journal, wind-down, readiness, and adaptive
  sleep guidance but no external-calendar bridge.
- Relevant source/device/OS/firmware class: shared analytics, iOS 17+ EventKit,
  Android Calendar Provider, Today, Automations, and local notifications.
- Existing tests, logs, exports, screenshots, or documents:
  `DailyActionPlanner`, `AdaptiveDayGuidance`, contextual prompt cooldowns,
  Daily Review, Morning Recap, Wind Down, and the supplied comparison image.
- Unknowns that must remain unknown until measured: real user calendar
  authorization behavior, OEM calendar-provider behavior, suspended/background
  delivery timing, and whether a physical device displays the final UI without
  truncation at every accessibility size.

## Delivered

- Swift and Kotlin now share the same deterministic planned-workout adjustment:
  a future same-day session is eligible only within 24 hours, for 10 minutes to
  six hours, and only when supported by a 45-minute sleep deficit or a current
  non-calibrating recovery shift.
- Sleep comparison uses up to 21 prior nights, requires five nights before
  calling the median a personal usual, and otherwise falls back to the user's
  bounded configured sleep target. Today shows measured sleep, planned start
  time, exact shortfall, and concise lighter-session guidance.
- iOS EventKit and Android Calendar Provider readers are separate default-off
  opt-ins nested under Adaptive Day Guidance. They reject past, all-day,
  cancelled, invalid-duration, and ambiguous events and publish only a generic
  in-memory time window.
- Both Today experiences refresh on lifecycle/calendar changes and place the
  context inside the existing Today's Plan surface. Turning the feature off or
  losing permission clears the snapshot and invalidates an in-flight provider
  read before it can publish. A changed/deleted event recomputes the visible
  plan, and a one-shot local clock invalidation removes the adjustment when its
  planned start passes without introducing a per-second screen timer.
- One private local prompt may open Workouts within two hours of the planned
  session. Travel guidance outranks it; it outranks weaker routine and sleep
  prompts; its action-center evidence names sleep and readiness only when each
  signal actually contributed. All existing quiet-hour, duplicate, global, and
  topic cooldowns remain active.
- Android calendar-provider cancellation is preserved as coroutine cancellation
  rather than converted into a generic failure. The bounded operation closes as
  `cancelled` before rethrowing, so a disposed screen or worker cannot continue
  through the publication path or leave misleading failure evidence. The
  recoverable fallback catches `Exception`, not `Throwable`, so fatal runtime
  errors are never mislabeled as an ordinary provider failure.
- Nine-localization source catalogs and generated Apple/Android resources now
  contain the setting, permission, Today, deficit, and notification copy.
- Debug-only Apple and Android fixtures reproduce 6h12 sleep against a 7h30
  personal usual and a 17:30 planned workout without reading a real calendar.
  The iOS visual matrix writes and verifies a fixed-category state marker before
  accepting each screenshot, propagates every warm-up/capture assertion failure,
  and safely handles an empty output directory. Android exposes the same fixture
  through the private `today-planned-workout` demo route.
- Exact-head review found four integration defects and all are corrected in
  `ceeab3f0`: Android rechecks Calendar permission before returning a cached
  snapshot and clears stale state when access changes; Apple calendar-provider
  changes force a refresh and schedule a new adaptive-guidance evaluation;
  accepted contextual actions persist their trusted Workouts destination across
  relaunch on both platforms instead of falling back to Sleep; and Android does
  not create or mutate the shared adaptive-day `PendingIntent` until the global
  prompt cooldown has accepted delivery.
- The first hosted Apple run exposed one independent release-contract mismatch:
  five new translated keys brought the app-wide source from 631 to 636 entries
  while the fail-closed count still expected 631. The ratchet now expects exactly
  636 and continues to require the same nine locales and exact Apple/Android key
  parity.
- Replacement-head review found three further lifecycle/provider edge cases,
  corrected in `070a4d3a`: Android provider edits now force refresh before
  adaptive-guidance reevaluation; canceled Apple evaluations stop immediately
  after EventKit returns; and both providers reject invitations declined by the
  current user before title classification or delivery.
- Final exact-head review found three delivery/UI-lifetime gaps. The correction
  schedules an Apple local notification and an Android WorkManager reevaluation
  at the two-hour boundary when the app is not foregrounded, expires the
  accepted in-app action at the actual workout start, and immediately
  reevaluates guidance after every Android calendar enable, grant, revoke, or
  resume transition. Opt-out, permission loss, a removed plan, and foreground
  live delivery cancel the durable fallback.
- Apple records the scheduled request, presentation, suppression, and
  cancellation under the fixed `adaptive_day` diagnostic identity. Android
  records only a fixed enqueue outcome and a bounded worker operation outcome
  (`completed`, `disabled`, `invalid_input`, `cancelled`, or `retry`); neither
  path records calendar content, exact times, device identity, or health values.
  Recoverable Android worker failures catch `Exception`, not `Throwable`, so
  fatal runtime failures are not mislabeled as retryable work.
- Final local fresh-eyes review corrected two process-death defects before
  push: the Apple scheduled request now carries only the already-reviewed fixed
  evidence labels so a recovery-only adjustment cannot falsely claim sleep
  support, and the Android worker resolves the persisted active-device registry
  at execution time rather than racing the process startup fallback.
- The first protected review of that exact head then surfaced four additional
  consent/lifecycle races. Apple now checks EventKit authorization before a
  five-minute cache can return, rechecks calendar consent before immediate or
  durable planned-workout delivery, and reconciles an already queued boundary
  request whenever another contextual prompt is accepted so travel priority and
  the shared cooldown remain authoritative. Android now owns Calendar Provider
  observation in the app-wide ViewModel rather than the Today destination,
  force-refreshes and reevaluates on every activity resume or provider edit,
  cancels the prior calendar evaluation before starting its replacement, and
  rechecks both the opt-in and runtime permission immediately around the atomic
  notification post before persisting an action.
- Review of that protected head found two final invalidation defects. Apple had
  materialized calendar-derived notification copy in the OS queue before
  consent and supporting evidence could be rechecked after process death, while
  moving, deleting, or reclassifying a workout could leave a delivered prompt
  and Workouts action behind on either platform. The replacement stores only a
  generic start and exact fingerprint on Apple, arms a process-local boundary
  task, and gives the existing background-refresh lane a one-shot earliest-wake
  hint. Both paths rerun the complete current-consent and current-evidence
  evaluation before any prompt is created.
- Apple and Android now fingerprint the exact workout start rather than a
  30-minute bucket. Every disabled, superseded, removed, moved, or expired plan
  reconciles its delivery ledger, recomputes the global cooldown from remaining
  deliveries, retracts stale Workouts actions, and cancels the stale
  notification. Android keeps the shared adaptive-day notification when a
  later non-workout delivery owns that slot. Legacy Apple boundary requests are
  removed during scheduling and reconciliation.
- The next exact-head review found five remaining delivery-boundary defects.
  Apple now revalidates both the Adaptive Day and Calendar permissions after
  each notification await, including immediately before and after scheduling.
  Android master opt-out directly retracts planned-workout artifacts; its
  cross-topic cooldown ledger records a bounded fixed owner for each prompt and
  restores the newest remaining owner when a workout prompt is removed.
  Android notifications expire at the workout start, while Apple persists only
  a generic delivered start and fingerprint, arms process-local cleanup, and
  reuses the existing one-shot background-refresh hint for restart recovery.
  Both title classifiers now require fitness context for ambiguous `run`,
  `running`, and `spin` uses and reject work phrases such as payroll, backup,
  staging, deployment, and runbook.
- Final local review closed the Android notify-to-state crash window: if the
  process stops after posting but before the private adaptive-day state is
  saved, master opt-out still force-cancels the shared adaptive notification
  and removes any recorded planned-workout cooldown owner. Ordinary calendar
  edits remain selective and do not cancel a newer non-workout notification.
- The latest exact-head review found four remaining input and ownership gaps.
  A same-day pain/unwell check-in and a changed sleep target now immediately
  request the existing coalesced adaptive-guidance evaluation on both
  platforms, so stale planned-workout advice is withdrawn or recomputed without
  waiting for another lifecycle event. Android now releases the global
  planned-workout prompt owner if Calendar consent disappears after the
  notification post succeeds. Apple also records immediate planned-workout
  notification lifecycle events under `adaptive_day`, matching its durable
  boundary path.
- Review of that replacement head found five final fail-closed gaps. Android
  now treats the Adaptive Day master toggle as part of every planned-workout
  delivery check, blocks the durable boundary worker until the exact current
  Terms are accepted, and uses a monotonic evaluation token plus the current
  Calendar snapshot revision so an older evaluator cannot recreate a moved or
  removed workout after a newer pass. Apple invalidates the current workout
  fingerprint immediately when Calendar or user inputs change and rechecks it
  across notification awaits; a replacement candidate can queue behind the
  invalidated delivery instead of being silently dropped.
- Both planners now distinguish an actual user-set sleep target from the
  implicit eight-hour display default. Fewer than five prior nights therefore
  fail closed unless the user has explicitly edited the target, preventing a
  new user from receiving a personalized-looking sleep-deficit claim against a
  value they never chose. The local title classifier now recognizes
  conservative workout terms across every shipped app language while retaining
  localized work-context exclusions and never persisting the title.
- Final fresh-eyes review found one Apple queue-lifetime race: after an
  in-flight planned-workout delivery drained, the same-kind delivery gate could
  clear even when a coalesced replacement was still queued. The gate now remains
  active until no same-kind pending delivery remains, so another candidate
  cannot bypass replacement coalescing while the queue drains.
- The first hosted Android run on that replacement head compiled and assembled
  the app, then stopped on one stale source-contract assertion after 4,217 tests:
  the test still looked for reevaluation only when the numeric sleep target
  changed. Production intentionally also reevaluates the first time the target
  becomes explicitly user-set. The contract now pins the explicit-state read
  and the first-write-or-value-change condition; the complete local Android
  unit suite passes 4,217 tests with seven expected skips.
- Exact-head review of that correction found three final delivery-lifetime
  races. Rejecting a stale Apple candidate now clears planned-workout artifacts
  only when that candidate still owns the current exact fingerprint, so it
  cannot erase a newer plan. An Apple boundary task now rechecks cancellation
  and exact candidate ownership immediately after notification authorization
  returns, before it mutates persisted state. Android derives notification
  timeout from the remaining lifetime at the actual post instant and rejects a
  workout that expired while waiting for cooldown ownership or notification
  preparation.
- The next exact-head review found one health-input invalidation race. Apple now
  invalidates the current planned-workout fingerprint synchronously when either
  the daily metric publisher or repository refresh revision changes, before it
  queues the coalesced adaptive-guidance evaluation. A notification await using
  pre-refresh sleep or readiness evidence therefore fails closed even if the
  app is suspended before the replacement evaluation completes.
- Exact-head review then found two final cooldown-lifetime gaps. Natural workout
  expiry had reused invalidation reconciliation and removed accepted delivery
  history, while quiet hours or a global cooldown at the two-hour boundary
  discarded the only evaluation even when the restriction ended before workout
  start. Apple and Android now preserve accepted cooldown history when a
  persisted exact-start fingerprint proves the workout has naturally passed,
  while a removed or future workout still receives full state reconciliation.
  Both platforms search only the bounded remaining pre-workout window for the
  next eligible instant and arm one exact retry; duplicate or stale evidence
  remains terminal.
- Final fresh-eyes review covered the later no-adjustment pass as well as the
  direct expiry callback. A persisted planned-workout start is parsed from the
  bounded fingerprint, so reevaluation after workout start cannot subsequently
  erase the preserved cooldown. Malformed fingerprints fail closed through full
  reconciliation, and Android refuses to let an older expiry remove artifacts
  owned by a newer exact fingerprint.
- The newest exact-head review found that Chinese titles with no word
  separators, such as `早上跑步` and `晚间瑜伽课`, could not match the reviewed
  workout vocabulary. Swift and Kotlin now allow substring matching only for
  known Han-script terms and apply the same unsegmented work-context checks
  first. Natural Simplified and Traditional Chinese workout phrases classify,
  while phrases that also contain meeting or seminar terms still fail closed.
- Final protected review found two replacement-lifetime races. Apple now gives
  every adaptive-day evaluation a monotonic generation, invalidates that
  generation synchronously before a replacement is queued, and distinguishes a
  superseded EventKit refresh from a completed refresh with no workout. An
  older provider result therefore cannot clear or recreate guidance owned by a
  newer evaluation. Android now reconciles an orphaned planned-workout cooldown
  owner under the same ledger lock used for delivery and cancels the shared
  adaptive-day notification before owner persistence only when that owner still
  owns the notification slot. A process stop between notification post and
  private state save therefore remains recoverable without erasing a newer
  adaptive-day prompt.
- Review of that replacement found two localized UI correctness gaps. Swift and
  Kotlin now normalize every configured workout and work-context term with the
  same case, width, and diacritic folding applied to incoming calendar titles,
  so terms such as Russian `Йога` remain eligible while German
  `Vorstellungsgespräch` still excludes a work event. The mounted Apple Today
  view also refreshes its lightweight cached daily plan whenever contextual
  intervention inputs change, so an edited sleep target updates visible
  planned-workout guidance without requiring navigation or a full query reload.
- Final replacement review found three notification-priority defects. Planned
  workout fingerprints now use only the planning day and exact start, while
  sleep/readiness evidence remains candidate content; changing supporting
  evidence cannot create a second workout identity or erase accepted cooldown
  history. Both platforms read the prior four-field identity and migrate its
  delivery state in place. Apple and Android also evaluate staleness, quiet
  hours, retry timing, and cooldown state from a fresh clock at the actual post
  boundary rather than the earlier analytics observation. When a future
  workout boundary is successfully armed, both evaluators return before a
  weaker routine or sleep recommendation can be posted.

## Data, privacy, and medical truth

- Schema or migration impact: no app schema migration. Apple temporarily
  retains only a generic planned start, exact fingerprint, and one requested
  background wake; Android WorkManager retains only the generic planned start
  needed for reevaluation. No event content or provider identifier is
  persisted.
- Existing-data retention impact: none.
- Source/provenance or formula impact: a new advisory planner context; existing
  Charge, Effort, Rest, readiness, and sleep formulas remain unchanged.
- Permissions/network disclosure impact: calendar access is explicit opt-in and
  local-only; no network path is added.
- Health/medical claim impact and limitations: advisory planning only; user
  symptoms and self-check remain authoritative.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: bounded
  calendar-refresh operation outcome, authorization category, candidate-count
  bucket, boundary armed/reevaluation/cancellation outcome, Android worker
  outcome, and prompt lifecycle outcome.
- Why existing evidence is sufficient, or why new evidence is required:
  notification lifecycle evidence covers accepted, presented, cancelled,
  suppressed, and unknown Apple requests; Android additionally needs a bounded
  worker operation because its boundary reevaluates evidence before posting.
- Existing evidence reused: `AppDiagnosticsRecorder`, local-notification
  lifecycle ledgers, the existing iOS background-refresh lane, and existing
  contextual cooldown state.
- New bounded events or operation spans:
  `calendar.workout_plan_refresh` with fixed permission state, outcome, duration,
  and zero/one/multiple candidate bucket, including fixed `superseded` and
  `access_changed` outcomes; Apple records fixed
  `adaptive_day.planned_workout_boundary` outcomes (`armed`,
  `reevaluation_requested`, `cancelled`, `expiry_armed`, `expired`, or
  `expiry_cancelled`) and the immediate prompt lifecycle; Android records the
  same boundary identity with enqueue and operation outcomes.
- Latest review-correction coverage: existing fixed `adaptive_day` rejection,
  suppression, cancellation, and stale outcomes cover all three corrected
  boundaries. The final classifier correction needs no new event because title
  text is discarded immediately; only the existing zero/one/multiple candidate
  bucket may be retained. Candidate fingerprints, calendar times, title text,
  health values, and arbitrary errors remain absent from diagnostics.
- Final prompt-priority correction coverage: the existing fixed lifecycle
  outcomes already distinguish accepted, suppressed, cancelled, stale, and
  retry-armed delivery. Stable identity and the fresh delivery clock alter only
  private policy inputs; no new event, calendar value, health value, or dynamic
  identifier is recorded.
- Redaction, retention, and high-frequency controls: no event title, notes,
  attendees, location, calendar/event identifiers, health values, or exact
  dynamic errors; refresh only on explicit enable and bounded lifecycle/data
  changes.
- Cross-platform/backend correlation: Apple and Android use matching fixed
  outcome categories; there is no backend.
- Remaining blind spots: physical permission sheet, actual provider data,
  OS/OEM execution and presentation timing, and vendor-specific calendar
  behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source audit | Existing morning recap, journal, wind-down, adaptive day, and daily-plan paths confirmed | The new work can extend established local-first paths | Real-device delivery or calendar permission behavior |
| `swift test --package-path Packages/StrandAnalytics` | 1,461 passed, 7 skipped | Planner, title classifier, formula, and existing analytics contracts pass | App integration or physical sensors |
| Focused review-correction tests | 32 final Apple tests passed; focused Android permission, delivery, route, provider-change, declined-invitation, boundary-lifetime, active-device, forced-opt-out, and production-compile gates passed | Durable boundary scheduling, exact action and notification expiry, evidence preservation, persisted active-device resolution, enablement reevaluation, provider-change reevaluation, cancellation after EventKit return, declined invitations, persisted Workouts routing, permission-before-cache ordering, access-change clearing, cooldown ownership restoration, forced opt-out, and cooldown-before-`PendingIntent` ordering are covered | Physical permission/provider behavior or notification presentation |
| `DailyActionTodayContractTests` | 5 passed | The Apple visual harness requires the real planner state, positively verifies whether planned-workout context was present, and refreshes its cached plan when contextual inputs change | A rendered simulator screenshot or physical-device layout |
| Latest protected-review correction tests | 27 Apple tests and 16 Android tests passed | Authorization-before-cache ordering, queued-request reconciliation, app-wide Android observer ownership, stale-evaluation cancellation, and consent checks around Android posting are pinned directly | Physical provider callbacks, OS delivery timing, or permission-sheet behavior |
| Final invalidation correction tests | 45 Apple tests passed across boundary, action, intervention, and calendar contracts; the focused Android notifier/action tests and production compile passed; a defensive Apple 30-test and Android notifier rerun also passed | Apple has no pre-materialized time-trigger request, rechecks consent before boundary reevaluation, exact-start fingerprints change on a five-minute move, and both platforms retract stale state/actions while recomputing cooldown | Physical background wake timing, provider callbacks, or notification presentation |
| Latest input-invalidation correction tests | 37 Apple tests passed; focused Android notifier and Today input-contract suites passed | Check-in and sleep-target changes trigger bounded reevaluation, Android post-success consent loss reconciles global prompt ownership, and Apple diagnostics keep the fixed adaptive-day identity | Physical provider callbacks, OS delivery timing, or notification presentation |
| Latest delivery-validity correction tests | 17 focused Swift planner/classifier tests, 34 Apple app integration tests, a final 12-test Apple Calendar queue suite, and the focused Android planner, locale, Calendar, worker, and notifier suites passed | Implicit target values fail closed, shipped-language workout titles classify conservatively, stale evaluation tokens and Calendar revisions are rejected, Android current-Terms and master-toggle gates precede delivery, Apple input invalidation precedes reevaluation, and a queued same-kind replacement retains its delivery gate until the queue drains | Physical provider callbacks, OS delivery timing, translated-title coverage outside the reviewed vocabulary, or permission-sheet behavior |
| Hosted Android replacement run and correction | APK assembly completed; the hosted unit task reported 4,217 tests with one stale source-contract failure and seven skips. After correcting only that assertion, the complete local unit task passed all 4,217 tests with seven expected skips. | Hosted CI exercised the production graph and identified test drift; the replacement contract now matches the reviewed explicit-target behavior without changing production code. | The corrected head is not hosted-green until replacement checks finish; no physical Android behavior is proven. |
| Final delivery-race correction tests | 15 Apple Calendar tests and the focused Android notifier plus Today contract suites passed | Stale Apple rejection cannot clear a newer fingerprint, a superseded Apple boundary task stops after the authorization await, repository health inputs synchronously invalidate stale Apple candidates, and Android notification lifetime is computed from the actual post instant | OS scheduling, notification presentation, or process suspension on physical devices |
| Final cooldown and natural-expiry correction tests | 42 focused Apple tests and the focused Android notifier suite passed | Quiet/global cooldown suppression retries only within the remaining workout window; duplicates remain terminal; natural expiry preserves accepted delivery state; a later no-adjustment pass distinguishes elapsed workouts from future retractions; malformed fingerprints fail closed; and stale Android expiry work cannot clear a newer workout prompt | OS scheduling precision, notification presentation, or process suspension on physical devices |
| Final unsegmented-title correction | All 1,461 analytics tests passed with seven expected skips; the complete Android unit/compile/lint wall passed 4,220 tests with seven expected skips | Swift and Kotlin recognize reviewed Han-script workout terms inside natural Simplified and Traditional Chinese phrases, while embedded meeting and seminar terms retain fail-closed priority | Unreviewed vocabulary, real user calendars, or independent translation review |
| Final replacement-lifetime correction | All 19 focused Apple Calendar tests passed; the focused Android adaptive-day notifier suite passed; `git diff --check` passed | Apple rejects superseded provider results before planning or reconciliation, queued replacement work invalidates the prior generation immediately, and Android orphan cleanup preserves notification-slot ownership while cancelling inside the ledger lock before owner removal | Process termination at every machine instruction, OS notification presentation, or physical provider behavior |
| Final localized-vocabulary and live-cache correction | The focused Swift and Android title-classifier suites passed, all 5 Apple Today contract tests passed, all 1,461 analytics tests passed with 7 expected skips, and `git diff --check` passed | Configured title vocabularies and incoming titles share one normalization path on both platforms, localized work exclusions remain authoritative, and mounted Apple Today recomputes guidance when contextual inputs change | Unreviewed calendar vocabulary, physical provider behavior, or rendered physical-device layout |
| Final workout-identity, post-clock, and priority correction | 51 focused Apple tests passed; the focused Android notifier suite passed; all 1,461 analytics tests passed with 7 skips; all 1,745 Apple app tests passed with 1 expected external-data skip; all 4,227 Android tests passed with 7 skips alongside APK assembly, production compile, lint, and instrumentation-source compilation; the complete unsigned iPhone/widget/watch graph built successfully | A reason-only evidence change retains one exact workout identity and cooldown, legacy identity state migrates without loss, policy uses the actual delivery clock, and an armed workout boundary suppresses weaker adaptive prompts on both platforms | Physical notification timing, OEM/provider behavior, process suspension, signing, or store distribution |
| Complete macOS app suite | 1,739 passed, 1 expected external-data skip, 0 failures | The complete shared app integration, generated localization, exact-start identity, stale-artifact reconciliation, bounded retry policy, preserved natural-expiry cooldown, background-wake policy, consent reconciliation, current check-in and sleep-target invalidation, cancellation contract, generation supersession, and affected routing graph pass together | iOS runtime or physical Calendar behavior |
| App-wide localization contract | 2 passed with exactly 636 keys | All five new strings exist in all nine locales and Apple/Android generated resources match the source exactly | Independent translation quality review |
| Unsigned iOS simulator build | Passed after review corrections | Complete iPhone/widget/watch dependency graph compiles with the permission declaration and UI | Physical calendar data, background timing, haptics, or battery |
| Fail-closed iOS daily-plan visual matrix | Seven states passed on a disposable iPhone simulator, including large text, increased contrast, dark mode, and the 6h12/17:30 planned-workout fixture | Every accepted image had the expected planner availability and planned-workout category, nonblank rendered pixels, and a live app process; the simulator was removed afterward | Physical-device layout, real calendar permission/provider behavior, or background delivery |
| Planned-workout visual inspection | `planned-workout.png`, 1170x2532 and 535,203 bytes, reviewed | Sleep, start time, exact 1h18 deficit, guidance, range, and bottom navigation are visible without overlap in the deterministic fixture | Every device size, locale, accessibility setting, or real user history |
| Android full gate | 4,223 passed, 7 skipped; APK assembly, production compile, lint, and instrumentation-source compilation passed on the final local source | Kotlin parity, app integration, localization contracts, exact-start identity, stale delivery/action reconciliation, preserved natural-expiry history, bounded transient-suppression retry, owner-aware shared cooldown and notification-slot restoration, crash-recoverable orphan cleanup, forced master-opt-out cleanup, app-wide calendar observation, consent-at-post enforcement, durable worker boundary, persisted active-device resolution, reviewed permission/routing/provider corrections, and static Android policy pass | OEM Calendar Provider, WorkManager timing, process termination at every instruction, or physical notification behavior |
| Focused Android calendar and demo-fixture tests | 3 passed | Logical-day bridging, cancellation-before-generic-failure ordering, fatal-error propagation, and the exact 6h12/17:30 scenario remain deterministic | A real Calendar Provider query, OEM cancellation latency, or rendered emulator screenshot |
| Final Apple graph | Unsigned `NOOPiOS` Debug build completed with exit 0 and `BUILD SUCCEEDED`, including the iPhone app, widgets, and watch app after the consent-safe boundary and stale-artifact correction | The complete Apple dependency graph compiles on the final local source | Signing, installation, physical calendar access, background delivery, or hardware behavior |
| Repository policy and terminology | 227 Tools tests passed after reviewed snapshot regeneration; release controls retained 9 checks, required CI retained 10 contexts, all 51 operations records validated, and terminology retained 17,371 occurrences across 1,512 classified path/category groups with reviewed active-allowlist SHA `77fd12aef2246bf73486eed92d4e8f8e9e9981caf3c2ac158b3d671448731bc7`, inventory SHA `56cffcb66debc0bffb71989fabbeed362c2559c58d26dd0f6cac4b9bf172121b`, and zero forbidden mappings. i18n, health-claims, calibration parity, legal provenance, and private-data gates also passed. | The final source and evidence preserve required CI, durable-record, privacy, and terminology controls; the active allowlist and category totals are unchanged, while reviewed source and test locations moved with the correction | Independent legal review or physical-device behavior |

## Physical device and deployment

- Install/update action: simulator build only; no physical install
- Generalized device and OS class: not run
- Data-preservation result: no migration planned
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: iOS and Android physical calendar authorization,
  provider query, notification timing, background behavior, accessibility, and
  battery impact

## Git and release state

- Changed paths: shared planners/classifiers and tests; Apple/Android calendar,
  Today, Automations, notification, permission, localization, privacy, and ops
  records
- Commits: `b8ae332d` (private calendar-aware guidance), `4b8c010e`
  (refresh cancellation), `28a75392` (fatal provider errors), `b752de56`
  (deterministic visual fixtures), and `0222fe1a` (fail-closed visual
  verification), `ceeab3f0` (first exact-head review corrections and hosted
  localization ratchet), `070a4d3a` (provider, cancellation, and declined-
  invitation closeout), `dc1cb776` (replacement closeout evidence), and the
  delivery-boundary correction plus latest consent/lifecycle correction
  containing this record
- Branch and remote state: protected pull request `#14` remains open; the final
  workout-identity, post-clock, and priority corrections are locally verified,
  and normal merge is pending commit, push, fresh exact-head review, and
  replacement required checks
- Parent integration state: visual-parity pull request `#13` merged normally to
  protected `main` as `2efd5e89`; this branch is now rebased onto that exact
  commit, has completed replacement local verification, and still requires
  protected review and normal merge.
- Repository visibility verified: private GitHub repository already verified by
  the preceding round
- Version/build impact: none planned
- Release or distribution impact: source-only until protected review and merge

## Decisions

- Durable decision added or changed: planned-workout context remains optional,
  local-only, generic, and subordinate to the user's same-day self-check.
- Decision-log entry: `D-053`

## Open risks and honest limitations

- Calendar event titles are unstructured and can only support conservative
  keyword classification. The bounded shipped-language vocabulary rejects
  localized work contexts plus spectator, shopping, ticket, and
  equipment-service contexts; unknown words and ambiguous events are
  intentionally ignored.
- Apple uses a process-local boundary task while alive and submits a one-shot
  earliest-wake hint through its existing background-refresh lane for
  process-death recovery; Android submits a durable WorkManager reevaluation.
  Both operating systems can defer or suppress background work, and neither a
  build nor a simulator proves physical delivery timing. Apple deliberately
  does not preload calendar-derived notification copy, so a deferred or denied
  background wake can mean no boundary prompt rather than a stale prompt.

## Next round

1. Commit and push the final workout-identity, post-clock, and priority
   correction, obtain a fresh exact-head review, resolve the three
   replacement-head conversations with evidence, and complete a normal
   protected merge without bypass.
2. Run the permission, provider-change, foreground/background notification,
   accessibility-size, and battery matrix on representative iOS and Android
   physical devices before release.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
