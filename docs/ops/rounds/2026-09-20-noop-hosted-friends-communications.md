# Round: 2026-09-20 - NOOP-hosted Friends and communications

## Status

- State: `focused implementation and verification complete; branch integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `3edddda180963444b8eb8caa48e5298623cd66f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`; one consolidated push after local
  verification

## Objective

Make Friends one NOOP-hosted account service on iOS, Android, and macOS. Remove
the user-facing provider and self-hosted setup choice, keep every health field
and communication capability off until the user enables it for an accepted
friend, and establish the production-safe foundation for direct messages,
photos, audio calls, and video calls.

## Owner direction

- NOOP operates the Friends service; customers do not configure a local or
  self-hosted server.
- Friends is available to eligible NOOP accounts while product capabilities are
  completed. NOOP versus NOOP+ packaging, payment, trial, and upgrade placement
  remain deferred and must not gate this implementation.
- Acceptance of a friend request does not share health data or enable
  communication by itself.
- Users choose health-summary visibility and message, photo, audio-call, and
  video-call permissions per accepted friend.
- Communication requires mutual eligibility, current friendship, no block, and
  the receiving user's permission.

## Scope

### In scope

- One managed Friends route and account-facing copy on Apple and Android.
- Friends account bootstrap independent of managed health-backup consent.
- Directional communication-permission contracts with false defaults.
- Block, report, revocation, retention, deletion, privacy, and bounded
  observability contracts.
- Server and client foundations that can be verified without real customer
  identities, health data, media, or provider traffic.

### Non-goals

- Choosing paid/free product packaging.
- Enabling public production traffic or using real identities, contacts,
  messages, photos, calls, or health data in tests.
- Claiming production E2EE, media moderation, CallKit/Telecom, TURN, push,
  background delivery, or physical-device behavior before their implementation
  and external gates pass.
- Replacing the phone's local collector or making core health operation depend
  on Friends.

## Starting evidence

- Reproduction or observed symptom: the routed macOS Friends screen still
  exposed the historical customer-operated server flow, while phone Friends
  setup coupled account access to managed health-backup enrollment.
- Relevant source/device/OS/firmware class: iOS and Android account/Friends
  clients, the read-only macOS viewer, shared remote-sync models, FastAPI and
  PostgreSQL managed social/account services, and default-off GCP runtime
  configuration.
- Existing tests, logs, exports, screenshots, or documents: the owner-supplied
  historical macOS capture, managed route/account/scheduler/deletion tests,
  social repository tests, migration manifests, and the September 17-19
  cloud-readiness rounds.
- Unknowns that must remain unknown until measured: signed-device background
  delivery, App Check, provider identity deletion, message/media/call
  transports, moderation, production scale, and physical notification
  behavior.

## Safety, privacy, and abuse boundary

- Every new directional permission defaults to false.
- Block or friendship removal must immediately prevent new sends, downloads,
  signaling, and call setup.
- Push payloads must remain opaque and contain no names, message text, media,
  health values, location, or friend identifiers.
- Photos require encrypted object storage, bounded type and size, metadata
  removal, short-lived capabilities, deletion, and orphan cleanup.
- Calls require authenticated short-lived signaling and relay credentials.
  SDP and ICE data must be ephemeral and must never enter PostgreSQL or logs.
- Reporting needs an explicit user-selected evidence path, a moderation
  lifecycle, and retention policy. Reports must not silently upload unrelated
  conversation history.

## Observability

- Record static operation names, fixed outcomes, status families, duration
  buckets, size buckets, and bounded counts only.
- Never record account/profile/installation/friend identifiers, message or
  media content, ciphertext, capabilities, URLs, SDP, ICE, contact details,
  report evidence, health values, or arbitrary exception text.
- Client reports remain user initiated and redacted. Server correlation uses
  server-generated request IDs without exposing identity.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused macOS route rerun | 5 passed, 0 failed | The Mac route is managed-only, read-only, and non-collecting after the permission-model changes | Live account or network behavior |
| Cross-platform source audit | completed | Remaining NOOP+/self-host copy and backup-enrollment coupling are identified | Corrections compile |
| Managed social backend audit | completed | Existing friendship, privacy, block, lifecycle, and object-store extension points are identified | Messaging, media, or calls exist |
| Consent-free account-enrollment Swift test | 1 passed, 0 failed | The Apple client calls the account endpoint without sending health consent | Live identity-provider or network behavior |
| Consent-free account-enrollment PostgreSQL integration test | 1 passed, 0 failed | Account bootstrap is idempotent, creates no health subscription, consent, or retention rows, and can later upgrade in place after explicit storage consent | Production database, identity-provider, or traffic behavior |
| Account-only Friends erasure PostgreSQL integration test | 1 passed, 0 failed against an isolated local PostgreSQL instance | A Friends-only account with no storage subscription, health consent, or retention snapshot can schedule account erasure, authenticate receipt reads with its installation credential, complete cloud-state and identity deletion, and read the final receipt | Production database, identity-provider deletion, or elapsed cooling-off behavior |
| iOS generic simulator build after account split | succeeded | The account-ready state, managed-only route, permission model, and updated Apple UI compile in the iPhone graph | Physical-device behavior or live service access; warnings observed in this earlier build were corrected and rechecked below |
| Final iOS generic simulator build | succeeded; embedded Watch app and widget extension validation succeeded | The latest account deletion, scheduler, UI, and localization changes compile together across the iPhone, Watch, and widget build graph | Physical-device behavior, signing, store distribution, and live provider access |
| Android full-debug Kotlin compile after account split | succeeded with one worker and 4 GB heap | The account-ready state, managed-only route, false-default permission model, decoder, and Android UI compile | Physical-device behavior or live service access |
| Android account scheduling and localization policy rerun | Gradle build succeeded; focused scheduler and localization tests passed; resource processing succeeded | Account-only Friends work is eligible for background scheduling without enabling health backup, Safety remains storage-gated, all complete locales contain every default resource, and partial locales preserve exact scoped parity | Android OS background-delivery behavior or physical-device push behavior |
| Shared Swift permission tests | 4 passed, 0 failed | Message, photo, audio-call, and video-call permissions default false and patch explicitly | A transport exists |
| Static migration contract | 2 passed, 0 failed | Migration 058 adds non-null false-default communication columns and both manifests include it | PostgreSQL runtime integration |
| Managed Friends PostgreSQL integration suite | 8 passed, 0 failed against an isolated local PostgreSQL instance | Social repository behavior, migration 058 communication-permission defaults, and account-only erasure execute together against the current migration graph | Production database, provider traffic, scale, or soak behavior |
| Apple localization recovery and audit | valid catalog; 0 missing de/es/fr/pt-PT keys | An accidental catalog-seed rewrite was reduced to the intended semantic delta and translated-key coverage remains complete | The audit's 162 broader pre-existing hardcoded Swift literals are resolved |
| Final Friends localization and accessibility wall | Android Full-debug build succeeded; 5/5 localization-policy tests, 3/3 Friends contracts, and 2/2 focused Apple tests passed; 40 Apple keys across 8 locales and 18 Android resource files validated | The managed Friends/account lifecycle copy is complete across supported locales, deletion dates use locale-aware formatting, and Android toggle rows expose one switch semantic node | Physical screen-reader behavior, font-scale layout, or signed-device locale switching |
| Managed-only Friends presentation cleanup | Apple focused graph executed 33 tests with zero failures; Android Full resource processing, Kotlin compilation, localization policy, and Friends localization contracts completed in a 29-task build | iOS and macOS route only to the NOOP-hosted Friends surfaces, the Android legacy self-hosted screen source is absent, and Android Friends resources are restricted to the 12 managed keys still referenced | Live account sign-in, provider delivery, or physical-device presentation |
| Account deletion terminology and localization audit | Apple string catalog is valid with zero de/es/fr/pt-PT translated-key gaps; Android locale resources parse and focused localization contracts pass | Account deletion is plan-neutral and no longer incorrectly describes the deleted identity as a NOOP+ account | Legal approval or live identity-provider deletion |
| Exact-current unsigned Release iOS graph | succeeded with zero compiler errors and zero `ManagedCloudService.swift` warnings; embedded Watch app and widget extension validation succeeded | The final managed Friends localization, date formatting, account lifecycle, Watch, and widget graph compile together after the Swift concurrency correction | Signing, App Store distribution, physical accessibility, background execution, or live managed-service access |
| Exact-current Swift package walls | `NoopRemoteSync` 188 passed; `WhoopStore` 539 passed | Managed account, Friends, Safety, encrypted sync, retention, metric storage, and workout-planning package contracts pass together | App process lifecycle, BLE, provider delivery, or physical-device behavior |
| Final release-control wall | 305 passed plus 44 subtests; final terminology audit reports 17,821 classified occurrences across 1,581 groups and zero forbidden mappings | Required CI, trusted controls, terminology ratchets, and operations-policy checks match the final candidate tree | Hosted exact-SHA checks or protected-branch integration |
| Exact-current complete macOS wall | 2,207 executed, 1 intentional skip, 0 failures | The complete macOS application and contract suite passes with the managed Friends route, lifecycle fencing, localization, shared packages, and current candidate source integrated | Signed distribution, live service access, notification delivery, BLE, or physical-device behavior |
| Exact-current complete Android wall | Full and Demo each executed 4,964 tests with 7 intentional skips and zero failures/errors; 175 compile, lint, APK, unit, and instrumentation-source tasks succeeded | The final managed-only Friends/account route, permissions, scheduler, deletion, localization, and complete Android graph pass together | API 35 runtime behavior, physical push/background delivery, TalkBack, BLE, or live service access |
| Apple account scheduler and deletion tests | 12 passed, 0 failed | Account-only Friends refresh is separate from health-backup and Safety scheduling; account-only deletion, cancellation, receipt authorization, and local-data preservation contracts hold | Live background execution, identity-provider deletion, or physical-device behavior |
| Fresh cross-platform deletion-race review and focused fixes | Apple account operations are canceled and awaited; Android deletion is serialized behind the Friends mutex; Friends enablement survives a canceled cooling-off period | In-flight summary upload and poke acknowledgement cannot continue past a newly scheduled deletion, and cancellation can resume Friends scheduling | Production contention, process death, or elapsed cooling-off behavior |
| Android encrypted outbox reconciliation | Focused Full-debug unit wall succeeded | Superseded outgoing ciphertext is removed only after durable database generations no longer reference it, preventing permanent quota exhaustion without age-evicting unacknowledged data | Low-storage/process-death behavior on a physical device |
| Current macOS routed-source and contract verification | compact `FriendsView` routes macOS directly to `MacManagedFriendsView`; 33 focused Apple tests and the complete 2,207-test macOS wall pass | The current macOS route is managed-only and read-only; the historical self-hosted screenshot is stale and is not accepted as current evidence | Live account sign-in, server access, signed distribution, or physical accessibility |

## Delivered in this slice

- iOS, Android, and macOS route Friends directly to the NOOP-hosted account
  service. The historical Apple and Android self-hosted Friends presentation
  source and Android presentation-only resources have been removed; the
  separate optional sync subsystem remains outside the Friends route.
- Added a consent-free managed account-enrollment endpoint and separate
  account-ready state on iOS and Android. Opening Friends no longer enrolls the
  user in health backup, creates health-data consent, or enables health upload.
  A later explicit storage enrollment upgrades the same account in place.
- Replaced the health-backup enrollment card in Friends with account setup copy
  that states the boundary: account creation enables Friends but does not
  enable health backup or upload.
- Added directional message, photo, audio-call, and video-call permissions to
  Swift, Kotlin, FastAPI, PostgreSQL migration, decoder, and per-friend UI
  contracts. Every permission defaults to false.
- Split background work by authority on Apple and Android. Friends refresh and
  pokes use account readiness, while health backup and Safety remain gated by
  explicit managed-storage enrollment.
- Added account management to the Friends surface on Apple and Android,
  including fresh-auth deletion, cooling-off status, cancellation, receipt
  polling, and explicit local-health-data preservation. The account-only path
  uses the account installation scope and does not require health-backup
  enrollment.
- Quiesced Friends work before account deletion, preserved the Friends-enabled
  preference through cooling-off, refreshed Android Friends when canceled
  deletion restores access, and reconciled Android outgoing encrypted
  documents against durable pending generations.
- Completed Android translations for the account lifecycle and existing
  communication-permission copy, while retaining strict full- and
  feature-scoped locale parity tests.
- Completed the corresponding Apple Friends translations across all eight
  supported non-English locales, localized deletion eligibility timestamps,
  and made Android toggle rows expose a single full-row switch target for
  TalkBack.
- Preserved rolling-service compatibility by decoding absent newly introduced
  message, photo, audio-call, and video-call fields as `false`. Existing health
  visibility fields remain required, so malformed established contracts still
  fail closed.
- Kept communication actions hidden because message, media, report, signaling,
  TURN, CallKit, Telecom, notification, moderation, and key-recovery transports
  do not yet exist.
- Recovered `Localizable.xcstrings` after
  `Tools/seed-string-catalog.py --help` unexpectedly executed the mutating
  script. Recovery retained 25 intentional modified keys and 47 translated new
  keys, removed generated English-only churn, validated JSON, and passed the
  translated-key audit.
- Made account-erasure confirmation, progress, error, cancellation, and
  completion copy plan-neutral on Apple and Android. Storage/backup copy still
  uses NOOP+ where that product boundary is accurate.

## Data, privacy, and medical truth

- Schema or migration impact: migration 058 adds false-default directional
  communication-permission columns; account-only deletion reuses the existing
  managed erasure lifecycle.
- Existing-data retention impact: Friends account deletion enters the existing
  cooling-off lifecycle; local health data remains on the phone and is not
  silently deleted or uploaded.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: account access is separate from
  managed health-backup consent; every health and communication permission is
  explicit and false by default.
- Health/medical claim impact and limitations: none; Friends and Safety remain
  sharing/paging capabilities, not medical diagnosis or emergency dispatch.

## Physical device and deployment

- Install/update action: simulator and local unsigned macOS candidate only; no
  signed install or production deployment.
- Generalized device and OS class: iPhone Simulator build, local macOS app,
  Android JVM/resource build, and isolated PostgreSQL.
- Data-preservation result: synthetic account-only erasure preserved local
  health-data scope while deleting managed account state.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: background refresh, push and poke receipt, notification
  presentation, App Attest/App Check, physical accessibility, and provider
  identity deletion.

## Git and release state

- Changed paths: shared remote-sync models, Apple and Android managed account
  services/UI/tests/localization, macOS managed viewer, server social/account
  models/repository/tests/migrations, GCP configuration, and operations docs.
- Commits: consolidated implementation commit pending.
- Branch and remote state: dirty local
  `codex/ui-cloud-readiness-20260917`; pull request `#16` still points to a
  superseded candidate until the one authorized replacement push.
- Repository visibility verified: not changed.
- Version/build impact: no version or build-number change.
- Release or distribution impact: source foundation only; public traffic,
  communication transports, signing, stores, and production deployment remain
  disabled or external.

## Decisions

- Durable decision added or changed: Friends is a NOOP-hosted account service;
  customers do not select or configure a self-hosted provider. Account access
  does not grant managed health-backup consent.
- Decision-log entry: recorded in `docs/ops/DECISIONS.md`.

## Open risks and honest limitations

- Audited E2EE protocol and multi-device key-recovery design.
- Message, media, report, and legal retention decisions.
- Media safety and unlawful-content handling.
- Realtime signaling, TURN capacity, abuse throttling, and provider operations.
- iOS CallKit/PushKit, Android Telecom, macOS notification behavior, and
  physical-device validation.
- Production managed-service configuration, identity-provider deletion,
  signed builds, deployment, monitoring, and elapsed cooling-off validation.
- Migration and runtime database credentials are now separated in source and
  plan tests. Live Cloud SQL role provisioning, secret rotation, and runtime
  validation remain an external staging gate.

## Next round

1. Add report/block enforcement for every future communication route.
2. Select and review an E2EE multi-device key and recovery protocol before
   implementing messages.
3. Implement private encrypted media storage, metadata stripping, bounded
   capabilities, retention, deletion, and moderation before enabling photos.
4. Implement authenticated ephemeral signaling, TURN, CallKit/Telecom, opaque
   push, and physical-device validation before enabling audio or video calls.
5. Run the branch-wide server and platform regression walls before the
   consolidated commit.
6. Configure only synthetic staging identities and managed-service endpoints,
   then validate signed-device background and push behavior before any public
   traffic.

## Privacy check

- [x] No credentials, customer identifiers, message or media content, health
      values, contact details, signing identities, or absolute personal paths
      are present.

## Cleanup

- Cleanup manifest
  `c302d957bcd169f7244512291cab3cbb9334690ee7d7d0baad5757b937d3ff09`
  covered 23 exact round-owned temporary paths totaling 7.170 GiB.
- The Apple DerivedData, local PostgreSQL clusters, Python test environment,
  bounded logs and statuses, and current-route capture were removed after their
  results were recorded above.
- Post-cleanup verification found every manifest path absent, no test
  PostgreSQL listener, and no candidate app process. Free data-volume space was
  20 GiB and iTerm RSS was approximately 330 MiB.
- Final pause cleanup manifest
  `13f5560c7a39e340cd3c4d842a369fbd3dd979f0c01bec0868d7221d387c271c`
  removed 30 exact round-owned paths, including the disposable Python
  environment, terminology review copies, and completed verification logs.
  Post-cleanup verification found all 30 paths absent, no active build or test
  process, and 21 GiB free. The pre-existing Homebrew PostgreSQL service was
  not round-owned and was left unchanged.
