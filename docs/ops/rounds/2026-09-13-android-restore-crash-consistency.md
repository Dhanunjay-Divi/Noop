# Round: 2026-09-13 - Android restore crash consistency

## Status

- State: `implementation, fresh cross-review, focused/API 35 verification, and
  complete Android wall complete; commit, hosted checks, and protected
  integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `f7481a11b97a2428e3d70c8afd6ba8705d076785`
- End implementation commit: `fdf04c30`
- Record commit or PR: pull request `#15`

## Objective

Close the remaining Android database-restore review findings without changing
the backup format or touching participant data. A validated replacement
database must have a durable point of no return before any restored preference
is committed; rollback must itself survive process death and cleanup failure;
and best-effort hydration scheduling must not make the health database
unavailable indefinitely.

## Scope

### In scope

- Durable restore finalization, rollback, and cleanup phases.
- Backward-compatible restore-marker parsing.
- Fail-closed recovery when required live or rollback files are missing.
- Best-effort hydration schedule reconciliation after restore.
- Fixed-category local diagnostics and focused Full/Demo tests.

### Non-goals

- Changing the `.noopbak` payload schema or settings whitelist.
- Changing Room schema, health calculations, or user-visible metrics.
- Claiming physical-device, process-kill, storage-failure, or OEM behavior from
  JVM tests.

## Starting evidence

- Reproduction or observed symptom: exact-tree review identified a database and
  restored-preference mismatch window, unrecoverable rollback cleanup, and an
  unbounded startup loop when hydration scheduling fails.
- Relevant source/device/OS/firmware class: Android local Room and
  SharedPreferences restore path; no band or firmware dependency.
- Existing tests, logs, exports, screenshots, or documents:
  `PendingDatabaseRestoreTest`, `BackupSettingsCodecTest`, and fixed-category
  `database.restore_settings` / `database.restore_reconcile` diagnostics.
- Unknowns that must remain unknown until measured: real process death at every
  filesystem boundary, filesystem fault behavior, and physical-device startup
  behavior.

## Delivered

- Added durable `FINALIZING`, `ROLLING_BACK`, and `ROLLED_BACK` phases with
  backward-compatible marker parsing and explicit prior-database/rollback
  checksum metadata.
- Made the finalizing marker the mandatory point of no return before any
  restored SharedPreferences commit. A cold launch after that point accepts
  the migrated live database and retries settings/reconciliation rather than
  reintroducing the previous database.
- Made rollback itself restartable: intent is persisted before file changes,
  the restored previous database is verified by hash and SQLite integrity, the
  terminal marker is persisted before marker-last cleanup, and no-prior-store
  restores verify the live database is absent.
- Added fail-closed resume and terminal-cleanup predicates. Missing,
  mismatched, invalid, or ambiguous rollback evidence cannot replace the live
  database or erase recovery artifacts.
- Read and cache staged settings before `FINALIZING`; made hydration reminder
  reconciliation best-effort so a repairable OS scheduler failure cannot trap
  the accepted health database in an unbounded startup loop.
- A shipped v1 `APPLIED` marker whose replacement was validly migrated by Room
  now resumes irreversible `FINALIZING`; invalid or ambiguous v1 states remain
  fail-closed and preserve recovery artifacts.
- Hydration reconciliation failure persists one private durable retry bit
  before cleanup. Process maintenance waits for Room, retries scheduling,
  clears the bit only after success, and retains it on failure.
- Added fixed rollback categories for metadata, marker, rollback existence,
  checksum/integrity, live restore/integrity, terminal state, and cleanup.
  Checkpoint/copy/hash failures now map to `live_restore`; a copied but invalid
  rollback maps to `rollback_invalid`.
- Added deterministic file-backed JVM phase-machine tests and an API 35
  instrumentation test using real SQLite databases through the public
  cold-open path.

## Data, privacy, and medical truth

- Schema or migration impact: none expected.
- Existing-data retention impact: restore must preserve either the fully
  accepted replacement or the verified previous database across every durable
  phase.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none; restore remains local.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: fixed restore
  completion, finalization-pending, rollback, and cleanup-pending outcomes.
- Why existing evidence is sufficient, or why new evidence is required:
  rollback cleanup needs an explicit fixed outcome because the app may continue
  on the restored previous database while artifact cleanup remains pending.
- Existing evidence reused: `AppDiagnosticsRecorder` restore and scheduler
  events.
- New bounded events or operation spans: fixed
  `database.restore_settings`, `database.restore_reconcile`, and
  `database.restore_rollback` outcomes and failure kinds only.
- Redaction, retention, and high-frequency controls: no paths, hashes, health
  values, settings, identifiers, timestamps, or exception messages.
- Cross-platform/backend correlation: not applicable; this closes an
  Android-specific Room restore implementation defect.
- Remaining blind spots: physical process-death and filesystem fault injection.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Full and Demo focused JVM matrix | 72 restore tests per variant, zero failures/errors/skips, inside the 124-test combined matrix | Durable phases, v1 compatibility, point-of-no-return ordering, rollback evidence, crash-resume states, cleanup, and hydration retry | Power-loss or filesystem guarantees |
| API 35 real-SQLite restore tests | 4 restore tests passed inside the 6-test managed-device matrix | Public cold-open, checkpoint/copy, invalid rollback rejection, restart, and finalization use real SQLite | Low-storage or OEM filesystem guarantees |
| Complete Android wall | Full and Demo each executed 4,675 unit tests with seven intentional skips and zero failures/errors; both lint variants, APK assemblies, and instrumentation compilations passed in 137 Gradle tasks | The state machine integrates with the complete Android graph | Signed physical-device startup |
| Full and Demo instrumentation compilation | Passed | The real-SQLite test and production restore graph compile for both variants | Signed physical-device startup |
| Diff integrity | `git diff --check` passed | Edited source and tests contain no whitespace errors | Hosted CI |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local JVM/build environment only
- Data-preservation result: no participant data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical process death, low-storage restore, OEM
  filesystem behavior, and signed-device startup

## Git and release state

- Changed paths: `PendingDatabaseRestore.kt`, `WhoopDatabase.kt`,
  `BackupSettings.kt`, their focused JVM tests, the real-SQLite instrumentation
  test, and this round record
- Commits: pending
- Branch and remote state: isolated PR branch; no push during implementation
- Repository visibility verified: unchanged
- Version/build impact: none expected
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: restored preferences may become durable
  only after the database is irreversibly accepted; rollback and cleanup are
  explicit restartable state-machine phases.
- Decision-log entry: none expected.

## Open risks and honest limitations

- Exact marker/file crash states are modeled in deterministic filesystem tests
  and the normal existing-database path runs against real SQLite on API 35.
  Physical process kill, power-loss, low-storage, and filesystem fault
  injection remain required before claiming device-level proof.

## Next round

1. Commit with the retry correction, push once after the repository wall,
   require fresh exact-SHA hosted checks, and integrate only through protected
   pull request `#15`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
