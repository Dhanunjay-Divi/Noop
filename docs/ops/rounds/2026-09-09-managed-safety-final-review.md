# Round: 2026-09-09 - Managed Safety final review

## Status

- State: `implemented and locally verified; replacement exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `94dfe9d04b54dee706f56361724640ded32f2773`
- End implementation commit: the replacement pull-request head containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close every actionable finding from the automated review of the replacement
pull-request head while preserving tenant isolation, fail-closed responder
state, durable latest-location-only sharing, localization, privacy, and the
existing external launch gates. The final pass also closes the subsequent
review findings in the iOS Firebase registration and FCM authorization path.

## Scope

### In scope

- Normalize PostgreSQL row-lock ordering between contact acceptance and
  profile blocking.
- Recompute incident acknowledgement when the final available responder
  changes to `cannot_respond`.
- Make an active Apple location-sharing session recoverable after process
  termination without persisting coordinates.
- Present localized app-owned incident status labels on Apple and Android.
- Register the iOS Firebase Messaging value as an FCM registration token while
  preserving rolling compatibility with pre-fix rows labeled `fid`.
- Recheck iOS notification authorization at every token callback and retire an
  installation that can no longer display alerts.
- Invalidate and reacquire a rejected cached FCM OAuth token once after `401`.
- Add focused regressions, rerun affected full gates, and obtain a clean exact
  protected-head review before merge.

### Non-goals

- Enable public traffic, automatic emergency inference, SMS/voice paging, or
  real participant paging.
- Claim physical APNs/FCM, terminated-background location, haptic, battery,
  legal, monitoring, failover, or staffed-operations evidence.

## Starting evidence

- Exact reviewed head:
  `94dfe9d04b54dee706f56361724640ded32f2773`.
- All required hosted checks passed on that exact head before the review
  findings were posted.
- Four actionable findings identify one database deadlock race, two incident
  lifecycle failures, and one cross-platform localization gap.
- The subsequent exact-head review of `eee0b733cc2f84cfefbb60504a8351ff01769c4c`
  identified three additional delivery defects: iOS sent an FCM registration
  token under the unsupported HTTP v1 `message.fid` field, token callbacks did
  not recheck notification authorization, and an FCM `401` left the rejected
  OAuth token cached through later delivery attempts.

## Delivered

- Contact acceptance now acquires the two active profile rows before the
  mutable request row. Blocking and acceptance therefore use the same
  profile-before-request order, and a deterministic PostgreSQL regression
  holds both profile rows while proving the accept path has not already locked
  the request.
- Active incidents now derive `open` versus `acknowledged` from the current
  participant rows after every response, contact removal, or profile block.
  When the final responding contact withdraws or is revoked, the incident
  reopens and its acknowledgement timestamp is cleared.
- Apple persists only an opaque incident UUID and bounded expiry for an active
  location-sharing session. A returning enrolled process restores that session,
  standard updates remain the fresh-fix path, and significant-location
  monitoring supplies the system-managed relaunch path. Ending, expiry,
  sign-out, profile deletion, or server-terminal reconciliation clears the
  persisted session and both location services.
- The iOS application delegate recognizes a Core Location launch, rechecks the
  launch-access and Terms gates, and bootstraps managed state on the main actor.
  Normal operational launches use the same idempotent bootstrap.
- Apple and Android map every incident and participant wire status to app-owned
  localized copy. Unknown future values fail closed to a localized
  `Unavailable` label instead of exposing an enum or partially English text.
- The Safety catalog was regenerated as 313 strings across all nine supported
  locales. No coordinate, account, contact, incident identifier, provider
  response, or arbitrary error entered diagnostics.
- The first hosted macOS rerun correctly rejected a stale contract that still
  expected the pre-status catalog size of 304. The invariant now pins the
  generated 313-entry catalog, and the exact focused macOS test passes.
- Apple now registers the Firebase Messaging delegate value as `token`.
  Migration `029` allows both corrected iOS `token` rows and existing iOS
  `fid`-labeled rows during a rolling update; the provider sends either stored
  value through FCM HTTP v1 `message.token` and retains the existing APNs
  localization, expiry, collapse, sound, and time-sensitive overrides.
- Every iOS token callback now reads current notification settings. Denied,
  undetermined, or unknown authorization retires the server installation and
  records only a fixed rejection reason; an enrollment or disconnect change
  while the settings read is suspended cancels publication.
- The FCM provider clears a cached access token only when it is the token that
  received `401`, reacquires metadata authorization, and retries once. A second
  `401` remains retryable-unavailable instead of consuming later attempts with
  the same stale credential. Concurrent refreshes cannot clear a newer token.
- The immutable migration restore manifest includes the exact checksum for
  migration `029`; the complete clean-database server suite passes.

## Data, privacy, and medical truth

- Schema or migration impact: additive migration `029` replaces only the
  push-target check constraint so iOS accepts `token` or legacy `fid` while
  Android remains restricted to `token`. No encrypted token row is rewritten.
- Existing-data retention impact: none expected.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: latest location remains opt-in,
  latest-only, and restricted to authenticated accepted Safety contacts.
- Health/medical claim impact and limitations: no automatic emergency or
  guaranteed-delivery claim is introduced.

## Observability

- Existing managed request correlation and bounded Safety operation events
  cover server success/rejection/failure.
- `managed_safety.push_registration` records completed, canceled, rejected, or
  fixed-category failure outcomes without recording the FCM token,
  authorization value, installation, account, or provider payload.
- Existing push batch and delivery receipt outcomes distinguish accepted,
  invalid, rejected, transient, and unavailable provider results. OAuth token
  values and FCM response bodies remain absent from operational evidence.
- Apple restoration evidence must record only fixed lifecycle categories and
  bounded outcomes; it must never include coordinates, identifiers, account or
  contact data, payloads, provider errors, or arbitrary exception text.
- Remaining physical push and background-location behavior will stay explicit
  as unproven external evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-head automated review | Four actionable findings reproduced and addressed | Scope is tied to reviewed source | Correctness after remediation |
| Fresh PostgreSQL managed-Safety file | 10 passed in 2.02 seconds against a disposable extension-free database | Real lock ordering, acknowledgement transitions, block behavior, and existing managed-Safety integration remain valid | Cross-region or production load behavior |
| Full server suite | 371 passed, 19 intentional environment-gated skips in 95.57 seconds | The server patch does not regress the locally runnable API, migration, ownership, social, or Safety contract | Hosted container, backup, and provider delivery gates |
| Apple Safety regression | 30 passed with `TEST SUCCEEDED` | Bounded restoration policy, launch wiring, status localization, and existing Safety shell contracts hold | A physical terminated-process Core Location relaunch |
| iOS simulator app build | `NOOPiOS` Debug simulator graph completed with `BUILD SUCCEEDED` | The application delegate, Firebase-managed service, Core Location, widgets, and watch dependencies compile together | Signing, APNs, GPS delivery, battery, or real background execution |
| Android Safety regression | 29 focused tests completed with `BUILD SUCCESSFUL` | Localized status mapping and existing location/session contracts compile and pass | FCM delivery, OEM process behavior, or physical GPS |
| Server formatting and generated localization | Ruff check/format passed; 313 strings regenerated for nine locales; JSON, Ruby, and diff checks passed | Changed source is formatted and generated resources match the catalog | Human linguistic review of every translation |
| Hosted macOS localization contract | The first exact-head run exposed the stale 304-entry assertion; the corrected 313-entry invariant passed locally in 0.074 seconds | The test now matches the reviewed generated catalog instead of masking a hosted failure | The replacement protected head still requires a green hosted rerun |
| Terminology ratchet | 17,376 classified occurrences across 1,509 path/category groups; zero forbidden mappings; active allowlist unchanged | Generated line movement and new source text were reviewed and the fail-closed snapshot is current | Removal of existing compatibility terminology |
| Subsequent exact-head review | Three actionable FCM registration, authorization, and cached-credential findings reproduced and addressed | The final replacement scope is tied to reviewed source | Physical APNs/FCM delivery |
| Complete fresh PostgreSQL server suite | 390 passed and the one real-Twilio staging test remained intentionally opt-in; disposable database created from `template0` and removed by an exit trap | Migration `029`, restore checksum, an in-place legacy-`fid` to corrected-`token` registration upgrade, provider payload, `401` refresh, repositories, tenancy, and existing server behavior pass together | Live FCM, Twilio, Cloud Run, or production database behavior |
| Full `NoopRemoteSync` package | 110 tests passed | Shared iOS/Android managed client models send and accept the corrected token contract | App callback or provider delivery behavior |
| Apple Safety regression after final review | 30 tests passed with zero failures | The notification authorization recheck, server retirement path, corrected token kind, and prior Safety shell contracts remain mounted | A physical notification permission transition or APNs delivery |
| Complete iOS simulator app graph after final review | Generic iOS simulator staging build completed with `BUILD SUCCEEDED` | Firebase Messaging, managed service, widgets, watch dependencies, and the corrected callback compile together | Signing, APNs acceptance, terminated execution, or battery behavior |
| Server quality gate after final review | Ruff check and format check passed | Changed provider and repository source conforms to the pinned server quality rules | Future dependency advisories or live provider behavior |
| Repository release-integrity matrix | 187 protected-control tests; 9 release checks; required CI, operations, terminology, calibration, localization, claims, legal/distribution, private-data, shell syntax, and shellcheck gates passed | The exact local replacement preserves immutable migration, trust-root, privacy, evidence, and release-policy contracts | Hosted execution or external launch approval |

## Physical device and deployment

- Install/update action: unsigned simulator build only; no physical app
  container was changed.
- Generalized device and OS class: iOS 26.5 simulator build target; no physical
  phone.
- Data-preservation result: no destructive data operation planned.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: APNs, FCM, process termination, background location,
  haptics, battery, and physical contact paging.

## Git and release state

- Changed paths: managed server provider, models, repository, migration,
  restore manifest, and tests; shared managed client contract and tests; Apple
  managed notification registration and Safety shell test; terminology
  snapshot, pinned digest, and operations records.
- Commits: prior implementation `e1c02d0b`; the replacement commit containing
  migration `029`, the three final review remediations, and this record becomes
  the protected pull-request head used for hosted checks and review.
- Branch and remote state: protected pull request `#10` remains open.
- Repository visibility verified: inherited from the exact-head review round.
- Version/build impact: no version change planned.
- Release or distribution impact: no release artifact or public deployment.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: not required.

## Open risks and honest limitations

- A simulator or source test cannot prove terminated-process location
  restoration on a physical iPhone.
- A simulator cannot prove FCM-to-APNs acceptance, token rotation after an
  installed-app upgrade, or notification authorization changes on a physical
  phone.
- Provider, legal, monitoring, failover, and staffed-operations gates remain
  outside this supplier-independent source round.

## Next round

1. Commit and push the verified replacement head.
2. Obtain a clean exact-head automated review and all protected hosted checks.
3. Resolve only findings verified against that exact head, then merge normally.
4. Keep public traffic and real participant paging disabled until physical
   push/location, legal, monitoring, failover, and staffed-operations gates
   pass.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
