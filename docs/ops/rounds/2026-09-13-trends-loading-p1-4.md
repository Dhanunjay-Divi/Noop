# Round: 2026-09-13 - Trends loading and aggregation

## Status

- State: `complete`
- Owner: project team
- Branch: `codex/trends-loading-p1-4-20260913`
- Start commit: `f7baaddc0818b238b86962e60c5664eb6b746d34`
- End implementation commit: this local handoff commit
- Record commit or PR: local commit only; push not authorized

## Objective

Close UI audit P1-4 in an isolated fork by making Trends show an honest
nonblank loading state and by keeping long-history preparation bounded,
memoized where useful, cancelable, and off the UI thread on Apple/macOS and
Android.

## Scope

### In scope

- Trends loading, refresh, timeout, cancellation, and retry behavior.
- Trends history/snapshot preparation performance on Apple/macOS and Android.
- Bounded privacy-safe operation evidence for changed long-running boundaries.
- Focused logic, contract, build, and simulator/macOS verification.

### Non-goals

- Weekly Digest presentation, wording, colour, metric, or missing-data changes.
- Other UI-audit findings.
- Formula, persistence schema, sensor, BLE, notification, or cloud changes.
- Push, merge, deployment, signing, or physical-device claims.

## Starting evidence

- Reproduction or observed symptom: the private audit proved a blank Trends
  body for about 5-15 seconds before content appeared on iOS and macOS.
- Relevant source/device/OS/firmware class: shared SwiftUI Trends screen and
  Android Compose Trends screen; no wearable or firmware behavior is involved.
- Existing tests, logs, exports, screenshots, or documents: private UI audit
  evidence retained outside Git; existing snapshot, cancellation, timeout, and
  screen-state tests in both app trees.
- Unknowns that must remain unknown until measured: physical-device frame
  timing, memory pressure, and OEM rendering.

## Delivered

- Apple/macOS now computes every Trends metric series in one source-history
  traversal, filters prepared chronological points by binary-searching the
  selected cutoff, and preserves the existing widening/date semantics.
- Apple/macOS uses an LRU snapshot cache capped at six entries, keys each result
  to the history, resolved-sleep revision, local day, and selected range, and
  clears stale presentation state when no current key exists.
- Android moves full history reads and snapshot preparation off the main
  dispatcher, computes metric series in one source-history traversal, and uses
  an LRU snapshot cache capped to the number of supported ranges.
- Both clients yield before expensive preparation so the loading skeleton can
  render, cancel obsolete work, reject stale keyed results, retain bounded
  timeout/retry behavior, and emit only fixed status/range/count-bucket
  diagnostics.
- Focused tests pin one source visit per history row, bounded LRU eviction,
  cancellation, cache instrumentation, the loading skeleton, and the absence of
  health values or device identifiers in the new diagnostic fields.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none; focused tests preserve existing
  metric values and date-window semantics.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `trends.history_load`, `trends.aggregate_prepare`, and
  `trends.weekly_digest_prepare` operation spans.
- Why existing evidence is sufficient, or why new evidence is required: the
  aggregate span now distinguishes `cache_hit`, completed work, cancellation,
  timeout, supersession, and failure.
- Existing evidence reused: operation duration and fixed outcome categories.
- New bounded events or operation spans: no new operation names; the aggregate
  span adds a fixed range, fixed cache status, cache capacity/entry count, and a
  bucketed history-row count.
- Redaction, retention, and high-frequency controls: fixed categories and
  bucketed counts only; no dates, health values, source/device/account
  identifiers, user content, or exception strings.
- Cross-platform/backend correlation: matched local Apple/Android operation
  names only; no backend boundary exists.
- Remaining blind spots: physical-device scheduling and UI frame evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Initial Android focused command | Did not reach tests because the isolated worktree had no SDK path configured | Environment prerequisite was missing | Any Android product or test failure |
| `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/LiquidKeyMetricTrendTests -only-testing:StrandTests/ScreenStateContractTests` | PASS, 19 tests, 0 failures | Apple code compiles and focused metric, cache, cancellation, loading-state, timeout, retry, privacy, and source contracts pass | Physical iPhone frame timing or memory pressure |
| `./gradlew :app:compileFullDebugKotlin :app:testFullDebugUnitTest --tests 'com.noop.ui.TrendsHistoryLoadTest' --tests 'com.noop.ui.UiAuditPresentationContractTest'` with the configured local Android SDK | PASS, 29 tasks | Android code compiles and focused history, background-preparation, cache, loading-state, privacy, and audit contracts pass | Physical Android rendering, OEM scheduling, or TalkBack |
| `git diff --check` | PASS | Changed files contain no whitespace errors | Runtime behavior |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS and simulators only
- Data-preservation result: no participant data is used or changed
- BLE/background/haptic/battery scenarios exercised: not applicable
- Unrun hardware gates: physical-device rendering, memory pressure, TalkBack,
  and VoiceOver

## Git and release state

- Changed paths: Apple and Android Trends implementation/tests plus this
  operations record, active-round index, and round index
- Commits: this local handoff commit
- Branch and remote state: isolated local branch; no push authorized
- Repository visibility verified: not changed
- Version/build impact: none
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none.

## Open risks and honest limitations

- Physical-device frame pacing and memory-pressure behavior remain unproven and
  stay as release gates.

## Next round

1. Integrating owner cherry-picks the bounded local commit and reruns the
   combined release branch matrix before any push.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
