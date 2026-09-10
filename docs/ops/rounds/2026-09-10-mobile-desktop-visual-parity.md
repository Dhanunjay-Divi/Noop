# Round: 2026-09-10 - Mobile and desktop Today visual parity

## Status

- State: `final review correction locally verified; replacement protected integration pending`
- Owner: project team
- Branch: `codex/mobile-desktop-visual-parity-20260910`
- Start commit: `beb0e88f70141766c32a0bcd270f5f8889c6f10d`
- End implementation commit: `e51c56e5f7397e4eec511d4d1fe607768f108dac`
- Android review-correction commit:
  `133cb5d8d064f98b70b1090c013881ecff3ebea7`
- Apple review-correction commit:
  `02594534df513dcaf49051ca9fa122618e946a30`
- Record commit or PR: protected pull request `#13`

## Objective

Use the approved desktop Today screen as the visual reference for both phone
apps while preserving mobile navigation, touch ergonomics, accessibility, and
all existing data behavior. Success requires one quiet obsidian canvas, a
single dominant Daily Signal hierarchy with integrated Fitness Age, compact
secondary rows, matched iOS and Android screenshots, and clean platform builds.

## Scope

### In scope

- Align the iOS and Android Today masthead, Daily Signal surface, spacing,
  surface treatment, and immediate post-hero hierarchy with the desktop
  reference.
- Reuse the existing static obsidian background and semantic status colors.
- Preserve mobile bottom navigation, day gestures, accessibility labels,
  section ordering, metric navigation, and responsive layout.
- Capture matched simulator/emulator evidence and run focused plus app build
  gates.

### Non-goals

- Change metric formulas, source selection, calibration, storage, sync, BLE,
  notification, account, cloud, or health-data behavior.
- Claim physical-device frame pacing, background collection, haptics, battery,
  or sensor correctness from simulator evidence.
- Redesign every app screen in this one reviewable change.

## Starting evidence

- Reproduction or observed symptom: the current desktop Today hierarchy was
  explicitly preferred over the busier mobile style.
- Relevant source/device/OS/firmware class: shared Apple Today implementation
  and Android Compose Today implementation; simulator/emulator evidence only.
- Existing tests, logs, exports, screenshots, or documents: the provided
  desktop screenshot, existing iOS Today screenshot harness, retained-screen
  performance tests, and bounded `ui.scroll.summary` diagnostics.
- Unknowns that must remain unknown until measured: physical OLED appearance,
  OEM rendering differences, physical-device frame pacing, and accessibility
  behavior outside the tested simulator matrix.

## Delivered

- Apple and Android phone Today now preserve the desktop reference's dense
  first-viewport hierarchy: compact masthead, one dominant Daily Signal
  surface, centered Recovery instrument, paired Sleep and Effort satellites,
  integrated Fitness Age, and the workout-coach row immediately below.
- Fixed-format score instruments scale down together on ordinary phone text
  sizes, while large Dynamic Type keeps the roomier dimensions so labels do
  not clip.
- Compact geometry is limited to phone-width layouts. iPad, Android tablet,
  and phone accessibility-text layouts use the roomier geometry instead of
  inheriting phone-only dimensions.
- The narrow Daily Signal header stacks status and provenance below the title
  when the actual width or text scale cannot fit them. Wider layouts retain
  the established single-row presentation.
- Android bottom bars now measure the actual localized labels against their
  available slot width before choosing labels or icon-only controls. Both the
  normal and Review Sample shells retain complete accessibility names without
  clipping long translations.
- The Android weather control retains at least a 48 x 48 dp hit target while
  its compact visual surface remains unchanged. At large text, a cached
  temperature surface grows from its 82 dp minimum when content requires it
  instead of clipping a signed Fahrenheit value.
- The compact Apple weather capsule keeps its 32/34-point visual height but is
  wrapped in the shared 48-point control target, so the complete button remains
  easy to activate without making the masthead visually heavier.
- Card radius, padding, spacing, weather control dimensions, and shadow depth
  now match across the two phone implementations without changing source
  selection, formulas, navigation, gestures, accessibility labels, or stored
  data.
- Paired synthetic Today captures were reviewed at 1080 x 2400 on Android and
  1170 x 2532 on iOS. They use different fixture states, but both preserve
  native system chrome and mobile navigation while using the desktop visual
  hierarchy.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: visual hierarchy only; no
  metric or medical behavior is validated by this work.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `ui.scroll.summary`, severe-hitch reporting, app build logs, UI-test
  screenshots, and accessibility identifiers.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes static composition and styling without adding a new fallible
  operation or state transition.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`,
  simulator/emulator screenshots, source contract tests, and app build gates.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: screenshots use synthetic
  fixtures; diagnostics retain no health values, identifiers, payloads, or
  user-authored content.
- Cross-platform/backend correlation: backend correlation is not applicable to
  a local visual-only change; Apple and Android evidence will be paired.
- Remaining blind spots: physical devices and hardware-dependent behavior.

## Evidence

Record exact commands and results. Distinguish unit, integration, simulator,
physical-device, and external-service evidence.

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source preflight | Desktop reference and both Today implementations inspected | Existing hierarchy and parity points are understood before edits | Final appearance or device performance |
| Android focused and app gates | Final exact-source invocation passed `:app:assembleFullDebug`, `:app:assembleDemoDebug`, `:app:lintFullDebug`, `:app:compileFullDebugAndroidTestKotlin`, and 31 focused Today, shell, Review Sample, and performance contracts in 3 minutes | Both Android variants compile, lint is clean, instrumentation sources compile, and the responsive, navigation, retained-screen, runtime, and Today contracts hold together | Physical-device frame pacing, OEM rendering, collection, or BLE behavior |
| Android exact review-correction gate | On commit `133cb5d8`, `:app:assembleFullDebug`, `:app:assembleDemoDebug`, `:app:lintFullDebug`, `:app:compileFullDebugAndroidTestKotlin`, and the focused `PrimaryNavigationContractTest`, `TodayResponsiveLayoutTest`, and `ReviewSampleModeContractTest` suites passed together in 1 minute 48 seconds | Both variants compile, lint and instrumentation-source compilation remain clean, measured-label fallback is covered, and the weather target/content-size contracts hold | Hosted exact-head execution or physical-device behavior |
| Apple focused contracts | Follow-up suite passed 77 tests across `LiquidTodayFeatureMountTests`, `TodayExplainabilityTests`, and `RetainedScreenPerformanceContractTests` with zero failures or skips | The shared Today source retains explainability, feature mounting, retained-screen behavior, and the compact-width/large-text selection policy | Physical-device smoothness or hardware-dependent behavior |
| Apple exact review-correction gate | On commit `02594534`, all 12 `LiquidTodayFeatureMountTests` passed with zero failures or skips, and the complete unsigned `NOOPiOS` simulator graph built successfully from the regenerated XcodeGen project | The compact capsule remains visually small while modifier order preserves a 48-point tappable label, and the correction compiles through the iPhone, widget, and watch dependency graph | Physical touch accuracy, signed installation, or App Store acceptance |
| iOS app build | `NOOPiOS` built for an arm64 iOS 26.5 simulator with signing disabled after regenerating the ignored XcodeGen project from `project.yml` | The changed shared Swift source and complete iOS dependency graph compile together | Signing, installation on a physical phone, or store acceptance |
| Android runtime capture | Demo Today rendered at ordinary and 1.5x text on an isolated API 35 arm64 emulator; phone captures are 1080 x 2400 and the tablet capture is 2560 x 1600. The corrected large-text Today and Review Sample captures each left a zero-byte crash buffer | Current APKs render compact phone, large-text phone, and regular-width tablet branches; the weather and navigation labels no longer truncate in either Android shell | Physical OLED appearance, OEM variance, sensor data, or sustained frame pacing |
| Android review runtime measurements | On the API 35 arm64 emulator at density 420 and 1.5x text, the no-snapshot weather control measured 126 x 126 px, exactly 48 x 48 dp. A synthetic cached `-100 C` reading displayed as signed `-148 F`; its control expanded to 225 px, about 85.7 dp, from the 82 dp visual minimum with no clipped glyphs. At ordinary text with the app locale forced to French, the production rail selected icon-only mode and retained every full localized accessibility name | The three exact review reports reproduce as fixed in rendered Compose output, including the widest supported signed Fahrenheit value | Physical touch accuracy, OEM font substitutions, or every locale/device width |
| iOS runtime capture | Synthetic Today rendered on an iOS 26.5 phone at ordinary and accessibility-large text and on an iPad simulator; phone captures are 1170 x 2532 and the tablet capture is 1640 x 2360 | The current iOS app renders phone, accessibility-text, and regular-width tablet branches without clipped Daily Signal labels | Physical-device frame pacing, background execution, BLE, battery, or haptics |
| Independent review | Five earlier findings were reproduced and corrected: Android header clipping, tablet geometry, incomplete large-text scaling, overclaimed evidence, and a stale radius comment. Exact-head review then reported three additional Android issues: a 34 dp icon-only weather target, localized bottom-label clipping in both shells, and fixed-width large-text weather clipping. Commit `133cb5d8` corrects all three. Review of that replacement head then found the compact Apple weather button exposed only its 32-point capsule as the hit region; commit `02594534` wraps it in the shared 48-point target. The focused source/runtime evidence above passes | The final source and evidence reflect multiple fresh reviews rather than only the implementation author’s assumptions | Replacement exact-head hosted review and independent physical-device review |
| Visual hierarchy review | Desktop, Android, and iOS first viewports compared directly despite different synthetic data states | Both phones share the approved hierarchy, visual weight, section order, and score geometry while preserving native chrome; tablet and large-text branches remain coherent | State-for-state screenshot parity, pixel identity across rendering engines, physical rendering, or every non-Today screen |
| Hosted Apple first attempt | Protected pull request `#13` ran the full macOS suite: 1,701 tests executed with one expected skip and one failure in `MoreListParityTests.testAdaptiveScaffoldBackgroundUsesDynamicInk` | The hosted matrix reached the changed Apple source and exposed that an older source-contract assertion still required the pre-responsive fixed `30pt` title | A green replacement head |
| Hosted assertion correction | The contract now verifies responsive `todayGreetingSize` followed by adaptive `StrandPalette.textPrimary`; the exact `MoreListParityTests` suite passed 14 tests locally with zero failures or skips | The corrected test still rejects hard-coded white ink while accepting the intentional `28/30pt` responsive title policy | A hosted rerun was still required at this evidence point and is recorded in the next row |
| Hosted Apple rerun on prior head | GitHub Actions run `34446056639` reran successfully on `67ffd848`; iOS/macOS job `102802245051` and the stable `apple-ci-required` result both passed | The prior reviewed head satisfies the complete protected Apple matrix after the launch-timeout rerun | The newer Android-only correction head still requires its own protected matrix |
| Terminology snapshot review | Regenerated inventory retains 17,367 classified occurrences across 1,511 groups with identical category totals, a byte-identical active allowlist, and zero forbidden mappings; only source line locations changed | The UI edit introduces no new or modified active customer/core legacy terminology and the fail-closed inventory matches the source tree | Independent provenance review of pre-existing compatibility terminology |
| Repository policy matrix | All 227 Tools tests passed; required CI verified 5 conditional workflows, 5 universal workflows, and 10 contexts; 9 release controls, 12-metric calibration parity, no-new-copy localization, 1,203-file health-claims scan, 230-component legal inventory, distribution provenance, private-data, 50 operations records, terminology, and diff checks passed | The exact local tree preserves release, metric, localization, claims, provenance, privacy, and durable-evidence contracts | Hosted exact-SHA checks, external legal approval, or physical behavior |
| Resource cleanup | API 35 emulator stopped, Gradle and Kotlin daemons stopped, both temporary DerivedData roots and the temporary terminology candidate removed, and no Android or Apple simulator remains booted | Temporary runtime and build resources created by this round are no longer consuming device or daemon resources | The pre-existing Gradle-managed AVD cache, repository build products, or unrelated user resources |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no persistence changes
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical-device and band-dependent scenarios

## Git and release state

- Changed paths: Apple Today source and feature-mount tests; Android Today,
  bottom-bar, Review Sample, and responsive/navigation contract sources;
  the Apple adaptive-ink source contract;
  `release/terminology/legacy-inventory.json`; `Tools/required-ci-gate.py`;
  this record; `docs/ops/rounds/INDEX.md`; and `docs/ops/ACTIVE.md`
- Commits: `290cefb0` (`Align mobile Today with desktop hierarchy`),
  `e51c56e5` (`Harden Today responsive accessibility`), `67ffd848`
  (`Fix responsive Today source contract`), and `133cb5d8`
  (`Fix Android large-text navigation and weather`), and `02594534`
  (`Fix compact iOS weather touch target`)
- Branch and remote state:
  `codex/mobile-desktop-visual-parity-20260910` is open as protected pull
  request `#13`; commit `02594534` and this evidence update still require push,
  replacement hosted checks, the final resolved review conversation, and
  normal merge
- Repository visibility verified: standalone GitHub repository relationship
  inherited from the current active handoff; exact protected integration
  remains pending
- Version/build impact: no version change
- Release or distribution impact: no artifact published

## Decisions

- Durable decision added or changed: desktop Today is the shared visual
  reference while mobile platform navigation and ergonomics remain native.
- Decision-log entry: none; the existing architecture already defines the
  macOS app as the reference implementation and this round applies that rule
  to one screen.

## Open risks and honest limitations

- A matched simulator/emulator image does not establish physical-device
  smoothness or sensor reliability.
- The wider mobile screen audit remains a separate checklist item; this round
  does not claim that every non-Today screen matches the desktop visual
  language.
- The iOS simulator fixture was still calibrating while the Android fixture
  contained scored values. That difference validates responsive content
  states, not numerical parity between fixtures.
- Simulator and emulator captures cover the intended phone, large-text, and
  tablet branches, but they do not replace physical-device accessibility,
  frame-pacing, OLED, OEM, or touch-target review.
- The first protected Apple run failed one stale source-contract assertion.
  Its prior rerun is green, but protected integration remains incomplete until
  the final Apple correction head passes every required check and its review
  conversation is resolved against that evidence.

## Next round

1. Merge this focused visual change only after the replacement protected
   matrix is green, then implement the already-recorded single explainable
   customer-day recommendation arbiter as a separate reviewable round.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
