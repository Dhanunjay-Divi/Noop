# Round: 2026-09-05 - Release checklist execution

## Status

- State: `completed for the CI repair slice; ownership continued in a separate
  evidenced round`
- Owner: project team
- Branch: `main`
- Start commit: `ea78d5eb`
- End implementation commit: `2c234840`
- Record commit or PR: `2c234840`

## Objective

Make the first-production-release checklist the standing execution ledger for
future NOOP work. Preserve the complete first-party band activation journey,
defer only behavior that requires the supplier SDK, firmware contract, physical
bands, or another external approval, and complete the next dependency-ordered
local/account work that can be verified without inventing hardware behavior.

Every future request must first be reconciled against the checklist: reuse an
existing action when it already covers the request, insert a stable new action
when it does not, and mark an action complete only with its required evidence.
The public landing-page refresh remains a later release phase after the product,
policy, support, and storefront facts are stable.

## Scope

### In scope

- Classify the release ledger into evidenced completion, independently
  actionable engineering, owner/external decisions, and supplier/physical-band
  dependencies.
- Preserve the printed-number, identify-vibration, authenticated physical
  confirmation, ownership-account, atomic-claim, onboarding, and plan-selection
  journey without implementing guessed device behavior.
- Implement and verify the highest-priority account/local release slice that is
  independent of supplier protocol bytes.
- Add bounded, privacy-safe evidence for every changed identity, persistence,
  network, or user-visible state boundary.
- Update the checklist, readiness records, active handoff, and round index with
  exact evidence and remaining gates.

### Non-goals

- Claim real pairing, haptics, possession proof, firmware security, BLE
  reliability, background collection, battery behavior, or sensor accuracy
  without representative physical hardware and the approved supplier dossier.
- Enable public traffic, real health-data upload, payment, or production
  entitlement.
- Check off legal, carrier, certification, signing, store, manufacturing, or
  owner-decision gates without their external evidence.
- Publish customer promises on the landing page before the corresponding
  product and policy decisions are release-approved.

## Starting evidence

- Reproduction or observed symptom: the owner needs one durable, deduplicated
  checklist that survives chat limits and drives all future work to launch.
- Relevant source/device/OS/firmware class: Apple and Android apps, FastAPI and
  PostgreSQL services, Firebase Identity Platform, GCP staging, and the future
  first-party NOOP Band.
- Existing tests, logs, exports, screenshots, or documents: 396 stable
  checklist actions, five evidenced owner decisions, phone-OTP-only private
  NOOP+ staging, and the owner-approved first-party activation contract.
- Unknowns that must remain unknown until measured: supplier GATT and wire
  protocol, per-unit key and label mapping, authenticated tap event, production
  hardware behavior, return duration, billing, legal approval, and signed
  physical-device results.

## Delivered

- Repaired server CI isolation so the standard PostgreSQL-overlay social tests
  use a dedicated database instead of racing the primary migration fixture.
- Split Android production-shell instrumentation into its own bounded job,
  fixed the managed-device ABI to the hosted runner architecture, added lint to
  the compile/unit job, and retained only managed-device test diagnostics.
- Replaced coordinate-only strength body-map selection in the iOS production
  shell test with debug-launch-only accessibility controls. The test now
  scrolls the complete map into view and proves simultaneous Chest and Back
  state plus rendered selection pixels without changing production behavior.
- Completed the local repair gates before publishing the CI slice.
- Published the CI repair as `2c234840`. The supplier-independent ownership
  implementation continued in
  [`2026-09-05-ownership-account-foundation.md`](2026-09-05-ownership-account-foundation.md)
  so this record does not mix its later schema, runtime, and mobile evidence
  into the earlier CI slice.

## Data, privacy, and medical truth

- Schema or migration impact: none in the CI repair slice. Ownership schema
  evidence is recorded in the separate ownership foundation round.
- Existing-data retention impact: no destructive migration is authorized.
- Source/provenance or formula impact: none planned in this round.
- Permissions/network disclosure impact: ownership identity and NOOP+ consent
  remain separate; public ingress remains disabled.
- Health/medical claim impact and limitations: none. Account or simulator
  evidence cannot validate a sensor or physiological metric.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: GitHub job
  boundaries separate Android compile/unit/lint from managed-device execution;
  the managed-device job retains its bounded HTML and machine-result reports
  for 14 days on both success and failure. Server fixtures now identify the
  exact isolated database contract. The iOS test records XCTest assertions and
  attachments for semantic and rendered selection state.
- Why existing evidence is sufficient, or why new evidence is required:
  `AppDiagnosticsRecorder`, `RequestObservabilityMiddleware`, and
  `emit_operational_event` exist; changed paths must prove whether they cover
  each new boundary.
- Existing evidence reused: Gradle, Android managed-device, pytest, and XCTest
  reports.
- New bounded events or operation spans: none. These are test and CI boundary
  changes, not product runtime paths.
- Redaction, retention, and high-frequency controls: no band number, account or
  installation identifier, email, phone, password, OTP, token, challenge
  payload, health value, request body, dynamic path, or arbitrary error may
  enter diagnostics.
- Cross-platform/backend correlation: server-generated request IDs and static
  route groups only.
- Remaining blind spots: supplier and physical-device behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Repository preflight | Clean `main` at `ea78d5eb`, equal to `origin/main` | Work starts from the published source | Runtime or release readiness |
| Workflow static validation | `actionlint` passed for the Android and server workflows; `git diff --check` passed | Edited workflow syntax and whitespace are valid | Hosted runner behavior |
| iOS focused production-shell test | `testStrengthBodyMapKeepsFrontAndBackRegionsSelectedTogether` passed, 1 test and 0 failures | The debug test seam selects Chest and Back together and the complete map is visible for image assertions | Other iOS screens, physical devices, or workout correctness |
| Android compile/unit/lint gate | `assembleFullDebug testFullDebugUnitTest lintFullDebug compileFullDebugAndroidTestKotlin` passed, 70 actionable tasks | Full debug app and test sources compile, unit tests and lint pass | Managed-emulator or physical-device behavior |
| Android managed-device gate | API 35 `pixel2Api35FullDebugAndroidTest` passed, 45 tests with two intentional private-pilot skips | Production-shell instrumentation runs on the pinned x86_64 managed device | BLE, background, haptic, battery, or hardware behavior |
| Server full suite | Exit 0 against two fresh isolated PostgreSQL 14 databases; 275 passed and one environment-gated skip | Primary and PostgreSQL-overlay migrations/tests no longer collide | Hosted CI, production Cloud SQL, or ownership behavior not yet implemented |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: pending.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party pairing, ownership proof, collection,
  history, power, haptic, firmware-update, and recovery scenarios.

## Git and release state

- Changed paths: Android and server workflows, Android managed-device ABI,
  server PostgreSQL-overlay fixture, iOS strength production-shell test and its
  debug-only selection seam, and this round record.
- Commits: `2c234840`.
- Branch and remote state: the CI repair was published to `main`.
- Repository visibility verified: not repeated.
- Version/build impact: no version change.
- Release or distribution impact: none at round start.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none.

## Open risks and honest limitations

- The independently actionable backlog is much larger than one unverified
  change. Work must close in dependency order and keep every external gate
  visible rather than treating a broad request as release evidence.
- Existing private phone-OTP staging is not the target verified-email ownership
  account and cannot be relabeled as complete.
- A virtual band can prove deterministic application and service behavior only;
  it cannot prove firmware possession, radio behavior, or hardware security.

## Next round

1. Continue supplier-independent ownership work in
   [`2026-09-05-ownership-account-foundation.md`](2026-09-05-ownership-account-foundation.md).
2. Keep supplier and physical-band behavior open until the approved dossier and
   representative hardware exist.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
