# Round: 2026-09-11 - Product, safety, and quality audit

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `2efd5e89999bd54b3fd6e316322b39d7e953ee8f`
- End implementation commit: pending
- Record commit or PR: pending

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
- Completed independent read-only tracks for private-reference extraction,
  product/health/Safety review, and cross-platform UX/accessibility review.
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
- Integrated the reviewed calendar-aware daily-guidance source. Calendar access
  remains a separate default-off local permission; event content is discarded
  during the query and only a generic future workout window can contribute to
  Today's Plan or one private, cooldown-ranked Workouts prompt. Sleep and
  readiness evidence must independently support any lighter-day suggestion.
- Closed the merged Xcode target-membership defect, refreshed both localization
  ratchets to 645 app-wide entries across nine locales, and reviewed the
  terminology inventory after merge-only line movement. The active
  customer/core terminology allowlist did not change.
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

- Schema or migration impact: no health-history migration. Body-input
  confirmation, activity-alert consent, adaptive-day consent, and calendar
  access are local preferences with fail-closed defaults; the calendar branch's
  bounded local action-state migration is covered by cross-platform tests.
- Existing-data retention impact: none. No local biometric history was removed,
  rewritten, or uploaded.
- Source/provenance or formula impact: BMI remains the conventional
  weight/height screening calculation, but now requires confirmed adult inputs.
  Body-composition values remain imported measurements with source/date
  context. No band-derived body-composition formula was added.
- Permissions/network disclosure impact: Android requests notification
  permission only after the user explicitly enables activity suggestions.
  Calendar data is read only after separate user opt-in and platform
  authorization, event content is not persisted in guidance state, and no
  endpoint, cloud traffic, or new background entitlement was added.
- Health/medical claim impact and limitations: BMI is optional adult screening
  context, not diagnosis or body composition. Target weight is not a NOOP
  recommendation. NOOP does not prescribe weight-loss pace, calories, or
  compensatory activity. Safety remains accepted-contact paging, not emergency
  dispatch or automatic medical inference.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  bounded notification lifecycle ledger records posted, suppressed, cancelled,
  and unknown outcomes for activity suggestions. Existing diagnostics expose
  only fixed categories/counts, not candidate times, heart rate, weight, BMI,
  or notification text.
- Why existing evidence is sufficient, or why new evidence is required:
  delivery uses the established notification path and ledger; body-profile
  availability is deterministic UI policy covered by focused tests and does
  not need a new high-frequency event.
- Existing evidence reused: `AppDiagnosticsRecorder`, server request
  observability, current operations records, bounded notification and
  background-work ledgers.
- New bounded events or operation spans: none; existing lifecycle outcomes are
  reused to avoid duplicate telemetry and health-value collection.
- Redaction, retention, and high-frequency controls: private review inputs must
  never be copied into Git; accepted diagnostics may use only fixed outcomes,
  bounded counts, and duration/status families.
- Cross-platform/backend correlation: body availability is covered by matched
  Swift/Kotlin policy tests; activity alerts remain entirely on-device and do
  not require backend correlation.
- Remaining blind spots: physical devices, band/firmware, production
  credentials, real providers, participants, licensing, clinical evidence, and
  store review.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Worktree isolation | Audit branch created at `2efd5e89` while calendar work remains in a separate dirty worktree | Concurrent review can proceed without overwriting active implementation | Merge compatibility or production readiness |
| Private reference inventory preflight | Private session export and reference-image/PDF sets were reviewed in place and excluded from Git | Inputs can inform the audit without redistributing private material | Accuracy, rights, clinical review, or physical behavior |
| Local source and round preflight | `CLAUDE.md`, operations contract, active handoff, and current release ledger reviewed | Audit is bounded by current repository rules | Any feature or external gate is complete |
| Shared body-profile policy tests | Swift `BodyProfilePolicyTests` passed 3 cases; Android full and demo policy/profile/import suites passed | Adult/confirmed-input gating and target suppression agree across platforms | Imported-device accuracy or clinical suitability |
| Apple profile regression tests | `ProfileExternalWeightTests` passed 11 cases | Existing external-weight behavior and new confirmation rules coexist | Physical HealthKit delivery |
| Android activity-alert tests | Full-variant `AutoWorkoutCandidateNotificationPolicyTest` and `AutoWorkoutSuggestionPolicyTest` passed | Posting now requires detection, separate interruption opt-in, OS authorization, and a new candidate token | OEM delivery timing or terminated-process execution |
| Shared analytics suite | 1,464 tests passed with seven evidence-dependent skips and zero failures | Body policy, daily planning, workout-title classification, scoring, and related shared analytics remain coherent after integration | Sensor accuracy or physical collection |
| Complete Apple app suite | 1,755 tests passed with one external-fixture skip and zero failures | Apple body, notification, calendar, privacy, lifecycle, and app contracts pass together | iOS background delivery or physical BLE behavior |
| Android full matrix | Full and Demo each passed 4,296 tests with seven skips and zero failures; both debug APKs assembled | Both Android variants compile and pass the merged body, notification, calendar, lifecycle, localization, and storage contracts | Signed install, OEM delivery timing, or physical-device behavior |
| Complete Apple simulator graph | Unsigned `NOOPiOS` generic iOS Simulator build succeeded after regenerating target membership, including app, widget, and watch dependencies | The merged Apple source graph compiles and links | Signing, App Store acceptance, or physical-device behavior |
| Calendar-aware guidance contracts | Focused Apple/Android suites plus the complete matrices passed; stale consent, moved/removed plans, cooldown ownership, privacy, and evidence attribution are covered | Guidance is local, opt-in, bounded, and fails closed when supporting evidence or permission disappears | Calendar-provider behavior on a real phone or OS notification timing |
| Localization, terminology, claims, and CI gates | 645 app-wide keys and 68 daily-plan keys generated for nine locales; localization audit, terminology ratchet, health-claims scan of 1,202 files, required-CI configuration, and diff checks pass | Merged copy is generated consistently, active legacy terminology did not expand, prohibited claims were not detected, and local release-gate wiring is valid | Professional translation, hosted exact-SHA checks, or clinical review |
| Project agent handoff | Root `AGENTS.md` points to the checked-in skill; `quick_validate.py` reports `Skill is valid!`; `bash -n` passes; the repository-local context snapshot runs against this dirty worktree; project and user-level skill copies are byte-identical; a read-only fresh-agent rehearsal recovered the branch, risks, invariants, verified/open split, and next command | A future agent entering the repository can discover the same stable engineering, medical-truth, privacy, parity, verification, and handoff contract and recover live context without the oversized chat | That any current feature, deployment, physical-device path, or external release gate is complete |

The complete app and policy totals above cover the last clean verification wall
before the current uncommitted notification, hydration, Safety, Today, and
accessibility delta. Focused checks for parts of that delta are recorded in the
working notes, but a new complete exact-tree wall is still required.

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no product data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device, wearable, terminated-process,
  notification-presentation, background-runtime, haptic, battery, and sensor
  scenarios

## Git and release state

- Changed paths: root `AGENTS.md`; project-local
  `.agents/skills/noop-ops` operating contract;
  shared body-profile policy/tests; Apple and Android profile,
  onboarding, Health/body-composition, notification consent/policy,
  calendar-aware daily guidance, generated localization, broad regression
  tests, privacy documentation, physical-device runbook, and this operations
  record.
- Commits: body/notification slice `9547c394`; calendar merge `4f8682a6`;
  wind-down privacy `83ec8598`; current handoff and later audit slices pending
- Branch and remote state: isolated local branch; no push or hosted CI
- Repository visibility verified: inherited from current repository record
- Version/build impact: none yet
- Release or distribution impact: none

## Concurrent ownership

- Current audit worktree owns `AGENTS.md`, `.agents/skills/noop-ops`, the
  notification-budget/adaptive-delivery delta, the uncommitted hydration and
  Today/accessibility review, generated localization affected by those screens,
  and this round's operations records.
- The calendar source is committed in `4f8682a6`. Its dedicated worktree is
  clean at `8cfe570e` and must not be edited as part of this remaining audit.
- The wind-down privacy source is committed in `83ec8598`. Its dedicated
  worktree is clean at `21946fd3`; further already-asleep suppression belongs
  in the audit worktree only after current notification ownership is reviewed.
- `/private/tmp/noop-safety-location-20260911` is the authoritative unfinished
  Safety-location lifecycle workspace. The audit worktree contains only a
  partial copy of that delta and must not stage or discard those server files
  until it is reconciled with the dedicated worktree, including
  `server/tests/test_postgres_integration.py`.
- `/private/tmp/noop-hydration-missing-data-20260911` contains no implementation
  delta, only an untracked draft round. Hydration code currently exists only in
  the audit worktree and requires local review before staging.
- Prior delegated UI and hydration rehearsals produced no scoped commit.
  Therefore every uncommitted Today, accessibility, hydration, and localization
  path remains owned by the current audit reviewer rather than by an assumed
  external worker.

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
- Physical devices are unavailable on this laptop; a separate reproducible
  handoff is required for another agent.
- Broad scope must be converted into small, independently reviewable rounds
  rather than one unsafe cross-product patch.

## Next round

1. Commit the verified calendar integration locally without triggering hosted
   Actions.
2. Address the remaining highest-severity accessibility and notification
   findings in bounded cross-platform slices.
3. Run the remaining simulator UI and local policy checks that add independent
   evidence, then prepare the physical-device handoff using the checked-in
   `noop-ops` skill and current operations record.
4. Clean temporary resources and consolidate the final push so hosted Actions
   run once for the finished source rather than once per audit slice.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
