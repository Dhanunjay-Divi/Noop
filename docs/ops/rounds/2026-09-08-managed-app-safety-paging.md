# Round: 2026-09-08 - Managed app Safety paging

## Status

- State: `supplier-independent implementation and private synthetic staging completed; protected merge and signed physical delivery remain`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `812ac0615257596d7ec1690eb7a0f54bf0695f1d`
- End implementation commits: `71ad5cb3a88d`, `ba26eeebde81`,
  `f3c60bf2c93d`, `ea1ff2ecb125`, `f711a6a6149e`
- Record commit or PR: protected pull request `#10`; record commit pending

## Objective

Make accepted NOOP accounts the primary emergency-contact paging path. A user
must be able to invite another account, receive explicit acceptance, manually
start one bounded Safety incident, share only the latest approved location, and
receive responder state in the apps. SMS and voice remain a later fallback
rather than a prerequisite for app paging.

## Scope

### In scope

- Add tenant-scoped managed Safety contacts, invitations, incidents,
  participants, responses, latest-only location, and installation push
  registrations.
- Reuse exact-match NOOP identity and invitation capabilities without making
  emergency contacts depend on friendship, feed sharing, rankings, or contact
  upload.
- Require at least two accepted contacts before manual paging is enabled.
- Deliver only an opaque incident reference in remote push payloads; names,
  location, health values, and free text are fetched after authenticated app
  entry.
- Support responding or declining, owner cancellation/resolution, 8- or
  12-hour expiry, token rotation/revocation, bounded retries, and payload-free
  operational evidence.
- Add Apple, Android, Swift-package, server, migration, privacy, lifecycle,
  and source-isolation tests.

### Non-goals

- Do not infer falls, medical emergencies, or automatic biometric SOS.
- Do not dispatch emergency services or claim guaranteed delivery.
- Do not expose public cloud ingress, real participant data, or real paging
  traffic during source implementation.
- Do not claim APNs/FCM physical delivery until production credentials,
  entitlements, signed builds, and representative physical phones pass.
- Do not delete or weaken the existing SMS/voice fallback code.

## Starting evidence

- Current Apple and Android Safety setup accepts E.164 phone contacts and
  treats the Twilio provider as the delivery-availability gate.
- Managed Friends already provides exact-match NOOP IDs, expiring capability
  invitations, explicit mutual acceptance, installation credentials, bounded
  catch-up claims, local notifications, and eligible band haptics.
- Managed Friends has no APNs/FCM immediate-delivery path. The Apple target has
  Firebase phone-auth callback forwarding but no production push entitlement,
  and Android has no Firebase Messaging service.
- Existing legacy Safety storage supports manual incidents, latest-only
  location, responder decisions, expiry, and provider fallback, but it is not
  bound to managed NOOP accounts.

## Delivered

- Added an additive PostgreSQL managed-Safety schema for separate accepted
  contacts, one-time invitations, manual incidents, participants, responses,
  one latest location, encrypted installation push registrations, and bounded
  delivery attempts.
- Added tenant-scoped FastAPI contracts for exact-ID and invite enrollment,
  explicit acceptance/removal, contact limits, manual incident creation,
  responder state, owner end-state, latest-only location replacement, push
  registration lifecycle, catch-up, account erasure, and expiry processing.
- Added opaque managed push delivery through Android FCM registration tokens
  and Apple Firebase Installation IDs. Remote payloads contain only a fixed
  event kind, opaque incident reference, and expiry; the authenticated app
  fetches every displayable detail.
- Added Apple and Android Safety surfaces for account contacts, pending
  requests, manual paging, 8- or 12-hour duration, optional latest-location
  sharing, responder state, cancellation/resolution, push registration, and
  foreground/background reconciliation.
- Added one bounded native location session per active incident. Apple and
  Android replace the previous server fix, retry transient same-location
  network failures, stop on end/disconnect/expiry, and never retain a route
  history.
- Added high-priority Android data-only delivery with an incident-specific
  local notification, Apple notification routing and entitlement plumbing,
  invalid-registration revocation, late-registration fan-out, three-attempt
  retry with short claims, and credential tombstones after every terminal
  registration path.
- Added bounded cross-platform diagnostics for registration, reconciliation,
  contact enrollment, page lifecycle, latest-location lifecycle, notification
  routing, and fixed failure classes without retaining payloads or identifiers.
- Added all managed Safety copy to the deterministic nine-locale generator and
  both platform catalogs.
- Added guarded private GCP FCM API, least-privilege sender role/bindings,
  regional Secret Manager storage for push-token encryption, and private
  managed API/lifecycle runtime wiring. Public invocation remains disabled.
- Added a staged migration-image contract and deterministic non-secret release
  marker. A stateful OpenTofu receipt executes and awaits the matching guarded
  migration before dependent runtime revisions can update, and
  image-to-revision evidence does not expose a project path or digest in logs.
- Hardened the synthetic smoke for pilot admission by provisioning, verifying,
  refreshing, revoking, and cleaning up disposable custom claims. Failure
  output is bounded by subsystem and status rather than response data.
- Hardened long hosted commands with a fixed-label, counter-only heartbeat.
  Pull request `#10` run `34253328209` initially completed 46 of 53 Android
  production-shell tests with zero failures before the hosted runner
  terminated the silent Gradle process with exit `143`, ahead of NOOP's
  explicit timeout and diagnostic-retention path. The wrapper now keeps that
  bounded control path active without printing commands, arguments, paths,
  identifiers, or data.
- Removed cross-process Android managed-device preparation after the same
  emulator version used by a prior green run became intermittently stranded
  across Gradle invocations. Run `34253328209` passed the isolated test and
  then stopped at 46 of 53 broad tests; run `34257266178` stopped before its
  isolated test began while two emulator processes remained. The exact source
  completed the broad phase locally with 53 passes plus 2 intentional skips in
  70 seconds and the isolated phase with 1 pass in 39 seconds.
- Split the isolated Review Sample proof and the broad production-shell suite
  into independently required fresh-runner jobs. Each job now performs one
  no-daemon Gradle test invocation, has its own bounded deadline and retained
  diagnostics, and is checked by `android-ci-required`. Each test phase permits
  at most one fail-closed retry after evidence proves that its runner failed
  before any test result existed.
- Exact-head run `34264150217` then proved that a fresh hosted runner can spend
  more than ten minutes compiling the APK graph before starting an emulator.
  The broad job exited through NOOP's explicit `124` timeout and retained its
  bounded status; no test had begun. Compilation and emulator execution are now
  separately bounded on both fresh runners. The preparation phase builds only
  the app and test APKs and never starts an emulator, while each test phase may
  retry once only after the retained status and UTP evidence prove zero tests
  ran. Any assertion, partial test run, malformed status, cleanup failure, or
  second failure remains terminal.

## Data, privacy, and medical truth

- Schema impact: additive migration `027` creates managed Safety and encrypted
  push-registration tables; it does not rewrite local health stores or prior
  managed records.
- Existing-data retention: one current location exists per active incident,
  replacing the prior value and purging on cancel, resolve, expiry, profile
  erasure, or lifecycle deletion. Terminal relationship and incident records
  retain only bounded replay/audit state.
- Source/formula impact: none. Safety does not alter Charge, Effort, Rest,
  sleep, stress, age, workout, or calibration formulas.
- Permissions/network impact: location remains optional and incident-scoped;
  notification registration is revocable; remote details require managed
  authentication, App Check, and per-installation authorization.
- Push data contains only a fixed event kind, opaque incident identifier, and
  expiry. It contains no display name, coordinates, health data, response,
  phone number, or user-authored text.
- Emergency-contact relationships are separate from Friends and do not grant
  metric, journal, workout, route, or social-feed access.
- The feature remains user-confirmed wellness communication, not emergency
  dispatch or medical monitoring.

## Observability

- Success, rejection, stall, and failure evidence: mobile operation spans cover
  registration, reconciliation, contacts, page state, location session, and
  notification routing; server route templates and operational events cover
  invitation, acceptance, fan-out, response, replacement, end-state, expiry,
  retry, and revocation.
- Existing evidence reused: `AppDiagnosticsRecorder` on Apple and Android plus
  request middleware and `emit_operational_event` on the server.
- New evidence is bounded to operation kind, lifecycle state, outcome,
  duration, count, status family, and fixed failure class. High-frequency
  location and push loops emit state transitions rather than fixes or payloads.
- Mobile evidence stays local and user-initiated. Server correlation remains
  in protected service logs and is not copied into app reports.
- Tokens, capability values, coordinates, names, health values, request,
  incident, account, installation, or provider identifiers, arbitrary errors,
  response bodies, and notification content are excluded and covered by
  redaction/contract tests.
- Remaining blind spots are provider-side APNs/FCM acceptance-to-display
  latency, physical terminated/background delivery, OS suppression, and
  physical-band haptic behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source and schema review | Passed | Managed Safety is isolated from Friends and legacy provider paging; push payloads are opaque; one latest location replaces the previous fix | Physical delivery or legal approval |
| Complete server suite | 383 passed, 1 environment-gated skip | Tenant isolation, accepted-contact limits, concurrency, idempotency, late registration, terminal registration tombstones, response terminalization, bounded retries, latest-only storage, erasure, and lifecycle rules against isolated PostgreSQL | APNs/FCM provider delivery |
| macOS app suite and universal Release build | 1,656 passed with 1 external-fixture skip; build passed | Shared Apple source, localization, privacy, diagnostics, shell, and contract coverage compiles for both desktop architectures | iOS notification delivery or phone background behavior |
| Apple Release graph and iOS simulator suite | Release graph passed; 35 UI tests executed with 34 passes, 1 intentional private-pilot skip, and 0 failures | The iOS target compiles with managed push/location integration; latest-only session, relaunch, privacy, shell, tab responsiveness, calendar, complete metric catalog, and scrolling contracts execute | Signed physical-phone background execution |
| iOS scroll performance | Passed; five swipe runs averaged 5.247 seconds including XCTest idle waits, 0.220 seconds CPU time, and about 68.3 MB peak physical memory with 0.077% variation | No simulator-reproducible scroll-lag regression appeared in the current Today journey | Physical-phone frame pacing, thermal pressure, large real databases, or background BLE contention |
| Android full/demo matrix | Unit, lint, instrumentation compile, and API 35 device matrix passed; exact-source fresh-process rerun completed 53 broad tests plus 2 private-pilot skips in 70 seconds and the isolated Review Sample test in 39 seconds; the final separately bounded APK preparation, broad test, and isolated test sequence also passed locally | Managed session compiles, survives service restoration, shares one GPS listener, routes notification taps, keeps diagnostics free of coordinates, and does not reproduce the hosted 46-test stall when each phase owns one emulator lifecycle | OEM/physical background and notification behavior; fresh hosted-runner proof remains a protected-check gate |
| Swift packages and harnesses | All 9 packages, 406 protocol tests with 1 opt-in corpus skip, 104 remote-sync tests, 12 study-harness tests, and 2 backfill tests passed | Shared models/clients, protocol compatibility, deterministic research harnesses, and backfill contracts remain intact | Supplier firmware or physical physiology |
| Repository policy and legal gates | 226 tool tests plus terminology, legal inventory, distribution provenance, claims, workflow, privacy, OpenTofu, and dependency-audit gates passed | Source, manifests, generated localization, notices, workflow controls, and private infrastructure remain internally consistent | External legal approval or production credentials |
| Private synthetic staging | Passed: container scan with zero known-vulnerability findings, migration `027`, five in-place runtime updates, enforced migration execution, lifecycle execution, three-account managed smoke in 120 seconds, cleanup audit, private-boundary verification, and zero drift | Accepted Safety contacts, manual paging, latest-only location, responder state, incident resolution, storage/restore/isolation, cleanup, base private-API internal ingress, managed-API IAM-only access with no broad invoker, digest pinning, scale bounds, PITR, and deletion protection work together on the deployed digest | Provider delivery because the smoke intentionally registered no APNs/FCM target or real account |
| Deployment-order recovery | Passed: the first concurrent rollout correctly failed new readiness while prior healthy revisions retained 100% traffic; migration then succeeded, every latest revision became ready, and the stateful release receipt was applied with no cloud-resource mutation and zero drift | Required migrations fail closed without taking healthy traffic down, and future image changes cannot update dependent runtime workloads until the guarded migration succeeds | Regional failover or production rollback under load |

## Physical device and deployment

- Install/update action: no phone install. One scanned immutable digest was
  deployed to private GCP staging after migration `027`. The accepted saved
  plan made five in-place updates with zero create, delete, replacement, or
  broad/public-invoker changes. Every latest revision became ready and received
  100% of its service traffic.
- Generalized device and OS class: iOS simulator and Android local JVM/source
  contracts only; physical phones remain unrun.
- Data-preservation result: additive migration, lifecycle execution, synthetic
  object erasure, social cleanup, managed-account erasure scheduling, provider
  identity cleanup, and a final zero-drift plan pass.
- BLE/background/haptic/battery scenarios exercised: none in this round;
  physical band haptic remains a separate device gate.
- Unrun hardware gates: APNs/FCM delivery, terminated-app wake, background
  limits, notification permission, deep link, and band haptic on representative
  physical phones.

## Git and release state

- Changed paths: implementation commit `71ad5cb3a88d` changes 105 tracked paths;
  the deployment-order and smoke-harness follow-up is limited to private GCP
  infrastructure, its operator documentation, deployment contracts, and this
  durable record. The Android control follow-up changes only the managed-device
  workflow, its required-job policy digest and tests, and this record.
- Branch and remote state: protected pull request `#10` is open from the
  isolated branch; required review, normal merge, and exact-main verification
  remain pending.
- Version/build impact: no customer version increment and no signed artifact.
- Release or distribution impact: private synthetic staging only. Public
  ingress remains disabled; no real push target, real account, real health
  data, tag, store artifact, or release was created.

## Decisions

- App-to-app paging is the primary first-release Safety path.
- SMS and voice are optional fallback channels after separate India carrier,
  legal, monitoring, and operations approval.
- Location sharing is latest-only and bounded to the active incident expiry.
- Automatic biometric or fall inference remains disabled.

## Open risks and honest limitations

- Production push credentials, Apple entitlements, Google configuration,
  signed clients, physical devices, notification permission journeys, carrier
  fallback, legal review, monitoring, failover, and staffed operations remain
  external or owner-controlled gates.

## Next round

1. Continue from the first remaining external or signed-delivery dependency
   after the supplier-independent implementation is merged and verified.

## Privacy check

- [x] No credentials, phone numbers, emails, raw health values, coordinates,
      capability values, push tokens, or private identifiers are present.
