# Round: 2026-09-05 - Native managed staging pilot

## Status

- State: `completed for private synthetic simulator pilot; public and physical-device gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `5671de3d`
- End implementation commit: `f1121490` plus the closeout commit containing this record
- Record commit or PR: commit containing this record

## Objective

Connect the existing optional NOOP+ iOS and Android clients to a controlled
synthetic GCP staging path, retain one fictional operator test identity, prove
the native enrollment and managed-storage journeys on both simulators, deploy
only the required cloud changes, and publish verified source and records to
`main`.

Core NOOP must remain account-free, fully useful offline, and independent of
NOOP+. The retained identity is a scoped staging tester, not an application or
infrastructure administrator.

## Scope

### In scope

- Audit the managed mobile configuration, Firebase OTP/App Check, Cloud Run
  ingress, and client enrollment boundaries.
- Implement the smallest legitimate staging access topology for native clients
  without embedding Google Cloud IAM credentials.
- Restrict staging enrollment to explicit fictional pilot identities and keep
  processor, migration, and lifecycle workloads private.
- Exercise decline, verified-but-not-consented, enrollment, synthetic upload,
  processing, restore, retry/idempotency, revocation, erasure, and cloud-outage
  behavior where simulator evidence can legitimately cover it.
- Build, install, and launch current iOS and Android applications in simulators.
- Review bounded observability, redeploy by immutable digest if source changes,
  verify infrastructure drift, update durable records, and push verified work
  to `main`.

### Non-goals

- Upload real health or biometric data to synthetic staging.
- Grant an app user administrative backend or infrastructure access.
- Claim BLE, background collection, battery, haptic, carrier, Play Integrity,
  or App Attest behavior from simulators.
- Open production enrollment or describe public distribution as launch-ready.

## Starting evidence

- Reproduction or observed symptom: the deployed managed API is IAM-only and
  released mobile configuration is disabled, so the existing private synthetic
  smoke does not prove that either native app can complete NOOP+ enrollment,
  upload, or restore.
- Relevant source/device/OS/firmware class: iOS and Android simulator builds,
  Firebase phone identity and Authentication App Check, Cloud Run managed API,
  Cloud SQL, Cloud Storage, Pub/Sub, and private processor/lifecycle workloads.
- Existing tests, logs, exports, screenshots, or documents: the server suite,
  native managed-client tests, private synthetic runtime smoke, image scan,
  migration/lifecycle executions, and zero-drift plan passed in the preceding
  rounds at `5671de3d`.
- Unknowns that must remain unknown until measured: signed physical-device
  attestation, operating-system background delivery, real wearable behavior,
  production abuse rates, carrier behavior, and real-data scale.

## Delivered

- Added a `pilot` managed-entitlement mode. A first enrollment is admitted
  only when the current Firebase Identity Toolkit user record contains the
  exact boolean custom attribute `noop_managed_pilot: true`. Missing, malformed,
  oversized, array-valued, or non-boolean custom attributes fail closed.
  Existing enrolled accounts retain the established entitlement lifecycle.
- Added a guarded operator tool that authenticates the one configured fictional
  test phone, provisions or removes only the pilot admission claim, generates
  mode-`0600` ignored native configuration, registers temporary App Check debug
  assertions, verifies the deployed private pilot, and removes assertions
  without printing the phone, code, API keys, tokens, user identifier, or
  resource names.
- Added a loopback-only IAM relay for simulator use. It binds only
  `127.0.0.1`, accepts only managed API and health-probe paths, injects the
  operator's short-lived Cloud Run identity assertion through
  `X-Serverless-Authorization`, preserves the app's Firebase authorization,
  rejects public/non-Cloud-Run targets, refuses upstream redirects, and bounds
  request and response bodies. IAM material remains on the development Mac.
- Added explicit cleartext exceptions for `127.0.0.1` on Apple and
  `10.0.2.2`/loopback on Android. They require ignored configuration and a
  Debug simulator/emulator build. Public or LAN HTTP endpoints remain rejected,
  and Release/physical Apple and Android execution cannot enable the exception.
- Added Debug-simulator fictional-phone verification support without embedding
  the OTP. The configured test number must exactly match the submitted number;
  all ordinary builds retain normal Firebase app verification.
- Added stable accessibility identifiers and Compose test tags for NOOP+ entry,
  setup, phone, code, consent, enrollment, enrolled, and sync surfaces.
- Added bounded `managed_auth.send_code`, `managed_auth.verify_code`, and
  `managed_enrollment` operation spans on Apple and Android. Outcomes and
  failure kinds are fixed categories; phone, OTP, identity, token, URL,
  payload, and health data are excluded.
- Hardened temporary assertion cleanup so invalid state fails closed and a
  partial provider deletion preserves only the unresolved resource for a
  subsequent cleanup attempt.
- Forwarded iOS APNs registration, Firebase phone-auth notification callbacks,
  and Firebase callback URLs through the SwiftUI application lifecycle. The
  APNs token is retained until the optional managed Firebase runtime is
  configured.
- Corrected Swift decoding for production snake-case response keys whose model
  properties contain acronyms such as `ID`, `SHA256`, and `JSON`. Corrected
  Android parsing so explicit JSON `null` values remain absent instead of
  becoming the literal string `"null"`.
- Added production-shaped response regressions on both platforms and a guarded
  Android native-pilot instrumentation journey. The iOS pilot gained reliable
  authentication-field focus, repeat-run sign-out handling, and stable
  identifiers attached to the exact enrolled and sign-out controls.
- Classified Firebase provider failures into fixed, payload-free categories on
  both clients. Diagnostics distinguish invalid input, rate limiting,
  configuration, app verification, expiry, authentication, transport, and
  generic provider failures without recording provider messages, phone
  numbers, codes, tokens, or identifiers.

## Data, privacy, and medical truth

- Schema or migration impact: none. Admission reads a current provider
  attribute and reuses the existing managed account schema.
- Existing-data retention impact: no real or existing user data is changed.
  Native testing is limited to empty or generated synthetic simulator state.
- Source/provenance or formula impact: none intended.
- Permissions/network disclosure impact: NOOP+ remains separately disclosed
  and explicitly consented; core NOOP makes no managed request. Cloud Run
  remains IAM-only, and no IAM credential enters either app.
- Health/medical claim impact and limitations: infrastructure and simulator
  evidence do not validate physiology or medical behavior.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: native
  authentication and enrollment now have explicit begin/end operation spans;
  managed HTTP retains static route groups, status families, duration, and the
  server request ID; the server middleware records the corresponding bounded
  request outcome. The operator tools return fixed PASS/FAIL states without
  credential or identity detail.
- Why existing evidence is sufficient, or why new evidence is required: the
  existing sync span begins only after enrollment, so it could not distinguish
  phone-verification or first-enrollment stalls. The three new spans close that
  gap. Relay behavior is diagnosed by fixed HTTP status and process exit, while
  Cloud Run retains the authoritative request event.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: `managed_auth.send_code`,
  `managed_auth.verify_code`, and `managed_enrollment` on both clients.
- Redaction, retention, and high-frequency controls: no phone number, OTP,
  token, app-check material, installation/account identifier, health value,
  payload, URL, or arbitrary provider error enters diagnostics. Each user
  action creates one bounded span; no per-request relay log or per-row event is
  added.
- Cross-platform/backend correlation: server-generated bounded request IDs and
  static route groups only.
- Remaining blind spots: physical attestation, background scheduling, BLE,
  battery, haptics, and real-user network behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Starting repository audit | `main` clean and equal to `origin/main` at `5671de3d` | Work begins from the published closeout | Native cloud connectivity |
| Full server suite on disposable PostgreSQL 14 | `275 passed, 1 skipped`; the skip is the explicit real-carrier test | Pilot admission, migrations through `025`, managed storage/social, tenancy, and existing server behavior execute against standard PostgreSQL | Cloud Run deployment or carrier delivery |
| `swift test` in `Packages/NoopRemoteSync` | 100 passed, 0 failed | Apple transport, production response decoding, loopback restriction, retry, restore, export, social, and existing sync contracts | App-target compilation or simulator UI |
| Focused Android compile and unit run | 29 tasks completed successfully | Kotlin changes compile and managed transport tests pass | Packaging, lint, or emulator behavior |
| Fresh iOS Debug simulator graph | Passed across 89 targets; the app installed and launched on an iOS 26.5 iPhone simulator | Current iPhone, Watch, widgets, Live Activities, Firebase integration, and app-target Swift compile together | Signing, App Attest, APNs delivery, BLE, background execution, or battery |
| Private-pilot operator tests | 5 passed | Cloud Run target/path constraints, no-follow redirects, strict mode-`0600` state, and partial cleanup behavior | Google provider behavior until exercised live |
| OpenTofu format and validate | Passed | The `pilot` variable contract is valid IaC | Applied infrastructure |
| Repository tool suite | 37 passed | Tooling, legal, launch-gate, private-pilot, and workflow contracts remain intact | Native runtime behavior |
| Privacy, claims, localization, legal, and round-record gates | Passed | No detected tracked credential/private export, new health claim, localization debt, legal inventory drift, or malformed operations record | Independent privacy, legal, security, or native-speaker review |
| Android Release compile attempt | Stopped at the mandatory private-signing guard before compilation | The repository refuses an unsigned/public-debug-key Release artifact | A signed Release build; no keystore is available in this environment |
| Full Android Full/Demo debug matrix | Build succeeded in 5m05s; 115/115 tasks executed | Both production and demo flavors compile, package, pass unit tests, and pass lint with the current managed configuration code | Signed Release, physical device, Play Integrity, BLE, or background behavior |
| Fictional pilot claim provisioning | First attempt failed safely at Google control HTTP 403; fixed missing OAuth quota-project binding, added a regression test, and the retry passed | Exactly the retained fictional test identity now carries the current pilot-admission attribute without printed credentials or identifiers | Native client behavior until exercised separately |
| Capacity incident and retry | The first fresh iOS build, Android lint run, and one runtime-verifier attempt failed with about 120 MB free. Only named stale NOOP build outputs were removed; free space recovered to 29 GB, and every affected check passed on retry. Final closeout had 26 GB free. | Initial failures were host-capacity failures rather than hidden code successes; successful retries used the same source | Product behavior under physical-device storage pressure |
| iOS shell and private native pilot | Five-tab offline navigation passed 1/1. The opt-in private enrollment, consent, initial synthetic sync, and two repeat syncs passed 1/1 with no skip or failure. | Core navigation remains offline-capable, and the native iOS client completes the scoped simulator journey against private staging | Real carrier OTP, signed App Attest, background upload, or physical hardware |
| Android private native pilot | The guarded instrumentation completed the enrollment, consent, initial synthetic sync, and two repeat syncs in 17.872 seconds: `OK (1 test)` | The native Android client completes the scoped emulator journey against private staging | Real carrier OTP, signed Play Integrity, background upload, or physical hardware |
| Final Android Full gate | Forced no-cache compile, unit, lint, and APK run passed 59/59 tasks in 5m28s | The final Kotlin source compiles, unit tests pass, lint passes, and the Full APK packages | Signing, Play Integrity, BLE, OEM background behavior, or battery |
| Android connected instrumentation | `connectedFullDebugAndroidTest` succeeded in 1m31s with 43 tests, 2 explicit private-input skips, and 0 failures; the exact APK then installed and launched on an API 35 emulator | The final Full APK and generic production-shell journeys execute on an emulator; private-input tests remain opt-in in the broad suite | Signed hardware, Play Integrity, carrier OTP, BLE, or background execution |
| Native visual inspection | Fresh iOS and Android NOOP+ captures were readable, unclipped, and equivalent in title, optional-storage boundary, state, status, and setup action | The tested builds render the same managed-storage contract at the inspected viewport | Full accessibility acceptance, every viewport, motion, or physical-device rendering |
| Scoped pilot and cleanup verification | Operator `verify` passed; cleanup reported no temporary App Check assertions; the loopback relay and Cloud Run proxy were stopped | One fictional identity retains only `noop_managed_pilot`, the runtime is in pilot mode, and temporary simulator authority is absent | A production mobile ingress topology or administrator account |
| Final cloud and infrastructure checks | Private-runtime verifier passed; OpenTofu format/validate passed; detailed plan exited `0` with no changes | Cloud Run remains IAM-only, Cloud SQL PITR/deletion protection remain enabled, the deployed source has zero drift, and no redundant deployment is needed | Load, disaster recovery, public launch, or physical-client attestation |
| Final repository gates | 37 tool-policy tests, localization/brand coverage, 1,175-file health-claims scan, private-data guard, 213-component legal inventory, distribution provenance, and whitespace checks passed | The closeout satisfies the repository's tracked policy gates without detected committed private test material | Independent legal, privacy, security, or native-speaker review |

## Physical device and deployment

- Install/update action: fresh unsigned iOS simulator app and final Android Full
  debug APK installed and launched.
- Generalized device and OS class: current iOS 26.5 simulator and Android API 35
  emulator.
- Data-preservation result: no physical-device data was modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed physical-device and wearable scenarios.

## Git and release state

- Changed paths: managed server admission/configuration/tests; Apple and Android
  managed configuration, authentication callbacks, production response
  decoding, diagnostics, UI identifiers, and native tests; guarded GCP
  variable; private pilot/relay tools and tests; ignored-file boundary;
  operations records.
- Commits: `f1121490` and the closeout commit containing this record.
- Branch and remote state: `main` equaled `origin/main` at the start; final
  push and equality verification are part of closeout.
- Repository visibility verified: not repeated.
- Version/build impact: no marketing-version or build-number change.
- Release or distribution impact: synthetic staging only.

## Decisions

- Durable decision added or changed: a private native pilot keeps Cloud Run
  IAM-only and admits only a current claim-scoped fictional tester; an app user
  is never granted application or infrastructure administrator privilege.
- Decision-log entry: `D-041`.

## Open risks and honest limitations

- The loopback IAM relay is development-only. It proves native managed behavior
  without public ingress, but it is not a production mobile topology. It and
  the underlying local Cloud Run proxy were stopped after the simulator run.
- Simulator debug App Check proves only the debug-provider path. It cannot
  replace signed App Attest or Play Integrity evidence.
- The retained fictional tester is an application pilot identity, not an
  operator, support, database, Firebase, or Google Cloud administrator.

## Next round

1. Complete signed physical-device enrollment, background sync, restore,
   revocation, low-storage, and upgrade evidence after this synthetic pilot.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
