# Round: 2026-09-09 - Large-data scroll lag

## Status

- State: `implemented and completely locally verified after Safety rebase; protected review and physical-device evidence pending`
- Owner: project team
- Branch: `codex/large-data-scroll-lag-20260909`
- Start commit: `812ac0615257596d7ec1690eb7a0f54bf0695f1d`
- End implementation commit: final protected pull-request head
- Record commit or PR: protected pull request `#12`

## Objective

Investigate the report that a fresh pull of current `main` still feels laggy,
especially while scrolling after the local health database has grown. Reproduce
the relevant storage and concurrent-ingestion pressure with deterministic
synthetic data, profile before changing retention, indexes, compaction, or
query architecture, fix measured supplier-independent bottlenecks on Apple and
Android where applicable, and leave physical-phone conclusions explicit.

## Scope

### In scope

- Benchmark current database reads, writes, first paint, scrolling, memory, and
  WAL behavior against the repository's large synthetic histories.
- Attribute high-volume storage by stream and distinguish file size, active
  ingestion contention, main-thread work, and rendering cost.
- Preserve local-first collection, history, metrics, export, and user-authored
  records.
- Reuse or improve bounded app-report evidence for screen hitches, database
  operations, memory, thermal state, and storage footprint.
- Add focused regressions and run the affected Apple and Android build gates.

### Non-goals

- Inspect or commit a user's real health database.
- Infer physical-device smoothness, BLE survival, battery impact, or thermal
  behavior from a simulator or host benchmark.
- Enable default health-data upload, delete unverified history, or make core
  behavior depend on NOOP+.
- Change physiological formulas or claim clinical validation.

## Starting evidence

- Reproduction or observed symptom: a tester pulled current source on
  2026-09-08 and still described the app as laggy. No reviewed shake report or
  physical-device trace is available yet. The protected performance work was
  still only on pull request `#12`, so that pull of `main` did not contain it.
- Relevant source/device/OS/firmware class: iPhone shell and shared GRDB store;
  Android Room parity applies to any changed retention or persistence
  contract. Exact phone, OS, database composition, thermal state, active
  backfill state, and screen are unknown.
- Existing tests, logs, exports, screenshots, or documents: the protected
  release round generated 10-, 30-, 90-, and 365-day synthetic histories; the
  retained 365-day profile is about 444 MB. Existing diagnostics record bounded
  scroll summaries, severe hitches, main-thread stalls, operation durations,
  process memory, thermal state, and database footprint. The current simulator
  scroll journey passes only on its small fixture.
- Unknowns that must remain unknown until measured: whether the tester saw
  render cost, a long query, active ingestion/backfill contention, low storage,
  thermal throttling, memory pressure, or an unrelated screen defect.

## Delivered

- A deterministic 30-day high-rate fixture inserted 4,207,350 rows and
  produced a 440.6 MB checkpointed database. The write pass took 28.5 seconds;
  temporary backup/restore space peaked near 1.32 GB.
- Database size by itself did not explain interactive lag. Calendar-day,
  selected-day, and trend reads stayed below 0.4 ms; a five-minute HR bucket
  read took 31.45 ms and the ingestion fingerprint took 10.62 ms. The one
  intentionally broad storage-attribution query took 1.81 seconds.
- Concurrent reads during one million additional writes rose from about 30 ms
  at rest to an 82 ms mean and 96 ms maximum. The measured pressure is active
  ingestion/backfill contention plus repeated screen work, not a justification
  to delete retained user history.
- Apple Liquid Today now banks one exact revision/day/profile query snapshot on
  the long-lived repository. A same-state tab return restores it without
  reopening the same history, current-day snapshots expire after 120 seconds,
  historical snapshots remain revision-bound but expire after five minutes so
  a swallowed store/open failure cannot bank an incomplete historical view
  indefinitely, and age/workout mutations invalidate the bank. The request key
  now also distinguishes a live current-day window from a historical full-day
  window, so an equal calendar key cannot restore data with the wrong time
  boundary.
- Apple snapshots are also scoped to the active device. Adopting another device
  clears the bank, publishes the device change to the view task identity, and
  prevents values from the prior device from being restored.
- Apple Today observes only the history-backfill boolean edge, preserves a
  populated same-day screen while bulk writes are active, and reloads
  automatically when backfill finishes. The completion edge clears the bank
  before reloading so pre-backfill HR cannot be restored. Day changes still
  load immediately.
- Apple Classic Today, Liquid Today, and Sleep now hold their query boundary
  through the short false edges between continuation sessions. Cold mounts do
  not run broad reads against active writes; same-device cached content stays
  visible, and one forced catch-up load runs after a two-second quiet edge.
- A final cache-ownership audit found Classic Today's task and two retained
  banks were still revision/day keyed but not device keyed. The task now
  includes the active device, device adoption synchronously invalidates both
  banks, cache entries carry their owner, and both day-scoped and history-wide
  loads compute into locals before publishing one complete same-device,
  same-revision snapshot. Day-specific Stress moved into the day-scoped bank,
  preventing a historical day navigation from restoring another day's score.
- The overnight Sleep Stress cards on Apple and Android now obey the same
  history-write quiet gate as their parent Sleep loads. They keep the last
  coherent result visible, avoid two 200,000-row reads during active offload,
  run HR and R-R reads concurrently once quiet, preserve structured
  cancellation, and reject cross-device or superseded publication.
- A fresh cold-mount audit closed the remaining Apple ordering race. AppModel
  now mirrors only the deduplicated history-write boolean onto the already
  observed Repository before screens mount. Classic Today, Liquid Today, and
  Sleep combine that synchronous edge with their local two-second quiet hold,
  so their first task cannot start broad reads before the leaf bridge appears,
  and the heavy roots still do not observe sensor-rate LiveState publications.
- Android parity was rechecked rather than changed speculatively: its retained
  ViewModel already exposes an eagerly seeded, deduplicated boolean StateFlow,
  and Today/Sleep initialize the same quiet gate from that current value.
- Android Today performs one resolved Rest-history read for both the selected
  score and sparkline, retains the compact day/value map across tab remounts,
  keys it to the daily data, active device, and metric-series revision, and
  filters day changes in memory. Failed reads remain retryable rather than
  being cached as a valid empty history.
- Android device-data deletion now uses the conservative metric invalidation
  path. It advances both the general and Rest revisions, so deleting a
  metric-series-only source cannot restore stale Sleep/Today Rest history from
  the retained ViewModel cache.
- The matching Apple path was re-audited after that review finding. It already
  awaits the off-main deletion, refreshes the repository, and explicitly clears
  retained Today/Liquid history through `noteAgeMetricsChanged()`, so no Apple
  code change was required for parity.
- Android Today now treats an active history offload as a database write
  boundary: it keeps the last coherent dashboard visible, cancels and defers
  history-wide card, calorie, weight, step, Rest, SpO2, provenance, Effort, and
  footer reads, then reloads once after the backfill edge falls. Best-effort
  reads rethrow structured cancellation and reject cross-device publication.
- Android uses the same two-second history-query quiet edge for Today and
  Sleep. The Today HR card no longer re-queries on every persisted chunk; it
  loads HR, sleep, and workouts concurrently once the burst is quiet, publishes
  one current-device snapshot, and records a bounded `today.hr_trend_load`
  operation.
- Android now exposes separate stable dashboard-live and exact history-progress
  projections. Today observes only connection, battery, and the boolean
  history-write edge; exact batches, rows, newest date, and elapsed time remain
  visible inside isolated header, sync-note, and data-source leaves. Sleep and
  Intelligence use the same leaf boundary, so a history batch cannot rebuild
  their full scroll roots.
- Android screen scaffolds publish drag/fling state to the liquid primitives.
  Decorative vessel, tube, and thread clocks pause while content is moving and
  resume from the same retained simulation state afterward.
- The remaining card-sized time-of-day backdrops on Apple Sleep and Android
  Health are now static. Their wash, stars, and card contrast remain unchanged,
  while the separate 20 fps decorative drift no longer competes with scrolling.
- Apple and Android status pulses, band-sync sweeps, and Daily Signal waveform
  clocks now honor the same drag/fling interaction gate as the liquid
  primitives. The Apple gate is published through StrandDesign as well, so
  every shared pulsing `StatePill` yields rather than only Today's custom
  header light. Their steady semantic state remains visible while scrolling
  owns the frame budget.
- A fresh wiring audit found that the Apple consumers above were reading the
  shared interaction key while the standard and liquid scroll roots still left
  its default `false` value in place. Both Apple roots now publish an
  edge-coalesced drag/deceleration state: high-frequency offsets stay in
  reference storage, one settle loop observes the latest monotonic movement
  timestamp instead of canceling and recreating a task per frame, the
  environment changes only at movement start and after a 180 ms settle edge,
  and retained children finally receive the intended motion budget. The
  matching Android scaffolds already published their real
  `isScrollInProgress` state.
- A fresh simulator run temporarily replaced the installed app's database with
  a verified 294.9 MB production-schema fixture for the same synthetic device
  used by the UI harness. That store contained 2,376,000 HR rows and 864,000
  R-R rows. Five Today up/down scroll iterations passed; the original simulator
  database was restored afterward with SQLite integrity `ok`.
- The Health live-heart-rate trace no longer owns an idle one-second clock on
  either platform. Its sampler exists only after the wearer explicitly starts
  Live HR, pauses while a drag/fling owns the frame budget, leaves the last
  truthful trace visible, and resumes after interaction settles.
- Apple Health exposes each expensive history section as its own lazy row, while
  Android Health collects only a distinct connection boolean at the screen root.
  Sensor-rate HR/R-R packets therefore update the live leaf without rebuilding
  the query-heavy Health surface.
- Apple and Android Sleep collect only a deduplicated history-sync projection at
  the root, start independent session, timing, confidence, evidence, and metric
  reads concurrently, and replace one motion query per sleep block with bounded
  batched reads. Each platform now publishes sessions, learned timing, motion,
  confidence, and evidence only as a coherent current-device snapshot; an
  active backfill cancels and defers these history reads until its completion
  edge. Android motion batches read the active-plus-canonical computed-source
  union in active-first order, so re-pairing a band does not orphan earlier
  canonical motion evidence. Android has a dedicated Rest-data revision
  covering every Sleep/Today series and daily-score mutation.
- Apple and Android Stress read the active-plus-canonical HR/R-R union, perform
  deterministic daytime analysis off the UI executor, propagate cancellation,
  and reject superseded or cross-device results before publication.
- Apple and Android Workouts defer the historical recovery trend until its lazy
  section mounts, preserve cancellation through each HR query, and reject stale
  device results. Android transfers the long recovery load to the retained
  screen scope after that first lazy mount, so scrolling the 1dp placeholder out
  of composition no longer cancels a trend that is still loading. Apple
  auto-workout detection also starts HR, motion, and saved span reads together
  and performs dense preprocessing off the main actor.
- Every new cache and history task is device-owned. Android observes the
  selected-device flow directly and scopes Today card/footer/Rest caches, Sleep,
  Stress, and Workouts work to that immutable device snapshot; Apple includes the
  published repository device in Today, Sleep, and Workouts task identities.
- Android Vital detail now captures the selected device before its multi-series
  read, checks coroutine cancellation, and rejects publication if the active
  strap changed while the read was suspended.
- Existing bounded diagnostics now show the optimized Apple path directly:
  `today.liquid.load` distinguishes full, cache-restore, and backfill-deferred
  outcomes. Android `today.rest_composite_load` distinguishes success,
  cache-restore, and failure with a bounded result count. Sleep, Stress,
  Workouts recovery, and Apple auto-detection add bounded operation spans and
  categorical result-size buckets. The existing scroll summary reports frame
  gaps without retaining health values or raw events.
- The post-Safety fresh lifecycle review found three Android realtime-HR
  surfaces whose `DisposableEffect` cleanup re-read mutable Compose state.
  Tapping Stop could therefore dispose the old true-keyed effect after the
  state had already become false and skip its release, leaving the
  battery-intensive stream leased. Health, Live, and spot-HRV capture now
  capture immutable effect-local ownership and release exactly the lease that
  effect acquired.
- The same ownership review found the strength guide video and GIF cleanup
  closures could target a newly assigned player or animation instead of the
  instance being disposed. Both effects now key to and capture the exact owned
  resource, preventing recomposition from releasing the replacement player or
  stopping the replacement animation.
- Android now records the low-frequency `realtime_hr.lease` lifecycle boundary
  in the user-reviewed app report. It stores only the fixed action and
  transition, foreground and transport booleans, and a zero/one/multiple lease
  bucket. It records no heart rate, sensor row, timestamp, device identifier,
  user content, or raw count.
- The first post-rebase iOS build used the temporary worktree's stale generated
  Xcode project and could not resolve Firebase Messaging. Regenerating from the
  already-correct `project.yml` restored the declared dependency; the complete
  unsigned iOS graph then built. No generated project file is committed.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none. Detailed history, unverified rows,
  failed imports, and user-authored records remain intact.
- Source/provenance or formula impact: none planned.
- Permissions/network disclosure impact: none planned.
- Health/medical claim impact and limitations: performance work does not
  validate a metric or medical behavior.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `ui.scroll.summary`, `ui.scroll.severe_hitch`, main-thread watchdog,
  `repository.refresh`, analysis/database operation spans, and bounded resource
  snapshots.
- Why existing evidence is sufficient, or why new evidence is required:
  existing evidence can correlate screen, frame gaps, database size, memory,
  power, thermal state, and overlapping repository work. Profiling will decide
  whether a missing bounded operation boundary remains.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, shake
  report review flow, and synthetic history harness.
- New bounded events or operation spans: `today.liquid.load`,
  `today.rest_composite_load`, `sleep.history_load`,
  `sleep.history_snapshot_load`,
  `sleep.history_metrics_load`, `stress.daytime_analysis`,
  `workouts.recovery_trend_load`, and `workouts.auto_detect_scan` record only
  outcome class, selected scope where already applicable, and bounded result
  counts. The retained Android recovery load distinguishes completed, canceled,
  superseded, and failed outcomes. `realtime_hr.lease` adds only fixed lifecycle
  categories, booleans, and a zero/one/multiple ownership bucket. No row values,
  metric values, dates, identifiers, exception messages, raw counts, or
  payloads are recorded.
- Redaction, retention, and high-frequency controls: no sensor values, rows,
  identifiers, payloads, or free-form content; summaries remain throttled and
  local until a user reviews and shares them.
- Cross-platform/backend correlation: no backend correlation is required for a
  local scroll path; any storage-contract change must remain cross-platform.
- Remaining blind spots: no physical report, OS signpost trace, energy log, or
  real-device thermal/background evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source preflight | Decoded per-second history is durable; managed pruning is explicit and validation-gated; existing scroll diagnostics are bounded | Current contracts and instrumentation are understood before edits | The reported tester root cause |
| 30-day high-rate synthetic fixture | 4,207,350 rows; 440.6 MB database; 1.32 GB temporary peak | Current schema can hold a phone-sized dense local history and supports exact size attribution | Physical-phone memory, flash, thermal, or background behavior |
| Read benchmark | Daily/trend reads below 0.4 ms; HR buckets 31.45 ms; fingerprint 10.62 ms; storage attribution 1.81 s | Ordinary indexed history reads remain bounded at this size and the broad diagnostic read is identifiable | Smoothness while a real BLE stream and OS services compete |
| Concurrent write benchmark | About 82 ms mean and 96 ms maximum reads during one-million-row writes versus about 30 ms at rest | Active ingestion creates measurable contention even though the database remains readable | A specific tester's lag without their reviewed report |
| Android production gate | Debug APK assembly, 4,144 tests with zero failures or errors and 7 skips, lint with zero errors, and instrumentation-source compilation passed after the final hosted-review fixes in 3m14s | Android source, cache, retry, diagnostics, cancellation, device-switch, query-gate, lazy-job lifetime, and animation-budget changes compile and pass repository tests | GPU pacing, OEM behavior, or physical scrolling |
| Backfill-contention follow-up | Focused Android compile/tests passed after the final quiet-edge, HR-card, and sync-leaf changes. The Apple app compiled and 18 retained-screen/Liquid-Today contracts passed | Query-heavy Today/Sleep work now defers through continuation gaps, Android no longer reloads the HR card or full Today/Sleep/Intelligence roots per chunk, cancellation remains structured, and cross-device partial snapshots are rejected | Physical frame pacing during a real band offload |
| Apple focused regression | The final passes ran 30 performance/model tests, 10 device-ownership and sleep-decode tests, and 10 final Liquid Today cache tests, with zero failures | Exact cache aging, defer policy, device invalidation, cancellation, off-main analysis, and sleep decoding remain mounted | Physical collection or real-device frame pacing |
| Apple simulator build and UI performance | The exact review-fix iOS build passed; repeated five-tab navigation passed in 81.637 s and Today scroll passed with a 5.213 s average measured window, 0.180 s CPU, and 41,375 KB peak app memory | The optimized simulator path is functional, nonblank, and emits no severe over-150 ms scroll hitch | Representative phone thermal, storage, BLE, or long-running performance |
| Apple bounded diagnostics | First full Liquid Today load recorded 1093/270 ms phases; same-state restores recorded 4 ms; worst observed frame gap was 69 ms | The cache removes repeated query work and the tested scroll stayed below the severe-hitch threshold | Performance on the tester's exact database and device |
| Repository policy matrix | 222 Tools tests passed; operations records, terminology, required CI, localization, health claims, release controls, calibration parity, legal/distribution, private-data, shell syntax, and shellcheck gates all passed | The exact local branch preserves repository release, privacy, terminology, and evidence contracts | Hosted checks and protected review on the pushed exact head |
| Hosted release-control diagnosis | The first pull-request run failed only because the fail-closed terminology inventory had not yet been regenerated; the final reviewed snapshot records 17,356 classified occurrences, no forbidden mapping, and 13 fewer classified legacy occurrences overall. The active ratchet only shrinks, removing eight core occurrences from the optimized Android Today screen | The performance change introduces no forbidden terminology mapping or active allowlist expansion | The rebased exact head still requires a green hosted rerun |
| Exact-head automated and fresh review | The initial four hosted cache-lifecycle findings were reproduced and corrected: Android metric revision, Android failed-read retry, Apple device identity, and Apple post-backfill invalidation. A later hosted pass found three more concrete defects: re-paired Android Sleep motion read only the active computed source, historical Apple Today failures could remain cached forever, and Android Workouts recovery was owned by a disposable lazy row. The next exact-head review identified that device-data deletion advanced only the age/general revision and could retain deleted Rest history. The branch now reads the active-plus-canonical motion union, age-bounds historical cache recovery, retains the recovery job at screen lifetime, and conservatively advances the Rest revision after device-data deletion. The fresh local pass also removed Compose `StateFlow.value` reads from composition, made Health history queries observe the selected Android device, and made Apple auto-workout scans cancel and reject cross-device results | The final local patch closes concrete stale-data, retry, lazy-lifetime, cancellation, and cross-device publication defects before protected merge | A clean review and hosted checks on the rebased exact head |
| Device-data deletion regression | `RestDataVersionPolicyTest` and `RuntimePerformanceContractTest` passed in 17 seconds after the exact-head review fix. The first invocation failed before compilation because this temporary worktree lacked its ignored `local.properties`; the rerun supplied the known SDK through `ANDROID_HOME` | The conservative repository notifier advances both revisions without a DAO read, and the deletion path is pinned to that notifier | Room deletion behavior or a physical-device cache remount beyond the covered source contract |
| Decorative-atmosphere follow-up | Android `HealthScreenPerformanceTest` and `RetainedScreenPerformanceTest` passed in 17 seconds; Apple compiled and ran 11 Health/retained-screen performance contracts with zero failures | The remaining Apple Sleep and Android Health card atmospheres are pinned static and cannot consume a separate 20 fps clock while their lists scroll | Physical GPU timing or the tester's exact phone |
| Scroll-interaction clock follow-up | Android compiled and ran 22 retained-screen, Health, and frame-pacer contracts with zero failures in 23 seconds. After the shared status-pill follow-up, all 52 StrandDesign tests and 22 Apple retained-screen, Health, and Liquid Today contracts passed with zero failures | Connection/status pulses, band-sync sweeps, and Daily Signal waveforms stop their decorative clocks while drag or fling owns the frame budget on both platforms; every shared Apple `StatePill` receives the shell gate | Physical GPU timing, hidden OS work, or the tester's exact phone |
| Apple interaction-wiring audit | The standard Apple scaffold and liquid Today now publish the shared interaction environment through an edge-coalesced offset tracker; the Android Health sampler uses the existing Compose interaction local. The production-flavor Android focused suite passed in 30 seconds, and the Apple app compiled and ran 15 Health/retained-screen contracts with zero failures. A follow-up no-churn audit replaced the first scheduler-sensitive lifecycle assertion with a pure latest-movement timing-policy test; all 13 focused retained-screen contracts then passed | Shared Apple motion consumers now receive a real drag/deceleration signal rather than the environment default, one settle task serves the full gesture instead of being recreated per frame, and Health has no one-second sampling clock while paused or scrolling on either platform | Physical touch latency, GPU pacing, or the tester's exact phone |
| Large-store Apple simulator scroll | A verified 294.9 MB store with 2,376,000 active-device HR rows and 864,000 R-R rows was swapped into the installed iPhone 17 Pro simulator. `testTodayScrollPerformance` passed five up/down iterations with a 5.188 s average automation window, 0.167 s average app CPU time, and about 35.3 MB peak physical memory. The original 1.10 MB database was restored with integrity `ok` | The optimized Today path remains functional and bounded when the same active device owns a phone-sized production-schema store | Physical GPU pacing, thermal behavior, flash latency, active BLE ingestion, or the affected tester's phone |
| Cold-mount history-write gate | The complete changed Apple graph compiled and 25 focused retained-screen/Liquid Today tests passed, including a runtime publisher regression proving only the initial value and true/false edges publish | A screen opened during an already-active history write sees the block synchronously, retains the two-second quiet release, and avoids sensor-rate root invalidation | Physical frame pacing during a real band offload |
| Final device/cache audit | The macOS app compiled and 27 Liquid Today/retained-screen tests passed with zero failures. Android's production flavor compiled and 16 retained-screen/Health tests passed with zero failures | Current-vs-historical Liquid keys are distinct; Classic Today publishes atomic device-owned snapshots; overnight Sleep Stress waits for the quiet edge; Android Vital detail rejects an old-device result | Physical-phone frame pacing, active BLE/offload behavior, or the affected tester's exact database |
| Old Android hosted production-shell run | Compilation and packaging completed, but the managed device task was terminated with exit 143 at the workflow's 900-second bound before any instrumentation result was emitted | The old failure was a bounded emulator/test-infrastructure timeout rather than a product assertion | The rebased exact head still requires a completed hosted production-shell run |
| Final repository policy matrix | `git diff --check`; 49 operations records; terminology and active-use ratchets; 5 conditional, 5 universal, and 10 required CI contexts; private-data guard; i18n diff audit; 1,195-file health-claims scan; 12-metric/3-revision/13-threshold/16-guard calibration parity; 9 release controls; 230-component/3-container legal inventory; distribution provenance; and all 227 Tools tests passed. The final snapshot contains 17,367 classified occurrences across 1,511 groups, zero forbidden mappings, and no active-allowlist expansion | The exact documented source preserves repository release, privacy, localization, terminology, calibration, evidence, and distribution contracts | Hosted exact-head checks and physical-device behavior |
| Non-gating broad ShellCheck probe | `bash -n Tools/*.sh` passed. A broader `shellcheck Tools/*.sh` command returned existing warnings and rejected two zsh-only visual-QA scripts as unsupported; no shell file changed in this round and this broad command is not a required repository gate | The changed patch introduced no shell syntax surface | Existing repository-wide shell lint debt outside this performance change |
| Post-rebase lifecycle review | Health, Live, and spot-HRV use immutable effect-local realtime-HR ownership; strength video and GIF disposal capture the exact player/animation; focused production-flavor contracts passed | Stop/navigation and media replacement can no longer skip the owned release or dispose a newly installed resource | Physical transport timing, battery drain, and exercise-media decoder behavior on an OEM phone |
| Final Android local production lane | 4,175 JVM tests passed with zero failures or errors and 7 skips; APK assembly, lint, and instrumentation-source compilation passed in 2m55s after the bounded lease event was added | The exact Android source compiles, packages, preserves diagnostics privacy contracts, and passes its complete local unit/lint gate | OEM frame pacing, BLE, background survival, and physical battery impact |
| Final Android API 35 managed device | 53 production-shell tests passed with zero failures and 2 expected private-pilot skips in 44s under the repository's 900-second bound. The first invocation failed before provisioning because the SDK environment was omitted; the corrected rerun and final exact-source rerun both passed | The app shell, migrations, storage reconciliation, body-map multi-selection, switch styling, and report-review surface execute on a managed Android device | Real-band transport, OEM process policy, physical scrolling, haptics, location, or battery |
| Final Apple local production lanes | The regenerated unsigned iOS graph built; the macOS scheme passed 1,698 tests with zero failures and 1 expected skip; the iPhone 17 Pro simulator production shell passed 35 tests with zero failures and 1 expected skip in 611.6s | The exact Apple source and generated dependency graph compile, the shared suite passes, and production-shell journeys execute on iOS 26.5 simulator | Physical iPhone frame pacing, BLE/background survival, energy, thermal behavior, or signing |

## Physical device and deployment

- Install/update action: unsigned iOS simulator build/test and Android API 35
  managed-device install/test only; no physical app container was changed.
- Generalized device and OS class: iPhone 17 Pro simulator on iOS 26.5 and the
  repository's Pixel 2 API 35 managed virtual device.
- Data-preservation result: the simulator database was replaced only with
  deterministic synthetic history and the original database was restored with
  integrity `ok`; no physical app container was touched.
- BLE/background/haptic/battery scenarios exercised: not run; simulator shell
  and persistence journeys are not hardware evidence.
- Unrun hardware gates: large existing database, active collection and
  backfill, low-storage, thermal, memory-pressure, background, and in-place
  upgrade checks on representative Apple and Android phones.

## Git and release state

- Changed paths: Apple Today, Health, Sleep, Stress, Workouts, repository/cache,
  diagnostics, and tests; Android Today, Health, Sleep, Stress, Workouts,
  repository/Room, liquid scaffolds, realtime-HR ownership, strength-media
  ownership, diagnostics, and tests; plus this operations record.
- Commits: the implementation chain was rebased onto Safety `main` and ends at
  `0237bdef` before this final lifecycle/observability closeout; the closeout is
  the final protected pull-request head.
- Branch and remote state: local rebased branch
  `codex/large-data-scroll-lag-20260909`; protected pull request `#12` remains
  open and requires a force-with-lease update to replace its pre-rebase head.
- Repository visibility verified: not repeated.
- Version/build impact: no version change.
- Release or distribution impact: none until reviewed and merged.

## Decisions

- Durable decision added or changed: local history is not pruned merely because
  the database is large. Interactive work is reduced at screen and animation
  boundaries first, while retention changes remain evidence- and
  policy-gated.
- Decision-log entry: this round record.

## Open risks and honest limitations

- A simulator or host benchmark can identify software bottlenecks but cannot
  close physical smoothness, collection survival, thermal, or battery gates.
- Database size alone was not the measured root cause. A reviewed app report
  from the affected phone is still required to distinguish any remaining
  screen, ingestion, storage-pressure, thermal, or OS-suspension problem.
- The 1.32 GB temporary restore peak remains too high to treat a low-storage
  phone as proven; representative in-place restore and low-storage tests remain
  release gates.
- Hosted checks and exact-head review still apply to the final pushed commit.
- The local API 35 and iOS simulator results do not replace the representative
  physical-phone matrix or the affected user's reviewed report.

## Next round

1. Push the rebased exact head, complete protected review/checks, and merge.
2. Collect one user-reviewed shake report from an affected physical phone and
   run the large existing-database, active-backfill, low-storage, thermal,
   memory-pressure, and in-place-upgrade device matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
