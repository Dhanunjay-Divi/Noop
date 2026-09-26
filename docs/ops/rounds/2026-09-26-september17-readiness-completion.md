# Round: 2026-09-26 - September 17 readiness completion

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/sept17-readiness-closeout-20260926`
- Start commit:
  `169230a9ae38ac8b4ca4b690489cd29f5af47ee4`
- End implementation commit: pending
- Record checkpoint:
  `9d57b6b354fa1e1c843a9e9ee0f5e8c2e3020b2b`

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
- The two formula-review findings were reconciled against current source:
  Recovery education already names only the five production inputs and rejects
  recent-load wording in tests; Rest already publishes as `noop-rest-v2` with
  full-history rescore gates. No formula change was justified in this round.
- The release-blocker handoff now reflects protected `main` after PR `#16`,
  exact hosted-green PR `#17`, its outstanding non-author review, and this
  follow-on branch without confusing an intermittent checkpoint with protected
  integration.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none. Existing Firebase identity
  requests are unchanged; this slice only bounds retries and maps failures.
- Health/medical claim impact and limitations: no formula or medical claim
  change. Heart-rate freshness presentation will become more conservative.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  ownership operation spans now emit fixed `network`,
  `verification_code_invalid`, `verification_expired`, `rate_limit`, and
  `resend_cooldown` categories. UI-only macOS and Watch changes use
  deterministic state tests rather than new logs.
- Why existing evidence is sufficient, or why new evidence is required:
  ownership resend/cooldown behavior changes a failure-prone network boundary,
  so tests must prove accepted, rejected, offline, expired, and cooldown states
  without recording addresses, codes, or provider payloads.
- Existing evidence reused: `AppDiagnosticsRecorder` ownership operation spans,
  authorized Watch snapshot tests, onboarding step-selection tests, managed
  sync operation spans, and hosted exact-SHA checks.
- New bounded events or operation spans:
  `managed_macos.history_restore` records only outcome, a capped applied-change
  count, continuation state, and fixed failure kind. Existing managed-sync
  spans distinguish the fixed `document_conflict` category from generic
  `conflict`; the typed error retains only an allowlisted document kind and
  numeric remote revision for local recovery logic.
- Redaction, retention, and high-frequency controls: no email, phone, OTP,
  account, device, health value, provider message, or URL may enter diagnostics.
- Cross-platform/backend correlation: Apple and Android user-visible account
  states must agree; provider error mapping remains local and payload-free.
- Remaining blind spots: real provider throttling, mail delivery,
  WatchConnectivity, physical complications, and production identity services.

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
| macOS `MacViewerRuntimeContractTests` through the bounded runner | 9/9 pass | Startup account-history restore is wired, localized, account-fenced, read-only, and remains outside BLE/mutation entitlements | Signed physical Mac behavior, live Firebase/App Check, or real account data |
| `xcodebuild -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` through the bounded runner | Pass | iOS-only ownership code type-checks and the app embeds/validates Watch, Watch complications, and widgets | Signing, physical devices, WatchConnectivity, BLE, background execution, or delivery |
| `python3 Tools/i18n_audit.py --platform all --full` | Pass; tracked Apple baseline remains 129 | No localization regression; all existing focus-locale catalog keys and Android locale resources are complete | Native-speaker review or visual fit |
| Private-data guard, 1,312-file health-claims scan, nine source release controls, operations validation, JSON/XML parsing, and diff hygiene | Pass | The change adds no tracked private filename, unsafe health claim, release-control regression, malformed catalog/resource, or operations-record error | External credentials, legal approval, hosted production state, or physical behavior |
| Live `gh pr view 16`, `gh pr view 17`, and remote-ref queries | PR 16 merged at `9c5141754`; PR 17 exact head `169230a9a` is open, mergeable, and 10/10 required contexts pass | The release-blocker handoff is refreshed from current protected repository state | Approval, integration of this follow-on branch, or physical behavior |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: hosted macOS/iOS simulator and source
  evidence only at round start.
- Data-preservation result: no data mutation at round start.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical Apple/Android/Watch and band scenarios.
- Round-owned resource cleanup: exact-deleted
  `/tmp/noop-mac-history-derived` and
  `/tmp/noop-mac-history-ios-derived` after their bounded build processes
  terminated, reclaiming about 8.7 GiB. No shared DerivedData, simulator,
  source, session, user data, or unrelated temporary path was removed; both
  paths were verified absent and system free space was about 23 GiB afterward.

## Git and release state

- Changed paths: macOS runtime entry, Watch snapshot/publication/complication
  behavior, Apple and Android ownership recovery UI/services/tests/locales, and
  this operations record.
- Commits: macOS/Watch checkpoint `50d41e5c8` and `6b36f035e`;
  account-recovery and Watch-policy correction checkpoint `7b3250b9e`;
  first-run hierarchy and named-progress checkpoint `c71dde298`; Daily Signal
  baseline-state copy checkpoint `cf967394c`; authority-guidance checkpoint
  `f3c98eaa1`; managed-document conflict recovery checkpoint `8e3947854`.
  History-only managed restore checkpoint `415bf5909`; macOS account-history
  viewer checkpoint `9d57b6b35`.
- Branch and remote state:
  `codex/sept17-readiness-closeout-20260926` tracks its public remote.
  Checkpoints through `9d57b6b35` are pushed and triggered zero workflows
  because the branch has no pull request and push workflows are scoped to
  `main`.
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

- PR 17 still requires non-author approval and protected integration.
- The localization baseline is not zero; native-speaker and visual-fit review
  remain unproved.
- Managed-document conflict resolution deliberately keeps the newer local
  generation and requires a later explicit retry; no automatic field merge is
  claimed.
- The Mac viewer restore is source/simulator verified but not exercised against
  a signed production account. Large-history catch-up latency and continuation
  require staging and physical validation.
- App-level database encryption and existing-user authority migration require
  separate approved designs and evidence before activation.

## Next round

1. Reconcile the remaining Account/Data & Sync information-architecture
   finding against current iPhone and Android source.
2. Run the applicable complete Apple/Android/repository-control walls.
3. Open or update the normal protected review only after the consolidated
   candidate is locally green, then require exact-head hosted checks,
   non-author approval, protected integration, and protected-main verification.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
- [x] Round-owned isolated DerivedData, bounded logs, status files, and release
      report were removed after their outcomes were recorded.
