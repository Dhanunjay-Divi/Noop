# Round: 2026-09-13 - Android post-backfill retry hardening

## Status

- State: `implementation, fresh cross-review, focused/API 35 verification, and
  complete Android wall complete; commit, hosted checks, and protected
  integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `3ab2852e445282500ca2ca74a3768e8d1fca6364`
- End implementation commit:
- Record commit or PR: pull request `#15`

## Objective

Close the remaining deferred post-backfill analysis review findings without
changing metric formulas: WorkManager enqueue/cancel completion must be
verified before success is reported, cancellation must return the owned
revision to durable work, only one future boundary may remain scheduled, clock
changes must reconcile that boundary, and deferred work must respect battery
and storage constraints.

## Scope

### In scope

- Android post-backfill latch ownership and cancellation.
- Durable WorkManager schedule state, deduplication, replacement, and
  time-change reconciliation.
- Battery-not-low and storage-not-low constraints.
- Fixed-category local diagnostics and deterministic Full/Demo tests.

### Non-goals

- Metric formulas, analysis windows, Apple behavior, database schema, or UI.
- Claiming exact WorkManager timing, process recreation, OEM broadcasts, or BLE
  behavior without physical execution.

## Starting evidence

- Reproduction or observed symptom: exact-tree review found asynchronous
  enqueue reported as success before completion, WorkManager cancellation did
  not own/cancel the application-scope analysis, stale unique chains could
  accumulate, and deferred work had no battery/storage guard.
- Relevant source/device/OS/firmware class: Android WorkManager and coroutine
  source; no hardware dependency for deterministic ownership tests.
- Existing tests, logs, exports, screenshots, or documents:
  `BackfillAnalysisRevisionLatchTest`,
  `PostBackfillAnalysisRetryPolicyTest`, and fixed-category
  `analysis.post_backfill_retry` diagnostics.
- Unknowns that must remain unknown until measured: OS process recreation,
  broadcast delivery, OEM scheduling latency, BLE collection, and battery
  impact.

## Delivered

- Awaited WorkManager enqueue and cancellation operations before reporting a
  durable schedule transition.
- Bound scheduler-owned analysis to the WorkManager coroutine and requeued the
  in-flight revision on cancellation or retryable caller-owned failure.
- Added one persisted next-boundary record with stale-state repair,
  deduplication, replacement, and clock/time-zone reconciliation.
- Added battery-not-low and storage-not-low constraints.
- Added focused cancellation, schedule-failure, marker-retention,
  deduplication, rescheduling, enqueue-failure, and constraint tests.
- Rejects legacy or incomplete WorkManager requests before resolving
  `NoopApplication`, opening Room, or touching BLE. Only a complete v2 request
  may enter scheduler coordination or analysis.
- Updated the durable-analysis source contract to require the stable v2 unique
  work name and `ExistingWorkPolicy.REPLACE`, while explicitly rejecting the
  superseded append-chain policy.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: deferred dirty revisions remain pending until
  analysis completes or a replacement worker owns them.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure:
  `analysis.post_backfill_retry` records fixed scheduled, deduplicated,
  rescheduled, cleared, failed, start-state-retry, and worker outcome
  categories.
- Why existing evidence is sufficient, or why new evidence is required: the
  schedule boundary needs lifecycle outcomes, but no dynamic boundary, work ID,
  source, device, timestamp, or exception text is required.
- Existing evidence reused: `AppDiagnosticsRecorder` worker operation span.
- New bounded events or operation spans: fixed coordinator outcomes only.
- Redaction, retention, and high-frequency controls: no health values, source
  identifiers, work IDs, planned times, or arbitrary errors; one event per
  schedule/worker transition.
- Cross-platform/backend correlation: not applicable; this is an
  Android-specific scheduler implementation.
- Remaining blind spots: physical WorkManager and broadcast behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Full and Demo focused JVM matrix | The combined restore/retry matrix executed 124 tests per variant with zero failures/errors/skips. The retry slice contains 52 tests per variant. | Latch cancellation, caller takeover, retry ownership, atomic replacement, partial-state recovery, stale/legacy rejection before app/BLE access, source-read failure, clock reconciliation, constraints, and the single-boundary contract | OEM scheduling or physical BLE behavior |
| API 35 WorkManager execution | 2 retry tests passed inside the 6-test managed-device matrix | Real WorkManager accepts v2 work, rejects legacy work, and replaces/rearms from inside a running worker | OEM background policy or physical BLE collection |
| Complete Android wall | Full and Demo each executed 4,675 unit tests with seven intentional skips and zero failures/errors; both lint variants, APK assemblies, and instrumentation compilations passed in 137 Gradle tasks | The correction integrates with the complete Android graph | Signed-device behavior |
| Diff and stale-API checks | `git diff --check` passed; no BLE source/test reference to removed `workName` | Scoped source integrity and test migration | Hosted CI |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local JVM/build environment only
- Data-preservation result: no participant data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: WorkManager process death, time/time-zone broadcasts,
  battery/storage constraints, OEM background policy, and BLE collection

## Git and release state

- Changed paths: Android manifest, post-backfill latch/scheduler/BLE helper,
  three focused BLE test files, the durable-analysis source contract, and this
  round record
- Commits: pending
- Branch and remote state: isolated PR branch; no push during implementation
- Repository visibility verified: unchanged
- Version/build impact: none
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: no global product decision; this applies
  the existing durable-analysis and bounded-observability contracts.
- Decision-log entry: none.

## Open risks and honest limitations

- API 35 covers real WorkManager execution and replacement. Arbitrary process
  death, OEM broadcasts, resource-constraint timing, and wall-clock changes
  still need representative physical-device evidence.
- BLE hardware behavior was not exercised.

## Next round

1. Commit with the restore correction, push once after the repository wall,
   require fresh exact-SHA hosted checks, and integrate only through protected
   pull request `#15`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
