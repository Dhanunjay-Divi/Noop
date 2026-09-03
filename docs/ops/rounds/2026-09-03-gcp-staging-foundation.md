# Round: 2026-09-03 - GCP staging foundation

## Status

- State: `in progress`
- Owner: project team
- Branch: `main`
- Start commit: `d7dab26c`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Connect the newly created Google Cloud account to a guarded, reproducible NOOP
staging environment. Success means the project is authenticated, billing is
verified and budget-alerted, synthetic-only foundation resources are managed by
OpenTofu, the existing server remains the implementation base, and no real
health data or credential enters Git or the cloud during this round.

## Scope

### In scope

- Configure the local Google Cloud CLI and Application Default Credentials.
- Verify the intended staging project, billing attachment, and operator access.
- Add a project-scoped monthly billing alert before paid runtime resources.
- Add reviewed OpenTofu for regional storage, encryption, messaging, registry,
  identities, secrets, and analytics foundations.
- Preserve the local-first, account-free default while documenting NOOP+ as a
  separate explicit cloud opt-in.
- Identify and address the existing TimescaleDB-to-Cloud-SQL compatibility
  boundary before provisioning a database.
- Run server, infrastructure, privacy, and operations-documentation checks.

### Non-goals

- Upload real biometric, journal, location, contact, or workout data.
- Connect iOS or Android clients to the staging environment.
- Claim production readiness, public identity/recovery, capacity, failover,
  restore, or health-data compliance from a synthetic foundation deployment.
- Enable automatic medical, anomaly, stress, or fall paging.
- Provision production or silently enable cloud sync for existing users.

## Starting evidence

- Reproduction or observed symptom: the owner created a new GCP account and
  project and requested the next implementation step for NOOP cloud scale.
- Relevant source/device/OS/firmware class: existing FastAPI server,
  PostgreSQL/TimescaleDB migrations, GCP staging project, and local mobile
  clients that remain disconnected from this environment.
- Existing tests, logs, exports, screenshots, or documents: the server baseline
  suite and Ruff check pass at the start commit; production operations already
  document identity, isolation, load, failover, and restore gates.
- Unknowns that must remain unknown until measured: production traffic shape,
  Cloud SQL sizing, regional latency, workload cost, physical-device background
  upload behavior, recovery behavior, and public multi-tenant isolation.

## Delivered

- Installed and authenticated Google Cloud CLI/OpenTofu against a dedicated,
  billed Mumbai staging project and added a USD 50 monthly alert budget.
- Applied the synthetic foundation: protected remote state, required APIs,
  Artifact Registry, KMS, raw/build buckets, Storage-to-Pub/Sub events,
  separate least-purpose service accounts, empty regional secrets, and an empty
  regional BigQuery dataset.
- Proved the Storage event path with one synthetic canary object and removed it.
- Added an explicit standard-PostgreSQL engine and initial-migration overlay
  while preserving TimescaleDB as the self-hosted default. Migration checksums
  differ intentionally by engine.
- Added guarded OpenTofu for a CMEK, deletion-protected PostgreSQL 16 instance,
  one-shot migration job, and internal-only scale-to-zero API. The billable
  database and runtime remain disabled until the committed build is selected.
- Added fail-closed build, secret-bootstrap, migration, and runtime-verification
  scripts. Secret values stay out of Git, plan files, and OpenTofu state.
- Recorded the durable local-first/optional-NOOP+ boundary and the target
  immutable-object plus derived-PostgreSQL data plane.

## Data, privacy, and medical truth

- Schema or migration impact: standard PostgreSQL substitutes only
  `001_init.sql`; later canonical migrations are shared. Existing TimescaleDB
  databases retain their original migration checksum and behavior.
- Existing-data retention impact: none at round start.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: Google Cloud operator authentication
  is local and untracked; application clients remain disconnected. The planned
  API has internal ingress and no broad invoker.
- Health/medical claim impact and limitations: none. Synthetic infrastructure
  does not validate a health metric or medical behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Server baseline tests | Passed at start commit | Existing server behavior starts green | Managed-cloud compatibility |
| Server Ruff check | Passed at start commit | Existing Python source passes lint | Runtime or security posture |
| Full server suite | 160 passed, 11 skipped out of 171 collected | Memory/API contracts and non-external server behavior remain green | Real carrier or managed-cloud behavior |
| Standard PostgreSQL 14 integration | 17 passed on a fresh temporary cluster | Migrations, tenancy, erasure races, Safety lifecycle, Friends, and provenance run without TimescaleDB | Cloud SQL, failover, restore, or production load |
| OpenTofu format/validate/plan | Passed; zero post-apply drift before runtime | Foundation state matches reviewed configuration | Billable runtime or mobile readiness |
| ShellCheck and deployment contract tests | Passed | Operator scripts parse and critical private/migration/encryption gates are asserted | External service behavior |
| Operations validator | Passed for all 19 round records | Required headings, index links, and basic privacy patterns are clean | Full privacy/legal review |

## Physical device and deployment

- Install/update action: no mobile app install or update.
- Generalized device and OS class: not applicable.
- Data-preservation result: no app container or real user data is modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical-device sync and background scenarios.

## Git and release state

- Changed paths: server engine/migration/test/docs, `infra/gcp/`, cloud
  architecture/privacy/operations records, and ignore rules.
- Commits: implementation commit pending.
- Branch and remote state: local `main` started equal to `origin/main`.
- Repository visibility verified: not repeated in this round.
- Version/build impact: no application version change planned.
- Release or distribution impact: synthetic staging only; no app release.

## Decisions

- Durable decision added or changed: optional NOOP+ managed sync remains
  separate from account-free, fully functional local NOOP; managed high-rate
  history uses immutable objects rather than indefinite PostgreSQL duplication.
- Decision-log entry: D-036.

## Open risks and honest limitations

- The existing first server migration requires TimescaleDB, while Cloud SQL
  PostgreSQL does not supply that extension. A managed database must not be
  provisioned until this is handled explicitly and tested.
- Public signup, identity proof, account recovery, support access, abuse
  controls, privacy review, and independent tenant-isolation evidence remain
  external launch gates.

## Next round

1. Build a digest-pinned image from the committed tree, provision the guarded
   database, create untracked secret versions, run migrations, enable and verify
   the private API, then complete this evidence record.

## Privacy check

- [ ] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
