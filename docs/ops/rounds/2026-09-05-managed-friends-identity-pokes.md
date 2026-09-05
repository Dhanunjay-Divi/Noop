# Round: 2026-09-05 - Managed Friends identity, sharing, badges, and pokes

## Status

- State: `deployed and verified in private synthetic staging; physical delivery pending`
- Owner: project team
- Branch: `main`
- Start commit: `68e305bd`
- End implementation commit: commit containing this record
- Record commit or PR: commit containing this record

## Objective

Extend optional NOOP+ with a privacy-preserving managed Friends experience.
Each enrolled account should receive a shareable exact-match NOOP ID, support
revocable invitation links and explicit friend requests, expose only
user-selected daily details after acceptance, provide non-competitive
achievement badges, and allow a friend to send a rate-limited poke only when
the recipient has opted in. A received poke should produce generic local
notification and best-effort band haptic behavior on both iOS and Android.

## Scope

### In scope

- Define stable exact-ID lookup without a browseable name or contact directory.
- Add revocable, expiring invitation links that create pending requests rather
  than immediate friendships.
- Reuse the six-field Friends summary boundary and require directional,
  per-friend consent before any metric is returned.
- Add bounded wellness achievements that do not rank health values or create
  medical claims.
- Add recipient-controlled pokes with per-friend permission, block handling,
  cooldowns, daily limits, quiet hours, expiry, and idempotent delivery.
- Add equivalent Apple and Android managed clients, UI, notification routing,
  and best-effort connected-band haptics.
- Add tenant-isolation, abuse-control, redaction, and lifecycle tests.
- Deploy only to private synthetic staging after every code-verifiable gate
  passes.

### Non-goals

- Public name search, contact upload, follower counts, leaderboards, or health
  ranking.
- Sharing raw streams, locations, journals, sleep stages, workouts, routes,
  device identifiers, or every account record by default.
- Guaranteeing a closed-app notification or band vibration without configured
  APNs/FCM delivery and representative physical-device evidence.
- Making an account, NOOP+, Friends, or network access necessary for core NOOP.
- Enabling real health-data traffic in synthetic staging.

## Starting evidence

- Reproduction or observed symptom: the owner requested a unique user ID,
  shareable link and exact Friends search, shared details, motivating badges,
  and opt-in pokes that notify and vibrate the band.
- Relevant source/device/OS/firmware class: optional NOOP+ managed service,
  Firebase identity/App Check, FastAPI/PostgreSQL, iOS 17+, Android API 26+,
  and connected supported-band haptics.
- Existing tests, logs, exports, screenshots, or documents: invitation-only
  self-hosted Friends already provides accepted-only six-field summaries and
  directional visibility. Managed storage is deployed only in private
  synthetic staging. The current worktree also contains intentional,
  uncommitted observability and staging-retention rounds that must be preserved.
- Unknowns that must remain unknown until measured: APNs/FCM credentials and
  delivery, signed-device attestation, notification receipt while suspended,
  connected-band haptic behavior, abuse rates, and user comprehension.

## Delivered

- Added one optional managed Friends profile per enrolled NOOP+ account. The
  service allocates a random, rotatable exact-match
  `NOOP-XXXX-XXXX-XXXX-XXXX` alias from an ambiguity-free alphabet; there is no
  browseable name, phone-contact, follower, or suggested-profile directory.
- Added profile links and expiring invitation links on both iOS and Android.
  Opening a profile link stages only its exact-match alias for review. An invite
  carries a random capability, is stored as a digest on the server, can be
  revoked, expires within 72 hours by default, and creates only a pending
  request. Received invite capabilities are stored in Keychain or encrypted
  preferences and never enter diagnostics.
- Added explicit incoming/outgoing request review, mutual acceptance, removal,
  blocking, alias rotation, and managed Friends deletion. A block removes
  sharing and pending pokes and hides exact-ID lookup in both directions.
- Added directional per-friend sharing for only Charge, Effort, Rest, sleep
  duration, HRV, and resting heart rate. Each field defaults off, and disabling
  the last reader for a field clears that field from the owner's server
  projection rather than retaining a broader copy.
- Added non-competitive `connected`, `steady_week`, and `steady_month` badges.
  They acknowledge accepted connection or the presence of seven/30 shared
  summary days; they do not rank health values, award streak pressure, or
  affect any metric.
- Added receiver-controlled pokes. Delivery requires global recipient opt-in
  and per-friend permission, remains blocked during recipient quiet hours, and
  enforces block state, a 15-minute pair cooldown, daily sender and recipient
  limits, 24-hour expiry, five-minute claim leases, and idempotent
  acknowledgement.
- Added equivalent Apple and Android managed clients, screens, deep-link
  routing, generic private local notifications, and a best-effort haptic request
  only for a currently connected, bonded, encrypted, worn supported band.
- Added additive PostgreSQL migration `025_managed_social.sql`, API and
  repository methods, account/profile deletion cascades, bounded lifecycle
  cleanup, tenant and consent enforcement, and cross-platform tests.
- Deployed migration `025` and the digest-pinned runtime to IAM-only synthetic
  staging. A two-account smoke proved exact lookup, invitations, mutual
  acceptance, post-acceptance-only feed visibility, all six directional fields,
  badges, poke opt-in/cooldown/claim/acknowledgement, blocks, social deletion,
  and account cleanup.

## Data, privacy, and medical truth

- Schema or migration impact: additive migration `025_managed_social.sql`
  creates managed-only profiles, aliases, invites, requests, friendships,
  directional visibility, blocks, six-field daily summaries, badges, and poke
  delivery state. Existing managed storage and self-hosted Friends schemas are
  unchanged.
- Existing-data retention impact: no biometric history is deleted or rewritten.
  Revoked aliases retain a bounded anti-reuse tombstone, invites/requests/pokes
  expire, managed daily social projections are lifecycle-bounded, and deleting
  the managed Friends profile cascades its social graph without deleting local
  data or the NOOP+ backup account.
- Source/provenance or formula impact: the six values retain their existing
  NOOP-derived units and provenance. Badges are product state derived from
  accepted friendship or non-empty projected days, not physiological metrics.
- Permissions/network disclosure impact: managed Friends requires separate
  explicit enrollment and sharing/poke controls; links expose only a random
  capability or exact-match alias, never credentials or health values.
- Health/medical claim impact and limitations: Friends, badges, and pokes are
  social wellness features and must not diagnose, rank health, or imply safety.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: fixed
  managed-social operation spans, static route groups, status families,
  server-generated request IDs, categorical rejection reasons, aggregate
  counts, and bounded delivery state.
- Why existing evidence is sufficient, or why new evidence is required:
  managed request instrumentation covers every static social route. New
  profile/invite link staging, refresh, summary upload, poke claim, notification,
  haptic-request, and acknowledgement boundaries add the missing fixed
  categories without recording their dynamic values.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  managed request instrumentation, `RequestObservabilityMiddleware`, and
  `emit_operational_event`.
- New bounded events or operation spans: `managed_social.profile_link_staged`,
  `managed_social.invite_link_staged`, social action/refresh operation spans,
  `managed_social.poke_delivery`, and payload-free server poke create/claim/ack
  events.
- Redaction, retention, and high-frequency controls: diagnostics must omit
  aliases, invite capabilities, account/profile/friend IDs, display names,
  notification tokens, health values, user text, URLs, credentials, payloads,
  and arbitrary provider errors. Poke records and links must expire and be
  purged.
- Cross-platform/backend correlation: static route groups and server-generated
  bounded request IDs only.
- Remaining blind spots: OS push delivery, process suspension, Bluetooth
  availability, wrist wear, and physical haptic acceptance require device
  evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source and architecture audit | Passed | Managed Friends is separate from self-hosted Friends and core local NOOP; only the intended six-field projection crosses the boundary | Live abuse rates or user comprehension |
| Real PostgreSQL 14 focused managed-social integration | Passed | Profile/alias rotation, exact lookup, request consent, projection isolation, field clearing, poke controls, blocks, lifecycle, and deletion execute on PostgreSQL | Cloud-scale behavior |
| Complete server suite against fresh PostgreSQL 14 | `269 passed, 1 skipped` | Existing managed/self-hosted/Safety behavior and processor JSONB handling remain compatible; the skip is the explicit real-carrier test | Twilio delivery |
| `swift test --package-path Packages/NoopRemoteSync` | `96 passed` | Swift URL/capability validation, client routes, response bounds, diagnostics, retention, restore, and social models pass | iOS app-target compilation or deep-link launch |
| `swift test --package-path Packages/WhoopStore` | `443 passed` | Managed sync state, retention, storage, and existing store behavior remain green | Physical storage pressure or cloud behavior |
| Android focused managed-social tests and full-debug compile | Passed | Kotlin URL/capability validation, client contract, haptic gate, Compose/service source, and manifest compile | Installed-device notification or haptic behavior |
| Android `testFullDebugUnitTest compileFullDebugKotlin lintFullDebug` checkpoint | Passed | Full Android production-flavor unit, compile, and lint graph remains green before the final invite-link completion | Physical Android behavior |
| `python3 Tools/i18n_audit.py --ci origin/main` | Initially failed on 63 new Apple Friends literals; passed after adding 60 unique catalog keys with complete `de`, `es`, `fr`, and `pt-PT` translations and matching format placeholders | New Friends UI copy is extracted and all maintained focus locales remain complete on Apple and Android | Native-speaker review or every non-focus locale |
| Fresh full iOS Debug simulator graph | Passed, 89 targets | iPhone app, Watch, widgets, Live Activities, and the corrected String Catalog compile from a new DerivedData directory | Signed deep links, push, BLE, or a felt band vibration |
| Private synthetic managed runtime smoke | Passed in 79 seconds | Deployed migration and social authorization, privacy, badges, poke, block, and cleanup paths work end to end | Immediate closed-app push or physical haptics |
| Ruff check and format check | Passed | Python source and tests satisfy repository static policy | Runtime deployment |
| Health-claims, private-data, 213-component legal inventory, refined credential-pattern, OpenTofu format/validate, operations-record, and whitespace gates | Passed | The reviewed publication worktree satisfies the repository release policies and contains no detected tracked runtime credential | Independent legal/security review |
| `git diff --check` | Passed | The current source has no whitespace errors | Functional correctness |

## Physical device and deployment

- Install/update action: not run; no mobile binary was installed.
- Generalized device and OS class: not run.
- Data-preservation result: no physical-device data modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: signed iOS/Android deep-link receipt,
  foreground/background notification routing, connected-band eligibility,
  haptic acceptance, cooldown, and in-place update preservation.

## Git and release state

- Changed paths: managed social migration/models/repository/API/lifecycle,
  NoopRemoteSync models/client/tests, iOS managed service/Friends screen/app
  routing, Android managed service/models/Friends screen/deep-link/notification
  and haptic paths, localized Android strings, diagnostics, and durable
  documentation. Intentional linked observability and staging-retention changes
  remain in the same publication worktree.
- Commits: `4048f013`, `87d6b784`, plus the record commit.
- Branch and remote state: publication to `origin/main` is part of closeout.
- Repository visibility verified: not repeated.
- Version/build impact: no marketing-version or build-number change.
- Release or distribution impact: private synthetic staging only unless every
  recorded public-launch gate later passes.

## Decisions

- Durable decision added or changed: managed Friends uses exact-match
  aliases and revocable invitation capabilities, accepted-only directional
  sharing, non-competitive badges, and receiver-controlled bounded pokes.
- Decision-log entry: `D-040`.

## Open risks and honest limitations

- A stable public alias is personal account metadata and can be shared beyond
  the intended recipient. Exact-match lookup, request acceptance, alias
  rotation, blocking, and rate limits reduce but do not eliminate harassment.
- Remote notification and band haptic behavior cannot be called complete from
  unit tests, simulators, or a private API deployment.
- Shared links currently use the registered `noop://` custom scheme. A
  production HTTPS universal/app-link domain, association files, fallback page,
  and domain-abuse controls remain launch work.
- There is no APNs/FCM provider delivery in this round. A suspended or closed
  client receives a queued poke only during a later foreground/background
  catch-up, after which it requests a generic local notification and eligible
  band haptic. Immediate delivery is not claimed.
- The Twilio credential pasted into conversation history must be revoked and
  replaced before provider testing; it must not enter source, logs, or records.

## Next round

1. Validate profile/invite links, notification authorization/receipt, cooldown,
   quiet hours, foreground/background catch-up, and worn-band haptics on signed
   representative iOS and Android devices.
2. Design the production HTTPS universal/app-link and minimal APNs/FCM wake
   path before public enrollment; do not place profile identity, health values,
   or poke content in push payloads.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
