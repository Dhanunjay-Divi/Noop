# Round: 2026-09-09 - Managed Safety final review

## Status

- State: `implemented and locally verified; protected exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `94dfe9d04b54dee706f56361724640ded32f2773`
- End implementation commit: `e1c02d0b`
- Record commit or PR: protected pull request `#10`

## Objective

Close every actionable finding from the automated review of the replacement
pull-request head while preserving tenant isolation, fail-closed responder
state, durable latest-location-only sharing, localization, privacy, and the
existing external launch gates.

## Scope

### In scope

- Normalize PostgreSQL row-lock ordering between contact acceptance and
  profile blocking.
- Recompute incident acknowledgement when the final available responder
  changes to `cannot_respond`.
- Make an active Apple location-sharing session recoverable after process
  termination without persisting coordinates.
- Present localized app-owned incident status labels on Apple and Android.
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

## Data, privacy, and medical truth

- Schema or migration impact: none expected.
- Existing-data retention impact: none expected.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: latest location remains opt-in,
  latest-only, and restricted to authenticated accepted Safety contacts.
- Health/medical claim impact and limitations: no automatic emergency or
  guaranteed-delivery claim is introduced.

## Observability

- Existing managed request correlation and bounded Safety operation events
  cover server success/rejection/failure.
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

- Changed paths: managed server repositories and tests; Apple Safety runtime,
  managed service, app delegate, view, and tests; Android Safety view and test;
  generated nine-locale Safety resources; the macOS localization contract;
  terminology snapshot and pinned digest; operations records.
- Commits: implementation `e1c02d0b`; this record follow-up will become the
  protected pull-request head used for hosted checks and review.
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
- Provider, legal, monitoring, failover, and staffed-operations gates remain
  outside this supplier-independent source round.

## Next round

1. Commit and push the verified replacement head.
2. Obtain a clean exact-head automated review and all protected hosted checks.
3. Resolve only findings verified against that exact head, then merge normally.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
