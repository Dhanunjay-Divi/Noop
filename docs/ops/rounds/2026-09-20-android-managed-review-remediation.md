# Round: 2026-09-20 - Android managed review remediation

## Status

- State: `implementation and complete local verification finished; consolidated integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `3edddda180963444b8eb8caa48e5298623cd66f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`; consolidated implementation commit
  and replacement push pending

## Objective

Close six confirmed Android managed-cloud review defects without changing
Apple or server source:

- preserve generic retry/failure semantics when a scheduler batch contains
  both retryable and unexpected failures;
- preserve and recover legacy v1 managed-account scope across disconnect and
  re-enrollment;
- reject an archive whose entry count exceeds the bound before materializing
  the complete ZIP entry list;
- support valid large export checkpoints without a fixed 8 MiB ceiling while
  retaining bounded authenticated persistence;
- never age- or quota-evict unacknowledged outgoing ciphertext; and
- complete ownership-deletion localization for Italian, Russian, and
  Traditional Chinese with locale-audit parity.

Success requires focused regression coverage for Full and Demo where the
variant applies, practical bounded compile/test evidence, a local commit, no
push, and preservation of unrelated dirty Apple work.

## Scope

### In scope

- Android managed scheduling, account-scope compatibility, archive validation,
  export-checkpoint persistence, ciphertext retention, localization resources,
  tests, and directly related operations documentation.

### Non-goals

- Apple or server implementation.
- Production deployment, provider traffic, managed enrollment, or real health
  transfer.
- Physical-device, BLE, notification, battery, or physiological validation.

## Starting evidence

- Reproduction or observed symptom: protected-review findings identify the six
  source-level failure modes listed in the objective.
- Relevant source/device/OS/firmware class: Android Kotlin/Room/filesystem
  managed-cloud implementation; Full and Demo variants.
- Existing tests, logs, exports, screenshots, or documents:
  `ManagedCloudSchedulerTest`, `ManagedAccountScopeTest`, managed-history
  export/import/ZIP tests, managed-document ciphertext tests, and Android
  localization-policy tests.
- Unknowns that must remain unknown until measured: large-account behavior
  under real low-storage/process-death conditions and live managed-service
  behavior.

## Delivered

- Preserved aggregate retry semantics and legacy account-scope recovery.
- Bounded archive enumeration and authenticated large export checkpoints.
- Retained unacknowledged outgoing ciphertext while adding durable-reference
  reconciliation so superseded generations cannot permanently consume quota.
- Completed the targeted ownership-deletion localization parity.
- Serialized account deletion behind Friends refresh, preserved Friends
  scheduling through cancellation, and made the open Friends screen refresh
  when account access returns.
- Reverted an unversioned Recovery behavior change so `noop-charge-v2`
  remains reproducible across Android, Apple, and the server.

## Data, privacy, and medical truth

- Schema or migration impact: pending source review; no schema change is
  intended.
- Existing-data retention impact: the ciphertext correction must increase
  protection for unacknowledged encrypted payloads, never reduce it.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: preserve the
  existing bounded managed operation outcomes; tests will pin retry categories,
  retention decisions, and validation rejection without payload logging.
- Why existing evidence is sufficient, or why new evidence is required:
  these are deterministic local policy and persistence boundaries, so focused
  tests provide the primary evidence; no new high-frequency event is expected.
- Existing evidence reused: managed sync/export/import operation diagnostics.
- New bounded events or operation spans: pending source review; none planned
  unless an affected failure path is currently opaque.
- Redaction, retention, and high-frequency controls: tests and diagnostics must
  not contain health values, ciphertext, account identifiers, paths, tokens,
  cursor values, or exception messages.
- Cross-platform/backend correlation: none added.
- Remaining blind spots: process death, low storage, and live-service retries
  require later physical or staging evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot and dirty-state audit | Passed | Correct isolated branch is active and eight unrelated Swift paths are preserved | Android correctness |
| Full-debug focused unit wall | Build succeeded | Ciphertext reconciliation, Friends scheduler/deletion contracts, and Recovery parity compile and pass together | Instrumented or physical-device behavior |
| Exact-current Full and Demo regression wall | 175 Gradle tasks succeeded in 10m 28s; each variant executed 4,964 tests with 7 intentional skips and zero failures/errors; compile, lint, APK assembly, and instrumentation-source compilation passed | The final Android source, managed-only Friends route, account lifecycle, archive/checkpoint bounds, encrypted outbox reconciliation, localization, and app graph pass together in both variants | API 35 runtime behavior, physical-device background execution, push, BLE, battery, accessibility, or low-storage/process-death behavior |
| Exact-current lint reports | Full and Demo each contain 1,212 warnings and 77 hints with zero Error/Fatal findings | The final variants satisfy the enforced Android lint gate | The existing warning backlog is not eliminated |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: synthetic fixtures only
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: low-storage and process-death portability behavior

## Git and release state

- Changed paths: Android managed service/preferences/scheduler/storage/history
  source, managed-only Friends routing/UI/resources, focused tests, and this
  record
- Commits: pending
- Branch and remote state: local branch; one consolidated replacement push to
  pull request `#16` remains
- Repository visibility verified: unchanged
- Version/build impact: none intended
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: no new product decision; this round
  enforces existing resumability, retention, retry, and localization contracts.
- Decision-log entry: none planned

## Open risks and honest limitations

- Physical low-storage, process-death, background scheduling, and notification
  behavior remain unverified.

## Next round

1. Re-run the protected review and complete hosted exact-SHA checks after the
   broader multi-platform remediation is consolidated.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
