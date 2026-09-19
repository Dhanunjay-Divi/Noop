# Round: 2026-09-18 - Managed history portability

## Status

- State: `implemented and exact-current local verification complete; live and physical evidence pending`
- Owner: project team
- Branch: `codex/managed-history-portability-20260918`
- Start commit: `b688b3b725cd497e96a31b28540a219bf50446e1`
- End implementation commit: `57df5cdf`
- Record commit or PR: integrated into the September 17 readiness candidate;
  protected review remains pending

## Objective

Complete the code-verifiable managed-history portability blocker on Apple and
Android without making managed cloud authoritative. A managed-history archive
must carry a versioned integrity manifest, export from a durable cursor after
interruption, validate completely before local mutation, import idempotently,
fail closed on identity or revision conflicts, and resume a partially applied
import.

## Scope

### In scope

- Shared Apple and Android managed-history manifest, checksum, export cursor,
  import cursor, and result contracts.
- Resumable managed snapshot export and private staged archive entries.
- Validated archive import through the existing local managed restore adapters.
- Focused package, Apple archive, Android archive, export, import, and resume
  tests.
- This feature-specific operations record and directly related contract
  documentation.

### Non-goals

- Cloud-authoritative storage, required accounts, or changes to local-first
  collection, scoring, history, or device control.
- Release documentation, localization, account deletion, navigation, or other
  user-interface changes.
- Production deployment, public enrollment, real health-data transfer, or
  physical-device validation.

## Starting evidence

- Reproduction or observed symptom: export currently creates a new server
  snapshot and streams directly to a new ZIP on every attempt; no durable
  cursor survives interruption and no managed-history importer exists.
- Relevant source/device/OS/firmware class: shared Swift package, Apple app
  archive/service layer, and Android app archive/service layer.
- Existing tests, logs, exports, screenshots, or documents:
  `ManagedHistoryExportTests`,
  `ManagedHistoryArchiveWriterTests`,
  `ManagedHistoryExporterTest`, and `ManagedHistoryZipWriterTest`.
- Unknowns that must remain unknown until measured: live server restore-job
  expiry behavior, large-account transfer performance, platform process-death
  behavior, and production cross-tenant enforcement.

## Delivered

- Version 2 Apple/Android archive manifests with a cross-platform aggregate
  SHA-256, exact entry count, and snapshot cursor while retaining v1 decoding.
- Account-scoped export checkpoints containing restore identity, expiry,
  pagination cursors, selected/delivered totals, manifest records, and server
  completion state.
- Immutable private entry staging with identical replay as a no-op and
  divergent replay as a conflict; final archives publish only after staged
  entry validation and matching server completion.
- Protected staged import archives and manifest-bound import checkpoints.
- Two-pass import that validates the complete archive before any local
  mutation, then applies only through existing local restore adapters and
  checkpoints every successful object.
- Apple and Android managed service wiring with bounded `managed_import`
  diagnostics and resumable `managed_export` fields.
- Focused synthetic tests for v2 integrity, export interruption/expiry,
  prevalidation, import resume/idempotency/conflict, v1 compatibility, archive
  replay, bounded reads, private staging, and checkpoint replacement.
- `docs/MANAGED_HISTORY_PORTABILITY.md` documents the portable format,
  lifecycle, privacy boundary, and external evidence gates.

## Data, privacy, and medical truth

- Schema or migration impact: no health database schema change.
- Existing-data retention impact: import applies only through existing local
  restore transactions and must not delete unrelated local-first history.
- Source/provenance or formula impact: no metric or formula change.
- Permissions/network disclosure impact: no new default network transfer.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded managed export operation span will be retained; import will use a
  matching bounded operation span with only object counts, byte counts, fixed
  phase/outcome, and fixed failure categories.
- Why existing evidence is sufficient, or why new evidence is required:
  export already has bounded lifecycle evidence; import is a new fallible
  boundary and requires equivalent evidence.
- Existing evidence reused: `managed_export`.
- New bounded events or operation spans: `managed_import`; `managed_export`
  adds only a categorical resumed field.
- Redaction, retention, and high-frequency controls: no archive paths, source
  IDs, document IDs, timestamps, payloads, health values, tokens, exception
  messages, or cursor values may enter diagnostics.
- Cross-platform/backend correlation: no new persistent correlation identifier.
- Remaining blind spots: OS process termination and live restore expiry require
  later physical and synthetic-staging evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `git diff --check` | passed before commit | The scoped patch has no whitespace errors | Compilation or runtime behavior |
| `xcrun swiftc -parse` on the changed Swift source files | passed with empty output before the final test/doc edits | Changed Swift production syntax parsed without invoking Xcode build orchestration | Type checking, linking, or the newly authored tests |
| Complete macOS `Strand` suite | 2,142 passed, 1 intentional skip | Shared Apple archive, service, and integration contracts compile and pass with the current source | Physical process death, low storage, or live service behavior |
| Complete Android Full and Demo unit walls | 4,883 tests per variant, 7 skipped, 0 failed after the final stale-expectation correction | Android export/import/archive/service contracts compile and pass in both variants | OEM process death, low storage, or live service behavior |
| API 35 managed-device lanes | 114 production-shell tests passed with 2 private-pilot skips; fresh Review Sample passed 1/1 | Current app packaging and Android runtime shell remain compatible | Production cloud, physical phone, or large archive behavior |
| Swift package/tool wall | all 11 build-and-test pairs passed, including `NoopRemoteSync` | Shared portability packages compile and their focused plus complete tests pass | Live cross-tenant authorization or production expiry |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: synthetic local fixtures only
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: process death during export/import, low storage,
  background suspension, and large real archives

## Git and release state

- Changed paths: shared Swift export/import source and tests; Apple transfer
  writer/service/tests; Android export/import/archive/service source and tests;
  this round, the round index, and the managed-history portability contract.
- Commits: implementation commit `57df5cdf`
- Branch and remote state: implementation is present on the active readiness
  branch; protected push/review remains pending
- Repository visibility verified: not changed
- Version/build impact: none planned
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: managed history remains an optional
  local-first portability path; import never makes cloud state authoritative.
- Decision-log entry: none planned; this completes an already recorded
  portability requirement without changing the local-first product boundary.

## Open risks and honest limitations

- Live managed-service, low-storage, large-account, cross-tenant, and physical
  process-death evidence remain external.

## Next round

1. Exercise live synthetic staging expiry, cancellation/auth refresh,
   cross-tenant isolation, and large-account interruption/resume.
2. Exercise physical process death and low-storage behavior before release.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
