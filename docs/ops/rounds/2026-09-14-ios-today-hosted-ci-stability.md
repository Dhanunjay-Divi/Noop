# Round: 2026-09-14 - iOS Today hosted CI stability

## Status

- State: `fourth hosted correction and complete replacement local verification
  finished; exact-SHA hosted checks, protected integration, repository privacy
  restoration, and cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `703727e6087ab8b1384d1cfab50cf4e28f18b430`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close the remaining hosted Apple failure without weakening the complete Today
metric-catalog or scroll-liveness contracts, then run one replacement exact-SHA
matrix before protected integration.

## Scope

### In scope

- The iOS complete Today metric-catalog UI test.
- The iOS simulator Today scroll-performance test.
- Exact hosted failure evidence, focused and complete local simulator evidence,
  operations records, protected integration, privacy restoration, and cleanup.

### Non-goals

- Changing Today product layout, metric availability, scoring, storage,
  recommendations, notifications, or runtime behavior.
- Removing either UI contract or treating a rerun as root-cause evidence.
- Claiming physical-device performance from simulator process metrics.

## Starting evidence

- Exact pull-request head `703727e6` built NOOPiOS successfully and passed 36
  UI tests before the complete metric-catalog test issued manual application
  swipes while its asynchronous demo section was still loading.
- All ten catalog assertions then missed, and the following three-iteration
  process-metric scroll test timed out on a `swipeDown` query after the hosted
  simulator had spent more than 25 minutes in the suite.
- The same 39-case suite passed locally with 38 passes, one intentional
  private-pilot skip, and zero failures, proving the product identifiers and
  scroll path exist but not that the old synchronization is hosted-stable.
- Replacement head `69749fbc` built the app and passed the rest of the hosted
  Apple job, but its Trends compaction swipe delivered no compact state and its
  Today smoke observed a 10.484-second XCTest gesture round trip. The measured
  app round used 0.403 seconds of CPU and about 73 MB peak physical memory,
  separating runner event/idle latency from an app CPU or memory blow-up.

## Delivered

- Added stable identifiers for the Today `ScrollView` and Key Metrics section.
- Wait for the first real Key Metrics tile before traversing the catalog.
- Return to the top, then collect all ten metric identifiers in an
  order-independent set during one bounded downward traversal.
- Use three unmeasured simulator round trips as an intermittent-liveness smoke
  plus one complete measured round trip; real devices retain five iterations
  of Apple's scrolling/deceleration metric.
- Compact immediately when the first native scroll-geometry sample is already
  beyond the down-page threshold; a coalesced first callback must not strand
  expanded navigation until a second gesture.
- Give Trends' real vertical scaffold a stable accessibility identifier and
  inject the verification gesture into that scroll view rather than the
  application root.
- Keep the simulator smoke bounded by a broad 15-second stall ceiling. Hosted
  XCTest gesture synthesis is not frame-pacing evidence; production continues
  to record bounded 50 ms and 150 ms display-link hitches, and physical devices
  retain Apple's scrolling/deceleration metric.
- Do not evaluate the compact-button accessibility query between every
  performance gesture. The dedicated compaction case owns that semantic
  contract; repeating the query inside the smoke loop can starve iOS 26
  XCTest's event-loop observer after the third swipe even when the app gesture
  itself completed.
- Keep the simulator contract to one unmeasured and one measured round trip,
  and re-query the scroll element before every event. Hosted interruption
  handling can invalidate a cached `XCUIElement` after repeated gestures; that
  framework failure is not a stable app-performance signal. Production and
  physical-device frame evidence remain unchanged.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- XCTest retains exact metric identifiers, bounded wait/gesture steps,
  per-test duration, process metrics, result bundles, and failure screenshots.
- No runtime diagnostic or product telemetry changed.
- No health values, user content, credentials, or dynamic identifiers are
  recorded by this correction.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Hosted exact-head iOS shell at `703727e6` | App build passed; 36 UI tests passed, one private-pilot test skipped, the catalog test recorded ten misses, and the following scroll test timed out | Isolates the required-check failure to hosted UI synchronization and simulator gesture pressure | Whether the correction passes |
| Focused corrected UI tests | Two of two passed without retry; three unmeasured round trips remained below the eight-second liveness bound and the measured round trip completed in 5.675 seconds | The complete metric catalog waits for real content, remains reachable, and the stable Today scroll survives repeated simulator gestures | Physical-device frame pacing or long-duration responsiveness |
| Complete iOS production shell | 39 tests executed: 38 passed, one intentional private-pilot skip, and zero failures in 724.931 seconds | The correction passes in the complete unchanged iPhone 17 Pro simulator production shell with every other UI contract | Physical-device performance |
| Hosted exact-head iOS shell at `69749fbc` | App build passed; 38 UI cases passed or intentionally skipped, while Trends compaction and the 8-second simulator gesture ceiling failed | Exposes the first-sample compaction race and shows that hosted XCTest wall time is not app CPU or memory evidence | Whether the correction passes hosted CI |
| Focused final correction | Source contract passed; both affected iPhone UI tests passed with zero retry/failure in 51.687 seconds | The coalesced first-sample rule compiles, Trends targets its actual scroll surface, and repeated Today gestures complete under the corrected bounded contract | Complete-suite or physical-device behavior |
| Complete replacement iOS production shell | 39 tests executed: 38 passed, one intentional private-pilot skip, zero failures in 654.629 seconds | The corrected implementation passes every production-shell UI contract without retry | Physical-device performance |
| Hosted exact-head iOS shell at `fd0e79ae` | App build and 38 UI cases passed or intentionally skipped; the performance case completed two round trips, then XCTest waited 60 seconds for its event-loop observer and timed out evaluating the third intermediate compact-button query | Isolates the remaining failure to redundant accessibility-query pressure inside the simulator smoke, not the production compaction contract | Whether removing that redundant query passes replacement hosted CI |
| Focused no-query performance case | Passed without retry in 36.251 seconds | The performance smoke completes after removing the redundant accessibility-tree query | Accumulated full-suite pressure or physical-device frame pacing |
| Complete no-query iOS production shell | 39 tests executed: 38 passed, one intentional private-pilot skip, zero failures in 659.905 seconds | The exact correction passes under accumulated local suite pressure | Hosted-runner and physical-device performance |
| Hosted exact-head iOS shell at `a748ab36` | All 33 non-derived required contexts passed; the iOS shell passed every other UI case, then interruption handling invalidated the cached Today ScrollView during the third simulator round trip | Proves the remaining failure is repeated hosted XCTest element invalidation, not an app assertion, build failure, or cross-platform regression | Whether the bounded fresh-query simulator contract passes hosted CI |
| Focused bounded fresh-query performance case | Passed without retry in 26.471 seconds | One smoke and one measured round trip complete with a fresh element per event | Accumulated full-suite pressure or physical-device frame pacing |
| Complete bounded fresh-query iOS production shell | 39 tests executed: 38 passed, one intentional private-pilot skip, zero failures in 712.449 seconds | The exact fourth correction passes under accumulated local suite pressure | Hosted-runner and physical-device performance |
| Replacement exact-SHA hosted matrix | Pending | Pending | External release gates |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: iPhone simulator only
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: representative physical iPhone scroll performance,
  VoiceOver, BLE, background, notification, haptic, battery, and sensor checks

## Git and release state

- Changed paths: shared scaffold/Trends accessibility targeting, iOS tab-shell
  first-sample handling, iOS UI tests, source contract, and operations records.
- Commits: pending bounded correction commit.
- Branch and remote state: pull request head remains `703727e6`; correction is
  local and uncommitted.
- Repository visibility verified: public during protected hosted checks; it
  must return to private immediately after merge.
- Version/build impact: none.
- Release or distribution impact: no deployment or distribution.

## Decisions

- Async demo framing must reach a real product element before XCTest injects
  traversal gestures.
- Hosted simulator process metrics are a bounded liveness signal, not a
  statistically stable physical-device performance benchmark.

## Open risks and honest limitations

- Replacement exact-SHA hosted verification, protected integration, privacy
  restoration, canonical sync, and cleanup remain.
- All physical, supplier, legal, carrier, signing, store, participant,
  licensing, public-runtime, and elapsed-operation gates remain.

## Next round

1. Include the correction in the single final commit and replacement push.
2. Verify the exact replacement SHA through the required hosted matrix.
3. Integrate through protection, restore privacy, synchronize canonical
   `main`, and remove only round-owned resources.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
