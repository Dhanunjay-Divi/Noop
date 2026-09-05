# Round: 2026-09-05 - NOOP+ live staging and hot-cache retention

## Status

- State: `in progress`
- Owner: project team
- Branch: `main`
- Start commit: `68e305bd`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Advance the optional NOOP+ implementation from locally verified source to a
functional, synthetic end-to-end staging model. Configure identity and paging
dependencies where the account permits, deploy the managed data path, prove
upload/processing/restore/isolation/erasure behavior, and keep both native apps
responsive with a bounded local hot cache. Core NOOP must remain account-free,
fully useful offline, and independent of NOOP+.

## Scope

### In scope

- Audit and, when all gates permit, deploy Firebase identity/App Check, Cloud
  SQL migrations, managed API, processor, lifecycle work, and private synthetic
  staging.
- Configure provider secrets outside source control and verify fixed,
  privacy-safe lifecycle evidence.
- Define and implement equivalent Apple and Android local retention behavior:
  seven days of high-rate raw optical/motion data, approximately 30 days of
  essential detailed time series, and lifetime compact summaries and user
  records.
- Prune only exact windows acknowledged and validated by managed storage.
- Exercise synthetic upload, duplicate, reconnect, restore, tenant isolation,
  retention, and erasure paths before any real health data is considered.
- Run relevant backend, package, app, infrastructure, privacy, and operations
  gates, then publish only verified intentional changes when authorized.

### Non-goals

- Make an account or cloud connection mandatory.
- Upload real health data before the recorded privacy, security, identity, and
  physical-device gates pass.
- Claim carrier delivery, background BLE reliability, or production scale from
  unit, simulator, emulator, or synthetic cloud evidence.
- Enable automatic medical, anomaly, or fall paging.

## Starting evidence

- Reproduction or observed symptom: a phone database reportedly reached about
  600 MB after roughly ten days, with UI stalls and intermittent collection.
  The owner requested a functional cloud model and a seven-day local strategy.
- Relevant source/device/OS/firmware class: native iOS and Android SQLite
  stores, optional NOOP+ clients, FastAPI/PostgreSQL managed services, GCP
  Mumbai staging, Firebase identity/App Check, and Twilio paging.
- Existing tests, logs, exports, screenshots, or documents: managed storage,
  export, identity, infrastructure, and clients are locally implemented and
  verified in the 2026-09-03 round. A scanned runtime image exists but was not
  deployed after Firebase terms blocked identity creation.
- Existing worktree state: `main` starts one commit ahead of `origin/main` and
  contains an intentional in-progress observability round. This round must
  preserve and verify that work rather than discard it.
- Unknowns that must remain unknown until measured: current Firebase terms and
  billing state, Twilio sender and market-registration state, signed mobile
  attestation, physical background cadence, compressed bytes per user-day,
  carrier delivery, and production capacity.

## Delivered

- Reconciled real GCP state against OpenTofu. Firebase Identity Platform, App
  Check, Cloud SQL, the IAM-only managed API, internal processor, lifecycle
  scheduler, Pub/Sub, KMS, and storage resources are deployed in synthetic
  Mumbai staging. The private-runtime verifier passes and the reviewed
  OpenTofu plan reports no drift.
- Confirmed the latest migration job completed successfully against PostgreSQL
  16.
- Found that every scheduled lifecycle execution was failing in bounded
  control-row cleanup because PostgreSQL inferred an interval parameter where
  the query required a timestamp. Added explicit `timestamptz` casts to all
  three affected retention expressions and a real-PostgreSQL regression test.
- Replaced the clients' single 90-day sensor cutoff with the server plan's
  class-specific policy: seven days for raw optical, motion, and auxiliary
  streams; 30 days for essential time series; no local pruning of summaries or
  user records. Apple and Android compute and test the same cutoffs.
- Updated the opt-in storage-reduction disclosure on both platforms and in the
  currently maintained locale catalogs. Deletion still requires an exact,
  processor-validated, unchanged managed window.

## Data, privacy, and medical truth

- Schema or migration impact: no migration. The PostgreSQL fix changes query
  parameter typing only; local pruning reuses the existing transactional
  managed-window state.
- Existing-data retention impact: no data may be pruned before exact managed
  processor validation; detailed and summary classes will have separate local
  policies.
- Source/provenance or formula impact: none intended.
- Permissions/network disclosure impact: NOOP+ remains explicit opt-in; provider
  credentials must remain in managed secrets and ignored local configuration.
- Health/medical claim impact and limitations: storage and delivery plumbing
  do not validate physiology or medical behavior.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  managed sync spans and per-request diagnostics cover native transfer and
  pruning outcomes. The lifecycle job emits one bounded start and terminal
  event with fixed failure kind, duration, and aggregate counts.
- Why existing evidence is sufficient, or why new evidence is required:
  lifecycle logs exposed the exact operational boundary, while the new
  PostgreSQL test prevents the SQL type regression. A successful deployed
  lifecycle execution remains required after the replacement image is
  scanned and applied.
- Existing evidence reused: native `AppDiagnosticsRecorder`, server
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: pending.
- Redaction, retention, and high-frequency controls: no health values, contact
  data, credentials, tokens, payloads, dynamic identifiers, or arbitrary
  provider errors may enter diagnostics.
- Cross-platform/backend correlation: server-generated bounded request IDs and
  static route groups only.
- Remaining blind spots: signed-device attestation, OS background scheduling,
  BLE continuity, and human carrier receipt require external evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `infra/gcp/scripts/verify-private-runtime.sh` | Passed | IAM-only runtime controls and deployed revisions satisfy the scripted private-staging contract | Application data paths |
| `tofu plan -detailed-exitcode -no-color` | Exit 0, no changes | Real infrastructure matches current source inputs | Runtime behavior |
| Latest migration execution | Completed successfully | Current deployed image migrated Cloud SQL through the checked-in migration set | Lifecycle query correctness |
| Scheduled lifecycle logs | Failed repeatedly with one fixed PostgreSQL type category | The maintenance path was not healthy and the failure was reproducible | Corrected image behavior |
| Focused Swift and Android retention tests | Passed | Both clients compute 7-day raw and 30-day essential cutoffs and never select summaries | Physical-device storage pressure |
| PostgreSQL 14 retention regression | Passed | The corrected purge statement prepares and executes on standard PostgreSQL | Cloud SQL deployment until the new image runs |
| Pre-deployment private-runtime verification and OpenTofu plan | Private controls passed; detailed-exit plan returned `0` with no changes | The existing IAM-only staging runtime has no broad private-API invoker, retains Cloud SQL PITR/deletion protection, and matches the checked-in infrastructure before the image replacement | Corrected lifecycle behavior or migration `025` |
| Current deployed runtime digest | `sha256:fece441d02a3e2b1a0c4b2311415171a81571c1bd33fb3f7cc6318da2f802088` | The exact rollback baseline is recorded before deployment | That this older image contains the lifecycle fix or managed Friends schema |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no physical-device data modified at round start.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed iOS/Android enrollment, background upload,
  BLE, battery, storage-pressure, restore, and in-place-upgrade scenarios.

## Git and release state

- Changed paths: this starting operations record only; pre-existing dirty paths
  belong to the active observability round.
- Commits: pending.
- Branch and remote state: local `main` at `68e305bd`, one commit ahead of
  `origin/main` at round start.
- Repository visibility verified: not repeated.
- Version/build impact: pending.
- Release or distribution impact: synthetic staging only unless later evidence
  and explicit gates permit more.

## Decisions

- Durable decision added or changed: proposed local retention is a seven-day
  high-rate raw hot cache, approximately 30-day essential detail cache, and
  lifetime compact summaries; pruning remains opt-in and server-validated.
- Decision-log entry: pending implementation and evidence.

## Open risks and honest limitations

- Provider credentials pasted into a conversation must be rotated; they are not
  suitable for source control or durable records.
- Firebase contractual acceptance, Twilio sender registration, signing,
  physical devices, independent security/privacy review, and production
  operations cannot be completed by code alone.

## Next round

1. Complete the live-state audit and execute the ordered plan above.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
