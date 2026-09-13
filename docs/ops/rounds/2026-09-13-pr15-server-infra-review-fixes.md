# Round: 2026-09-13 - PR 15 server and infrastructure review fixes

## Status

- State: `completed`
- Owner: project team
- Branch: `codex/pr15-server-infra-review-fixes-20260913`
- Start commit: `0aa7c86c2350e4bc3596faac994d7865a37d1660`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close two exact-head review findings without deploying or touching real data:
keep migration `038` compatible with a migration-first rollout while the prior
Safety writer omits quota-event trigger, and make the feedback bucket lifecycle
rule a later safety ceiling than the exact `retained_until` deletion owned by
the lifecycle worker.

## Scope

### In scope

- Migration `038` expand-window trigger derivation and provenance enforcement.
- PostgreSQL migration and managed Safety repository regression tests.
- Feedback-bucket lifecycle ceiling, focused OpenTofu/static tests, and narrow
  retention-contract documentation.

### Non-goals

- Deploying infrastructure, running migrations against shared or real data, or
  enabling public traffic.
- Changing Safety admission, quota amounts, health behavior, feedback payloads,
  or lifecycle-worker deletion semantics.

## Starting evidence

- Migration `038` sets `managed_safety_page_quota_events.trigger` `NOT NULL`
  while the pre-038 Safety writer omits that column.
- The migration trigger returns an omitted trigger unchanged, so a
  migration-first deployment rejects the legacy insert.
- The feedback bucket lifecycle currently uses the exact configured retention
  day count rather than a later backstop.
- Physical devices, deployed services, provider behavior, and real data are
  outside this source-only round.

## Delivered

- Kept `managed_safety_page_quota_events.trigger` nullable through the expand
  window instead of contracting it in migration `038`.
- Changed the quota provenance trigger to derive an omitted trigger from the
  referenced incident. This supports the pre-038 writer after migration-first
  rollout or application rollback without inventing a default.
- Retained explicit owner and trigger consistency checks, historical-row
  backfill, orphan classification, incident immutability, and the validated
  two-value trigger constraint.
- Added direct migration coverage for nullable schema state and a legacy insert
  that omits `trigger`, plus repository coverage proving an explicit
  `band_sos` write is stored consistently with its incident.
- Moved the feedback bucket lifecycle deletion rule to
  `feedback_retention_days + 1`. The lifecycle worker remains responsible for
  exact `retained_until` deletion; the bucket rule is only a later fallback.
- Updated the migration manifest, focused OpenTofu/static assertions, and the
  two retention-contract documents.

## Data, privacy, and medical truth

- Schema or migration impact: migration `038` remains an expand migration; its
  new quota trigger column is nullable while normal inserts are populated and
  validated by a `BEFORE` trigger.
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
| Focused migration tests | 3 passed | Migration `038` backfills history, leaves the new column nullable, derives a legacy omitted trigger, rejects inconsistent provenance, classifies retained orphan rows, and aborts mismatched preexisting ownership | A previously deployed old checksum or production rollout |
| Managed Safety repository test | 1 passed against a disposable standard-PostgreSQL database | The current repository and complete migration chain persist `band_sos` quota provenance consistently | Provider delivery, physical-band input, or public traffic |
| Backup and deployment contracts | 20 passed | Migration manifest, restore contract, and GCP static deployment boundaries remain coherent | A deployed restore or cloud lifecycle execution |
| OpenTofu | `fmt -check`, `validate`, and 8 lifecycle plan tests passed | Default-off feedback infrastructure plans a 29-day bucket backstop for the 28-day exact worker retention and retains all admission/drain gates | Apply behavior or Cloud Storage deletion timing |
| Formatting and integrity | Ruff format/check passed for 3 touched Python files; all 40 migration checksums passed; `git diff --check` passed | Touched source is formatted and the revised migration is correctly manifested | Hosted CI |
| Corrected test invocations | The first OpenTofu assertion used invalid direct indexing into a provider set, and the first manual manifest check ran from the wrong directory; both were corrected and the authoritative reruns passed | Failed setup attempts remain visible rather than being rewritten as product failures | Deployment evidence |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no real or shared data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all; not applicable to this server/infra correction

## Git and release state

- Changed paths: migration `038`, its manifest and migration/repository tests;
  feedback GCP lifecycle source/tests and retention docs; this operations record,
  index, and active handoff
- Commits: commit containing this record
- Branch and remote state: local PR branch; push prohibited for this round
- Repository visibility verified: not changed
- Version/build impact: no app or API version change
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: schema expansion must remain compatible
  with the prior writer until a separate contract migration is safe; exact
  feedback deletion belongs to the lifecycle worker and bucket lifecycle is a
  later safety ceiling.
- Decision-log entry: none expected.

## Open risks and honest limitations

- If migration `038` from the prior checksum was applied to any persistent
  environment, that environment must not accept this rewritten checksum
  silently; it requires an explicit reconciliation plan. No deployment was
  performed in this round.
- Cloud lifecycle execution is asynchronous and was not applied or observed.
- Hosted CI and protected PR integration remain outside this no-push round.

## Next round

1. Review and integrate the local commit into pull request `#15`, then run the
   required exact-head hosted checks without bypassing protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
