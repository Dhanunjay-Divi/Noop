# Round: 2026-09-09 - Large-data scroll lag

## Status

- State: `implemented and locally verified; protected review and physical-device evidence pending`
- Owner: project team
- Branch: `codex/large-data-scroll-lag-20260909`
- Start commit: `812ac0615257596d7ec1690eb7a0f54bf0695f1d`
- End implementation commit: `80729acb`
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
  physical-device trace is available yet.
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
  historical snapshots remain revision-bound, and age/workout mutations
  invalidate the bank.
- Apple Today observes only the history-backfill boolean edge, preserves a
  populated same-day screen while bulk writes are active, and reloads
  automatically when backfill finishes. Day changes still load immediately.
- Android Today performs one resolved Rest-history read for both the selected
  score and sparkline, retains the compact day/value map across tab remounts,
  and filters day changes in memory.
- Android screen scaffolds publish drag/fling state to the liquid primitives.
  Decorative vessel, tube, and thread clocks pause while content is moving and
  resume from the same retained simulation state afterward.
- Existing bounded diagnostics now show the optimized Apple path directly:
  `today.liquid.load` distinguishes full, cache-restore, and backfill-deferred
  outcomes, while the existing scroll summary reports frame gaps without
  retaining health values or raw events.

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
- New bounded events or operation spans: `today.liquid.load` records only
  outcome class, selected scope, and bounded result counts. No row values,
  metric values, dates, identifiers, or payloads are recorded.
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
| Android production gate | Debug APK assembly, full unit suite, lint, and instrumentation-source compilation passed in 2m43s | Android source, cache, and animation-budget changes compile and pass repository tests | GPU pacing, OEM behavior, or physical scrolling |
| Apple focused regression | 9 tests passed after the final backfill-completion trigger fix | Exact cache aging, defer policy, invalidation wiring, and backfill reload remain mounted | Physical collection or real-device frame pacing |
| Apple simulator build and UI performance | iOS build passed; repeated navigation and Today scroll tests passed; scroll journey averaged 5.182 s wall time, 0.161 s CPU, and about 44.7 MB peak physical memory | The optimized simulator path is functional, nonblank, and emits no severe over-150 ms scroll hitch | Representative phone thermal, storage, BLE, or long-running performance |
| Apple bounded diagnostics | First full Liquid Today load recorded 1093/270 ms phases; same-state restores recorded 4 ms; worst observed frame gap was 69 ms | The cache removes repeated query work and the tested scroll stayed below the severe-hitch threshold | Performance on the tester's exact database and device |

## Physical device and deployment

- Install/update action: unsigned simulator builds only; no physical app
  container was changed.
- Generalized device and OS class: not provided.
- Data-preservation result: no physical app container touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: large existing database, active collection and
  backfill, low-storage, thermal, memory-pressure, background, and in-place
  upgrade checks on representative Apple and Android phones.

## Git and release state

- Changed paths: Apple Today repository/cache and tests, Android Today/liquid
  scaffolds and tests, plus this operations record.
- Commits: implementation `80729acb`; record follow-up is the pull-request
  head.
- Branch and remote state: pushed to
  `codex/large-data-scroll-lag-20260909`; protected pull request `#12` is open.
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

## Next round

1. Complete protected review and merge.
2. Collect one user-reviewed shake report from an affected physical phone and
   run the large existing-database, active-backfill, low-storage, thermal,
   memory-pressure, and in-place-upgrade device matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
