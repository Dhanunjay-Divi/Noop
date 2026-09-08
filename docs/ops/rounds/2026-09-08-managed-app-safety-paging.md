# Round: 2026-09-08 - Managed app Safety paging

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `812ac0615257596d7ec1690eb7a0f54bf0695f1d`
- End implementation commit: pending
- Record commit or PR: pending

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
| Android full/demo matrix | Unit, lint, instrumentation compile, and API 35 device matrix passed; 55 device tests with 2 private-pilot skips | Managed session compiles, survives service restoration, shares one GPS listener, routes notification taps, and keeps diagnostics free of coordinates | OEM/physical background and notification behavior |
| Swift packages and harnesses | All 9 packages, 406 protocol tests with 1 opt-in corpus skip, 104 remote-sync tests, 12 study-harness tests, and 2 backfill tests passed | Shared models/clients, protocol compatibility, deterministic research harnesses, and backfill contracts remain intact | Supplier firmware or physical physiology |
| Repository policy and legal gates | 222 tool tests plus terminology, legal inventory, distribution provenance, claims, workflow, privacy, OpenTofu, and dependency-audit gates passed | Source, manifests, generated localization, notices, workflow controls, and private infrastructure remain internally consistent | External legal approval or production credentials |
| Private synthetic staging | Prerequisite FCM/IAM/secret/runtime wiring applied; digest image, migration, and synthetic flow pending | Private internal ingress, no broad invoker, digest pinning, scale bounds, PITR, and deletion protection remain intact | New managed Safety API behavior until the new image and migration run |

## Physical device and deployment

- Install/update action: no phone install. Private GCP FCM/IAM/secret/runtime
  prerequisites were applied with zero delete, zero replacement, and zero
  public-invoker changes; digest image and migration remain pending.
- Generalized device and OS class: iOS simulator and Android local JVM/source
  contracts only; physical phones remain unrun.
- Data-preservation result: additive migration and lifecycle tests pass;
  deployed private migration and synthetic cleanup evidence remain pending.
- BLE/background/haptic/battery scenarios exercised: none in this round;
  physical band haptic remains a separate device gate.
- Unrun hardware gates: APNs/FCM delivery, terminated-app wake, background
  limits, notification permission, deep link, and band haptic on representative
  physical phones.

## Git and release state

- Changed paths: pending.
- Branch and remote state: isolated branch from exact protected `main`.
- Version/build impact: pending.
- Release or distribution impact: none; no public traffic or release mutation
  is authorized by this round.

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
