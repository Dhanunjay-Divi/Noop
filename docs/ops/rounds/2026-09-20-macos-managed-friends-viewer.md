# Round: 2026-09-20 - macOS managed Friends viewer

## Status

- State: `focused implementation and verification complete; branch integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `3edddda180963444b8eb8caa48e5298623cd66f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`; no new push before consolidated gates

## Objective

Replace the macOS Friends screen's unconditional legacy self-hosted fallback
with the signed-in, read-only managed viewer already defined by the product and
server contracts. Customers do not choose or configure a Friends server.
macOS must remain unable to collect over BLE or mutate managed Friends, Safety,
sharing, upload, or paging state.

## Scope

### In scope

- macOS managed-account sign-in, App Check, explicit viewer enrollment, and
  read-only Friends/profile/request/feed refresh.
- One NOOP-hosted Friends route on macOS with no provider selector.
- macOS Firebase/configuration/App Attest target composition.
- Bounded diagnostics and focused source/runtime contract tests.
- The stale managed-retry source assertion found by the exact-current macOS
  suite.

### Non-goals

- macOS BLE collection, managed uploads, Safety initiation, location writes,
  pokes, friend-request decisions, sharing changes, or push registration.
- Account creation, band activation, managed-health consent, or payment on
  macOS.
- Public traffic, production credentials, real account or health-data transfer,
  signing, or physical-device claims.

## Starting evidence

- Reproduction: macOS renders `selfHostedBody` unconditionally in
  `FriendsView`, producing the owner-supplied screenshot that says “server you
  control.”
- The backend already accepts explicit `macos` enrollment when a separate
  macOS App Check app ID is configured and rejects non-read/restore routes with
  `managed macOS viewer is read-only`.
- `AppRuntimeRole.currentPlatform` is already `.managedViewer`, but
  `hasManagedViewerTransport` remains false and the Mac target does not link
  Firebase Auth/Core/App Check.
- The exact-current full macOS suite executed 2,203 tests with one stale
  source-shape failure after account-transition fencing was added.

## Delivered

- Added a separate macOS managed-viewer configuration with its own Firebase
  Apple app identity, App Check setup, and fail-closed missing-configuration
  state.
- Added verified email/password sign-in, explicit read-only Mac enrollment,
  account-scoped credentials, and managed profile/Friends/request/feed reads.
- Made the NOOP-hosted account service the only routed macOS Friends source.
  The prior self-hosted Friends presentation source has been removed after
  route and account-lifecycle contracts passed.
- Kept macOS outside band collection and every managed mutation path, including
  uploads, sharing changes, friend decisions, pokes, Safety paging, and
  location writes.
- Added bounded lifecycle diagnostics and source/runtime contract coverage.
- Updated the stale managed retry assertion to include account-transition
  fencing.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: managed access requires explicit
  sign-in and enrollment; there is no customer server configuration.
- Health/medical claim impact and limitations: none.

## Observability

- Success, rejection, and failure evidence: bounded sign-in, enrollment, and
  refresh operation outcomes; request route group, method, duration, status
  family, and fixed failure category.
- Forbidden evidence: email, password, account/user/installation identifiers,
  tokens, URLs, friend names, NOOP IDs, health values, summaries, request
  payloads, or exception text.
- Frequency: only user-initiated/bootstrap operations and one diagnostic per
  managed HTTP request.
- Remaining blind spots: App Attest provisioning and live Firebase/server
  behavior require signed staging evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot and source trace | passed | The defect is an unconditional macOS UI branch and missing target transport | The correction works |
| Backend macOS route-contract tests | existing green evidence | macOS enrollment is platform-bound and writes fail closed | A live signed Mac can authenticate |
| XcodeGen regeneration | passed | The Mac target resolves the new config, Firebase dependencies, and App Attest entitlement | Signed provisioning works |
| Focused macOS app tests | 6 passed, 0 failed | The managed viewer is the default, stays read-only and non-collecting, and the retry fence is current | Live Firebase/App Check/server behavior |
| Fresh local macOS visual launch | passed | A fresh preference state lands on NOOP+ and does not show the legacy self-hosted setup as the default | Configured account sign-in or live data retrieval |
| Final managed-only route contract | 33 focused Apple tests passed with zero failures | The compact Friends wrapper has no self-hosted body or service dependency and macOS remains a read-only managed viewer | Signed launch, live account access, or physical accessibility |
| Exact-current complete macOS wall | 2,207 passed, 1 intentional skip, 0 failures | The managed viewer, account fencing, shared packages, localization, and complete desktop contract suite pass together | Signed App Attest, live account/server access, notification delivery, or physical accessibility |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS build/test only
- Data-preservation result: no local data mutation is planned
- BLE/background/haptic/battery scenarios exercised: not applicable to this
  read-only viewer
- Unrun hardware gates: signed App Attest, live account, live server, network
  loss/recovery, accessibility hardware

## Git and release state

- Changed paths: Mac target configuration, runtime role, Friends routing,
  managed-viewer service/UI, focused tests, and this round record
- Commits: pending
- Branch and remote state: existing PR branch; consolidate before one push
- Repository visibility verified: not changed
- Version/build impact: no version bump planned
- Release or distribution impact: adds a credential-gated macOS viewer path

## Decisions

- macOS uses the managed NOOP viewer when configured.
- Friends exposes no customer provider or self-hosted setup choice.
- macOS managed Friends is read-only; mutations remain phone-only.

## Open risks and honest limitations

- Actual macOS Firebase app configuration and App Check registration are
  external credential/signing gates.

## Next round

1. Run focused and full macOS verification, then continue the consolidated
   Apple/Android/release wall before protected integration.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
