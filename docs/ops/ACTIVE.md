# Active NOOP handoff

Last updated: **2026-09-09**

## Repository

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Branch: `main`
- Remote branches: `origin/main`
- GitHub repository relationship: standalone, with no parent reported at the
  last authenticated check
- Current source-rights record:
  [`../provenance/OWNER-RIGHTS-DECLARATION.md`](../provenance/OWNER-RIGHTS-DECLARATION.md)
- Current agent handoff:
  [`../handoff/archive/AGENT-HANDOFF-20260827.md`](../handoff/archive/AGENT-HANDOFF-20260827.md)
- Current release blockers:
  [`../handoff/RELEASE-BLOCKERS.md`](../handoff/RELEASE-BLOCKERS.md)

## Active work

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
apps map every wire status to localized app-owned copy. A fresh extension-free
PostgreSQL Safety file passed 10 tests, the full server suite passed 371 tests
with 19 environment-gated skips, the Apple Safety suite passed 30 tests, the
Android Safety suite passed 29 tests, and the complete iOS simulator app graph
builds. The first final-review hosted macOS run found one stale 304-entry
localization assertion; the corrected contract pins the generated 313-entry
catalog and passes locally. Protected exact-head review, hosted checks, and
normal merge remain.
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
release gates remain open. The frozen terminology inventory classifies 17,370
legacy-name occurrences across 1,508 path/category groups; active customer/core
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
