# Active NOOP handoff

Last updated: **2026-09-05**

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

- NOOP remains local-first and account-free by default.
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
- Core NOOP remains fully local and account-free; NOOP+ managed sync requires
  explicit enrollment and must never silently upload existing history.
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

1. Validate shake reports on representative iPhone and Android hardware during
   UI lag, active collection, locked-background operation, and managed sync;
   inspect every attachment before sharing.
2. Define backend log retention, access control, volume/cost budgets,
   dashboards, alerts, and ownership before managed public traffic.
3. Install the current build on the physical iPhone without clearing data and
   prove durable HR advances while worn, locked, relaunched, and upgraded.
4. Keep the public invoker and released mobile configuration disabled while
   proving signed physical-client attestation and the complete install,
   enrollment, background, restore, revoke, and upgrade journeys.
5. Load-test reconnect bursts and rehearse Cloud SQL PITR, object recovery,
   secret rotation, and cell-level operational response.
6. Establish production HTTPS links, minimal opaque APNs/FCM wake delivery,
   abuse controls, support access, and deletion operations.
7. Prove complete managed-history export with live cloud-only/large-account
   data, then add resumable continuation and documented import before public
   enrollment.
8. Complete signed physical-device background, storage-pressure, battery,
   upgrade, multi-device, profile/invite-link, notification, and worn-band
   haptic validation.
9. Consolidate ordinary wellness notifications through the shared day arbiter
   after this storage round closes.
10. Complete privacy/legal, security, support-access, carrier, accuracy, store,
   and native-speaker external gates.
11. Keep automatic emergency inference unavailable until its separate
   validation and regulatory program is complete.
