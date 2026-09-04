# Round: 2026-09-03 - NOOP+ managed storage

## Status

- State: `source complete and locally verified; live deployment blocked by Firebase terms`
- Owner: project team
- Branch: `main`
- Start commit: `9a7113f3`
- End implementation commit: `3a55dfdb`
- Record commit or PR: commit containing this final record

## Objective

Implement the optional NOOP+ managed-storage path end to end: account identity,
explicit consent, tenant authorization, immutable chunk storage, configurable
quota and retention, backup/restore, erasure, and resumable iOS and
Android sync. Core NOOP must remain account-free, local-first, fully featured,
and compatible with self-hosted Sync. Deliver a complete, locally verified
managed-history export on Apple and Android while keeping live deployment and
round-trip import as explicit launch gates.

## Scope

### In scope

- Add the managed identity, tenancy, plan, quota, object-manifest, processing,
  aggregate-provenance, cursor, restore, export, erasure, encryption-metadata,
  tombstone, support-access, and audit schema.
- Configure and verify synthetic-only Identity Platform staging.
- Implement authenticated managed-storage APIs and immutable object transfer.
- Add explicit optional enrollment and background sync to iOS and Android.
- Measure storage representation and validate isolation, retry, duplicate,
  reconnect-burst, restore, retention, and erasure behavior.
- Document architecture, operations, costs, limitations, and rollout gates.

The `/exports` schema and API remain control-plane groundwork for a
client-produced encrypted archive. Native complete-history export instead uses
the restore snapshot/list/download contract so cloud-only history can be
included without conflating the two facilities.

### Non-goals

- Make an account or network connection mandatory.
- Paywall metrics, coaching, workouts, journal, automations, or export.
- Upload existing users or real health data without explicit consent.
- Claim that cloud storage fixes operating-system suspension or BLE dropouts.
- Enable production traffic before privacy/legal and physical-device gates.

## Starting evidence

- Reproduction or observed symptom: one phone accumulated approximately 600 MB
  in ten days and experienced UI slowdown plus intermittent collection. The
  owner requested scalable managed storage and optional OTP login.
- Relevant source/device/OS/firmware class: local GRDB and Room stores,
  self-hosted FastAPI/PostgreSQL Sync, GCP Mumbai synthetic staging, iOS and
  Android background schedulers.
- Existing tests, logs, exports, screenshots, or documents: server baseline
  passed at the start of this round; the prior GCP foundation round deployed a
  private zero-finding runtime with no connected mobile clients.
- Unknowns that must remain unknown until measured: compressed bytes per
  user-day by stream, physical-device background cadence, production SMS
  conversion/abuse rate, restore throughput, and production capacity.

## Delivered

- Added managed account, external identity, policy consent, plan/rule, quota,
  installation, source, client key, immutable chunk, stream manifest, aggregate
  provenance, change feed, restore, document, export, erasure, tombstone,
  support-access, audit, lifecycle, and worker-lease schema in migrations `014`
  through `024`.
- Added phone-token and Firebase App Check verification, per-installation
  credentials, tenant-scoped APIs, generation-bound signed object
  capabilities, quotas, idempotency, cursor expiry, a client-upload export
  control plane, reauthenticated erasure, and identity-deletion tickets.
- Added a bounded processor that validates object identity, generation,
  checksum, compressed/uncompressed size, schema, stream manifests, event
  windows, source ownership, and authoritative replacement before making a
  chunk available.
- Added iOS and Android phone OTP, explicit versioned consent, App
  Attest/Play Integrity configuration, dormant-by-default environment loading,
  device revocation, deletion cooling-off/cancel, and storage overview UI.
- Added deterministic compressed chunk construction, forward and dirty-window
  repair, durable upload receipts, snapshot plus incremental restore, and
  authentication-refresh retry on both platforms.
- Added optional **Reduce phone storage after backup** behavior. It keeps 90
  days of detailed history and prunes only exact processor-validated clean
  windows; summaries, user records, dirty windows, and unvalidated data remain.
- Kept local NOOP, Self-hosted Sync, metrics, coaching, workouts, journal,
  automations, and export independent of a NOOP+ account or entitlement.
- Added guarded GCP identity, App Check, IAM-only managed API, processor,
  lifecycle, scheduler, Pub/Sub push, least-purpose IAM, and runtime variables.
  Public Cloud Run invocation is a separate final gate.
- Added privacy-safe app diagnostics and user-initiated report bundles for
  investigating UI stalls and sync behavior without logging health values or
  credentials.
- Added Apple and Android complete managed-history export. Each client first
  performs bounded high-budget backup catch-up without pruning, creates a
  consistent restore snapshot, pages all five managed chunk classes plus every
  current personal document, verifies per-object digests/sizes and aggregate
  object/byte totals, completes the snapshot, and writes a manifest-backed ZIP.
- The Apple writer uses a complete-protection temporary file and removes it
  after the share handoff; Android streams to a user-selected SAF destination.
  Both reject traversal/duplicate entries and delete or truncate partial output
  on failure or cancellation.
- Added the customer-day, frontend, backend, regional-cell, SLO, security, and
  1K-to-1M scale contract in `docs/PLATFORM_ARCHITECTURE.md`.

## Data, privacy, and medical truth

- Schema or migration impact: additive server migrations `014` through `024`,
  Swift local migrations, and Android Room versions through 45. Existing
  self-hosted tables remain supported.
- Existing-data retention impact: local pruning is default off. When explicitly
  enabled after enrollment, only an exact validated detailed-data window older
  than 90 days is eligible; user-authored and summary records remain local.
- Source/provenance or formula impact: none at round start.
- Permissions/network disclosure impact: App Attest/Play Integrity and Firebase
  dependencies are added, but empty checked-in configuration leaves NOOP+
  unavailable. No mobile client is connected to GCP.
- Health/medical claim impact and limitations: storage and identity work does
  not validate a physiological metric or medical behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Server baseline (`cd server && .venv/bin/pytest -q`) | Passed; PostgreSQL-dependent tests skip only when no test URL is supplied | Existing unit and contract baseline is green | Physical-device sync or live cloud behavior |
| Pinned provider schema inspection | Identity Platform phone sign-in, SMS region policy, Firebase app, and App Check resources are available | Infrastructure can represent the intended identity controls | Enrollment security, SMS delivery, or mobile correctness |
| Full server suite against disposable PostgreSQL 14 | Passed again on 2026-09-04 with migrations `001` through `024` | Managed API, repository, migrations, processing, lifecycle, isolation contracts, and existing server behavior pass on standard PostgreSQL | Cloud SQL operations, load, or physical clients |
| Managed PostgreSQL migration/integration matrix | Passed | Additive migrations and managed state machines execute against PostgreSQL | Production restore/failover capacity |
| Android Demo and Full unit/lint plus API-35 managed-device matrices | Passed on 2026-09-04, including complete-history exporter and archive-writer tests | Both flavors compile with dormant managed configuration; Room migrations, snapshot paging, auth refresh, digest/count reconciliation, ZIP writing, and cleanup contracts pass | Signed Play Integrity, OEM background behavior, live OTP, or live large-account export |
| iOS 89-target simulator graph plus focused Swift tests | Passed on 2026-09-04 with a quiet warning rerun, including 88 NoopRemoteSync tests and app archive-writer tests | Apple app, Watch, complications, widgets, Firebase dependencies, dormant configuration, snapshot export, and protected ZIP contracts compile/pass | Signed App Attest, CoreBluetooth, background execution, live OTP, or live large-account export |
| Full macOS Strand and StrandAnalytics suites | The Strand test action exited successfully; StrandAnalytics passed 1,451 tests with seven intentional skips and no failures on 2026-09-04 | The complete current macOS app and analytics suites remain green after managed-storage integration | Physical-device behavior, clinical accuracy, or production cloud behavior |
| Source/security/release gates | Ruff, Python dependency audit, localization/brand, health claims, private-data filename, 80 repository-tool tests, 213-component legal inventory, `git diff --check`, and secret-pattern scan passed | The reviewed worktree is internally consistent and contains no detected checked-in runtime credential | Independent penetration testing, legal review, or signed-store evidence |
| `tofu fmt -check -recursive` and `tofu validate` | Passed on 2026-09-04 | Current GCP source is formatted and provider-valid | Successful apply or runtime behavior |
| Final identity plan | `7 add, 0 change, 0 destroy`; Android SHA-1 representation has no diff | Current plan is strictly additive and the prior certificate-format drift is fixed | Firebase terms acceptance or resource creation |
| Identity apply and Cloud Audit Log | Apply retried at 2026-09-04 20:04 UTC and stopped before Firebase creation; Owner permission granted, status `Firebase Tos Not Accepted` | Failure is the account-level contractual terms gate, not missing project IAM or source configuration | Identity, App Check, SMS, or managed runtime deployment |
| Clean runtime image build and on-demand scan | Cloud Build succeeded from implementation commit `3a55dfdb`; immutable digest `sha256:7567a6fccfe73436f167b5df17a32a0a15422dc18dd0f664a116d1d8ab2665fb`; scan reported zero findings | The exact reviewed server source builds as the minimal runtime image and passes the material vulnerability gate | Identity creation, migration, Cloud Run deployment, runtime behavior, or production security |

## Physical device and deployment

- Install/update action: simulator/emulator builds only; no signed physical
  managed configuration installed.
- Generalized device and OS class: iOS simulator and Android build/test hosts.
- Data-preservation result: no app container or user data modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: iOS and Android enrollment, background upload,
  reconnect, storage-pressure, restore, battery, and in-place upgrade.

## Git and release state

- Changed paths: managed server/schema/IaC, Swift and Kotlin clients/storage/UI,
  dependency/legal inventories, diagnostics, tests, and architecture/ops docs.
- Commits: implementation published as `3a55dfdb`; the final evidence record is
  the commit containing this update.
- Branch and remote state: implementation commit `3a55dfdb` is published on
  `origin/main`; this evidence-only update follows it.
- Repository visibility verified: not repeated.
- Version/build impact: Firebase libraries and local database migrations are
  additive; empty managed configuration keeps community/default builds
  disconnected.
- Release or distribution impact: synthetic staging only.

## Decisions

- Durable decision added or changed: phone OTP plus App Check and
  per-installation credentials; storage-only entitlement; 90-day validated
  local detailed window; local explainable day guidance and regional cells.
- Decision-log entries: D-036 through D-038.

## Open risks and honest limitations

- The account holder must accept Firebase terms while signed in as the GCP
  owner. No code or IAM change can bypass that contractual action.
- Identity/App Check, IAM-only managed runtime, signed mobile configuration, and
  live synthetic end-to-end tests are not deployed.
- Public ingress remains deliberately disabled.
- Physical-device BLE/background/battery/storage-pressure/multi-device behavior,
  security review, legal review, restore/failover drills, and production load
  evidence remain open.
- The observed 600 MB is a SQLite footprint, not measured compressed cloud
  bytes. Production storage cost cannot be inferred directly from it.
- Server-readable managed backup is not end-to-end encrypted and must never be
  described as private opaque storage.
- The native clients now assemble a readable, snapshot-bound archive from the
  restore/list/download APIs, including cloud-only chunks. The `/exports` API
  remains a separate encrypted client-archive facility and is not invoked.
- Managed-history export is not resumable across process death and has no
  archive importer yet. Live large-account, token-expiry, cancellation,
  snapshot-expiry, corruption, and tenant-isolation evidence remain launch
  gates.

## Next round

1. Accept Firebase terms while signed in as the authenticated project-owner
   account, regenerate and review the identity plan, then apply.
2. Generate ignored mobile configuration and prove debug App Check.
3. Run Cloud SQL disposable integration, migrate through `024`, and deploy the
   already built and scanned managed runtime digest IAM-only.
4. Prove complete managed-history export against live cloud-only and
   large-account fixtures; add resumable continuation and documented import
   before public enrollment.
5. Complete synthetic and physical launch gates, final review, commit, and push
   before closing this round.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
