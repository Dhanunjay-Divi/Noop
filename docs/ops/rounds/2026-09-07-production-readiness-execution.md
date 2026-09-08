# Round: 2026-09-07 - Production readiness execution

## Status

- State: `complete for supplier-independent source and repository work`
- Owner: project team
- Continued: `2026-09-08`
- Branch: `main`
- Start commit: `52a84649c33c57b091c110e2b2912d2021ce7ffb`
- End implementation commit: `59093db492b84862c8fb282f9f6976c84c1886ea`
- Record commit or PR: pull request `#6`, merged as
  `c3c377abd57ab090b2ed0b5ade4461f6769a0d3a`; trust compatibility and
  activation follow-ups `#7` and `#8`

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
  filters. The bootstrap contract retains nine exact contexts while installing
  the protected-base workflow needed for a separately reviewed tenth-context
  activation; operations validation runs on every `main` commit so exact-SHA
  publication evidence is always available.
- Added a tested release-version gate that compares both reviewed platform
  build numbers and the shared marketing version with the latest published
  production tag. A reused Android `versionCode`, Apple
  `CURRENT_PROJECT_VERSION`, non-advancing semantic version, missing prior tag,
  prior tag/source mismatch, or an existing destination tag bound to another
  commit stops the workflow before draft creation.
- Bound exact-SHA publication checks to the same GitHub Actions application
  identity enforced by protected `main`, so a same-named check from another app
  cannot satisfy release policy. The retained AltStore implementation no longer
  pushes directly to protected `main` or advertises a draft IPA, but immutable
  GitHub Releases cannot host its required mutable source pointer. Direct
  dispatch is removed and production release invocation is hard-disabled until
  the pointer is moved to a separate host and anonymous fetch/install behavior
  is verified. Its history, rollback, and interrupted-initialization controls
  remain tested dormant code rather than an advertised channel.
- Closed the final applicability defect found by protected review. All five
  conditional workflows now write the complete changed-path list before
  matching it, so `grep -q` cannot close a `pipefail` pipeline early and turn a
  relevant large change into `run=false`. Rename detection is disabled for this
  path inventory, so both the removed source and added destination are checked
  and a move out of a scoped directory cannot bypass its required build. The
  repository contract requires this complete-consumption shape.
- Removed the legacy raw local release mutator and checked-in AltStore mutator.
  `Tools/release.sh` now accepts only a version, requires a clean exact
  `origin/main`, rechecks release controls, live repository policy, and
  exact-SHA hosted contexts, preserves the cadence guard, and dispatches the
  canonical production draft build with the already verified source SHA. It
  finds and waits for exactly that run title, workflow path, source, branch,
  repository, and successful conclusion before rechecking policy and publishing
  through the bounded shared publisher. A failed, interrupted, or ambiguous run
  leaves a nonpublic draft. The script never uses raw `gh release` mutation.
- Closed the final publication findings from independent review. Testing tags
  now use their own strict verifier and no-bypass ruleset profile. Production
  and testing Actions stop at exact verified drafts because the Actions token
  cannot inspect the administration-only immutable-release setting; an
  owner-authenticated local command verifies that setting and the appropriate
  ruleset before dispatch, immediately before mutation, and again after
  publication. The repository gate structurally locks both
  exact-check and draft-verification steps, rejects job/step skip wrappers, and
  requires owner-side run identity verification. Failed testing cleanup retains
  a candidate on any lookup error rather than deleting a tag after a guessed
  absence.
- Restored the documented Homebrew opt-in as a retryable reusable/manual
  workflow after immutable release publication. The guarded local dispatcher
  dispatches it only after canonical publication. The workflow requires a
  public source, a public project tap, exact platform versions and artifact
  size, a repository-scoped tap owner variable, and a tap-only write secret.
  The helper accepts the scoped token through the environment, validates every
  repository coordinate before network access, and retains its deliberate
  local token-file fallback. No tap or token is provisioned by this round, so
  the lane remains disabled by default and no release was published.
- Closed the retained Homebrew-to-Forgejo mirror path without broadening
  release credentials. The local dispatcher carries the nested opt-in
  explicitly, rejects a Forgejo-tap request when canonical Homebrew
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
- Added an owner-only trust root for every release-authority change. The
  `pull_request_target` validator executes only protected-base source, treats
  the candidate checkout as untrusted data, requires the repository owner to
  be the exact `opened` or `synchronize` event actor for an in-repository
  release-authority change, has no manual-dispatch trigger, and writes one
  explicit `trusted-release-controls` check to the exact pull request head.
  Candidate semantics remain independently enforced by the required
  `release-controls` check. The trusted check payload, scope, Actions app, run
  ID, attempt, event, workflow path, repository, details URL, external ID, head
  SHA, and conclusion must all agree. A failed, skipped, or canceled validation
  writes a bounded failure check and exits failed; no native same-named skipped
  job or branch copy can manufacture the protected context. Exact-SHA release
  verification accepts only the `protected-main` scope, so the otherwise valid
  custom check on a pull request head cannot authorize publication.
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
  return an unexpected public creation, invalid publication response, failed
  post-publication asset lookup, or changed post-publication set or payload to
  a response-verified draft. Stateful fake-Forgejo tests exercise each
  rollback and explicit rollback-failure path through the real shell helper.
  An already exact release is idempotent without mutation. The
  Homebrew-to-Forgejo repair path now runs
  even when the canonical tap is already current, and each Git host process
  receives only its own scoped credential. Optional Forgejo variables and
  credentials are absent from the Homebrew publication environment unless the
  nested mirror opt-in is selected.
- Closed the final automated release-path findings on the exact candidate.
  Testing-snapshot run and attempt captures are saved before the independent
  version regex can replace Bash's match state. Production release history is
  obtained by one latest-first query that excludes drafts and prereleases
  before applying its one-result bound, and the same stable tag drives version
  monotonicity plus generated notes. Homebrew publication has a 20-minute job
  bound; every remote Git clone or push also has a maximum five-minute process
  deadline and a 30-second low-speed cutoff. A failed or timed-out clone now
  fails closed instead of constructing an empty local tap. Behavioral tests
  execute both the valid testing tag path and a deliberately hanging Git
  transport.
- Bound GitHub release publication to preventative repository controls rather
  than an Actions-side post-exposure rollback. The private repository has an
  active no-bypass production tag ruleset that rejects update and deletion of
  `v*` tags and an active no-bypass testing ruleset that rejects updates to
  `testing-snapshot-*`. The immutable-release setting remains intentionally
  disabled through the nine-context bootstrap merge. It is enabled only after
  a separately reviewed activation change adds the protected-base trust
  workflow as the tenth source context, the exact custom protected-main check
  passes, and live branch protection matches all ten source contexts. Each
  workflow now defaults to read-only repository access; only the exact
  draft-creation, artifact-upload, and failed-draft cleanup jobs receive
  `contents: write`, and any additional write-capable job fails the repository
  gate. The owner publisher loads the reviewed activation contract, rejects a
  missing trusted context, requires live strict branch protection to contain
  exactly the same contexts under the GitHub Actions application, and then
  checks the immutable setting and exact tag ruleset before dispatch,
  immediately before mutation, and after publication;
  resolves lightweight or bounded annotated tags against the exact reviewed
  commit with a stable-ref reread; binds testing tags to their encoded run and
  attempt; and requires the exact five uploaded assets by server-assigned ID,
  positive size, uploaded state, and server-computed SHA-256 digest. The
  workflow retains that identity in an exact run-attempt manifest, and the
  owner publisher rejects any changed asset before or after mutation. Two
  fresh release-by-ID reads confirm the exact immutable release. A timed-out
  publish request is accepted only if those live immutable checks prove it
  completed correctly. Production and testing workflows each execute only a
  canonical mutation-free draft verifier; the repository gate rejects changed
  arguments, shell wrappers, skip conditions, workflow-side publication,
  direct release REST mutation, and raw owner-script mutators. Bash syntax and
  ShellCheck for both owner entrypoints are now part of the required hosted
  release-control check. Every workflow, policy input, schema, and helper with
  release-publication authority is also bound to an explicit reviewed SHA-256
  source contract, so shell token concatenation, an extra write step, or an
  unrelated cleanup deletion cannot pass by evading literal command scanning.
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
- Reconciled user and operator documentation with immutable fixed releases,
  owner-promoted testing snapshots, and the disabled AltStore pointer; also
  corrected current engineering guidance that still described required Apple
  and Android workflows as disabled.
- A second independent publication review found that no-bypass update/deletion
  rules did not restrict initial tag creation, testing builds could expose
  repository-scoped Android signing secrets to a branch-selected workflow,
  testing metadata was not canonical, and the draft-to-public transition still
  depended on a mutable interval. Production and testing now each have two
  active tag rules: an administrator-only creation rule and a separate
  no-bypass update/deletion rule. The publisher requires the authenticated
  repository owner, rejects every non-owner collaborator with write, maintain,
  or administrator access, and rechecks this policy immediately before
  publication.
- A private synthetic GitHub probe proved that creating a draft release does
  not create its Git tag; the probe draft and tag locator were removed
  immediately. This exposed a previously masked functional defect in the
  verifier. Draft verification now requires the destination tag to be absent,
  publication checks absence again immediately before mutation, and only the
  resulting immutable release may introduce an exact tag that resolves twice
  to the reviewed commit.
- Testing candidates are now restricted to the exact protected `main` commit.
  Their title, body digest, target, run, attempt, assets, and source are bound
  in the candidate manifest. Both testing and community-release Android
  signing jobs read only from the protected `staging` environment; metadata
  jobs cannot access those values. The live manual dispatchers are disabled
  until the four write-only signing values are re-entered as environment
  secrets and their repository-scoped copies are removed; no secret value was
  read, printed, copied, or deleted by this round.
- Reverified retained private GCP staging: OpenTofu format, validation, all
  three configuration tests, IAM-only runtime checks, and detailed live plan
  exit `0` pass with no drift.
- A fresh hosted Android run exposed an evidence-retention defect rather than
  an application assertion failure: the managed-device job exceeded its
  50-minute outer ceiling after the isolated Review Sample test had passed, so
  GitHub terminated the job before the always-run diagnostic upload and
  retained no artifact. Each emulator invocation now runs in its own process
  group under a shorter hard deadline, receives a bounded graceful termination
  followed by a hard kill when necessary, and writes a fixed success, failure,
  timeout, or start-error status beside the managed-device output. The complete
  suite excludes the already-proven Review Sample class, and the job-level
  timeout is now only a 70-minute fallback after all per-command deadlines and
  diagnostic upload. The helper and process-group behavior are unit-tested in
  the hosted Android build lane.
- Exact-head run `34189356723` then proved that retention boundary under a
  different infrastructure failure. Android build, unit, lint, and
  instrumentation compilation passed. The isolated managed-device command
  spent about ten minutes compiling, entered the device task, produced no test
  result, and timed out. The wrapper retained an exact 63-byte
  `review-sample-fresh-process/timeout/124` status, the artifact upload
  completed, and the 70-minute outer ceiling was never reached. GitHub's final
  cleanup found orphaned emulator and ADB processes, confirming a boot/runtime
  stall rather than an app assertion. The final candidate now prepares APKs,
  test APKs, the emulator image, and the managed-device setup under their own
  deadline; the isolated test deadline therefore measures device/test
  execution instead of compilation. Only an exact timeout before any test
  result or the existing exact activity-service loss may trigger one retry.
  Gradle's own bounded `cleanManagedDevices` task clears the stale AVD before
  that retry. Any partial test result, malformed status, cleanup failure, or
  second failure remains terminal.
- Completed the protected merge sequence without bypass: pull request `#6`
  passed the full Apple, Android, server, package, policy, and calibration
  matrix; pull request `#7` repaired canonical GitHub check-link handling
  without weakening provenance; and pull request `#8` activated the tenth
  trusted context.
- Verified merged protected `main` commit `d8cee4f6` with all ten exact-SHA
  checks, including protected-main custom check `101959809854` owned by GitHub
  Actions application `15368`. Live protection is strict, administrator
  enforced, conversation-resolution and linear-history gated, and denies force
  pushes and deletion.
- Enabled immutable GitHub Releases only after the ten-context source contract,
  live branch rule, exact-main evidence, and four active production/testing tag
  rulesets agreed. No release, tag, draft, or artifact was created.
- Completed scoped cleanup after the full local and hosted matrices. Generated
  build, package, OpenTofu, and Python caches and temporary worktrees created by
  this execution are removed after the final closeout merge; retained private
  synthetic GCP staging is intentionally preserved.

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
  credentials, user data, or artifact content. The trusted PR validator emits
  only a fixed check name, bounded success/failure summary, exact source SHA,
  and authenticated Actions details link. Android managed-device preparation,
  test, reset, retry, and full-suite deadlines retain only a safe static label,
  one bounded lifecycle status, and an exit code; commands, arguments, paths
  outside the fixed artifact location, credentials, health values, and
  arbitrary exception text are not recorded.
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
| Android API 35 managed device | The local exact CI sequence passes: the fresh-process Review Sample journey passes 1/1, then the complete suite reports 54 scheduled tests plus UTP accounting, 2 intentional private-pilot skips, and 0 failures. Focused report and disabled-switch regression tests also pass together. Earlier hosted stalls proved bounded timeout retention and drove preparation/reset/retry hardening. Final pull-request run `34191194480` then passed the 13m40s production-shell lane, 22m12s full build/unit/lint/instrumentation lane, and stable required result on exact head `59093db4`. | Current local production-shell behavior, hosted Android source and emulator execution, and a fail-closed retained diagnostic boundary | A physical phone, radio, battery, or attestation |
| Android Release build | Final `assembleFullRelease` completed 54 tasks successfully in 1m 14s, including lint-vital and signing validation, using a one-use locally generated certificate removed immediately after the build | Final shipping source compiles, dexes, packages, and passes Release-vital checks | Production upload key, Play App Signing, signed RC identity, or store acceptance |
| Server Python 3.12 | Ruff and runtime/dev dependency audits green; 296 passed and 63 environment-gated skips | Source behavior and dependency policy in the isolated local environment | Container, PostgreSQL, public topology, or production operations |
| GCP private staging plan | OpenTofu format, validate, three tests, and live plan green with zero drift | Retained IAM-only synthetic staging matches source | Public or production deployment |
| GCP private runtime verifier | Passed internal ingress, no broad invoker, digest pin, scale bounds, PITR, and deletion-protection checks | Current private synthetic runtime keeps its intended infrastructure controls | Application correctness, public topology, or real-data operation |
| Long-history synthetic matrix | All 10/30/90/365-day scenarios passed integrity and exact restore; report in `validation/HISTORY-HARNESS-2026-09-07.json` | Current host storage shape and exact retained-content recovery | Phone memory, thermal, battery, background, BLE, or population accuracy |
| Staged repository policy matrix | The complete Tools suite passes 222/222; the exact hosted release-control selection and bounded-command/retry-classifier tests pass; release controls pass the activated five-conditional/five-universal, ten-context contract; terminology covers 17,370 classified occurrences in 1,508 path/category groups with zero forbidden mappings; calibration parity covers 12 metrics, 3 revisions, 13 thresholds, and 16 guards; health-claims, i18n, legal inventory, private-data, operations records, workflow syntax, Bash syntax, and ShellCheck pass | The exact staged source satisfies repository release, calibration-drift, privacy, claims, localization, legal, workflow-syntax, and operations contracts | Store approval |
| Deterministic source-release evidence | Version parity resolves to 9.2.1 on Apple and Android; the fresh source SBOM contains 216 components and its two-artifact release manifest verifies against the exact candidate source SHA | Release evidence generation and verification are reproducible before hosted publication | Signed artifact identity, immutable publication, or store acceptance |
| Required merge, tag, and repair contract | Five conditional and five universal workflow contracts plus ten stable contexts pass structural tests. Pull request `#8` passed all preceding protected checks and exact-head custom trust, then merged normally. Exact merged-main commit `d8cee4f6` passes `10/10`; custom check `101959809854` is bound to protected-main run `34194674313`, exact SHA, attempt `1`, and Actions app `15368`. Live strict branch protection contains the same ten contexts; four tag rulesets are active and immutable releases are enabled. Release source mutation is rejected, both build counters must advance, Actions can only produce an exact checked draft, and the owner dispatcher authenticates exact run and repository policy. AltStore remains disabled; Forgejo/Homebrew paths retain their fail-closed rollback and scoped credential contracts. | Applicable platform/license failures cannot be hidden by path filters or a same-named check, and production or repair publication cannot proceed from an unchecked, stale-build, off-main, backward-version, nonexclusive-writer, policy-unverified, mutable-release, or history-dropping source | A completed production release, public Homebrew/Forgejo tap, provisioned mirror credentials, or completed environment-secret migration |
| Scoped local cleanup | Earlier isolated environments, synthetic databases, relays, proxies, virtual-device runtimes, and generated products were removed or stopped. Final closeout removes the bounded caches and temporary worktrees recreated for verification while preserving the explicitly retained private GCP staging resources. | Cleanup is scoped and does not target unrelated user files or intentionally retained private staging | Destruction of intentionally retained billable staging |

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
- Commits: implementation head `59093db4`; protected merge `c3c377ab`;
  canonical-check repair `ffae30d5`; trusted-context activation `d8cee4f6`.
- Branch and remote state: pull requests `#6`, `#7`, and `#8` all passed their
  applicable protected contexts and merged normally to `main` without bypass.
  Pull request `#6` final Android run `34191194480` passed production-shell,
  full build/test, and the stable required result; final Apple run
  `34191194505` passed the complete simulator and universal macOS graphs.
  Merged-main run `34194674313` produced the exact protected-main trusted
  result, and the repository verifier passed all ten exact-SHA checks on
  `d8cee4f6`.
- Repository visibility verified: inherited from current release evidence.
- Version/build impact: none at round start.
- Release or distribution impact: release and repair workflows changed. The
  repository rejects unauthorized production/testing tag creation and
  update/deletion, requires ten exact app-bound contexts, and has immutable
  releases enabled. Both owner publication commands fail closed unless source,
  live strict branch protection, the Actions application, tag rulesets, and
  immutable-release setting agree. No production release, AltStore source,
  Homebrew tap, Git tag, draft, or app artifact was created or mutated.

## Decisions

- Durable decision added or changed: production release tags and published
  assets are immutable; a correction requires a new reviewed version. Actions
  builds exact drafts, while an owner-authenticated command verifies live
  policy and performs publication.
- Decision-log entry: this round record.

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
- Immutable GitHub Releases and the tenth `trusted-release-controls` context
  are now active after exact protected-main evidence and live strict branch
  protection matched the reviewed source contract. This closes repository
  policy activation, not signing, store, or launch readiness.
- The live testing-build and community-release workflows are intentionally
  disabled. Their four Android staging-signing values remain repository-scoped
  because GitHub does not expose existing secret values for safe migration.
  The key owner must re-enter them in the protected `staging` environment,
  verify the repository-scoped copies are removed, and only then re-enable the
  workflows.
- Repository collaborator `nobelchowdary` currently has write access. The
  publisher now rejects publication while any non-owner writer exists, which
  closes the draft-mutation race fail-closed. GitHub accepted but did not apply
  an attempted read-only downgrade because private personal-account
  repositories grant collaborators write access only. Publication therefore
  requires an owner decision to remove that collaborator or move the
  repository/release authority to an organization with granular roles.
- The measured retained 365-day database is about 444 MB and exact
  backup/restore temporarily reaches about 1.33 GB. Indexed host reads are fast,
  but only representative phones can establish launch, scroll, memory,
  thermal, background-collection, and low-storage budgets.
- The final Android preparation/reset/retry remediation passed on hosted exact
  pull-request head `59093db4`; physical OEM, radio, battery, and background
  behavior remain open.

## Next round

1. Continue from the first remaining external or signed-release dependency
   after this execution round closes.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
