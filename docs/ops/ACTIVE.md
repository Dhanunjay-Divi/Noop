# Active NOOP handoff

Last updated: **2026-10-04**

## Authoritative context

- The current PR `#33` replacement candidate is on
  `codex/mobile-cloud-release-finalization-20261003`, based exactly on GitHub
  protected merge `1cd401f69dd8b4df75872a830ed33a84918ea344`.
  Product commit `fc2343ff5f96304ccca95fc802d3b6252b467d5b`
  removes Android's invisible measured-height Today gaps, gives both phones a
  calmer scroll-reactive floating navigation disclosure that snaps and
  persists at either bottom corner, preserves all five named tabs and complete
  metric history, replaces the quick-action `Done` capsule with an accessible
  close icon, and starts customer setup in one unified compatible-band scan.
  Android Demo/Full unit and build matrices plus Android-test source
  compilation pass; the final navigation recheck passes 15/15. Apple affected
  contracts pass 107/107, StrandDesign passes 59/59, iPhone navigation passes
  2/2, complete metric history passes 1/1, and the configured, fresh-install,
  unified-scan, and quick-action flows pass after correcting one covered-parent
  accessibility query. The exact iPhone Simulator executable digest is
  `ee765debf4ab5463e2f794dcd9c3552e3c4332d9f5525ff00f1e051cf35c8e63`;
  the Demo and Full APK digests are
  `455a523fb67de460c22e6da8e0c439b17c4d3de3fea1a6837edb3ddc5c30c415`
  and
  `ec3bbc03161e40d0bab33136c8655eb8c0b1320497ead10d93b93e2e246861b0`.
  The exact protected release-control subset passes 258/258, source controls
  pass 9/9, required-CI policy verifies all 10 contexts, and trusted controls,
  calibration, terminology, legal, privacy, claims, shell, operations, and
  diff gates pass. The reviewed terminology snapshot records 18,638
  occurrences across 1,651 groups, no forbidden active use, active-allowlist
  digest
  `b281b0c5d44913bac8540ccc1c64af55d9262a19e97143a56fdc8ddfc142e147`,
  and inventory digest
  `ac2ab789f822bac3ea45d2b371bb36872dadf1e997167c5ea67d9c51a1ccfb06`.
  Initial hosted localization run `37230079611` rejected 13 newly authored
  labels. They now use the Apple and Android resource systems; the exact CI
  audit passes, all four Android production/test source sets compile, and the
  iPhone Simulator build succeeds. Replacement Android run `37231077501`
  exposed one missing complete-locale resource and two stale source contracts;
  the three exact failures and both complete Full/Demo unit suites pass after
  correction. Hosted release-control run `37231919823` then exposed a
  temporary Git-fixture cleanup race after its source controls passed. Fixture
  Git commands now disable automatic garbage collection and maintenance; the
  formerly failing release-evidence test passes 100 consecutive runs.
  Final hosted Android run `37232335010` then executed 126 production-shell
  instrumentation tests and exposed two stale onboarding assertions that still
  waited for the removed static Band 5.0 / MG and Band 4.0 rows. The product
  correctly opened the unified live scan. The tests now require the localized
  device-picker title and searching state while rejecting those static rows;
  both Android-test source sets compile, the focused onboarding and pairing
  contracts pass, and the exact API 35 cases pass 2/2.
  Exact-head Apple run `37233895083` on
  `2d1b35249f8c7e4621877a09a726ca2ea844312a` then built both products and
  exposed only stale shell tests: the macOS contracts still parsed an obsolete
  one-line frame boundary and expected superseded compact-navigation action
  labels, while one iOS UI case still required ordinary text to end above the
  floating bar. The corrected contracts now follow the structured
  `onReselect` closure, require the current `Move to left edge` and
  `Move to right edge` accessibility actions, verify a full-height ordinary
  viewport, and separately preserve the accessibility-text reservation. The
  complete local Strand suite passes 2,446 tests with one intentional skip and
  zero failures, and both corrected iPhone viewport cases pass 2/2. Product
  source is unchanged by this correction.
  Private staging remains unchanged at source merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c` and immutable digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`;
  no cloud build, migration, deploy, or apply is required. Protected hosted
  integration and every signed or physical-device gate remain pending.

- The current follow-up candidate is on
  `codex/mobile-cloud-release-finalization-20261003`, based on protected merge
  `1cd401f69dd8b4df75872a830ed33a84918ea344`. Exact-main Apple workflow
  `37108981075` isolated one intermittent Recovery date-scrub failure after the
  other nine required contexts passed. Production implementation
  `0d76116178a90f2a93cf7f61b9df579078672868` maps touch through the live chart
  scale, preserves scroll/tap and macOS hover, and adds adjustable date
  stepping. PR `#33` hosted run `37120314609` later failed on Xcode 26.6 because
  only a chart sliver was hittable while the synthesized gesture coordinates
  remained under persistent bottom navigation; the app-report review state was
  also slower than its prior wait. Test-only repair
  `9689bd3b88268eebfc7b174336281de6f9c74476` measures and clears the full
  gesture corridor and waits for explicit report readiness without changing
  production interaction. A valid PR review then identified that the redundant
  400-millisecond post-scrub deadline could discard the first deliberate tap.
  Local implementation
  `72f079a9ad6cda697dbcb6978a954826c89cadf9` removes that deadline, proves the
  immediate tap and one-back path 10/10, and also fixes an onboarding
  measurement clear action that reproduced keyboard-focus loss in 9/10 runs.
  The repaired clear-and-retype workflow passes 10/10. The three original
  hosted failures pass together 3/3, both geometry cases pass 20/20 under
  repetition, StrandDesign passes 59/59, and the final complete iPhone
  Simulator graph executes 43 tests with one intentional skip and zero
  failures. The complete Tools discovery passes 374 tests with one intentional
  skip; the exact protected release-control subset passes 258/258; local trust,
  calibration, terminology, localization, claims, privacy, legal, operations,
  release-shell, and diff gates pass on the final local candidate. The
  regenerated terminology inventory records 18,626 classified occurrences
  across 1,650 groups and is reviewed at digest
  `32da17b04296d5319729f15830af076a57d39e97db41216cb1f31226cd6a6427`.
  Private staging remains unchanged and reverified at source merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c` and immutable digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`;
  no cloud rebuild, migration, or apply is required. Protected follow-up
  integration remains pending. Every signed or physical-device validation gate
  also remains pending; simulator evidence remains explicitly
  nonphysical.

- One local release-candidate branch now combines the mobile tab/OTP and
  exact-date scrub correction, supplier optional-read request fencing, and the
  production physical-validation handoff. Implementation/evidence base
  `e5f11cfe1602ec02e8b08bc4a766f7b07689e752` passes focused Apple supplier
  88/88, the complete iPhone Simulator graph, clean first-run 2/2, the Recovery
  exact-date case 1/1 on the dedicated review simulator, StrandDesign 58/58,
  Android navigation/OTP 12/12 with production and Android-test compilation,
  Android API 35 first-run 3/3, supplier/quarantine Python 62/62, and
  repository controls. The exact consolidated UI paths are unchanged from the
  paired `1206x2622` iPhone and `1080x2424` Android visual-review revision,
  which had no observed clipping or overlap. The retained PR27 simulator did
  not preserve the selected trend value while the dedicated review simulator
  did; protected exact-head execution remains authoritative. Source and
  contract audits also confirm that historical screenshots containing the
  local-first welcome, local-test account bypass, self-hosted Friends setup, or
  the old plus/grid command control are not current customer runtime; the
  consolidated candidate uses required account onboarding, managed Friends,
  and the movable NOOP N.
  No push, merge, workflow dispatch, deployment mutation, signed install, or
  physical claim occurred. Private staging remains at protected merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c` and immutable digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`.
  WHOOP physical comparison may proceed only after protected integration and
  signing. Supplier physical validation remains blocked because available
  local archives do not match approved trust evidence.

- The matched mobile tab/OTP motion refinement has one local hosted-failure
  correction on branch
  `codex/mobile-liquid-tab-otp-motion-20261002`. iPhone and Android use one
  raised selected lens across the same five labeled tabs while preserving
  reselect behavior, touch targets, accessibility roles, Reduced Motion, and
  the separate movable NOOP N. Managed verification preserves the four-through-
  eight digit service contract, localized decimal normalization, platform OTP
  autofill, immediate secret clearing, masked editable-field accessibility,
  and a three-second server-confirmed success state that never stores or
  redraws the code. The final token pass covers lens body, rim, highlight,
  spacing, label padding, and palette ownership on both platforms. iPhone now
  reserves the measured dock footprint at every text size, matching Android's
  non-overlapping content boundary. Exact-current evidence passes Android
  focused 12/12, production and instrumentation-source compile,
  onboarding/Trends/package wall, Full APK
  SHA-256 `3a134fc284b029c82afb2e9859191f0cdbd01d055d145a5761b12808ec6ada05`,
  Apple focused 86/86, direct dock-boundary UI 1/1, the complete iPhone graph,
  clean first-run 2/2, all-platform i18n, and reviewed `1080x2424` /
  `1206x2622` captures. Private native-pilot assertions compile but were not
  executed without their private inputs. PR `#32` replacement run
  `37033095763` passed every Android, macOS, package, policy, and repository-
  control boundary but failed one iOS shell case after 41 passes and one
  intentional skip: touch scrub selected the exact Recovery date, then a
  synthetic iOS hover-end lifecycle cleared the shared chart state after finger
  release. Local commit `3d8256978` preserves the documented touch-pinned
  selection while leaving macOS hover behavior unchanged. The exact-date UI
  case passes 1/1 in `23.557` seconds and `StrandDesign` passes 58/58. XCTest
  completed before an abnormal local Xcode teardown, so full replacement
  hosted execution remains the integration authority. The remote PR head
  remains `1d2543ba1`; the local correction has not been pushed under the
  current no-push/no-Actions handoff. One authorized replacement push,
  exact-head protected checks, normal merge, and exact-main verification
  remain.
  Real OTP, signed-device accessibility, and every physical band/source gate
  remain pending.

- Supplier optional step/sleep read serialization is completed locally on
  branch `codex/supplier-read-serialization-20261002` from protected-main
  baseline `a8a617593b4b81485fca672353ebcebe2d073f55`. A due sleep read now
  queues behind the active step result or failure, step polling pauses while
  sleep is pending or in flight, and every command carries an app-owned request
  ID through the wrapper callback. Late or duplicate callbacks cannot satisfy a
  newer request, bounded step/sleep timeouts release the lane and reset the
  transport, and disconnect/stop clear every optional-read state. Existing
  supplier qualification, persistence, fixed-category diagnostics, existing
  comparison-transport behavior, formulas, source routing, and SDK artifact
  boundaries are unchanged. Focused Apple supplier tests pass 75/75 and the
  complete iPhone Simulator graph builds. No raw logging, push, merge,
  deployment, or physical BLE/accuracy/background/battery/retention claim is
  part of this round. The consolidated production handoff now links the exact
  install/evidence commands, candidate signature checks, WHOOP-first gate,
  account/cloud and metric protocols, and privacy-safe hand-back contract. The
  currently available local supplier archives do not match protected-main or
  transferred October 1 trust evidence, so supplier physical testing remains
  blocked until an authoritative approved artifact bundle is restored and
  reverified; WHOOP comparison testing can proceed independently.

- The mobile command-lens regression repair is integrated on protected `main`
  through PR `#30` at squash merge
  `a8a617593b4b81485fca672353ebcebe2d073f55`. It restores one matched
  rounded-stroke N on iPhone and Android while preserving the `48x52` target,
  bounded drag, edge snap, persistence, nine-action launcher, and accessibility
  movement actions. Android focused compile/unit and APK assembly, Apple shell
  1/1, the complete iPhone Simulator graph, paired visual review, terminology,
  localization, operations, claims, legal, private-data, and required-CI
  controls passed before protected integration. The Android follow-up also
  confirmed Steps in the default six and all 18 choices grouped as
  measured/imported, source-dependent, and NOOP insights. Signed physical
  device/source behavior remains unvalidated and unclaimed.

- A replacement private synthetic GCP staging deployment is live and its source
  is integrated through PR `#31` at protected merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c`. The dedicated
  billing-enabled project has protected remote state, budget alerts, Firebase
  iOS/Android registration, App Check registration, synthetic phone OTP, one
  retained fictional pilot claim, and email/password account identity. One
  immutable image digest scanned with zero findings; Cloud SQL, migrations,
  workload-specific credentials, IAM-only APIs, processors, lifecycle jobs,
  App Check enforcement, and the scheduler are deployed. A three-account
  fictional OTP/runtime smoke covered upload, processing, tenant isolation,
  restore, erasure, social, and Safety fail-closed behavior; disposable
  fictional push destinations and App Check debug tokens were removed, the
  scheduled lifecycle completed, the private-runtime verifier passes, and
  OpenTofu reports no drift. Public invocation, real health data, payment
  entitlement, real OTP/push, and physical-band claims remain disabled or
  unvalidated.

- The direct-and-derived Today metric expansion is integrated on protected
  `main` through PR `#27` at squash merge
  `5a287b50423b921d408833392b6dfdeadf14a8ae`. Apple and Android now
  expose the same 18 Today-ready choices, retain Steps in the fresh-install
  six, and group the editor into measured/imported, source-dependent, and NOOP
  insight values. Average HR, maximum HR, asleep time, and measured VO2 max are
  directly selectable; measured VO2 max never falls back to `vo2max_est`.
  `Open all metric history` is source-qualified on both platforms: Apple Health,
  Health Connect, compatible-band, and NOOP series with the same key remain
  separate. Every persisted Apple Health history key has a catalog entry.
  Primary Steps accepts Apple Health/Health Connect or a registry-qualified
  supplier-native total, but excludes motion estimates; WHOOP Steps is
  deliberately unavailable because neither the current BLE nor export path
  supplies a validated value. Generic aggregated records remain labelled
  `Apple Health`, not `Apple Watch`, because source-device identity is not
  retained. Android measured Weight is bounded to the selected day and never
  borrows profile setup weight. Exact hosted head `fd8f10ac6` passed Swift
  packages, macOS, server, release controls, production shell, and review
  sample; its failures isolated one stale Android performance assertion,
  localized Android/Apple presentation contracts, and stale Apple onboarding
  and chart UI observations. The replacement repair passes bounded Full Kotlin
  compilation plus the focused Android performance/localization tests,
  complete local i18n audit, and the paired configured-onboarding and
  exact-date chart-scrub iPhone UI cases. Pushed head `5b011341e` then isolated
  one stale terminology inventory as its first completed failure. Final PR
  head `f57d2de9373d0656a36052674e50a55007ea1c5e` passed all ten required
  contexts after the regenerated zero-forbidden-mapping inventory and both
  reviewed-source pins passed the complete 258-test release-control wall.
  Protected merge `5a287b50423b921d408833392b6dfdeadf14a8ae`
  completed 38 exact-main checks with 33 successes, five intentional skips,
  zero failures, and strict required-CI verification passed 10/10. A current
  Android API 35 follow-up reviewed Today plus the upper/lower metric editor at
  `1080x2424`, confirming all 18 choices and the three source groups without
  observed clipping or overlap. Physical
  Apple Watch, WHOOP, supplier-band, HealthKit, Health Connect, background,
  battery, and accuracy behavior remains unvalidated and unclaimed.

- The hydration target/correction implementation is integrated through the
  same PR `#27` and exact-main verification. Apple and Android now explain the existing
  confirmed-profile/weight plus bounded-Effort target, keep body composition
  and wrist temperature outside that estimate, place editable NOOP entries
  immediately after quick logging, and require confirmation before an atomic
  clear of only NOOP-owned entries. Apple and Android focused hydration tests,
  Full Kotlin/resources, Apple app graphs, nine-locale generation, all 114
  operations records, and diff hygiene pass. Hydration-specific phone visual
  review, real-provider behavior, notification delivery, and physical-band
  behavior remain pending and unclaimed.

- Daily Signal compact statuses are integrated through the same PR `#27` and
  exact-main verification. Recovery retains its
  existing `Low / Steady / Strong` and calibration semantics; Sleep now uses
  `Need more rest / Steady / Well rested`; Effort now uses
  `Light / Moderate / High`. Apple focused tests pass 50/50, Android Full
  resources/Kotlin/unit tests build successfully, and the complete iPhone
  Simulator graph builds. A current 1206x2622 iPhone capture with values
  `43 / 85 / 45` was reviewed showing `Steady / Well rested / Moderate`
  without observed clipping or overlap. A current 1080x2424 Android API 35
  follow-up also shows the matched compact hierarchy without observed clipping
  or overlap. No formula, source, storage, account, network, BLE, or
  physical-device behavior changed or was claimed.

- The Today metric-catalog and Fitness Age refinement is integrated through
  the same PR `#27` and exact-main verification. Apple and Android now
  expose the same 18 Today-ready metrics in a selected-first, searchable,
  grouped editor while keeping the dashboard bounded to three through six
  cards. Fitness Age is a compact today-only weekly lane under Daily Signal.
  Apple dual-architecture build and focused contracts pass; Android focused
  contracts and all 5,262 Full-flavor unit tests pass; visual review found no
  observed clipping or overlap. Hosted head `30524ac09` passed every non-Apple
  required context, including the complete Android wall. Apple run
  `36899526468` isolated only stale source/UI contracts for the renamed compact
  Fitness Age lane, the replaced Key Metric switches, and Recovery-chart
  interaction around the movable action lens. The macOS repair wall passes
  5/5; the repaired iOS Key Metric boundary and exact-date Recovery scrub cases
  pass independently on a dedicated iPhone 17 Pro simulator. Final head
  `f57d2de9373d0656a36052674e50a55007ea1c5e` passed all required
  contexts before the protected merge. No formula, source, storage, account,
  BLE, notification, or physical-device behavior changed or was claimed.

- Band-first required-account onboarding is integrated on protected `main`
  through PR `#25` at merge commit
  `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`. A reset customer
  installation now proceeds through Terms, Welcome, Bluetooth, supported-band
  setup, Create account or Sign in, required ownership confirmation, profile,
  plan, and app entry. Unconfigured account builds fail closed at Account and
  expose no local-test continuation. Apple onboarding and Bluetooth contracts
  pass 33/33; clean iPhone journeys pass 2/2 plus a final 1/1 neutral-copy
  rerun; Android API 35 first-run journeys pass 3/3; Android onboarding policy
  passes 17/17; and Full/Demo compilation passes without the removed
  local/exploration resource warning. Current 1206x2622 captures and OCR show
  the neutral `your compatible band` footer without observed clipping.
  A versioned completion marker returns legacy account-free installs to the
  required Account boundary, and the final combined walls pass 57/57 Apple and
  78/78 Android focused cases. Earlier hosted heads isolated stale localization,
  Android shell-fixture, and Apple source-contract expectations without
  weakening the required flow. Exact hosted head `06e064f42` passed every
  repository-policy, backend, Swift-package, Android, and macOS job. The final
  exact PR head `3fb09d6093789a8939f075d4b9e36d026e61b76f` then passed all
  ten required hosted contexts, including the repaired iOS production-shell
  onboarding case, before the normal protected merge. The onboarding repair
  changed no product, consent, account, or health behavior. Production
  identity credentials, signed installation, live provider recovery, and
  physical BLE remain pending.

- Actionable wellness notifications are integrated on protected `main`
  through PR `#25` at merge commit
  `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`. Hydration opens a
  user-confirmed water-log flow, qualified stress opens a visible one-minute
  paced-breathing session, and inactivity opens a dismissible two-minute
  movement break; notification delivery never silently logs behavior. Stress
  remains default-off, non-diagnostic, and requires the existing corroborated
  HRV, resting-HR, fresh low-motion, worn, session, quiet-hour, cooldown, and
  replay gates rather than heart rate alone. Hydration cannot schedule more
  often than hourly; inactivity defaults to a 45-minute threshold, 30-minute
  continuing-bout re-nudge, worn-only evidence, and active/quiet-hour gates.
  One- and two-minute actions use monotonic elapsed time across UI pauses.
  Exact local evidence passes the complete iOS Simulator graph, 57/57 Apple
  focused tests, 108/108 Apple reminder regressions, 78/78 Android focused
  tests, Full/Demo Android compilation, all supported-locale generation,
  claims/privacy/brand gates, 110 operations records, and diff hygiene.
  Earlier hosted heads isolated release-policy and onboarding verification
  drift rather than a reminder-runtime defect. Exact hosted head `06e064f42`
  passed health claims, i18n, operations, release controls, runtime licenses,
  trusted release controls, server, Swift packages, Android, and macOS. The
  only earlier iOS failure was the unrelated configured-provider onboarding
  test interacting nondeterministically with the fail-closed Terms switches.
  A final independent audit then found and fixed three Apple
  gaps: clean-install inactivity enable now requests notification permission,
  macOS hydration notifications open the confirmed water-log flow, and Apple
  plus Android movement copy no longer exposes inferred seated minutes. The
  combined Apple regression passes 11/11, the generic iOS Simulator build
  passes, Android focused notification/localization tests pass, and the full
  all-platform i18n audit has zero translated-key gaps. The final exact PR head
  `3fb09d6093789a8939f075d4b9e36d026e61b76f` passed all ten required
  hosted contexts before merge. Stress remains multi-signal and never
  heart-rate-only; no action silently logs behavior. Signed physical-device
  notification, background, haptic, battery, and sensor validation remain
  pending.

- The final mobile UI replacement is integrated through PR `#25` on protected
  `main` at `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`. Mobile Today is
  number-first, the compact iPhone `More`
  endpoint no longer has a decorative outer pill, selected metrics support six
  focused cards plus one explicit all-history route, and macOS Today no longer
  sits inside a nested `960`-point phone column. Wide Mac windows use the full
  detail pane with Daily Signal beside the plan disclosure and a three-column
  metric grid; narrow windows and accessibility text retain a full-width
  stacked fallback. Final replacement evidence passes 69/69 Android focused
  tests with Full/Demo Kotlin compilation, 134/134 affected Apple contracts,
  and the complete iPhone Simulator graph. Wide `3200x1880` and narrow
  `2000x1520` macOS captures were reviewed without observed clipping or overlap.
  Earlier complete Android walls, configured onboarding automation, paired
  phone review, StrandDesign, localization, claims, release-control, and
  repository-policy evidence remain applicable. Exact PR head
  `3fb09d6093789a8939f075d4b9e36d026e61b76f` passed all ten required
  hosted contexts before normal protected integration. Signed physical-phone
  accessibility/frame-pacing and all physical-band behavior remain external.
  No formula, source selection, storage, account-provider, network, BLE,
  store-release, or production-traffic behavior changed.

- The mobile liquid-navigation refinement is integrated in PR `#25`. The
  five-tab dock now
  remains structurally separate from a compact `28x38` visible, `48x52`
  interactive edge lens with bounded drag, nearest-edge snap, persisted side
  and height, and accessibility movement alternatives. Android Trends now uses
  connected-observation semantics instead of a decorative wand, More uses a
  familiar app grid, and both dock rims are quieter. Exact local evidence
  passes 58/58 StrandDesign tests, 19/19 Android focused contracts, Full/Demo
  Kotlin compilation, Demo APK assembly, 90/90 Apple shell/state contracts,
  and the complete iOS Simulator graph. Paired default, alternate-edge, and
  nine-action-center screenshots were reviewed at 1206x2622 and 1080x2424;
  Android drag persistence survived relaunch and its recent log sample had zero
  matching fatal/ANR signatures. No formula, health data, network, BLE,
  account, deployment, store-release, or production-traffic behavior changed.
  Signed physical-phone navigation, accessibility, and frame-pacing checks
  remain. Full all-platform
  localization, 107 operations records, and diff hygiene pass. After evidence
  became durable, the exact 5.7 GiB iOS DerivedData, 623 MiB Android app build
  output, and 170 MiB StrandDesign build output were removed; installed
  synthetic candidates remain available for review.

- The local mobile-navigation and sparkline redesign is branch
  `codex/mobile-navigation-sparkline-redesign-20260930` from protected-main
  commit `144e1bb904d4de1760a2d773e88d769bcf2f490d`. It aligns the iPhone and
  Android five-tab signal docks, replaces the full-slot selected pill with an
  icon-sized accent halo, and turns the ambiguous add control into a
  speech-bubble/ECG NOOP action center that opens the existing nine vetted
  actions under "How can NOOP help?". It also applies bounded monotone
  interpolation to shared sparkline primitives without changing samples,
  formulas, sources, or storage. Exact local evidence passes all 58
  StrandDesign tests, Android focused contracts and Demo APK assembly, 85/85
  Apple shell/state contracts, and the complete final iOS Simulator app graph.
  Paired synthetic Today and action-center screenshots were reviewed at
  1206x2622 and 1080x2424 for parity, clipping, readability, and overlap.
  Android's recent log buffer had no matching fatal/ANR and both app processes
  remained live. No commit, push, deployment, release, or physical-device
  claim has been made; owner review and protected integration remain pending.

- The current supplier-metrics replacement is branch
  `codex/supplier-metrics-main-verification-20260930`. PR `#22` reviewed exact
  head `a16bbfac92bfe80945ff7c2a71a05a0940e88232` and merged normally into
  protected `main` as `23a0d491b8b4f30e9a26e35da7373422ed232470`.
  It preserves the
  owner-validated connection/live-HR/native-step/sleep baseline `7ca94bf8`,
  excludes development-only commit `0b99aca0`, and retains current pairing,
  ownership, viewer, privacy, source-switching, and release safeguards.
  Supplier HR is bounded and receipt-timed; native steps and sleep persist
  atomically; optional reads do not tear down transport; and Apple primary Steps
  accepts the native total only when the exact active registry row is
  `.veepoo`, with Apple Health still winning per day and all WHOOP wrist-motion
  estimates excluded. Local evidence passes Apple supplier
  106/106 and source/provenance 101/101, complete StrandAnalytics 1,519 with
  seven documented skips, WhoopStore 558/558, Android focused Full Debug 22/22,
  supplier controls 65/65, and default-off macOS plus complete iOS Simulator
  graphs. Physical BLE, accuracy, battery, history, background, haptics,
  retention, signed installation, and firmware remain external. The owner
  initially requested no GitHub-hosted runner use. On 2026-09-30 the owner
  authorized the required hosted checks and normal protected merge for this
  integration. That
  authorization excludes manual release, signing, firmware, store, and
  production-traffic workflows. Pull request `#22` is the protected integration
  record. Exact hosted head `5719e9f3d` passed Android APK assembly, production shell, and
  Review Sample shell, but its 5,227-case unit wall failed one stale
  `AppWideLocalizationContractTest` expectation that still described the
  pre-integration non-persistence behavior. The corrected contract passes its
  focused case and the complete local Full Debug wall with 5,227 tests, seven
  skips, and zero failures. The same old head built both Apple app graphs, then
  its 2,405-case Strand wall exposed the mirrored stale expectation as the only
  failure; the corrected Apple localization and Bluetooth-consent contracts
  pass 10/10 locally. Replacement head `a16bbfac9` then passed all ten
  protected contexts, including Android run `36757182137`, Apple run
  `36757181954`, and Swift packages run `36757182321`. The squash merge body
  inherited historical `[skip ci]` text, so GitHub created no push runs for
  `23a0d491...`. A minimal documentation follow-up with a clean commit message
  is in progress to obtain exact protected-main verification without changing
  product runtime code. No release, signing, firmware, store, or
  production-traffic workflow was dispatched. The signed physical matrix
  remains.

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Protected branch: `main`
- Active source: protected `main`
- Integrated product commit:
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`
- Reviewed pull-request candidate:
  `91e20504eb824572becfe6dcc440b5a6d5ecc8f2`
- Pull request `#18` merged normally through protected branch policy on
  2026-09-29. Its reviewed candidate and integrated product commit have the
  identical tree `f45676caf1d4d70ef2c732d859e6bf12ea78e470`.
- The seven review threads are resolved from matching source and test evidence.
  Every exact-head pull-request check is green. The first protected-main run
  completed successfully, including the exact iOS production shell, and the
  strict verifier reports `10/10` exact-SHA checks passed for
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`.
- Four later automated review
  findings are corrected in the final local replacement without changing data
  authority or score formulas: macOS managed history now uses exact
  account-scoped databases and sources, stale work is generation-fenced across
  account changes/sign-out, history-only capability version 3 excludes active
  and deleted documents, stale document-inclusive checkpoints are replaced,
  continuation is bounded and cancellable, terminal Firebase authentication
  and terminal continuation failures remove cached account data, transient
  provider failures remain retryable, strict managed sleep history paginates
  beyond one 4,000-row page, and managed history remains distinct while
  participating in Stress selection. Managed raw charts now use one globally
  bounded ordered SQL union across restored sources; overlapping seconds are
  resolved before HR bucket aggregation and the newest restored source has
  precedence. Read-only Mac routes keep navigation while hiding mutation
  controls, including the Stress breathing/haptic entry and local Lab Book;
  account bootstrap no longer waits on an unrelated collector-store read; and
  supplier activation becomes durable only inside a valid pairing lease. The
  viewer starts no local scoring, recommendation, reminder, legacy-sync,
  upload, source-registration, or device-control workers. Exact current
  evidence passes: NoopRemoteSync 205/205; WhoopStore 556/556; the combined
  managed-viewer/supplier focused wall 50/50; the final managed-viewer
  follow-up 29/29; the supplier lease wall 24/24; complete macOS 2,394 with one
  intentional skip; and the exact unsigned iOS Simulator graph with app,
  Watch, complications, and widgets under the expected four bundle
  identifiers. Independent follow-up review confirms all four residual
  implementation findings are closed and identifies only the now-corrected
  stale evidence count. The earlier complete Apple, Android,
  server/PostgreSQL, analytics, production-shell, localization, accessibility,
  privacy, claims, calibration, legal, required-CI, trusted-release, and
  SDK-artifact walls remain applicable because this replacement does not alter
  their implementations. The final current policy wall passes 372 tests with
  one intentional skip plus 50 top-level tests; all-platform localization with
  the tracked Apple baseline at 130; 18,564 classified terminology occurrences
  across 1,635 groups with zero forbidden mappings; nine release checks; ten
  required contexts; trusted self-verification; 12-metric calibration parity;
  legal inventory for 230 runtime components and three container inputs;
  distribution provenance; private-data and 1,312-file health-claims gates;
  103 operations records; exact 10-file SDK artifact verification; and diff
  hygiene. Final post-cleanup terminology regeneration and release-trust
  repinning pass on the exact current tree. The 7.6 GiB round-owned
  `/private/tmp/noop-pr18-review2` tree was exact-deleted after its outcomes
  became durable; no process or open handle owned it, the path is absent, and
  Data-volume free space increased from about 15 GiB to 22 GiB. One
  replacement commit/push, exact-head hosted checks, review-thread closure,
  normal protected integration, and exact-main verification are complete. This
  documentation and release-evidence closeout finalizes the durable handoff
  without changing product runtime code. Physical BLE, background, battery, haptics,
  accessibility, physiological accuracy, supplier firmware/rights,
  signing/store, credentials, carrier/legal, and elapsed production operations
  remain external gates.
- The app-level encrypted working-set migration, existing-user cloud backfill,
  selective managed restore, conflict-replacement policy, Coach evidence
  ledger, and Automation execution ledger remain separately approved
  D-059/design work. They are not silently treated as implemented by this
  source-readiness closeout and do not authorize a cloud-authority flip.
- Older pending-PR statements below are retained as chronological evidence and
  are superseded by this authoritative block.
- Public checkpoints `c8a986a61` and `cf7e28e4b` now simplify the mobile
  Account/Data hierarchy and reframe the shared destination as Data & Sync.
  Local backup and restore remain primary; legacy D-036 self-hosted sync is
  unchanged behind a default-collapsed Advanced control. Apple contracts pass
  17/17, Android focused navigation plus Full/Demo compilation pass, the exact
  unsigned iPhone graph validates Watch, complications, and widgets, and a
  1206 x 2622 iPhone 17 Pro simulator capture shows no clipping or overlap in
  the tested dark appearance. These public branch pushes trigger no workflows
  because there is no pull request and automatic push workflows target
  protected `main`. The slice's isolated 7.0 GiB DerivedData, bounded logs,
  status files, screenshot, and simulator runtime were removed after evidence
  became durable; Data-volume free space was about 24 GiB afterward.
- The September 17 review is now reconciled in the active round instead of
  being treated as current source truth. Account deletion, recovery states,
  Trends loading, Recovery presentation, Dynamic Type navigation, sync
  visibility, provenance, and formula revision findings are implemented or
  covered; authority migration, application-level database encryption,
  production cloud operations, and physical validation remain gated. The next
  code checkpoint also clamps a caller-side future local-prune timestamp to the
  sync run's own time on Apple and Android. Swift coordinator tests pass 22/22
  and the focused Android Full test task passes. This does not provide a
  server-trusted clock or enable automatic pruning.
- The September 17 readiness closeout is active on a stacked public checkpoint
  branch. macOS fresh installs now enter the viewer/account shell rather than a
  collector-only BLE dead end. Watch snapshots carry an exact optional HR
  observation timestamp, enforce a two-minute live window, preserve legacy
  decoding, scrub locked values, and share one transport-independent
  publication policy between macOS tests and iPhone. Apple and Android account
  recovery now use 60-second monotonic resend cooldowns with specific offline,
  invalid-code, expired-session, rate-limit, and local-cooldown states plus
  payload-free diagnostics and complete supported-locale copy. Focused Apple
  verification passes 12/12; Android Full/Demo compile and focused recovery
  passes 7/7; the complete unsigned iPhone Simulator graph embeds Watch,
  complications, and widgets; and all-platform localization passes. The first
  checkpoint `6b36f035e` is public. The account-recovery/Watch-policy
  checkpoint `7b3250b9e` is also public; both triggered zero workflows.
  Remaining Claude/release-record reconciliation, complete walls, exact-head
  hosted review, protected integration/main verification, and
  physical/provider gates remain pending.
- The stale release-blocker handoff no longer describes PR `#16` as pending.
  It records protected `main` at the PR `#16` merge, hosted-green PR `#17` at
  exact head `169230a9a`, the outstanding non-author review, and the separate
  unintegrated September 17 checkpoint branch.
- The newest September 26 step-source correction supersedes older statements
  below that describe a classification-gated band counter as valid primary
  Steps. Historical byte 63 has conflicting wear/contact and activity
  interpretations, so Apple and Android production paths now reject every
  positive delta from the reverse-engineered byte-57 counter regardless of the
  adjacent legacy value. Primary Steps therefore requires an imported OS
  pedometer or a future validated supplier-native stream; heart rate remains
  wear/effort context rather than gait proof. Observed counter days clear only
  NOOP-computed `steps` and `steps_est` under validated `-noop` namespaces,
  including when an imported source owns the usable HR day, while Apple Health
  and Health Connect rows are preserved. Transactional guards reject imported
  cleanup targets before mutation. Local evidence passes protocol 406 with one
  opt-in skip, analytics 1,513 with seven documented skips, storage 555,
  Apple app/data 75/75, primary-Steps presentation 25/25, the complete iPhone
  Simulator graph with Watch, complications, and widgets, Android focused
  primary-Steps 75/75, Android Full 5,213 with seven skips, Full/Demo
  compilation, Android instrumentation-source compilation, zero-error lint,
  and Full APK assembly. The current iPhone Simulator graph embeds Watch,
  complications, and widgets. The complete current-tree Tools wall passes 372
  tests with one intentional skip. Standalone controls
  pass the 1,312-file claims scan, full localization, private-data, 12-metric
  calibration, nine release checks, ten required contexts, trusted self,
  exact ten-file SDK artifact, legal inventory/distribution, 18,508 classified
  terminology occurrences across 1,629 groups with zero forbidden mappings,
  and all 101 operations records. Exact implementation checkpoint
  `6c7d3fa2b1e7f744774a89a942465ff1aa137216` is pushed. Its complete unsigned
  macOS wall passes 2,358 tests with one intentional skip, and all ten required
  hosted contexts pass, including Apple run `36264295238`, Android run
  `36264295298`, and package run `36264295274`. Pull request `#17` is open and
  mergeable but blocked pending the requested non-author review. Protected
  integration/main verification and synchronized physical validation remain
  pending.
- September 26 exact-day step parity is locally green on the current dirty
  replacement. Apple Calendar and Workout detail now prefer the exact-day
  Apple Health pedometer aggregate over the classified band counter. Android
  Health Connect projects owned steps into its daily row, and Calendar,
  Workout detail, Today, and Fusion share imported-first arbitration without
  admitting gravity-only motion or heart rate as gait proof. Apple tests pass
  8/8; Swift counter/Fusion tests pass 42/42; Android focused tests pass 58/58,
  and its complete Full Debug wall passes 5,196 tests with seven intentional
  skips plus compile, lint, and APK assembly. The unsigned macOS test graph and
  iPhone Simulator graph pass, with Watch, complications, and widgets embedded.
  The reviewed terminology inventory contains 18,537 classified occurrences
  across 1,628 groups. All 370 Tools tests, all ten required contexts, nine
  release checks, trusted protected-main self-verification, exact SDK artifact
  verification, legal distribution, 12-metric calibration parity, 99
  operations records, private-data, the 1,311-file claims scan, terminology,
  and full localization pass. The consolidated replacement containing this
  record still requires exact-head hosted checks, non-author approval,
  protected integration/main verification, and synchronized physical
  manual-count validation.
- The current September 26 replacement starts from remote PR `#17` head
  `d775d7c36bed7795f67ff447f0a8d645625be5ba` and is locally verified but not
  yet pushed. Primary Steps on Apple and Android now accepts only imported
  pedometer data or classification-gated band counter totals; calibrated
  gravity motion remains a separate `Steps estimate` and cannot reappear after
  tapping a blank Steps card. Mirrored Swift/Kotlin regressions reject a
  variable head-washing/hand-gesture sequence that advances the raw counter by
  exactly 4,000 while still. Heart rate remains wear/effort context rather than
  gait proof. The iOS app-report review now resets to the visible phase anchor.
  Local evidence passes iOS report UI 3/3, Apple metric tests 22/22, Swift step
  suites 76/76, Android focused step/Today/detail tests 104/104, and the final
  iOS Simulator app build. Repository controls also pass: 82 focused control
  tests, all ten required contexts, nine release checks, trusted self and exact
  SDK artifact verification, 98 operations records, the 18,532-occurrence
  terminology ratchet with zero forbidden mappings and unchanged customer
  count, localization parity, and the 1,310-file health-claims scan. One
  consolidated push, replacement exact-head hosted checks, non-author review,
  protected integration/main verification, and synchronized physical
  validation remain.
- Final September 26 product-code head
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19` is pushed to PR `#17` and passes
  all ten required protected contexts. Exact stale all-still cleanup is
  source/day scoped, another computed namespace with the same valid step value
  is preserved, and broad estimate deletion still requires authoritative
  walk/run evidence. Heart rate remains wear/effort context rather than gait
  proof. The supplier-wrapper quarantine lexes outside nested comments and
  string literals, including Swift raw strings, so comment-separated vendor
  references cannot bypass the release control. Focused evidence passes:
  wrapper 7/7, WhoopStore MetricsCache 48/48, Android integrity plus Full Kotlin
  compilation, and Apple ReadSpine 58/58. The complete Tools wall passes
  370/370 with one intentional skip; all 97 operations records, the terminology
  ratchet, and diff hygiene pass. Hosted Apple run `36233287879`, Android run
  `36233287858`, package run `36233287831`, and the remaining protected
  workflows are green. PR `#17` is mergeable and auto-merge is armed, but
  required non-author approval remains outstanding. Exact round-owned logs,
  Android generated output, and the regenerated 6.0-GiB Strand DerivedData were
  removed after hosted evidence became durable; Data-volume free space is about
  32 GiB. Protected integration/main verification and physical step accuracy
  remain open.
- PR `#17` implementation head
  `9474ffbb6021f186d7a381e53c6b9e20ce0f9a16` is now hosted-green across all
  ten protected contexts. Its first iOS production-shell attempt failed only
  the profile height re-entry assertion after retaining the first batched
  keystroke. The exact UI case passed six consecutive local executions,
  including five app-relaunched repetitions, and failed-jobs-only retry run
  `36207653817` passed the complete unmodified iOS shell and
  `apple-ci-required`. No unresolved PR review thread remains. Final
  documentation/terminology closeout, one protected merge, protected-main
  verification, and exact round-owned cleanup remain; signed devices, physical
  BLE/background behavior, supplier firmware classification, and metric
  accuracy remain explicit external gates.
- September 26 final-review remediation is local and green. Remote PR `#17`
  head `65e4b0ab5f5ae7695ad2199b90fd50cacc1e5ba1` passed 34 hosted jobs with four
  intentional skips, including all ten protected contexts. Final review found
  one Apple lifecycle gap: a pending supplier credential cleanup ledger could
  be unreadable before first unlock and never be retried. The local replacement
  retains one bounded cleanup owner, retries once on protected-data availability
  plus at 1s/5s/15s, stops after success, and cannot re-arm an unbounded unlock
  loop. Apple supplier lifecycle passes 51/51, and the exact-current unsigned
  Release iPhone app builds with Watch, Watch complications, and widgets
  embedded. One consolidated commit/push, replacement exact-SHA checks,
  evidence-backed resolution of the final thread, normal protected merge,
  protected-main verification, and exact temporary-output cleanup remain.
- The September 26 step-integrity refinement is also local and green. Current
  motion-derived steps require per-record walk/run classification; still,
  unknown, classless, reset/gap, and singleton evidence cannot publish steps or
  re-enter through gravity fallback. Exact stale raw-motion cleanup now also
  requires continuous civil-day coverage with no edge or internal gap above
  15 minutes, so a short head-bath or hand-motion burst cannot erase unrelated
  history. Swift counter tests pass 20/20, mirrored Android analytics plus
  transactional integrity compile and pass, and Apple engine orchestration
  passes 2/2. The exact complete shared walls pass 1,507 analytics tests with
  seven intentional skips and 551 storage tests with zero failures. Physical
  firmware classification and synchronized manual-count accuracy remain
  external gates.
- Exact PR `#17` head
  `47e99f529350d5682fa0600e063d85b69eeeac87` passes every hosted required
  context. Nine later review findings are corrected locally across two review
  passes. Apple authentication rejection now writes a distinct durable cleanup
  intent before credential deletion, can reopen its retained bounded retry
  owner after startup, and archives the supplier registration as a process-
  durable fail-closed fallback when both marker stores are unavailable. A new
  process clears credentials for archived supplier rows. Android constructs
  Oura only after old-source teardown and clears a failed restored WHOOP
  identity so a later selection can retry. Release controls protect every
  importable Python surface under the Tools execution roots, including
  third-party dependency shadows and package initializers. The supplier wrapper
  boundary recognizes attributed, access-qualified, scoped, and semicolon-
  separated Swift imports. Focused Apple lifecycle/registry verification passes
  79/79, the Android coordinator class builds and passes, and 15 focused
  trust/wrapper/app-slice cases pass. The exact-current macOS wall passes 2,349
  tests with one intentional skip; Android Full unit tests, APK assembly, lint,
  and instrumentation-source compilation pass in one 73-task wall and produce
  a 54,402,643-byte APK; the iPhone Simulator graph succeeds without the new
  isolation warning and embeds widgets, Watch, and Watch complications under
  their expected bundle identifiers. Final terminology regeneration,
  repository-control rerun, one replacement commit/push, replacement exact-SHA
  checks, review resolution, normal protected integration, protected-main
  verification, and exact round-owned cleanup remain. Physical BLE, supplier
  firmware classification, and synchronized step accuracy remain explicit
  device gates.
- Current integration state: PR `#17` includes the supplier qualification
  candidate whose first hosted run used exact head
  `25b239a9cca9b5f5da15bc882d51fc344fe122b0`. The same Full/iPhone app
  build keeps WHOOP and the verified local supplier adapter available
  together. Apple terminal live state, supplier-only Live presentation,
  usable-registration onboarding, Android live fallback/freshness, WHOOP
  5/MG reachability, operation failure parity, and iOS artifact trust findings
  are corrected. Supplier binaries remain ignored and absent from Git. The
  generic iPhoneOS app and Android Full APK build successfully; focused Apple,
  Android, Swift SDK, and local trust tests pass. Earlier protected-review
  conversations through that qualification checkpoint were resolved. The final
  qualification slice adds one shared exact product-compatibility manifest and
  rejects
  malformed or unapproved model, hardware, firmware, protocol, and wrapper
  tuples before battery or live data. Because the supplied hardware tuple is
  not yet physically known, only verified local Debug builds permit unlisted
  qualification; Release/install paths stay blocked and fail closed. Focused
  Apple tests pass 34/34, focused Android supplier tests and Full APK assembly
  pass with seven exact AARs, focused trust tests pass 34/34, and the unsigned
  Debug iPhoneOS graph builds with all required frameworks embedded. The
  complete Tools wall passes 360 tests with one intentional skip, required CI
  validates all ten contexts, all 91 operations records validate, and the
  terminology snapshot records 18,146 classified occurrences across 1,616
  groups with zero forbidden mappings. The first exact-head hosted run exposed
  one deterministic Android localization-generation mismatch: the canonical
  nine-locale source contained the printed-band-ID copy, but generated Android
  resources did not. Regenerating all nine Android app-wide locale files fixed
  the mismatch. The focused parity test, all 5,053 Full Debug unit tests,
  source-only Full Debug lint, and Full Debug instrumentation compilation pass
  locally. Replacement exact head
  `ebcbb13acac29b110ee28e923768eba4a15a07a7` passed every hosted context
  except the iOS production-shell cancellation regression. The hosted fixture
  deliberately held a synthetic report queued, but cancellation then entered
  the production authenticated remote-deletion path even though the synthetic
  report has no remote binding. A DEBUG-only correction now terminally cancels
  that held fixture through the existing outbox cleanup path; Release behavior
  is unchanged. Exact head
  `9d5ebf0751b4bc697c4a64c7ad6a7f4491c6e090` then passed every hosted
  context except the same iOS production-shell test, but the replacement
  failure occurred before cancellation: the hosted simulator took longer than
  the test's label wait to expose the review action, and an off-screen tap did
  not execute. Stable Build/Send/Cancel identifiers, explicit hittability
  scrolling, bounded phase waits, and fail-fast prerequisites now synchronize
  the regression without changing report or Release behavior. The corrected
  focused test passes locally in 25.994 seconds; all three app-report UI tests
  pass together 3/3 in 62.214 seconds. Follow-up commit/push, replacement
  exact-SHA hosted checks, normal protected merge, protected-main
  verification, and final round-owned cleanup remain.
  Supplier redistribution, signing/store review, physical BLE, background
  collection, history retention, haptics, battery, firmware, egress, provider
  delivery, production load, and physiological accuracy remain external or
  physical gates.
- A September 25 Android review follow-up is committed locally at
  `12e7819c968eea5006e18f4d000874dac6b4673b`.
  Live now selects supplier versus standard controls from the durable active
  registry source kind, preserves the last confirmed projection across a
  registry-read failure, blocks standard controls while source ownership is
  unresolved or malformed, and still exposes ordinary connection controls
  after a successful read confirms there is no active band. Therefore a
  temporary supplier credential-store failure that resets display state to
  `IDLE` cannot expose or invoke WHOOP Scan & Connect under the supplier row.
  Full debug production/test Kotlin compiled and the focused supplier Live
  suite passed 10/10 with zero skips or failures. No emulator, physical device,
  or push was performed.
- A September 25 Apple review follow-up is committed locally in the same
  `12e7819c968eea5006e18f4d000874dac6b4673b` implementation.
  Supplier discovery keeps the existing short retry burst and then continues
  through one cancellable 60-second recovery tail while that durable source
  keeps WHOOP paused. The tail stops with the source and resets after a
  successful live sample. Focused macOS tests passed 2/2 with zero failures.
  Physical iPhone and supplier-band reconnect timing remains unverified.
- Final September 25 local replacement review is green and remains unpushed.
  Apple now restores supplier transport after early pairing failure, binds
  handoff to the exact current registry owner, and removes stale day ownership
  even when a device row was already archived. Android serializes pairing and
  reconciliation, records transient live failure as recovering, compensates a
  mutating credential-clear failure before reconnect, and ignores delayed
  callbacks from replaced sources. Apple local SDK paths are root-derived,
  quoted for spaces, and reject xcconfig injection characters. Focused Apple
  tests pass 50/50. The final Android follow-up distinguishes a missing
  credential from a transient encrypted-store read failure, quiesces WHOOP
  before a supplier retry can inherit its source identity, serializes
  reconciliation and pairing, generation-fences queued pairing requests, and
  restores the durable source after pairing scan failure or cancellation.
  Coordinator regressions pass 31/31 and the complete supplier-focused Android
  slice passes 73/73. The complete Android Full wall passes 5,085 tests with
  seven intentional skips; `WhoopStore`
  passes 539/539; the macOS app passes 2,296 tests with one intentional fixture
  skip; and the exact-current unsigned Release iOS graph builds the phone app
  with embedded Watch, Watch complications, and widget products without source
  warnings. The complete Tools wall passes 365 tests with one intentional skip
  plus 50 root localization-parser tests. Direct release,
  required-CI, trusted-control, calibration, terminology, provenance,
  private-data, health-claim, localization, workflow, and shell gates pass.
  Terminology records 18,282 classified occurrences across 1,618 groups with
  zero forbidden mappings. Remote PR head
  `5c67c664a4e7347d9de4c5fd319b6613fd308be8` remains the previous all-green
  candidate. The local tree additionally adds restart-safe orphaned-credential
  cleanup, a cancellable Android recovery tail, and ownership-before-connect
  ordering. Supplier APIs are quarantined behind one native client per
  platform; a cross-platform source-boundary regression and updated runbooks
  make future SDK drops a wrapper, artifact-trust, compatibility, and
  conformance change rather than an app rewrite. One consolidated replacement
  commit/push, exact-SHA hosted checks, evidence-backed thread resolution,
  protected merge/main verification, and final exact round-owned cleanup
  remain.
- The September 25 first-run and supported-band milestone is committed in
  `db7de8e2571b1effd8278537d63bd7019b2b0d28`; its exact hosted head is green.
  Apple and Android now use the same eight-stage first-run
  sequence, with supported-band setup before account and no Home surface mounted under
  incomplete onboarding. Normal customer entry points say `Connect band` and
  list only pairable launch transports: the supplier `NOOP Band` appears only
  when its native adapter is available, while compatible 5/MG and 4.0 remain
  explicit qualification transports. Experimental devices remain behind the
  internal all-device scope. Dynamic accent fills use paired inverse ink, and
  Android light surfaces resolve to dark text and icons. Exact evidence is
  green: iOS UI 2/2, complete macOS 2,312 with one intentional skip, Android
  Full 5,099 with seven intentional skips plus APK/lint/instrumentation
  compile, API 35 visual hierarchy inspection, 365 Tools tests with one
  intentional skip, 50 root localization-parser tests, and the full direct
  policy wall. The terminology ratchet records 18,330 occurrences across 1,621
  groups with zero forbidden mappings. The API 35 emulator was shut down and
  the exact 5.7-GiB round-owned Apple DerivedData tree was removed. Exact
  implementation head `db7de8e25` passed every hosted job and all ten protected
  contexts. Review-closeout commit `93d5ffed1` adds explicit non-supplier
  reactivation regressions and removes the remaining Android archived-row
  direct callback. One replacement push, exact-head hosted checks, normal
  protected integration, and physical BLE remain.
- The September 25 step-motion false-positive correction in the commit
  containing this record is the final locally verified candidate for PR `#17`.
  Apple and Android now retain current counter deltas only when activity
  evidence says walk or run;
  still, current classless, unknown, invalid, zero, and sync-gap deltas are
  rejected. Heart rate remains wear/effort context rather than gait proof.
  Rejected or ambiguous partial windows suppress new gravity/step estimates but
  do not erase prior daily or estimated history; only retained locomotion
  removes a superseded computed `steps_est`. Manual-workout display also keeps
  a rejected band counter distinct from a truly absent one, so the iPhone
  pedometer is used only when no band counter rows exist. Focused evidence
  passes Swift analytics 35/35, Swift storage 46/46, Apple app orchestration
  57/57, and Android 58/58. Complete walls pass StrandAnalytics 1,503 with seven
  intentional private-data skips, WhoopStore 547/547, Android Full 5,150 with
  seven intentional skips plus APK, lint, and instrumentation compilation, and
  macOS 2,324 with one intentional fixture skip. The exact-current unsigned
  iPhone simulator graph also builds the Watch, complications, and widgets.
  The complete repository-control wall passes 571 tests with one intentional
  skip, and all direct release gates pass. PR `#17` is authoritative for the
  candidate head, hosted exact-SHA checks, and protected integration state.
  Exact round-owned cleanup follows durable hosted evidence. Physical step
  validation remains external.
- The uncommitted final September 25 replacement keeps the step policy
  unchanged and closes the remaining source-integration findings. Day ownership
  requires a retained classified walk/run delta rather than a raw or singleton
  counter row. Supplier removal on Apple and Android now archives while the
  credential remains available, then performs restart-safe secure cleanup
  through the pending ledger. Apple registration becomes ready after verified
  battery and treats live HR as optional; not-worn or busy does not force
  re-pairing. Android accepts approved hardware/firmware revision drift only
  for the established peripheral, model, and capabilities, persists the new
  binding before continuing, and rejects model or peripheral substitution.
  Exact local evidence is green: Apple supplier lifecycle 49/49; Android
  supplier adapter/coordinator 75/75; Android Full 5,164 with seven intentional
  skips plus APK/lint/instrumentation-source compilation; macOS 2,336 with one
  intentional fixture skip; and the generic iPhoneOS Release graph embeds
  Watch, complications, and widgets. The configured complete
  repository/server/SDK wall passes 1,173 tests with 215 declared skips and
  78 subtests; the focused release-policy wall passes 137 tests plus
  62 subtests; direct release, required-CI, trusted-control, calibration,
  terminology, localization, operations, legal, distribution, private-data,
  claims, SDK-artifact, and diff gates pass. The reviewed terminology ratchet
  records 18,533 classified occurrences across 1,628 groups with no active-use
  regression. Remote PR `#17` head `e92efc51e` passed every applicable hosted
  job and all ten protected contexts, but it predates these final fixes. One
  consolidated replacement commit/push, replacement exact-SHA hosted checks,
  evidence-backed review-thread resolution, normal protected merge,
  protected-main verification, and final bounded-log/test-environment cleanup
  remain.
- The September 26 final Android review closeout remains local and keeps the
  step formula unchanged. Pending supplier-credential cleanup now has separate
  durable archive and authentication-rejection ledgers, supports multiple
  pending device cleanups across process recreation, retries on the bounded
  1s/5s/15s schedule and foreground entry, and fails closed by archiving a
  rejected supplier row if both ledger persistence and secure deletion fail.
  The initial durable active-source projection retries transient registry-read
  failure and invalidates a stale confirmed projection when source selection
  changes. Devices selects supplier connection/battery presentation only from
  the exact supplier device's display stream rather than stale WHOOP state.
  Focused compilation and 76/76 tests pass. The complete Full wall passes
  5,177 tests with seven intentional skips, builds the 54,399,693-byte debug
  APK, passes lint with zero errors, and compiles 207 instrumentation test
  classes. Independent final review reports no remaining correctness finding
  in the changed Android boundary. The post-closeout complete Tools wall and
  direct policy controls are rerun after the final operations and terminology
  snapshot. Remote PR `#17` head `58f4c3d5` remains the prior hosted-green
  candidate; one replacement commit/push, replacement exact-SHA checks,
  resolution of the three matching threads, normal protected merge,
  protected-main verification, and exact cleanup remain.
- An isolated local follow-up from `60df38a2` confirms the vendored Swift and
  Kotlin `failOperation` implementations already reject non-operation failure
  categories before state mutation. Matching app-side regressions pass 2/2 on
  each platform and preserve the existing authentication/security active
  operation terminal behavior. The follow-up is local only and unpushed.
- Historical checkpoint: `NoopBandSDK` PR `#24` merged normally at
  `f20f4ed552328a64a8a598aaac72befa1d481262`. Two independent app-source
  exports from that exact merge are byte-identical. The app's exact ten-file
  source export has manifest SHA-256
  `4801fd6ecbece36df653d91e0d0d975f2fea4c1f7d59f81c69a8b08d90f1b9cf`.
  The app-owned Swift wrapper SHA-256 is
  `31705f1ceb14f0d6eac686083b7012ff685403b0e01435c472e5a8fce3ca7943`.
  Export-manifest schema `1` remains unchanged; the negotiated capability
  contract is schema `2`. It separates `liveStreams` from `historyStreams`,
  binds retained and first-lost overflow ranges through acceptance and durable
  receipt, blocks established authentication/security invalidation while
  persistence is unresolved, validates retained sample bounds and loss-range
  chronology, rejects advertised history with zero retention, and exposes a
  distinct terminal firmware-failure state. The SDK additionally publishes
  each platform's ordered conformance list and fails closed on contract-order
  drift. PR `#20` additionally rejects malformed delayed capability snapshots
  without moving a ready Kotlin session to `INCOMPATIBLE`. PR `#21` preserves
  a restored history checkpoint across an intervening source, adds a
  generation-fenced graceful disconnect to idle, and cancels active live and
  history work through bounded typed diagnostics. PR `#22` binds discovery
  callbacks to an opaque scan-session token, bounds hostile Kotlin set
  traversal by iterator steps, and rejects history operations unless both
  retention and a history stream were negotiated. PR `#23` closes the
  same-module Kotlin authority gap by retaining the exact issued scan token and
  requiring reference identity for scan callbacks. PR `#24` makes Swift consume
  the active scan token before candidate-selection diagnostics suspend, so
  late select, cancel, and failure callbacks match Kotlin's `staleCallback`
  contract without invalidating the accepted connection. Upstream verification
  passed Swift 64/64, Kotlin/JVM 71/71 plus `installDist`, shared conformance
  42/42, and the clean 60-file repository gate.
  At that checkpoint, the app was repinned locally to `f20f4ed5`. The exact artifact verifier
  and its adversarial suite pass 9/9, the vendored Swift package passes 15/15
  across all 42 automated scenarios, the real macOS app boundary passes 10/10,
  and Android Full integration passes 13/13, including a direct app-module
  forged-token rejection while the issued token remains usable. Android Demo
  plus Full and Demo instrumentation sources compile. The unsigned Release iOS
  simulator graph builds and embeds validated Watch, Watch complications, and
  widget products. Heavy commands ran sequentially through the bounded runner.
  The generated vendored SwiftPM caches and 3.2 GiB/5.1 GiB isolated Apple
  DerivedData were exact-deleted after evidence capture, restoring 22 GiB free
  disk; the exact artifact verifier passes again.
  PR `#17` remote head `fed31b0f164675b0d1f6ef5a7724262afb23f0af`
  was the prior exact head with all ten required hosted contexts green.
  The PR `#24` app repin was still locally modified and uncommitted at this
  historical checkpoint; it was later superseded by the PR `#25` app
  implementation and reviewed-evidence commits recorded above.
  The reviewed terminology snapshot, complete 318-test Tools wall, exact
  204-test release matrix, direct policy gates, and independent exact-diff
  review are complete. The review's only P2 was stale status wording corrected
  in the authoritative records. Final post-correction verification, commit,
  one consolidated push, replacement exact-SHA hosted checks, protected
  merge/main verification, and final cleanup remain.
  WHOOP remains the default independent test transport and the first-party
  source factory remains disabled. No supplier binary, firmware, real adapter,
  flasher, physical BLE evidence, background evidence, battery evidence,
  haptic evidence, or physiological-accuracy evidence is included. Both
  repositories reported `PUBLIC`; that historical visibility gate was later
  superseded by the current public, source-only D-056 decision.
- Historical PR `#16` checkpoint: supplier-independent implementation and applicable local
  platform verification are green. Pull request `#16` candidate `e9b3a380`
  passed 32 hosted jobs, including every Android job (Review Sample,
  production shell, and build-and-test), policy, trust, server, Swift packages,
  and the macOS build/tests. The iOS build passed; its production shell
  completed 37 tests, skipped one intentional private case, and failed only
  `testTodayScrollPerformance`. The first timed scroll round trip completed,
  then XCTest invoked the simulator measurement closure for extra calibration
  gestures and its event-loop observer stopped becoming idle. The correction
  makes the simulator path execute exactly one wall-clock-bounded round trip
  while retaining Apple's five-iteration scrolling/deceleration metric on real
  devices. The corrected simulator test passed once and then 3/3 repeated
  iterations locally through the bounded runner. The exact Android command
  shape and 65 focused CI tests pass. After the test-only correction, 66
  focused terminology/required-CI/trust tests and the complete 305-test tool
  wall pass with one intentional skip. The reviewed active terminology
  allowlist is unchanged and the historical inventory has zero forbidden
  mappings. The exact Python 3.14 release-policy matrix is green; replacement
  commit/push, hosted exact-SHA checks, protected merge, and protected-main
  verification remain pending.
- Fresh September 20 independent Apple/Android and server/infrastructure review
  found no P0, but the replacement candidate is not yet release-ready. Local
  fixes now quiesce Friends work around account deletion, preserve scheduling
  after cancellation, reconcile Android encrypted outbox generations, restore
  `noop-charge-v2` reproducibility, bind installations to platform/plan limits,
  return truthful account privacy state, fail closed on migration-058 schema
  drift, bound deletion-worker lock attempts, verify real Friends account
  erasure, bind mobile App Check enrollment to platform, and emit bounded
  enrollment outcomes. Focused Android Full-debug tests, 29 Swift Recovery
  tests, 305 Tools tests with one intentional skip, 50 i18n tests, required-CI
  validation, 38 consolidated PostgreSQL cases, and 4 focused enrollment API
  cases pass. The GCP source now separates pinned migration authority from five
  workload-specific restricted runtime identities and database secrets; 13
  provisioning tests, 22 production-deployment contracts, and 20 plan-only
  OpenTofu tests pass. Failed secret publication or verification restores the
  previous password or quarantines a first-time runtime role. The final Friends
  localization/accessibility wall also passes on Android and Apple, the
  unreachable Apple/Android self-hosted Friends presentation has been removed,
  account-deletion copy is plan-neutral, and 33 focused Apple tests plus the
  29-task Android managed-only Friends build pass. The exact-current unsigned
  Release iOS graph builds with its embedded Watch app and widget validated.
  `NoopRemoteSync` passes 188/188 after a fail-safe legacy communication-field
  decoder correction, `WhoopStore` passes 539/539, and the complete Tools wall
  passes 305 tests plus 44 subtests with zero forbidden terminology mappings.
  The exact-current complete macOS wall passes 2,207 tests with one intentional
  skip and zero failures.
  Remaining blockers include live staging credential provisioning, the
  consolidated commit/push, hosted exact-SHA checks, and protected integration.
- The September 21 final closeout additionally preserves the terminal
  service-erasure account fence, makes managed import reachable on both phone
  platforms, prevents restored Apple preferences from creating an outbox echo,
  serializes all Android Friends communication permissions, completes
  destructive-flow localization, and removes only proven unreferenced
  self-hosted Friends presentation resources. Focused closeout evidence is
  green: Apple 13/13, Android localization 6/6, Android retention 19/19, Swift
  retention 6/6, managed-erasure unit 4 pass/3 PostgreSQL-gated skips, and
  changed-server Ruff check/format. The separately recorded disposable
  PostgreSQL terminal-fence test remains green.
- The same closeout now makes history-chunk credit callback-confirmed on Apple
  and Android, fences delayed persistence/callbacks across ended sessions, and
  treats local `strap_trim` only as a diagnostic watermark. Apple reconnects
  fail-closed if a watchdog expires with an acknowledgement in flight. The
  Apple focused suite passes 23/23. Exact-current broad evidence is green:
  `NoopRemoteSync` 191/191, `WhoopStore` 539/539, macOS 2,213 with one
  intentional skip, iOS simulator 39 with one intentional skip, unsigned
  Release iOS with embedded Watch/widget and zero compiler warnings/errors,
  Android Full and Demo 4,972 each with seven intentional skips across 175
  tasks, disposable PostgreSQL 784 with one intentional skip, and 20/20
  plan-only OpenTofu tests. The repository tool wall passes 305 tests with one
  intentional skip. Required-CI validates all ten contexts; the terminology
  ratchet records 17,837 classified occurrences across 1,583 groups with zero
  forbidden mappings. Remaining work is consolidated commit/push, hosted
  exact-SHA verification, protected integration, and round-owned cleanup.
- PR `#16` review remediation advanced the remote head to
  `149843c109ef85093f62965ac977263180bcc796` with an Apple formula-migration
  integration regression. The final local tree also omits unusable optional
  formula baselines without changing `noop-charge-v2`, serializes
  ownership-deletion claims with cancellation, removes the remaining
  unreferenced Android self-hosted Friends view model and server-address invite
  copy, and adds account-scope/localization/navigation regressions. Focused
  evidence is green: server 39 unit/contract plus 4 disposable-PostgreSQL
  cases, Apple 56 requested plus 10 archive and 10 formula cases, Android Full
  and Demo 62/62 each with app and instrumentation-source compilation, and the
  complete 305-test tool wall with one intentional skip. The terminology
  snapshot now records 17,840 occurrences across 1,585 groups with zero
  forbidden mappings. Final consolidated remediation commit/push, all ten
  exact-SHA hosted contexts, remaining reviewed-thread resolution, protected
  merge/main trust, and exact cleanup remain pending.
- The consolidated PR `#16` remediation is now remote at
  `1b61ebcac5c0803e6025c0491d1b36feb7aa7af1`. Two later Android review findings
  were confirmed and corrected locally: complete-history import retains an
  explicit cancel handle and localized canceled state, and an OS-disabled
  preferred Safety channel is blocked rather than routed through the standard
  channel. Full and Demo each passed 12/12 focused import/Safety cases while
  compiling app and instrumentation sources; after adding all-locale copy and
  its ratchet, each variant passed 18/18 focused cases. A narrow follow-up
  commit/push, exact-SHA hosted contexts, thread resolution, protected merge,
  protected-main verification, and cleanup remain.
- The late Android follow-up is remote at
  `ad936850d9094ac2c317095f979eebc3b26845ca`. The final two review findings are
  corrected and verified locally alongside two additional review closures.
  Formula civil-day UTC conversion rejects underflow/overflow through the
  existing input contract. Forward migration 059 targets only links created by
  migration 047 for identities/accounts already terminal at that timestamp,
  removes dependent authority state, preserves active ownership roots including
  a concurrent link, retires only true orphans, and restores ordinary guards.
  Apple and Android defer mixed Friends summaries until formula migration is
  complete, and complete-history restore/list paths explicitly select
  `server_readable` chunks while retaining client-encrypted storage. The
  canonical localization source and generated Apple/Android resources agree
  after retiring the stale invite key. Hosted Android production-shell runs now
  use a 1.5 GiB heap and one worker. The final migration repair also removes
  the historical migration-versus-erasure deadlock, preserves
  `deletion_pending` principals needed for cancellation, avoids global
  ownership-table locks, and uses one schema-bound security-definer lock
  function whose body, principal-table owner, search path, return type,
  arguments, and exact execute ACL are verified before runtime credentials can
  be published. Registration takes the principal lock before ownership writes
  and reconciles the ownership link in the same transaction; the restored link
  guard is schema-qualified so the hardened function search path cannot shadow
  or hide its control-plane tables. A final independent database review also
  unified registration/reconciliation/deletion on one privacy-safe advisory
  key, restored only tombstone-proven pre-059 erasure principals whose
  ownership roots predated retirement, and extended runtime verification to
  helper volatility and `pg_proc` ownership. Current evidence: the complete
  fresh-database server wall passed 800 tests with only the explicitly opt-in
  Twilio staging test skipped across 801 collected tests; the final late
  database/provisioning wall passes 19/19 after the earlier broad 21/21 wall;
  migration 059 is pinned at
  `f8fbc7171eaae23b6f5aa8c48c12613189a4ad2567e22c9807eea84c2e8ea1cd`;
  Ruff check and format pass on the seven final review files after the earlier
  101-file release-scoped wall; `NoopRemoteSync` passes 192/192; Apple formula
  contracts pass 12/12; and Android Full/Demo each pass 64/64 focused final
  cases. The final
  terminology snapshot records 17,846 occurrences across 1,585 groups with
  zero forbidden mappings; the complete repository wall passes 355 tests plus
  44 subtests, and required-CI, release, legal, private-data, health-claims,
  localization, operations, calibration, trusted-control, and diff gates are
  green. A final review then confirmed one Android-only parity gap: an empty
  formula-traversal segment could preserve prior-revision computed scores while
  recording migration completion. The local follow-up now threads traversal
  intent into Android scoring and atomically clears only that computed
  daily/managed-Rest window when no raw or imported evidence remains; ordinary
  transient empty passes still preserve the last complete scores. Its focused
  JVM regression passes 3/3 and the Full-debug app plus instrumentation source
  compile succeeds. The first 1.5 GiB local compile was bounded and stopped on
  Kotlin heap exhaustion; the repository-standard 4 GiB local rerun passed.
  Only the final narrow commit/push, exact-SHA hosted verification,
  review-thread resolution, protected merge/main trust, and exact cleanup
  remain.
- Initial hosted replacement commit `bec61a55c7e45fbb2b1563c891858e439049b9cb`
  reached run `35546684149`. Server source lint passed, but Ruff's format check
  identified seven files. Ruff 0.12.2 applied its canonical formatting to
  exactly those files; the complete server source check and format check now
  pass locally. The correction is formatting-only and does not invalidate the
  recorded server behavior wall. The corrected exact head still requires one
  replacement push and hosted verification.
- Exact PR head `825d015cd404433ac28f67ec7182520b123d48d5`
  passed every required Apple, server, package, policy, release, trust, and
  Android build wall. Its API 35 production shell passed the new eight-case
  stale-formula Room regression but failed two existing app-report tests before
  their sheets opened. The process-global report channel could hand a request
  to a retiring Activity collector. The local correction removes that mailbox
  and routes Test Centre through a compiler-required callback owned by the
  current `MainActivity`; shake and demo requests retain their direct
  controller path. Fixed-category `report.request` outcomes make the boundary
  observable without identifiers or payloads. The 4 GiB one-worker Full app,
  focused JVM test, and complete Full instrumentation-source compile pass; a
  deliberate 1.5 GiB local attempt stopped at the known Compose compiler heap
  boundary. One narrow commit/push, replacement exact-SHA checks, protected
  merge/main verification, and cleanup remain.
- Replacement PR head
  `e1eaa4deafbc1b986e933037acaaec3d4e7367da` proves that correction in the
  hosted API 35 production shell. Android production shell, Review Sample,
  build-and-test, and its required aggregate pass; iOS, macOS, server, Swift
  packages, operations, localization, health-claims, runtime-license, and trust
  checks also pass. The sole failure is the release-control terminology
  snapshot ratchet: source and operations edits moved existing line numbers and
  digests while occurrence count, category totals, and the active customer/core
  allowlist remained unchanged. The reviewed scan records 17,846 occurrences
  across 1,585 groups and zero forbidden mappings. The inventory has now been
  regenerated and its exact digest repinned; the 191-case release-control wall,
  standalone 9-check report, required-CI ten-context check, trusted self-check,
  shell entrypoints, calibration parity, distribution provenance, private-data
  guard, operations validation, terminology ratchet, and diff hygiene pass
  locally. One evidence-only push, final exact-SHA hosted verification,
  protected merge/main trust, and cleanup remain.
- The next exact-head review identified four P2 contract defects. Watch live-HR
  selection is remote at `3b69ee07`: freshness and plausible BPM are applied
  before selecting the newest sample, with invalid-newest/valid-earlier and
  no-valid-initial-batch ratchets. Local commits `e1e94c67` and `5778e2f0`
  make Android selected-file staging cancellation responsive without replacing
  prior durable import state, enforce the formula-shadow `+/-1e308` persistence
  bound through 422 validation, and reject skipped civil days such as
  `Pacific/Apia` 2011-12-30 before persistence. Focused evidence is green:
  Watch source/XCTest type-checks and two policy checks; two Android deterministic
  staging regressions by source review; 29 executor plus 9 model/API tests; and
  Ruff check/format. The Android Gradle attempt was stopped before compilation
  because free disk was 3.4-4.0 GiB with 8.7 GiB swap, below the unchanged
  10 GiB floor. Superseded heavy GitHub runs were canceled, exact worker-created
  Android/Watch outputs were removed, and the final combined push, exact-SHA
  hosted walls, four-thread resolution, protected merge/main trust, and cleanup
  remain.
- Xcode 27 is installed and `xcodebuild -license check` exits `0`; the former
  license blocker is resolved.
- Earlier broad local evidence before the late-review follow-up:
  `NoopRemoteSync` passed 191/191 and
  `WhoopStore` passes 539/539. The complete disposable-PostgreSQL server wall
  passes 784 cases with one intentional skip and two framework deprecation
  warnings. Android Full and Demo each execute 4,972 tests with seven intentional skips and zero
  failures/errors inside one 175-task compile, lint, APK, unit, and
  instrumentation-source wall; lint reports zero Error/Fatal findings. The
  complete macOS wall passed 2,213 tests with one intentional skip and zero
  failures. The unsigned Release iOS graph succeeds with zero compiler errors,
  zero `ManagedCloudService.swift` warnings, and its Watch, complications, and
  widget extensions embedded; the iOS simulator production shell passes 39
  tests with one intentional skip. That repository-tool wall passed 305 tests
  plus 44 subtests, and its then-current terminology inventory recorded 17,837
  classified occurrences across 1,583 groups with zero forbidden mappings. Thirteen
  database-role tests, 22 production-deployment contracts, and 20 plan-only
  OpenTofu tests pass without apply. Exact replacement-candidate API 35
  execution remains a required hosted context because the required local x86
  managed device is unavailable.
- Deterministic Safety paging capture passes a test-only user confirmation and
  two preselected dummy contact roles through the production token codec,
  managed push service, and FCM payload builder with 3/3 installations and 2/2
  contacts reached, zero provider traffic, and no sensitive payload values.
  Accepted-contact selection/revocation and precise-location lifecycle are
  separate PostgreSQL integration boundaries. The direct smoke test passes 1/1,
  Ruff passes, three focused PostgreSQL tests pass, the Apple Safety contract
  passes 51/51, and Android Full and Demo each pass 45/45 focused tests. The
  disposable database and test environment were removed after evidence.
- Execution safety now defaults bounded commands to discard unrequested child
  output, cap explicit private logs at 128 MiB, enforce 10% free-memory and
  10 GiB free-disk floors, and terminate runaway-output process groups. All 134
  bounded-runner, required-CI, and trusted-control regression tests pass. This
  directly guards the observed iTerm application-memory failure mode when
  repository heavy commands use the runner; it does not control unrelated apps
  or commands run outside that boundary.
- The hosted-candidate correction passes 77/77 focused macOS tests, including
  all 51 Safety contracts, and the exact Android Full app plus instrumentation
  APK preparation graph with Kotlin in-process. Candidate `e9b3a380` proves
  all three hosted Android jobs complete under the smaller execution heap and
  unchanged host guards. It also exposed the iOS simulator's extra XCTest
  measurement invocations; the corrected single-round-trip path passes four
  local executions while physical devices retain the real performance metric.
- The final policy wall passed all 301 tool tests with one intentional skip plus release, calibration, terminology, required-CI, trusted-control, provenance, privacy, medical-truth, localization, operations-record, and diff gates. The hosted disk-control and initial execution-memory corrections passed the complete 304-test wall with one intentional skip; the retry-hardening tree and corrected iOS simulator liveness path each pass the 305-test wall with one intentional skip. The exact 2 GiB daemon command, 65 focused Android CI tests, 66 focused terminology/required-CI/trust tests, and four iOS scroll executions also pass.
- Exact cleanup manifest
  `8080d7201bc9ec1ac940842c2aa8d0c0026b79fd8980275d8fe187f97583a62f`
  removed three closed completed review-session files totaling
  4,475,749,846 bytes. Manifest
  `991d0340c6e0d4cf61856c0c41b8135dfe059dec471b0646aaed69e84bffbfca`
  removed 62 exact round-owned `/private/tmp/noop-*` paths totaling
  16,566,458 bytes after preserving their results. Current agent-session files
  with open handles and the two cleanup manifests are deliberately retained.
  Later verification outputs were removed by the final closeout cleanup
  recorded below.
- Replacement candidate SHA, hosted `10/10`, protected merge SHA, and
  protected-main trusted result remain pending. No Docker image build,
  production runtime, signing, legal, carrier, physiology, or physical
  accessibility result is claimed without direct evidence.
- The current release candidate requires a NOOP account before shell entry;
  there is no ordinary account-free exploration path. D-059 still stages cloud
  authority for durable history, canonical formulas, recommendations, and
  cross-device state while retaining the encrypted edge collector, bounded
  offline cache, immediate Safety initiation, and explicit per-data-class
  rollback gates.
- Managed portability now has v2 integrity, resumable export, complete
  prevalidation, and resumable idempotent import for selected chunks plus
  `day_ownership`. Ownership deletion now has cooling-off request, status,
  cancellation, session revocation, migration-045 durable target progress,
  restricted managed-data erasure coordination, and matched mobile flows.
  `DAT-170` remains open for live scale/expiry/isolation/physical evidence;
  `ACC-340` remains open for provider identity erasure, ownership control-plane
  final erasure, approved physical band retirement/wipe, and legal/operator
  evidence.
- The September 20 managed-Friends slice now separates account-only background
  work from health-backup and Safety enrollment, exposes account-only deletion
  and cancellation on Apple and Android, and completes the corresponding
  localized account lifecycle. Focused Apple tests pass 12/12; Android
  scheduler/localization tests and resource processing pass; the latest iPhone
  simulator graph builds with Watch and widgets validated; and the isolated
  PostgreSQL managed-Friends suite passes 8/8. Current routed source and 33
  focused Apple tests prove that macOS uses the managed read-only account
  route; the historical self-hosted screenshot is stale and is not accepted as
  current evidence. The legacy Apple/Android Friends presentation source is
  now removed, and Android managed-resource contracts pass. See
  [NOOP-hosted Friends and communications](rounds/2026-09-20-noop-hosted-friends-communications.md).
- Cleanup manifest
  `c302d957bcd169f7244512291cab3cbb9334690ee7d7d0baad5757b937d3ff09`
  removed 23 exact September 20 round-owned temporary paths totaling 7.170 GiB
  after evidence was recorded. Post-cleanup verification found no test
  PostgreSQL listener or candidate app process, with 20 GiB free and iTerm at
  approximately 330 MiB RSS.
- Final pause cleanup manifest
  `13f5560c7a39e340cd3c4d842a369fbd3dd979f0c01bec0868d7221d387c271c`
  removed 30 additional exact round-owned paths after the complete macOS and
  final policy evidence was recorded. No build or test process remained, 21
  GiB was free, and the unrelated pre-existing Homebrew PostgreSQL service was
  preserved.
- Final closeout cleanup manifest
  `a9380fba359496f22cf7ae977dbd95ee39b5eec420ff51876aecc5f17424e152`
  removed five exact regeneratable paths containing 118,883 files and
  approximately 6,111,817,728 bytes. Verification found no remaining build or
  test process, 22 GiB free, and iTerm2 at approximately 310 MiB RSS.
- Exact PR `#17` head `a54be2ae` passed every applicable hosted context except
  the iOS production shell. Its only failure was not an infrastructure retry:
  the Recovery chart's hold-to-scrub release also fired its simultaneous
  navigation tap. Retained hierarchy showed Recovery detail already open while
  the test still expected the selected chart value. The shared chart now
  consumes that one overlapping release while preserving ordinary tap
  navigation and re-queries its stable accessibility identifier across
  SwiftUI node replacement. Focused iOS passes 1/1 in 21.607 seconds,
  `StrandDesign` passes 55/55, and the complete local iOS production shell
  passes 39 with one intentional skip and zero failures in 636.770 seconds.
  One exact remediation commit/push, replacement hosted checks, protected
  review/merge, protected-main verification, and exact cleanup remain.

Resume from:

- [September 17 readiness completion](rounds/2026-09-26-september17-readiness-completion.md)
- [PR 17 final review closure](rounds/2026-09-26-pr17-final-review-closure.md)
- [PR 16 final readiness closeout](rounds/2026-09-21-pr16-final-readiness-closeout.md)
- [Cloud authority, Safety paging, and live surfaces](rounds/2026-09-19-cloud-authority-safety-live-surfaces.md)
- [Current UI/cloud readiness review](rounds/2026-09-17-ui-cloud-readiness-review.md)
- [NOOP-hosted Friends and communications](rounds/2026-09-20-noop-hosted-friends-communications.md)
- [First production release checklist](../FIRST_PRODUCTION_RELEASE_CHECKLIST.md)
- [Release blockers](../handoff/RELEASE-BLOCKERS.md)
- [Band physical validation handoff](../handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md)
- [Claude final production review prompt](../handoff/CLAUDE-FINAL-PRODUCTION-REVIEW-PROMPT.md)
- [Agent entry point](../../AGENTS.md)
- [NOOP operations skill](../../.agents/skills/noop-ops/SKILL.md)

## Current scope

- Reconcile the owner's September 19 cloud-authoritative direction through a
  staged, versioned, dual-run migration. The phone remains the reliable edge
  collector and offline cache until per-metric and per-data-class authority
  gates pass.
- Implement and verify bounded pager-grade app Safety, independent live-HR
  presentation controls, managed Friends parity, macOS viewer foundations,
  evidence-backed UI refinements, and the supplier wrapper handoff.
- Preserve the current WHOOP compatibility path for physical regression
  testing. The public `NoopBandSDK` repository contains the binary-free neutral
  core and virtual conformance surface. The app pins that export and now
  contains quarantined optional supplier adapters and an Android provider, all
  default-off without exact ignored local configuration. No supplier binary,
  firmware flasher, or physical behavior is checked in or proven. Keep real
  scanning, possession proof, history, haptics, OTA, and flashing behind the
  supplier-artifact and physical-device gates.
- Validate every material external finding against current source.
- Inspect representative current and proposed renders directly.
- Correct only evidence-backed formula explanation, terminology, loading,
  accessibility, navigation, and account-journey defects.
- Preserve Apple/Android meaning and identify intentional macOS/Watch
  asymmetries.
- Run bounded verification and report external release gates without converting
  source checks into physical-device or production claims.

## Immediate next actions

1. Regenerate the terminology snapshot after the final operations edits, repin
   the required-CI digest, and rerun the complete repository-control wall plus
   diff hygiene.
2. Commit once, push once, open a new protected pull request for
   `codex/sept17-readiness-closeout-20260926`, and require all ten exact-head
   contexts before a normal linear-history merge.
3. Verify protected `main`, then execute the signed physical-device handoff for
   iPhone and Android. A simulator cannot prove BLE discovery, pairing,
   history, battery, reconnect, background collection, haptics, notification
   delivery, TalkBack/VoiceOver traversal, or physiological accuracy.
4. Keep both repositories public under D-056 while excluding supplier
   binaries, firmware, credentials, signing material, private inputs, and user
   or health data. Begin signed physical validation only after the exact
   supplier rights/SBOM/security inputs and representative devices are
   available.

## September 24 exact-head Android correction

- PR `#17` head `f127a605` built the hosted Android product but exposed stale
  tests: feedback process-recreation switched from its injected September 9
  clock to the wall clock and crossed retention on September 24; the
  localization allowlist omitted the new full-history key; and the
  production-shell journey still searched for unselected HRV on the
  selected-only Today surface.
- The tests now preserve the injected clock across recovery, admit the exact
  history key, and navigate through selected Recovery. The complete local
  Android wall passes 4,997 tests with seven intentional skips, lint,
  Android-test compilation, Full APK assembly, and the corrected API 35
  production-shell journey 1/1 in 3.298 seconds. The bounded emulator was
  terminated after the result.
- The terminology inventory is repinned after these durable records and the
  repository controls pass. Next: push one narrow exact-head replacement,
  require all ten protected contexts, merge normally, verify protected `main`,
  and clean exact round-owned outputs. Physical BLE, supplier compatibility,
  background collection, history retention, haptics, battery, firmware,
  signed install, and physiological accuracy remain device or external gates.

## September 23 historical local evidence

- The Recovery chart correction now uses an expiry deadline rather than
  delayed state mutation, preventing a stale first-scrub cleanup from
  interfering with an immediate second scrub. `StrandDesign` passes 55/55, the
  exact scrub-then-tap journey passes 1/1 in 21.660 seconds, and the complete
  iOS production shell passes 39 with one intentional private synthetic-pilot
  skip and zero failures in 628.915 seconds. The exact SDK cache, package
  build, and 3.1 GiB iOS DerivedData outputs were removed after evidence
  capture; 101 GiB is free. Final terminology repin, repository controls, one
  consolidated push, exact-head hosted checks, protected merge/main
  verification, and final log/worktree cleanup remain.
- The prior PR `#30` terminology repin and repository controls were green:
  318/318 Tools tests with one intentional skip, nine release controls, ten
  required contexts, trusted self-verification, exact SDK artifact,
  calibration, distribution/private-data/health-claim guards, all 84
  operations records, complete supported-language catalog coverage,
  shell/workflow lint, Python compilation, and diff hygiene. The PR `#31`
  documentation repin recorded 17,883 occurrences across 1,589 groups with
  an unchanged active allowlist, zero forbidden mappings, and reviewed digest
  `433d89784f464c4a44f423221cf989a05a09f87c1420a24a217ce64e95ac3005`;
  replacement repository-control execution passed 318/318 with one skip. The
  final public-repository handoff correction now records 17,884 occurrences
  across the same 1,589 groups, zero forbidden mappings, and reviewed digest
  `d266cf5458193d6e6d54fac1b9eb949438f537e7ee2a4866c284d04a91e9a529`.
  Candidate `e12b71fb` remains the previous remote head; the PR `#30`
  replacement is still local.
- Historical PR `#31` checkpoint (superseded by current PR `#32`) consumed
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`. Two clean exports are
  byte-identical with manifest SHA-256
  `1290444d1e997a2e9bc4bcc025685f33e9bdd8cf147e49c716f8d7017bc56fa1`.
  The vendored tree is byte-identical to the clean export. Exact app,
  simulator, and onboarding verification are green. Final repository-control
  verification and hosted exact-head verification remain before the app branch
  can integrate.
- Repository visibility was reverified on 2026-09-23: both
  `Dhanunjay-Divi/Noop` and `Dhanunjay-Divi/NoopBandSDK` are public. D-056 now
  records that as the owner-approved operating state, so no post-merge
  visibility change is pending. The public-source exclusion boundary remains
  mandatory.
- App PR `#17` remote head `6d3b54a0` passed every hosted context except the
  iOS production shell. The app built, and the shell's only failure was
  immediate typing after clearing a profile measurement because keyboard focus
  had been removed. The local correction preserves focus, uses native clear
  buttons, and passes the exact UI case three times. A narrow replacement push
  and exact-head hosted rerun remain before protected integration.
- Separate supplier-adapter worktrees are not part of PR `#17`. The Apple
  source-only adapter remains default-off and has no production stream. The
  Android adapter review found uncontained supplier exceptions and terminal
  diagnostic ordering defects; it also retains opt-in and physical gates.
  WHOOP remains the default test transport in the integration candidate.
- `AGENTS.md` and the physical-validation handoff now direct the next
  device-connected agent to install exact signed iPhone and Android candidates
  from protected `main`, complete first-run account/onboarding, establish the
  WHOOP comparison baseline, and integrate only the exact approved supplier
  adapter before expecting the supplier band to connect.
- Final local controls pass: 318 repository tests with one intentional skip,
  84 operations records, the exact 10-file SDK artifact and its 9 adversarial
  tests, the reviewed terminology ratchet, and diff hygiene. The branch is
  ready for its single replacement commit and hosted exact-head run.

## September 24 iOS supplier trust-root follow-up

- Isolated branch `codex/pr17-apple-supplier-runtime-review-20260924` starts
  from `60df38a2ad3e1a825198909336e75c415459b310`.
- The local iOS supplier verifier now requires a tracked owner-only manifest
  for the exact Pod inputs and generated FMDB/MJExtension framework hashes and
  inventories. The embed script re-verifies that contract before copying.
- Focused evidence is green: 29/29 verifier/trust-control tests, direct local
  iPhoneOS bundle verification, Python and shell syntax, scoped diff hygiene,
  and 91/91 operations records. No app runtime file is part of the trust-root
  commit, no push occurred, and signed-device, physical BLE, supplier rights,
  and reproducible rebuild evidence remain external gates.
