# Round: 2026-09-25 - Step motion false-positive rejection

## Status

- State: `implementation and review closeout committed locally with focused and complete local verification green; replacement push and hosted integration pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `4604fd53d15b459d0c2251da8e8697134bdb30e1`
- End implementation commit:
  `db7de8e2571b1effd8278537d63bd7019b2b0d28`
- Review-closeout commit:
  `93d5ffed104d7e3b9f193c2af71c9dfb57d486c8`
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
- Preserved the prior wrap-aware raw-motion estimate only for legacy windows
  where every activity class is absent. Existing data is not relabelled as a
  measured step count.
- Kept the same kernel for daily steps, Daily Effort's movement floor, and
  manual-workout strap ticks so those surfaces cannot disagree.
- Kept heart rate out of the gait gate. Slow walking remains eligible without a
  heart-rate rise, while bathing heat or stress cannot turn stationary wrist
  motion into locomotion merely by raising heart rate.
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

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: the motion-derived step estimate now
  rejects counter deltas explicitly classified as non-locomotion when class
  evidence exists. Rows with no class evidence remain a labelled legacy raw
  motion estimate.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: step filtering is an activity
  estimate, not a medical result. Heart rate is supporting wear/effort context,
  not a gait detector.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  opt-in Steps test trace will report bounded class-filter mode and kept/rejected
  delta counts without timestamps, identifiers, or raw samples.
- Why existing evidence is sufficient, or why new evidence is required: the
  production calculation is pure and synchronous; no new lifecycle operation
  exists. The existing trace must change because the prior trace would otherwise
  disagree with the filtered total.
- Existing evidence reused: `StepsEstimateEngine.rawCounterTrace`.
- New bounded events or operation spans: none; deterministic trace fields only.
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
| Focused Swift analytics | 45 tests, 0 failures | The 4,000-tick stationary fixture is rejected; mixed, unknown, invalid, legacy, wrap, gap, daily, and trace behavior is deterministic | Physical sensitivity or specificity |
| Focused Android analytics | 44 tests, 0 failures | Kotlin matches the Swift vectors and trace contract | OEM or physical-band behavior |
| Complete `StrandAnalytics` wall | 1,497 tests, 7 intentional private-data skips, 0 failures | The changed step kernel preserves the complete shared formula surface | App integration or physical accuracy |
| Complete Android Full wall | 5,121 tests, 7 intentional skips, 0 failures; APK, lint, and instrumentation-source compilation pass; APK SHA-256 `968d8ed32757b1ba81e0dffde66d85442a49e4211b39afe948ba908a02ae92a3` | The exact Full app, analytics integration, resources, and test sources compile together | Installation, background collection, or hardware callbacks |
| Apple rollback regression | First full wall exposed one stale failure-injection fixture; corrected focused case passes | The atomic registration failure restores the prior source and leaves no partial supplier row | A real secure-store, radio, or vendor callback failure |
| Complete macOS app wall | 2,317 tests, 1 intentional fixture skip, 0 failures | Shared Apple app, storage, source coordination, metrics, Watch/widget contracts, and accessibility metadata pass together | iPhone hardware, BLE, or signed distribution |
| Unsigned Release iOS graph | Build passes without source warnings; `NOOP.app`, `NOOPWatch.app`, `NOOPWatchComplications.appex`, and `NOOPWidgets.appex` are present | Phone, Watch, complication, widget, localization, and Release dependency graphs compile together | Signing, installation, haptics, notifications, or physical performance |
| Focused release-contract recovery | SDK artifact tests 9/9 and supplier app-slice tests 8/8 pass after exact generated-cache cleanup and atomic-contract update | The vendored SDK tree is exact and the source-shape gate follows the current transactional registration contract | Hosted execution or physical SDK behavior |
| Complete repository and direct gates | Complete Tools wall passes 365 tests with one intentional dependency skip; 9 release controls, 10 required contexts, trusted self-check, 12 metrics/3 revisions/13 thresholds/16 calibration guards, final terminology snapshot, distribution provenance, private-data, 1,310-file health-claims, full localization, 94 operations records, 50 parser tests, Actionlint, shell syntax, ShellCheck, changed-Python compilation, and diff hygiene pass | Current source satisfies the listed local release/privacy/claim/localization/evidence contracts | Hosted exact-SHA checks, protected integration, physical validation, or external approvals |
| Exact implementation hosted checks | Exact head `db7de8e2571b1effd8278537d63bd7019b2b0d28` passed 33 jobs with four intentional skips, including all ten protected contexts, Android, macOS, and iOS production-shell checks | The consolidated implementation builds and passes hosted policy/tests on the reviewed SHA | The later review-closeout commit until replacement hosted checks finish |
| PR review closeout | Apple focused set passes 32/32; Android Full compile and `SupplierDeviceCardPolicyTest` pass 7/7 | Oura ownership, supplier transient live restart, archived activation policy, non-supplier reactivation, and Android supplier presentation are covered on the local replacement head | Physical BLE, Compose instrumentation, or signed installation |

## Physical device and deployment

- Install/update action: no physical install; source-only Android Full APK and
  unsigned generic iPhoneOS Release app were built.
- Generalized device and OS class: local macOS host and source build graphs.
- Data-preservation result: no schema, migration, or retention change.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all `PHY-MET-001` through `PHY-MET-005` scenarios,
  including synchronized manual/video counts for walking and stationary wrist
  motion.

## Git and release state

- Changed paths: shared Apple/Android step counter, bounded trace, daily/manual
  integration comments, matching tests, the stale Apple transactional
  registration fixture, source-contract tests, supported-band first-run flow,
  Android archived-device action policy, terminology snapshots, and operations
  records.
- Commits: implementation `db7de8e2571b1effd8278537d63bd7019b2b0d28`;
  review closeout `93d5ffed104d7e3b9f193c2af71c9dfb57d486c8`.
- Branch and remote state: implementation commit is pushed on PR `#17`; the
  review-closeout commit and this record remain local pending one replacement
  push and exact-head hosted checks.
- Repository visibility verified: not rechecked in this slice.
- Version/build impact: no version bump.
- Release or distribution impact: no release claim; physical metric validation
  remains required.

## Decisions

- Durable decision added or changed: classified locomotion evidence outranks
  raw wrist-motion ticks when available; heart rate is not gait evidence; fully
  unclassified legacy windows retain the existing labelled estimate.
- Decision-log entry: none. This implements the existing motion-derived,
  source-aware metric contract without changing cloud authority or a public
  product promise.

## Open risks and honest limitations

- A firmware aggregate with no per-record evidence cannot be repaired reliably
  after ingestion.
- The existing activity class is itself device-derived and needs exact-hardware
  false-positive and true-positive validation.
- Legacy unclassified rows remain less trustworthy and must continue to be
  presented as motion-derived estimates.
- A strict class gate can undercount if firmware emits missing or incorrect
  classes during true walking. That tradeoff is intentional until synchronized
  physical ground truth supports a more capable classifier.
- Server-side formula authority remains behind the recorded D-059 migration
  gates; this round does not claim backend parity or cloud authority.

## Failed attempts and cleanup

- The first complete macOS rerun executed 2,317 tests and failed four assertions
  in one stale supplier-registration fixture. The fixture still expected the
  retired split add/activate compensation path, so its trigger did not reject
  the current atomic insert. The corrected test injects the real transaction
  failure, passes focused, and the complete wall then passes.
- The first complete Tools wall ran 365 tests with one intentional dependency
  skip. It found an Xcode-generated ignored
  `Vendor/NoopBandSDK/.swiftpm` directory, the same stale source-shape
  expectation, and the intentionally not-yet-refreshed terminology snapshot.
  The generated directory was exact-deleted and the two focused contract suites
  pass. After the reviewed terminology refresh and exact source-digest repin,
  the complete 365-test Tools wall passes with one intentional dependency skip.
- The first root localization-parser invocation ran from the repository root
  and failed to import its sibling `i18n_audit` module. Running the suite from
  its owning `Tools/` directory passes all 50 tests.
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
  No source, simulator data, credentials, health data, or unidentified cache
  was removed. Free Data-volume space returned to about 21 GiB.

## Next round

1. Capture the exact reporting band/firmware and a privacy-safe Steps test trace,
   then execute the physical validation matrix with synchronized manual counts.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
