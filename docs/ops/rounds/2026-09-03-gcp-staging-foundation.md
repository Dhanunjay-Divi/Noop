# Round: 2026-09-03 - GCP staging foundation

## Status

- State: `completed synthetic staging; launch blockers remain`
- Owner: project team
- Branch: `main`
- Start commit: `d7dab26c`
- End implementation commit: `0f5ae275`
- Record commit or PR: commit containing this record

## Objective

Connect the newly created Google Cloud project to a guarded, reproducible NOOP
staging environment. Success means billing is alert-budgeted, synthetic
foundation and runtime resources are managed by OpenTofu, the existing server
remains the implementation base, the deployed image passes a material
vulnerability gate, and no real health data or mobile client enters the cloud.

## Scope

### In scope

- Configure authenticated Google Cloud and remote OpenTofu state.
- Create a monthly billing alert before paid runtime resources.
- Provision regional storage, encryption, messaging, registry, identities,
  secrets, analytics, PostgreSQL, migration, and private API foundations.
- Preserve local-first, account-free NOOP while keeping NOOP+ explicit opt-in.
- Resolve TimescaleDB-to-standard-PostgreSQL and image-security boundaries.
- Run server, infrastructure, privacy, security, and operations checks.

### Non-goals

- Upload biometric, journal, location, contact, or workout data.
- Connect iOS or Android clients to staging.
- Provide public signup, identity recovery, support access, or public ingress.
- Claim production capacity, isolation, restore, failover, or compliance.
- Enable automatic medical, anomaly, stress, fall, or Safety paging.

## Starting evidence

- Reproduction or observed symptom: the owner created a GCP project and asked
  for the next implementation step for optional managed NOOP sync.
- Relevant source/device/OS/firmware class: FastAPI server,
  PostgreSQL/TimescaleDB migrations, GCP Mumbai staging, and disconnected local
  mobile clients.
- Existing tests, logs, exports, screenshots, or documents: server baseline
  and Ruff checks passed; production operations already listed identity,
  isolation, load, failover, restore, and physical-device gates.
- Unknowns that remain unknown: public traffic shape, production database
  sizing, regional latency, per-user cost, restore behavior, physical-device
  background upload, and multi-tenant isolation.

## Delivered

- Added a USD 50 monthly alert budget and protected remote state.
- Applied Mumbai foundation resources: required APIs, immutable Artifact
  Registry, KMS, CMEK raw storage, seven-day build storage, Storage-to-Pub/Sub
  events, least-purpose service accounts, empty secret containers, and an empty
  BigQuery dataset. A synthetic object proved the event path and was removed.
- Added `NOOP_DATABASE_ENGINE=postgresql` and a PostgreSQL first-migration
  overlay while retaining TimescaleDB as the self-hosted default. Engine
  checksums intentionally prevent silent switching.
- Applied a CMEK PostgreSQL 16 `db-f1-micro` staging instance with encrypted
  transport, deletion protection, PITR, and seven retained backups. The first
  automated backup completed successfully.
- Added secret bootstrap that keeps generated database credentials in process
  memory and out of Git, command arguments, OpenTofu plans, and state.
- Built a digest-pinned runtime from commit `bda7ae01`. Debian 13 and Bookworm
  candidates were rejected after scans found 3 effective Critical and 8 High
  issues. The final flattened Alpine runtime removes package tooling and
  returned zero findings in repeated on-demand scans.
- Ran the final migration image twice successfully, proving current migration
  compatibility and idempotency.
- Deployed the zero-finding digest to an IAM-protected, internal-ingress Cloud
  Run API with no broad invoker, scale zero to two, runtime migration and
  Safety worker disabled, and startup/liveness probes.
- Added a reusable digest-scoped scanner gate and stronger live private-runtime
  verification.

## Data, privacy, and medical truth

- Schema or migration impact: standard PostgreSQL substitutes only
  `001_init.sql`; later migrations remain canonical and shared.
- Existing-data retention impact: none. The cloud resources contain no mobile
  health history.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: operator authentication and local
  OpenTofu inputs remain ignored; clients remain disconnected; the API is
  internal-only and has no public invoker.
- Credential incident: an initial database-user command form allowed a
  generated password to enter a local CLI debug log. The password was rotated,
  secret version 1 was destroyed, the affected local log was cleared, and the
  command was replaced by an in-memory authenticated API helper. Version 2 is
  the only enabled database secret version.
- Health/medical claim impact and limitations: none. Synthetic infrastructure
  does not validate a metric, recommendation, alert, or medical behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Full server suite | 162 passed, 11 skipped of 173 collected | Existing server contracts remain green | Managed-cloud load or physical behavior |
| PostgreSQL 14 integration | 17 passed on a fresh temporary cluster | Migrations, tenancy, erasure races, Friends, provenance, and Safety lifecycle work without TimescaleDB | Cloud SQL failover, restore, or production scale |
| Deployment and legal contracts | Focused deployment tests, legal inventory, Ruff, and ShellCheck passed | Image, secret, private-runtime, scanner, and dependency gates are represented in source | Independent security or legal review |
| Runtime image scans | Final digest `sha256:9b0154ed...` returned 0 findings twice | The exact deployed image had no scanner findings at verification time | Future vulnerability intelligence or exploit absence |
| Managed migrations | Two final-image executions completed | Cloud SQL connectivity and migration idempotency for the current schema | Destructive rollback or future migration safety |
| Cloud SQL controls | PostgreSQL 16 runnable; CMEK, TLS, deletion protection, PITR, seven backups; one automated backup successful | Configured staging durability controls and backup creation | Restore correctness or regional failover |
| Private runtime verifier | Passed on revision `noop-staging-api-00002-5tr` | Ready, internal ingress, no broad invoker, scale 0-2, and digest pinning | Public identity or end-user reachability |
| External and log checks | Unauthenticated external `/healthz` returned 404; recent API error query returned none | Internal ingress rejects the tested external path and rollout emitted no queried errors | Exhaustive penetration or runtime testing |
| OpenTofu final plan | No changes | Applied resources match reviewed state | Correctness outside managed resources |
| Operations validator | Passed after record update | Required evidence structure and privacy patterns are present | Substantive privacy, medical, or compliance approval |

## Physical device and deployment

- Install/update action: no mobile app install or update.
- Generalized device and OS class: not applicable.
- Data-preservation result: no app container or real user data was modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical-device sync, reconnect, background upload,
  haptic, battery, and in-place-upgrade scenarios.

## Git and release state

- Changed paths: server engine/migration/image/test/legal files, `infra/gcp/`,
  cloud architecture/privacy/decision records, and operations records.
- Commits: `89acc65b` through `0f5ae275`; final record is in the commit
  containing this file.
- Branch and remote state: direct `main`; publication follows final local gates.
- Repository visibility verified: not repeated in this round.
- Version/build impact: no mobile application version change.
- Release or distribution impact: synthetic staging only; no app release and no
  user-facing cloud feature.

## Decisions

- Durable decision added or changed: optional NOOP+ managed sync remains
  separate from account-free, fully functional local NOOP. Managed high-rate
  history uses immutable compressed objects, while PostgreSQL holds identity,
  control, manifests, and queryable aggregates rather than indefinite raw
  sample duplication.
- Decision-log entry: D-036.

## Open risks and honest limitations

- Identity provider selection, enrollment, recovery, deletion, and support
  access are not implemented.
- The raw-object processor is not deployed; the Pub/Sub subscription has no
  production consumer.
- `db-f1-micro`, zonal Cloud SQL, public connector endpoint, and scale 0-2 are
  staging cost choices, not a production topology or capacity claim.
- A successful backup is not a restore drill. Restore, regional failure,
  isolation, abuse, reconnect burst, soak, and 10,000-user tests remain open.
- A zero-finding scan is point-in-time evidence. Every new digest still requires
  scanning, patch review, and provenance/SBOM work.
- Privacy/legal review and explicit-opt-in physical iOS/Android background sync
  tests remain required before any real health upload.

## Next round

1. Select and threat-model identity, recovery, deletion, and operator access.
2. Implement the immutable chunk manifest, upload authorization, processor
   idempotency, aggregate provenance, export, and erasure paths.
3. Prove restore, tenant isolation, reconnect burst, soak, load, and failover on
   synthetic data.
4. Only after privacy/legal approval, add explicit NOOP+ client enrollment and
   physical-device background upload tests without changing core local NOOP.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
