# Round: 2026-10-02 - GCP private staging redeploy

## Status

- State: `in progress`
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

## Data, privacy, and medical truth

- Schema or migration impact: pending guarded migrations in a new empty
  synthetic PostgreSQL database.
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

## Physical device and deployment

- Install/update action: identity foundation applied; no app install or runtime
  deployment yet.
- Generalized device and OS class: not run.
- Data-preservation result: new empty project; no prior data imported.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed-phone, BLE, background, notification,
  haptic, battery, supplier, and physiological checks.

## Git and release state

- Changed paths: GCP IAM sequencing/tests and pilot tooling/tests, server PyJWT
  runtime inputs and notices, terminology inventory, and operations records.
- Commits: pre-image source commit pending.
- Branch and remote state: local deployment branch; not pushed.
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
- Cloud SQL and vulnerability scanning are the next billable stages and have
  not started.
- Authentication App Check remains `UNENFORCED` until reviewed native debug
  assertions or signed attestation are available; managed runtime validation
  requires a deliberate transition to `ENFORCED`.
- Real OTP delivery, mobile App Check attestation, push delivery, public
  ingress, and physical ownership remain prohibited and unverified.
- The broad Tools wall has one unrelated existing brand-localization count
  failure. The deployment-owned terminology snapshot was regenerated; final
  repository walls will be rerun after current mobile UI integration lands.

## Next round

1. Commit the reviewed source so the image builder can enforce a clean input.
2. Build and scan one immutable runtime digest.
3. Apply Cloud SQL, migrations, and least-privilege workload secrets.
4. Transition Authentication App Check deliberately, deploy IAM-only managed
   workloads, and keep public invocation false.
5. Run synthetic managed-runtime, authorization/isolation/lifecycle,
   private-boundary, and zero-drift verification.
6. Record exact evidence, close the protected pull request, and remove
   temporary credentials, logs, plans, and test data.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
