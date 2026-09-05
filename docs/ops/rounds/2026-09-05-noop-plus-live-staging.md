# Round: 2026-09-05 - NOOP+ live staging and hot-cache retention

## Status

- State: `completed for private synthetic staging; public and physical gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `68e305bd`
- End implementation commit: commit containing this record
- Record commit or PR: commit containing this record

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
- Built and scanned one immutable replacement image. The on-demand scan found
  zero vulnerabilities at every reported severity. OpenTofu applied five
  in-place workload updates with no additions or destroys, and all three
  services plus both jobs now use digest
  `sha256:c55ec7eba9a7f66028ee1f67be3c567273bb4981652228b22f288e540852598a`.
- Deployed migration `025`, then proved successful migration and repeated
  lifecycle executions. The managed API remains IAM-only, released clients
  remain disconnected, and staging still contains no real health data.
- The first private smoke exposed a real processor defect: PostgreSQL `jsonb`
  was returned by `asyncpg` as a string, so a valid manifest was quarantined.
  Repository decoding now accepts and bounds that representation, and the
  processor emits only fixed `available`, `quarantined`, or
  `already_processed` outcomes.
- The next smoke correctly returned only the current day after friendship
  acceptance, while the runner incorrectly expected seven pre-acceptance days.
  The runner now proves that accepted friends cannot read earlier history and
  sends the explicit confirmation required for managed Friends deletion.
- The final 79-second private smoke passed fictional OTP identity, App Check,
  enrollment and consent, upload, processing, duplicate idempotency, tenant
  isolation, restore, raw erasure, retention, exact IDs, invites, directional
  sharing, badges, pokes, blocks, social deletion, account erasure, and identity
  cleanup. Exactly one pre-existing fictional login configuration remains for
  operator testing; temporary identities and App Check debug tokens were
  removed.
- Closed the final iPhone shell readability regression without flattening the
  glass treatment. Shape-local light and dark scrims now prevent page copy from
  remaining legible through the floating navigation and quick-action lens.
  Android needs no equivalent code change because its independently rendered
  navigation is a `Scaffold` bottom slot and already reserves content space.

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
  lifecycle logs exposed the SQL type boundary, processor outcome evidence
  exposed the manifest quarantine, and PostgreSQL regressions cover both.
  Successful deployed lifecycle runs and the private smoke close those
  synthetic boundaries.
- Existing evidence reused: native `AppDiagnosticsRecorder`, server
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: processor terminal outcomes are fixed
  categories with no manifest, object, account, or job identifier.
- Final shell observability decision: no new diagnostic event is warranted for
  a deterministic rendering-only change. The source contract and untracked
  synthetic simulator capture diagnose regression without recording a user
  action, screenshot, health value, or dynamic identifier.
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
| Latest migration execution | Completed successfully | Cloud SQL is migrated through `025` by the deployed digest | Mobile behavior |
| Scheduled lifecycle logs | Initial executions failed with one fixed PostgreSQL type category; replacement executions completed successfully | The defect was observable and the corrected deployed query runs | Long-duration production retention |
| Focused Swift and Android retention tests | Passed | Both clients compute 7-day raw and 30-day essential cutoffs and never select summaries | Physical-device storage pressure |
| PostgreSQL 14 retention regression | Passed | The corrected purge statement prepares and executes on standard PostgreSQL | Cloud SQL deployment until the new image runs |
| Runtime build and on-demand vulnerability scan | Digest `sha256:c55ec7eba9a7f66028ee1f67be3c567273bb4981652228b22f288e540852598a`; zero findings at all severities | The exact deployed source artifact passed the configured scan | Independent penetration testing |
| Private synthetic runtime smoke | Passed in 79 seconds | OTP/App Check, storage, isolation, restore, erasure, lifecycle, and managed social contracts work together against deployed private staging | Public ingress, scale, real data, carrier, or physical-device behavior |
| Post-deploy private verifier and OpenTofu plan | Passed; detailed-exit plan returned `0` with no changes | IAM-only invocation, PITR/deletion protection, digest pinning, and zero drift remain true | Public launch readiness |
| Fresh iOS simulator graph and launch | Passed, 89 targets | The iPhone, Watch, widgets, and Live Activities compile and the app process launches | BLE, background execution, or signed-device attestation |
| Final Apple shell contract and render | First run exposed one stale pre-fix source assertion; corrected rerun passed 14/14, and a deterministic Today-bottom capture passed visual inspection | The current floating controls retain glass highlights while body text beneath them is no longer readable | Physical-device contrast, motion, or accessibility acceptance |
| Forced Android Full build and emulator launch | `BUILD SUCCESSFUL` in 3m22s with 59/59 tasks executed; APK installed and launched on API 35 | The current production-flavor compile, unit, lint, packaging, install, and first activity launch paths work together | Physical BLE, OEM background behavior, or managed attestation |
| Final publication gates | Operations records, private-data and credential patterns, health claims, 17 policy tests, focus-locale coverage, 213-component legal inventory, Ruff check/format, Python syntax, OpenTofu format/validate, and whitespace passed | The reviewed publication tree satisfies repository policy and contains no detected tracked runtime credential | Independent security, privacy, legal, or native-speaker review |

## Physical device and deployment

- Install/update action: unsigned iOS simulator app and Android Full debug APK
  installed and launched; no physical-device install.
- Generalized device and OS class: current iOS 26.5 simulator and Android API 35
  emulator.
- Data-preservation result: no physical-device data modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed iOS/Android enrollment, background upload,
  BLE, battery, storage-pressure, restore, and in-place-upgrade scenarios.

## Git and release state

- Changed paths: managed retention clients/tests, lifecycle SQL/tests,
  processor/repository handling and tests, deployment controls, synthetic smoke
  runner, and durable records.
- Commits: `68e305bd`, `4048f013`, and `87d6b784`, plus the record commit.
- Branch and remote state: publication to `origin/main` is part of closeout.
- Repository visibility verified: not repeated.
- Version/build impact: no marketing-version or build-number change.
- Release or distribution impact: synthetic staging only unless later evidence
  and explicit gates permit more.

## Decisions

- Durable decision added or changed: local retention is a seven-day
  high-rate raw hot cache, approximately 30-day essential detail cache, and
  lifetime compact summaries; pruning remains opt-in and server-validated.
- Decision-log entry: `D-037`.

## Open risks and honest limitations

- Provider credentials pasted into a conversation must be rotated; they are not
  suitable for source control or durable records.
- Twilio sender registration, signing, physical devices, independent
  security/privacy review, and production operations cannot be completed by
  code alone. A credential previously pasted into conversation must be rotated
  and was not used.
- Two profiles from a failed synthetic attempt remain only while their already
  scheduled account erasures observe the 24-hour cooling-off contract. No
  provider identity remains for them, and the successful smoke added none.

## Next round

1. Run signed iOS and Android pilot journeys for account creation, consent,
   background catch-up, restore, storage pressure, and in-place upgrade.
2. Prove large-account managed export/resume/import, load, PITR restore, secret
   rotation, support access, and production HTTPS/push delivery before public
   enrollment.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
