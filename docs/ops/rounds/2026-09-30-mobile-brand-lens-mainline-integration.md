# Round: 2026-09-30 - Mobile brand lens and mainline integration

## Status

- State: `final local verification complete; protected integration pending`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `144e1bb904d4de1760a2d773e88d769bcf2f490d`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Finish the reviewed mobile navigation slice by replacing the ambiguous
conversation glyph with a compact NOOP `N` brand lens, reconciling Android and
iPhone presentation semantics, deciding whether the reviewed Trends surface
earns its primary-tab position, and integrating the verified result through
protected `main`.

Success requires:

- the movable lens retains its bounded geometry, persistence, accessibility,
  and nine-action launcher while using one matched `N` mark on both phones;
- Android and iPhone use the same customer-facing Effort and Daily Signal
  vocabulary without fabricating weather or health state;
- Trends remains only when it provides distinct longitudinal value and avoids
  duplicating Today;
- focused contracts, complete affected app builds, paired visual review,
  repository gates, hosted protected checks, and exact-main verification pass.

## Scope

### In scope

- iPhone and Android mobile shell presentation.
- Existing Today and Trends presentation contracts where the screenshots show
  semantic divergence.
- Focused source and geometry tests, simulator/emulator review, operations
  records, and normal protected-main integration.

### Non-goals

- Metric formulas, calibration, health-source selection, storage, cloud,
  account, BLE, background collection, notifications, or release distribution.
- Fabricating weather, physiological values, source availability, or readiness
  state to force pixel equality.
- Store upload, signed physical-device validation, production traffic, or
  firmware work.

## Starting evidence

- Reproduction or observed symptom: owner captures show the current
  speech-bubble/ECG lens, Android vocabulary and badge differences beside the
  iPhone Today surface, and a dense Trends screen whose product value must be
  assessed rather than retained by inertia.
- Relevant source/device/OS/firmware class: iOS Simulator and Android API 35
  emulator with synthetic Review Sample data.
- Existing tests, logs, exports, screenshots, or documents: the two preceding
  mobile-navigation rounds, their verified local app graphs, source contracts,
  and the owner-supplied screenshots.
- Unknowns that must remain unknown until measured: physical drag comfort,
  VoiceOver/TalkBack traversal, physical frame pacing, BLE behavior, and sensor
  accuracy.

## Delivered

- Replaced the ambiguous speech/ECG edge control with one compact geometric
  NOOP `N` on iPhone and Android while preserving drag, snap, persistence,
  nine-action launch, and accessibility movement controls.
- Reduced the default Today surface to Daily Signal, Recovery, Sleep, Effort,
  and one adaptive action. Evidence lists, workout-adjustment explanation, and
  detailed rationale now remain behind expansion.
- Removed weekly Fitness Age from the daily hero; it remains in the default
  lower `Your Cards` metric set and its detailed history.
- Removed Android's exposed low-Effort educational paragraph and the unused
  legacy score-hero implementation.
- Kept Trends as a primary destination because range comparison, history,
  sparse-data behavior, and export are distinct from Today.
- Corrected Android ordinary first launch so Review Sample appears only through
  the explicit review route, matching iPhone. Normal launch now proceeds to
  Terms and onboarding before the operational shell.
- Added matched fresh-install automation that proves Terms, welcome, account,
  Bluetooth disclosure, scan, and supported-band selection occur in that order
  while the operational tab shell remains unavailable. The supported picker
  retains compatible 5/MG and 4.0 comparison transports and excludes unrelated
  generic HR, gym, and Oura choices from this mandatory path.
- Matched Android Daily Signal accessibility output to iPhone by including the
  readiness summary and Health Monitor navigation purpose.
- Corrected the remaining Android Key Metrics label from the legacy visible
  word `Strain` to the same localized `Effort` vocabulary used by the hero,
  iPhone, and metric detail surfaces; a source contract prevents regression.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: presentation labels and
  hierarchy only; missing data remains missing.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: deterministic
  geometry/source contracts, build status files, paired screenshots, process
  checks, and bounded Android fatal/ANR review.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes synchronous local rendering and navigation only; it adds no
  network, persistence lifecycle, health calculation, or long-running worker.
- Existing evidence reused: accessibility identifiers, shell contracts,
  simulator app state, and app launch diagnostics.
- New bounded events or operation spans: none. Logging render/drag frames would
  be noisy and would not improve diagnosis.
- Redaction, retention, and high-frequency controls: synthetic values only;
  screenshots and build logs remain round-owned and are not committed.
- Cross-platform/backend correlation: paired Apple/Android source contracts and
  screenshots; backend is not applicable.
- Remaining blind spots: signed-phone accessibility and frame pacing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source and state preflight | Passed | Work continues in the isolated verified branch and unrelated step-count work remains untouched | Final rendering or hosted integration |
| Android focused contracts | 40/40 passed: 22 shell/presentation cases plus 18 configured-account ownership-selection cases | Daily Action hierarchy, compact `N`, primary navigation, Review Sample policy, bounded sparkline geometry, localized Effort vocabulary, and configured/unconfigured account-step selection compile and pass together | Live provider registration, physical TalkBack, or band behavior |
| Apple focused contracts | 81/81 passed | Daily Action hierarchy, Review Sample policy, onboarding discovery, and shell/action contracts remain coherent | Physical VoiceOver or band behavior |
| Apple configured-account and discovery contracts | 27/27 passed | Configured, signed-out, ready-account, supplier-claim, and unconfigured exploration states select the intended account/onboarding step | A live registration request against the deployed provider |
| StrandDesign package | 58/58 passed | Shared bounded monotone sparkline geometry and existing design-system behavior remain green | Every product dataset or physical rendering |
| iPhone Simulator app graph | Build passed | The changed shared Today view, iOS shell, Watch app, complications, widgets, and packages compile in the real app graph | Signed phone behavior |
| iPhone visual matrix | 21/21 scenarios captured and reviewed | Today hierarchy, Trends, action launcher, bottom states, keyboard, alert, Safety, nutrition, and accessibility-size states have no observed incoherent clipping or overlap | Physical OLED rendering, VoiceOver, or frame pacing |
| iPhone fresh-install UI automation | 1/1 passed in 36.699 seconds; enclosing `xcodebuild` exited with `TEST SUCCEEDED` | A DEBUG-only launch harness clears every first-run gate before launch, then proves Terms, welcome, account exploration, Bluetooth, scan, and supported comparison bands before exposing the tab shell | Release builds cannot invoke the reset harness; this is not live-provider or signed-device proof |
| Android Full, Demo, and instrumentation APKs | All assembled | Both shipped variants and the connected-test candidate compile and package the changed UI | OEM rendering or physical TalkBack |
| Android fresh-install instrumentation | 1/1 passed on API 35 with every mutated first-run preference snapshotted and restored | Terms, account, Bluetooth, scan, and supported-band setup precede the operational shell without leaking test state into the installed candidate | Physical permissions, BLE discovery, live-provider registration, or OEM behavior |
| Android visual review and diagnostics | Today, Trends, and nine-action launcher reviewed at 1080x2424; no matching fatal/ANR in the bounded recent sample | The final hierarchy and compact edge lens render without observed content overlap in the tested synthetic states | Absence of all runtime defects |
| Repository controls | Operations 108/108, localization audit, private-data filename guard, health-claims scan of 2,321 files, and diff hygiene passed | The durable record is valid, supported locale keysets remain complete, and no new private-data/claim gate failure was introduced | Hosted protected checks or release approval |

## Physical device and deployment

- Install/update action: unsigned iPhone Simulator graph and Android Full/Demo
  debug APKs built locally
- Generalized device and OS class: iOS Simulator and Android API 35 emulator
- Data-preservation result: no data-path change planned
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all signed physical-device and band-dependent cases
- Simulator-only accessibility coverage: source contracts and large-text visual
  states passed; VoiceOver and TalkBack traversal remain physical-device gates
- Resource cleanup: after the exact results above were recorded, the
  round-owned 9.9 GiB build/log/screenshot directory was removed. Installed
  synthetic simulator and emulator candidates were left intact for review. A
  later hermetic iPhone rerun created another 5,538,976 KiB DerivedData tree;
  after its clean `TEST SUCCEEDED` became durable and no process or open handle
  owned the path, that exact tree was also removed, leaving about 72 GiB free.

## Git and release state

- Changed paths: shared Apple Today hierarchy and sparkline primitives, iPhone
  shell/review sample, Android Today/shell/review sample/charts, mirrored
  tests/localization, and operations records
- Commits: pending
- Branch and remote state: final locally verified isolated branch based on
  exact protected `main`; commit, push, hosted checks, and protected
  integration pending
- Repository visibility verified: unchanged
- Version/build impact: no version change planned
- Release or distribution impact: source integration only; no store release

## Decisions

- Durable decision added or changed: Today is metric-first, deeper evidence is
  progressive disclosure, the five primary destinations remain stable, and the
  NOOP-wide launcher is a separate compact movable `N`.
- Decision-log entry: not expected unless the Trends information architecture
  changes beyond the existing primary-route contract.

## Open risks and honest limitations

- The configured account-selection contracts exercise deterministic provider
  states, but no live account registration or recovery request was sent from
  these simulator candidates.
- Simulator and emulator evidence cannot prove BLE, background collection,
  battery, haptics, sensor accuracy, physical accessibility traversal, or
  physical frame pacing.

## Next round

1. Run the signed physical-phone navigation, accessibility, and frame-pacing
   matrix from protected `main`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
