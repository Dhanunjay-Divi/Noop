# Round: 2026-09-11 - Product, safety, and quality audit

## Status

- State: `supplier-independent implementation, exact-current-tree local wall,
  UI-audit and feedback-ingestion closeout, and independent review complete; one
  consolidated replacement push, corrected exact-SHA checks, and normal PR #15
  integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `2efd5e89999bd54b3fd6e316322b39d7e953ee8f`
- End implementation commits: first consolidated hosted correction head
  `142eeec5`; latest pushed production-shell correction `66c2b0a9`; the
  exact-current local implementation and closeout are
  `156937fc642980286355cb663b9f3840af7e4923`; its record follow-up forms the
  replacement PR head
- Record commit or PR: pull request `#15`

## Objective

Audit and substantially improve NOOP across product strategy, health and
fitness safety, nutrition, managed Safety/SOS, UX/UI, architecture,
reliability, accessibility, testing, and documentation. Use the current
repository as the source of truth and treat the owner-provided private session
export plus reference-image directory as review inputs, not distributable
product assets or settled requirements.

Success requires severity-ranked findings backed by current source evidence,
explicit build/defer/reject decisions, scoped cross-platform fixes, bounded
privacy-safe observability, relevant local verification, and durable handoff
records. Concurrent development must remain isolated by worktree and branch.

## Scope

### In scope

- Product coherence across Today, Sleep, Fitness, Nutrition, Journal,
  Automations, Friends, and Safety.
- Health-claim, false-precision, metric-provenance, calibration, consent,
  notification-fatigue, and emergency-boundary review.
- Apple and Android UX, accessibility, performance, lifecycle, and parity.
- Architecture, storage, background execution, reliability, diagnostics,
  testing, release controls, and documentation.
- Evidence-based evaluation of background workout detection and its
  notifications.
- Evidence-based evaluation of optional BMI, body-composition inputs,
  weight-goal pacing, and in-activity goal nudges.
- Review of supplied screenshots, videos, animations, and reference material
  for user value, safety, accessibility, provenance, licensing, and technical
  suitability.
- Supplier-independent fixes that can be verified without physical hardware,
  production credentials, public traffic, or real health-data transfer.

### Non-goals

- Inferring body fat or body composition from unsupported band signals.
- Presenting BMI as a diagnosis, a complete health assessment, or a universal
  target.
- Prescribing rapid weight loss, compensatory exercise, unsafe calorie
  restriction, or medical treatment.
- Claiming reliable terminated-app detection, background delivery, BLE,
  haptics, battery behavior, or notification timing from simulator evidence.
- Enabling automatic medical/fall inference, emergency-service dispatch,
  public paging, public cloud traffic, or real participant health-data upload.
- Importing third-party videos or artwork without verified rights and
  appropriate health/safety review.
- Editing or rebasing the concurrent calendar-aware guidance worktree.

## Starting evidence

- Reproduction or observed symptom: the owner reports that another health app
  detected a workout while its UI was not active and issued a useful
  notification. The owner also supplied body-composition, BMI/weight-goal,
  workout-guidance, and instructional-media references for evaluation.
- Relevant source/device/OS/firmware class: current macOS/iOS/Watch and
  Android applications, local analytics and stores, HealthKit/Health Connect,
  notification/background integrations, nutrition, and managed Safety.
- Existing tests, logs, exports, screenshots, or documents: repository tests
  and operations records; approximately 59 million lines in the private
  `noop.json` session export; 68 private reference images plus one PDF in
  `noop_ref`; separately supplied videos in Downloads that require correlation
  and provenance review.
- Unknowns that must remain unknown until measured: whether the reference
  workout prompt was true on-device detection, delayed wearable sync,
  HealthKit/Health Connect ingestion, or another app's workout record; actual
  physical-device background behavior; body-composition source accuracy;
  video ownership and instructional review; user benefit and alert-fatigue
  rates.

## Delivered

- Created an isolated audit worktree and branch from protected-main source so
  broad review cannot overwrite the active calendar-aware branch.
- Added one shared Apple/Android body-profile policy. BMI is shown only for an
  adult with confirmed age, height, and weight; seeded editor defaults cannot
  become personal BMI or Health Connect-derived BMI history.
- Kept body composition source-bound. Imported weight, whole-body fat, and lean
  mass retain source/date context; NOOP does not infer segmental fat, muscle,
  or body shape from band signals.
- Kept target weight user-owned and non-prescriptive. Unsupported contexts,
  unconfirmed measurements, age below 20, and underweight-current BMI suppress
  target progress instead of producing a pace, deadline, calorie instruction,
  or exercise prompt.
- Added Android parity for the existing Apple activity-suggestion interruption
  consent. Detection can remain in Ask mode for quiet Today review while Lock
  Screen suggestions are separately default-off, permission-aware, and cleared
  when disabled or when OS authorization is revoked.
- Integrated the reviewed calendar-aware daily-guidance source with separate
  default-off consent, content-discarding local classification, evidence-gated
  adjustments, stale-plan cleanup, and private cooldown-ranked prompts.
- Replaced scalar-only Apple hydration persistence with schema-v55 editable
  rows and an atomic scalar projection. Legacy preferences migrate once; rapid
  adds, edits, and deletes serialize; missing imported totals remain missing;
  failed writes do not advance reminder state. Android now matches the same
  source-merge, failure, and accessibility contract.
- Implemented local corrections for the second hosted-review hydration path
  findings. Apple schema v56 installs durable insert/update/delete tracking for
  existing hydration rows, validates remote hydration payloads, atomically
  refreshes the scalar projection after remote upsert or tombstone, and
  suppresses outbox echo. Android Today retains the last confirmed hydration
  total across a transient read failure but still clears a confirmed missing
  result.
- A later fresh Apple review found three additional managed-document gaps in
  the correction head: client-encrypted personal rows could enter the
  older server-readable adapter, remote application could overwrite an
  unacknowledged local generation, and hydration restore accepted
  insufficiently exact numeric, date, timestamp, and identifier inputs. The
  final correction partitions outbox rows by content mode,
  allowlists only `dayOwnership` for the server-readable adapter, retains
  client-encrypted hydration, journal, preferences, and other personal
  documents locally, maps local-generation collisions to conflict, and adds
  strict hydration bounds.
- A fresh Android review found that profile-height changes after the one-time
  Room migration could leave Health Connect BMI derived from an older height,
  that a historical Today date could read or retain another day's hydration,
  and that cancellation after a successful best-effort load could still
  publish the late result. The final correction adds a durable
  local height-dependency fingerprint, forces only Weight through full
  supported-history projection when that dependency changes, preserves every
  cursor and the old fingerprint on failure, rejects non-finite height, scopes
  hydration reads and transient retention to the displayed day, and rechecks
  cancellation before publication.
- Replaced history-sized launch/resume and BLE post-backfill score
  fingerprinting with a durable generation/acknowledgement ledger. Apple
  schema v57 and Android Room v48 seed existing sources and install
  conflict-safe triggers over all ten score-bearing raw tables. Analysis
  snapshots without clearing, acknowledges only after the full persistence
  boundary succeeds, survives process death and partial failure, and leaves a
  concurrent write pending. Formula-only forced passes still run without
  manufacturing a claim, blank IDs are excluded, and source deletion removes
  the marker last.
- Added a shared one-notification budget for each completed wearable or
  external-health sync. Workout review, post-workout summary, adaptive-day
  guidance, and morning recap cannot burst from one late sync, and skipped
  lanes retain their durable frontier for later reconsideration.
- Implemented the local correction for the queued-delivery ownership race found
  in hosted review. Clearing Apple workout suggestions now releases every
  queued reservation before discarding it, while the suspended active delivery
  retains its own defer-based cleanup. Android remains synchronous and already
  releases every reservation on failure.
- Hardened wind-down delivery with generic private-preview copy, suppression
  when fresh computed sleep evidence shows the user is already asleep, and
  conservative fail-open handling for stale, edited, sparse, malformed, or
  future sleep evidence.
- Extended Apple's one-shot wind-down schedule to 28 nights and uses the
  existing finite background-refresh lane to request renewal while three weeks
  of reminders remain. Android now persists nullable `gravitySparse` evidence
  through local analysis, Room, managed export, and restore; sparse or unknown
  motion can no longer suppress a reminder.
- Removed Today text-size caps, made the workout-coach row adapt vertically at
  accessibility sizes, and added explicit expanded/collapsed state semantics
  on Apple and Android. App-wide localization now contains 685 generated keys
  across nine locales.
- Made Safety precise-location retention terminal-state complete. Preview
  expiry, cancellation, acknowledgement, exhaustion, closure, and deletion
  cancel pending delivery and delete latest precise location in both memory and
  PostgreSQL implementations; direct lifecycle tests cover the durable state.
- Added PostgreSQL migration `033` to purge precise location rows already
  retained by terminal incidents from older deployments while preserving open
  and acknowledged incidents.
- Added Android Room v46 and v47. V46 removes legacy Health Connect BMI rows
  derived by older builds from the untouched 178 cm editor seed, retains real
  weight and non-Health-Connect BMI rows, and stores nullable sleep
  motion-quality evidence. V47 clears only the WeightRecord incremental cursor
  so the next authorized full reconciliation can rebuild supported BMI history
  from confirmed height while preserving every unrelated provider cursor. The
  Body screen also requires confirmed adult age, confirmed height, and current
  weight before displaying BMI.
- Provider invalidation now withdraws the published Android calendar snapshot,
  cancels scheduled reevaluation, and retracts old planned-workout artifacts
  before a replacement query. A failed provider refresh therefore cannot leave
  guidance for a moved or deleted workout.
- Classified Apple `hydrationEntry` as a client-encrypted managed hydration
  target without enabling production upload or changing core NOOP's local-first
  behavior. Apple owns row-level hydration document restoration; Android keeps
  its existing scalar `metricSeries`/chunk path, so the platform asymmetry is
  intentional and recorded rather than hidden.
- Width-normalized Android calendar titles with compatibility decomposition,
  matching the established classifier behavior for full-width Latin workout
  text without broadening the reviewed workout vocabulary.
- Made the deterministic visual harness reliable from temporary worktrees by
  staging synthetic simulator logs outside `/private/tmp`; added an
  accessibility-size Today scenario and validated 42 unique captures.
- Classified supplied exercise media as deferred: the reviewed downloads do
  not currently establish redistribution rights or clinical/instructional
  review, so none was copied into source or a shipping bundle.
- Added a small root `AGENTS.md` and the project-scoped `noop-ops` Codex skill
  under `.agents/skills/noop-ops`. The root file makes the handoff contract
  deterministic for a new repository session; the skill routes future agents
  to focused product/health-safety, repository-map, and verification/handoff
  references. Its bounded context snapshot restores the live branch, worktrees,
  recent commits, active operations record, round inventory, and toolchain
  without treating old chat as source of truth.
- Kept current implementation state out of the skill itself. Ephemeral status,
  dirty-path ownership, exact verification, deployment state, and next commands
  remain in this round and `docs/ops/ACTIVE.md`, so the reusable skill cannot
  silently become a stale completion claim.
- Statically assessed the owner-supplied HBand/Veepoo Android and iPhone SDK
  package without copying its 297 MB of private binaries into Git. The review
  records candidate confirmation/password, capability, live/history, haptic,
  reconnect, and OTA surfaces; the mandatory serialized command queue; the
  arm64 iPhoneOS-only Apple archive; unsafe demo permissions/networking; hard
  coded vendor endpoints; incomplete distribution/privacy evidence; and the
  physical/supplier acceptance matrix. The resulting architecture keeps one
  active phone collector while Mac and additional devices are managed-sync
  viewers.
- Created and published the separate private
  `Dhanunjay-Divi/NoopBandSDK` repository at initial commit `ee82cc0`. Its
  NOOP-owned API/docs scaffold is English-only and binary-free, its local gate
  rejects CJK text and tracked supplier artifacts, and no GitHub Actions
  workflow was enabled. The original multilingual supplier drop remains
  immutable outside Git rather than being rewritten, preserving provenance and
  avoiding an unsupported redistribution.
- Added Apple schema `58` to repair pre-release analysis dirty-window bounds
  and schema `59` to partition managed-document mutation intent by the account
  active when each local edit occurs. Legacy unowned intent is quarantined
  under an unbound random local profile instead of being attributed to the next
  signed-in account.
- Added Android Room schema `49` for editable hydration rows and schema `50`
  for the matching managed-document account partition. Both platforms clear
  stale intent from another profile before recording a current-account
  mutation, create no upload intent while signed out, and retain all local
  personal records.
- Added PostgreSQL migrations `034` through `037` to expand the managed
  document-kind registry and inventory contract-v2 readiness without exposing
  or mutating personal content. A fresh review found that the earlier draft
  would have erased legacy plaintext and published encrypted tombstones that
  current clients cannot consume. The corrected migrations never change a
  document, head, or change cursor, and they leave the stricter database
  content-mode constraint gated until versioned client encryption, restore,
  key recovery, and backfill exist. Migration `038` adds the accepted-contact
  band-origin SOS admission path with server-side coalescing; automatic
  medical or fall inference remains disabled.
- Centralized Android notification construction behind `PrivateNotification`
  so hidden previews remain generic across adaptive guidance, workout,
  hydration-adjacent, Safety, social, stale-sync, stress, illness, and report
  lanes. The final review found that the persistent BLE connection service was
  still public while displaying Recovery and Effort; it now uses the same
  neutral public version, and the source contract scans the BLE lane as well
  as alarm, notification, and Safety code. Apple and Android wind-down,
  journal, morning, and routine prompts retain separate consent, quiet-hour,
  completion, cooldown, and already-asleep suppression.
- Replaced stale full-history analysis fingerprint work with bounded
  generation-ledger checks in the actual launch, resume, Health Connect, and
  BLE catch-up entry points. Full package, application, migration-oracle,
  Android source-compilation, and PostgreSQL tests now exercise the current
  implementation rather than relying on the earlier static harness.
- Replaced the repository README end to end with a product-first guide to
  NOOP's daily experience, platform surfaces, first-run and ownership
  boundaries, NOOP versus NOOP+, local-first privacy, Safety limitations,
  architecture, builds, release status, and documentation. Every local link
  and the checked-in product mark resolve: 379 lines, 15,138 bytes, and 35
  local links with zero missing targets. The page makes no hardware, clinical,
  signing, store, or launch-readiness claim.
- Reviewed the latest desktop, routine-notification, and calendar-guidance
  references as interaction evidence rather than distributable assets. NOOP
  retains its approved metric-first desktop hierarchy; wind-down, journal, and
  morning prompts remain separate consented/private lanes; and Daily Plan may
  combine supported sleep/readiness evidence with a generic local workout
  window. Third-party marks, exact copy, retained calendar content, fixed
  notification times, and the unsupported "optimal performance" claim were not
  copied.
- Closed two findings from the replacement exact-tree review of managed
  restore. The server change feed now joins a document on account scope,
  stable identifier, revision, and document kind, so equal identifiers across
  kinds cannot return the wrong payload. Apple schema `60` and Android Room
  schema `51` persist change-feed capability version `1`; a client with a
  legacy cursor must complete a supported-kind snapshot before incremental
  changes advance, while failed or stale snapshot completion cannot bless a
  newer cursor. The generated Room schema now includes the managed-sync state
  source in its freshness hash and requires a v2 KSP generation proof bound to
  both schema-bearing source bytes and current-version JSON bytes before the
  test snapshot can be copied. A real 50-to-51 migration preserves an existing
  cursor and interrupted snapshot state. The producer also retains a proven
  unchanged schema across unrelated incremental Kotlin work, while a tampered
  generated schema forces KSP regeneration back to the canonical hash.
- Corrected the iPhone floating navigation shell after maximum Dynamic Type
  evidence showed readable content under the status area and behind persistent
  controls. The measured bar height is now reserved once as a real safe-area
  inset; accessibility sizes add an opaque reading boundary without flattening
  normal glass. A zero-height Daily Plan anchor keeps deterministic QA focused
  on the real planner state without changing production order or preferences.
  Android already measures its navigation rail, applies that height through
  Material `Scaffold`, and adds system navigation-bar padding, so no matching
  source change was required.
- Corrected the Android production-shell navigation test after the first
  consolidated hosted run proved that the HRV tile was outside the composed
  portion of Today's lazy list. `LazyScreenScaffold` now offers a distinct
  modifier for the actual `LazyColumn`; Today exposes a stable list marker; the
  test uses list-level `performScrollToNode`, validates the Today root rather
  than virtualized child visibility, restores the acceptance/onboarding/
  changelog state it mutates, and no longer overwrites the user's Today order.
  No metric visibility, ordering, or health behavior changed.
- Corrected a current-iOS Today scroll stall reproduced by repeated direction
  changes. A zero-height `GeometryReader` preference probe inside the lazy
  content could leave iOS in an unbounded layout transaction. Current iOS now
  reports a normalized scroll position through native scroll geometry; iOS 17
  and macOS retain one full-content compatibility probe outside the lazy
  stack. Pull-to-refresh, interaction ownership, shell compaction, and
  scroll-to-top continue to consume the same normalized offset.
- Corrected the final-control reachability defect on pushed iPhone
  destinations. The shell measures its persistent navigation once, keeps one
  viewport safe-area reservation for tab roots, and passes the measured height
  only to pushed screen content as a tail reservation. Sleep Planner exposes
  stable weekday-row accessibility identities, and UI coverage accepts either
  compact or accessibility-expanded navigation without weakening the endpoint
  clearance assertion.
- Updated two source-contract tests whose old slice ended at the removed
  geometry modifier. They now inspect the real `liquidBody` mount boundary and
  continue to require both the health alert and auto-detected workout card in
  their production order.
- Closed the final managed-Safety admission and concurrency review. The server
  now locks the active caller/account/profile and eligible push installation
  rows before snapshot or incident creation, and runtime push unavailability
  fails with `503` before an incident is persisted. Both phones derive
  readiness from delivery-capable accepted contacts and refresh immediately
  before creation. Android serializes incident creation with a dedicated
  mutex; Apple uses one cancellation-aware FIFO gate shared by manual and band
  paths, removes cancelled waiters, releases cancelled handoffs, propagates
  caller cancellation through shared refresh, and rechecks cancellation before
  authorization and persistence. The first independent review found that an
  unstructured shared refresh could outlive its caller and still page; the
  final source and focused regressions close that path, and exact-current
  re-review returned no actionable findings.
- Preserved cross-platform backup compatibility without reviving retired
  planner state. Apple and Android schema-v5 payloads retain the historical
  weekday wake shape, Android round-trips legacy `windDown.recoveryMinutes`
  without mapping it into current settings, and every verified full database
  replacement clears stale planner-derived recovery independently of whether a
  settings sidecar exists. Database-only restores therefore clear the derived
  value; Android clears it before applying an optional sidecar, so an empty,
  malformed, or unknown-only sidecar cannot bypass the reset. Settings-only
  import does not clear current planner state.
- Kept daily guidance and calendar context current without duplicate work.
  Android resume coalesces an already active calendar refresh instead of
  invalidating its generation; same-identity contextual actions refresh their
  evidence and copy while retaining creation, route, source, and identity; and
  the shared planner now has real `America/New_York` fallback-day coverage.
- Closed all four P1 and sixteen P2 findings in the private cross-platform UI
  audit. Recovery presentation, Daily Signal vocabulary, tab accessibility,
  Trends loading/retry/cancellation, imported-sleep disclosure, missing-value
  formatting, evidence-aware coach copy, device copy, age, current product
  vocabulary, Stress, Charge details, Journal spacing, NOOP+, Health Monitor,
  and Sleep naming now agree across applicable Apple and Android surfaces.
- Added one explicit user-reviewed **Send feedback** path on both phones with
  durable local outboxes, exact attachment ownership, bounded redacted
  diagnostics, screenshot sanitization, best-effort background continuation,
  lifecycle progress, cancellation, retry, and terminal cleanup. The backend
  adds a fail-closed capability/principal boundary, tenant isolation,
  PostgreSQL/object lifecycle, quotas, and payload-free observability; public
  ingress, attestation, operator, monitoring, legal, and physical-device gates
  remain disabled or external.
- Applied the latest desktop, notification, and adaptive-day references as
  interaction principles only: compact metric-first hierarchy, concise private
  reminders, and an explainable collapsed planned-workout adjustment. No
  third-party branding, copy, imagery, exact event details, fixed delivery
  times, or unsupported performance promise entered the product.
- Added an exact-current eleven-state iPhone visual matrix, including normal and
  accessibility collapsed planned-workout states. Stale macOS WindowServer
  surfaces were excluded from product evidence; current source, built objects,
  resources, and the complete macOS test suite are the authoritative desktop
  evidence.

## Data, privacy, and medical truth

- Schema or migration impact: Apple local database schema `54` to `55` adds
  `hydrationEntry`; schema `56` installs and backfills its managed-document
  tracking; schema `57` adds the per-source analysis generation ledger and
  seeds score-bearing sources; schema `58` repairs dirty-window bounds for
  pre-release databases; schema `59` partitions managed-document intent by
  local account profile; schema `60` adds persisted change-feed capability
  versions to the change cursor and snapshot checkpoint. Existing scalar
  hydration history migrates once into an editable row and the scalar
  projection remains transactionally aligned after local or remote mutation.
  Android Room schema `45` to `46` adds
  nullable `sleepSession.gravitySparse` and removes only legacy Health
  Connect-derived BMI rows; schema `47` resets only the WeightRecord sync
  cursor for a complete supported reprojection; schema `48` adds the matching
  analysis generation ledger, seed, and triggers; schema `49` adds editable
  hydration rows; schema `50` partitions managed-document intent by local
  account profile; schema `51` adds the matching persisted change-feed
  capability versions. PostgreSQL migration `033` removes precise locations
  joined to terminal Safety incidents; migrations `034` through `037` expand
  the document-kind registry and write aggregate contract-v2 readiness without
  changing user content; migration `038` adds band-origin accepted-contact SOS
  admission and coalescing. Migration `040` adds feedback-principal lifecycle
  cleanup. The stricter managed-document database content-mode constraint is
  not active.
- Existing-data retention impact: no source biometric measurement was
  uploaded or removed. The Android migration deletes unsupported derived BMI,
  not Health Connect weight or another source's BMI. The fresh Android
  correction stores only a local dependency fingerprint and does not send that
  reserved state row to Health Connect. Safety location now has stricter
  deletion at preview expiry, every incident terminal state, and upgrade
  cleanup for legacy terminal rows. The managed-document readiness migration
  stores aggregate counts only; it does not scrub payloads, add tombstones,
  advance revisions, update heads, or append change events.
- Source/provenance or formula impact: BMI remains the conventional
  weight/height screening calculation, but now requires confirmed adult inputs.
  Body-composition values remain imported measurements with source/date
  context. Hydration preserves manual and imported provenance instead of
  manufacturing a total when a source is missing. No band-derived
  body-composition formula was added.
- Permissions/network disclosure impact: Android requests notification
  permission only after the user explicitly enables activity suggestions.
  Calendar data is read only after separate user opt-in and platform
  authorization, event content is not persisted in guidance state, and no new
  endpoint, public traffic, health upload, or background entitlement was added.
- Managed-storage boundary: the storage map requires `client_encrypted` content
  for hydration and other personal documents. Client encryption and key
  recovery are not implemented. The fresh Apple correction therefore leaves
  those encrypted rows durable and local, while the older server-readable
  adapter is restricted to the reviewed `dayOwnership` operational kind and
  rejects hydration in either wire mode. The API enforces the wire boundary,
  but PostgreSQL does not yet activate a content-mode check over legacy rows.
  Capability-versioned restore prevents an older filtered change cursor from
  silently skipping a kind added to the supported client set. This round does
  not establish an encrypted upload or restore path.
  Production health-document transfer and database contract activation remain
  disabled until client encryption, key recovery, versioned backfill, security
  review, and physical-device validation are implemented and independently
  verified.
- Health/medical claim impact and limitations: BMI is optional adult screening
  context, not diagnosis or body composition. Target weight is not a NOOP
  recommendation. NOOP does not prescribe weight-loss pace, calories, or
  compensatory activity. Safety remains accepted-contact paging, not emergency
  dispatch or automatic medical inference.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: hydration
  mutation results are explicit success/failure values; remote hydration
  insert, update, and tombstone tests inspect durable outbox, projection, and
  no-echo state; Android Today distinguishes transient read failure from
  confirmed missing data. Existing bounded notification ledgers retain posted,
  suppressed, cancelled, and unknown outcomes; one new
  `post_sync.notification_budget` event records only the fixed winning lane and
  source class. Safety lifecycle tests inspect durable delivery cancellation
  and location deletion directly.
- Existing evidence reused: both mobile `AppDiagnosticsRecorder`
  implementations, server request observability, notification lifecycle
  ledgers, and the user-initiated redacted diagnostic report.
- New bounded events or operation spans: one per completed sync only, with
  categorical `lane`, `outcome`, and `source`; no health value, time, text,
  account, device, contact, or payload is logged.
- No new event was added for the deterministic Room cursor migration, title
  normalization, or hydration projection trigger. Their exact state
  transitions are covered by migration and persistence tests, while logging
  row values, titles, or hydration amounts would add privacy risk without
  improving diagnosis.
- No new event is warranted for the fresh content-mode partition, local
  generation conflict, BMI dependency fingerprint, or displayed-day hydration
  selection. Their outcomes are deterministic local state transitions covered
  by direct tests; logging document content, profile height, BMI, hydration
  amount, or day values would weaken the existing privacy boundary.
- The analysis invalidation gate records only existing bounded
  `analysis.recent` booleans/outcome/resource fields. BLE retry diagnostics use
  fixed outcomes and exception class only; source identifiers, raw values, and
  exception messages are excluded. The durable ledger itself is the restart
  evidence, so no high-frequency per-sample event was added.
- Redaction, retention, and high-frequency controls: private review inputs must
  never be copied into Git; accepted diagnostics may use only fixed outcomes,
  bounded counts, and duration/status families. Visual-QA stderr is
  debug-only, synthetic, and removed with the temporary evidence directory.
- Cross-platform/backend correlation: matched Swift/Kotlin tests cover body,
  hydration, routine-notification, Today, and accessibility semantics; direct
  memory/PostgreSQL tests cover Safety terminal deletion.
- Remaining blind spots: physical devices, band/firmware, production
  credentials, real providers, participants, licensing, clinical evidence, and
  store review.
- Feedback transfer adds bounded queue and server lifecycle evidence for queued,
  uploading, retrying, rejected, cancelled, sent, and terminal-failure states.
  Events contain fixed categories, counts, status families, and timing only;
  report content, screenshots, notes, health values, identifiers, credentials,
  URLs, payloads, and arbitrary exception messages remain outside diagnostics.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Worktree isolation | Audit branch created at `2efd5e89` while calendar work remains in a separate dirty worktree | Concurrent review can proceed without overwriting active implementation | Merge compatibility or production readiness |
| Private reference inventory preflight | Private session export and reference-image/PDF sets plus the latest desktop, routine-notification, and calendar-guidance screenshots were reviewed in place and excluded from Git | Inputs can inform interaction hierarchy, notification usefulness, and adaptive-day product decisions without redistributing private or third-party material | Accuracy, rights, clinical review, background delivery, or physical behavior |
| Local source and round preflight | `CLAUDE.md`, operations contract, active handoff, and current release ledger reviewed | Audit is bounded by current repository rules | Any feature or external gate is complete |
| Hydration, managed documents, and Apple schema | Exact-current-tree `WhoopStore` executed 488 tests with zero failures; the Apple schema oracle executed seven tests and matched the Android oracle. | Schemas v55-v60, hydration projection/tombstone/no-echo, generation-ledger repair, encrypted-row retention, conflict preservation, strict restore validation, account-partitioned mutation intent, capability-versioned restore, and database-only plus settings-bearing legacy restore handling pass together. | Client encryption/key recovery, physical import-provider accuracy, or production transfer |
| Managed client package | Exact-current-tree `NoopRemoteSync` executed 127 tests with zero failures. The new incident-gate suite covers FIFO admission, cancelled waiter removal, and cancellation during ownership handoff. | Content-mode partitioning, server-readable allowlisting, local encrypted-row retention, account binding, conflict preservation, capability-version snapshot recovery, retry, coordinator behavior, and Apple incident serialization remain coherent. | Production encryption, public traffic, or real participant transfer |
| Shared health and guidance analytics | Exact-current-tree `StrandAnalytics` executed 1,479 tests with zero failures. | Body/BMI guards, hydration goals, sleep/recovery evidence gates, workout detection, adaptive guidance, planned-workout collapse, fallback-day handling, and formula contracts pass on the current source. | Clinical validity, individual physiology, or physical sensor accuracy |
| Complete Apple app suite | Exact-current-tree macOS `Strand` suite executed 1,913 tests with one expected external Xiaomi-fixture skip and zero failures after the UI-audit and feedback corrections. | Current Apple app, persistence, notification, calendar, privacy, accessibility, performance, Safety, hydration, feedback, Trends, Today feature mounts, and lifecycle contracts pass together. | iOS background delivery, physical BLE, haptics, notification presentation, signing, or store behavior |
| iPhone UI and navigation regression wall | The complete isolated iPhone 17 Pro UI suite executed 39 tests with one intentional private-pilot skip and zero failures. It covers repeated tab navigation, compact navigation, semantic green switches, Sleep Planner final-control and weekday endpoint clearance, strength body-map multi-selection, the complete Today metric catalog, Trends loading, Today scroll performance, feedback consent/progress, onboarding, Review Sample, calendar routing, pull-to-sync feedback, planner states, and update history. Today scroll averaged 5.411 seconds with 0.190 seconds average CPU time and peak physical memory of about 63.3 MiB. | The corrected simulator build can repeatedly scroll Today, load Trends with explicit state, submit only reviewed feedback, and expose real endpoint controls above either compact or accessibility-expanded persistent navigation without the reproduced freeze or overlap. | VoiceOver traversal, physical-device memory pressure, signed distribution, background collection, or background upload |
| Android exact-source matrix | Full and Demo unit suites passed. Both lint variants, APK assemblies, and Full/Demo instrumentation Kotlin compilation succeeded; Gradle completed 137 tasks successfully. | Room v46-v51, Health Connect BMI reprojection, exact-day hydration, account isolation, private notifications including the persistent connection service, generation-ledger behavior, capability-versioned restore, feedback archive/outbox/upload, Trends state, UI-audit presentation, incident serialization, and both product variants compile and pass their local contracts together. | Signed install, API 35 runtime behavior on this final source, OEM delivery timing, Health Connect provider behavior, or physical hardware |
| Durable analysis invalidation | Apple package/app tests and Android JVM/source-compilation gates cover all ten score-bearing tables, migration seeding and repair, blank-ID exclusion, snapshot-without-clear, crash/restart persistence, exact acknowledgement, partial failure, concurrent writes, outer UPSERT/REPLACE, forced passes, and source deletion. | Launch/resume and post-backfill work now use bounded durable generations rather than whole-history fingerprints, and current Swift/Kotlin/Room source compiles. | Participant-scale performance, Android device instrumentation execution, or physical BLE catch-up |
| Complete Apple simulator graph | Unsigned generic `NOOPiOS` simulator build succeeded on the exact current source after the disk-only failed attempt was discarded. | The current iPhone app, Watch app, widgets, App Intents metadata, and embedded graph compile, link, and validate. | Signing, store acceptance, physical-device behavior, or UI interaction quality |
| Deterministic visual matrices | The exact final iPhone matrix generated eleven current nonblank states, including normal, check-in, recovery-shift, planned-workout, collapsed planned-workout, dark/high-contrast, stop, and accessibility variants. The normal and accessibility collapsed-planned-workout captures were manually inspected for clipping and overlap. Stale macOS WindowServer surfaces were rejected as evidence. | Required simulator states preserve hierarchy, reachability, text visibility, and a stable navigation footprint on the current source. | VoiceOver focus order, fresh macOS visual proof, haptics, notification presentation, physical display behavior, or hardware |
| Android navigation accessibility | `PrimaryNavigationContractTest` passed on the exact source; review confirmed `Scaffold` applies its measured bottom-bar inset to the `NavHost`, while `GlassBottomBar` grows with wrapped text and applies system navigation-bar padding. | Android source retains a dynamic, non-overlapping navigation reservation rather than copying the iOS overlay implementation. | Runtime large-text behavior on a physical Android device or OEM font/rendering differences |
| Complete server suite | A fresh exact-tree run against isolated local PostgreSQL databases passed 433 tests with 106 external/configuration skips and one Starlette deprecation warning. The focused feedback/API slice passed 25 tests with nine external/configuration skips; eight OpenTofu feedback lifecycle tests and configuration validation passed. | The current server, standard-PostgreSQL migrations, memory/PostgreSQL parity, backup/deployment contracts, Safety lifecycle, managed-document readiness, feedback tenant/capability/lifecycle boundaries, and object cleanup pass together under available local dependencies. | Docker image execution, public feedback ingress, attestation, encrypted staging restore, real providers/carriers, or production runtime |
| Localization and repository policy | Strict i18n and feedback-localization generation, 230 Tools tests plus 34 subtests, the 1,246-file health-claims scan, required-CI, calibration parity across 12 metrics/three revisions/13 thresholds/16 guards, active and legacy terminology inventories with zero forbidden uses, release controls with its high-confidence credential scan, legal inventory for 230 runtime components and three container inputs, distribution provenance, private-data, all 54 operations records, both locked dependency audits, and diff gates pass locally before the final record refresh. | Current source and release-control wiring reject new unlocalized copy, unsupported claims, forbidden vendor mappings, high-confidence secrets, and unreviewed distribution inputs. | Professional translation, hosted exact-SHA checks, or clinical/legal approval |
| Review status | Pull request `#15` previously identified ten actionable lifecycle defects. Replacement exact-tree reviews then closed restore, schema-proof, BLE privacy, Safety cancellation, and backup defects. The private UI audit added four P1 and sixteen P2 findings; all twenty are implemented and covered locally. The feedback path received direct archive, outbox, screenshot, capability, principal, lifecycle, tenant, retention, and cleanup tests. Final independent read-only review found three record-consistency defects, now corrected, and no P0 code defect, high-confidence secret, or tracked private audit screenshot. | Corrective work remains tied to concrete source review and direct regression evidence, including explicit rejection of stale screenshot and stale-tree evidence. | Corrected hosted exact-SHA verdict, physical behavior, or external launch gates |
| Project agent handoff | Root `AGENTS.md` points to the checked-in skill; `quick_validate.py` reports `Skill is valid!`; `bash -n` passes; the repository-local context snapshot runs against this dirty worktree; project and user-level skill copies are byte-identical by recursive diff and per-file SHA-256; a read-only fresh-agent rehearsal recovered the branch, risks, invariants, verified/open split, and next command | A future agent entering the repository can discover the same stable engineering, medical-truth, privacy, parity, verification, and handoff contract and recover live context without the oversized chat | That any current feature, deployment, physical-device path, or external release gate is complete |
| Owner-supplied band SDK static assessment | Android protocol AAR and latest iOS static archive were hashed; docs, headers, demo manifests/plists, platform slices, background hooks, license files, and embedded endpoint strings were inspected without executing or importing the binaries | A phone integration path exists in the package; commands must be serialized; model-gated history/backfill, connection confirmation, password rotation, haptics, and other optional APIs are present; the iOS package cannot serve Mac/simulator | Exact NOOP band capability, printed-label mapping, triple-tap possession, runtime egress, redistribution authority, signed app behavior, background reliability, sensor accuracy, or production readiness |
| Separate SDK repository | Private `Dhanunjay-Divi/NoopBandSDK` created and pushed at `ee82cc0`; local validation passed 14 files with no CJK text, tracked supplier binary, or invalid JSON; repository contains no workflow | SDK ownership, language, binary, and release cadence are isolated from the app repository without spending hosted Actions | Supplier redistribution authority, adapter implementation, artifact publication, physical behavior, or production approval |

The exact-current-tree local wall and independent review above cover the
current implementation. The generated terminology snapshot and complete
fail-fast repository policy wall pass on this source. Fresh hosted required
exact-SHA checks on the replacement head and normal protected integration
remain required before this round can be closed.

## Physical device and deployment

- Install/update action: unsigned generic iOS Simulator build plus Android Full
  and Demo debug APK assembly; no signed install
- Generalized device and OS class: not run
- Data-preservation result: synthetic simulator data only; no participant or
  owner health data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device, wearable, terminated-process,
  notification-presentation, background-runtime, haptic, battery, and sensor
  scenarios

## Git and release state

- Changed paths: shared Apple/Android hydration, notification, wind-down,
  Today/accessibility, Recovery/Daily Signal/Trends/UI-audit presentation,
  feedback archive/outbox/review/upload, generated localization and tests;
  Apple queue ownership;
  Android Room v46-v51 and managed sleep/analysis/document evidence; WhoopStore
  schema v55-v60 and migrations; PostgreSQL migrations `033`-`040`; Safety
  repository lifecycle, band-origin admission, and tests; visual QA harness;
  GCP feedback source/tests; complete root README and owned visual assets;
  separate SDK decision records; durable skill and operations records.
- Commits: body/notification `9547c394`; calendar integration `4f8682a6`;
  wind-down privacy `83ec8598`; durable handoff `6b78df33`; current mobile
  reliability/accessibility `99a51b80`; Safety lifecycle `e35d1d37`; first
  consolidated correction `142eeec5`; latest pushed production-shell
  correction `66c2b0a9`; final exact-current implementation `156937fc`; this
  evidence entry in the record follow-up
- Branch and remote state: protected pull request `#15` previously evaluated
  pushed head `66c2b0a9`. Its exact-SHA run passed Android, server, Swift-package,
  repository-control, and macOS jobs but exposed the iOS Today scroll stall and
  pushed-destination endpoint defect. The replacement commit contains the
  fully verified local correction, this record, and refreshed generated policy
  evidence. Fresh hosted corrected-head review, every required exact-SHA check,
  and normal integration remain pending; the failed hosted head is not reused
  as proof.
- Repository visibility verified: `PUBLIC` before final protected integration;
  the owner-requested return to `PRIVATE` occurs only after the merge is
  verified so required checks are not silently disrupted mid-review
- Version/build impact: Apple local database schema `54` to `60`; Android Room
  schema `45` to `51`; PostgreSQL migrations through `040`; no marketing
  version change
- Release or distribution impact: none

## Concurrent ownership

- Current audit worktree owns all remaining source, generated artifacts,
  terminology/required-CI refresh, and this round's operations records.
- Delegated review is read-only and has no write ownership. Its initial source
  findings were checked against later corrections in the exact local tree. Its
  final pass found three record-consistency defects, now corrected, and no P0
  code defect, high-confidence secret, or tracked private audit screenshot.
- The calendar source is committed in `4f8682a6`. Its dedicated worktree is
  clean at `8cfe570e` and must not be edited as part of this remaining audit.
- The wind-down privacy source is committed in `83ec8598`. Its dedicated
  worktree is clean at `21946fd3`; further already-asleep suppression belongs
  in the audit worktree only after current notification ownership is reviewed.
- The Safety and hydration delegated worktrees have been reconciled into
  `e35d1d37` and `99a51b80`; they may be removed only after confirming each is
  clean. No concurrent worktree may be deleted while dirty.

## Decisions

- Build: optional adult BMI from confirmed inputs; source/date-aware imported
  whole-body composition; neutral user-selected target status; separately
  consented, private activity-suggestion notifications after eligible sync;
  metric-first desktop hierarchy; private routine prompts; evidence-gated
  Daily Plan use of a generic local workout window.
- Defer: claims about reliable background/terminated delivery until physical
  iOS/Android evidence; supplied exercise videos/animations until rights,
  instruction quality, captions, reduced-motion behavior, and exercise-safety
  review are documented; fixed notification timing until physical scheduling
  and fatigue evidence exists.
- Reject: band-inferred body fat or segmental composition; BMI interpretation
  for users below 20; pregnancy/eating-disorder/clinical target logic without a
  dedicated reviewed pathway; weight-gap-driven walking/exercise/calorie
  prompts; automatic saving of unvalidated workout inference; copied
  third-party branding/copy or an "optimal performance" promise.
- Decision-log entry: this round is the durable record until a dedicated
  product-decision registry is introduced.

## Open risks and honest limitations

- The private session export may contain stale, contradictory, duplicated, or
  unrelated work and must not override current source evidence.
- Reference visuals can demonstrate a useful interaction without proving the
  underlying detection, formula, safety, privacy, or background reliability.
- Apple and Android background execution is opportunistic. Simulator builds
  prove compilation, not that a force-quit or OEM-restricted app will run.
- BMI cannot assess body composition or individual health; imported body-fat
  and lean-mass values inherit the limitations of their source devices.
- The target-weight guard does not replace clinician review for pregnancy,
  eating disorders, medications, illness, or other clinical contexts.
- Physical devices are unavailable on this laptop. BLE collection, background
  wake, force-quit behavior, notification presentation, haptics, battery,
  firmware gestures, and sensor accuracy remain external evidence gates.
- The supplied vendor SDK does not identify the production band's exact
  project/function matrix and does not prove NOOP's printed-label mapping or
  challenge-bound at-least-three-tap possession target. Its default four-digit
  password is not cryptographic owner identity. The binaries remain outside Git
  until supplier distribution, dependency, privacy, egress, update, and
  security gates pass.
- PostgreSQL integration ran against isolated synthetic local databases and
  passed. Docker is unavailable on this machine, and real Safety provider,
  carrier, contact, and location delivery was not enabled.
- Managed health-document production transfer remains blocked because the
  storage policy requires client encryption and key recovery, neither of which
  is implemented. The fresh correction keeps encrypted personal documents
  local and limits the server-readable adapter to reviewed operational data;
  local outbox/restore tests do not close encryption, key-recovery,
  security-review, or physical-device gates.
- Feedback ingestion remains default-off for production. Signed physical
  background/cellular transfer, App Attest/Play Integrity, public-edge abuse
  controls, operator access, monitoring, legal retention, and production
  deployment must pass before public reservations are enabled.
- The display half of issue `#977` is fixed: stale historical Rest no longer
  appears as today's value. The analytics calculation remains an explicit
  expected failure when a live chargeable day has no staged sleep, so that
  state can still produce no Rest signal. It must remain missing rather than
  inventing a score until real live-device evidence supports a bounded
  fallback or sleep-staging correction.
- Public traffic, production health transfer, legal/terms approval, carrier
  registration, 24/7 operations, signing, store review, participant validation,
  and exercise-media redistribution remain external gates.

## Next round

1. Create one bounded replacement commit, push it once, and update pull
   request `#15`.
2. Require fresh corrected-head hosted review and every required exact-SHA
   check, then integrate through the normal protected merge path without
   bypassing a gate.
3. After verified integration, return the repository to private visibility and
   remove only round-owned databases, temporary evidence, daemons, and the
   audit worktree.
4. Run the checked-in physical-device handoff on representative iOS and Android
   phones plus supported band firmware; record failures and logs rather than
   treating simulator evidence as hardware evidence.
5. Complete legal, carrier, provider, signing, store, participant, licensing,
   and operational-readiness gates before any production launch claim.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
