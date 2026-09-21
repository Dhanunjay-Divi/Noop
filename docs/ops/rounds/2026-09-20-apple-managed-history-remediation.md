# Round: 2026-09-20 - Apple managed history remediation

## Status

- State: `implementation and complete local verification finished; consolidated integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `3edddda180963444b8eb8caa48e5298623cd66f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`; consolidated implementation commit
  and replacement push pending

## Objective

Remediate the confirmed Apple managed-sync and managed-history defects without
changing the concurrent dirty files owned by other work. Expose the existing
managed-history importer through shipped NOOP+ UI; fence account transitions;
preserve clean local preference state until managed apply commits; bound archive
enumeration and checkpoint storage; retain unacknowledged ciphertext; and add
ownership-deletion localization parity. Add focused tests and commit the
verified slice locally without pushing.

## Scope

### In scope

- Apple NOOP+ managed-history import selection, progress, completion, failure,
  and retry UI.
- Apple managed-account transition cancellation/fencing.
- Swift managed preference apply semantics.
- Apple archive entry enumeration, export checkpoint storage, and outgoing
  encrypted-document retention.
- Apple ownership-deletion localization catalog coverage.
- Focused package and app contract tests plus bounded verification.

### Non-goals

- Changes to the already dirty managed importer implementation, runtime-role,
  BLE, intelligence-engine, or their concurrent tests.
- Android, server, infrastructure, deployment, protected-branch integration,
  or production enablement.
- Physical-device, low-storage, process-death, live-service, BLE, notification,
  or physiological validation.

## Starting evidence

- Reproduction or observed symptom: pull-request review identified that the
  existing managed importer is not reachable from shipped UI; account rebinding
  can race canceled sync; remote preference apply can dirty local defaults;
  archive enumeration and checkpoint storage have fixed-size failure modes;
  unacknowledged ciphertext can be swept; and Apple deletion copy lacks locale
  parity.
- Relevant source/device/OS/firmware class: shared Swift package, Apple app
  managed-service layer, and iOS NOOP+ SwiftUI surface.
- Existing tests, logs, exports, screenshots, or documents:
  `ManagedHistoryExportTests`, `WhoopManagedSyncAdapterTests`,
  `ManagedHistoryArchiveWriterTests`, managed-service source contracts, and the
  September 18 portability round.
- Unknowns that must remain unknown until measured: real archive scale,
  low-storage behavior, process termination, signed-device document picking,
  live managed-service behavior, and physical accessibility.

## Delivered

- Exposed explicit complete cloud-history import with cancelable progress,
  complete prevalidation, resumable idempotent apply, and truthful completion
  or retry state.
- Fenced sync, import, Friends, Safety, and document-profile work across account
  transitions and awaited old account work before rebinding.
- Added the preference-specific managed document adapter so durable revision
  acceptance precedes one MainActor preference commit and account-fence
  validation.
- Bounded archive enumeration, retained authenticated large checkpoints, and
  reconciled ciphertext only after durable generations no longer reference it.
- Completed the managed-history and account-deletion localization contracts.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: the change must retain unacknowledged
  ciphertext and must not delete or overwrite local history by default.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: import remains an explicit user
  action inside separately consented NOOP+.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: reuse bounded
  `managed_import` and `managed_export` lifecycle evidence; UI exposes fixed
  selecting, validating/importing, completed, and retryable-failure states.
- Why existing evidence is sufficient, or why new evidence is required:
  importer/service evidence already records bounded outcome and counts; the
  missing boundary is truthful customer-visible state rather than payload
  logging.
- Existing evidence reused: `managed_import`, `managed_export`, managed-sync
  fixed outcome fields.
- New bounded events or operation spans: none planned unless source inspection
  proves an uncovered lifecycle transition.
- Redaction, retention, and high-frequency controls: no archive path, file
  name, account/source/document identity, payload, health value, token, cursor,
  timestamp, or exception text enters diagnostics.
- Cross-platform/backend correlation: none added.
- Remaining blind spots: OS document-picker cancellation and process death are
  not operator-correlated.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot and dirty-path review | passed | Work resumed in the intended isolated branch and excluded concurrent paths are known | Product correctness |
| Exact-current Swift package walls | `NoopRemoteSync` 188/188 and `WhoopStore` 539/539 passed | Shared managed history, encrypted document, account, Friends, Safety, retention, and metric-storage contracts pass together | App lifecycle, OS document picking, live service, or physical-device behavior |
| Focused Apple managed-document rerun | 11/11 passed | Immutable actor capture, account-scope cleanup, preference commit ordering, deletion purge fallback, and current source-shape contracts pass | Complete app regression or physical behavior |
| Exact-current complete macOS wall | 2,207 passed, 1 intentional skip, 0 failures | Shared Apple app and contract source passes with the final adapter and account/history lifecycle integrated | Signed distribution, iOS background behavior, BLE, or physical-device behavior |
| Exact-current unsigned Release iOS graph | succeeded with zero compiler errors and zero `ManagedCloudService.swift` warnings; Watch, complications, and widget extensions embedded | The final iPhone, Watch, widget, account, managed-history, and Friends graph compiles together after the Swift concurrency correction | Signing, App Store distribution, document-picker interruption, low storage, background suspension, or live service access |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: synthetic package and app tests prove fail-closed
  prevalidation, revision-monotonic apply, resumable import, and retained local
  state on rejection
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: signed-device document picker, interruption, low
  storage, background suspension, and large real archives

## Git and release state

- Changed paths: shared managed-history/document packages, Apple managed
  service/UI/adapter, package and app tests, localization, and this record
- Commits: pending
- Branch and remote state: local branch tracks its existing remote; one
  consolidated replacement push to pull request `#16` remains
- Repository visibility verified: not changed
- Version/build impact: none planned
- Release or distribution impact: source remediation only

## Decisions

- Durable decision added or changed: none planned; this enforces existing
  portability, retention, consent, and account-isolation contracts.
- Decision-log entry: none planned

## Open risks and honest limitations

- Signed-device document picker, process-death recovery, low-storage behavior,
  live App Check/service access, and large real archives remain external.

## Next round

1. Integrate only after the consolidated commit passes the required hosted
   exact-SHA checks.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
