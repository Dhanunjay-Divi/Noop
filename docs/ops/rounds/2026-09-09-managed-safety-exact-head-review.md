# Round: 2026-09-09 - Managed Safety exact-head review

## Status

- State: `implemented and locally verified; hosted replacement-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `b98f2db4e2ca6dbf9e97ffe8c49ed30b8b93cdca`
- End implementation commit: `e1521ecc`
- Record commit or PR: protected pull request `#10`

## Objective

Close every actionable finding from the automated review of the exact pull
request head without weakening managed Safety privacy, delivery, expiry,
localization, or lifecycle guarantees.

## Scope

### In scope

- Preserve failed Android push revocations across an offline disconnect.
- Route a user tap on an expired iOS Safety notification to retained history
  while continuing to reject expired background delivery.
- Send localized APNs alert keys instead of literal English notification text.
- Clear and reconcile Apple and Android Safety state immediately after a
  successful social-profile deletion.
- Add focused regression coverage and rerun all affected app/server gates.

### Non-goals

- Enable public ingress, real participant paging, or automatic emergency
  inference.
- Claim carrier, physical-phone, haptic, background-delivery, or signed-release
  evidence.
- Resolve review conversations before the exact replacement head is clean.

## Starting evidence

- Exact reviewed commit:
  `b98f2db4e2ca6dbf9e97ffe8c49ed30b8b93cdca`.
- Review findings: one P1 and four P2 comments posted at
  `2026-09-09T05:33:04Z`.
- All hosted required checks except the still-running iOS production-shell job
  were green before this replacement work began.

## Decisions

- A managed-device disconnect may complete only when no push invalidation is
  required, the server registration was revoked, or the provider token was
  deleted. If both invalidation paths fail, the account remains connected and
  retryable.
- Push expiry continues to reject background delivery. A direct user tap may
  route an expired notification to authenticated retained incident history.
- APNs receives string-catalog localization keys and no literal alert copy.
- Deleting the social profile also clears local Safety state because the server
  transaction cascades the corresponding Safety rows.

## Delivered

- Apple and Android now refuse to finalize a managed disconnect when both push
  invalidation paths fail, retain bounded diagnostics, and restore the active
  Safety runtime for a retryable connected account.
- Apple notification-response parsing accepts an elapsed expiry only after the
  user taps the delivered notification; background and foreground delivery
  parsing remains expiry-gated.
- The server emits generic APNs localization keys from the existing translated
  catalog instead of literal English notification text.
- Successful social-profile deletion clears Friends and Safety preferences,
  cached presentation, pending capabilities, location sharing, and background
  scheduling state on both phones.
- The launch-gate isolation preflight now resolves one all-target build-setting
  snapshot and groups setting names in memory instead of invoking four
  independent package-graph resolutions. Secret values remain discarded.
- Focused and broad Apple, Android, server, dependency, privacy, localization,
  release-control, and operations verification is complete locally.

## Data, privacy, and medical truth

- No health values or sensor payloads are added to push content or diagnostics.
- Safety notification content remains generic and authenticated incident detail
  remains an in-app fetch.
- No medical or guaranteed-delivery claim is introduced.

## Observability

- Retry state and outcomes must remain bounded and contain no token, account,
  contact, incident, or location values.
- Existing managed-operation diagnostics and provider delivery receipts remain
  the correlation path.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-head automated review | Five actionable lifecycle/localization findings | The replacement scope is tied to reviewed source | Physical or carrier behavior |
| Swift package focused regressions | 8 tests passed | Revocation policy and expired-response parsing are deterministic | App lifecycle or push delivery |
| Full `NoopRemoteSync` package | 110 tests passed | Shared managed models and clients remain compatible | Phone runtime behavior |
| Apple focused app regressions | 28 tests passed | Notification routing and cross-platform source contracts remain mounted | APNs or terminated-device delivery |
| Full macOS app graph | `xcodebuild test` passed in 87.442 seconds | The broad Apple app test target remains green | iOS-specific runtime behavior |
| iOS production shell | 35 journeys executed, 1 intentional private-pilot skip, 0 failures | Shipping iPhone navigation, reports, accessibility, settings, metrics, strength map, and scroll paths remain functional | Signed physical push, location, BLE, battery, or background behavior |
| Android full gate | APK assembly, full unit suite, lint, and instrumentation-source compilation passed in 2m26s | Android implementation and source contracts compile and pass repository tests | OEM background delivery or physical notification behavior |
| Android API 35 production shell | 55 tests finished, 2 intentional private-pilot skips, 0 failures | Managed production-flavor navigation and lifecycle paths remain functional | Real FCM, location, or haptic delivery |
| Fresh PostgreSQL server suite | 388 passed, 1 intentional staging skip | Repository, migration, push payload, and lifecycle behavior pass on clean databases | Exact TimescaleDB-hosted lane or live provider traffic |
| Server focused push regressions | 12 passed | APNs localization-key payload and generic notification contract are pinned | APNs acceptance on a physical phone |
| Server quality and dependency gates | Ruff check/format passed; both locked dependency audits found no known vulnerability | Changed server source is formatted and scanned against current local advisories | Future advisories or provider security review |
| Repository policy gates | Ops records, private-data guard, health claims, legal inventory, release controls, and launch-gate isolation passed | The replacement preserves repository privacy, claims, legal, and release invariants | Owner/legal approval or signed distribution |
| Hosted release-control diagnosis | The first replacement-head run failed only because changed source line numbers made the fail-closed terminology inventory stale; a reviewed regeneration records 17,376 classified occurrences, no forbidden mapping, and no active allowlist change | The hosted failure is an evidence-snapshot mismatch rather than an application or policy regression | The replacement head still requires a green hosted rerun |
| Hosted Apple preflight diagnosis | The corrected head's release-control check passed, but the iOS job spent 150 seconds on repeated cold `xcodebuild -showBuildSettings` package resolution and returned no settings for its first two targets. The replacement single all-target scan passed locally in 13.4 seconds, and its six parser/policy tests pass | Launch-secret isolation remains fail-closed while avoiding four redundant cold package resolutions | The revised exact head still requires a green hosted Apple rerun |
| Scoped resource cleanup | Six synthetic PostgreSQL databases and eight inactive temporary benchmark/build directories totaling about 20 GB were removed after their evidence was recorded | Completed local test resources are not being left to consume disk or database capacity | The intentionally retained private GCP staging stack or worktrees still needed for protected merge |

## Physical device and deployment

- No public traffic or real paging will be enabled in this round.
- Physical notification delivery, tap routing after expiry, location sharing,
  and app termination remain external release gates.

## Git and release state

- Pull request `#10` remains open and blocked until the replacement head passes
  hosted checks and exact-head review.
- Implementation commit: `e1521ecc`; the record follow-up is the pull-request
  head.
- Review threads remain unresolved until a clean exact-head review and required
  checks pass.

## Open risks and honest limitations

- Provider token deletion can remain unavailable for an unbounded offline
  period; the client must retain a retry obligation rather than claiming
  revocation.
- Simulators cannot prove APNs/FCM delivery or background execution.
- A first broad server run against two retained test databases failed only
  because those databases carried a stale checksum for immutable migration
  `001`. Fresh databases created from `template0` passed the complete suite;
  no migration was rewritten or checksum rule weakened.
- The local machine has no Docker runtime, so exact TimescaleDB overlay
  verification remains delegated to protected hosted CI.
- The active Safety and performance worktrees, one iOS simulator, and build
  daemons remain until protected merges and exact-main verification complete;
  they are not abandoned resources and will be stopped or removed at final
  closeout.

## Next round

1. Push the replacement head, obtain green protected checks and a clean
   exact-head review, resolve only verified conversations, and merge normally
   through the protected branch.

## Privacy check

- [x] No credentials, account identifiers, phone numbers, push tokens, contact
      identities, incident identifiers, or location values are present.
