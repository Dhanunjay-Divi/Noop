# Round: 2026-09-13 - PR 15 server and infrastructure review fixes

## Status

- State: `completed`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `0aa7c86c2350e4bc3596faac994d7865a37d1660`
- Review-correction start commit: `811060ae67db3b965552b5fb57483b4a53301807`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close the exact-head review findings without deploying or touching real data:
preserve migration-first compatibility for the prior Safety writer without
mutating migration `038`, define rollback honestly around the exact-manifest
readiness contract, make incident/quota provenance concurrency-safe, and make
the feedback bucket lifecycle rule a later safety ceiling than the exact
`retained_until` deletion owned by the lifecycle worker.

An exact-tree review subsequently found that the first implementation rewrote
already-published migration `038`. This resumed correction restores `038`
byte-for-byte to its original checksum and moves the writer-compatibility
behavior into the next forward-only migration.

A final read-only server review then found three follow-up defects in the
correction: the migration runner ignored forward/unknown ledger rows, mutating
lifecycle commands did not require exact readiness, migration application
hashed newline-normalized text while validation and backup used raw bytes, and
the runbooks described the fresh-install `038`/`041` transaction as if it also
applied to databases that had already committed `038`. This same round now
records the bounded source-only correction.

## Scope

### In scope

- Migration `038` immutability and forward-only Safety writer compatibility.
- PostgreSQL migration and managed Safety repository regression tests.
- Feedback-bucket lifecycle ceiling, focused OpenTofu/static tests, and narrow
  retention-contract documentation.

### Non-goals

- Deploying infrastructure, running migrations against shared or real data, or
  enabling public traffic.
- Changing Safety admission, quota amounts, health behavior, feedback payloads,
  or lifecycle-worker deletion semantics.

## Starting evidence

- Original migration `038` sets
  `managed_safety_page_quota_events.trigger` `NOT NULL` while the pre-038 Safety
  writer omits that column.
- The original migration trigger returns an omitted trigger unchanged, so an
  already-applied `038` rejects the legacy insert.
- The first local correction rewrote `038` from checksum `da26324b...` to
  `017556a7...`; the repository migration runner rejects any such applied
  checksum change.
- A final read-only review found that the first forward-only correction still
  committed `038` before `041`, tested only raw legacy SQL rather than runtime
  readiness, left incident/quota provenance vulnerable to a concurrent incident
  reassignment, and did not pin finalized `041` to a fixed checksum.
- The feedback bucket lifecycle currently uses the exact configured retention
  day count rather than a later backstop.
- Physical devices, deployed services, provider behavior, and real data are
  outside this source-only round.

## Delivered

- Restored migration `038` byte-for-byte to its original published SHA-256
  `da26324bf1c99c3f384af4fc24c8ef7ad728afcd5e5fd84b1e9a81fe4c61a943`.
- Added forward-only migration
  `041_managed_safety_writer_compatibility.sql`, the next available version
  after `040`. It drops the quota trigger column's `NOT NULL` contract for the
  expand window and derives an omitted trigger from the referenced incident.
  This supports the pre-038 writer after migration-first rollout without
  inventing a default.
- Finalized unpublished migration `041` at SHA-256
  `227809febdd3369ef530cab71deb08553a45a1d5e62ea070c86547b8d9ae3f9f`
  and pinned that fixed value in the focused migration test.
- Added an explicit migration-runner compatibility bundle that validates all
  existing checksums first, then applies `038` and `041` in one transaction
  before the independent `039` and `040` migrations on a fresh installation.
  An existing database that already recorded immutable `038` validates it,
  locks the quota table, and applies only pending `041`; this path requires the
  documented maintenance drain because the historical `038`-only commit cannot
  be made atomic retroactively.
- The `041` quota trigger now locks the referenced incident while deriving
  provenance, and the incident provenance trigger unconditionally rejects every
  later owner-profile or trigger change. The database no longer depends on
  seeing a concurrently inserted quota row before protecting ownership.
- Kept exact migration-set equality at readiness and documented the consequence:
  rollback uses a forward-built code revert retaining the current immutable
  migration set. An exact older image is not claimed as supported.
- The migration runner now rejects applied versions absent from the running
  image before any pending DDL. The migration command verifies exact manifest
  equality after application, and both mutation-capable lifecycle commands
  verify exact equality before constructing their repositories, object-store
  clients, identity deleter, processor, or provider services.
- The API lifespan now performs that exact check before starting embedded
  global-retention, Safety-retention, or feedback-lifecycle tasks. Rejection
  emits one bounded startup event containing only the fixed outcome, service,
  and exception class before the pool closes.
- Lifespan cleanup now covers every failure after repository startup,
  including Safety heartbeat failure. All started tasks are cancelled and
  collected together before the pool closes.
- Global retention, Safety retention, feedback cleanup/retention, and managed
  lifecycle hold the shared migration advisory lock from exact-manifest
  validation through bounded mutation. Migration holds the exclusive form,
  removing the prior check-then-mutate schema race.
- Restore smoke selects an immutable engine-specific manifest. TimescaleDB uses
  the canonical initial migration; standard PostgreSQL uses the extension-free
  overlay. Unknown engines and cross-engine overrides fail closed.
- Migration application now reads each SQL file as bytes once, hashes those
  exact bytes, decodes them as UTF-8 for execution, and stores the raw-byte
  digest. Validation, readiness, immutable manifest tests, and restore/backup
  contracts use the same byte definition, including CRLF input.
- Retained explicit owner and trigger consistency checks, historical-row
  backfill, orphan classification, incident immutability, and the validated
  two-value trigger constraint.
- Added an immutable-checksum regression for `038`, a manifested-forward-change
  regression for `041`, a fresh complete migration-chain test, and an upgrade
  test that records original `038` before running the repository migration
  runner through `041`.
- Updated direct migration coverage for the pre-041 rejection and post-041
  legacy insert, plus repository coverage proving an explicit `band_sos` write
  is stored consistently with its incident.
- Updated restore smoke to require migration `041` and the nullable expand
  state. The smoke still verifies the validated provenance constraint and
  enabled consistency trigger.
- Moved the feedback bucket lifecycle deletion rule to
  `feedback_retention_days + 1`. The lifecycle worker remains responsible for
  exact `retained_until` deletion; the bucket rule is only a later fallback.
- Updated the migration manifest, focused OpenTofu/static assertions, and the
  two retention-contract documents.

## Data, privacy, and medical truth

- Schema or migration impact: migrations `038` and `041` remain byte-identical.
  Finalized migration `041` relaxes the quota trigger column to nullable during
  the expand window while normal and legacy inserts are populated and validated
  by a `BEFORE` trigger; it also strengthens immutable incident provenance. A
  fresh runner applies `038` and `041` under one transaction boundary. An
  installation with recorded `038` applies pending `041` under a drained,
  `ACCESS EXCLUSIVE`-locked transaction.
- Existing-data retention impact: existing quota rows retain their backfilled
  trigger. Feedback exact deletion remains unchanged; only the independent
  bucket fallback moves one day later.
- Source/provenance or formula impact: no health formula change.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: direct
  PostgreSQL state/SQLSTATE assertions, exact manifest equality, Cloud Run job
  exit state, and existing lifecycle operational events. Manifest rejection is
  exposed as the fixed `MigrationManifestMismatchError` failure category; no
  database value or exception text is emitted by lifecycle events.
- Why existing evidence is sufficient, or why new evidence is required: the
  standalone lifecycle commands already had bounded begin/failure events. The
  API's embedded lifecycle startup lacked an equivalent rejection signal, so
  the exact-manifest gate adds one fixed-category event before closing the pool.
- Existing evidence reused: migration checksums, repository integration tests,
  lifecycle-worker state, and static deployment-contract tests.
- New bounded events or operation spans: `runtime.startup` records only
  `service=noop-api`, `outcome=rejected`, severity, and exception class. The
  focused lifespan test proves the private exception message is absent.
- Redaction, retention, and high-frequency controls: tests use generated
  synthetic UUIDs and no payload or health data.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: no deployed migration, bucket lifecycle execution, or
  real-data path is exercised.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Migration, readiness, and concurrency tests | 11 passed | Original `038` and finalized `041` remain byte-identical; the fresh compatibility bundle precedes `039`/`040`; an existing `038` upgrade applies pending `041`; readiness and the runner reject a forward image; the migration job post-checks exact equality; CRLF application stores the raw-byte digest; and concurrent quota/incident provenance cannot diverge | A production rollout or concurrent live-service deployment |
| Lifecycle fail-closed tests | 29 passed across managed lifecycle, feedback lifecycle, and retention scheduler files | Both standalone mutation-capable jobs reject a stale/forward manifest before constructing mutating dependencies; the API gate rejects it before embedded tasks; and existing bounded result/failure behavior remains intact | Cloud scheduler execution, provider access, or deployed job IAM |
| Direct Safety migration tests | 3 passed | Original `038` rejects the omitted field, finalized `041` enables the compatibility insert, and provenance mismatch/orphan behavior remains enforced | Provider delivery, physical-band input, or public traffic |
| Feedback migration tests | 4 passed | The adjacent feedback schema remains compatible with the non-lexical Safety compatibility bundle | Public feedback ingestion or real-data retention |
| Backup and deployment contracts | 26 passed | The immutable manifest, backup contract, and deployment/readiness controls remain coherent with the current-manifest rollback rule | An encrypted TimescaleDB restore drill or deployed rollback |
| Fresh review regression matrix | 61 tests passed on separate clean general and PostgreSQL-overlay databases | Engine-specific restore selection, lifespan cleanup, maintenance-lock ordering, and lifecycle fail-closed behavior work together | Hosted containers or cloud IAM |
| Complete server suite | 569 passed, 1 intentional real-provider/environment skip on separate freshly recreated general and PostgreSQL-overlay databases | API, migration, lifecycle, ownership, Safety, feedback, tenancy, backup, and deployment contracts pass without cross-engine ledger contamination | Hosted CI, provider delivery, or deployed services |
| Formatting, dependencies, and integrity | Ruff format/check passed for 80 files; Python compilation and backup shell syntax passed; both locked dependency audits found no known vulnerabilities; both 41-entry raw-byte manifests matched; `git diff --check` passed | Source is formatted, dependency-scanned, and correctly manifested | Container execution |
| OpenTofu source tests | Validation and 12 tests passed | Feedback/ownership defaults, retention bounds, public-ingress guards, and migration-image separation remain intact | Cloud plan/apply or live IAM |
| Corrected test invocations | The first new PostgreSQL fixture reused an uncast timestamp parameter in interval arithmetic; asyncpg rejected the ambiguous type. Explicit `timestamptz` casts fixed only the fixture, and the unchanged 8-case matrix then passed. A final direct-integration invocation initially set only `NOOP_TEST_POSTGRESQL_DATABASE_URL`, so its 3 cases skipped; rerunning with that file's required `NOOP_TEST_DATABASE_URL` produced 3 passes. In this follow-up, the first complete suite found that the new unknown-version test used unqualified `to_regclass('devices')`, which legitimately resolved the existing `public.devices` table after earlier tests. Qualifying the generated isolated schema corrected only the assertion; the failed test then passed and the clean complete suite passed. Earlier OpenTofu and manifest invocation corrections remain recorded. | Failed setup attempts remain visible rather than being rewritten as product failures | Deployment evidence |
| Operations-record validation | The changed round passes its required headings/privacy checks and is already linked from `INDEX.md`; the repository-wide validator remains blocked by two pre-existing untracked Android round records that are not indexed | This server record is structurally and privacy-valid without modifying concurrent documentation | Repository-wide operations-index completeness for the unrelated Android rounds |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no real or shared data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all; not applicable to this server/infra correction

## Git and release state

- Changed paths in this follow-up: migration repository/readiness, migration
  command, managed and feedback lifecycle commands, API lifecycle startup gate,
  their focused tests, the two server runbooks, and this existing round record.
  Migrations `038` and `041`, the migration manifest, Android, `ACTIVE.md`, and
  `rounds/INDEX.md` have no follow-up diff.
- Commits: commit containing this record
- Branch and remote state: local PR branch; push prohibited for this round
- Repository visibility verified: not changed
- Version/build impact: no app or API version change
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: published migrations are immutable.
  Compatibility migrations may form an explicit dependency-ordered atomic
  bundle for fresh installation when numeric adjacency cannot prevent a
  committed incompatible state. An already-applied prerequisite is validated
  but never rerun; its compatibility upgrade requires maintenance drain and
  explicit locking. Database-backed rollback uses a current-manifest code
  revert unless an older image is separately proven compatible. Exact feedback
  deletion belongs to the lifecycle worker and bucket lifecycle is a later
  safety ceiling.
- Decision-log entry: `D-058`.

## Open risks and honest limitations

- No shared or production database was inspected or migrated. The upgrade proof
  used an extension-free disposable PostgreSQL 16 cluster, not the hosted
  TimescaleDB/PostgreSQL image.
- The maintenance contract requires API admission and in-flight writes to be
  drained before migration. No live orchestrator or load-balancer drain was
  exercised.
- Cloud lifecycle execution is asynchronous and was not applied or observed.
- Docker is not installed on this host, so Compose rendering, image builds,
  encrypted backup execution, and the disposable container restore drill remain
  delegated to the required hosted server workflow.
- Hosted CI and protected PR integration remain outside this no-push round.

## Next round

1. Review and integrate the local commit into pull request `#15`, then run the
   required exact-head hosted checks without bypassing protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
