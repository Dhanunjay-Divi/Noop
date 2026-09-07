# Round: 2026-09-06 - Hosted release gates

## Status

- State: `in progress`
- Owner: project team
- Branch: `main`
- Start commit: `6436ba597f6de28b87f36f33e61020ecc87f4c51`
- End implementation commit: pending
- Record commit or PR: pending

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

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none planned.
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
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: hosted diagnostics contain
  fixed test and predicate names only, with no identity, credential, payload,
  health value, or dynamic customer data.
- Cross-platform/backend correlation: exact source commit and hosted run IDs.
- Remaining blind spots: physical phone, band, background, haptic, battery,
  attestation, legal, and public-production behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Complete plain-PostgreSQL server suite | 358 passed and one intentional environment skip on PostgreSQL 14 | Migrations, API, isolation, ownership, managed services, recovery, and regression tests pass together | Hosted TimescaleDB image or production runtime |
| PostgreSQL 16 ownership and provisioning suite | 51 passed | The same role, privilege, idempotency, concurrency, and provisioning contract passes on the hosted PostgreSQL major version | TimescaleDB-backed primary lane |
| Overlay extension guard | Local PostgreSQL 16 overlay contains only `plpgsql`; `actionlint` passed | The workflow uses a syntactically valid, extension-free PostgreSQL lane | Hosted execution until the repair commit runs |
| Server quality and policy gates | Ruff check/format, legal inventory, private-data filename guard, operations validation, and whitespace passed | Edited source and records satisfy current static policy | Runtime behavior |
| Hosted server run `34078020631` | 358 passed, 1 failed, 1 skipped | Failure is isolated to ownership readiness in the PostgreSQL-overlay database | Exact failing readiness predicate by itself |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no customer data touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party band and signed physical-client gates.

## Git and release state

- Changed paths: server hosted workflow and operations records.
- Commits: pending.
- Branch and remote state: clean `main` equaled `origin/main` at start.
- Repository visibility verified: not repeated.
- Version/build impact: none planned.
- Release or distribution impact: none; public ingress and released ownership
  configuration remain disabled.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none.

## Open risks and honest limitations

- A green hosted source matrix cannot replace supplier, legal, signed-device,
  physical-band, certification, or store evidence.

## Next round

1. Continue the first unchecked dependency in the production release checklist.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
