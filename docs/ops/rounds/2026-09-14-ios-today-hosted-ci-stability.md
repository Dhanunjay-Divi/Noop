# Round: 2026-09-14 - iOS Today hosted CI stability

## Status

- State: `implementation and complete local verification finished; replacement
  exact-SHA hosted checks, protected integration, repository privacy
  restoration, and round-owned cleanup pending`
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

## Delivered

- Added stable identifiers for the Today `ScrollView` and Key Metrics section.
- Wait for the first real Key Metrics tile before traversing the catalog.
- Return to the top, then collect all ten metric identifiers in an
  order-independent set during one bounded downward traversal.
- Use three unmeasured simulator round trips as an intermittent-liveness smoke
  plus one complete measured round trip; real devices retain five iterations
  of Apple's scrolling/deceleration metric.

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
| Replacement exact-SHA hosted matrix | Pending | Pending | External release gates |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: iPhone simulator only
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: representative physical iPhone scroll performance,
  VoiceOver, BLE, background, notification, haptic, battery, and sensor checks

## Git and release state

- Changed paths: Today accessibility identifiers, iOS UI tests, and operations
  records only.
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
