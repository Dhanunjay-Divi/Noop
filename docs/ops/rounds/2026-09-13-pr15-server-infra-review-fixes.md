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

Close two exact-head review findings without deploying or touching real data:
preserve migration-first and rollback compatibility for the prior Safety writer
without mutating migration `038`, and make the feedback bucket lifecycle rule a
later safety ceiling than the exact `retained_until` deletion owned by the
lifecycle worker.

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
  This supports the pre-038 writer after migration-first rollout or application
  rollback without inventing a default.
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

- Schema or migration impact: migration `038` is unchanged. Migration `041`
  relaxes the quota trigger column to nullable during the expand window while
  normal and legacy inserts are populated and validated by a `BEFORE` trigger.
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
| Immutable and forward migration tests | 4 passed | Original `038` bytes and manifest hash are fixed; `041` is manifested; a fresh complete chain accepts the prior writer; and a database with original `038` already recorded upgrades through `041` | A production rollout or concurrent live-service deployment |
| Direct migration and repository tests | 5 passed | Original `038` rejects the omitted field, `041` enables the compatibility insert, provenance mismatch/orphan behavior remains enforced, and the current repository persists explicit `band_sos` provenance | Provider delivery, physical-band input, or public traffic |
| Backup and restore contracts | 7 passed, plus direct read-only restore smoke | The manifest, required migration set, nullable expand state, constraints, triggers, and restored application contract remain coherent | An encrypted TimescaleDB restore drill |
| OpenTofu | `fmt -check`, `validate`, and 8 lifecycle plan tests passed | Default-off feedback infrastructure plans a 29-day bucket backstop for the 28-day exact worker retention and retains all admission/drain gates | Apply behavior or Cloud Storage deletion timing |
| Formatting and integrity | Ruff format/check passed for 3 touched Python files; all 41 migration checksums passed; scoped `git diff --check` passed | Touched source is formatted and immutable/forward migrations are correctly manifested | Hosted CI |
| Corrected test invocations | The first new PostgreSQL fixture reused an uncast timestamp parameter in interval arithmetic; asyncpg rejected the ambiguous type. Explicit `timestamptz` casts fixed only the fixture, and the unchanged 8-case matrix then passed. Earlier OpenTofu and manifest invocation corrections remain recorded. | Failed setup attempts remain visible rather than being rewritten as product failures | Deployment evidence |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no real or shared data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all; not applicable to this server/infra correction

## Git and release state

- Changed paths: restored migration `038`; new migration `041`; migration
  manifest; restore smoke; migration, repository, and backup tests; feedback GCP
  lifecycle source/tests and retention docs from the prior slice; this
  operations record, index, and active handoff
- Commits: commit containing this record
- Branch and remote state: local PR branch; push prohibited for this round
- Repository visibility verified: not changed
- Version/build impact: no app or API version change
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: published migrations are immutable.
  Schema expansion must remain compatible with the prior writer through a new
  forward migration until a separate contract migration is safe; exact feedback
  deletion belongs to the lifecycle worker and bucket lifecycle is a later
  safety ceiling.
- Decision-log entry: none expected.

## Open risks and honest limitations

- No shared or production database was inspected or migrated. The upgrade proof
  used an extension-free disposable PostgreSQL 14 cluster, not the hosted
  TimescaleDB/PostgreSQL image.
- Cloud lifecycle execution is asynchronous and was not applied or observed.
- Hosted CI and protected PR integration remain outside this no-push round.

## Next round

1. Review and integrate the local commit into pull request `#15`, then run the
   required exact-head hosted checks without bypassing protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
