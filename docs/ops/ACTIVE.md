# Active NOOP handoff

Last updated: **2026-09-12**

## Repository

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Canonical protected branch: `main`
- Active audit worktree: `/private/tmp/noop-product-audit-20260911`
- Active audit branch: `codex/product-safety-quality-audit-20260911`
- Remote branches: `origin/main`,
  `origin/codex/product-safety-quality-audit-20260911`
- GitHub repository relationship: standalone, with no parent reported at the
  last authenticated check
- Current source-rights record:
  [`../provenance/OWNER-RIGHTS-DECLARATION.md`](../provenance/OWNER-RIGHTS-DECLARATION.md)
- Current agent handoff:
  [`../handoff/archive/AGENT-HANDOFF-20260827.md`](../handoff/archive/AGENT-HANDOFF-20260827.md)
- Current release blockers:
  [`../handoff/RELEASE-BLOCKERS.md`](../handoff/RELEASE-BLOCKERS.md)

## Active work

### Current audited state

The supplier-independent product, safety, and quality audit remains active on
`codex/product-safety-quality-audit-20260911` and is tracked by protected pull
request `#15`. The remote branch remains at committed correction head
`5ddd812c`; the final correction set is intentionally local until one
consolidated push.

The exact local wall now passes on the current implementation tree:
`WhoopStore` 485 tests; `NoopRemoteSync` 123; `StrandAnalytics` 1,466 with
seven evidence-dependent skips; Apple app 1,850 with one external-fixture
skip; Android Full and Demo 4,455 each with seven evidence-dependent skips,
plus both lint variants, APK assemblies, and instrumentation-source
compilation; and the PostgreSQL-backed server 457 with one provider/environment
skip. The unsigned generic iOS Simulator graph builds. Ruff, both locked Python
dependency audits, migration-manifest integrity, backup shell syntax,
standalone Compose configuration, 227 Tools tests, 49 localization tests,
health claims, strict i18n, required CI, calibration parity, terminology,
release controls, legal inventory, provenance, private-data, operations-record,
JSON, shell, and diff gates also pass locally.

The current source partitions managed-document mutation intent by the account
active at edit time on Apple schema v60 and Android Room v51. Legacy unowned
intent is quarantined instead of attributed to a later account; signed-out
edits create no upload intent; client-encrypted hydration, journal,
preferences, and other personal documents remain local because client
encryption and key recovery are not implemented. PostgreSQL migrations 034-037
expand the managed-document kind registry and store aggregate contract-v2
readiness without changing any document, head, or change cursor. The stricter
database content-mode constraint remains deliberately absent until versioned
clients can encrypt, restore, and backfill every supported personal document.
Migration 038 adds accepted-contact band-origin SOS admission and coalescing
without enabling automatic medical or fall inference.

The replacement exact-tree review also closed two restore defects: server
change-feed document lookup is now qualified by document kind, and both mobile
clients persist change-feed capability version `1`. A legacy filtered cursor
must complete a supported-kind snapshot before incremental changes advance;
failed or stale completion cannot mark a newer cursor current.

The final review then found that Android's persistent connection notification
could expose Recovery and Effort while locked. That service now uses the shared
neutral public version, and the privacy contract includes the BLE package.
Room schema generation retains a valid proof across unrelated incremental KSP
work, rejects an unproven export, and regenerates a deliberately tampered
schema to the canonical hash. A real 50-to-51 migration preserves an existing
cursor and interrupted snapshot state.

The source also includes editable hydration rows on both platforms, exact-day
Today routing, dependency-driven Health Connect BMI reprojection, bounded
analysis generation ledgers instead of launch/resume whole-history
fingerprinting, private notification construction, sleep-aware wind-down,
routine-notification budgeting, accessibility corrections, and terminal Safety
location deletion. The root README has been completely replaced with a
product-first, local-first, launch-honest guide whose local links resolve.
Maximum Dynamic Type evidence also corrected the iPhone floating-navigation
reservation: the measured rail now owns one real safe-area inset and an opaque
accessibility reading boundary. Eight exact-current Daily Plan captures pass;
Android's measured `Scaffold` bottom inset and focused navigation contract pass
without requiring an overlay copy of the iOS fix.

A delegated review initially returned migration and ownership findings from an
earlier dirty-tree snapshot. Exact-current source inspection shows migrations
034-037 are additive/read-only and Android ownership invalidation derives
bounded persisted input times. Replacement reviews drove the change-feed,
capability-version, current-schema, Room-proof, and BLE lock-screen
corrections; the final exact-current-tree verdict is clean.

The owner-supplied HBand/Veepoo package was assessed without importing its
private binaries. The neutral SDK boundary is a separate private
`Dhanunjay-Divi/NoopBandSDK` repository at `ee82cc0`; its 14 tracked files pass
English-language, binary, and JSON gates, it contains no supplier payload or
hosted workflow, and its working tree is clean. The original multilingual
supplier drop remains immutable outside Git. NOOP's intentional product
translations, including Chinese locales, remain in the app.

Fresh hosted required exact-SHA checks and protected integration remain
pending. Round-owned Apple and dependency-audit scratch environments have
been removed. Physical phones, exact band/firmware,
BLE/background/notification/haptic/battery/sensor behavior, real
providers/carriers, client encryption/key recovery, public traffic, production
health transfer, legal/terms, 24/7 operations, signing, stores, participants,
and media licensing remain external gates. Rest display freshness is fixed,
but issue `#977` still intentionally leaves a chargeable day without staged
sleep as a missing Rest signal rather than inventing a score.

The detailed paragraphs below are chronological progress notes. Where they
describe an earlier dirty-tree total or a pending source correction, the
current audited state above and the active round record supersede them.

The product, safety, and quality audit is active on
`codex/product-safety-quality-audit-20260911`. Its verified body slice makes
BMI adult-only and dependent on confirmed age, height, and weight; prevents
seeded profile values from becoming personal Health Connect BMI history;
preserves source/date context for imported whole-body composition; and keeps
target weight neutral and non-prescriptive. Android now matches Apple's
separate default-off activity-suggestion interruption consent while retaining
quiet in-app workout review. Supplied exercise media remains excluded until
rights and instructional-safety evidence exists. The reviewed calendar-aware
daily-guidance source is now integrated locally with separate consent, local
event classification, content-discarding queries, sleep/readiness evidence
gates, private prompt copy, stale-plan cleanup, and cooldown ownership.
The last clean verification wall before the current uncommitted
notification/hydration/Safety/UI delta passed 1,464 shared analytics tests,
1,755 Apple app tests, 4,296 tests in each Android variant, both APK assemblies,
the complete unsigned iOS simulator graph, 645-key app-wide localization,
terminology, claims, required-CI configuration, and diff checks. Those totals
must not be presented as coverage of the present dirty tree. Broader
accessibility, notification, simulator UI, physical-device, cleanup, and
protected integration work remains. Root `AGENTS.md` now routes every new Codex
repository session to a project-scoped `noop-ops` skill carrying the stable
product, health-safety, privacy, parity, observability, verification, and
handoff contracts; live implementation state remains in this record and the
active round rather than being frozen into the skill. Details are in
[Product, safety, and quality audit](rounds/2026-09-11-product-safety-quality-audit.md).

The final local calendar-aware source has completed its clean verification
wall. Shared analytics passed 1,461 tests with seven expected skips; the
complete macOS suite passed 1,750 tests with one expected external-data skip;
both Android Full and Demo variants passed 4,234 tests with seven expected
skips apiece alongside both APK assemblies, lint variants, and instrumentation
source compilation; and the complete unsigned iPhone, widget, and Watch graph
built. Seven deterministic iPhone visual states passed and the planned-workout
fixture was inspected without clipping or overlap. Two iOS UI-test attempts
compiled but failed before worker creation because this Mac's Xcode debugger
version store is unavailable; that is recorded as test-infrastructure evidence,
not an app result. Exact physical scenarios are now documented in
`docs/handoff/CALENDAR-AWARE-PHYSICAL-DEVICE-RUNBOOK.md`. The source remains
local and unpushed to avoid spending GitHub Actions without explicit owner
approval; protected review, hosted checks, merge, and physical-device evidence
remain open.

Calendar-aware daily guidance is implemented and review-corrected locally on
protected pull request `#14` from
`codex/calendar-aware-daily-guidance-20260910`. Apple and Android expose a
separate default-off Calendar option under Adaptive Day Guidance, classify
same-day future workout titles locally, discard event content inside the
query, and keep only a generic in-memory time window. Today's Plan can combine
that window with supported personal sleep and readiness evidence, while one
private cooldown-ranked prompt opens Workouts without placing event details,
exact times, or health values on the lock screen. Opt-out and permission
changes invalidate reads already in flight, and action-center evidence names
only signals that actually supported the prompt. Calendar edits update the
visible plan, the adjustment expires at its start time, and spectator,
shopping, ticket, or equipment-service titles fail closed. Exact-head review
also found and the replacement head corrects stale Android
Calendar cache use after permission revocation, missing Apple reevaluation after
calendar edits, contextual actions opening Sleep instead of Workouts, and
Android adaptive-day `PendingIntent` mutation before global cooldown approval.
Replacement-head review then corrected Android provider-change reevaluation,
Apple cancellation after EventKit return, and declined invitations on both
providers. Final review then added the two-hour boundary reevaluation,
workout-start action expiry, exact supporting-evidence preservation, persisted
active-device resolution, and immediate Android reevaluation after every
Calendar enablement or permission transition. The latest protected review found
that Apple could still preload calendar-derived copy before consent changed and
that either platform could retain a stale delivered prompt or Workouts action
after a workout moved or disappeared. Apple now stores only generic boundary
metadata, uses a process-local task while alive, and gives its existing
background-refresh lane a one-shot earliest-wake hint; every path reruns current
consent and evidence before creating a prompt. Android retains WorkManager
reevaluation. Both platforms use the exact start in the fingerprint and
reconcile stale delivery state, cooldowns, actions, and notifications on every
disabled, superseded, moved, removed, or expired plan. The newest exact-head
review also closed consent changes across Apple notification awaits, Android
master-opt-out cleanup, owner-aware cross-topic cooldown restoration,
workout-start notification expiry, and ambiguous work uses of `run` and `spin`.
A final local review covered the Android process-death window between posting
and private-state persistence, so master opt-out still retracts the shared
notification and planned-workout cooldown owner. The latest exact-head review
also found that same-day pain/unwell check-ins and sleep-target edits could
leave the prior plan visible until another lifecycle event, Android could keep
global planned-workout prompt ownership after consent disappeared immediately
after a successful post, and Apple's immediate notification diagnostic used
the generic vital category. Both platforms now coalesce immediate
input-triggered reevaluation, Android reconciles that owner on post-success
consent loss, and Apple records both immediate and durable delivery under
`adaptive_day`. The complete replacement local wall passes: 1,461 analytics
tests with seven skips, 1,726 Apple app tests with one expected skip, the
complete unsigned iOS app/widget/watch graph, and 4,211 Android tests with seven
skips plus APK assembly, production compile, lint, and instrumentation-source
compilation. Repository policy totals are refreshed in the round record. The
first hosted Apple attempt exposed
only the app-wide localization ratchet still
expecting 631 rather than the exact new total of 636; that contract is corrected
and passes locally. Fresh protected review/checks and normal merge remain, along
with physical iOS/Android permission, provider, background-delivery,
accessibility, and battery evidence.
The latest review correction also closes five final fail-closed gaps: Android
rechecks the master toggle and current Terms at delivery boundaries, both
platforms reject stale in-flight workout plans, the planners require a
genuinely user-set target while personal sleep history is thin, and the local
classifier recognizes conservative workout titles across every shipped
language. Focused Swift analytics, Apple app integration, and Android
planner/Calendar/notifier suites pass on the replacement source. A final
fresh-eyes review also keeps the Apple same-kind delivery gate active while a
newer planned-workout candidate waits behind an in-flight delivery, preventing
a third candidate from bypassing queue coalescing. The queue-specific regression
suite and the exact current iOS source graph pass. The first hosted Android
replacement run then exposed one stale source-contract assertion that still
required the pre-explicit-target condition. The contract now pins both the
explicit-target read and the intended first-write-or-value-change condition;
the complete Android unit suite passes 4,217 tests with seven expected skips.
Exact-head review then found three final delivery-lifetime races. Apple now
prevents a rejected stale candidate from clearing a newer exact fingerprint and
stops a superseded boundary task immediately after notification authorization
returns. Android computes notification expiry from the remaining lifetime at
the actual post instant instead of restarting the original window. A subsequent
exact-head review found that new daily sleep/readiness state could still queue
reevaluation without first invalidating a suspended candidate. Both Apple
repository health-input publishers now invalidate that candidate synchronously
before scheduling replacement evaluation. The focused regressions pass, the
next exact-head review found that natural workout expiry removed accepted
cooldown history and that quiet hours or a global cooldown at the two-hour
boundary discarded the only notification opportunity. Both platforms now
preserve accepted history only for a persisted workout whose exact start has
passed, fully retract future/invalidated workouts, and schedule one bounded
retry at the next eligible instant before workout start. A final no-adjustment
pass cannot erase the preserved history; malformed fingerprints fail closed,
and stale Android expiry work cannot remove a newer exact prompt. The focused
correction suites pass 42 Apple tests plus the Android notifier suite. The
complete Apple rerun passes 1,734 tests with one intentional external-data skip,
and the final Android wall passes 4,220 tests with seven skips plus production
compile, lint, instrumentation-source compile, and APK assembly. The complete
unsigned iPhone/widget/watch graph also builds. Final terminology regeneration,
the 227-test Tools suite, release controls, required CI, all 51 operations
records, i18n, health claims, calibration parity, legal provenance,
terminology, and private-data gates pass on the exact source. Commit, fresh
exact-head review, protected checks, and normal merge remain required.
The newest exact-head review found one final classifier gap: Chinese calendar
titles normally have no word separators, so natural phrases such as
`早上跑步` did not match the reviewed workout vocabulary. Swift and Kotlin now
apply substring matching only to Han-script terms, after applying the same
unsegmented work-context denylist. Natural Simplified and Traditional Chinese
phrases classify, while workout-plus-meeting or seminar phrases still fail
closed. All 1,461 analytics tests and the complete 4,220-test Android
unit/compile/lint wall pass on the replacement source. Commit, fresh exact-head
review, protected checks, and normal merge remain required.
The final replacement review then found three prompt-lifetime defects. Planned
workout identity now consists only of the planning day and exact start, so a
change from sleep-only to sleep-plus-readiness evidence updates explanation
without consuming a second notification or erasing cooldown history; legacy
four-field identities migrate in place. Apple and Android evaluate quiet hours,
staleness, retry timing, and cooldowns from the actual delivery boundary rather
than the earlier analytics timestamp. A successfully armed future workout also
suppresses weaker routine or sleep guidance until that higher-priority
reevaluation runs. The exact replacement source passes all 1,461 shared
analytics tests with seven skips, all 1,745 Apple app tests with one expected
external-data skip, all 4,227 Android tests with seven skips plus APK assembly,
production compile, lint, and instrumentation-source compilation, and the
complete unsigned iPhone/widget/watch graph. Fresh exact-head review, protected
checks, and normal merge remain required.
The newest exact-head review then found two final state-lifetime gaps. Android
now invalidates the active adaptive-day generation as soon as a new health-data
emission arrives and uses latest-only collection, so an older suspended
evaluation cannot publish after fresher sleep or readiness data exists. Apple
now discovers and migrates any equivalent legacy Workouts action ID, processing
state, and bounded dismissed/completed tombstones even when delivery state is
already canonical, preserving the action and the user's prior decision under
the three-field identity. The focused closeout passes 40 Apple tests and the
two Android regression suites. The latest exact-head review then found that
Apple repository publishers could queue calendar-backed contextual work before
the accepted launch/runtime gate and that Android could canonicalize delivery
state without migrating the active Workouts action or its bounded history.
Apple now fails closed at every scheduling and evaluation entry point until
operational work starts; Android migrates the action, processing state, and
dismissed/completed identities together before stale reconciliation. The
focused closeout passes 22 Apple tests and both Android regression suites. The
complete replacement wall passes 1,748
Apple app tests with one expected external-data skip, 4,228 Android tests with
seven skips plus APK assembly, full debug compile, lint, and instrumentation-
source compilation, and the complete unsigned iPhone/widget/watch graph. The
signed Android release probe remains correctly blocked before compilation
without private signing credentials. Source and local evidence are complete;
fresh exact-head review, protected checks, and normal merge remain required.
The latest exact-head review found two remaining priority-boundary defects.
Android timezone travel guidance now invalidates and retracts stale planned-
workout notification, action, and cooldown ownership before it enters the
shared delivery policy. Apple Calendar disable, denial, and unavailable paths
now synchronously remove delivered workout artifacts before queued
reevaluation, so suspension cannot preserve opted-out guidance. The focused
closeout passes 23 Apple Calendar tests and the Android notifier suite; the
complete replacement wall passes 1,749 Apple app tests with one expected skip
and 4,231 Android tests with seven skips plus APK assembly, full debug compile,
lint, and instrumentation-source compilation. The final Apple graph, policy
wall, replacement commit, exact-head review, protected checks, and normal merge
remain required.
The stale-head hosted production-shell run also exposed an independent Android
report-liveness defect: slow OS exit/ANR capture could occupy the live
diagnostics queue until the bounded snapshot silently omitted the current
session attachment. Historical capture now runs separately, only completed
history is eligible, and an allowlisted bounded fallback explicitly reports a
degraded snapshot without arbitrary errors or private data. The exact API 35
app-report case passes 1/1, and the final Android unit wall passes 4,233 tests
with seven skips plus APK assembly, full debug compile, lint, and
instrumentation-source compilation. Replacement hosted checks must confirm the
complete managed-device production shell.
Fresh replacement-head review found one additional launch-boundary defect:
Android's manifest-delivered timezone entry point could observe and post travel
guidance while the current Terms receipt was absent. It now checks
`ManagedRuntimeGate` before timezone state, settings, scheduling, diagnostics,
or delivery. The focused notifier suite and the complete 4,233-test Android
wall pass with seven expected skips plus APK assembly, full debug compile,
lint, and instrumentation-source compilation. A replacement commit, exact-head
review, protected checks, and normal merge remain required.
Fresh review also found that the generic title `ride` was treated as an
unconditional workout, so transport plans such as `Train ride` could create
fitness guidance. Swift and Kotlin now treat `ride` as ambiguous: a bare or
fitness-context ride remains eligible, while train, bus, airport, taxi,
rideshare, transit, driving, and commuting contexts fail closed. The focused
classifier suites pass on both platforms, all 1,461 analytics tests pass with
seven expected skips, all 1,749 Apple app tests pass with one expected
external-data skip, the complete unsigned iPhone/widget/watch graph builds, and
the final Android wall passes 4,233 tests with seven skips plus APK assembly,
full debug compile, lint, and instrumentation-source compilation. The
replacement record and policy snapshot, commit, fresh exact-head review,
protected checks, and normal merge remain required.
The next exact-head review found one remaining background-entry gap:
`HealthConnectSyncWorker` and other non-UI callers could reach the shared
Android evaluator after a newly required Terms version made the runtime
unauthorized. `AdaptiveDayEvaluator` now checks `ManagedRuntimeGate` before it
creates a generation, observes timezone state, reads Room or Calendar, records
guidance diagnostics, or posts a prompt, so every current and future caller
shares the same fail-closed boundary. The focused contract passes in both
variants, and the complete Android wall passes 4,234 tests with seven expected
skips plus both APK assemblies, full debug compile, lint, and instrumentation-
source compilation. The replacement record and policy snapshot, commit, fresh
exact-head review, protected checks, and normal merge remain required.
Details are in
[Calendar-aware daily guidance](rounds/2026-09-10-calendar-aware-daily-guidance.md).

The mobile and desktop Today visual-parity round is merged on protected
`main` as `2efd5e89` through pull request `#13`. Apple and Android
phones now share the desktop reference's compact masthead, dominant Daily
Signal hierarchy, score geometry, integrated Fitness Age row, and immediate
workout-coach placement while preserving native navigation and accessibility.
Paired synthetic phone, large-text, and tablet captures were reviewed. The
follow-up Apple suite passed 77 tests; Android passed 31 focused contracts plus
both debug builds, lint, and instrumentation-source compilation; and the
complete iOS simulator app graph builds. Android large-text weather and normal
plus Review Sample navigation retain full accessibility names without
ellipsized visual fragments. Exact-head review later found three additional
Android accessibility defects. Commit `133cb5d8` now measures localized
bottom-bar labels before showing them, preserves a 48 x 48 dp weather hit
target, and lets the large-text weather surface expand for signed Fahrenheit
values. Both variants, lint, instrumentation-source compilation, and the three
focused suites pass; API 35 runtime evidence confirms a 48 dp target and
unclipped `-148 F` presentation. No formula, provenance, storage, sync,
collection, account, or network behavior changed. A final exact-head review
found that the compact Apple weather capsule exposed only a 32-point hit
region. Commit `02594534` keeps the capsule compact while wrapping it in the
shared 48-point control target; all 12 focused Apple contracts and the complete
unsigned iOS simulator graph pass. Review of that exact head then found that a
source-less localized Daily Signal row still relied on a width guess and that
Review Sample could announce a visible tab twice. Commit `4ff38930` now measures
the complete localized identity, state, optional source, and fixed chrome before
retaining one row, and adds an explicit tab accessibility name only in icon-only
mode. Both Android variants, lint, instrumentation-source compilation, the three
focused suites, terminology, and required-CI unit contracts pass. All six
review conversations were resolved and every required hosted context passed
before the normal protected merge. Physical-device smoothness and
hardware-dependent evidence remain. Details are in
[Mobile and desktop Today visual parity](rounds/2026-09-10-mobile-desktop-visual-parity.md).

The managed Safety implementation from protected pull request `#10` is merged
on `main` as `035dec3c` after all 35 hosted checks passed. Apple and Android require a
working app-alert path before accepting a Safety contact; incident creation
counts only accepted contacts represented by deterministically locked active
push installations. Apple suppresses foreground managed Safety presentation
until launch authorization is current and completes background catch-up exactly
once within a 20-second deadline. The delivery lease now covers the provider's
bounded maximum plus receipt margin, and Android releases a foreground service
that existed only for managed location after all independent reasons end. The
complete local server suite passed 424 tests with only the explicit real-provider
case skipped; Android passed 4,143 tests plus lint, build, and instrumentation
compilation; Apple passed 1,669 tests with one expected skip and the complete
unsigned iOS simulator graph builds; 227 Tools tests and every local policy gate
pass. Physical providers/devices and external launch gates remain. No public
traffic, real paging, or real health data was used during verification. Evidence is recorded in
[Managed Safety late-review closeout](rounds/2026-09-09-managed-safety-late-review-closeout.md).

The latest managed Safety lock and retention closeout is implemented and
completely locally verified on protected pull request `#10`. Contact request
creation/removal and profile/incident expiry now follow one deterministic lock
hierarchy; broad erasure cancellation cannot reactivate an account while
another broad erasure is live; and migration `032` bounds terminal
contact-request churn with an account-scoped rolling ledger that survives
profile recreation. The complete server collection contains 423 cases: 422
passed and only the explicit real-provider Twilio staging case was skipped.
Apple now implements Firebase Messaging's exact registration-token delegate
selector; its focused contract and complete iOS simulator app graph pass.
All local release, terminology, privacy, claims, calibration, localization,
legal, and operations controls pass. Replacement exact-head review, hosted
checks, normal protected merge, physical providers/devices, and external
launch gates remain. No public traffic, real paging, or real health data was
used. Evidence is recorded in
[Managed Safety lock and retention closeout](rounds/2026-09-09-managed-safety-lock-retention-closeout.md).

The latest exact-head managed Safety erasure closeout is implemented and
completely locally verified on protected pull request `#10`. Both Cloud Run
services wait for current and previous push-token secret IAM grants; account
erasure atomically retires active Safety state; contact removal locks profiles,
incidents, then contacts; incident creation locks its owner and all contacts in
one global order; push completion locks installation before delivery; and
erasure replay locks job before account. The complete clean server suite now
covers 416 cases with one intentional real-provider skip. Replacement policy
gates, exact-head review, protected checks, and normal merge remain. No public
traffic or real paging was enabled. Evidence is recorded in
[Managed Safety erasure closeout](rounds/2026-09-09-managed-safety-erasure-closeout.md).

The latest managed Safety final-gate closeout is implemented and locally
verified on protected pull request `#10`. Apple and Android now reject every
managed push wake, token-refresh, notification, and worker entry point until
launch access and the exact current Terms version are valid; normal
post-acceptance bootstrap retries registration. A profile can receive at most
40 pending contact requests while retaining 10 outgoing pending requests, with
count and insert serialized under the contact profile/account lock and
idempotent replay preserved. Due urgent Safety push retries now run before
slower lifecycle cleanup. The latest review follow-up also adds migration `031`
to cap invitation create/revoke churn at 50 per account per rolling 24 hours
without allowing profile recreation or retained-capability reuse to reset the
limit. Deleting a responding profile now reopens a surviving incident when no
responder remains, and both apps retire a confirmed contact-request replay
before any fallible refresh.

The fresh PostgreSQL server suite passed 393 tests with 19 expected skips,
Android passed 4,142 tests plus lint/build/instrumentation-source compilation,
the Apple Safety suite passed 33 tests, the full Strand suite passed 1,666 tests
with one expected skip, and the complete iOS app/widget/watch simulator graph
builds for arm64 and x86_64. The complete local release-policy matrix is green.
The fully verified replacement head still requires commit, push, clean
exact-head review, protected checks, and normal merge. No public traffic or
real participant paging was enabled. Evidence is recorded in
[Managed Safety final gate closeout](rounds/2026-09-09-managed-safety-final-gate-closeout.md).

The reported physical-phone lag is not evidence against the large-data fix yet:
yesterday's protected `main` did not contain pull request `#12`. Its
deterministic 4,207,350-row fixture produced a 440.6 MB database and showed
ordinary indexed reads remain bounded while one-million-row active writes
measurably increased concurrent read latency. Apple Liquid Today restores an
exact revision-bound query snapshot across tab remounts, scopes it to the active
device, defers repeated same-day reads during bulk backfill, and discards
pre-backfill state before the completion reload. Historical snapshots expire
after five minutes so an incomplete failed read cannot be retained forever.
Android shares one
Rest-history read, keys it to the active device and metric revision, retries
failed reads instead of banking an empty result, and pauses decorative liquid
clocks during drag/fling. Across both platforms, Health avoids sensor-rate root
updates, Sleep parallelizes independent history reads and batches motion
lookups, with Android preserving canonical computed motion after a re-pair.
Stress moves deterministic analysis off the UI executor, and Workouts defers
historical recovery scans until their lazy section mounts; both platforms then
own the long load at screen lifetime so scrolling the placeholder away cannot
cancel it. Device switches now invalidate or supersede every affected cache and
task. No local history was deleted and no retention or formula contract
changed. Protected integration and exact-head check history are tracked by pull
request `#12`. The complete replacement local gates pass: 4,176 Android tests
plus build/lint/instrumentation compilation, 53 API 35 production-shell tests,
1,700 macOS tests, the unsigned iOS graph, and 35 iOS production-shell tests. A
fresh lifecycle review also
fixed three Android realtime-HR surfaces that could skip their lease release
after Stop, and strength video/GIF cleanup that could target a replacement
resource. The final Apple lifetime review also preserves an off-screen
Workouts recovery request across retained-tab suspension and moves Health's
explicit Live HR lease outside the lazy row, so row recycling cannot stop a
stream the user requested. The latest exact-head review additionally prevents
hidden Apple Workouts restarts, protects Android recovery cleanup through an
A-B-A request cycle, keeps failed Android pinned-card reads retryable, expires
Classic Today's fallback-empty cache after two minutes, and links Apple
auto-workout CPU workers to cancellation before the step query and classifier.
Focused Android tests and 19 Apple retained-screen contracts pass after those
corrections. The final iOS shell scroll pass averaged 5.185 seconds of
automation time and 0.172 seconds of app CPU across five repetitions. All 227
repository tooling tests and local policy gates pass after regenerating the
fail-closed terminology snapshot and its reviewed digest. The app report now
records only bounded realtime-lease categories and a zero/one/multiple
ownership bucket. The first hosted release-control run
exposed only a stale fail-closed terminology inventory; its reviewed
regeneration has no forbidden mapping or active allowlist expansion. A
reviewed shake-to-report ZIP from the affected phone on the integrated build
plus representative large-database, active-collection,
low-storage, thermal, memory-pressure, and in-place-upgrade physical-device
runs remain required. Evidence is recorded in
[Large-data scroll lag](rounds/2026-09-09-large-data-scroll-lag.md).

The latest managed Safety race closeout is implemented and locally verified on
protected pull request `#10`. Invitation and contact deletes are idempotent,
invalid provider receipts are bound to the exact claimed token hash, Apple and
Android serialize push registration with disconnect revocation, and all nine
supported locales tell an invitation redeemer to accept the request. The
locally available server suite passed 388 tests with 19 expected skips, Android
passed 4,140 tests plus lint/build/instrumentation compilation, 31 Apple Safety
tests passed, the clean iOS graph builds, and the complete repository policy
matrix passes. Replacement protected checks, a clean review of the exact
replacement head, and normal merge remain. Physical APNs/FCM,
terminated/background execution, location, haptic, battery, legal, monitoring,
failover, and staffed-operations evidence remains open. No public traffic or
real participant paging was enabled. Evidence is recorded in
[Managed Safety race closeout](rounds/2026-09-09-managed-safety-race-closeout.md).

The managed Safety review-hardening round is implemented and locally verified
on protected pull request `#10`. Migration `030` preserves account-scoped page
quotas and consumed request IDs across social-profile recreation; invitation
redemption follows profile/account-before-invite locking; and push-token
encryption now has a v1-compatible dual-reader rollout phase plus distinct
retryable-key and terminal-corruption outcomes. The complete two-database
server suite collected 406 tests: 405 passed and only real-Twilio staging
remained explicitly skipped. OpenTofu, dependency, shell, privacy, terminology,
claims, calibration, operations, and release-control gates pass. Replacement
protected checks, a clean exact-head review, and normal merge remain. No public
traffic or real participant paging was enabled. Evidence is recorded in
[Managed Safety review hardening](rounds/2026-09-09-managed-safety-review-hardening.md).

The trusted release-control activation round is complete. Pull request `#8`
passed the preceding protected rule and exact-head trust check, merged normally
as `d8cee4f6`, and then passed all ten exact-SHA contexts on protected `main`.
Live protection requires those ten GitHub-Actions-owned contexts, enforces
administrators, conversation resolution, and linear history, and rejects force
pushes and deletion. All four tag rulesets are active and immutable GitHub
Releases are enabled. No tag, artifact, draft, or release was published.
Evidence is recorded in
[Trusted release-control activation](rounds/2026-09-08-trusted-release-control-activation.md).

The trusted check URL compatibility round is complete. The reporter and
exact-SHA verifier now accept GitHub's canonical check-run URL only when it is
bound to the exact repository and authenticated response check ID. Protected
main run `34194149601` passed validation and publication on exact commit
`ffae30d5`; SHA, application, workflow-run, attempt, scope, and conclusion
checks remain enforced. Evidence is recorded in
[Trusted check URL compatibility](rounds/2026-09-08-trusted-check-url-compatibility.md).

The managed app Safety paging round has completed its supplier-independent
source, simulator, server, migration, and private synthetic deployment work on
`codex/managed-app-safety-paging-20260908`; protected-main review and merge are
pending. Accepted NOOP accounts are the primary manual Safety contact path,
opaque APNs/FCM wake payloads contain only a fixed event kind, opaque incident
reference, and expiry, while authenticated app entry fetches every displayable
detail. One latest location replaces the prior fix for the bounded active page.
Apple and Android reconcile the location session across
foreground/background runtime changes, and Android shares one platform GPS
stream even if the later provider fallback is also active. A scanned digest,
migration `027`, lifecycle execution, and a three-account private smoke pass
with no public invoker, provider push target, real user, or real health data.
Evidence is recorded in
[Managed app Safety paging](rounds/2026-09-08-managed-app-safety-paging.md).
Signed physical terminated/background push, location permission and battery
behavior, legal/security review, monitoring, failover, and staffed operations
remain launch gates. SMS/voice is not on the app-paging critical path.

The exact-head Safety review follow-up is implemented and locally verified on
the same protected branch. Apple and Android now refuse to discard an account
when both server and provider push invalidation fail, expired notification taps
route to retained authenticated history while background delivery remains
expiry-gated, APNs alerts use translated catalog keys, and social-profile
deletion immediately clears cascaded Safety state on both phones. The full
Apple, Android, and fresh-PostgreSQL server suites, dependency audits, and
repository policy gates pass locally. The first replacement-head hosted
release-control run exposed only a stale fail-closed terminology inventory;
the reviewed regeneration contains no forbidden mapping or active allowlist
change. The following iOS run then exposed four redundant cold package-graph
resolutions in the launch-gate isolation preflight; one all-target,
name-only scan now preserves the same fail-closed policy and passes locally.
Pull request `#10` still requires a green hosted rerun, a clean exact-head
review, and normal protected merge. Physical APNs/FCM, terminated/background
execution, location, haptic, carrier, legal, monitoring, failover, and
staffed-operations evidence remains open. Evidence is recorded in
[Managed Safety exact-head review](rounds/2026-09-09-managed-safety-exact-head-review.md).

A final exact-head Safety review round is implemented and locally verified
after the prior replacement head passed all required hosted checks. Contact
acceptance now follows the same profile-before-request lock order as blocking;
incident acknowledgement is recomputed whenever responders withdraw or are
revoked; Apple persists only a bounded opaque location-session reference and
uses significant-location monitoring for system-managed relaunch; and both
apps map every wire status to localized app-owned copy. The next exact-head
review found three additional push defects. Apple now labels the Firebase
Messaging callback value as an FCM registration token, rechecks notification
authorization before each registration, and retires unauthorized
installations. The server always addresses that value through FCM HTTP v1
`message.token`, keeps legacy iOS `fid`-labeled rows rolling-compatible through
migration `029`, and invalidates and reacquires a cached OAuth token once after
`401`. The complete fresh PostgreSQL suite passed 390 tests with only the
explicit real-Twilio staging test skipped, all 110 shared managed-client tests
passed, the Apple Safety suite passed 30 tests, Ruff passed, and the complete
iOS simulator app graph builds. Protected replacement-head review, hosted
checks, and normal merge remain.
No public traffic or real participant paging is enabled. Evidence is recorded
in
[Managed Safety final review](rounds/2026-09-09-managed-safety-final-review.md).

The production-readiness execution round is complete for supplier-independent
source and repository work. Current source adds
provenance-gated official-reference comparison and chronological personal
presentation calibration on Apple and Android, atomic cross-platform
score-window publication, fail-closed import manifests, generic metric validity
guards, Apple retry-on-persistence-failure semantics, a deterministic
10/30/90/365-day history and exact-restore harness, neutral compatibility
labels, a machine-readable terminology ratchet, and a disclosed deterministic
Review Sample Mode in the shipping Apple and Android source. The current ledger
has 396 stable actions: 68 evidenced complete and 328 pending, split into 31
owner, 230 engineering, 33 joint, and 34 external actions. Full local Android,
server, package, macOS, localization, claims, legal, private-data, OpenTofu,
and private-runtime checks pass; the final Apple simulator suite also passes.
Review Sample passes focused Apple standard/compact/exit-to-Terms simulator
journeys, Android API 35 instrumentation, source-isolation contracts, and
an iOS Release-simulator graph plus a one-use locally signed Android Release
build. Android also removes WorkManager's pre-application initializer and the
API 35 journey proves it remains uninitialized until Terms. Those are not
production signing evidence. Exact signed-archive/store-console review evidence
remains open. Pull request `#6` passed the full protected Apple, Android,
server, package, policy, and calibration matrix and merged normally; follow-up
pull requests `#7` and `#8` completed exact-main trust reporting and the tenth
protected context. The
retained 365-day synthetic profile is about 444 MB with a 1.33 GB temporary
backup/restore peak, so phone memory, thermal, background, collection, and
low-storage budgets remain physical release gates. Evidence is recorded
in
[Production readiness execution](rounds/2026-09-07-production-readiness-execution.md).

The status and resource audit is complete. Its starting first-release ledger
had 396 stable actions: 44 evidenced complete and 352 pending, split into 33
owner, 252 engineering, 33 joint, and 34 external actions. Known local relay, proxy,
preview, temporary-database, simulator, and Gradle runtimes remain stopped.
Sixteen inactive temporary PostgreSQL, proxy-probe, and OpenGym paths were
removed, and approximately 245 MB of generated OpenTofu plans/provider and tool
caches were moved to Trash. Live GCP inspection confirms that the private
synthetic staging stack remains provisioned: three Cloud Run services, two
jobs, one `db-f1-micro` Cloud SQL instance, one enabled five-minute lifecycle
schedule, three buckets, and a 381 MB container repository. The services have
no public invoker. Cloud SQL and the schedule remain billable and were retained
for unfinished NOOP+, ownership, restore, isolation, and deployment work.
Evidence is recorded in
[Status and resource audit](rounds/2026-09-07-status-and-resource-audit.md).

The launch owner-decision round is complete. Source review confirms that
Firebase Identity Platform handles managed account and phone-OTP identity;
Twilio is used only for optional Safety contact SMS/voice paging, DTMF
acknowledgement, and provider callbacks. The current shell has no Twilio CLI,
standard profile, or Twilio-named environment configuration, and the configured
private GCP project has no Twilio- or paging-named secret binding. A browser
login therefore does not yet constitute deployable paging configuration. The
owner has now placed manual, user-confirmed app SOS paging with latest-location-
only sharing in the first-release target. Existing server, Android, and Apple
focused contracts pass, but real provider traffic remains unavailable while
India TRAI DLT, carrier, legal, physical-phone, monitoring, failover, and
operations gates remain open. Evidence is recorded in
[Launch owner decisions](rounds/2026-09-07-launch-owner-decisions.md).

Post-release local cleanup is complete. Four local HTTP relays, three Cloud SQL
proxies, two OpenGym previews, the NOOP Gradle daemon, one Android emulator,
three iOS simulators, and a 313 MB synthetic PostgreSQL test cluster were
stopped; the test cluster was removed. All nine scoped ports are closed.
Simulator definitions and the Android AVD were retained without erasure, the
unrelated PostgreSQL service on port 5432 remains healthy, and retained
IAM-only GCP staging was not changed. No application source, build, deploy, or
release state changed. Evidence is recorded in
[Post-release resource cleanup](rounds/2026-09-07-post-release-resource-cleanup.md).

The first public production release now has one ordered execution plan:
[`../FIRST_PRODUCTION_RELEASE_PLAN.md`](../FIRST_PRODUCTION_RELEASE_PLAN.md).
Its editable action ledger is
[`../FIRST_PRODUCTION_RELEASE_CHECKLIST.md`](../FIRST_PRODUCTION_RELEASE_CHECKLIST.md),
with 396 stable actions: 68 evidenced complete and 328 pending. New owner
requests can be inserted without renumbering the plan.
It covers the first-party NOOP Band input dossier, firmware and native SDK
boundaries, safe terminology/data migration, mobile parity, storage and
performance, metric evidence, optional NOOP+ productionization, security,
certification, manufacturing, signing, stores, physical release-candidate
validation, and launch operations. The plan does not claim readiness. There is
currently no NOOP firmware or first-party protocol in the repository, and
protected-main commit `d8cee4f6` has green exact-SHA Apple, Android, server,
Swift-package/study, localization, health-claims, runtime-license, operations,
release-control, and trusted-release-control evidence. Strict branch
protection, active tag rulesets, and immutable releases are enabled; external
release gates remain open. The frozen terminology inventory classifies 17,369
legacy-name occurrences across 1,509 path/category groups; active customer/core
removal must use a reviewed allowlist and additive migration rather than
destructive replacement. Evidence is recorded
in
[First production release plan](rounds/2026-09-05-first-production-release-plan.md).

The completed checklist-execution round adds fail-closed source release controls,
a deterministic CycloneDX SBOM generator, and commit/tree-bound privacy-safe
evidence manifests. Dependency locks, full-SHA Actions, OCI digests, immutable
migrations, runtime inventory, tracked private-artifact names, and
high-confidence token formats are checked before release mutation. Focused
Apple, Android, and server evidence also closes the existing Ask-only workout,
reviewed app-report, disabled automatic-emergency, and anonymous public-policy
URL actions. Exact-main `Release Controls` run `34084340375` passes on
`b5caec52`; its retained 216-component SBOM manifest independently verifies
after download. Protected `main`, reviewed environments, credential rotation,
and every external release gate remain open. Evidence is recorded in
[Production checklist execution](rounds/2026-09-07-production-checklist-execution.md).

The hosted release-gate closeout is complete for code-verifiable source gates.
The server failure on ownership readiness was not a runtime privilege defect:
the PostgreSQL-overlay database was cloned from TimescaleDB's modified
`template1` and inherited extension-wide `PUBLIC` privileges that the
restricted ownership principal correctly rejects. The workflow now clones the
plain-PostgreSQL lane from pristine `template0` and fails early if a non-core
extension appears. Exact-main server run `34078811154`, Android run
`34079190997`, Apple run `34080116658`, Swift/study run `34078979831`, and the
localization, claims, legal-inventory, and operations runs pass without
weakening readiness. Evidence is recorded in
[Hosted release gates](rounds/2026-09-06-hosted-release-gates.md).

The owner has fixed the public market sequence as India first and the USA
second. The first-party band target now has a narrow ownership-account
exception: the user matches the printed band number, receives an identify
vibration, confirms possession from the worn band through a firmware-authenticated
at-least-three-tap event, accepts the binding disclosure, creates or signs in
with verified email/password and optional phone, and completes one atomic
single-owner claim. After activation, collection, metrics, export, and local
control stay independent of NOOP+, payment, subscription, and continuous
network. General v1 self-service resale release is not planned, but return,
RMA, recovery, deletion, verified dispute, and future eligible-upgrade exits
must pass India/USA legal and support review. The NOOP/NOOP+ choice appears
before Home; NOOP+ has an accessible gold identity and no working payment until
billing is approved. V1 exposes no user-facing unpair or transfer; an ordinary
claim remains bound for the band's life, and a consumer release appears only
through a future eligible successor-band upgrade. Operator-only return, RMA,
legal, deletion, recovery, and security exits remain required.

Terms are targeted as immutable versioned remote documents in NOOP-controlled
storage. The app verifies and renders them through an ephemeral
no-persistent-cache path and stores no full local terms document; the server
retains exact acceptance metadata and historical versions. The owner intends a
voluntary return period but has not selected 14 versus 30 days or its start
event. Condition grading, lawful disclosed refund deductions, appeals, wipe,
unlink, quarantine, and India/USA approval remain open.

The supplier-independent ownership foundation is now implemented default-off
across PostgreSQL/FastAPI, Apple, Android, and guarded GCP IaC. It includes
verified email/password identity mechanics, optional phone linking, immutable
remote-terms verification, Keychain/Keystore-backed installation credentials,
atomic single-owner claim and replacement-installation authorization,
installation revocation, resumable onboarding, and the pre-Home NOOP/NOOP+
choice. The production possession provider intentionally returns unavailable,
the runtime has no public invoker, and released mobile configuration remains
disabled. Supplier protocol, printed-label mapping, cryptographic possession,
owner-key provisioning, approved terms/returns, physical validation, signing,
and public deployment remain open. Evidence is recorded in
[Ownership account foundation](rounds/2026-09-05-ownership-account-foundation.md).

The private native NOOP+ simulator pilot is complete. One fictional Firebase
identity remains for repeat operator testing with only the exact
`noop_managed_pilot` admission attribute; it is not an application or Google
Cloud administrator. iOS and Android each completed the private enrollment,
consent, synthetic sync, and idempotent repeat-sync path through loopback-only
operator access while Cloud Run remained IAM-only. Production-shaped response
decoding, iOS Firebase phone-auth callbacks, bounded provider failure
categories, final app builds, connected instrumentation, private-runtime
verification, cleanup, and an OpenTofu zero-drift plan pass. Temporary App
Check assertions and local relay/proxy processes are absent. Physical
attestation, carrier delivery, background execution, BLE, battery, haptic, and
public-ingress evidence remain open. Evidence is recorded in
[Native managed staging pilot](rounds/2026-09-05-native-managed-staging-pilot.md).

Managed Friends is implemented for optional NOOP+ accounts on Apple,
Android, FastAPI, and PostgreSQL. It provides random rotatable exact-match IDs,
profile and expiring invitation links, explicit mutual requests, directional
per-friend sharing of only Charge, Effort, Rest, sleep duration, HRV, and RHR,
non-competitive badges, and receiver-controlled bounded pokes. Both clients
request generic local notification and an eligible worn-band haptic only after
foreground/background catch-up. There is no public directory, contact upload,
ranking, automatic sharing, production HTTPS universal/app link, or APNs/FCM
immediate delivery. Migration `025` and the corrected lifecycle/processor
runtime are deployed to IAM-only synthetic staging. The 269-test PostgreSQL
server suite, 96 `NoopRemoteSync` tests, Android unit/compile/lint gate, fresh
89-target iOS graph, and a complete two-account private smoke pass. Physical
notification/haptic behavior remains unverified. Evidence is recorded in
[Managed Friends identity, sharing, badges, and pokes](rounds/2026-09-05-managed-friends-identity-pokes.md).

The current observability round makes bounded diagnostic evidence part of the
definition of done. Apple and Android app reports now capture lifecycle,
responsiveness, storage, navigation, database/analysis work, managed and
self-hosted sync, fixed-category band connection failures, and begin/end
history-sync spans. Reports omit band transcripts, sensor values, health
timestamps, health databases, credentials, persistent identifiers, and
arbitrary exception messages; user notes and screenshots remain explicit,
reviewed attachments. Managed clients retain the server-generated request ID
with a static route group, while API, processor, lifecycle, retention, and
Safety paths emit payload-free structured events. The server suite,
`NoopRemoteSync`'s 89 tests, 1,614 macOS tests, 4,038 Android tests plus
lint/build gates, and the complete iOS simulator graph pass. No physical
device, cloud deployment, or live log-volume/retention validation occurred.
Evidence and remaining gates are recorded in
[Privacy-safe observability contract](rounds/2026-09-05-observability-contract.md).

The v9.2.1 client-discovery round makes NOOP+ an always-visible first item in
More on iPhone and Android, adds a dedicated Data row and destination, and
renders an explicit unavailable state instead of hiding the feature when the
managed runtime is disconnected. Core metrics, coaching, workouts, journal,
automations, local backup, and exports remain account-free. The same release
adds a one-current-version welcome, one-time first-install edge treatment, and
permanent More -> Updates history. Apple and Android focused tests, complete
debug builds, visual captures, version parity, localization, health-claims,
legal, private-data, and whitespace gates pass. Released mobile managed
configuration remains disabled and no enrollment or real health-data upload is
claimed. Evidence is
recorded in
[NOOP+ discovery and release welcome](rounds/2026-09-05-noop-plus-discovery-release-welcome.md).

The newest transport round separates live biometric health from generic BLE
traffic on Apple and Android. Battery, metadata, and command packets can no
longer hide a stopped HR stream; each client first rewrites live notification
subscriptions and then reconnects if accepted HR remains absent. Fresh explicit
off-wrist evidence suppresses reconnect churn for at most 15 minutes, so a
missed wrist-on event cannot disable recovery indefinitely. Empty 5/MG history
support no longer disables recovery, and the 5/MG live-HR-only path now runs the
watchdog. Apple diagnostics also decode the persisted current family correctly.
The 15 focused Apple checks, the 1,600-test Apple app suite, 4,018 Android
tests, 39 Android production-shell instrumentation tests, Android
lint/build/launch, and the clean iOS Release simulator graph pass. The hosted
managed-device dependency-verification gap is pinned with the independently
verified JUnit module checksum. A physical phone and worn band were unavailable,
so continuous locked-background collection and the band's reported empty
history remain open. Evidence and the physical procedure are recorded in
[Biometric collection liveness](rounds/2026-09-04-biometric-collection-liveness.md).

The optional NOOP+ managed-storage source is implemented across iOS, Android,
FastAPI/PostgreSQL, and guarded GCP IaC. It adds phone OTP, App Check,
per-installation credentials, explicit versioned consent, immutable compressed
chunk upload, processor validation, snapshot plus incremental restore, quotas,
device revocation, erasure, and optional seven-day raw plus 30-day essential
detail retention after exact server validation.
Core NOOP remains account-free; metrics, workouts, coaching, journal,
automations, and local export are not plan entitlements. The final local
checkpoint passed the complete server suite against PostgreSQL 14, Android
Demo/Full unit and lint matrices, the managed-device matrix, and the 89-target
iOS simulator graph including Watch/widgets. The full macOS Strand test action
also exited successfully, and StrandAnalytics passed 1,451 tests with seven
intentional skips and no failures. Ruff, dependency, localization, claims,
private-data, legal-inventory, OpenTofu, and repository-tool gates also pass.
Apple and Android provide a snapshot-bound, manifest-backed complete
managed-history ZIP export that verifies object digests, byte/object totals,
and final archive structure. Evidence is recorded in
[NOOP+ managed storage](rounds/2026-09-03-noop-plus-managed-storage.md).
The current immutable runtime digest is
`sha256:c55ec7eba9a7f66028ee1f67be3c567273bb4981652228b22f288e540852598a`.
Its on-demand scan reported zero findings at every severity. Migration and
lifecycle jobs complete, the private runtime smoke passes upload, processing,
restore, isolation, erasure, retention, and managed social paths, and the
post-deploy OpenTofu plan reports zero drift.

The complete-history export uses the restore snapshot/list/download APIs and
therefore includes history retained only in managed storage. It is deliberately
separate from the server `/exports` control plane, which accepts and verifies a
client-produced encrypted archive. Live large-account interruption/expiry
evidence, resumable continuation, and a documented importer remain
public-launch gates.

The Mumbai foundation remains synthetic-only with no connected released mobile
client and no real health data. Firebase Identity Platform, enforced App Check,
Cloud SQL, managed API, processor, lifecycle scheduler, KMS, Pub/Sub, and
storage are deployed. The managed API remains IAM-only with no public invoker.
The database is migrated through `025`; the corrected lifecycle executions
succeed and the stack is at zero drift. One fictional phone test configuration
is retained for operator testing, while temporary smoke identities and App
Check debug tokens are removed.

The final native closeout rebuilt both app graphs. The fresh
89-target iOS build installed and launched on an iOS 26.5 simulator, the
floating-shell contract passes 14/14, and a deterministic Today-bottom render
confirms content no longer reads through the glass controls. Android's forced
Full compile/unit/lint run executed 59/59 tasks, and that APK installed and
launched on an API 35 emulator. These are simulator and emulator checks only;
they add no BLE, background, attestation, notification, or haptic evidence.

The customer-day and scale contract is now explicit in
[`../PLATFORM_ARCHITECTURE.md`](../PLATFORM_ARCHITECTURE.md): immediate guidance
stays local, ordinary wellness prompts converge on one evidence-gated
cross-domain arbiter, outcome learning cannot weaken hard gates, and backend
growth uses bounded regional cells rather than one global database.

The latest round improves stress and daily-guidance notification reliability.
Android now evaluates qualified stress evidence from fresh live R-R and
committed motion updates, while retaining conservative sensor, wear, session,
quiet-hour, replay, and cooldown gates. Android gains the same default-off
morning Sleep and evening Journal guidance offered on Apple; both platforms
use private copy, trusted routes, and completion-aware evening suppression.
Local verification completed with 1,563 macOS tests, 28 iOS production-shell
tests, the Android unit and managed-emulator matrices, and the localization and
policy gates passing. Physical-device BLE, background, haptic, battery, and
operating-system delivery evidence remains open. The implementation and
evidence are recorded in
[Stress and daily guidance notification reliability](rounds/2026-08-31-stress-daily-guidance-notifications.md).

Round 24 completed the local performance, health-profile, notification, and
testing release. Android startup work moves Room and WorkManager off the first
frame, lifecycle-bounds retained collectors, and caps liquid rendering; the
same-emulator eight-launch median improved from approximately 1.465s to 1.064s.
Apple HealthKit paths now fail closed in unsigned profile-less builds. BMI,
optional user-selected target weight, aggregate vital-range status, and a
privacy-safe opt-in post-sync workout summary are implemented with
cross-platform settings schema v4. The implementation and evidence are recorded
in [Performance, health profile, and testing release](rounds/2026-08-27-performance-health-profile-release.md).

The
[NOOP Health App Store record and release preflight round](rounds/2026-08-25-noop-health-app-store-record.md)
has created the durable `NOOP Health` iOS record (`6804921246`) in `Prepare for
Submission` on exact private mainline. App Store release control is manual.
The ignored one-way launch verifier is generated locally and valid, and the
fail-closed boundary now covers the iPhone shell, iOS widgets, Live Activities,
Dynamic Island, Watch app, and Watch complications without copying verifier
material or build settings into extensions. A locked build-230 iPhone also
replaces build-229 Watch caches with a legacy-decodable neutral snapshot during
a staggered upgrade. The full embedded unsigned Release graph passes as
`9.2.0 (230)` with the existing bundle/App Group identity, 51/51 StrandDesign
tests pass, and the name-only build-setting isolation gate passes. Signed
archive, upload, physical validation, and the recorded release gates remain
open.

The final local matrix passes across the app, nine Swift packages, Android Full
and Demo flavors, StudyHarness, server, localization, privacy, legal, and
policy checks. Direct `main` publication, hosted CI, and the community testing
build are release-execution evidence for the commit containing the round
record. External signing, store, infrastructure, carrier, physical-device,
participant, and native-speaker gates remain separate.

## Decisions that remain binding

- NOOP remains local-first. App exploration, imports, metrics, records, and
  exports remain account-free; first-party band activation has the narrow
  ownership-account exception in D-046.
- Missing physiology is not zero and is never guessed.
- Wellness metrics are not medical outputs.
- Automatic medical, Rhythm, anomaly, and unvalidated fall paging remains
  disabled.
- Physical-device behavior cannot be claimed from simulator or unit evidence.
- A shared protocol or service UUID does not establish future-model support.
- BMI and target weight remain neutral, non-diagnostic user tools.
- Post-workout alerts remain generic, local, opt-in, and post-sync.
- Existing app identity and local data must be preserved during in-place
  upgrades.
- NOOP's PolyForm license and independent dependency notices remain intact.
- Daily guidance and automatic stress interruptions remain explicit opt-ins,
  private, evidence-gated, and honest about best-effort OS delivery.
- Core scoring and post-activation band use remain fully local and
  subscription-independent; NOOP+ managed sync requires separate explicit
  enrollment and must never silently upload existing history.
- Band ownership identity, NOOP+ consent, and NOOP+ payment are separate
  boundaries. A plan downgrade or payment failure cannot deactivate a band.
- V1 has no user-facing unpair or transfer. Remote terms, operator-only
  return/RMA release, and any condition-based refund deduction require exact
  versioning, disclosure, legal approval, and auditable operations.
- NOOP+ can restrict managed storage, restore, and multi-device history only;
  core product capability is not a storage-tier entitlement.
- Optional local storage reduction keeps seven days of high-rate raw data and
  30 days of essential time series, and prunes only an exact
  server-validated clean window.
- Ordinary customer-day prompts must converge on one explainable local arbiter;
  safety and fresh workout caution remain separate lanes.
- No real health data enters the GCP staging project until identity, processor,
  isolation, restore, privacy/legal, and physical-device gates pass.
- Every material change must review observability. Mobile evidence remains
  bounded, local, and user-shared; backend events remain payload-free. Neither
  may contain health values, user text, credentials, dynamic URLs, or
  persistent user/device/job identifiers.
- Managed Friends remains exact-match and accepted-only. Its six-field sharing
  is directional, badges are non-competitive, and pokes are receiver-controlled
  and best effort.

## Next priorities after this round

1. Preserve the green hosted source matrix and establish protected `main`,
   required-check policy, reviewed environments, credential rotation, and
   artifact provenance.
2. Finish the launch-language, NOOP+, Safety, pricing, public-version, owner,
   transfer/legal, payment, and legacy-support decisions; India-first and
   USA-second are already recorded.
3. Obtain the supplier SDK, license, printed-label/identity mapping, pairing and
   gesture contract, versioned NOOP Band hardware/firmware dossier, and
   representative engineering units. Do not infer the protocol.
4. Integrate the implemented ownership foundation with the supplier-backed
   printed-label, identify-haptic, authenticated-possession, owner-key, and
   controlled-release contracts after those inputs are approved.
5. Build the terminology classifier/allowlist, correct the false
   legacy-to-first-party display mapping, and introduce neutral core boundaries
   with old-data migration fixtures.
6. Create the protocol-spec template, neutral Swift/Kotlin SDK interfaces,
   deterministic virtual band, conformance corpus, and bounded observability
   categories before hardware arrives.
7. On hardware arrival, implement and prove authenticated provisioning,
   offline flash collection, durable history acknowledgement, clock, wear/power,
   haptics, and signed rollback-capable OTA on both phones.
8. Validate shake reports and performance on representative physical phones
   during lag, active collection, locked-background work, storage pressure,
   history, OTA, and managed sync.
9. Keep NOOP+ public ingress and released enrollment disabled until signed
   physical attestation, privacy, restore, load, monitoring, support, push,
   deletion, and production-operations gates pass.
10. Complete sensor/metric evidence, certifications, manufacturing, signing,
   store records, reviewer sample mode, accessibility, localization, and the
   signed physical release-candidate matrix.
11. Keep automatic emergency inference unavailable until its separate
    validation and regulatory program is complete.
12. Refresh the public landing page only after product names, claims, pricing,
    policies, supported hardware, and launch evidence are approved.
