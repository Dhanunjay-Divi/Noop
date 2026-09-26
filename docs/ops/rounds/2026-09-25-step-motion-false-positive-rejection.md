# Round: 2026-09-25 - Step motion false-positive rejection

## Status

- State: `exact product-code head 4bcaa17a passes every hosted required context.
  The source-scoped stale-value repair and lexical supplier-wrapper quarantine
  are pushed and green. Exact round-owned cleanup is complete. PR #17 is
  mergeable with auto-merge armed but still requires non-author approval;
  protected-main verification and physical accuracy validation remain`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `4604fd53d15b459d0c2251da8e8697134bdb30e1`
- End implementation commit:
  `db7de8e2571b1effd8278537d63bd7019b2b0d28`
- Review-closeout commit:
  `93d5ffed104d7e3b9f193c2af71c9dfb57d486c8`
- Previous all-green remote review candidate:
  `65e4b0ab5f5ae7695ad2199b90fd50cacc1e5ba1`
- Final hosted-green implementation candidate:
  `9474ffbb6021f186d7a381e53c6b9e20ce0f9a16`
- Previous hosted-green documentation candidate:
  `58f4c3d5b70eb657ae3c953286d569ec76a05cff`
- Final source-scope and wrapper closeout commit:
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`
- Final Android review follow-up commit: commit containing this record
- Record commit or PR: application pull request `#17`

## Objective

Reduce false step totals from stationary repetitive wrist motion while keeping
Apple and Android deterministic. The immediate report is an approximately
4,000-step increase during a head bath despite no walking. The correction must
use evidence the supported stream actually provides, preserve an honest
fallback for legacy rows without activity classification, and avoid treating
heart-rate elevation as proof of walking.

## Scope

### In scope

- Review the WHOOP-style cumulative motion-counter path and every daily/windowed
  consumer.
- Use persisted per-record `still` / `walk` / `run` classification to exclude
  classified non-locomotion deltas.
- Preserve wrap handling, disconnect/reset rejection, calibration, missing-data
  semantics, and Swift/Kotlin parity.
- Add deterministic false-positive, mixed-activity, legacy, and trace tests.
- Record the distinct supplier-band aggregate limitation and the physical
  validation still required.

### Non-goals

- Claiming that synthetic fixtures validate real-world step accuracy.
- Treating heart rate, temperature, or a short motion burst as proof of gait.
- Shipping a new raw-IMU gait model without synchronized physical ground truth.
- Reconstructing individual false steps from a supplier firmware aggregate that
  carries no per-record activity or raw-IMU evidence.

## Starting evidence

- Reproduction or observed symptom: owner report of about 4,000 steps added
  during a head bath and increments from hand motion.
- Relevant source/device/OS/firmware class: exact reporting hardware and
  firmware are not yet recorded. The current WHOOP-style path stores cumulative
  `step_motion_counter@57` plus optional `activityClass`; the supplier SDK
  assessment records aggregate firmware totals without enough app-side evidence
  to remove false steps reliably.
- Existing tests, logs, exports, screenshots, or documents:
  `StepsCounterTests`, `StepsDailyTests`, Android twins,
  `WakeMotionRefinement.walkClassTicksPerMinute`, the September 17 readiness
  round, the supplier SDK assessment, and the physical validation handoff.
- Unknowns that must remain unknown until measured: whether the reported burst
  came from WHOOP-compatible or supplier hardware, its activity-class sequence,
  exact firmware behavior, and physical false-positive/true-positive error
  rates.

## Delivered

- Added one shared class-aware counter analysis on Apple and Android. When a
  window contains activity-class evidence, only deltas attributed to `walk` or
  `run` are retained; `still`, absent/unknown, invalid, zero, and sync-gap
  deltas are counted separately and rejected.
- Preserved the legacy raw-motion kernel only for explicit offline compatibility
  analysis. Production daily and manual paths require activity classification;
  a current all-unclassified window is observed but yields no steps.
- Kept the same kernel for daily steps, Daily Effort's movement floor, and
  manual-workout strap ticks so those surfaces cannot disagree.
- Kept heart rate out of the gait gate. Slow walking remains eligible without a
  heart-rate rise, while bathing heat or stress cannot turn stationary wrist
  motion into locomotion merely by raising heart rate.
- Distinguished an absent counter from any present counter. Gravity movement
  can support the legacy Effort fallback only when no counter row exists; a
  singleton, flat, discontinuous, still, or unknown counter window cannot
  re-enter through the gravity path.
- Moved classified calendar-day steps ahead of the overnight-HR gate. A real
  walk/run counter can publish steps and movement Effort without a scorable sleep
  night, while a counter with no retained locomotion still owns the day and
  suppresses new motion estimates.
- Added a day-scoped integrity repair on Apple and Android. Only a retained
  classified walk/run total removes a superseded computed `steps_est`.
  Still-only, classless, singleton, flat, gap-only, and unknown-only windows
  suppress new fallback estimates without deleting an earlier daily total or
  estimate that the partial window cannot disprove.
- Added one narrowly bounded exception for a stale value produced by the former
  raw-motion algorithm. An all-still window may compare-and-clear that exact
  computed value only when its rows cover the civil-day start through the
  observed end with no edge or internal gap above 15 minutes. Short bathing or
  hand-motion bursts reject new steps but cannot erase whole-day history.
- Integrated retained-counter estimate deletion into the same GRDB/Room
  transaction as score-range replacement. When no score range is being
  replaced, the estimate-only repair still runs in one transaction across all
  computed source namespaces. Validation finishes before mutation and observer
  invalidation occurs only after commit.
- Closed the independent final-review findings that the first repair treated
  every observed no-count window as destructive, performed cleanup through
  separate writes, and lacked sparse-evidence/rollback coverage. Matching
  Swift/Kotlin policy properties and storage regressions now distinguish
  observed counter evidence from authoritative retained locomotion.
- Made active-source ownership fail closed. A failed active counter read or an
  explicit active classified rejection cannot fall through to a canonical/older
  source and restore stationary motion in manual workout totals.
- Preserved the absent-versus-rejected distinction through the Apple manual
  workout display. A phone-pedometer fallback is now eligible only when no band
  counter rows exist; a present still, unknown, flat, singleton, or gap-only
  counter remains blank rather than re-entering through the phone fallback.
- Replaced raw counter-value diagnostics with a bounded opt-in analysis line:
  fixed status/filter categories plus sample, kept, still, unknown, gap, and
  zero-delta counts. Timestamps, day keys, device identifiers, raw counter
  values, delta ranges, and per-user calibration values are excluded.
- Added matching synthetic Apple and Android vectors for a 4,000-tick
  stationary burst, mixed still/walk/run intervals, intermittent/invalid
  classes, legacy rows, wraparound, gaps, daily aggregation, and trace parity.
- Updated the stale Apple supplier-registration regression uncovered by the
  complete macOS wall. The test now injects failure into the current atomic
  insert-and-activate transaction and verifies that the prior WHOOP test source
  remains active with no partial candidate row.
- Closed the remaining PR review surface without broadening the metric formula.
  The final implementation already constructs Oura only after owner-generation
  advancement, routes archived Apple supplier rows through pairing, publishes
  a supplier-only Android capability profile, and restarts Apple supplier live
  measurement after transient not-worn or busy responses. The review closeout
  removes the remaining Android archived-row direct callback and adds explicit
  WHOOP/Oura behavior-preservation regressions.
- Closed five final review findings without using heart rate as gait proof.
  Apple source activation now publishes the exact verified registry rows from
  the same transaction that promotes the sole active source, and a failed
  verification rolls back both activation and ownership invalidation. Apple
  supplier battery callbacks now normalize the vendor's level form to
  percentage, publish charging state, and clear both values on terminal or
  disconnected paths. Apple and Android resolve each source's own heart-rate
  or step evidence before applying source priority, so an imported HR row
  cannot preempt an active band's classified walking evidence. Android
  onboarding accepts a durable supplier row only when the adapter is present
  and the encrypted credential is available or temporarily unreadable, while a
  proven missing credential requires repair. Android pairing returns the exact
  device identifier from its durable commit and no longer depends on a second
  registry read to report success.
- Tightened day-owner evidence on both platforms. A raw or singleton counter
  row can no longer claim a day; the bounded probe carries the preceding row
  across 8,192-row chunks and requires at least one production-retained
  classified walk/run delta. Imported HR therefore wins only when the active
  source has no usable gait evidence, without making HR itself a gait signal.
- Closed the final supplier lifecycle review. Apple treats an incompatible
  product tuple as one terminal event, clears stale live presentation,
  disconnects, and reconciles the durable source. Android accepts approved
  firmware/hardware revision drift through a durable non-authentication rebind,
  records bounded secure-write/rebind outcomes, and preserves the existing
  credential plus supplier retry path when that write fails. Outside
  display-only live mode it clears stale HR/receipt state.
- Completed the Android supplier presentation boundary. Idle and failed picker
  states no longer spin indefinitely, archive returns its transactional
  fallback directly, and the UI no longer asks the user to repeat an obsolete
  replacement step.
- Closed the final credential-loss review on both phone platforms. Supplier
  removal now persists a bounded pending-cleanup marker, commits the registry
  archive while the encrypted credential remains available, and deletes the
  credential only afterward. Archive failure preserves the credential and
  restores the active source; post-archive secure-store failure leaves the
  marker for startup reconciliation rather than attempting a lossy rollback.
- Made live heart rate optional during Apple supplier registration. A verified
  battery response makes the band registrable and starts live HR
  opportunistically; not-worn or busy responses keep the session ready, while
  non-transient live failures remain terminal.
- Corrected Android warm reconnect identity handling. An already established
  source accepts only approved hardware or firmware revision drift for the same
  peripheral, model, and capabilities, persists the replacement binding before
  continuing, and still rejects model or peripheral substitution.
- Closed the final Apple protected-data review finding. Startup credential
  cleanup now reports whether it actually completed and is owned by one retained
  reconciler. An unavailable Keychain ledger or failed deletion receives one
  protected-data-available retry plus a finite 1s/5s/15s retry budget. Success
  cancels both owners; consuming the unlock edge cannot re-arm an unbounded
  lock/unlock loop. Registered supplier rows still retain their credential,
  archived rows still delete it, and an unreadable registry or ledger remains
  fail-closed.
- Closed the final Android review findings without changing the step policy.
  Pending supplier-credential cleanup now separates ordinary archive cleanup
  from authentication-rejection cleanup, persists multiple pending identifiers
  across process recreation, receives a finite 1s/5s/15s retry budget, and
  retries immediately when the app next reaches the foreground. If both
  rejection-ledger persistence and secure deletion fail, the supplier row is
  archived transactionally so the rejected credential cannot remain an active
  source. Startup reconciles only archived rows that still own cleanup and
  avoids duplicate cleanup ownership. The initial durable active-device
  projection retries the same bounded schedule when Room is temporarily
  unreadable, invalidates stale confirmed state after a source-selection
  change, and accepts only a projection for the exact active identifier.
  Device cards select connection and battery state by exact durable device and
  source kind, so a supplier card cannot inherit stale WHOOP state and a
  working supplier card can show only its own live state and battery.
- Closed four post-hosted exact-head findings without changing the step
  formula. Apple persists authentication-rejection cleanup in a separate
  Keychain ledger before credential deletion, reopens the retained bounded
  retry owner after startup, and preserves a rejected credential when the
  marker itself cannot yet be written. Android keeps only supplier construction
  in the preflight path and constructs Oura after teardown, so teardown cannot
  cancel the new Oura state observer. Release trust now treats `Tools/local` as
  a Python execution root, protects the supplier wrapper-boundary test itself,
  and executes that test in the required release-control workflow.
- Closed the final independent source-scope review without changing the gait
  formula. Broad deletion of superseded `steps_est` values remains limited to
  authoritative walk/run evidence, while an all-still legacy compare-and-clear
  is now keyed by computed source and day. The day-owner namespace and current
  aggregate output are the only exact-clear targets; an equal valid value under
  another computed or imported source survives both standalone and score-window
  transactions.
- Replaced the regex-only supplier wrapper detector with a bounded lexical
  scanner. It detects comment-separated Swift imports, qualified module use,
  and Android package paths while skipping nested comments plus ordinary,
  multiline, and Swift raw strings, so comments cannot hide supplier use and
  documentation strings cannot create false importers.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: exact-day computed estimate replacement only.
  Stale `steps_est` points are deleted only after a retained classified
  walk/run count. A continuously covered all-still day may additionally clear
  only an exact matching computed value from the former raw-motion formula.
  Classless, sparse, short, flat, gap-only, unknown-only, mismatched, and
  imported evidence remains intact. Other daily evidence, unrelated series,
  and adjacent days are retained.
- Source/provenance or formula impact: production motion-derived steps now
  require walk/run classification. Rows with no class evidence remain available
  only to explicit legacy compatibility analysis and are rejected by current
  daily and manual production paths.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: step filtering is an activity
  estimate, not a medical result. Heart rate is supporting wear/effort context,
  not a gait detector.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  opt-in Steps test trace reports bounded class-filter mode and kept/rejected
  delta counts. A manual-workout counter read failure records one bounded
  `workouts.step_summary` event on Apple and Android with only fixed outcome and
  failure-kind categories. Supplier credential cleanup uses the existing
  `band.supplier_lifecycle` event with fixed `secure_cleanup` stage,
  completed/failed outcome, and `protected_data_available` or
  `scheduled_retry` trigger.
- Why existing evidence is sufficient, or why new evidence is required: the
  production calculation is pure and synchronous; no new lifecycle operation
  exists. The existing trace must change because the prior trace would otherwise
  disagree with the filtered total.
- Existing evidence reused: `StepsEstimateEngine.rawCounterTrace`.
- New bounded events or operation spans: one failure-only
  `workouts.step_summary` event; no success or per-sample event. The cleanup
  retry adds no event family and only supplies a fixed trigger to the existing
  lifecycle event.
- Android cleanup attempts reuse the existing bounded
  `band.supplier_lifecycle` secure-cleanup outcome. The retry owner records no
  device identifier, credential, health value, or exception text. Active-source
  retry and device-card projection are local presentation reads with no new
  network or high-frequency event boundary.
- Redaction, retention, and high-frequency controls: aggregate counts and fixed
  categories only, emitted solely through the existing opt-in test mode.
- Cross-platform/backend correlation: identical Swift/Kotlin result and trace
  fixtures; server formula parity remains a later D-059 gate.
- Remaining blind spots: real activity-class accuracy, supplier firmware
  aggregate behavior, dominant/non-dominant wrist effects, bathing, driving,
  cycling, and short-walk sensitivity require physical ground truth.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source and consumer review | Complete | The prior WHOOP-style path summed every plausible positive counter delta; the persisted stream also carries optional still/walk/run evidence, and daily/manual consumers share the counter kernel | Whether the device classifies real bathing or walking correctly |
| Focused Swift analytics | 35 tests, 0 failures | The 4,000-tick stationary fixture is rejected; current classless, singleton, gap-only, unknown-only, mixed, legacy, wrap, daily, and trace behavior is deterministic | Physical sensitivity or specificity |
| Focused Swift storage | 46 tests, 0 failures | Ambiguous counter windows preserve prior daily fields and estimates, while retained locomotion removes only superseded computed estimates | App orchestration or physical accuracy |
| Focused Android analytics and integrity | 58 tests, 0 failures; Full app compile passes | Kotlin matches the Swift vectors, owner/window behavior, manual-workout fail-closed policy, chunking, and repository transaction fixtures | OEM or physical-band behavior |
| Focused Apple app orchestration | 57 tests, 0 failures | Classified walking publishes without overnight HR, active-source rejection cannot fall through, rejected counter evidence remains distinct from a truly absent counter for phone fallback, stationary evidence preserves prior history, and retained locomotion replaces only stale computed estimates | Physical-device collection or firmware classification quality |
| September 26 continuous-coverage refinement | Swift `StepsCounterTests` pass 20/20; Android `StepsCounterTest` plus `IntelligenceStepIntegrityTest` compile and pass; Apple engine regressions pass 2/2 | A 4,000-tick all-still burst is rejected, short/sparse/internal-gap windows preserve history, continuously covered all-still evidence clears only the exact stale computed value, and unrelated daily fields survive | Whether physical firmware labels bathing and real walking correctly |
| Complete `StrandAnalytics` wall | 1,507 tests, 7 intentional private-data skips, 0 failures | The changed step kernel, absent-versus-observed fallback boundary, sparse-evidence preservation, and complete shared formula surface remain green | App integration or physical accuracy |
| Complete `WhoopStore` wall | 551 tests, 0 failures | Exact-day computed estimate replacement preserves unrelated evidence and transaction boundaries | App orchestration or physical accuracy |
| Complete Android Full wall | 5,164 tests, 7 intentional skips, 0 failures; APK, lint, and instrumentation-source compilation pass | The exact Full app, analytics integration, archive-first secure cleanup, warm revision rebind, resources, and test sources compile together | Installation, background collection, or hardware callbacks |
| Apple rollback regression | First full wall exposed one stale failure-injection fixture; corrected focused case passes | The atomic registration failure restores the prior source and leaves no partial supplier row | A real secure-store, radio, or vendor callback failure |
| Complete macOS app wall | 2,336 tests, 1 intentional fixture skip, 0 failures | Shared Apple app, exact stale-estimate repair, battery-confirmed pairing, archive-first secure cleanup, terminal compatibility handling, storage, source coordination, metrics, Watch/widget contracts, and accessibility metadata pass together | iPhone hardware, BLE, or signed distribution |
| Unsigned iOS Release graph | Exact-current generic iPhoneOS Release build passes; the phone app embeds `NOOPWatch.app`, `NOOPWatchComplications.appex`, and `NOOPWidgets.appex` | Phone, Watch, complication, widget, localization, and dependency graphs compile together | Signing, installation, haptics, notifications, or physical performance |
| Focused release-contract recovery | SDK artifact tests 9/9 and supplier app-slice tests 8/8 pass after exact generated-cache cleanup and atomic-contract update | The vendored SDK tree is exact and the source-shape gate follows the current transactional registration contract | Hosted execution or physical SDK behavior |
| Complete repository and direct gates | Broad pinned repository/server/SDK wall passes 1,173 tests with 215 declared optional/environment skips and 78 subtests; focused artifact, supplier-wrapper, terminology, trust, required-CI, and release controls pass 137 tests plus 62 subtests. Direct checks pass 9/9 release controls, all ten required contexts, trusted-main verification, 12 metrics / 3 revisions / 13 thresholds / 16 calibration guards, the reviewed 18,533-occurrence terminology ratchet, full localization, all 96 operations records, distribution/private-data, the 1,310-file health-claims scan, syntax, workflow lint, and diff hygiene. | The exact local candidate satisfies the broad local repository, server, SDK-artifact, privacy, claims, localization, workflow, and trust contracts | Hosted exact-SHA checks, protected integration, physical validation, or external approvals |
| Final exact-SHA hosted replacement | Implementation head `9474ffbb6021f186d7a381e53c6b9e20ce0f9a16` passes every required hosted context. The first Apple attempt completed 38 production-shell cases, skipped the intentional private pilot, and lost two batched XCTest keystrokes only in the profile-height assertion. The exact case then passed once locally and five more times with app relaunch between repetitions; the same unmodified SHA passed the complete hosted iOS production shell on retry, and `apple-ci-required` is green. | The final implementation graph, including iPhone, Watch, widgets, macOS, Android, packages, policy, claims, localization, operations, runtime licenses, and trust controls, is hosted-green on the exact reviewed source | Signed installation, physical BLE/background behavior, or step accuracy |
| Exact implementation hosted checks | Exact head `db7de8e2571b1effd8278537d63bd7019b2b0d28` passed 33 jobs with four intentional skips, including all ten protected contexts, Android, macOS, and iOS production-shell checks | The consolidated implementation builds and passes hosted policy/tests on the reviewed SHA | The later review-closeout commit until replacement hosted checks finish |
| PR review closeout | Apple focused set passes 32/32; Android Full compile and `SupplierDeviceCardPolicyTest` pass 7/7 | Oura ownership, supplier transient live restart, archived activation policy, non-supplier reactivation, and Android supplier presentation are covered on the local replacement head | Physical BLE, Compose instrumentation, or signed installation |
| Final source-integration review remediation | Android Full debug compile and supplier Live policy tests pass 10/10; Apple supplier recovery tests pass 2/2 | Durable source ownership now selects Android Live controls, the confirmed no-active path remains reachable, and Apple discovery continues through a cancellable low-frequency tail | Physical radios, background execution, signed installation, or supplier timing |
| Final supplier compatibility, pairing, revision, owner, picker, and archive review | Apple supplier lifecycle tests pass 49/49; Android supplier adapter/coordinator tests pass 75/75; complete Android Full passes 5,164 with seven intentional skips; complete macOS passes 2,336 with one intentional fixture skip; the unsigned Release iPhone graph embeds Watch, complications, and widgets | A singleton/raw step row cannot own the day, battery verification is sufficient for supplier registration, archive failure cannot destroy a credential, post-archive cleanup is restart-safe, approved warm revision drift rebinds durably, and model/peripheral substitution remains rejected | Signed installation, physical BLE, real revision callbacks, secure-store faults on devices, firmware activity classification, background execution, or physical step accuracy |
| Final protected-data cleanup lifecycle | Apple supplier lifecycle tests pass 51/51; exact-current unsigned generic iPhoneOS Release builds and embeds `NOOPWatch.app`, `NOOPWatchComplications.appex`, and `NOOPWidgets.appex` | A ledger unavailable before first unlock is retried on the protected-data edge, cleanup stops after success, and a failed unlock retry cannot create an unbounded observer loop | A physical device Keychain fault, signed install, background relaunch, or supplier hardware behavior |
| Final Android review remediation | Focused Full compile plus 76/76 source-coordinator, credential-store, active-device projection, and supplier-display cases pass. The complete Full wall passes 5,177 tests with seven intentional skips, builds the 54,399,693-byte debug APK, passes lint with zero errors, and compiles 207 instrumentation test classes. Independent final review reports no remaining correctness finding in the changed Android boundary. | Failed pending cleanup retries in-process and on foreground, authentication rejection survives process recreation for multiple devices, combined ledger/deletion failure archives the rejected source, stale active-source projections cannot cross a source-selection change, and supplier cards use only exact supplier connection/battery state | Physical encrypted-store recovery, Activity/OEM lifecycle timing, supplier BLE callbacks, installation, signed-device UI, hosted replacement checks, or protected integration |
| Post-hosted exact-head review remediation | Apple supplier lifecycle passes 56/56; Android Full source compiles and the affected source-coordinator plus step-integrity classes pass; the generic iPhone Simulator graph builds; 68 focused trust/required-CI/wrapper tests pass; required-CI validates all ten contexts and trusted-main self-verification passes | Rejected Apple credentials have a distinct durable retry path, Oura state ownership survives source switching, `Tools/local` cannot shadow Python runtime modules without owner review, and the wrapper-boundary test is both protected and required | Physical Keychain faults, Oura hardware callbacks, supplier firmware classification, hosted replacement checks, protected integration, or physical step accuracy |
| Final source-scope hosted closeout | Exact head `4bcaa17a1e61eba864c03b7f1a16284cc5550c19` passes all ten required contexts. Apple run `36233287879` passes macOS, the 28m44s iOS production shell, and `apple-ci-required`; Android run `36233287858` passes build/unit/lint/instrumentation compilation, both managed shells, and `android-ci-required`; package run `36233287831` and every policy workflow pass. | The exact pushed source-scoped cleanup and lexical wrapper quarantine compile and pass across the protected graph | Required non-author approval, protected-main integration, signed installation, physical BLE/background behavior, firmware classification, or step accuracy |

## Physical device and deployment

- Install/update action: no physical install; source-only Android Full APK and
  unsigned generic iPhoneOS Release app were built.
- Generalized device and OS class: local macOS host and source build graphs.
- Data-preservation result: no schema or migration. The repair removes only stale
  computed step values on exact affected days and preserves unrelated daily and
  imported evidence.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all `PHY-MET-001` through `PHY-MET-005` scenarios,
  including synchronized manual/video counts for walking and stationary wrist
  motion.

## Git and release state

- Changed paths in this final local slice: Apple rejected-credential cleanup
  and app wiring, Android source-construction ordering, release trust roots and
  workflow coverage, their focused regressions, and closeout operations
  records. Earlier PR changes remain as recorded above.
- Commits: implementation `db7de8e2571b1effd8278537d63bd7019b2b0d28`;
  review closeout `93d5ffed104d7e3b9f193c2af71c9dfb57d486c8`.
- Branch and remote state: PR `#17` implementation head
  `9474ffbb6021f186d7a381e53c6b9e20ce0f9a16` passes all ten required hosted
  contexts. Its first Apple attempt failed only the profile measurement
  re-entry assertion after the field retained the first of three batched
  keystrokes. The exact case passed six consecutive local executions, including
  five process-relaunched repetitions, and the unchanged hosted SHA then passed
  the complete iOS production shell plus `apple-ci-required`.
- Current replacement state: exact product-code head
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19` is pushed and hosted green across
  all ten required contexts. PR `#17` is mergeable and auto-merge is armed, but
  the requested non-author approval is still pending. Exact round-owned
  temporary output is removed. Normal protected merge, protected-main
  verification, physical BLE, supplier firmware classification, signed
  installation, background behavior, and synchronized step-accuracy validation
  remain.
- Repository visibility verified: not rechecked in this slice.
- Version/build impact: no version bump.
- Release or distribution impact: no release claim; physical metric validation
  remains required.

## Decisions

- Durable decision added or changed: classified locomotion evidence outranks
  raw wrist-motion ticks; heart rate is not gait evidence; current production
  paths reject fully unclassified windows while explicit compatibility analysis
  may still inspect the historical labelled estimate.
- Decision-log entry: none. This implements the existing motion-derived,
  source-aware metric contract without changing cloud authority or a public
  product promise.

## Open risks and honest limitations

- A firmware aggregate with no per-record evidence cannot be repaired reliably
  after ingestion.
- The existing activity class is itself device-derived and needs exact-hardware
  false-positive and true-positive validation.
- Legacy unclassified rows remain available only to explicit compatibility
  analysis; current daily and manual production paths do not publish them.
- A strict class gate can undercount if firmware emits missing or incorrect
  classes during true walking. That tradeoff is intentional until synchronized
  physical ground truth supports a more capable classifier.
- If firmware labels stationary wrist motion as `walk`/`run`, or exposes only a
  daily aggregate without per-record activity/raw-IMU evidence, application
  software cannot reliably reconstruct the false steps. That remains a firmware
  and synchronized physical-validation gate.
- Server-side formula authority remains behind the recorded D-059 migration
  gates; this round does not claim backend parity or cloud authority.

## Failed attempts and cleanup

- The first archive-first Android focused run left one concurrency fixture
  waiting because that fixture did not inject the newly required cleanup
  ledger. The fixture now injects it and proves authentication rejection waits
  until archive rollback completes; the 75-test combined supplier set passes.
- The first Apple focused run used adapter-level failure events and an
  adapter-only counter against the lower-level SDK fake. The tests now use the
  correct fake at each boundary; all 49 supplier lifecycle tests pass.
- The first complete macOS invocation requested a timeout above the bounded
  runner's supported maximum and was rejected before launch. The supported
  one-hour invocation completed 2,336 tests with one intentional skip.
- The first expanded warm-reconnect test placed one operation-count fixture in
  the adjacent success case, causing a Kotlin compile error. Moving the fixture
  into the model-substitution case produced the green 75-test supplier rerun
  and complete 5,164-test Full wall.
- Independent final review found that the first stale-value repair treated any
  observed counter with no retained count as destructive and wrote daily and
  series cleanup separately. That candidate was not pushed. The replacement
  distinguishes observed from authoritative evidence, preserves ambiguous
  history, and proves transaction rollback on both platforms.
- The first final focused Swift command was rejected before launch because the
  bounded runner label was omitted. The corrected invocation then exposed four
  test-helper calls using a nonexistent argument label; those fixtures were
  corrected and the 32-test focused wall passed.
- The first final WhoopStore compile rejected async reads inside XCTest
  autoclosures. Values are now awaited before assertions; the focused
  46-test set and complete 547-test wall pass.
- The first final Android compile exposed one mismatched Kotlin enum-case
  spelling in the new predicate. The existing case name is now used; the
  focused 58-test wall and complete 5,150-test Full wall pass.
- The final pre-commit source review found that Android stopped active-source
  fallback on a storage failure but swallowed the exception before the bounded
  presentation diagnostic could record it. The repository now propagates that
  failure without reading an older source; the app records the fixed-category
  failure and withholds only workout steps. Full Kotlin compilation and the
  focused ownership suite pass.
- The first final macOS wall executed 2,324 tests and found one stale assertion
  that still expected rejected stationary motion to erase prior step history.
  The corrected regression now pins the non-destructive policy; its focused
  rerun and the complete 2,324-test wall pass.
- The first complete Tools wall ran 365 tests with one intentional dependency
  skip. It found an Xcode-generated ignored
  `Vendor/NoopBandSDK/.swiftpm` directory, the same stale source-shape
  expectation, and the intentionally not-yet-refreshed terminology snapshot.
  The generated directory was exact-deleted and the two focused contract suites
  pass. After the reviewed terminology refresh and exact source-digest repin,
  the complete 365-test Tools wall passes with one intentional dependency skip.
- The first Tools invocation in this final slice used Homebrew's newly selected
  Python 3.14, which does not contain pytest, so zero tests ran. The exact wall
  was restarted with the installed Python 3.11/pytest 8.3.5 environment. It ran
  all 365 tests: 359 passed and six correctly stopped on the regenerated empty
  SDK `.swiftpm` cache plus the pending terminology refresh. Exact cache deletion
  and the protected SDK/trusted-control subset then passed 24/24. After the
  reviewed inventory refresh and digest repin, the complete wall passed 365/365.
- Exact hosted head `b45c67bf6186e238ee1e6f23422c2dc7aceec412`
  then failed only `test_repository_snapshot_is_current` in release-controls:
  the final review fixtures and operations wording added six classified legacy
  occurrences after the previous snapshot. The reviewed snapshot and digest
  correction was pushed as `fe616b5dc7a7ea51f345e5c940af38cab3612477`,
  whose complete hosted run passed. The current final-review candidate records
  18,454 occurrences across 1,628 path/category groups without broadening the
  active allowlist.
- The first root localization-parser invocation ran from the repository root
  and failed to import its sibling `i18n_audit` module. Running the suite from
  its owning `Tools/` directory passes all 50 tests.
- The first combined Android final-review run exposed a test-ordering defect:
  Kotlin evaluated a registry lookup argument before awaiting the pairing
  commit, so the fixture observed the old owner. Awaiting the committed device
  identifier before the comparison corrected the test without changing
  production behavior; the combined focused rerun passes 77/77.
- A later focused Apple day-owner rerun was refused by the bounded runner at the
  disk floor after the complete macOS wall had already covered the exact test
  on the same source. No floor override was used; the complete wall and the
  earlier focused 81-test run remain the applicable evidence.
- The first final 572-case repository wall failed six cases because Xcode had
  regenerated the ignored `Vendor/NoopBandSDK/.swiftpm` cache and the reviewed
  terminology inventory was stale after source, test, and operations changes.
  Exact cache deletion restored the protected SDK artifact shape. Review found
  18,484 classified occurrences across 1,628 path/category groups, zero
  forbidden mappings, and no active customer/core allowlist change.
- The next repository wall passed the SDK and terminology tests but failed
  three required-CI/trust cases because the regenerated inventory's SHA-256 was
  still pinned to the previous reviewed bytes. The exact zero-forbidden
  inventory digest was repinned without changing the enforcement rule. The
  final complete wall then passed 571 tests with one intentional dependency
  skip and two non-failing FastAPI deprecation warnings; direct release,
  required-CI, trust-root, calibration, terminology, health-claim,
  localization, operations, legal-inventory, private-data, and diff gates pass.
- The final broad wall was first invoked with the host Python 3.11 environment,
  which lacked `asyncpg`; collection stopped before product tests ran. A
  round-owned Python 3.11 virtual environment installed the pinned server
  development requirements and reran the complete repository/server/SDK wall.
  Its first run executed 1,231 cases and failed only on the regenerated empty
  SDK `.swiftpm` cache and the expected terminology ratchet/digest update.
  Exact cache deletion, review of all 30 new classified occurrences, and the
  two reviewed SHA-256 repins produced a 90/90 focused policy pass followed by
  1,017 passed, 214 declared skips, and 78 passed subtests with zero failures.
- The final replacement broad-wall invocation initially ran from the repository
  root without loading `server/pyproject.toml`. It completed 1,148 tests but
  correctly failed 25 async cases and errored 62 async fixtures because
  `asyncio_mode = "auto"` was not active; 153 environment-dependent cases
  skipped. No product code changed. A focused configured rerun passed all 25
  executable async cases and skipped the 62 PostgreSQL-only cases. The exact
  configured complete wall then passed 1,173 tests, skipped 215 declared
  optional/environment cases, and passed 78 subtests.
- The first final focused release-policy wall found only closeout drift: an
  empty Xcode-generated `Vendor/NoopBandSDK/.swiftpm` directory, one source-shape
  fixture that still required live HR before supplier registration, and the
  reviewed terminology inventory digest. The exact cache was deleted, the
  fixture was aligned to battery-confirmed registration with optional live HR,
  and the zero-forbidden inventory digest was repinned. The supplier
  artifact/app-slice subset passes 17/17 and the complete focused policy wall
  passes 137 tests plus 62 subtests.
- The first final calibration command omitted the required `check` subcommand,
  so no audit ran. The corrected command passed 12 metrics, 3 revisions,
  13 thresholds, and 16 guards.
- The first September 26 Apple engine regression compile used the detached
  scan's nonexistent `now` name. Replacing it with the already captured
  `actualNow` value preserved executor isolation; both partial-window
  preservation and continuous-day exact-clear orchestration tests then passed.
- The first final direct-wall command omitted the mandatory `--root` argument
  from trusted-main verification. Release controls and all ten required
  contexts passed before that invocation error. The corrected command ran the
  complete direct wall and passed without changing source.
- The final operations wording moved only historical inventory line numbers.
  A temporary snapshot retained 18,511 classified occurrences, 1,628 groups,
  zero forbidden mappings, and a byte-identical active allowlist. The reviewed
  historical inventory was regenerated and its exact digest repinned.
- The first post-documentation focused-policy invocation omitted the bounded
  runner's required timeout, so no tests started. The corrected invocation
  passed all 90 artifact, terminology, trust, required-CI, and release-control
  tests plus 54 subtests.
- A blanket ShellCheck invocation included two zsh visual-QA scripts and exited
  with ShellCheck's `SC1071` unsupported-shell result. All sh/bash scripts pass
  ShellCheck and `bash -n`; the two zsh scripts pass `zsh -n`.
- A focused Oura rerun was refused before launch because the Data volume had
  only 9.6 GiB free. The active-session-aware cleanup helper audited and then
  deleted 45 closed prior-day rollout files totaling 54,933,798,163 bytes while
  preserving the current day and every open resumed session. Free space
  returned to about 61 GiB; the apply manifest checksum is
  `6c01a82e00b6c02769a64af0e6973936138bc287eb5245291826e9a3b6f82513`.
- An exploratory replacement for the already-correct supplier live-retry path
  added unnecessary scheduler and diagnostic complexity. It was removed before
  commit. The retained bounded 2s/5s/15s restart plus 60s tail implementation
  passes its three focused regressions as part of the final 32-test Apple set.
- Exact round-owned DerivedData trees removed after evidence capture:
  `/tmp/noop-20260925-apple-focused-dd`,
  `/tmp/noop-20260925-ios-ui-post-review-dd`,
  `/tmp/noop-20260925-ios-release-post-review-dd`,
  `/tmp/noop-20260925-macos-full-wall-after-step-filter-dd`, and
  `/tmp/noop-20260925-ios-release-graph-after-step-filter-dd`.
  This final review also exact-deleted superseded generated trees
  `/tmp/noop-step-apple-orchestration-dd`,
  `/tmp/noop-step-ios-release-dd`, and `/tmp/noop-step-macos-full-dd`
  before the final Apple walls, recovering about 10 GiB without removing logs,
  source, simulator data, credentials, or user data.
  The obsolete duplicate
  `/tmp/noop-step-false-positive-20260925/ios-derived` was also exact-deleted
  before the final iPhone graph, recovering about 5.5 GiB. After the later
  2,330-test macOS wall and exact-current Release iPhone graph were recorded,
  `/tmp/noop-step-false-positive-20260925/review-apple-derived` was
  exact-deleted, recovering another 5.5 GiB. The bounded review logs remain
  until replacement hosted evidence is durable.
  The final generic iPhoneOS Release DerivedData tree was also exact-deleted
  after its success status and embedded-product evidence were durable,
  recovering about 3 GiB. The round-owned Python test environment remains only
  until exact-SHA hosted verification is durable. It is 127 MiB and will then
  be exact-deleted with the bounded review logs.
  No source, simulator data, credentials, health data, or unidentified cache
  was removed. Free Data-volume space was about 19 GiB after the final local
  controls.
- After the 2,336-test macOS wall and exact-current Release iPhone bundle
  contents were recorded, the exact regenerated
  `Strand-aijzjsbotbmojjcctaropcqoyjpv` DerivedData tree was deleted with
  `find -depth -delete`, reclaiming 4.4 GiB. No Xcode build process owned the
  tree. The bounded status and logs remain under the round-owned temporary
  directory until replacement hosted evidence is durable.
- The first protected-data regression compile failed only because the test
  double added a read counter without an explicit Swift `return`. The corrected
  test passed, then the complete supplier lifecycle class passed 51/51.
- The first exact replacement Apple run failed only
  `testProfileMeasurementsCanBeClearedAndRetyped`: XCTest reported the height
  field as `"1"` after asking the simulator to type `"183"`. The product source
  was unchanged because the exact test passed once locally, then 5/5 additional
  process-relaunched repetitions. A failed-jobs-only retry of run
  `36207653817` passed the complete iOS production shell and aggregate
  `apple-ci-required` context on the same exact implementation SHA.
- Two exact-current iPhone Release attempts stopped at the bounded runner's
  10 GiB disk floor; no floor override was used. One orphaned compiler owned by
  the stopped build was terminated by its exact process group. The incomplete
  DerivedData, two obsolete round-owned Apple DerivedData trees, active-worktree
  Gradle/Swift package outputs, global Xcode DerivedData, the global Gradle
  cache, and the SwiftPM cache were removed only after process/open-handle
  checks. Source, simulators, SDK inputs, credentials, screenshots, logs, and
  user data were preserved. The third bounded invocation succeeded and
  produced the verified embedded phone/Watch/complication/widget bundle.
- The current 3.5 GiB round-owned iPhone DerivedData is retained only until the
  replacement hosted evidence is durable; free Data-volume space was about
  13 GiB after the successful build.
- After exact head `4bcaa17a1` passed every required hosted context, final
  cleanup removed `/tmp/noop-step-source-scope-20260926`, repo-relative Android
  app/build/project-cache output, and the exact regenerated
  `Strand-aijzjsbotbmojjcctaropcqoyjpv` DerivedData directory. No build process
  or open file handle owned those paths. About 6.3 GiB was reclaimed and
  Data-volume free space increased to about 32 GiB. Source, SDK inputs,
  simulator data, credentials, user data, and unrelated caches were preserved.
- The first late-Android focused run stopped before Kotlin compilation because
  local dependency verification resolved two official Jackson 2.13.5 parent
  POMs that were not needed by the prior hosted cache path. Fresh Maven Central
  downloads were byte-identical to the local cache. A Gradle-generated
  verification pass resolved the graph without changing committed metadata,
  and the normal strict-verification rerun proceeded.
- The next focused run constrained the Kotlin compiler to 2 GiB and exhausted
  that heap during unrelated full-module IR lowering. The production-equivalent
  4 GiB in-process, one-worker rerun compiled the app and passed the earlier
  59/59 focused set. After the final cleanup-ownership and exact-device review
  fixes, the focused wall passed 76/76 and the same bounded profile completed
  the 5,177-test Full wall, 54,399,693-byte APK, lint with zero errors, and
  instrumentation-source compilation without a persistent daemon.
- Before the final Android wall, resource review found no active build process
  or open handle and only 6.8 GiB free. Exact deletion of superseded
  round-owned Apple DerivedData, prior Android build output, and Gradle project
  cache reclaimed about 27 GiB. Source, logs still needed for evidence,
  simulators, credentials, SDK inputs, and user data were preserved. The
  Android wall then regenerated only its current build output; free space
  remained about 32 GiB afterward.
- The final terminology inventory is regenerated only after this independent
  review record is durable. Its exact reviewed digest is then repinned before
  the complete Tools and direct policy walls run.

## September 26 independent review remediation

- A read-only independent review found five additional exact-source defects.
  No new step-filtering or health-claim defect was found.
- Protected release tooling now treats every importable Python file below the
  Tools execution roots, repository-root modules, and package initializers as
  owner-protected. This closes both standard-library and third-party dependency
  shadowing, including package initialization before the protected unittest
  suite. Focused trust tests include mixed-case, native-extension, package,
  startup-hook, and third-party dependency cases.
- The supplier wrapper boundary now recognizes Swift import attributes, access
  modifiers, scoped imports, semicolon-separated declarations, and qualified
  module references for every framework in the protected artifact manifest.
  Android package-family detection remains derived from the protected required-
  class inventory.
- If Apple cannot persist either authentication-rejection cleanup marker, it
  archives the supplier row before fallback selection. Archived supplier rows
  form a process-durable cleanup inventory, so a recreated reconciler retries
  credential deletion without making the rejected source activatable. The
  focused Apple lifecycle and registry suites pass 79/79.
- If Android fails while restarting the prior WHOOP transport after a post-
  teardown source-construction failure, it clears the tentative active identity.
  A later selection therefore re-enters targeting instead of hitting the same-
  identity no-op guard. The focused coordinator class compiles and passes.
- The first exact iPhone graph exposed a Swift 6 isolation warning from using a
  main-actor singleton in a default argument. The fallback parameter is now
  optional and the singleton is resolved inside the main-actor initializer.
  Focused Apple lifecycle/registry verification remains 79/79 and the final
  iPhone graph contains no copy of that warning.
- The prior macOS wall was cancelled after review edits because it no longer
  represented an exact candidate. The exact-current replacement passes 2,349
  tests with one intentional skip and zero failures. No stale invocation is
  counted as final evidence.
- The exact-current Android Full wall passes unit tests, APK assembly, lint,
  and instrumentation-source compilation in 73 tasks. The resulting
  `app-full-debug.apk` is 54,402,643 bytes. No persistent Gradle daemon remains.
- The exact-current generic iPhone Simulator graph succeeds and the built
  `NOOP Staging.app` embeds `NOOPWidgets.appex`, `NOOPWatch.app`, and
  `NOOPWatchComplications.appex` with the expected app-family bundle
  identifiers.
- The pre-closeout Tools wall passed 368 tests with one intentional dependency
  skip, and the direct release, required-CI, trust, calibration, terminology,
  localization, operations, health-claim, privacy-filename, legal-inventory,
  and diff gates passed. They are rerun after this final documentation and
  terminology snapshot so only exact replacement bytes count as final policy
  evidence.

## Next round

1. Capture the exact reporting band/firmware and a privacy-safe Steps test trace,
   then execute the physical validation matrix with synchronized manual counts.
   Include a timed head-washing/showering interval, ordinary dominant-hand
   washing motions, and a matched no-arm-motion hot-water interval so activity
   classification and step deltas can be separated from heart-rate elevation.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
