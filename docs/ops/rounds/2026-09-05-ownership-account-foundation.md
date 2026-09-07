# Round: 2026-09-05 - Ownership account foundation

## Status

- State: `completed for the supplier-independent code foundation; external
  launch gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `2c234840`
- End implementation commit: commit containing this record
- Record commit or PR: commit containing this record

## Objective

Complete the supplier-independent first-party NOOP Band ownership-account
foundation across backend, Apple, and Android while preserving account-free,
local-first core NOOP. Keep supplier SDK, firmware, physical possession,
approved terms, billing, legal, signing, and production gates explicitly open.

Make the existing release checklist the durable source of truth, mark only
verified actions complete, and leave the public landing-page refresh after
product and policy facts stabilize.

## Scope

### In scope

- Additive ownership-control-plane schema, API, isolation, idempotency,
  least-privilege database identity, and privacy-safe operational evidence.
- Verified-email identity, optional linked-phone mechanics, remote immutable
  terms verification, installation credentials, recovery primitives,
  replacement-installation authorization, and plan preference.
- Resumable Apple and Android account/onboarding state and an honest NOOP versus
  NOOP+ choice with no payment or entitlement.
- Guarded default-off GCP resources, deterministic tests, cross-platform
  builds, checklist updates, and durable handoff.

### Non-goals

- Guess supplier GATT, packet, printed-label mapping, haptic, gesture,
  cryptographic possession, key-provisioning, firmware, or OTA behavior.
- Enable public ownership ingress, released-client activation, real customer
  identity, health-data upload, payment, or production traffic.
- Claim physical-device, BLE, background, haptic, battery, sensor, metric,
  legal, certification, signing, or storefront validation.
- Refresh the public landing page before release facts and approved policies
  are stable.

## Starting evidence

- Reproduction or observed symptom: the ownership flow was documented but not
  implemented; the resumed worktree contained an unfinished backend
  foundation, Apple service, Android service, and cross-platform plan chooser.
- Relevant source/device/OS/firmware class: FastAPI/PostgreSQL, Firebase
  Identity Platform and App Check, iOS 17+, Android API 26+, and a future
  first-party NOOP Band whose supplier contract is unavailable.
- Existing tests, logs, exports, screenshots, or documents:
  `docs/FIRST_PRODUCTION_RELEASE_CHECKLIST.md`,
  `docs/ops/rounds/2026-09-05-band-ownership-onboarding.md`, and local ignored
  build/test results.
- Unknowns that remain unknown: supplier protocol and possession proof,
  physical reliability, approved terms content, return policy, payment,
  production identity configuration, and launch approvals.

## Delivered

### Backend and data boundary

- Added migration `026_band_ownership.sql` for accounts, hashed external
  identities, immutable terms documents and acceptances, random installation
  credentials stored only as digests, provisioned-band identity digests,
  challenges, atomic claims, replacement authorizations, plan preferences,
  entitlement separation, controlled releases, and bounded events.
- Added an isolated FastAPI ownership runtime with Firebase App Check,
  verified email/password identity, installation authentication, immutable
  remote-terms manifests, account/bootstrap/installations routes, claim and
  replacement authorization, installation revocation, and plan selection.
- Claim and replacement mutations are advisory-locked, idempotent, and
  tenant-scoped. Already-claimed responses reveal no owner identity.
- The runtime database principal receives exact table `SELECT`/`INSERT` and
  column-level `UPDATE` grants only. Readiness rejects superuser, inheritance,
  role administration, database/schema creation, object ownership, unexpected
  functions/sequences, non-ownership access, broad table updates, and
  unapproved columns.
- The production possession provider always returns unavailable. No simulator
  or synthetic provider can be enabled through deployment configuration.

### Apple and Android

- Added matched secure ownership services and state machines. Installation
  tokens and resumable checkpoints use Keychain on Apple and encrypted,
  Keystore-backed preferences on Android.
- Added account creation/sign-in, email verification/resend, password reset,
  optional phone linking, terms review, registration reconciliation, claim,
  replacement-installation authorization, installation revocation, sign-out,
  explicit local repair, and plan preference surfaces.
- Terms clients reject redirects, credentials, query/fragment components,
  non-approved hosts, non-TLS transport outside explicit debug loopback, bad
  UTF-8/control characters, oversized documents, and digest mismatches. Terms
  are fetched without a persistent cache and are not stored in app databases
  or diagnostics.
- Onboarding checkpoints survive recreation/process death, reconcile every
  post-claim page back to ownership when required, and resume the existing
  profile/import/notifications/Safety/appearance/daily-rhythm flow after claim.
- Added the pre-Home NOOP/NOOP+ chooser on both phones. NOOP remains the
  default; NOOP+ records preference only and explicitly performs no upload,
  checkout, or entitlement grant.
- Added a stable Band Account destination on both platforms and retained
  account-free core behavior when ownership activation is not configured.

### Infrastructure and release control

- Added default-off GCP identity/runtime variables and an IAM-only Cloud Run
  ownership service with a separate Cloud SQL secret and service identity.
- Added a database provisioner that revokes excess effective privilege,
  applies the exact runtime allowlist, verifies readiness as the restricted
  principal, and writes the connection URL directly to Secret Manager without
  exposing it in arguments or output.
- Released mobile configuration remains disabled, the runtime has no public
  invoker, no approved terms document was published, and no cloud deployment
  occurred in this round.

## Data, privacy, and medical truth

- Schema or migration impact: additive PostgreSQL migration `026`; no local
  health schema changed.
- Existing-data retention impact: none. No local health data was deleted,
  pruned, uploaded, or migrated.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: ownership is a separate explicit
  identity/control boundary and remains disabled in released configuration.
- Health/medical claim impact and limitations: none. Ownership does not validate
  a sensor, metric, or medical claim.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: Apple and
  Android emit fixed begin/end operations for identity, terms, registration,
  reconciliation, claim, replacement authorization, installation revocation,
  and plan selection. HTTP evidence records only static route group, method,
  status family, duration, outcome, and validated server request ID. The server
  reuses request middleware and payload-free fixed ownership outcomes.
- Why existing evidence is sufficient, or why new evidence is required: the
  existing recorders provide bounded storage/redaction; dedicated ownership
  lifecycle categories were added because identity, terms, and partial commit
  boundaries otherwise could not be distinguished.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: account reconciliation, identity
  create/sign-in/verification/reset/phone link, terms fetch/acceptance,
  registration, challenge, claim, replacement authorization, installation
  list/revoke, local reset, plan selection, and static ownership HTTP routes.
- Redaction, retention, and high-frequency controls: fixed transitions are
  emitted once per operation. Tests prohibit email, phone, password, OTP,
  printed number, band/account/installation identifier, token, challenge,
  response, health value, payload, dynamic URL, and arbitrary error text.
- Cross-platform/backend correlation: only the validated server-generated
  request ID and static route category cross the boundary; persistent
  identifiers remain excluded.
- Remaining blind spots: supplier discovery, identify haptic, physical
  possession, owner-key provisioning, released-client attestation, public
  runtime behavior, and production alert/retention policy.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Restricted PostgreSQL flow | 11 focused tests passed against fresh databases | Exact grants can register, challenge, claim, and select a plan while escalation and broad updates fail readiness | Production IAM or Cloud SQL policy |
| Complete server suite | 359 collected; 358 passed and one intentional skip against fresh PostgreSQL databases | Migration, API, identity, isolation, idempotency, concurrency, recovery, managed features, and provisioning regressions are covered together | Load, regional failure, or physical possession |
| Python quality | Ruff check/format and `compileall` passed | New Python is formatted, lint-clean, and syntactically valid | Runtime behavior |
| Android unit/compile/lint | Full and Demo each passed 4,098 tests with seven intentional skips; both compile and lint gates passed | Shared Kotlin state, secure persistence, API parsing, navigation, and existing app behavior remain compatible | OEM or physical-band behavior |
| Android managed device | API 35 completed 45 tests with two credential-gated private-pilot skips and no failures | Room migrations and production-shell instrumentation run on an emulator | BLE, haptics, battery, or background behavior |
| Android install/visual | Full debug APK installed and launched on API 35; plan chooser inspected with all copy and controls visible | Built APK starts and the matched plan state renders without overlap | Accessibility on every device size or released signing |
| Apple focused tests | 44 ownership/onboarding tests passed | Checkpoint transitions, cancellation, secure-store validation, endpoint constraints, no-redirect terms, plan behavior, and onboarding reconciliation | Live identity provider or physical possession |
| Complete Apple app tests | 1,651 tests passed with one external-fixture skip | Existing shared storage, metrics, diagnostics, onboarding, and app contracts remain green | iPhone-specific UI or hardware |
| iOS build and UI | Full iPhone/widget/Watch simulator graph built; 34 production-shell tests passed with one private-pilot skip | App graph compiles and dense/compact/accessibility/navigation/performance surfaces launch successfully | Signed phone, Watch pairing, BLE, or background behavior |
| iOS install/visual | Rebuilt app installed and launched on an iPhone 17 Pro simulator; plan chooser inspected without clipping or overlap | Exact simulator product and new plan surface run | Physical-device behavior |
| Universal macOS build | `x86_64` and `arm64` build passed and final binary contains both architectures | Hosted macOS compile shape is preserved | Signing or distribution |
| OpenTofu | Recursive format and validate passed; three ownership default-off/IAM-only guard tests passed | IaC is valid and cannot create the runtime without every explicit guard | Applied cloud state or public readiness |
| Policy gates | Private-data filename, 1,184-file health claims, localization, legal inventory/distribution, and launch-isolation gates passed | Repository policy boundaries remain intact | Legal approval or native-speaker review |
| Visual parity review | Apple and Android plan screenshots show the same default, copy, selection semantics, unavailable-payment boundary, progress, and CTA | Feature-level parity for the changed onboarding surface | Pixel identity across native frameworks |

## Physical device and deployment

- Install/update action: rebuilt iOS and Android apps installed on simulators;
  no physical phone or band install.
- Generalized device and OS class: iPhone 17 Pro simulator on iOS 26.5 and
  Android API 35 emulator.
- Data-preservation result: simulator/emulator test state only; no user health
  data was touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: supplier discovery, printed-label match, identify
  vibration, exact gesture, cryptographic possession, owner-key provisioning,
  reconnect, replacement phone, release, transfer, battery, background
  collection, and sensor behavior.

## Git and release state

- Changed paths: migration and ownership server/runtime/tests; Apple and
  Android services, secure state, UI, configuration, localization, and tests;
  guarded GCP IaC/provisioning; architecture, privacy, checklist, and operations
  records.
- Commits: commit containing this record.
- Branch and remote state: local `main` started at `2c234840`, equal to
  `origin/main`.
- Repository visibility verified: not repeated.
- Version/build impact: no version bump; this is a dormant first-release
  foundation within v9.2.1.
- Release or distribution impact: no artifact was published, no cloud resource
  was changed, and ownership activation/public ingress remain disabled.

## Decisions

- Durable decision added or changed: none; D-045 through D-051 remain binding.
- Decision-log entry: none.

## Open risks and honest limitations

- A supplier-independent foundation cannot prove or replace authenticated
  physical-band possession. Enabling activation before that provider exists
  would be a security defect.
- Identity and terms mechanisms are not production-ready until approved
  configuration, policies, abuse controls, support/recovery operations,
  security review, and signed physical evidence pass.
- Account deletion, operator release/RMA, owner-key provisioning, billing,
  approved return handling, and future upgrade release remain separate
  checklist work.
- Simulator/emulator success does not establish BLE, background execution,
  battery, haptic, physiology, sensor accuracy, or medical behavior.

## Next round

1. Integrate the approved supplier SDK and cryptographic possession provider
   after the hardware dossier and representative bands arrive.
2. Publish approved immutable terms and complete India/USA legal, return,
   support, deletion, and controlled-release operations.
3. Prove signed physical clients, production identity/App Check, private
   ownership runtime operations, abuse/load/recovery, and the complete
   two-phone/two-account matrix before public ingress.
4. Refresh the landing page only from approved product, policy, pricing, and
   support facts.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
