# Round: 2026-09-30 - Mobile navigation and sparkline redesign

## Status

- State: `integrated through protected main as part of the final brand-lens refinement`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `144e1bb904d4de1760a2d773e88d769bcf2f490d`
- End implementation commit: `d210b7ba6`
- Record commit or PR: PR `#25`

## Objective

Replace the oversized mobile bottom navigation and detached quick-action
button with one calmer cross-platform navigation language, add a compact
screen-edge quick-action control, and make metric sparklines visually regular
without changing or fabricating health values.

Success requires:

- matched Today, Trends, Workouts, Sleep, and More icon semantics on iOS and
  Android;
- smaller persistent navigation that does not obscure the next metric row;
- an accessible edge-mounted quick-action entry on both platforms;
- bounded, non-overshooting sparkline interpolation with consistent inset,
  area treatment, and endpoint presentation;
- focused tests, complete app compilation, and paired simulator/emulator
  screenshots reviewed for clipping, overlap, and parity.

## Scope

### In scope

- iOS `RootTabView` navigation chrome and Android `AppRoot` navigation chrome.
- Shared Apple and Android sparkline drawing primitives.
- Existing source-contract and geometry tests.
- Synthetic simulator/emulator visual evidence.
- Design research from the owner-supplied public repositories, used as
  principles rather than imported runtime dependencies or copied product
  assets.

### Non-goals

- Metric formulas, source selection, calibration, storage, sync, BLE,
  notifications, account behavior, or health recommendations.
- Copying third-party branding, assets, complete components, or framework code.
- Claiming physical-device smoothness, OLED appearance, TalkBack/VoiceOver
  traversal, BLE, background, haptic, battery, or sensor behavior.

## Starting evidence

- Reproduction or observed symptom: paired iPhone and Android captures show a
  wide dark navigation island, a large active-tab capsule, and a detached
  circular quick-action control occupying most of the bottom viewport. Key
  Metric sparklines use sharp point-to-point polylines and inconsistent visual
  padding.
- Relevant source/device/OS/firmware class: iOS 26.5 simulator and Android API
  35 emulator using synthetic demo data.
- Existing tests, logs, exports, screenshots, or documents: current
  `RootTabView`, `AppRoot`, shared sparkline primitives, mobile visual-parity
  round, and the owner-supplied screenshots.
- Unknowns that must remain unknown until measured: physical touch comfort,
  OEM typography, physical frame pacing, OLED appearance, and assistive
  technology traversal.

## Delivered

- Replaced the oversized full-slot selected state with a compact glass dock,
  icon-sized active signal halo, tab-specific accent, and persistent labels on
  both phone platforms.
- Aligned the five destinations around a shared health-signal vocabulary:
  Today/ECG, Trends/rising signal, Workouts/dumbbell, Sleep/moon, and
  More/modules.
- Replaced the ambiguous detached add button with an asymmetric screen-edge
  NOOP action-center control. Its speech-bubble, ECG, and restrained assistant
  glint communicate a health conversation without implying an unimplemented
  free-form chatbot.
- The later refinement on this same branch replaces that interim glyph with
  the final compact NOOP `N`; no interim third-party visual asset remains.
- Reframed the existing nine-action launcher as "How can NOOP help?" and used
  semantic-color icon plates for Workout, Strength, Meal, Journal, Hydration,
  HRV, Breathe, Intervals, and Live HR. Existing routes, identifiers, update
  access, and minimum touch targets remain intact.
- Replaced the shared point-to-point sparkline polylines with bounded monotone
  cubic interpolation. Every original sample remains on the curve and each
  segment's controls remain inside its measured endpoint range.
- Added consistent horizontal/vertical inset, subtle area treatment, and a
  crisp latest-sample marker on Android to match the existing Apple treatment.
- Added cross-platform geometry and source-contract tests.
- Rebuilt, installed, launched, captured, and visually compared the iOS and
  Android synthetic Today and action-center states. Both simulators remain
  available on Today for owner review.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none. Interpolation is presentation-only
  and must remain bounded by adjacent samples.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  simulator/emulator screenshots, app launch/crash scans, accessibility
  identifiers, source-contract tests, and bounded build status/log files.
- Why existing evidence is sufficient, or why new evidence is required: the
  changed paths are deterministic local drawing and navigation controls with
  no new persistence, network, or long-running operation boundary.
- Existing evidence reused: `AppDiagnosticsRecorder` screen ownership,
  simulator process checks, Android crash/ANR scan, and Apple/Android UI
  contract tests.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: synthetic fixtures only;
  no screenshots or metric values are committed.
- Cross-platform/backend correlation: backend not applicable; Apple and Android
  screenshots and geometry contracts are paired.
- Remaining blind spots: physical accessibility and frame pacing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source and design preflight | Passed | Current navigation/chart ownership and external-reference applicability are understood | Final appearance or physical behavior |
| Complete StrandDesign tests | 58/58 passed | The four new bounded-geometry cases and the full shared design package remain green | Every product sparkline dataset or physical rendering |
| Android focused unit/contracts | Passed | New geometry, persistent navigation, and quick-action contracts compile together | Physical TalkBack traversal or OEM rendering |
| Apple shell/state contracts | 85/85 passed | The revised shell preserves quick actions, navigation, state, and accessibility source contracts | Physical VoiceOver traversal or touch comfort |
| Final iOS Simulator app graph | Build succeeded | The app, Watch app, widgets, shared package, revised iPhone shell, and complete spoken action inventory compile together | Signed-device behavior, Watch pairing, or frame pacing |
| Android Demo APK | Build succeeded | The revised Compose shell and charts package into an installable demo APK | Physical-device or production-flavor behavior |
| Paired synthetic screenshots | Reviewed Today and action-center states at 1206x2622 and 1080x2424 | Both platforms render the signal dock, pulse-conversation control, complete nine-action launcher, readable labels, and smooth bounded curves without observed clipping or incoherent overlap | OLED appearance, device-specific font rasterization, or physical scrolling performance |
| Launch diagnostics | Android recent log buffer had no matching fatal/ANR; Android and iOS app processes remained live | The exact installed synthetic candidates launched and stayed available for review | Absence of all runtime defects or physical-device frame pacing |

## Physical device and deployment

- Install/update action: exact local iOS Simulator app and Android Demo APK
  installed and launched
- Generalized device and OS class: iOS 26.5 simulator and Android API 35
  emulator only
- Data-preservation result: no data path changes
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device and band-dependent scenarios

## Git and release state

- Changed paths: shared Apple/Android navigation shells, shared sparkline
  primitives, focused tests, and operations records
- Commits: implementation candidate `d210b7ba6`
- Branch and remote state: final exact PR head
  `3fb09d6093789a8939f075d4b9e36d026e61b76f` passed all ten required
  contexts and merged normally as
  `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`; no deployment or store
  release performed
- Repository visibility verified: unchanged
- Version/build impact: no version change planned
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: phone navigation uses five persistent
  labeled health-signal destinations, an icon-sized selection halo, and a
  separate pulse-conversation action center; sparkline smoothing must remain
  bounded by measured adjacent samples.
- Decision-log entry: not required; this refines existing cross-platform shell
  and medical-truth contracts without changing data authority.

## Open risks and honest limitations

- Shared sparkline changes affect every surface using the primitive and require
  a later broad physical visual review beyond the synthetic Today screen.
- A simulator screenshot cannot establish physical touch comfort, animation
  smoothness, or assistive technology traversal.
- The iOS simulator emitted two SwiftUI multiple-update diagnostics during the
  demo-route launch. The app stayed live and the changed shell contracts pass,
  but a signed-device performance/accessibility round should still inspect
  navigation updates under real interaction.

## Next round

1. Exercise the dock, action center, Dynamic Type, VoiceOver/TalkBack, and
   long-scroll behavior on supported physical phones.
2. Sample additional shared-sparkline call sites in light/dark and missing-data
   states before release promotion.
3. Integrate the consolidated brand-lens result through the normal
   protected-main flow.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
