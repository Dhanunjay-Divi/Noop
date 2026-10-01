# Round: 2026-09-30 - Mobile brand lens and mainline integration

## Status

- State: `final local candidate verified; protected review pending`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `144e1bb904d4de1760a2d773e88d769bcf2f490d`
- End implementation commit: `96fdef2c2`
- Record commit or PR: PR `#25`

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
- Replaced the oversized ring hierarchy with three equal, number-first
  Recovery, Sleep, and Effort readouts on both phones. The default lower cards
  are now HRV, Resting HR, and Blood Oxygen, avoiding duplicate Recovery,
  Sleep, and Effort cards while keeping every metric available through
  customization and history.
- Preserved calibration, missing-data, trend, provenance, and detail access in
  the compact surface. Accessibility sizes stack the three signals instead of
  shrinking or clipping them, and spoken provenance retains the complete source
  summary even when the visible label is condensed.
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
- Added explicit configured-provider test lanes that exercise create/sign-in
  controls, synthetic supported-band selection, ownership confirmation,
  profile, plan, completion, and final shell entry without contacting a live
  provider or pretending a simulator performed Bluetooth discovery.
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
| Android focused contracts | 46/46 passed | Compact number-first Daily Signal hierarchy, key-metric defaults, compact `N`, primary navigation, Review Sample policy, bounded sparkline geometry, localized Effort vocabulary, provenance, and configured/unconfigured account-step selection compile and pass together | Live provider registration, physical TalkBack, or band behavior |
| Apple focused contracts | 81/81 passed | Daily Action hierarchy, Review Sample policy, onboarding discovery, and shell/action contracts remain coherent | Physical VoiceOver or band behavior |
| Apple configured-account and discovery contracts | 27/27 passed | Configured, signed-out, ready-account, supplier-claim, and unconfigured exploration states select the intended account/onboarding step | A live registration request against the deployed provider |
| StrandDesign package | 58/58 passed | Shared bounded monotone sparkline geometry and existing design-system behavior remain green | Every product dataset or physical rendering |
| iPhone Simulator app graph | Build passed | The changed shared Today view, iOS shell, Watch app, complications, widgets, and packages compile in the real app graph | Signed phone behavior |
| Paired current Today review | iPhone 1206x2622 and Android 1080x2424 captures reviewed | Both phones show the same compact three-signal hierarchy, HRV/RHR/Blood Oxygen defaults, lower movable `N`, and matched five-tab semantics without observed clipping or chart overlap | Physical OLED rendering, VoiceOver/TalkBack, or frame pacing |
| iPhone configured full-onboarding UI automation | 1/1 passed; enclosing `xcodebuild` exited with `TEST SUCCEEDED` | A DEBUG-only hermetic lane proves Terms -> welcome -> create/sign in -> Bluetooth -> supported simulated band -> ownership -> profile -> plan -> completion -> tabs, with tabs unavailable before completion | Release builds cannot invoke the harness; no live provider, BLE discovery, signed install, or physical claim occurred |
| Android complete app wall | Full and Demo each passed 5,242 unit tests with seven intentional skips; both Kotlin variants, lint variants, APKs, and the Full instrumentation APK passed | The changed production source, mirrored tests, localization, and shipped variants compile and pass together | OEM rendering, physical TalkBack, or physical band behavior |
| Android configured full-onboarding instrumentation | 1/1 passed on API 35 with every mutated preference restored; the corrected Recovery-detail shell case also passed 1/1 | A hermetic configured-provider lane proves the same gated sequence before a lightweight test shell, while a separate real-shell test proves the compact Recovery detail opens without changing tabs | Physical permissions, BLE discovery, live-provider registration, or OEM behavior |
| Repository controls | Operations 108/108, required-CI 10-context policy, nine release controls, terminology ratchet, full localization, app-report localization, private-data filename guard, health-claims scan of 1,312 files, and diff hygiene passed | The durable record and generated resources are coherent, required workflow ownership is pinned, and no private-data or unsafe-claim regression was introduced | Hosted protected checks or release approval |

## Physical device and deployment

- Install/update action: unsigned iPhone Simulator graph and Android Full/Demo
  debug APKs built locally
- Generalized device and OS class: iOS Simulator and Android API 35 emulator
- Data-preservation result: no data-path change planned
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all signed physical-device and band-dependent cases
- Simulator-only accessibility coverage: source contracts and large-text visual
  states passed; VoiceOver and TalkBack traversal remain physical-device gates
- Resource cleanup: after the exact results above were recorded, the idle
  round-owned Gradle daemon was stopped and the exact two DerivedData trees,
  isolated Gradle cache, and corrupt superseded result bundle were removed.
  The round directory fell from about 10 GiB to 13 MiB and Data-volume free
  space rose to about 57 GiB. Small bounded logs, status files, and the paired
  screenshots remain temporarily for protected-review diagnosis.

## Git and release state

- Changed paths: shared Apple Today hierarchy and sparkline primitives, iPhone
  shell/review sample, Android Today/shell/review sample/charts, mirrored
  tests/localization, and operations records
- Commits: initial implementation `d210b7ba6`; final metric-first and
  onboarding-proof implementation `96fdef2c2`; documentation pin follows on the
  same PR branch
- Branch and remote state: final locally verified branch is one consolidated
  push ahead of PR `#25`; hosted checks and protected integration remain
  pending
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
