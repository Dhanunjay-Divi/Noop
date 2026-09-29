# Round: 2026-09-26 - September 17 readiness completion

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/sept17-readiness-closeout-20260926`
- Start commit:
  `169230a9ae38ac8b4ca4b690489cd29f5af47ee4`
- End implementation commit: pending
- Record checkpoint:
  `db07e2c68afd55709d81241b580258938328947e`; final closeout commit pending

## Objective

Complete the supplier-independent September 17 UI and cloud-readiness audit
without enabling an abrupt cloud-authority migration. Close verified Apple,
Android, account, accessibility, localization, privacy, observability, and
release-control gaps; preserve the green PR 17 checkpoint; and leave only
physical-device, signing, legal, carrier, credential, production-service, or
explicitly gated migration work open.

## Scope

### In scope

- Remove the fresh-install macOS viewer onboarding dead end.
- Give Watch heart-rate presentation an exact observation timestamp and bounded
  freshness contract equivalent in meaning to the phone/widget surface.
- Improve Apple and Android ownership-account recovery with bounded resend
  cooldowns and specific offline, expired-code, and invalid-code states.
- Reconcile the September 17 Claude review against current source and record
  implemented, rejected, gated, and external-only findings.
- Correct stale operations and test-build records.
- Run focused verification first, then the applicable repository controls and
  hosted checks for the final integration candidate.

### Non-goals

- Enabling the D-059 cloud-authority flip, silently enrolling existing users,
  or pruning local history.
- Adding SQLCipher without an approved key recovery, migration, backup,
  performance, and rollback design. Current Apple file protection and Android
  device encryption remain the documented edge-at-rest boundary.
- Claiming physical BLE, WatchConnectivity, notification delivery, background
  relaunch, battery, haptics, signing, physiological accuracy, or supplier
  behavior from simulator or source evidence.
- Machine-translating health copy without review.

## Starting evidence

- Exact PR 17 head
  `169230a9ae38ac8b4ca4b690489cd29f5af47ee4` passes all ten required hosted
  contexts. Apple run `36266411704` completed successfully, including the iOS
  production shell.
- macOS is a viewer runtime, but a fresh install enters the shared onboarding
  wizard whose completion requires a durable paired-band record. macOS rejects
  scan/connect operations, so the path can dead-end.
- Watch score snapshots carry a heart-rate value without a heart-rate
  observation timestamp. Complications may display it until the whole snapshot
  reaches its much longer stale limit.
- Apple and Android ownership flows expose resend actions without a local
  cooldown and collapse some expired, invalid, and offline failures into generic
  copy.
- D-059 approves a staged cloud-authoritative target only after per-data-class
  consent, migration, parity, restore/deletion, performance, rollback,
  security, and physical-device gates. It does not authorize the authority flip
  in this round.
- The Apple localization audit is regression-gated and still reports a tracked
  hardcoded-literal backlog. Catalog coverage exists for the current Watch,
  widget, complication, and app keys; native-speaker and visual-fit evidence
  remains external.

## Delivered

- macOS fresh installs no longer enter collector/BLE onboarding. The viewer
  runtime proceeds from Terms into the account/application shell, while iPhone
  collector onboarding remains unchanged.
- Watch score snapshots now carry an optional heart-rate observation timestamp.
  Live Watch/complication HR uses a two-minute freshness window, legacy
  snapshots remain decodable without inventing freshness, and locked snapshots
  scrub both the value and timestamp.
- The Watch headline-change policy is transport-independent, so macOS tests and
  the iPhone `WatchSessionBridge` execute the same freshness/deduplication rule.
- Apple and Android ownership flows now apply a 60-second monotonic resend
  cooldown to email and phone verification. Sign-out/reset clears local
  user-specific timers, successful verification refreshes countdown state, and
  provider throttling remains authoritative after process restart.
- Both mobile clients distinguish offline, invalid-code, expired-session,
  provider-rate-limit, and active-local-cooldown states with fixed
  payload-free diagnostic categories.
- Recovery/countdown UI is localized across the supported Android resource
  sets and the eight Apple application locales.
- Fresh-install Review Sample entry now makes real account/band setup the
  primary action on iPhone and Android. The fictional sample remains available
  as a clearly secondary, non-operational path.
- Apple and Android onboarding progress now names the current step as well as
  showing its numeric position, with combined screen-reader semantics.
- Apple and Android Daily Signal empty rationale now explains that current
  baseline-relative signals are insufficient instead of claiming that no
  recovery signal has enough history when a Recovery score is already visible.
- Managed-document restore conflicts now preserve the affected document kind
  and remote revision in typed local error context on Apple and Android while
  retaining the newer local generation. The cloud document is not applied,
  generic server conflicts remain distinct, and the user sees that current
  data was kept with an explicit `Sync now` retry path.
- Conflict diagnostics remain bounded to the fixed `document_conflict`
  category. Document ids, local keys, account scopes, payloads, health values,
  and exact revisions do not enter app reports.
- Managed sync now exposes a strict history-only restore mode for signed-in
  viewers. It downloads retained metric chunks without source registration,
  health or document upload, local pruning, or document download/application;
  the existing phone sync path retains full document behavior.
- An enrolled macOS viewer now restores retained account history during app
  startup, refreshes the local metric repository only after applied changes,
  displays a read-only Account history status with manual retry, and continues
  to expose no BLE, source-registration, Friends mutation, sharing change,
  paging, Safety mutation, or cloud-upload path.
- The macOS restore boundary is account-fenced before, during, and after the
  operation. Its diagnostics contain only fixed outcomes, a bounded applied
  count, continuation state, and a categorical failure kind.
- Mac account-history and enrollment copy is translated across every supported
  Apple application locale. The complete unsigned iPhone graph remains
  compatible and embeds Watch, complications, and widgets.
- iPhone and Android More now place Band Account and Data & Sync first as
  ordinary setup rows, before everyday shortcuts and the collapsible
  catalogue. Their duplicate Body/Data rows were removed, the oversized NOOP+
  hero was removed, and NOOP+ remains reachable as one conventional Data row.
- Profile remains once in the complete Body index. Its duplicate quick-access
  tile was replaced by Journal & Insights while Safety, Devices, and Friends
  remain one tap away on both mobile platforms.
- The real iPhone production shell was installed and launched headlessly on an
  iPhone 17 Pro simulator with seeded fictional data. The 1206 x 2622 capture
  showed the revised hierarchy without clipping, overlap, or hidden setup
  actions at the tested text size and appearance.
- Apple and Android now present the destination as Data & Sync with localized
  title and purpose copy. Local folder backup, automatic snapshots, and restore
  remain primary. D-036 self-hosted sync remains available and behaviorally
  unchanged behind one default-collapsed Advanced control at the end of the
  screen; no authority, consent, upload, credential, retention, or formula
  contract changed.
- macOS uses the same Data & Sync display label while preserving the legacy
  `Backup & Sync` raw navigation identifier so existing persisted navigation
  state remains compatible.
- The two formula-review findings were reconciled against current source:
  Recovery education already names only the five production inputs and rejects
  recent-load wording in tests; Rest already publishes as `noop-rest-v2` with
  full-history rescore gates. No formula change was justified in this round.
- The September 17 account/cloud and UI findings were re-audited against the
  current branch rather than accepted as current defects. The disposition
  matrix below is authoritative for this round.
- Managed pruning now clamps an explicit prune timestamp to the sync run's own
  wall-clock boundary on Apple and Android. A caller-side future timestamp can
  no longer advance local deletion beyond the run that is uploading and
  settling those windows. This is mismatch hardening only; it does not invent a
  server-trusted clock, enable automatic pruning, or change the opt-in.
- Apple and Android history backfill now classify decoded-row, raw-row, and
  cursor persistence failures with fixed categories. A failed store write or
  cursor commit cannot advance the durable cursor or acknowledge the band.
  Android's preferences cursor uses synchronous `commit()` and fails closed
  when persistence is rejected; injected storage-full/private-message tests
  prove the diagnostic path remains payload-free.
- Managed upload batching now reads one bounded lookahead item beyond the
  100-item transfer cap, reports whether backlog remains, rejects an oversized
  adapter response, and coalesces repeated offline edits by profile, table, and
  local key while incrementing the generation. The implementation does not
  introduce a destructive count cap that could discard the latest unacknowledged
  user state.
- PostgreSQL chunk reservation, grant lookup, and completion now take a shared
  lock on the active installation before mutating or accepting completion.
  Revocation therefore cannot race a transfer into committing an acknowledgement
  or advancing a client checkpoint after the installation becomes inactive.
- The macOS sidebar footer now reflects the actual managed-viewer state:
  unconfigured, signed out, verification required, enrollment required,
  syncing, current, stale/pending, or a fixed safe failure. It exposes an
  accessibility label/value and never presents arbitrary backend errors.
- Ownership/account setup on Apple and Android now exposes named progress,
  distinct verification phases, screen-reader grouping, supporting/error text,
  and live status announcements. The added strings are complete across the
  supported application locales.
- Recovery, Rest, Sleep, and Fitness Age scoring guides now show the production
  algorithm revision, on-device provenance, implemented inputs, baseline or
  lookback window, and exclusions. Mirrored tests prove that Recovery does not
  silently use the optional Recovery Index or prior-day activity-balance terms.
  No score formula changed.
- Repeated Journal attribution explanation moved behind an information
  affordance on Apple and Android while the actionable editing and
  tomorrow-attribution guidance remains visible.
- iPhone Quick Access becomes a one-column list at accessibility text sizes,
  retains two-line labels, and preserves stable tab-bar dimensions. Fresh
  iPhone 17e captures of More and Daily Plan were inspected without clipping or
  incoherent overlap in the tested accessibility state.
- The legacy terminology inventory was regenerated only after reviewing the
  current delta: no forbidden mapping or new customer-facing occurrence was
  admitted. The final source-control digest is repinned by the required-CI
  gate.
- The release-blocker handoff now reflects protected `main` after PR `#16`,
  exact hosted-green PR `#17`, its outstanding non-author review, and this
  follow-on branch without confusing an intermittent checkpoint with protected
  integration.

## September 17 review reconciliation

The supplied review was produced against an older source snapshot. Its
recommendations remain useful, but an old finding is not completion evidence
and must not override D-059 or current source.

| Review finding | Current disposition | Current evidence or remaining gate |
|---|---|---|
| Account/cloud P0-1: cloud authority contradicts the then-current local-first contract | Superseded only by the staged D-059 target; no authority flip in this round | Cloud remains an optional replica until consent, migration, restore/deletion, performance, rollback, security, and physical gates pass |
| P0-2: add SQLCipher immediately | Not approved for implementation in this round | Apple file protection and Android device encryption remain the recorded edge boundary; an application-level encryption change still needs key recovery, migration, backup, performance, and rollback design |
| P0-3: migrate existing local-only history | Gated, not silently implemented | Existing users are not enrolled or pruned; resumable consented backfill remains a separate migration round |
| P0-4: cloud is not yet authoritative-operable | Still open externally | Production ingress, App Check, identity recovery, restore drills, load, legal, monitoring, and operator evidence remain launch gates |
| P1-1: automatic 7/30-day pruning and phone-storage disclosure | Partially implemented and intentionally opt-in | Processor-validated ack-before-prune remains available only through the explicit optimize-storage setting; no default prune or authority change was introduced |
| P1-2: cross-device document conflicts need resolution | Bounded recovery implemented; automatic merge remains gated | Apple and Android preserve the newer local generation, retain typed document context, show that current data was kept, and expose `Sync now`; no unsafe field merge is claimed |
| P1-3: scalable restore chooser and large-account proof | History-only viewer restore implemented; scale proof remains open | macOS can restore retained metric chunks without upload, source registration, document application, or pruning; staging and physical large-account continuation remain required |
| P1-4 and UI P1-4: growth, lag, and blank Trends | Loading-state defect fixed; physical performance remains open | Apple and Android Trends expose loading, timeout/failure, retry, and cached-content states; device startup, scroll, thermal, low-storage, and large-account budgets still require physical evidence |
| P1-5: force account creation into every fresh install | Rejected as an unconditional change | Real setup is now the primary Review Sample action and configured ownership remains in onboarding; dormant/unconfigured ownership stays fail-closed instead of pretending account services are live |
| P2-1: no account-deletion surface | Implemented | Apple and Android expose request, cooling-off status, cancellation, acknowledgements, and local-data boundaries; server lifecycle and erasure tests cover the control plane |
| P2-2: generic offline, resend, and expired-code states | Implemented | Both clients use a 60-second monotonic cooldown and distinct offline, invalid-code, expired-session, provider-rate-limit, and local-cooldown states with payload-free diagnostics |
| P2-3: ownership client/service and wire-contract coverage | Substantially implemented; physical UI remains open | Apple and Android parser, route, secure-store, deletion, recovery, and source-contract suites now exercise the live client boundaries; signed-device account UI and production Firebase delivery remain external |
| P2-4: five managed-sync fault cases | Supplier-independent deterministic cases closed; trusted time remains gated | Bounded 100-item upload with one-item lookahead/backlog reporting, oversized-response rejection, repeated-edit coalescing, revoked-installation transfer serialization, storage-full cursor/ack stalling, completion retry, cancellation-before-prune, account fencing, cursor expiry, conflict retention, dirty-pruned hydration, and caller-clock clamping are covered. An independent trusted-time anchor still requires server authority and a D-059 migration gate |
| P2-5: no sync/provenance UI | Implemented | Today and Health expose sync status; metric and sleep surfaces retain source provenance on both mobile platforms; Data & Sync explains the local/cloud boundary |
| UI P1-1: Recovery vocabulary and color disagree | Implemented | Shared `RecoveryBandPresentation` drives Today, Calendar, digest, and liquid surfaces on Apple and Android with focused parity tests |
| UI P1-2: Daily Signal says `RECHECK` while rationale says within range | Implemented | The empty rationale now describes insufficient baseline-relative signals without contradicting a visible Recovery score |
| UI P1-3: tab bars fail Dynamic Type | Implemented in source and contract tests | Apple uses scaled measurements and Large Content Viewer; Android computes bounded label fit, ellipsizes, and exposes tab semantics. Physical VoiceOver/TalkBack traversal remains open |
| Formula F1/F2 | Rejected as stale findings | Recovery copy matches the five production inputs; Rest is already revisioned as `noop-rest-v2` with rescore gates |
| Coach evidence chips and Automations last-fired state | Gated rather than fabricated | The current models do not retain one truthful cross-platform evidence/automation execution ledger. UI was not added until a bounded data contract exists |
| Conflict UI should offer `keep other` | Gated by authority and payload design | The current retry path preserves the newer local generation; the remote conflicting payload is not retained locally, so offering `keep other` would be misleading without an approved API and authority contract |
| Restore chooser with exact dataset sizes | History-only restore retained; chooser gated | The service does not yet expose a trustworthy restore manifest with estimated sizes, and large-account continuation lacks staging/physical proof |

This table does not convert source or simulator evidence into production,
physiological, BLE, notification-delivery, or physical accessibility proof.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: no score output or provenance owner
  changed. Scoring guides now disclose the current production revision and
  actual wired inputs, and tests ratchet those explanations to the formula.
- Permissions/network disclosure impact: none. Existing Firebase identity
  requests are unchanged; this slice only bounds retries and maps failures.
- Health/medical claim impact and limitations: no formula or medical claim
  change. Heart-rate freshness presentation will become more conservative.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  ownership operation spans now emit fixed `network`,
  `verification_code_invalid`, `verification_expired`, `rate_limit`, and
  `resend_cooldown` categories. Backfill emits only fixed
  `decoded_store_write`, `raw_store_write`, or `cursor_store_write` failure
  kinds and cannot acknowledge unpersisted progress. Managed sync exposes
  bounded item counts, continuation/backlog state, and fixed conflict/failure
  kinds. UI-only macOS, account accessibility, scoring-guide, Journal, and
  Watch changes use deterministic state tests rather than high-frequency logs.
- Why existing evidence is sufficient, or why new evidence is required:
  ownership resend/cooldown behavior changes a failure-prone network boundary,
  so tests must prove accepted, rejected, offline, expired, and cooldown states
  without recording addresses, codes, or provider payloads.
- Existing evidence reused: `AppDiagnosticsRecorder` ownership operation spans,
  authorized Watch snapshot tests, onboarding step-selection tests, managed
  sync operation spans, the fixed-enum `ui.more_visible` destination event, and
  hosted exact-SHA checks.
- New bounded events or operation spans:
  `managed_macos.history_restore` records only outcome, a capped applied-change
  count, continuation state, and fixed failure kind. Existing managed-sync
  spans distinguish the fixed `document_conflict` category from generic
  `conflict`; the typed error retains only an allowlisted document kind and
  numeric remote revision for local recovery logic. No new event was needed for
  the PostgreSQL installation lock because the API operation already has
  request correlation and fixed outcomes; direct database race tests provide
  the missing correctness evidence.
- Redaction, retention, and high-frequency controls: no email, phone, OTP,
  account, device, health value, provider message, or URL may enter diagnostics.
- Cross-platform/backend correlation: Apple and Android user-visible account
  states must agree; provider error mapping remains local and payload-free.
- Remaining blind spots: real provider throttling, mail delivery,
  WatchConnectivity, physical complications, production identity services,
  independent trusted time, a restore-size manifest, a shared automation
  execution ledger, VoiceOver/TalkBack traversal, and physical-device visual
  fit.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `gh pr checks 17 --required` on exact head `169230a9a` | 10/10 pass | Existing PR checkpoint is hosted green | New changes or physical behavior |
| Apple hosted run `36266411704` | Pass | macOS build/tests and iOS production shell pass at the starting SHA | Physical devices, signing, or the pending fixes |
| `xcodebuild ... -only-testing:StrandTests/OwnershipVerificationRecoveryContractTests -only-testing:StrandTests/WatchScoreSnapshotTests test` through the bounded runner | 12/12 pass | Monotonic cooldown/source contracts, stable failure categories, payload-free diagnostics, eight-locale Apple coverage, Watch wire compatibility, HR freshness, locked scrub, and transport-independent publication policy | Live Firebase delivery or WatchConnectivity |
| Apple Review Sample contract suite | 5/5 pass | Real setup precedes the fictional sample and the sample remains isolated from operational dependencies | Physical-device visual fit or VoiceOver navigation |
| Android Full/Demo compilation plus `OwnershipVerificationRecoveryTest` through the bounded runner | 7/7 pass | Both Android flavors compile; monotonic countdowns, provider mapping, UI disable/countdown state, nine resource sets, and payload-free diagnostics agree | Real provider throttling, OTP delivery, or physical UI |
| Android Full/Demo compilation plus `ReviewSampleModeContractTest` | Pass | Both Android source graphs compile with the new progress semantics and real setup remains the primary entry action | Physical TalkBack behavior or OEM rendering |
| Apple `DailyActionTodayContractTests` plus Android Full/Demo compilation and focused `DailyActionTodayContractTest` | Apple 5/5 pass; Android pass | A visible Recovery score can coexist with a Building Daily Signal without contradictory empty-state copy on either mobile implementation | Physical visual fit, real physiological inputs, or recommendation accuracy |
| `swift test --package-path Packages/NoopRemoteSync --filter WhoopManagedSyncAdapterTests` through the bounded runner | 13/13 pass | A newer local managed-document generation remains intact and maps to typed document kind/revision context | Production service concurrency or physical-device network transitions |
| Apple `ManagedCloudDocumentAdapterTests` and `ManagedCloudRetryContractTests` through the bounded runner | 16/16 pass; final contract recheck 14/14 pass | Local preferences are not replaced, export recovery recognizes the typed conflict, diagnostics stay categorical, and both mobile surfaces retain a visible manual retry | Production cloud races or physical UI interaction |
| Android Full/Demo Kotlin compilation, focused `ManagedDocumentConflictContractTest`, and Full instrumentation-source compilation through the bounded runner | Pass | Both flavors carry only bounded conflict context, retain generic conflict compatibility, compile the Room conflict assertions, and expose the localized retry path | On-device Room execution or production service races |
| `swift test --package-path Packages/NoopRemoteSync` through the bounded runner | 193/193 pass | History-only restore excludes documents and preserves all existing full-sync/document behavior | Production service availability, large-account latency, or signed clients |
| Swift `ManagedSyncCoordinatorTests` plus Android `ManagedSyncCoordinatorTest` through parallel bounded runners | Swift 22/22 pass; Android focused task passes | A future explicit prune timestamp is clamped to the sync run's time on both clients, while retention, cancellation, retry, restore, and dirty-pruned hydration contracts remain green | A server-trusted clock, device wall-clock correctness, disk-full collection, revoked-installation transfer, or automatic pruning |
| macOS `MacViewerRuntimeContractTests` through the bounded runner | 9/9 pass | Startup account-history restore is wired, localized, account-fenced, read-only, and remains outside BLE/mutation entitlements | Signed physical Mac behavior, live Firebase/App Check, or real account data |
| `xcodebuild -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` through the bounded runner | Pass | iOS-only ownership code type-checks and the app embeds/validates Watch, Watch complications, and widgets | Signing, physical devices, WatchConnectivity, BLE, background execution, or delivery |
| Apple `MoreListParityTests` and `MoreSectionPrefsTests` through the bounded runner | 24/24 pass | Account/data rows lead More, NOOP+ has one normal catalogue row, quick access is bounded, and every typed destination remains reachable | VoiceOver traversal or physical-device rendering |
| Android `PrimaryNavigationContractTest` plus Full/Demo Kotlin compilation through the bounded runner | 6/6 pass; both variants compile | Android mirrors the same Account/Data/NOOP+ order and retains its routes without duplicate grouped rows | TalkBack traversal, OEM rendering, or physical navigation |
| Headless iPhone 17 Pro simulator install, seeded More launch, and 1206 x 2622 screenshot inspection | Pass | The exact built app renders the revised hierarchy without clipping or overlap in the inspected state | Other devices, Dynamic Type sizes, light mode, or physical behavior |
| Apple `MoreListParityTests` through the bounded runner at `cf7e28e4b` | 17/17 pass | Data & Sync is the visible Apple label, local backup/restore precede Advanced, and the legacy self-hosted card remains reachable only after expansion | Physical VoiceOver traversal or live sync behavior |
| Android `PrimaryNavigationContractTest` plus Full/Demo Kotlin compilation through the bounded runner at `cf7e28e4b` | Pass | Android localizes the new title/purpose across nine resource sets, keeps self-hosting default-collapsed after restore, and preserves both build variants | Physical TalkBack traversal, OEM rendering, or live sync behavior |
| Exact unsigned `NOOPiOS` generic Simulator build through the bounded runner at `cf7e28e4b` | Pass | The complete iPhone graph compiles and validates embedded Watch, complications, and widgets | Signing, physical devices, BLE, background execution, or delivery |
| Headless iPhone 17 Pro simulator install, direct `backup_sync` route, and 1206 x 2622 screenshot inspection at `cf7e28e4b` | Pass | The Data & Sync title, subtitle, local controls, persistent bottom navigation, and tested dark appearance render without clipping or overlap | Advanced expanded state, other sizes, Dynamic Type, light mode, or physical behavior |
| `python3 Tools/i18n_audit.py --platform all --full` | Pass; tracked Apple baseline remains 129 | No localization regression; all existing focus-locale catalog keys and Android locale resources are complete | Native-speaker review or visual fit |
| Private-data guard, 1,312-file health-claims scan, nine source release controls, operations validation, JSON/XML parsing, and diff hygiene | Pass | The change adds no tracked private filename, unsafe health claim, release-control regression, malformed catalog/resource, or operations-record error | External credentials, legal approval, hosted production state, or physical behavior |
| Live `gh pr view 16`, `gh pr view 17`, and remote-ref queries | PR 16 merged at `9c5141754`; PR 17 exact head `169230a9a` is open, mergeable, and 10/10 required contexts pass | The release-blocker handoff is refreshed from current protected repository state | Approval, integration of this follow-on branch, or physical behavior |
| Complete `Packages/NoopRemoteSync` wall through the bounded runner | 197/197 pass | Upload lookahead/backlog bounds, oversized-response rejection, repeated-edit coalescing, conflict behavior, history-only restore, retention, and cancellation contracts remain green | Production latency, trusted server time, or physical network transitions |
| Complete `Packages/StrandAnalytics` wall through the bounded runner | 1,514 executed, 7 intentional skips, 0 failures | Production analytics remain green and Recovery wiring excludes optional Recovery Index and prior-day activity-balance terms | Physiological accuracy or a formula-authority migration |
| Apple focused closeout suite through the bounded runner | 75/75 pass | Backfill persistence/ack stalling, macOS sync footer states, ownership accessibility, tab accessibility, scoring copy, and Journal information hierarchy are covered | Physical VoiceOver, BLE, notification delivery, or device rendering |
| Complete unsigned macOS wall through the bounded runner | 2,377 executed, 1 intentional Xiaomi fixture skip, 0 failures | The complete shared/macOS source graph and all app tests remain green with the new viewer state machine | Signed macOS operation, live account service, or physical-band behavior |
| Exact current `NOOPiOS` generic Simulator build | Pass | The complete iPhone graph compiles and embeds Watch, Watch complications, and widgets | Signing, physical WatchConnectivity, BLE, background execution, or notification delivery |
| Exact iOS production-shell suite on the current candidate | 39 executed, 1 intentional private-pilot skip, 0 failures | First-run, navigation, loading/retry, accessibility-size, and current production-shell regressions remain green in Simulator | Physical accessibility, battery, thermal, background, or band behavior |
| Complete Android Full and Demo app wall through the bounded runner | Full 5,232/7 skipped; Demo 5,225/7 skipped; 0 failures; both compile, lint, assemble, and Full instrumentation source compile pass | Both shipped source graphs, localization, account accessibility, sync/backfill, analytics, and UI contracts remain green | OEM behavior, physical TalkBack, BLE, battery, or background execution |
| Android API 35 production-shell and Review Sample suites | Production shell 123 executed/2 skipped/0 failures; Review Sample 1/1 pass | Current first-run and production-shell paths execute on an emulator at API 35 | Physical-device rendering, permissions, BLE, provider delivery, or OEM background rules |
| Complete server suite against isolated PostgreSQL plus focused revocation race | Pass | Active-installation locking prevents reserve/grant/completion from crossing a concurrent revocation and the complete backend regression wall remains green | Production IAM, live traffic, load, backup/restore operations, or elapsed monitoring |
| Complete current repository tool walls | 372 tests with 1 intentional skip plus 50 root tests, 0 failures | Operations validation, bounded runner, release policy, localization tooling, and source-control tests remain green | Hosted exact-SHA execution |
| Direct release/policy controls on the final pre-documentation source | Pass: 9 release checks, 10 required contexts, trusted protected-main self-check, 12-metric calibration parity, terminology, legal/distribution, private-data, 1,312-file claims, full localization, exact 10-file SDK artifact | The source candidate preserves the project release-control contracts and supplier artifacts remain absent | Hosted review, signed distribution, supplier rights, firmware, or physical-device behavior |
| Fresh iPhone 17e accessibility captures for More and Daily Plan | Inspected; no clipping or incoherent overlap in the tested states | The revised one-column Quick Access and stable tab shell render coherently at the tested accessibility size | Other devices, physical VoiceOver order, every locale, or every appearance |

## Physical device and deployment

- Install/update action: exact unsigned builds installed to a headless iPhone
  17 Pro simulator for More and Data & Sync inspection; no physical install.
- Generalized device and OS class: hosted macOS/iOS simulator, local iOS 26.5
  simulator, and source evidence only.
- Data-preservation result: no data mutation at round start.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical Apple/Android/Watch and band scenarios.
- Final closeout cleanup stopped the isolated PostgreSQL 14 cluster on loopback
  port 55432, then exact-deleted
  `/private/tmp/noop-sept17-final-20260928`, `android/app/build`, and
  `android/build`. This reclaimed about 14 GiB. The paths are absent; no
  PostgreSQL, Gradle, Xcode, simulator, or emulator process from the round
  survives; and Data-volume free space increased from about 57 GiB to 70 GiB.
  Shared caches, source, simulators, sessions, private inputs, credentials, and
  user data were not removed.
- Round-owned resource cleanup: exact-deleted
  `/tmp/noop-mac-history-derived` and
  `/tmp/noop-mac-history-ios-derived` after their bounded build processes
  terminated, reclaiming about 8.7 GiB. No shared DerivedData, simulator,
  source, session, user data, or unrelated temporary path was removed; both
  paths were verified absent and system free space was about 23 GiB afterward.
- The mobile hierarchy slice also exact-deleted its 7.0 GiB isolated
  `/tmp/noop-account-data-apple-derived` tree, bounded logs/status files,
  screenshot, and headless simulator runtime after recording the evidence.
- The Data & Sync slice exact-deleted its 7.0 GiB isolated
  `/private/tmp/noop-data-sync-apple-derived` tree, all
  `/private/tmp/noop-data-sync-*` bounded logs/status files, and its inspected
  screenshot after evidence was durable. The reused iPhone 17 Pro simulator
  was shut down, every exact path was verified absent, and Data-volume free
  space was about 24 GiB afterward.

## Git and release state

- Changed paths: macOS runtime entry, Watch snapshot/publication/complication
  behavior, Apple and Android ownership recovery/accessibility UI,
  backfill/sync durability, scoring and Journal presentation, server
  installation locking, localization/tests, terminology controls, and
  operations records.
- Commits: macOS/Watch checkpoint `50d41e5c8` and `6b36f035e`;
  account-recovery and Watch-policy correction checkpoint `7b3250b9e`;
  first-run hierarchy and named-progress checkpoint `c71dde298`; Daily Signal
  baseline-state copy checkpoint `cf967394c`; authority-guidance checkpoint
  `f3c98eaa1`; managed-document conflict recovery checkpoint `8e3947854`.
  History-only managed restore checkpoint `415bf5909`; macOS account-history
  viewer checkpoint `9d57b6b35`; evidence/cleanup checkpoint `8ba797109`;
  mobile hierarchy checkpoint `c8a986a61`; Data & Sync presentation checkpoint
  `cf7e28e4b`.
- Branch and remote state:
  `codex/sept17-readiness-closeout-20260926` tracks its public remote.
  Remote checkpoint `db07e2c68` is unchanged while the final locally green
  closeout remains dirty. The branch has no pull request; the older hosted-green
  PR `#17` targets a different branch and exact head. One consolidated push and
  a new protected pull request remain pending.
- Repository visibility verified: public.
- Version/build impact: none planned.
- Release or distribution impact: no deployment or signed artifact.

## Decisions

- Durable decision added or changed: none. The implementation follows D-059's
  staged authority contract and the current documented platform-encryption
  boundary.
- Decision-log entry: none planned unless implementation changes a durable
  contract.

## Open risks and honest limitations

- The current follow-on branch has not yet been pushed at its final SHA or
  exercised by hosted checks. PR `#17` is an older branch and is not evidence
  for this dirty candidate.
- The localization baseline is not zero; native-speaker and visual-fit review
  remain unproved.
- Managed-document conflict resolution deliberately keeps the newer local
  generation and requires a later explicit retry; no automatic field merge is
  claimed.
- Managed upload lookahead, oversized responses, repeated offline edits,
  installation revocation during transfer, and storage-full cursor/ack
  stalling are now deterministic regressions. A unique-key capacity policy and
  independent trusted-time anchor remain authority/design gates; dropping
  unacknowledged user state merely to cap a row count is not approved.
- The Mac viewer restore is source/simulator verified but not exercised against
  a signed production account. Large-history catch-up latency and continuation
  require staging and physical validation.
- Data & Sync now matches the useful information-architecture finding without
  removing D-036 compatibility or changing data authority. Native-speaker
  review, physical accessibility traversal, other device sizes, and the
  expanded Advanced state remain outside this simulator/source evidence.
- App-level database encryption and existing-user authority migration require
  separate approved designs and evidence before activation.
- Coach evidence chips, Automations last-fired state, remote-wins conflict
  replacement, and a sized selective-restore chooser remain gated on truthful
  shared data contracts rather than placeholder UI.

## Next round

1. Regenerate the terminology ratchet after final operations-record edits,
   repin its source digest, and rerun operations, tooling, localization,
   claims, privacy, legal, calibration, required-CI, trusted-release, SDK, and
   diff gates.
2. Commit once, push once, open a new pull request for this branch, require all
   ten exact-head protected contexts, and merge normally only while they remain
   green.
3. Verify protected `main`, then hand the signed physical iPhone/Android round
   to the device-connected agent using the existing physical-validation
   handoff.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
- [x] Round-owned isolated DerivedData, Android generated output, synthetic
      PostgreSQL data/socket state, bounded logs, status files, and captures
      were removed after their outcomes were recorded.
