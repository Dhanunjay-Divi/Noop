# Round: 2026-09-07 - Production readiness execution

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/production-readiness-closeout-20260907`
- Start commit: `52a84649c33c57b091c110e2b2912d2021ce7ffb`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Complete every supplier-independent production-readiness action that can be
implemented and honestly verified in the current environment. Re-audit
calibration, metric truth, storage, performance, Apple/Android behavior,
backend/cloud operation, security, release controls, and resource cleanup from
current source; fix defects found; and leave only gates that require supplier
contracts, first-party hardware, physical-device evidence, participants,
external approval, signing authority, or elapsed production operation.

## Scope

### In scope

- Reconcile all pending engineering checklist actions against current source
  and evidence.
- Run fresh calibration, causality, missing-data, longitudinal-stability,
  provenance, and cross-platform metric checks.
- Exercise long-history storage, migration, backup, restore, export, and
  performance tooling that does not require personal health data.
- Rebuild and test Apple, Android, server, Swift packages, study tools,
  repository policy, and private synthetic staging.
- Implement and verify supplier-independent defects and missing controls.
- Review observability at every changed user-visible or operational boundary.
- Remove temporary resources created by this round.

### Non-goals

- Do not invent first-party firmware, protocol bytes, sensor calibration, or
  possession proof before the supplier dossier exists.
- Do not claim physiological accuracy, physical background reliability,
  battery life, haptics, carrier delivery, signed distribution, legal approval,
  certification, manufacturing readiness, or store acceptance without their
  required evidence.
- Do not enable public ingress, production traffic, real paging, payment, or
  real health-data transfer.

## Starting evidence

- Reproduction or observed symptom: the owner requested complete end-to-end
  execution with a fresh review of calibration and all currently executable
  work.
- Relevant source/device/OS/firmware class: Apple and Android apps, shared
  Swift/Kotlin analytics and storage, FastAPI/PostgreSQL services, guarded GCP
  staging, release tooling, and the future first-party band boundary.
- Existing tests, logs, exports, screenshots, or documents: clean synchronized
  `main` at the start commit; 396 stable checklist actions with 44 evidenced
  complete and 352 pending. Prior rounds report green source matrices and
  private synthetic staging but no first-party firmware, production band,
  signed physical-client, participant, carrier, legal, certification, or
  storefront evidence.
- Unknowns that must remain unknown until measured: supplier protocol and
  firmware behavior; production sensor calibration; physical BLE/background,
  battery, haptic, OTA, and storage behavior; population metric accuracy;
  carrier delivery; legal/certification/store outcomes.

## Delivered

- Added matched provenance-gated official-reference comparison and
  holdout-validated personal presentation calibration on Apple and Android.
  The UI deliberately exposes only Charge, Effort, and Rest for calibration;
  the engine supports nine additional raw/direct metric comparisons without
  misrepresenting them as independently recomputed score families.
- Made calibration persistence fail closed on both platforms and bound every
  stored model to its metric, scoring revision, chronological holdout evidence,
  untouched raw estimate, and separately labeled calibrated estimate.
- Added a machine-readable 12-metric calibration contract and a release gate
  that rejects Apple/Android drift in series keys, ranges, revisions,
  thresholds, chronological holdout, duplicate rejection, RMSE non-regression,
  calibrated-output exclusion, and source-namespace separation.
- Made official-import provenance manifests transaction-aware: stale evidence
  is invalidated before replacement and a successful manifest is written only
  after the data transaction commits.
- Reconciled Apple and Android computed scores atomically across daily and
  metric-series surfaces, including forced late-failure rollback and a
  1,200-day case that avoids SQLite variable-bind limits. Both clients reject
  malformed dates, duplicate ownership, invalid managed keys, non-finite
  values, and out-of-window rows before mutating either store.
- Kept Apple analysis retryable after persistence failure: the idle-analysis
  watermark now advances only when score publication, active-minute
  publication, and repair all succeed. Bounded diagnostics retain only a fixed
  failure category rather than database error text.
- Added bounded generic metric reads and rejected non-finite and legacy
  sleep-efficiency-unit values rather than letting invalid rows reach UI or
  calibration.
- Added a deterministic long-history harness for 10, 30, 90, and 365 days,
  exact retained-content backup/restore verification, storage attribution,
  WAL, export, and bounded read timing.
- Defined fail-closed metric reprocessing and rollback, complete key lifecycle
  ownership, and coordinated vulnerability/security-update handling; made all
  four policy documents required release inputs without claiming that
  production keys, staffed intake, firmware, or response drills exist.
- Replaced false first-party labels on compatibility hardware with
  `Compatible band`, added a complete classified terminology inventory and
  machine-readable active-use ratchet, and wired the ratchet into release CI.
- Normalized stable hosted check names so protected-main required checks can be
  configured against durable contexts.
- Verified and closed three matched mobile behavior contracts: automatic
  history recovery expands for three seconds over cached content before
  compacting without blocking the app; each month-calendar metric opens its
  own category-scoped day overview; and reselecting the active bottom tab
  returns nested metric/calendar routes to that tab's root.
- Added a disclosed deterministic Review Sample Mode to the shipping Apple and
  Android source. It appears before Terms on a fresh install, keeps fictional
  values inside a visibly labeled process-only presentation tree, covers
  Today, metric detail, Trends, Workouts, Sleep, Friends, privacy, and Devices,
  and exits into the normal Terms/setup journey. Android defers Room, BLE,
  cloud, ownership, workers, notifications, and the operational ViewModel until
  current Terms are accepted. Apple constructs its existing inert bootstrap
  objects but starts `AppModel` with operational work disabled and never passes
  sample values into the production repository, HealthKit, cloud, Friends,
  notification, or Safety paths.
- Corrected the Android consent transition found by the final source review:
  returning consented users no longer repeat activity route, scheduler,
  profile, or sensor repair, while a genuine first-acceptance transition still
  resumes those hooks exactly once. Pre-consent configuration changes also no
  longer request a widget refresh.
- Removed WorkManager's AndroidX Startup initializer and supplied its
  configuration lazily from `NoopApplication`. A fresh API 35 sample journey
  now proves WorkManager remains uninitialized before entry and after exit to
  Terms, while the merged manifest retains the unrelated Emoji, lifecycle, and
  profile startup components.
- Passed the staged release-control, health-claims, localization, runtime
  license, distribution-rights, private-data, operations-record, workflow
  syntax, and exact-diff whitespace gates.
- The final release-control review found that path-filtered platform workflows
  could not be configured as stable protected-branch requirements. Android,
  Apple, Swift-package, and server CI now run an always-present applicability
  job and publish one fail-closed required result. Expensive jobs still skip
  irrelevant changes, but applicability errors, skipped applicable work, or
  any failed heavy job make the stable result fail.
- Added a machine-readable merge and release context contract with
  repository tests. The production release workflow now builds only the exact
  reviewed `main` commit, cannot bump or commit a version inside CI, validates
  that Apple, Android, release notes, localization, and in-app What's New
  already match, and verifies every required check on the exact SHA before
  draft creation and again before publication.
- Protected review found and closed two additional release defects. Runtime
  license inventory now has an always-present fail-closed required result, and
  the lightweight health-claims, localization, operations-record, and release
  controls are modeled as universal checks that cannot use event-level path
  filters. The contract now covers nine exact contexts; operations validation
  runs on every `main` commit so exact-SHA publication evidence is always
  available.
- Added a tested release-version gate that compares both reviewed platform
  build numbers and the shared marketing version with the latest published
  production tag. A reused Android `versionCode`, Apple
  `CURRENT_PROJECT_VERSION`, non-advancing semantic version, missing prior tag,
  prior tag/source mismatch, or an existing destination tag bound to another
  commit stops the workflow before draft creation.
- Bound exact-SHA publication checks to the same GitHub Actions application
  identity enforced by protected `main`, so a same-named check from another app
  cannot satisfy release policy. The AltStore publication lane no longer
  pushes directly to protected `main` or advertises a draft IPA. A reusable,
  manually repairable workflow updates an anonymously verified stable
  prerelease asset only after the exact checked production release is
  published. Existing channel history is mandatory once the channel exists,
  and a tested semantic-version guard rejects rollback to an older feed. If a
  first publication created the channel release but failed before uploading
  its initial manifest, a retry now recovers from the reviewed template;
  existing manifest history remains mandatory once the asset is present.
- Closed the final applicability defect found by protected review. All five
  conditional workflows now write the complete changed-path list before
  matching it, so `grep -q` cannot close a `pipefail` pipeline early and turn a
  relevant large change into `run=false`. Rename detection is disabled for this
  path inventory, so both the removed source and added destination are checked
  and a move out of a scoped directory cannot bypass its required build. The
  repository contract requires this complete-consumption shape.
- Removed the legacy local release publisher and checked-in AltStore mutator.
  `Tools/release.sh` now accepts only a version, requires a clean exact
  `origin/main`, rechecks release controls and exact-SHA hosted contexts,
  preserves the cadence guard, and dispatches the canonical production
  workflow with the already verified source SHA as a required input. If `main`
  advances before GitHub resolves the dispatch, the workflow fails closed
  instead of building the newer commit. The dispatcher cannot create, edit,
  upload, or push a release directly.
- Closed the three post-release defects found across the final protected reviews.
  AltStore replacement now preserves the complete current manifest as a
  separate durable release asset before `--clobber`; an interrupted
  replacement restores from that asset only when the stable asset is absent.
  A transient stable-asset fetch failure now fails closed instead of selecting
  older history, while template recovery is permitted only for a release
  explicitly marked as an unfinished first publication.
  Both AltStore and Homebrew repair paths require their production tag to be
  contained in protected `main` and to retain the exact required check set.
- Restored the documented Homebrew opt-in as a retryable reusable/manual
  workflow after immutable release publication. The guarded local dispatcher
  carries only the opt-in decision. The workflow requires a public source, a
  public project tap, exact platform versions and artifact size, a
  repository-scoped tap owner variable, and a tap-only write secret. The
  helper accepts the scoped token through the environment, validates every
  repository coordinate before network access, and retains its deliberate
  local token-file fallback. No tap or token is provisioned by this round, so
  the lane remains disabled by default and no release was published.
- Closed the retained Homebrew-to-Forgejo mirror path without broadening
  release credentials. The local and GitHub dispatchers now carry the nested
  opt-in explicitly, reject a Forgejo-tap request when canonical Homebrew
  publication is disabled, pass only the tap-specific GitHub and Forgejo
  secrets to the reusable workflow, and fail the requested mirror operation
  visibly if the canonical GitHub tap succeeds but the Forgejo push fails.
- Added a bounded Forgejo semantic-version history gate before every release
  create or update. It inspects at most 500 records in each bounded published
  and draft view, retains interrupted draft refreshes in the rollback
  baseline, ignores prereleases and unrelated non-semantic tags, allows an
  idempotent retry, and rejects an older target than the latest stable mirror.
  Exact-tag lookup now distinguishes a missing release from transport or
  server failure instead of treating every lookup failure as permission to
  create.
- Bound exact-SHA required-check verification to the owning GitHub Actions
  workflow as well as the Actions application. The verifier obtains each
  required check's Actions run, requires the exact requested head SHA and
  configured workflow path, and rejects same-named checks from another
  workflow. A repository-wide structural guard also requires exactly one
  source workflow owner for every protected context. Release and repair jobs
  have the explicit `actions: read` permission needed for that validation.
- Closed the final independent release-integrity findings before merge.
  Required-check ownership now treats every dynamic job display name as a
  wildcard and rejects it when it could resolve to any protected context;
  inline or differently indented jobs and noncanonical property keys also fail
  closed, as do folded, aliased, tagged, escaped, or comment-ambiguous display
  names. A job without a display name is checked by its job ID.
  Forgejo asset uploads have both connect and total timeouts under a bounded
  workflow job, clear the complete attachment set returned by Forgejo's
  non-paginated release-asset API under a 10 MiB JSON-response bound, require
  exact hosted attachment URLs, names, sizes, types, and byte content, and
  return a changed post-publication set or payload to a response-verified
  draft. An already exact release is
  idempotent without mutation. The Homebrew-to-Forgejo repair path now runs
  even when the canonical tap is already current, and each Git host process
  receives only its own scoped credential. Optional Forgejo variables and
  credentials are absent from the Homebrew publication environment unless the
  nested mirror opt-in is selected.
- Bound GitHub release publication to the live destination tag immediately
  before and after mutation. Lightweight and bounded annotated tags must
  resolve to the exact reviewed commit; a changed tag, unexpected release
  identity/state, or changed/nonempty exact asset set returns that exact
  release to a response-verified draft before the workflow fails.
- Removed the remaining legacy vendor name from generated Homebrew package
  metadata. The reviewed terminology snapshot now contains 17,370 classified
  occurrences across 1,508 path/category groups, one active/core occurrence
  fewer than the preceding candidate, with zero forbidden mappings.
- Fixed the intermittent Android diagnostic-report test at the product
  boundary. While screenshot compression was pending, Android supplied a null
  switch callback, which removed `ToggleableState` instead of exposing a
  disabled default-off control. Android now matches iOS by retaining the switch
  semantics and disabling it until the transient capture is available. The
  archive still proves that no screenshot is attached without explicit opt-in.
- Reconciled the user and operator documentation with the stable release-asset
  AltStore channel and corrected current engineering guidance that still
  described required Apple and Android workflows as disabled.
- Reverified retained private GCP staging: OpenTofu format, validation, all
  three configuration tests, IAM-only runtime checks, and detailed live plan
  exit `0` pass with no drift.
- Removed every generated local resource created or reused for this round from
  the workspace: the isolated Python environment, Android build/cache output,
  all Swift package build directories, custom Xcode DerivedData, OpenTofu
  provider cache, Python bytecode caches, and temporary reports/plans. More
  than 20 GB was moved to macOS Trash through the explicit-path system utility;
  the user's unrelated Trash was not emptied. No Gradle daemon, Android
  emulator, or booted Apple simulator remains.

## Data, privacy, and medical truth

- Schema or migration impact: no production schema migration was added. Apple
  and Android score reconciliation changes transaction semantics only; the
  long-history harness uses production APIs against disposable synthetic
  databases.
- Existing-data retention impact: no new destructive migration is authorized.
  The measured candidate keeps seven days of high-rate raw detail, 30 days of
  essential time series, and full compact/user-authored history. Managed
  pruning remains conditional on exact server validation of an unchanged,
  complete window.
- Source/provenance or formula impact: Charge, Effort, and Rest raw formulas
  are unchanged. Personal calibration is presentation-only, chronological,
  revision-bound, and accepted only on unseen holdout improvement. Imported
  official outcomes never enter the raw formulas.
- Permissions/network disclosure impact: no public or production network
  boundary is enabled by this round.
- Health/medical claim impact and limitations: wellness outputs remain
  non-medical; unvalidated inputs and claims remain unavailable.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded app diagnostics, server request/operation events, deterministic test
  results, migration manifests, performance summaries, and private staging
  checks.
- Why existing evidence is sufficient, or why new evidence is required:
  source-only changes reuse established evidence where it answers the exact
  boundary; new persistence, long-running, transport, or network boundaries
  require bounded lifecycle evidence in the same change.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, server
  request middleware and operational events, release manifests, and operations
  records.
- New bounded events or operation spans: Apple and Android comparison work
  records a fixed metric category, duration, paired-day count, calibration
  decision, persistence outcome, and bounded failure kind. Import replacement
  records only invalidate/stamp phase, result, and range count. Apple score and
  active-minute persistence failures expose only the bounded failure kind and
  deliberately clear the analysis watermark so the next idle pass retries.
  Review Sample adds no high-frequency or payload evidence because it has no
  long-running, persistence, device, or network operation. Existing Apple
  launch evidence records the fixed `operational=false` state; Android records
  only the bounded `runtime.operational_started` and
  `activity.operational_runtime_available` transitions after consent. Required
  CI and release verification records only fixed workflow context names and
  bounded missing, running, failed, skipped, unexpected-workflow, or successful
  states. Workflow-run identifiers and URLs are used only for authenticated
  lookup and are not emitted. Post-release
  channel automation records only static validation/recovery categories,
  workflow status, version, and bounded artifact presence; it does not emit
  credentials, user data, or artifact content.
- Redaction, retention, and high-frequency controls: no raw health values,
  sensor rows, user text, credentials, identifiers, dynamic URLs, payloads, or
  arbitrary errors enter diagnostics.
- Cross-platform/backend correlation: static operation/route categories and
  server-generated request IDs only.
- Remaining blind spots: physical hardware and every external gate listed
  above.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Starting Git and release-ledger audit | Clean synchronized `main`; 44 complete and 352 pending actions | Exact source and planning baseline | Production readiness |
| Swift package matrix | Nine package build/test lanes green; StudyHarness 12 tests and HistoryHarness 2 tests green | Shared analytics, storage, import, design, remote-sync, study, and history source behavior | Physical app behavior |
| Calibration parity gate | 12 metrics, 3 revisions, 13 thresholds, and 16 critical guards match on Apple and Android; 15 audit/release-gate tests pass | Machine-enforced cross-platform calibration contract and fail-closed drift detection | Physiological accuracy on production hardware |
| macOS application suite | The final isolated macOS result bundle reports 1,654 passed, 1 external-fixture skip, and 0 failures after a successful universal app build | Current application source and backup/calibration contracts on macOS | Signing, notarization, or phone behavior |
| iOS simulator application suite | The final isolated iPhone 17 Pro / iOS 26.5 result bundle reports 34 passed, 1 intentional private-pilot skip, and 0 failures after a successful simulator app build; Review Sample also passed standard and compact layout runs plus the final 18.348-second entry/disclosure/detail/exit-to-Terms journey | Current production shell, navigation, onboarding, settings, calendar, body-map, updates, Review Sample isolation/presentation, and scroll behavior on the simulator | Physical iPhone, signing, background radio, thermal, or battery behavior |
| iOS Release simulator build | Complete app, widgets, Watch app, complications, and launch-gate script built successfully in Release configuration | Shipping-source graph and Release compilation include Review Sample | Distribution signing, Organizer validation, or exact App Review archive |
| Android source gate | Final post-review full debug assemble, unit, lint, and instrumentation compile completed 70 tasks successfully; the merged manifest contains no WorkManager initializer while retaining the other AndroidX Startup components | Current Android source, resources, consent/runtime deferral, lazy worker initialization, diagnostic-report accessibility/privacy, and lint contract | Physical OEM/background/BLE behavior |
| Android API 35 managed device | The exact CI sequence passes: the fresh-process Review Sample journey passes 1/1, then the complete suite reports 54 scheduled tests plus UTP accounting, 2 intentional private-pilot skips, and 0 failures. Focused report and disabled-switch regression tests also pass together | Production-shell, persistence, rollback, navigation, Review Sample presentation/exit, pre-consent worker isolation, screenshot default-off semantics, and emulator behavior | Physical phone, radio, battery, or attestation |
| Android Release build | Final `assembleFullRelease` completed 54 tasks successfully in 1m 14s, including lint-vital and signing validation, using a one-use locally generated certificate removed immediately after the build | Final shipping source compiles, dexes, packages, and passes Release-vital checks | Production upload key, Play App Signing, signed RC identity, or store acceptance |
| Server Python 3.12 | Ruff and runtime/dev dependency audits green; 296 passed and 63 environment-gated skips | Source behavior and dependency policy in the isolated local environment | Container, PostgreSQL, public topology, or production operations |
| GCP private staging plan | OpenTofu format, validate, three tests, and live plan green with zero drift | Retained IAM-only synthetic staging matches source | Public or production deployment |
| GCP private runtime verifier | Passed internal ingress, no broad invoker, digest pin, scale bounds, PITR, and deletion-protection checks | Current private synthetic runtime keeps its intended infrastructure controls | Application correctness, public topology, or real-data operation |
| Long-history synthetic matrix | All 10/30/90/365-day scenarios passed integrity and exact restore; report in `validation/HISTORY-HARNESS-2026-09-07.json` | Current host storage shape and exact retained-content recovery | Phone memory, thermal, battery, background, BLE, or population accuracy |
| Staged repository policy matrix | 142 repository-tool tests and the exact 105-test release-control selection pass; release controls 9/9; terminology covers 17,370 classified occurrences in 1,508 path/category groups with zero forbidden mappings; calibration parity covers 12 metrics, 3 revisions, 13 thresholds, and 16 guards; health-claims 1,195 files clear; i18n passes; legal inventory covers 213 runtime components plus 3 container inputs; private-data and all 36 operations records pass; 14 workflows parse and pass `actionlint`; the changed Bash helpers pass syntax and ShellCheck | The exact staged source satisfies repository release, calibration-drift, privacy, claims, localization, legal, workflow-syntax, and operations contracts | Hosted execution or store approval |
| Required merge, tag, and repair contract | Five conditional and four universal workflow contracts plus nine stable contexts pass local structural tests; every protected name has one configured workflow owner; live read-only verification bound all nine checks on commit `bf77f902` to their exact Actions workflow and head SHA, then correctly reported only the two intentionally canceled platform runs as failed; release source mutation is rejected, both build counters must advance from published `v9.1.1`, exact-SHA verification is required twice, AltStore history is backed up before replacement, ambiguous channel recovery fails closed, Forgejo rollback is rejected before mutation, and nested Homebrew mirroring reaches a scoped, manually repairable exact-tag workflow | Applicable platform/license failures cannot be hidden by event path filters or a same-named Actions job, and production or repair publication cannot proceed from an unchecked, stale-build, off-main, backward-version, or history-dropping source | A completed signed production release, public Homebrew/Forgejo tap, or provisioned mirror credentials |
| Scoped local cleanup | Generated Python, Android, Swift, Xcode, OpenTofu, bytecode, and temporary artifacts absent; no Gradle daemon, emulator, or booted simulator; only the pre-existing PostgreSQL listener remains on the audited ports | This round left no active local app/test runtime or generated workspace cache | Reclaimed disk until macOS Trash is emptied, or removal of intentionally retained private staging |

## Physical device and deployment

- Install/update action: Android managed-device test installation only; no
  physical-device update was claimed.
- Generalized device and OS class: API 35 managed Pixel-class emulator and
  current Apple simulators/host.
- Data-preservation result: synthetic exact restore passed; signed
  physical-device upgrade preservation remains open.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party band and production physical-device
  gates until corresponding hardware exists.

## Git and release state

- Changed paths: calibration, import provenance, Apple and Android score
  reconciliation and validity, Apple analysis retry semantics,
  comparison/export UI, compatibility labels, long-history tooling,
  localization, metric rollback, key/security operations, disclosed Apple and
  Android Review Sample presentation/runtime gates, release workflows/policy,
  stable required-check enforcement, exact-SHA tag verification, failure-safe
  AltStore history repair, retryable Homebrew publication, validation evidence,
  and release documentation.
- Commits: pending.
- Branch and remote state: clean synchronized `main` at round start; PR `#6`
  carries the protected closeout branch. Four implementation commits are
  already pushed. The final post-release channel fixes now pass the complete
  local repository-policy evidence and remain local only until the next
  closeout commit is created. Hosted final-head and exact-main evidence remain
  pending.
- Repository visibility verified: inherited from current release evidence.
- Version/build impact: none at round start.
- Release or distribution impact: release and repair workflows changed, but no
  production release, AltStore source, Homebrew tap, Git tag, or app artifact
  was created or mutated.

## Decisions

- Durable decision added or changed: none at round start.
- Decision-log entry: pending only if implementation changes a durable product
  boundary.

## Open risks and honest limitations

- A complete source pass cannot close supplier, physical, participant,
  regulatory, carrier, signing, store, or elapsed production-operation gates.
- Review Sample source implementation is complete, but the exact
  distribution-signed archive/AAB, private App Review/store-console record,
  sanitized reviewer video, and store-operated journey remain open. Apple also
  retains its pre-existing inert bootstrap construction before the sample
  screen; source and simulator evidence proves operational work and sample
  values stay isolated, not that the process constructs no local objects.
- Seven-day raw and 30-day essential managed retention remains a measured,
  implemented candidate rather than the final owner-approved all-class policy.
- Homebrew automation is code-complete but remains intentionally disabled
  until the owner creates the public project tap and provisions the scoped
  repository variable and tap-only write secret.
- The measured retained 365-day database is about 444 MB and exact
  backup/restore temporarily reaches about 1.33 GB. Indexed host reads are fast,
  but only representative phones can establish launch, scroll, memory,
  thermal, background-collection, and low-storage budgets.

## Next round

1. Continue from the first remaining external or signed-release dependency
   after this execution round closes.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
