# Round: 2026-10-02 - GCP private staging redeploy

## Status

- State: `private synthetic staging deployed and verified; protected integration pending`
- Owner: project team
- Branch: `codex/gcp-staging-redeploy-20261002`
- Start commit: `e840874872f5e7eb7f38afcecd7aaa826b12288e`
- End implementation commit: pending
- Record commit or PR: pending
- Environment: new private synthetic GCP staging only

## Objective

Recreate the guarded NOOP cloud staging stack under the owner-selected replacement
Google Cloud account. Success requires a dedicated billing-enabled project,
protected remote state, budget alerts, Firebase synthetic phone identity and
App Check, Cloud SQL, immutable scanned runtime images, migrations, separate
least-privilege workload credentials, IAM-only managed and ownership services,
synthetic OTP/account smoke, private-boundary verification, and zero drift.

This round does not authorize public invocation, real phone numbers, real health
data, production traffic, payment entitlement, or a physical-band ownership
claim.

## Scope

### In scope

- Create and bind a dedicated replacement staging project to the owner-selected
  billing account.
- Bootstrap protected OpenTofu state in Mumbai and apply the foundation in
  reviewed stages.
- Enable Firebase identity/App Check with an untracked synthetic phone/code.
- Build, scan, and deploy one immutable server digest.
- Create Cloud SQL, run migrations, provision separate runtime principals, and
  deploy private managed workloads.
- Stage verified email/password ownership identity and the IAM-only ownership
  authority while keeping physical possession verification fail closed.
- Run synthetic identity, authorization, isolation, lifecycle, and drift
  verification without real user or health data.
- Record exact evidence, cleanup, costs, and unresolved external gates.

### Non-goals

- Public Cloud Run invocation or production customer traffic.
- Real SMS/phone OTP, APNs/FCM delivery, real contacts, or real health uploads.
- Supplier possession proof, band claim, BLE, background, haptic, battery, or
  sensor-accuracy validation.
- Payment, NOOP+ entitlement grants, store submission, or launch approval.
- Reuse or migration of the inaccessible prior project, state, secrets, users,
  database, or health data.

## Starting evidence

- The replacement Google Cloud account has an open billing account and a
  billing-enabled automatically created project.
- A separate dedicated NOOP staging project was created and linked to that
  billing account.
- `gcloud` and application-default credentials are pinned to the dedicated
  project.
- The deployment checkout is clean protected `main` at
  `e840874872f5e7eb7f38afcecd7aaa826b12288e`.
- The new project has no inherited NOOP state, secrets, database, users, or
  runtime resources.
- Unknowns that remain unknown until measured: provider quotas, Firebase terms
  acceptance, image scan findings, migration/runtime readiness, synthetic OTP
  behavior, managed smoke behavior, and final drift.

## Delivered

- Authenticated the owner-selected replacement Google Cloud account without
  copying a password or credential into the repository.
- Created a dedicated staging project and linked it to the selected billing
  account.
- Pinned CLI and application-default quota context to the dedicated project.
- Created an isolated deployment worktree and branch from exact protected
  `main`.
- Bootstrapped a versioned, public-access-prevented remote state bucket and
  applied the zero-runtime foundation.
- Enabled the IAM API explicitly and sequenced service-account/custom-role
  creation behind it. Added a bounded propagation wait before GCS bindings use
  newly created custom roles.
- Created a monthly USD 50 gross-before-credits budget with current-spend
  alerts at 50%, 90%, and 100%, plus a forecast alert at 90%. This is an alert,
  not an automatic spending stop.
- Ran the server release gates. The live dependency audit found
  `PYSEC-2026-4141` in PyJWT 2.14.0; runtime inputs, hashes, notices, and legal
  inventory now use PyJWT 2.15.0, and both audited inputs report no known
  vulnerabilities.
- Applied Firebase project registration, iOS and Android app registration,
  App Attest, Play Integrity, Authentication App Check in `UNENFORCED`
  synthetic-pilot mode, and fictional test-phone Identity Platform
  configuration. The reviewed retry applied seven creates and zero updates or
  deletes.
- Generated ignored Apple and Android pilot configuration with mode `0600`.
- Completed a fictional phone verification and sign-in round trip, removed its
  temporary App Check debug token, and verified the retained synthetic pilot
  claim without printing the phone, code, tokens, or identity identifier.
- Enabled email/password account identity through one in-place Identity
  Platform update with zero creates or deletes.
- Corrected the pilot tool so identity/config/OTP operations can run before a
  managed Cloud Run service exists, while final pilot verification still
  requires a private deployed runtime. Focused tests cover both states.
- Removed six applied `.tfplan` files after use because provider plans can
  retain synthetic credentials. Remote state and the exact applied resources
  remain intact.
- Built and scanned one immutable runtime image at digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`;
  the deployed image scan reported zero vulnerabilities.
- Created the new empty Cloud SQL database, applied all guarded migrations, and
  provisioned separate runtime principals for the API, managed API, processor,
  managed lifecycle, feedback lifecycle, and migration job. Runtime roles use
  bounded socket URLs and cannot read the migration credential.
- Deployed the private API, private managed API, managed processor, migration
  job, managed lifecycle job, and feedback lifecycle job. App Check is
  `ENFORCED`, Cloud Run has no public invoker, and all deployed services and
  jobs reached their ready or successful state.
- Removed `NOOP_MANAGED_STORAGE_ENABLED` from the lifecycle job. That worker
  imports lifecycle settings, not the managed API startup contract; setting
  the flag caused the first live lifecycle execution to reject otherwise valid
  worker-only configuration.
- Added a bounded managed-upload capability lifetime input. Normal staging
  remains `900` seconds; this disposable synthetic environment uses the
  allowed `60`-second minimum so the smoke can prove erasure after every signed
  upload capability expires instead of weakening the capability fence.
- Extended the private smoke with temporary fictional push destinations. The
  Safety path now proves invite/request/contact setup, two-contact incident
  targeting, request replay idempotency, and fail-closed cancellation when the
  fictional destinations are rejected. It explicitly revokes those
  destinations and does not claim real APNs/FCM delivery.
- Passed the complete private managed-runtime smoke in `210` seconds: three
  fictional phone OTP identities, App Check, pilot claims, enrollment,
  upload/processing/idempotency/isolation/restore, object erasure, social
  identity and sharing, disposable Safety destinations, account erasure, and
  provider-identity cleanup.
- Restored Identity Platform to exactly one retained fictional phone and
  verified that zero App Check debug tokens remain.
- Resumed the every-minute managed lifecycle scheduler after smoke completion.
  Execution `noop-staging-managed-lifecycle-2ckzw` completed successfully in
  `17.33` seconds, and the scheduler remains enabled.
- Re-ran the private-runtime verifier and an OpenTofu
  `-detailed-exitcode` plan. The private checks passed and the final plan
  reported `No changes`.

## Data, privacy, and medical truth

- Schema or migration impact: all guarded migrations were applied to a new
  empty synthetic PostgreSQL database.
- Existing-data retention impact: none; no prior project data is imported.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: private IAM-only staging is in scope;
  public invocation remains disabled.
- Health/medical claim impact and limitations: no real health data or
  physiological validation is permitted in this round.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: bounded
  command status files, OpenTofu plans/applies, Cloud Build/Run/SQL operation
  states, migration receipts, fixed-route server operation events, synthetic
  smoke outcomes, private-boundary verification, and final drift exit status.
- Why existing evidence is sufficient, or why new evidence is required: the
  repository already emits bounded backend operation events; this round adds
  deployment evidence rather than payload logging.
- Existing evidence reused: guarded infrastructure scripts, request
  observability middleware, migration receipts, workload readiness probes, and
  private-runtime verifier.
- New bounded events or operation spans: none planned unless a deployment
  boundary is found to be opaque.
- Redaction, retention, and high-frequency controls: logs exclude phone/code,
  identity subjects, tokens, URLs, database credentials, payloads, health
  values, and dynamic identifiers; temporary logs are round-owned and removed
  after durable evidence is recorded.
- Cross-platform/backend correlation: synthetic account and service requests
  use server-generated correlation IDs only.
- Remaining blind spots: physical clients, carrier/provider delivery,
  terminated/background execution, band behavior, and production load.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Replacement-account authentication | Passed | The selected operator account can call Google Cloud APIs | Runtime deployment or customer identity |
| Dedicated project creation and billing link | Passed | A separate billing-enabled target exists | Trial-credit duration, final cost, or deployed resources |
| Clean deployment checkout | Passed at exact protected `main` | Deployment source is isolated from dirty development work | Cloud correctness |
| Foundation apply and drift refresh | Passed | Protected state and the zero-runtime regional foundation exist | Database or runtime readiness |
| Budget policy | Passed | Project-scoped alerts exist at the recorded thresholds | A hard cost cap |
| OpenTofu source tests | Passed 21/21 with deployment-only ownership identity explicitly reset to its source default | Database-secret separation, feedback bounds, ownership defaults, runtime guards, and IAM sequencing remain enforced | Live provider behavior |
| Server dependency and PostgreSQL gates | Passed; one intentional provider/environment skip | Current server source, lock, legal inventory, and standard PostgreSQL behavior are release-buildable | Cloud deployment or production load |
| Managed identity plan/apply | Passed; seven creates, zero updates, zero deletes | Firebase apps, App Check registrations, and fictional phone auth exist | Signed-device App Attest or Play Integrity |
| Ignored native configuration | Passed; both files mode `0600` and Git-ignored | Local candidates can be configured without committing API keys or the fictional phone | App installation or native sign-in |
| Synthetic phone OTP and pilot claim | Passed | Provider verification start, code exchange, sign-in, lookup, and custom-claim update work for the fictional identity | Real SMS delivery, carrier behavior, or user recovery |
| Ownership account identity plan/apply | Passed; one update, zero creates or deletes | Email/password account creation is enabled on the same staged identity service | Ownership claim, possession proof, or public account availability |
| Pilot sequencing regression tests | Passed 8/8 | Identity-only operations no longer incorrectly require an undeployed runtime; runtime verification remains fail-closed | Deployed runtime correctness |
| Legal inventory | Passed for 230 runtime components and three container inputs | Updated runtime inputs have matching notices and distribution provenance | Image vulnerability scan |
| Immutable runtime image | Passed; one digest deployed and scan reported zero vulnerabilities | The live workloads use the reviewed server image and the registry scan found no known image vulnerability | Unknown future disclosures or runtime behavior |
| Cloud SQL, migrations, and workload roles | Passed | The new database is migrated and each workload uses a separate bounded runtime credential | Production load, prior-project migration, or customer data |
| Private workload deployment | Passed; API, managed API, processor, migration, managed lifecycle, and feedback lifecycle ready/successful | The guarded runtime can start with App Check enforced and no public invoker | Public traffic, physical clients, or real provider delivery |
| Private managed-runtime smoke | Passed in 210 seconds | Fictional OTP, identity, enrollment, storage, processing, isolation, erasure, social, Safety fail-closed behavior, and cleanup work end to end | Real SMS, APNs/FCM reachability, signed-device attestation, or physical-band behavior |
| Synthetic configuration restoration | Passed; one fictional phone retained and zero debug tokens remain | Temporary smoke identity/App Check configuration was removed | Production identity recovery or carrier behavior |
| Managed lifecycle schedule | Passed; resumed execution completed successfully in 17.33 seconds | The scheduled lifecycle invoker can run the deployed job | Long-duration reliability or production volume |
| Private-boundary verifier | Passed | Public invocation remains disabled and expected IAM-only boundaries are present | Application correctness behind the boundary |
| Final OpenTofu plan | Passed with exit code 0 and `No changes` | Applied infrastructure matches the reviewed configuration | Future provider drift |
| Final OpenTofu test wall | Passed 21/21 | Database-secret separation, lifecycle/API configuration, ownership defaults, feedback bounds, and required-service ordering remain enforced after the live fixes | Provider behavior beyond the applied staging project |
| Final server wall | Ruff and both dependency audits passed; complete pytest wall passed with documented external-database/provider skips | Server source, lock files, smoke contract, and non-external API behavior remain green | Signed clients, production load, or unavailable external providers |
| Final repository controls | 115 operations records, 258 release-control tests, 10 required contexts, calibration, legal/distribution, private-data, and 1,324-file health-claims scan passed | The exact branch remains within repository release, privacy, provenance, and health-claim policy | Hosted exact-SHA checks or physical-device evidence |
| Terminology ratchet | Passed with 18,600 classified occurrences across 1,646 groups, zero forbidden mappings, and an unchanged customer/core allowlist | Documentation line shifts were regenerated and reviewed without adding customer-facing legacy terminology | Future source changes |

## Physical device and deployment

- Install/update action: private synthetic cloud runtime deployed; no signed
  mobile app was installed.
- Generalized device and OS class: not run.
- Data-preservation result: new empty project; no prior data imported.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed-phone, BLE, background, notification,
  haptic, battery, supplier, and physiological checks.

## Git and release state

- Changed paths: GCP foundation/runtime/identity/IAM/database configuration and
  tests, synthetic deployment/smoke tooling, server PyJWT runtime inputs and
  notices, terminology inventory, and operations records.
- Commits: implementation commits `783568e75` through `9eb61ad20`; final
  smoke/TTL/documentation commit pending.
- Branch and remote state: local deployment branch from exact GitHub protected
  `main`; protected pull request pending.
- Repository visibility verified: public repository; private credentials and
  generated configuration remain excluded.
- Version/build impact: none.
- Release or distribution impact: private staging only.

## Decisions

- Durable decision added or changed: none. Existing staged cloud-authority,
  synthetic-only staging, private-ingress, and fail-closed ownership decisions
  remain authoritative.
- Decision-log entry: none.

## Open risks and honest limitations

- Trial credit is a billing credit, not a hard cap; the repository budget is an
  alert and does not automatically stop resources.
- This project now has cost-bearing Cloud SQL, Cloud Run, storage, scheduler,
  registry, logging, KMS, and related resources. The USD 50 budget is an alert,
  not a hard stop.
- Authentication App Check is `ENFORCED` for the staged identity service.
  Simulator smoke uses a temporary debug assertion that is deleted; signed
  App Attest and Play Integrity behavior remains unverified.
- Real OTP delivery, mobile App Check attestation, push delivery, public
  ingress, and physical ownership remain prohibited and unverified.
- Fictional Safety destinations intentionally fail closed and therefore do not
  validate live APNs/FCM delivery, responder actions, alert sound, or physical
  notification behavior.
- The synthetic environment uses a `60`-second signed-upload TTL solely to
  keep destructive smoke bounded. The documented normal staging default
  remains `900` seconds.

## Next round

1. Run the complete source/release/privacy operations gates on the exact branch
   head.
2. Push one protected pull request, allow required hosted checks to complete,
   and merge without bypass.
3. Verify exact protected `main` and remove round-owned temporary logs and
   build output after evidence is durable.
4. Configure signed iPhone and Android candidates against this private staging
   project and run the physical-device handoff without enabling public
   invocation or real health data.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
