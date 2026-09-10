# Round: 2026-09-10 - Calendar-aware daily guidance

## Status

- State: `post-rebase local verification complete; protected integration and physical-device evidence pending`
- Owner: project team
- Branch: `codex/calendar-aware-daily-guidance-20260910`
- Start commit: `67ffd848094bbc3e7cbab682feed592c68a10f88`
- End implementation commit: `0222fe1a410943ce6bd849361308e889f14911f2`
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

## Data, privacy, and medical truth

- Schema or migration impact: none; only bounded local preferences.
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
  bucket, and prompt outcome.
- Why existing evidence is sufficient, or why new evidence is required: current
  notification lifecycle evidence covers accepted/suppressed requests, but no
  calendar boundary exists yet.
- Existing evidence reused: `AppDiagnosticsRecorder`, local-notification
  lifecycle ledgers, and existing contextual cooldown state.
- New bounded events or operation spans:
  `calendar.workout_plan_refresh` with fixed permission state, outcome, duration,
  and zero/one/multiple candidate bucket, including fixed `superseded` and
  `access_changed` outcomes; existing notification lifecycle evidence records
  accepted and suppressed prompts.
- Redaction, retention, and high-frequency controls: no event title, notes,
  attendees, location, calendar/event identifiers, health values, or exact
  dynamic errors; refresh only on explicit enable and bounded lifecycle/data
  changes.
- Cross-platform/backend correlation: Apple and Android use matching fixed
  outcome categories; there is no backend.
- Remaining blind spots: physical permission sheet, actual provider data,
  suspended delivery, and vendor-specific calendar behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source audit | Existing morning recap, journal, wind-down, adaptive day, and daily-plan paths confirmed | The new work can extend established local-first paths | Real-device delivery or calendar permission behavior |
| `swift test --package-path Packages/StrandAnalytics` | 1,459 passed, 7 skipped | Planner, title classifier, formula, and existing analytics contracts pass | App integration or physical sensors |
| Focused macOS app tests | 19 passed | Calendar bridge, private routing, truthful signal evidence, cooldown ordering, and affected contextual policies pass | iOS EventKit permission sheet or notification presentation |
| `DailyActionTodayContractTests` | 4 passed | The Apple visual harness requires the real planner state and positively verifies whether planned-workout context was present | A rendered simulator screenshot or physical-device layout |
| Unsigned iOS simulator build | Passed | Complete iPhone/widget/watch dependency graph compiles with the permission declaration and UI | Physical calendar data, background timing, haptics, or battery |
| Fail-closed iOS daily-plan visual matrix | Seven states passed on a disposable iPhone simulator, including large text, increased contrast, dark mode, and the 6h12/17:30 planned-workout fixture | Every accepted image had the expected planner availability and planned-workout category, nonblank rendered pixels, and a live app process; the simulator was removed afterward | Physical-device layout, real calendar permission/provider behavior, or background delivery |
| Planned-workout visual inspection | `planned-workout.png`, 1170x2532 and 535,203 bytes, reviewed | Sleep, start time, exact 1h18 deficit, guidance, range, and bottom navigation are visible without overlap in the deterministic fixture | Every device size, locale, accessibility setting, or real user history |
| Android full gate | 4,194 passed, 7 skipped; production compile and lint passed | Kotlin parity, app integration, localization contracts, and static Android policy pass | OEM Calendar Provider or physical notification behavior |
| Focused Android calendar and demo-fixture tests | 3 passed | Logical-day bridging, cancellation-before-generic-failure ordering, fatal-error propagation, and the exact 6h12/17:30 scenario remain deterministic | A real Calendar Provider query, OEM cancellation latency, or rendered emulator screenshot |
| Post-rebase Apple graph | Unsigned `NOOPiOS` Debug build completed with exit 0 and `BUILD SUCCEEDED`, including the iPhone app, widgets, and watch app | The complete Apple dependency graph still compiles after rebasing onto protected `main` at `2efd5e89` | Signing, installation, physical calendar access, background delivery, or hardware behavior |
| Repository policy and terminology | 227 Tools tests passed; all 51 operations records validated; terminology audit retained 17,367 occurrences across 1,511 groups, a byte-identical active allowlist, and zero forbidden mappings | The rebased source and evidence preserve required CI, durable-record, privacy, and terminology controls | Independent legal review or physical-device behavior |

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
  verification)
- Branch and remote state: rebased branch synchronized to `origin` at
  `61651bbc`; protected pull request `#14` is open and merge remains pending
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
  keyword classification. The initial bounded English-keyword set rejects
  work, spectator, shopping, ticket, and equipment-service contexts; unsupported
  languages and ambiguous events are intentionally ignored.
- Pre-workout evaluation runs on supported foreground, calendar-change, data,
  and background-ingestion opportunities. iOS and Android still own suspended
  execution and can defer routine reminders; exact background timing requires
  the physical-device matrix below.

## Next round

1. Complete protected review and normal merge without bypass.
2. Run the permission, provider-change, foreground/background notification,
   accessibility-size, and battery matrix on representative iOS and Android
   physical devices before release.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
