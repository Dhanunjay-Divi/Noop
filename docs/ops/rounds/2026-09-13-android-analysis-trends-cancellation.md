# Round: 2026-09-13 - Android analysis and Trends cancellation closeout

## Status

- State: `completed locally`
- Owner: project team
- Branch: `codex/pr15-android-performance-cancellation-20260913`
- Start commit: `0aa7c86c2350e4bc3596faac994d7865a37d1660`
- End implementation commit: local commit containing this record
- Record commit or PR: pull request `#15`; local follow-up commit only

## Objective

Close two Android performance findings without changing metric formulas or UI
presentation:

1. A dirty range whose newest timestamp is later than the current-day 18:00
   scoring boundary must not trigger the same full 21-day pass every 15 minutes.
   Unsupported late-evening input must remain durably pending until the next
   local-day window can evaluate it.
2. Trends aggregate and weekly-digest CPU loops must observe cancellation from
   their `withTimeout` worker so the 12-second timeout can complete promptly.

## Scope

### In scope

- Android analysis-window planning and its two runtime callers.
- Android Trends timeout/cancellation context.
- Focused JVM regression coverage and bounded operational evidence.

### Non-goals

- Metric, sleep-stage, Recovery, Effort, or digest formula changes.
- Apple changes, UI redesign, schema migration, BLE behavior, or deployment.

## Starting evidence

- A recent pass advertises coverage only through local 18:00. A claim ending
  after that boundary cannot advance, while both runtime callers still execute
  the full plan.
- Both Trends CPU paths capture `currentCoroutineContext()` before
  `withTimeout`, so their cancellation callbacks observe the parent
  `LaunchedEffect` rather than the timed worker.
- Relevant source/device/OS class: Android source and JVM tests; no physical
  device required for these deterministic coroutine/planning contracts.
- Unknowns that must remain unknown until measured: physical-device scheduling,
  thermal behavior, and OEM process lifetime.

## Delivered

- Added an explicit deferred analysis plan for claims whose newest affected
  timestamp is beyond the recent pass's actual evaluable coverage.
- Kept deferred generations durable and unacknowledged until the next local-day
  window can evaluate their newest edge.
- Kept formula/repair work independent: it can complete its requested window
  once without claiming unsupported late input, after which ordinary ticks
  defer instead of repeating a capped 21-day pass.
- Applied the plan in both the foreground 15-minute loop and the post-backfill
  worker. The foreground path becomes a cheap gate/plan check; the durable
  post-backfill revision waits cancellation-safely and replans at the next
  local-day boundary.
- Bound both Trends CPU cancellation callbacks to the coroutine executing
  inside `withTimeout` and `Dispatchers.Default`, covering snapshot and weekly
  digest preparation.
- Added focused planning, durable acknowledgement, caller-contract, and real
  CPU-loop timeout regressions.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: late-evening dirty generations remain durable
  rather than being falsely acknowledged.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Existing analysis and Trends operation evidence retains fixed, bounded
  outcome categories.
- Deferred analysis uses a fixed reason token only; no timestamp, device
  identifier, sensor value, or exception message is recorded.
- Trends keeps its existing completed, timed-out, canceled, and failed outcomes.
- Remaining blind spots: physical scheduler and process-lifetime behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Five focused Android JVM classes | 57 tests passed, zero skipped/failures/errors | Late-input deferral, one-time forced work, exact non-acknowledgement, both runtime callers, and timed worker cancellation | Physical-device scheduling |
| Complete `testFullDebugUnitTest` | 4,586 tests passed with 7 expected skips and zero failures/errors | Full-variant source and behavior integration | OEM runtime behavior |
| `lintFullDebug` and `compileFullDebugAndroidTestKotlin` | Passed; 43 successful/up-to-date tasks in the final run | Android static analysis and instrumentation-source compilation | On-device instrumentation execution |
| Operations and diff checks | All 58 round records validated; private-data filename guard and `git diff --check` passed | Repository record, privacy filename, scope, and whitespace integrity | Hosted checks |

The first compile attempt used the repository's 4 GB Kotlin daemon heap and
failed with an out-of-memory error while lowering unchanged
`NutritionLogScreen.kt`. The same commands passed with a temporary local
`-Pkotlin.daemon.jvmargs=-Xmx8192m` override; no repository build setting was
changed.

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: JVM only
- Data-preservation result: no participant data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device behavior

## Git and release state

- Changed paths:
  - `android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt`
  - `android/app/src/main/java/com/noop/ble/WhoopBleClient.kt`
  - `android/app/src/main/java/com/noop/ui/AppViewModel.kt`
  - `android/app/src/main/java/com/noop/ui/TrendsScreen.kt`
  - `android/app/src/test/java/com/noop/data/AnalysisInputGateTest.kt`
  - `android/app/src/test/java/com/noop/ui/AgeMetricReconciliationRunnerTest.kt`
  - `android/app/src/test/java/com/noop/ui/AnalysisInputGateContractTest.kt`
  - `android/app/src/test/java/com/noop/ui/TrendsHistoryLoadTest.kt`
  - this round record, `docs/ops/ACTIVE.md`, and
    `docs/ops/rounds/INDEX.md`
- Commits: local commit containing this record
- Branch and remote state: local exact-head worktree; push explicitly prohibited
- Repository visibility verified: not changed
- Version/build impact: none
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: no global product decision; this applies
  the existing bounded-analysis and cancellation contracts.
- Decision-log entry: none

## Open risks and honest limitations

- No physical Android device or OEM background/process-lifetime scenario was
  run. A canceled post-backfill wait remains durably queued for service
  recreation, but that lifecycle still needs device evidence.
- The post-backfill worker intentionally retains its current durable revision
  while waiting for the next evaluable local-day boundary. This is idle,
  cancellation-aware work, but multi-device scheduling latency was not measured
  on hardware.
- No formula, schema, UI, deployment, or production behavior outside the two
  requested findings was changed.

## Next round

1. Review or cherry-pick the local commit into the PR branch.
2. Rerun protected hosted checks from the integrated PR head.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
