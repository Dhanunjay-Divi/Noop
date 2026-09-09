# Round: 2026-09-08 - Managed Safety review closeout

## Status

- State: `supplier-independent implementation and local verification complete;
  protected exact-head hosted review and merge pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `f733c153ddd6a134a6e61feafe2697b66b327180`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close every actionable managed app Safety review finding with regression
coverage, preserve server history and transaction boundaries, keep Apple and
Android behavior aligned, rerun the complete protected release matrix, merge
normally to protected `main`, verify the exact merged commit, and remove only
temporary resources created by the implementation and verification rounds.

## Scope

### In scope

- Resolve push-token rotation, delivery-claim, account-status, expiry
  transaction, and retained-history defects in the managed Safety server.
- Harden Apple and Android date decoding, idempotency, permission, stale-state,
  list identity, and incident/location contracts.
- Make managed Safety copy complete in every shipped locale and disclose its
  deletion behavior on both mobile platforms.
- Add focused regression tests, rerun complete local and hosted gates, respond
  to review threads with exact evidence, and merge without bypassing branch
  protection.
- Recheck simulator scrolling evidence and retain physical-phone, large-real-
  database, background BLE, thermal, and frame-pacing limitations as explicit
  external gates.

### Non-goals

- Do not enable public traffic, real paging, real participant accounts, or
  health-data transfer.
- Do not claim signed physical APNs/FCM delivery, background location, BLE,
  haptic, battery, or sensor calibration evidence from builds or simulators.
- Do not weaken local-first core NOOP or automatic-emergency safeguards.

## Starting evidence

- Reproduction or observed symptom: the current iOS simulator journey does not
  reproduce scroll lag, but a physical phone with a large real database has not
  been measured in this round.
- Relevant source/device/OS/firmware class: FastAPI/PostgreSQL managed Safety,
  shared Apple client plus iOS UI/runtime, and Android Compose/runtime.
- Existing tests, logs, exports, screenshots, or documents: pull request `#10`
  has ten green required contexts on `f733c153`; its merge remains blocked by
  unresolved review conversations.
- Unknowns that must remain unknown until measured: provider acceptance-to-
  display latency, physical-phone frame pacing and memory pressure, terminated
  app delivery, background location, band haptics, and representative real-
  database behavior.

## Delivered

- Preserved push-installation and delivery history when a revoked token is
  reassigned, while retiring the old token material under a deterministic
  non-secret digest.
- Reset every unsent delivery claim, attempt counter, retry timestamp, and
  provider reference after a real token rotation, without replaying a duplicate
  registration or rewriting a successfully sent receipt.
- Excluded suspended, erased, or otherwise inactive accounts from Safety
  contact lists, incident creation, push registration joins, and dispatch;
  pending deliveries for inactive accounts become terminally rejected.
- Wrapped read paths that perform expiry mutation in explicit transactions and
  bounded both owner-triggered and retry dispatch to one configured concurrency
  wave at a time. Owner-triggered dispatch excludes deliveries already
  attempted by the same request so a transient first-wave result cannot jump
  ahead of untouched deliveries.
- Accepted retained owner incidents with zero or one remaining participant
  after lifecycle erasure, gave reciprocal contact rows role-stable identities,
  accepted an idempotent lower server location sequence without moving the
  local high-water mark backward, and decoded fractional push expiry values.
- Made incident creation retry-safe across process death on Apple and Android:
  one account-and-options-bound request ID is retained across ambiguous
  failures and retired only after success or a terminal response.
- Made contact-request creation retry-safe across process death on Apple and
  Android: one account-and-target-bound request ID is persisted before
  transport, retained after ambiguous failures, and retired only after success
  or a terminal response. A fixed SHA-256 vector proves both platforms derive
  the same canonical target scope.
- Bound the Apple Safety invite capability and request ID in one
  device-only Keychain record, including deterministic legacy migration and a
  duplicate-insert race that returns the binding actually persisted.
- Rolled back failed automatic Safety-attempt leases on both clients; Android
  uses an atomic preferences lease and Apple restores the prior timestamp.
- Cleared stale Safety enrollment, scheduling, location sequence, invitation,
  and incident-request state after a server-side profile removal while
  preserving a pending inbound invitation.
- Required Android 13+ notification permission before FCM auto-init or token
  registration, restored auto-init after permission, classified `403` as
  forbidden instead of authentication, and stopped live location after a
  forbidden response. Apple requests time-sensitive notification delivery and
  already carries the required entitlement.
- Made Android display the generic private Safety notification synchronously
  before the FCM callback returns, then hand authenticated incident catch-up to
  unique network-only WorkManager jobs. FCM token refresh now uses the same
  durable worker boundary instead of an untracked process-local coroutine.
- Added migration `028` so an accepted Safety relationship cascades through
  its creating request during profile/account deletion instead of blocking the
  existing deletion lifecycle.
- Serialized both directions of a Safety relationship before removal and
  canceled every still-pending request in either direction in the same
  transaction, preventing an old reciprocal request from recreating a removed
  relationship.
- Restored persisted enrollment before a cold iOS Safety push checks its
  enrolled guard, so a terminated launch can authenticate and reconcile rather
  than silently dropping the catch-up.
- Required a usable app-level notification state and Safety channel on
  Android, and an authorized notification state on Apple. Both clients now
  disable provider auto-initialization and retire the server installation when
  notification delivery is unavailable.
- Expanded the account-deletion disclosure to include Safety contacts,
  invitations, incident history, active alerts, and location sharing.
- Replaced placeholder Safety text with generated translations for all nine
  shipped Safety locales and added the new authorization message to every
  complete locale plus the three intentionally feature-scoped locales.
- Upgraded the test-only `httpx2` pin from `2.9.0` to `2.12.0` after the final
  dependency audit found four newly disclosed CVEs; both runtime and dev locks
  now audit with zero known vulnerabilities.
- Added focused regression coverage for token transfer, stale-claim rotation,
  transaction boundaries, inactive recipients, bounded initial and retry waves,
  fractional timestamps, retained participant erasure, lower idempotent
  location sequences, notification policy, durable push work identity,
  contact-request replay and binding, incident-request lifecycle, profile
  deletion, reciprocal-request cancellation, cold iOS push bootstrap, and
  app/channel notification retirement.

## Data, privacy, and medical truth

- Schema or migration impact: additive migration `028` changes only the
  `managed_safety_contacts.accepted_request_id` foreign-key delete action from
  restrict to cascade. Migration `027` remains byte-for-byte unchanged.
- Existing-data retention impact: delivery history and incident audit records
  remain preserved across token reassignment. Accepted contact rows are now
  removed when the creating request is deleted through profile/account
  lifecycle cleanup, while the other account and unrelated history remain.
- Source/provenance or formula impact: none; no metric or calibration formula
  is changed by this Safety review.
- Permissions/network disclosure impact: Apple and Android registration now
  follows the runtime notification-delivery state, including Android global
  and channel controls. Precise location remains optional, latest-only, and
  incident-bounded. No new endpoint, public ingress, provider, or payload field
  is enabled.
- Health/medical claim impact and limitations: manual trusted-contact paging
  remains wellness communication, not emergency dispatch or medical
  monitoring; automatic inference stays disabled.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded mobile operation spans and server operational events cover
  registration, permission rejection, refresh, incident, expiry, delivery,
  retry, and location lifecycles.
- Why existing evidence is sufficient, or why new evidence is required:
  corrected paths reuse payload-free boundaries and tests assert the durable
  state transitions; no high-frequency or identifier-bearing log was added.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  server request correlation, and `emit_operational_event`.
- New bounded events or operation spans: notification rejection uses the
  existing fixed `managed_safety.push_registration`,
  `managed_safety.notification_enable`, and
  `managed_safety.push_revocation` boundaries. FCM receipt and token refresh
  use `managed_safety.push_received` and
  `managed_safety.push_token_refresh`, with fixed outcome, notification, and
  worker-state values only.
- Redaction, retention, and high-frequency controls: no tokens, capabilities,
  account/contact/incident identifiers, coordinates, user text, payloads,
  health values, or arbitrary exceptions may enter diagnostics.
- Cross-platform/backend correlation: fixed route groups, outcome categories,
  and server-generated request correlation remain the only shared evidence.
- Remaining blind spots: provider and physical-device behavior listed above.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Starting protected pull-request matrix | 10 required contexts passed on `f733c153` | The pre-review implementation compiled and passed its declared hosted gates | Correctness of the unresolved review findings or physical-device behavior |
| iOS simulator scroll journey | Five runs averaged 5.186 seconds including XCTest idle waits, 0.172 seconds CPU, and about 68.5 MB peak physical memory with 0.114% variation | No simulator-reproducible regression in the measured journey | Physical-phone frame pacing, thermal pressure, large real databases, or BLE contention |
| Shared Apple package | `109` tests passed | Managed Safety parsing, identifiers, cross-platform contact-target hashing, retry binding, lower-sequence replay, fractional expiry, retained incidents, and existing sync contracts are green | App-target or physical-device behavior |
| Apple app graph | Fresh exact-source NOOPiOS Debug simulator build passed; the production-shell suite passed `35` tests with `1` intentional environment skip and `0` failures; prior Release-device graph remains green | The iOS app, widgets, Watch graph, corrected notification lifecycle, cold-push bootstrap, navigation, and performance shell compile and execute | Signing, APNs display, iPhone background execution, or store upload |
| Complete macOS XCTest graph | `1,658` executed with `1` existing external-fixture skip and `0` failures | Broad Apple persistence, metrics, UI policy, backup, reporting, Safety source contracts, and integration behavior remain compatible | iOS-only and physical-band behavior |
| Android production-flavor gate | `assembleFullDebug`, `testFullDebugUnitTest`, `lintFullDebug`, and `compileFullDebugAndroidTestKotlin` passed; `4,136` unit tests with `7` existing skips and `0` failures or errors; `70` actionable tasks | Android app, resources, localization policy, synchronous notification handoff, durable Safety workers, retry binding, APK, lint, and instrumentation sources are green | Managed-emulator or physical OEM delivery/background behavior |
| Clean Python 3.12 server gate | Ruff check and format passed; `388` tests passed with only the intentionally unconfigured Twilio staging test skipped | API, PostgreSQL overlay, additive migration `028`, identity, Safety, initial/retry dispatch, profile deletion, relationship removal, lifecycle, and retention behavior pass against fresh extension-free databases | TimescaleDB container, provider traffic, or public deployment |
| Python dependency audit | Runtime and dev requirements report zero known vulnerabilities after `httpx2 2.12.0` | The checked dependency declarations satisfy the repository's zero Critical/High policy and the newly disclosed test-client issues are fixed | Future disclosures |
| Localization generation and CI audit | `304` Safety strings generated for `9` locales; `49` audit tests passed; no new unextracted Apple copy or Android complete-locale gaps | Safety copy is generated, translated, placeholder-safe, and brand-boundary clean | Human linguistic review in every market |
| Repository policy matrix | `9` release controls and `187` control tests passed; ten required contexts, terminology ratchet, calibration parity (`12` metrics, `3` revisions, `13` thresholds, `16` guards), health claims (`1,194` files), legal provenance, private-data, `49` localization tests, and `40` operations records passed | Source policy, metric parity, claims, provenance, privacy, and durable evidence remain intact | Legal approval, clinical validation, or production authorization |

## Physical device and deployment

- Install/update action: no physical-device install; unsigned simulator/debug
  artifacts only.
- Generalized device and OS class: Apple simulator/macOS and Android JVM/build
  graph only.
- Data-preservation result: fresh PostgreSQL integration tests prove retained
  push delivery history across token reassignment and transaction-safe expiry;
  no real user or device data was touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: signed APNs/FCM delivery, terminated/background
  behavior, notification and location permissions on representative phones,
  large-real-database scrolling, band haptic, BLE continuity, battery, thermal,
  and sensor calibration.

## Git and release state

- Changed paths: managed Safety server, shared Apple client, iOS runtime/UI,
  Android runtime/client/resources/tests, localization source/generated files,
  the reviewed terminology inventory and its pinned release-source digest, the
  test-only Python dependency pin, and this operations record.
- Commits: commit containing this record is pending push at the local-evidence
  checkpoint.
- Branch and remote state: pull request `#10` remains open; its previous exact
  head passed all ten protected contexts. The remediated head must rerun those
  checks and resolve every review conversation before a normal protected merge.
- Repository visibility verified: authenticated GitHub repository and pull
  request inspected.
- Version/build impact: no version increment planned.
- Release or distribution impact: none; private synthetic staging stays
  private and retained until dependent validation is complete.

## Decisions

- Durable decision added or changed: none. Manual app-to-app Safety paging and
  latest-only location remain the already-recorded owner decision.
- Decision-log entry: not required.

## Open risks and honest limitations

- Twenty-four review threads have source and local regression dispositions but
  still require exact-head hosted verification and explicit resolution.
- The local server run uses the plain PostgreSQL overlay. The protected hosted
  server context must still exercise the pinned TimescaleDB image, containers,
  backup, and restore on the pushed head.
- Physical-device and external operational gates remain outside source-only
  verification.

## Next round

1. Push the reviewed implementation, pass all ten exact-head protected
   contexts, resolve the twenty-four conversations with evidence, and merge
   normally.
2. Run exact-main verification, then perform the bounded temporary-resource
   cleanup without removing retained private synthetic staging.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
