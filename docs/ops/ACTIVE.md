# Active NOOP handoff

Last updated: **2026-09-04**

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

The newest transport round separates live biometric health from generic BLE
traffic on Apple and Android. Battery, metadata, and command packets can no
longer hide a stopped HR stream; each client first rewrites live notification
subscriptions and then reconnects if accepted HR remains absent. Explicit
off-wrist evidence suppresses reconnect churn, empty 5/MG history support no
longer disables recovery, and the 5/MG live-HR-only path now runs the watchdog.
Apple diagnostics also decode the persisted current family correctly. Focused
Apple tests, 4,017 Android tests, Android lint/build/launch, and the clean iOS
Release simulator graph pass. A physical phone and worn band were unavailable,
so continuous locked-background collection and the band's reported empty
history remain open. Evidence and the physical procedure are recorded in
[Biometric collection liveness](rounds/2026-09-04-biometric-collection-liveness.md).

The optional NOOP+ managed-storage source is implemented across iOS, Android,
FastAPI/PostgreSQL, and guarded GCP IaC. It adds phone OTP, App Check,
per-installation credentials, explicit versioned consent, immutable compressed
chunk upload, processor validation, snapshot plus incremental restore, quotas,
device revocation, erasure, and an optional 90-day detailed local window.
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
The clean implementation commit `3a55dfdb` also produced immutable runtime
digest `sha256:7567a6fccfe73436f167b5df17a32a0a15422dc18dd0f664a116d1d8ab2665fb`;
the on-demand scan reported zero findings. The image is stored but not deployed.

The complete-history export uses the restore snapshot/list/download APIs and
therefore includes history retained only in managed storage. It is deliberately
separate from the server `/exports` control plane, which accepts and verifies a
client-produced encrypted archive. Live large-account interruption/expiry
evidence, resumable continuation, and a documented importer remain
public-launch gates.

The Mumbai foundation remains synthetic-only with no connected mobile client
and no real health data. The final identity plan on 2026-09-04 contained seven
adds, zero changes, and zero destroys. Apply again stopped before Firebase
resource creation. Cloud Audit Logs confirm the project Owner was granted
`firebase.projects.update`; Google rejected the request because
`Firebase Tos Not Accepted`. The account holder must accept the terms at
`https://console.firebase.google.com/`, after which the plan must be regenerated.
The managed runtime and public invoker remain disabled.

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
- Optional local storage reduction keeps 90 days of detailed data and prunes
  only an exact server-validated clean window.
- Ordinary customer-day prompts must converge on one explainable local arbiter;
  safety and fresh workout caution remain separate lanes.
- No real health data enters the GCP staging project until identity, processor,
  isolation, restore, privacy/legal, and physical-device gates pass.

## Next priorities after this round

1. Install the current build on the physical iPhone without clearing data and
   prove durable HR advances while worn, locked, relaunched, and upgraded.
2. Accept Firebase terms, regenerate the zero-destroy identity plan, and deploy
   Identity Platform plus App Check to synthetic staging.
3. Generate ignored mobile configuration, prove debug attestation, run managed
   Cloud SQL tests, build/scan a digest, migrate through `024`, and deploy the
   managed runtime IAM-only.
4. Prove synthetic upload, duplicate, reconnect, restore, isolation, retention,
   erasure, load, and recovery before enabling public invocation.
5. Prove complete managed-history export with live cloud-only/large-account
   data, then add resumable continuation and documented import before public
   enrollment.
6. Complete signed physical-device background, storage-pressure, battery,
   upgrade, and multi-device validation.
7. Consolidate ordinary wellness notifications through the shared day arbiter
   after this storage round closes.
8. Complete privacy/legal, security, support-access, carrier, accuracy, store,
   and native-speaker external gates.
9. Keep automatic emergency inference unavailable until its separate
   validation and regulatory program is complete.
