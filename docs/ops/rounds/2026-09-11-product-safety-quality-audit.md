# Round: 2026-09-11 - Product, safety, and quality audit

## Status

- State: `supplier-independent implementation and complete local verification; protected PR #15 exact-head integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `2efd5e89999bd54b3fd6e316322b39d7e953ee8f`
- End implementation commits: `99a51b80`, `e35d1d37`, plus the corrective
  head recorded by pull request `#15`
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
- Closed the second hosted-review hydration path findings. Apple schema v56
  installs durable insert/update/delete tracking for existing hydration rows,
  validates remote hydration payloads, atomically refreshes the scalar
  projection after remote upsert or tombstone, and suppresses outbox echo.
  Android Today retains the last confirmed hydration total across a transient
  read failure but still clears a confirmed missing result.
- Added a shared one-notification budget for each completed wearable or
  external-health sync. Workout review, post-workout summary, adaptive-day
  guidance, and morning recap cannot burst from one late sync, and skipped
  lanes retain their durable frontier for later reconsideration.
- Closed the final queued-delivery ownership race found in hosted review.
  Clearing Apple workout suggestions now releases every queued reservation
  before discarding it, while the suspended active delivery retains its own
  defer-based cleanup. Android remains synchronous and already releases every
  reservation on failure.
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
  on Apple and Android. App-wide localization now contains 653 generated keys
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

## Data, privacy, and medical truth

- Schema or migration impact: Apple local database schema `54` to `55` adds
  `hydrationEntry`; schema `56` installs and backfills its managed-document
  tracking. Existing scalar hydration history migrates once into an editable
  row and the scalar projection remains transactionally aligned after local or
  remote mutation. Android Room schema `45` to `46` adds nullable
  `sleepSession.gravitySparse` and removes only legacy Health Connect-derived
  BMI rows; schema `47` resets only the WeightRecord sync cursor for a complete
  supported reprojection. PostgreSQL migration `033` removes precise locations
  joined to terminal Safety incidents.
- Existing-data retention impact: no source biometric measurement was
  uploaded or removed. The Android migration deletes unsupported derived BMI,
  not Health Connect weight or another source's BMI. Safety location now has
  stricter deletion at preview expiry, every incident terminal state, and
  upgrade cleanup for legacy terminal rows.
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
  for hydration and other personal documents, but the current native managed
  adapter still implements the earlier `server_readable` pilot envelope.
  Therefore this round proves local capture, outbox generation, restoration,
  and projection integrity only. Production health-document transfer remains
  disabled until client encryption, key recovery, security review, and
  physical-device validation are implemented and independently verified.
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

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Worktree isolation | Audit branch created at `2efd5e89` while calendar work remains in a separate dirty worktree | Concurrent review can proceed without overwriting active implementation | Merge compatibility or production readiness |
| Private reference inventory preflight | Private session export and reference-image/PDF sets were reviewed in place and excluded from Git | Inputs can inform the audit without redistributing private material | Accuracy, rights, clinical review, or physical behavior |
| Local source and round preflight | `CLAUDE.md`, operations contract, active handoff, and current release ledger reviewed | Audit is bounded by current repository rules | Any feature or external gate is complete |
| Hydration store and schema | Full `WhoopStore` suite passed 452 tests; all schema-oracle checks passed; Apple/Android oracles are byte-identical | Schema-v55 row migration, schema-v56 managed tracking/backfill, atomic local/remote row-to-scalar projection, tombstone handling, and no-echo contracts hold | Client encryption, physical import-provider accuracy, or production transfer |
| Managed client package | Full `NoopRemoteSync` suite passed 110 tests with zero failures | Existing managed client, storage, social, Safety, and adapter contracts remain coherent with the local hydration restoration changes | Production encryption, public traffic, or real participant data transfer |
| Focused current-delta suites | 43 focused Apple tests, 31 focused Android tests, and 13 focused Safety lifecycle tests passed; a separate 16-test Apple notification run covers the queued-budget correction | Changed hydration, notification, wind-down, accessibility, and Safety boundaries have direct regressions | Whole-app interaction or physical delivery |
| Complete Apple app suite | 1,779 tests passed with one external-fixture skip and zero failures | Apple app, persistence, notification, calendar, privacy, accessibility, and lifecycle contracts pass together | iOS background delivery or physical BLE behavior |
| Android full matrix | Full and Demo each passed 4,316 tests with seven evidence-dependent skips and zero failures; lint passed and both debug APKs assembled | Both Android variants compile and pass the current cross-platform contracts, including transient hydration retention and width-normalized workout titles | Signed install, OEM delivery timing, or physical-device behavior |
| Android managed API 35 shell | The production managed-device shell completed successfully; XML reports 55 cases, two credential-gated skips, and zero failures or errors | Room v45-to-v47 migration, selective WeightRecord cursor reset, database validation, and the remaining production instrumentation shell pass on the managed emulator | Physical Health Connect reprojection, signed install, or OEM behavior |
| Complete Apple simulator graph | Unsigned generic iOS Simulator build succeeded for app, widget, and Watch dependencies | Current Apple source compiles and links | Signing, store acceptance, or physical-device behavior |
| Deterministic visual matrix | 42 unique captures passed on iPhone 17 Pro Max and iPhone 17e; Today accessibility, Nutrition, keyboard, Safety, light/dark, and contrast states were inspected | Required screens are nonblank and show no incoherent clipping or overlap in these simulator states | VoiceOver focus, haptics, notification presentation, or hardware behavior |
| Complete server suite | 340 tests passed, 94 environment/provider cases skipped, and Ruff passed | Current in-memory and configured server contracts remain coherent, including Safety lifecycle | PostgreSQL integration where `NOOP_TEST_DATABASE_URL` is absent, provider delivery, or public runtime |
| Localization and repository policy | 653 app-wide keys generated for nine locales; terminology, required CI, calibration, release controls, trusted-main controls, legal provenance, private-data, health-claims, i18n, operations, schema, diff, 227 tool tests, and 49 i18n tests passed | Exact local source and release-control wiring pass the repository policy wall | Professional translation, hosted replacement-head checks, or clinical review |
| Hosted review | Pull request `#15` first identified six actionable lifecycle defects: legacy Safety location retention, finite wind-down exhaustion, legacy derived BMI, stale provider artifacts, sparse sleep suppression, and queued notification-budget leakage. A second review identified four more: the retained WeightRecord cursor after BMI cleanup, missing compatibility normalization for Android titles, transient hydration reads clearing confirmed Today state, and Apple hydration rows lacking managed triggers/restoration projection. All ten now have direct source and regression corrections locally. | The corrective scope is tied to concrete hosted findings rather than an unbounded rewrite | Fresh exact-head hosted verdict, physical behavior, or external launch gates |
| Project agent handoff | Root `AGENTS.md` points to the checked-in skill; `quick_validate.py` reports `Skill is valid!`; `bash -n` passes; the repository-local context snapshot runs against this dirty worktree; project and user-level skill copies are byte-identical; a read-only fresh-agent rehearsal recovered the branch, risks, invariants, verified/open split, and next command | A future agent entering the repository can discover the same stable engineering, medical-truth, privacy, parity, verification, and handoff contract and recover live context without the oversized chat | That any current feature, deployment, physical-device path, or external release gate is complete |

The app, package, server, simulator-build, visual, and policy totals above cover
commits `99a51b80` and `e35d1d37`, all ten pull-request review corrections, and
the current record/policy delta. Protected exact-head checks and a fresh
no-findings review remain required before integration.

## Physical device and deployment

- Install/update action: simulator-only unsigned build and visual matrix
- Generalized device and OS class: not run
- Data-preservation result: synthetic simulator data only; no participant or
  owner health data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device, wearable, terminated-process,
  notification-presentation, background-runtime, haptic, battery, and sensor
  scenarios

## Git and release state

- Changed paths: shared Apple/Android hydration, notification, wind-down,
  Today/accessibility, generated localization and tests; Apple queue ownership;
  Android Room v46/v47 and managed sleep evidence; WhoopStore schema v55/v56
  and migration; PostgreSQL Safety migration `033`; Safety repository lifecycle
  and tests; visual QA harness; durable skill and operations records.
- Commits: body/notification `9547c394`; calendar integration `4f8682a6`;
  wind-down privacy `83ec8598`; durable handoff `6b78df33`; current mobile
  reliability/accessibility `99a51b80`; Safety lifecycle `e35d1d37`
- Branch and remote state: protected pull request `#15`; two hosted review
  passes returned ten total actionable findings, all corrected and fully
  verified locally. The final corrective head requires its own exact-SHA checks,
  a fresh no-findings review, and normal integration; earlier green checks are
  not reused as proof.
- Repository visibility verified: inherited from current repository record
- Version/build impact: Apple local database schema `54` to `56`; Android Room
  schema `45` to `47`; no marketing version change
- Release or distribution impact: none

## Concurrent ownership

- Current audit worktree owns the project skill update, terminology/required-CI
  refresh, and this round's operations records.
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
  consented, private activity-suggestion notifications after eligible sync.
- Defer: claims about reliable background/terminated delivery until physical
  iOS/Android evidence; supplied exercise videos/animations until rights,
  instruction quality, captions, reduced-motion behavior, and exercise-safety
  review are documented.
- Reject: band-inferred body fat or segmental composition; BMI interpretation
  for users below 20; pregnancy/eating-disorder/clinical target logic without a
  dedicated reviewed pathway; weight-gap-driven walking/exercise/calorie
  prompts; automatic saving of unvalidated workout inference.
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
- PostgreSQL integration cases remain skipped unless
  `NOOP_TEST_DATABASE_URL` points to the isolated test database; real Safety
  provider, carrier, contact, and location delivery was not enabled.
- Managed health-document production transfer remains blocked because the
  storage policy requires client encryption while the native pilot adapter
  still uses server-readable envelopes. Local outbox/restore tests do not close
  encryption, key-recovery, security-review, or physical-device gates.
- Public traffic, production health transfer, legal/terms approval, carrier
  registration, 24/7 operations, signing, store review, participant validation,
  and exercise-media redistribution remain external gates.

## Next round

1. Run the checked-in physical-device handoff on representative iOS and Android
   phones plus supported band firmware; record failures and logs rather than
   treating simulator evidence as hardware evidence.
2. Complete legal, carrier, provider, signing, store, participant, licensing,
   and operational-readiness gates before any production launch claim.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
