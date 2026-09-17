# Round: 2026-09-14 - iOS tab-selection CI stability

## Status

- State: `focused and complete local verification passed; replacement
  exact-SHA hosted verification pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `1b215c82e0bf98abed4ee69b047e7de4d4084673`
- End implementation commit: the bounded commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close the only failed exact-SHA hosted check without weakening the product
responsiveness contract, then complete protected integration, privacy
restoration, canonical synchronization, and round-owned cleanup.

Success requires:

- reproduce the hosted failure from its complete job log;
- distinguish a product navigation failure from stale XCTest accessibility
  state;
- keep a bounded assertion that every primary tab becomes selected promptly;
- pass focused repeated-navigation verification and the complete iOS
  production shell;
- pass the replacement exact-SHA hosted matrix before protected integration.

## Scope

### In scope

- The repeated iOS primary-tab navigation UI test.
- Exact hosted failure evidence, focused and complete iOS simulator evidence,
  operations records, protected integration, privacy restoration, and cleanup.

### Non-goals

- Changing primary navigation layout, animation, product behavior, metrics,
  recommendations, notifications, storage, or network behavior.
- Weakening required checks or treating a rerun as proof without root-cause
  evidence.
- Claiming physical-device responsiveness, VoiceOver, BLE, background,
  haptic, battery, or sensor behavior from a simulator.

## Starting evidence

- Reproduction or observed symptom: exact head `1b215c82` hosted run
  `34806225421` built successfully, then
  `testRepeatedTabNavigationRemainsResponsive` failed once at the immediate
  `tab.isSelected` assertion for Sleep during the second navigation cycle.
  The test continued through the remaining tabs and all other 38 UI tests
  passed; one private-pilot test was intentionally skipped.
- Relevant source/device/OS/firmware class: Xcode 26 hosted iPhone 17 Pro
  simulator UI automation.
- Existing tests, logs, exports, screenshots, or documents: complete raw job
  log, the existing stable primary-tab test, and prior complete local iOS UI
  suite.
- Unknowns that must remain unknown until measured: physical-device
  responsiveness and assistive-technology behavior.

## Delivered

- Replaced cached `XCUIElement` selected-state reads with fresh identifier
  queries after every tab tap.
- Reused the existing bounded polling pattern from the stable primary-tab
  contract.
- Retained a three-second responsiveness limit and an explicit per-tab failure
  message; a tab that does not expose its selected state still fails.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: XCTest records
  the exact tab identifier, selected-state timeout, tap sequence, and simulator
  result bundle.
- Why existing evidence is sufficient, or why new evidence is required: this
  is test-harness synchronization around an existing accessibility trait, not
  a new runtime boundary. Product tab transitions already emit the bounded
  `ui.tab_changed` category without values or identifiers.
- Existing evidence reused: XCTest activity logs, result bundles, and
  `AppDiagnosticsRecorder` tab categories.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged; no health
  value, user content, credential, dynamic identifier, or payload is logged.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: physical-device navigation and VoiceOver timing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Hosted exact-head iOS shell at `1b215c82` | 38 passed, one failure, one intentional skip | Isolates the only hosted failure to one stale selected-trait assertion after a successful tap | Whether the corrected test passes |
| Focused repeated-tab UI test | One pass, then three consecutive no-retry passes; zero failures | Fresh identifier queries and the bounded selected-state wait remain stable across repeated complete navigation cycles | Physical-device behavior |
| Complete iOS production shell | 39 tests executed: 38 passed, one intentional private-pilot skip, zero failures in 643.179 seconds; the corrected repeated-tab case passed in 81.295 seconds | The correction passes in the complete unchanged iPhone 17 Pro simulator production shell with every other UI contract | Physical-device behavior |
| Replacement exact-SHA hosted matrix | Pending | Pending | External release gates |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: iOS simulator only
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: representative physical iPhone navigation,
  VoiceOver, BLE, background, notification, haptic, battery, and sensor checks

## Git and release state

- Changed paths: iOS UI test and operations records only.
- Commits: the bounded correction commit containing this record.
- Branch and remote state: pull request head remains `1b215c82`; corrective
  changes are locally verified and uncommitted.
- Repository visibility verified: public during protected hosted checks; it
  must return to private immediately after merge.
- Version/build impact: none.
- Release or distribution impact: no deployment or distribution.

## Decisions

- Durable decision added or changed: UI automation must query SwiftUI
  accessibility selection through a fresh element and a bounded prompt-state
  wait; immediate reads from cached nodes are not accepted as responsiveness
  evidence.
- Decision-log entry: round-local test policy only; no global product decision.

## Open risks and honest limitations

- Replacement exact-SHA hosted verification remains pending.
- Protected integration, privacy restoration, canonical sync, and cleanup
  remain pending.
- All previously recorded physical, supplier, legal, carrier, signing, store,
  participant, licensing, public-runtime, and elapsed-operation gates remain.

## Next round

1. Commit and push the bounded correction.
2. Wait for exact-SHA hosted checks, then complete protected integration,
   privacy restoration, canonical sync, and cleanup.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
