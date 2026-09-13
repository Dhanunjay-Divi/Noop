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
  before the independent `039` and `040` migrations. A prior writer cannot
  observe a committed `038`-only schema.
- The `041` quota trigger now locks the referenced incident while deriving
  provenance, and the incident provenance trigger unconditionally rejects every
  later owner-profile or trigger change. The database no longer depends on
  seeing a concurrently inserted quota row before protecting ownership.
- Kept exact migration-set equality at readiness and documented the consequence:
  rollback uses a forward-built code revert retaining the current immutable
  migration set. An exact older image is not claimed as supported.
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

- Schema or migration impact: migration `038` remains byte-identical. Finalized
  migration `041` relaxes the quota trigger column to nullable during the expand
  window while normal and legacy inserts are populated and validated by a
  `BEFORE` trigger; it also strengthens immutable incident provenance. The
  runner applies `038` and `041` under one transaction boundary.
- Existing-data retention impact: existing quota rows retain their backfilled
  trigger. Feedback exact deletion remains unchanged; only the independent
  bucket fallback moves one day later.
- Source/provenance or formula impact: no health formula change.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: direct
  PostgreSQL state/SQLSTATE assertions and OpenTofu plan assertions.
- Why existing evidence is sufficient, or why new evidence is required: these
  are deterministic database and infrastructure contracts; no runtime event is
  needed for the source-only compatibility correction.
- Existing evidence reused: migration checksums, repository integration tests,
  lifecycle-worker state, and static deployment-contract tests.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: tests use generated
  synthetic UUIDs and no payload or health data.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: no deployed migration, bucket lifecycle execution, or
  real-data path is exercised.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Migration, readiness, and concurrency tests | 8 passed | Original `038` remains byte-identical; finalized `041` has a fixed SHA; the explicit compatibility bundle precedes `039`/`040`; readiness rejects an exact prior image; a prior writer cannot observe a committed `038`-only state; and concurrent quota/incident provenance cannot diverge | A production rollout or concurrent live-service deployment |
| Direct Safety migration tests | 3 passed | Original `038` rejects the omitted field, finalized `041` enables the compatibility insert, and provenance mismatch/orphan behavior remains enforced | Provider delivery, physical-band input, or public traffic |
| Feedback migration tests | 4 passed | The adjacent feedback schema remains compatible with the non-lexical Safety compatibility bundle | Public feedback ingestion or real-data retention |
| Backup and deployment contracts | 26 passed | The immutable manifest, backup contract, and deployment/readiness controls remain coherent with the current-manifest rollback rule | An encrypted TimescaleDB restore drill or deployed rollback |
| Formatting and integrity | Ruff format/check passed for the 2 touched Python files; Python compilation passed; all 41 migration checksums passed; scoped `git diff --check` passed | Touched source is formatted and immutable/forward migrations are correctly manifested | Hosted CI |
| Corrected test invocations | The first new PostgreSQL fixture reused an uncast timestamp parameter in interval arithmetic; asyncpg rejected the ambiguous type. Explicit `timestamptz` casts fixed only the fixture, and the unchanged 8-case matrix then passed. A final direct-integration invocation initially set only `NOOP_TEST_POSTGRESQL_DATABASE_URL`, so its 3 cases skipped; rerunning with that file's required `NOOP_TEST_DATABASE_URL` produced 3 passes. Earlier OpenTofu and manifest invocation corrections remain recorded. | Failed setup attempts remain visible rather than being rewritten as product failures | Deployment evidence |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no real or shared data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all; not applicable to this server/infra correction

## Git and release state

- Changed paths: finalized unpublished migration `041`; migration runner and
  manifest; focused migration/readiness/concurrency tests; server deployment
  and release-control runbooks; this operations record, index, active handoff,
  and decision log. Migration `038` has no diff and was verified at its
  published checksum.
- Commits: commit containing this record
- Branch and remote state: local PR branch; push prohibited for this round
- Repository visibility verified: not changed
- Version/build impact: no app or API version change
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: published migrations are immutable.
  Compatibility migrations may form an explicit dependency-ordered atomic
  bundle when numeric adjacency cannot prevent a committed incompatible state.
  Database-backed rollback uses a current-manifest code revert unless an older
  image is separately proven compatible. Exact feedback deletion belongs to the
  lifecycle worker and bucket lifecycle is a later safety ceiling.
- Decision-log entry: `D-058`.

## Open risks and honest limitations

- No shared or production database was inspected or migrated. The upgrade proof
  used an extension-free disposable PostgreSQL 14 cluster, not the hosted
  TimescaleDB/PostgreSQL image.
- The maintenance contract requires API admission and in-flight writes to be
  drained before migration. No live orchestrator or load-balancer drain was
  exercised.
- Cloud lifecycle execution is asynchronous and was not applied or observed.
- Hosted CI and protected PR integration remain outside this no-push round.

## Next round

1. Review and integrate the local commit into pull request `#15`, then run the
   required exact-head hosted checks without bypassing protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
