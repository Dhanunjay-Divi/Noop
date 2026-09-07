# Metric reprocessing and rollback

**Status:** source-defined release contract. Production execution still
requires an approved, commit-bound metric manifest and evidence from the exact
release candidate.

This policy applies whenever NOOP recomputes, republishes, backfills, repairs,
or rolls back a derived wellness metric. It covers Apple, Android, local
history, imports, managed backup/restore, and any future server-side
reprocessing. It does not authorize a new health claim or substitute for
sensor, participant, subgroup, or physical-device validation.

## Invariants

- Raw sensor samples, imported source values, user-authored records, source
  identity, and source timestamps are evidence. Reprocessing must not overwrite
  or relabel them.
- Every derived value is bound to an explicit algorithm, importer, calibration,
  dependency, unit, and local-day-bucketing revision as applicable.
- A calibration model is presentation-only. It never becomes an input to the
  raw formula and is invalid when its metric, source, algorithm revision,
  provenance, or held-out evidence no longer matches.
- Missing, stale, malformed, non-finite, unsupported, or ambiguously sourced
  input fails closed. The result is unavailable, not guessed or carried
  forward.
- One logical date/range has one atomic publication outcome. Related daily,
  series, calendar, Coach, notification, export, and trend surfaces must not
  observe a mixed revision.
- A watermark, completion marker, source manifest, or cloud acknowledgement is
  written only after every required value commits and the post-commit receipt
  matches the requested range.
- Rollback never means destructive schema downgrade, deletion of raw evidence,
  or changing a revision label on stale values.

## Reprocessing workflow

1. Record the reason, owner, source commit, metric revisions, affected source
   classes, exact date/account range, expected dependencies, and rollback
   target.
2. Freeze a deterministic input snapshot or immutable source generation.
   Validate source identity, canonical dates, units, quality flags, duplicate
   ownership, clock alignment, and range bounds before any mutation.
3. For a broad reprocess, require a verified backup/restore point, free-space
   budget, batch and transaction limits, cancellation behavior, and a dry run
   that writes candidate output separately from published output.
4. Compare the candidate with the current revision using bounded aggregate
   evidence: requested/published/missing counts, coverage, range violations,
   non-finite counts, provenance/revision distribution, and approved
   statistical acceptance criteria. Diagnostics must not contain biometric
   values, account/device identifiers, user text, credentials, or arbitrary
   database errors.
5. Publish the complete date/range atomically. The commit must replace only
   the managed derived keys owned by that metric revision and leave raw,
   official reference, and unrelated user-authored values untouched.
6. Read back an exact post-commit receipt. Only then advance the analysis
   watermark, stamp an import manifest, acknowledge a managed generation, or
   prune eligible local data.
7. Observe bounded success, retry, rejection, cancellation, and failure
   counts. Reprocessing must be idempotent and resumable from the last verified
   batch, not from an assumed in-memory position.

Large account/server jobs must use account-isolated bounded batches, leases,
idempotency keys, and concurrency limits. A failed batch cannot authorize
later batches to publish or local data to prune.

## Rollback workflow

1. Stop new publication for the affected revision and disable any dependent
   notification or coaching claim that cannot be supported by the remaining
   data.
2. Preserve the failed candidate, bounded receipts, and immutable inputs long
   enough for diagnosis under the applicable retention policy.
3. Atomically republish a previously approved derived revision from the same
   immutable inputs, or mark the metric unavailable. Never display stale data
   under the reverted revision.
4. Invalidate personal calibration models and caches whose source,
   dependencies, or revisions no longer match. Recompute them only after the
   raw rollback result has committed.
5. If storage integrity, migration, or publication atomicity is uncertain,
   restore the exact pre-operation backup into a separate location, run
   integrity and retained-content verification, and replace the live store
   only through the approved restore path.
6. Re-run dependency, calendar, Coach, notification, export, trend, and
   cross-platform parity checks before re-enabling the metric.

## Release evidence

The exact release manifest must identify:

- source commit and build;
- metric, importer, calibration, dependency, and bucketing revisions;
- supported source/device/firmware classes;
- required inputs, missing-data behavior, units, and output bounds;
- validation report and known limitations;
- reprocessing range, dry-run comparison, atomic receipt, and rollback target;
- tests for preflight rejection, late-write rollback, large ranges,
  interruption/resume, duplicate execution, restore, and stale-revision
  invalidation.

Current source implements the atomic score-window and revision-bound
calibration parts in `Packages/WhoopStore`,
`Packages/StrandAnalytics`, `Strand/Data/IntelligenceEngine.swift`, and the
corresponding Android analytics/repository code. Physical sensor validation,
population accuracy, and a signed final metric manifest remain separate
release gates.
