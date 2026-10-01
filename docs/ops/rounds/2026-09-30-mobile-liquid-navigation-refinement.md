# Round: 2026-09-30 - Mobile liquid navigation refinement

## Status

- State: `completed locally; consolidated protected integration pending`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `144e1bb904d4de1760a2d773e88d769bcf2f490d`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Refine the locally completed mobile navigation redesign so the five primary
destinations use a clearer, more distinctive icon language and the NOOP action
control becomes a small movable screen-edge lens instead of reading as an
attached sixth tab.

Success requires:

- matched Today, Trends, Workouts, Sleep, and More semantics on iPhone and
  Android with a distinct trend/constellation treatment;
- a compact 44-point-or-larger accessible action target whose visible glass
  body is smaller than the current attached rail;
- drag movement within safe bounds, nearest-edge snapping, and persisted side
  and vertical position on both platforms;
- non-drag accessibility actions for moving the control;
- no continuous decorative animation or new high-frequency diagnostics;
- focused contracts, complete affected app builds, and paired simulator
  screenshots reviewed for clipping, overlap, and visual hierarchy.

## Scope

### In scope

- iOS `RootTabView` and Android `AppRoot` primary navigation chrome.
- Navigation geometry/persistence helpers and focused tests.
- Synthetic simulator/emulator visual evidence.
- Owner-supplied public design repositories as research inputs only.

### Non-goals

- Metric formulas, calibration, storage, BLE, background collection,
  notifications, account behavior, or health recommendations.
- Importing CSS, Tailwind, Tkinter, orchestration frameworks, third-party
  components, branding, or assets into the native apps.
- Claiming physical touch comfort, VoiceOver/TalkBack traversal, frame pacing,
  BLE, background, haptic, battery, or sensor behavior from simulators.

## Starting evidence

- Reproduction or observed symptom: the prior paired mobile captures show the
  action control attached to the bottom dock, where its size and proximity make
  it read as a sixth destination. The current Trends glyph is also visually
  generic relative to the other health destinations.
- Relevant source/device/OS/firmware class: iOS Simulator and Android API 35
  emulator using synthetic demo data.
- Existing tests, logs, exports, screenshots, or documents: the preceding
  mobile-navigation round, its paired captures, current source contracts, and
  the owner-supplied public design references.
- Unknowns that must remain unknown until measured: physical drag comfort,
  assistive-technology traversal, OEM rendering, physical frame pacing, and
  OLED appearance.

## Delivered

- Kept the primary dock to exactly five destinations on both phones and
  separated the NOOP action center into an independent screen-edge control.
- Refined the matched icon vocabulary to Today/health signal,
  Trends/connected observations, Workouts/dumbbell, Sleep/moon, and More/app
  grid. Android no longer uses the decorative `AutoGraph` wand for Trends or
  the asymmetric Widgets glyph for More.
- Reduced the final visible action lens to `28x38` while preserving a `48x52`
  interaction target. Its resting location is lower on the edge so it does not
  collide with the Daily Signal information action in the reviewed states.
- Added bounded drag geometry, nearest-edge snapping, persisted edge and
  vertical position, and non-drag accessibility movement actions on both
  platforms.
- Softened the full-dock accent rim while retaining the selected destination's
  icon-sized color halo. iOS uses native navigation glass where available;
  Android uses the existing static, scroll-safe glass surface rather than a
  per-frame blur.
- Kept the existing nine-action "How can NOOP help?" sheet and verified that
  both platform presentations remain readable and unobscured after detaching
  the entry lens.
- Imported no third-party UI code, assets, frameworks, or branding from the
  public design references.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: deterministic
  geometry/persistence tests, accessibility/source contracts, bounded build
  status files, simulator screenshots, and launch/crash checks.
- Why existing evidence is sufficient, or why new evidence is required: the
  changed boundary is local navigation presentation and preference storage;
  no network, health-data, or long-running operation is introduced.
- Existing evidence reused: app screen ownership, simulator process checks,
  Android fatal/ANR scan, and mobile shell tests.
- New bounded events or operation spans: none planned. Drag-frame logging would
  be noisy and privacy-irrelevant; deterministic tests cover the geometry.
- Redaction, retention, and high-frequency controls: only two bounded
  non-health preferences are stored; no drag coordinates enter diagnostics.
- Cross-platform/backend correlation: backend not applicable; Apple and Android
  geometry and screenshots are paired.
- Remaining blind spots: physical accessibility and frame pacing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source/design preflight | Passed | Current shell ownership, dirty paths, and applicability of external references are understood | Final rendering or physical interaction |
| Complete StrandDesign package | 58/58 passed | Shared bounded sparkline geometry and all existing design-system contracts remain green on the refined tree | Every app dataset or physical rendering |
| Android focused contracts | 22/22 passed on the final consolidated tree | Navigation geometry, icon/source contracts, Review Sample parity, Today hierarchy, and sparkline geometry pass together | Physical TalkBack traversal or OEM rendering |
| Android Full and Demo compilation plus Demo APK | Passed | Both production code variants compile and the exact synthetic candidate packages successfully | Signed installation, physical touch behavior, or release readiness |
| Apple final focused contracts | 81/81 passed | The movable lens, icon vocabulary, launcher inventory, Today hierarchy, onboarding discovery, accessibility source contracts, and existing shell/state behavior compile together | Physical VoiceOver traversal or drag ergonomics |
| Complete iOS Simulator app graph | Build succeeded | The app, Watch app, complications, widgets, shared packages, and refined shell compile as one graph | Signing, physical Watch behavior, BLE, or frame pacing |
| Default Today screenshots | Reviewed at 1206x2622 and 1080x2424 | The lens is visually smaller, detached from the dock, clear of the tested info controls, and the refined icons remain readable without observed clipping | All screens, orientations, font scales, or physical OLED appearance |
| Movement and persistence | Android drag snapped to the left edge and survived relaunch; iOS restored a persisted left-edge/alternate-height state | Edge geometry and preference restoration work in the synthetic environments | Physical finger comfort or complete assistive-technology focus behavior |
| Action-center screenshots | Reviewed on both platforms | The detached lens opens the complete nine-action sheet without incoherent overlap or clipped labels | Every action's downstream workflow |
| Launch diagnostics | Android recent log sample had zero matching fatal/ANR signatures; both candidates remained live | No matching launch-time fatal or ANR was observed in the bounded sample | Absence of all runtime defects |
| Repository gates | Full all-platform localization, 108 operations records, private-data and health-claims gates, and diff hygiene passed | New accessibility copy is complete across supported Android locales and the durable handoff remains structurally valid | Hosted protected checks or release approval |

## Physical device and deployment

- Install/update action: exact local iOS Simulator app and Android Demo APK
  installed and launched with synthetic demo data
- Generalized device and OS class: iOS 26.5 simulator and Android API 35
  emulator only
- Data-preservation result: no data path change
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device and band-dependent scenarios
- Resource cleanup: the final consolidated round removed its exact 9.9 GiB
  build/log/screenshot directory after the evidence became durable. Installed
  synthetic candidates remain available for review.

## Git and release state

- Changed paths: Apple and Android phone navigation shells and Review Sample
  icons, focused navigation/accessibility contracts, Android localized lens
  accessibility copy, and operations records; the preceding round also owns
  the shared sparkline changes on this branch
- Commits: pending
- Branch and remote state: isolated dirty local branch; no commit, push,
  deployment, release, or production traffic action performed
- Repository visibility verified: unchanged
- Version/build impact: no version change planned
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: the app-wide action entry is a compact,
  edge-snapping movable lens separate from the stable five-destination dock.
- Decision-log entry: not required; this refines the existing mobile shell
  decision without changing product or data authority.

## Open risks and honest limitations

- A movable control can obscure content in an owner-selected position; safe
  bounds and edge snapping reduce but cannot eliminate that tradeoff.
- Simulator evidence cannot establish physical drag ergonomics or
  assistive-technology focus order.
- The visual matrix covers the synthetic dark Today and action-center states,
  not every destination, appearance mode, Dynamic Type size, orientation, or
  OEM font/rendering combination.

## Next round

1. Run the signed physical-phone navigation, accessibility, and long-scroll
   matrix before release promotion.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
