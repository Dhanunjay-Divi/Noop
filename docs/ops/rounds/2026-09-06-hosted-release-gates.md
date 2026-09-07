# Round: 2026-09-06 - Hosted release gates

## Status

- State: `completed for code-verifiable hosted source gates; external release
  gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `6436ba597f6de28b87f36f33e61020ecc87f4c51`
- End implementation commit: `1443acb1d2fea6067ac1943198d97520c97a2ee6`
- Record commit or PR: commit containing this record

## Objective

Close every code-verifiable hosted release gate for the supplier-independent
ownership foundation, preserve its least-privilege boundary, publish the
verified repair to `main`, and leave supplier, legal, signing, physical-band,
and public-production gates explicitly open.

## Scope

### In scope

- Diagnose the current server, Apple, and Android hosted workflows on exact
  mainline.
- Repair any deterministic source or workflow defect without weakening
  ownership isolation.
- Run focused and complete applicable local and hosted gates.
- Reconcile the permanent release checklist and operations records with exact
  evidence.

### Non-goals

- Infer supplier firmware, protocol, possession, or physical-band behavior.
- Enable ownership or NOOP+ public ingress, real customer identity, real health
  data, payment, or storefront release.
- Claim legal, certification, carrier, signing, or hardware evidence that does
  not exist.

## Starting evidence

- Reproduction or observed symptom: hosted server run `34078020631` passed 358
  tests and one intentional skip, but
  `test_ownership_readiness_accepts_only_a_restricted_principal` failed.
- Relevant source/device/OS/firmware class: TimescaleDB 2.20.3 on PostgreSQL 16,
  plain PostgreSQL 14 and 16, hosted Apple runners, and Android API 35 managed
  devices.
- Existing tests, logs, exports, screenshots, or documents: ownership round
  local matrix, GitHub hosted run logs, and release checklist actions
  `CI-010` through `CI-070`.
- Unknowns that must remain unknown until measured: final hosted Apple and
  Android outcomes, physical-device behavior, and every supplier/external
  launch gate.

## Delivered

- Changed the PostgreSQL-overlay database creation to use pristine
  `template0`, preventing TimescaleDB's `template1` extension objects and
  `PUBLIC` grants from contaminating the plain-PostgreSQL lane.
- Added an early hosted assertion that the overlay contains no extension other
  than core `plpgsql`.
- Preserved every ownership readiness predicate and runtime/database grant
  unchanged.
- Re-ran the complete server workflow on the repair commit, including legal
  lock, lint, both dependency audits, the 359-case suite, production and backup
  containers, encrypted backup, and disposable restore.
- Ran the Apple application matrix on the exact repair commit, including the
  universal macOS build/tests, launch-gate isolation, complete iOS simulator
  build, and iOS production-shell tests.
- Ran the Android build/unit/lint/instrumentation-compile lane and API 35
  managed-device production-shell lane on the exact repair commit, retaining
  the device diagnostics.
- Verified every Swift package plus the study harness, private-data rejection,
  localization, health claims, runtime-license inventory, and operations
  record on the same source commit.
- Reconciled the permanent checklist, readiness record, master plan, active
  handoff, and round index with the hosted evidence. No external launch gate
  was converted into code evidence.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: ownership and managed services remain
  disabled in released clients and private at the runtime boundary.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: hosted job and
  test boundaries, PostgreSQL readiness predicates, XCTest, Gradle/JUnit, and
  retained Android managed-device reports.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes verification infrastructure rather than a product runtime
  path; existing bounded product and server observability remains unchanged.
- Existing evidence reused: GitHub job results, pytest assertions, XCTest
  results, Gradle reports, `AppDiagnosticsRecorder`,
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: hosted diagnostics contain
  fixed test and predicate names only, with no identity, credential, payload,
  health value, or dynamic customer data.
- Cross-platform/backend correlation: exact source commit and hosted run IDs.
- Remaining blind spots: physical phone, band, background, haptic, battery,
  attestation, legal, and public-production behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Complete local plain-PostgreSQL server suite | 358 passed and one intentional environment skip on PostgreSQL 14 | Migrations, API, isolation, ownership, managed services, recovery, and regression tests pass together | Hosted execution or production runtime |
| Local PostgreSQL 16 ownership and provisioning suite | 51 passed | The same role, privilege, idempotency, concurrency, and provisioning contract passes on the hosted PostgreSQL major version | Production Cloud SQL policy |
| Overlay extension guard | Local PostgreSQL 16 overlay contained only `plpgsql`; `actionlint` passed | The workflow uses a syntactically valid, extension-free PostgreSQL lane | Production topology |
| Baseline hosted server run `34078020631` | 358 passed, 1 failed, 1 skipped | The original failure is isolated to ownership readiness in the contaminated PostgreSQL-overlay database | A passing repaired lane |
| Exact-main hosted server run `34078811154` | Passed on `1443acb1`: extension guard, lint, dependency audits, 358 passed plus one intentional skip, Compose validation, both container builds, encrypted backup, and disposable restore | The repaired hosted workflow and least-privilege ownership contract pass together | Public ingress, load, or regional recovery |
| Exact-main hosted Android run `34079190997` | Passed: APK build, 4,098-test unit lane, lint, instrumentation compile, and 45 API 35 production-shell tests with retained diagnostics | Android source and production-shell automation are green on the repair commit | Physical phone, BLE, background, battery, haptic, or attestation behavior |
| Exact-main hosted Apple run `34080116658` | Passed: universal macOS build/tests, iOS launch-gate isolation and build, and iOS production-shell tests | Apple app source, simulator graph, and shell automation are green on the repair commit | Signed hardware, BLE, HealthKit entitlement, Watch pairing, or background behavior |
| Exact-main Swift/study run `34078979831` | Passed every package and the study harness, including tracked-private-data rejection | Portable package contracts and the private study tool remain green | App-target or physical-device behavior |
| Exact-main policy runs | Localization `34078811190`, health claims `34078811160`, runtime license inventory `34078979957`, and operations record `34078811177` passed | Current tracked source satisfies the named repository policy gates | Legal approval, native-speaker review, or launch authorization |
| Local closeout policy matrix | Operations validator passed 31 records; legal inventory verified 213 runtime components and three container inputs plus nine tests; private-data filename guard passed; eight health-gate tests and the 1,184-file scan passed; localization passed; tracked-source token-format scan found no matches; `git diff --check` passed | The edited release records remain internally valid and contain no detected common credential format or whitespace defect | Independent security review or proof that no credential exists in any external system |
| GitHub release-control inspection | Repository remains private on `main`; branch-protection endpoint returned not protected; environment list and Actions-variable list were empty; only four Android staging-signing secret names were present | The readiness record's open protection, environment, and production-credential gates match current repository metadata without reading secret values | Credential validity, custody, or production approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no customer data touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party band and signed physical-client gates.

## Git and release state

- Changed paths: server hosted workflow, release checklist/readiness/plan, and
  operations records.
- Commits: `1443acb1` (`fix(ci): isolate plain postgres ownership gate`) plus
  the commit containing this closeout record.
- Branch and remote state: `main`; implementation commit `1443acb1` was pushed
  and verified on `origin/main`; the closeout record is pushed in its containing
  commit.
- Repository visibility verified: not repeated.
- Version/build impact: none.
- Release or distribution impact: none; public ingress and released ownership
  configuration remain disabled.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none.

## Open risks and honest limitations

- A green hosted source matrix cannot replace supplier, legal, signed-device,
  physical-band, certification, or store evidence.
- `main` is not protected and the repository has no reviewed GitHub
  environments. Production signing/deployment credentials, required-check
  policy, artifact provenance, and credential-rotation evidence remain open.

## Next round

1. Continue the first unchecked dependency in the production release
   checklist, beginning with owner decisions and protected release controls
   while the supplier hardware/firmware dossier is obtained.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
