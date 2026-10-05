# Round: 2026-10-04 - Mobile overlay and feed closeout

## Status

- State: `hosted app-report review correction locally verified; replacement checks pending`
- Owner: project team
- Branch: `codex/mobile-cloud-release-finalization-20261003`
- Protected base: `1cd401f69dd8b4df75872a830ed33a84918ea344`
- Product implementation commit:
  `fc2343ff5f96304ccca95fc802d3b6252b467d5b`
- Current remote PR head:
  `ea7e34ccc8ae858b4a77e4282ca7cb03c8f115f5`
- Pull request: `#33`

## Objective

Deliver a stable, metric-first Today experience and a compact, discoverable
mobile navigation model without reducing metric access, changing source
authority, or overstating simulator evidence.

## Scope

Close the remaining mobile presentation and first-run findings without changing
health formulas, source authority, cloud infrastructure, or physical-band
claims:

- remove the blank Today regions and unstable scroll presentation;
- replace the permanent bottom shelf with floating navigation;
- collapse navigation only after meaningful upward reading progress;
- let the compact control snap and persist at either bottom corner;
- preserve all five named destinations and complete metric-history access;
- begin customer band setup with one compatible-band scan instead of static
  product rows or an unavailable placeholder;
- keep the normal post-onboarding Devices entry on that same scan-only path;
- prevent the legacy transport name from reaching any shipped localization
  value or dynamic release-note surface;
- keep iPhone and Android behavior and accessibility semantics aligned.

## Starting evidence

- The candidate started from protected GitHub merge
  `1cd401f69dd8b4df75872a830ed33a84918ea344`, with the unrelated divergent
  local `origin/main` intentionally excluded.
- Android launch and scroll captures showed full-height Today sections measured
  in the feed while their delayed entrance alpha still made them invisible.
- Both mobile shells retained the full five-destination navigation, but the
  permanently reserved bottom footprint made reading space and scroll behavior
  feel heavier than necessary.
- The customer band path still presented model rows before discovery instead of
  beginning with one generation-agnostic compatible-band scan.

## Delivered

- Android Today no longer applies delayed alpha staging to measured
  `LazyColumn` sections. The prior animation reserved each section's final
  height while drawing it transparent, which produced a large blank gap during
  launch and scroll. Reorderable feed sections now render immediately and keep
  stable positions.
- iPhone and Android retain the full five-destination rail while expanded.
  Sustained upward reading progress collapses it; returning near the top or
  making a deliberate downward gesture expands it.
- Compact navigation is a floating icon, active destination name, and
  disclosure arrow. It defaults to a bottom corner, supports horizontal drag
  to the opposite corner, persists that choice locally, and exposes equivalent
  accessibility move actions.
- Android uses a stable `136dp` compact width so the longest primary label,
  `Workouts`, remains visible. iPhone keeps the active destination in the
  VoiceOver value together with its current corner.
- Normal text sizes no longer reserve a permanent iPhone footer. The measured
  control height is passed into scroll content as tail clearance, so the final
  item can clear the overlay without creating a black shelf during reading.
  Accessibility Dynamic Type still shortens the viewport to prevent large rows
  from being split behind persistent controls.
- Android compact mode reserves only the operating-system navigation inset.
  The compact disclosure floats over the page instead of occupying the
  Scaffold bottom-bar height.
- Scroll hysteresis was increased on both platforms so small corrections and
  elastic bounce do not repeatedly open and close navigation.
- Today renders every configured Key Metric rather than a six-card subset.
  `Open all metric history` opens the complete metric explorer through the
  active tab route and has deterministic accessibility identifiers.
- The quick-action detail close command is now an icon-only circular close
  control with a named accessibility action instead of a floating `Done`
  capsule.
- Customer band setup enters the existing generation-agnostic compatible-band
  scan directly. Static model-choice rows and unavailable account-linked
  placeholders are absent from that path. The optional supplier route is shown
  only when its quarantined build capability is actually present.
- The normal `More > Devices > Connect band` entry now has a stable automation
  identifier and is covered independently from onboarding. Both production
  customer entries use the same scan-only scope; the broader source catalog
  remains limited to explicit development/test scope.
- The terminology gate now parses every shipped Apple string-catalog value and
  Android string-resource value, and fails if the legacy transport name is
  rendered in any locale. Historical localization keys and internal protocol
  identifiers remain unchanged. Dynamic changelog and onboarding expectation
  copy continues through `CustomerFacingBrand` on both platforms.
- Review remediation preserves the currently selected compatible-band family
  for initial scan, rescan, and registration on both platforms. Entering the
  optional account-linked setup from discovery records that origin, so Back
  returns to the live scanner instead of exposing the development catalog.
- Android compact navigation now counts only consumed post-scroll travel,
  supplies explicit scroll-tail clearance while compact, and maps drag plus
  accessibility movement to physical left/right edges in both LTR and RTL.
- Apple complete metric history uses a real macOS navigation destination,
  iPad retains pointer hover beside touch scrubbing, selected-metric counts use
  locale plural rules, dock drags cannot also expand navigation, and legacy
  semantic dock preferences migrate to stable physical edges.
- The terminology audit now covers source-language key fallback in every
  shipped Apple catalog and all packaged Android main, demo, and debug value
  resources. Direct Test Centre and score-explainer copy is neutral, while
  protocol identifiers and persisted source IDs remain unchanged.

## Root cause

The blank Today area was not missing data or an empty container. Android's
reorderable feed measured full section height before applying a delayed
`alpha = 0` entrance state. The scroll layout therefore contained real space
whose content was temporarily invisible. Removing section-level delayed alpha
from the actionable feed fixes both the apparent blank region and the odd
scroll timing without changing data, ordering, or card dimensions.

## Evidence

| Evidence | Result | Proves | Does not prove |
|---|---|---|---|
| Android complete affected matrix | Demo and Full unit suites, both Debug APKs, and both Android-test Kotlin source sets built successfully | Both product flavors and instrumentation sources compile with the new feed, navigation, and scan behavior | OEM rendering or physical sensors |
| Android focused navigation recheck | `PrimaryNavigationContractTest` 15/15 and Demo APK assembly passed after the final full-label width change | Corner persistence, drag threshold, accessibility actions, stable full labels, and expanded rail contracts | Physical TalkBack interaction |
| Android Today regression | `TodayCompactHeroContractTest` passed with a source contract that rejects delayed alpha inside the reorderable feed | The invisible measured-height failure cannot return through the same section path | Every future animation implementation |
| Apple affected source wall | 107/107 tests passed across Bluetooth consent, device state, shell parity, Safety shell, and screen-state contracts | Apple source and accessibility contracts agree with the floating overlay and unified scan | Signed-device behavior |
| StrandDesign | 59/59 tests passed | Shared navigation geometry and design package remain valid | App-level touch behavior |
| iPhone navigation UI | Compact/expand and scroll-to-corner cases passed 2/2 | Scrolling collapses the rail and tapping the disclosure restores all tabs without changing selection | Physical touch comfort |
| iPhone metric-history UI | Complete selected-metric and history route case passed 1/1 | Eight configured metrics remain represented and the history action reaches the metric explorer | Real provider history delivery |
| iPhone first-run and quick actions | Configured completion and quick-action cases passed; fresh Terms-to-scan and unified-scan cases passed on corrected recheck | Terms, Bluetooth, scan-before-account ordering, scan-only presentation, and icon close behavior | Real account provider or BLE discovery |
| Final iPhone build | `BUILD SUCCEEDED`; simulator executable SHA-256 `ee765debf4ab5463e2f794dcd9c3552e3c4332d9f5525ff00f1e051cf35c8e63` | Exact source compiles for the iPhone Simulator | Signing or installation on a phone |
| Final Android artifacts | Demo APK SHA-256 `5d8dc888d5f9ab18af0939cd3b658dbebe9bbc530ff0a43176667fafaf8e0022`; Full APK SHA-256 `26cfaf9cb8170cdbe7a0a0e23c6ff2a29d84e1f350b9f83a51fb6c194daf9e92`; Demo Android-test APK SHA-256 `792e572a18d7f322f2c30e96c8767c8e29bba214f1ab1b9c3374983acda1d87d`; Full Android-test APK SHA-256 `abdf906720e11da024139c48c746c75b73523c5d207f9677feff0097a781f1f7` | Exact affected Android product and instrumentation artifacts package | Release signing or physical installation |
| Android customer-entry scan recheck | The rebuilt Full APK and Android-test APK were installed on API 35 without clearing app data. `AppShellInstrumentedTest#devicesConnectBandStartsUnifiedScanWithoutLegacyModelRows` and `OnboardingFlowInstrumentedTest#postTermsBandFirstFlowReachesSupportedBandPickerWithoutAccountBypass` passed 1/1 each. Both require the localized picker title and live searching state while rejecting Band 5.0 / MG, Band 4.0, and account-linked model rows. | First-run and normal post-onboarding customer entries resolve to the same implemented live scanner in the exact rebuilt artifact | Physical discovery, pairing, claim, or stale APKs installed elsewhere |
| Customer-visible terminology wall | `CustomerFacingBrandTests` passed 4/4; terminology unit tests passed 7/7; the parser reports zero legacy-name values across all Apple localizations and Android values resources; the active-use ratchet passes; reviewed source digests pin the exact audit and inventory | Shipped static localization values and reviewed dynamic release/onboarding surfaces cannot render the legacy transport name | Arbitrary future server copy outside the current reviewed boundaries |
| Protected release-control subset | 260/260 unit tests passed; complete Tools suite 376 with one intentional skip; source controls 9/9; required CI 10/10; trusted controls, calibration, terminology, legal, privacy, claims, shell, operations, and diff checks passed | Exact local candidate satisfies the repository's protected source-policy wall | Hosted runner execution or protected merge |
| Hosted localization correction | Initial PR run `37230079611` rejected 13 new hardcoded navigation, scan, and close labels. Those labels now use the existing Apple and Android resource systems; the exact CI audit passes, all four Android production/test source sets compile, and the iPhone Simulator build succeeds. Replacement Android run `37231077501` then exposed one missing complete-locale resource and two stale source contracts; the three exact failures and both complete Full/Demo unit suites pass after correction. | New customer and accessibility text is resource-backed on both platforms, with complete-locale and source-contract enforcement | Translation quality beyond the recorded locale gate or physical accessibility services |
| Hosted release-control stabilization | Run `37231919823` passed source controls, then one release-evidence test hit `Directory not empty: objects` while Python removed a temporary Git fixture. Fixture Git commands now disable automatic garbage collection and maintenance, preventing detached writes during cleanup; the formerly failing test passes 100 consecutive runs. | Temporary release-evidence repositories clean up synchronously on hosted Git versions | Unrelated hosted runner or network failures |
| Hosted Android unified-scan correction | Run `37232335010` executed 126 production-shell instrumentation tests and failed only two onboarding assertions that still waited for the removed static Band 5.0 / MG and Band 4.0 rows. The assertions now require the localized device-picker title and searching state while rejecting the static rows. Both Android-test source sets compile, focused onboarding and pairing contracts pass, and the exact API 35 cases pass 2/2. | The first-run and post-Terms customer paths enter the implemented unified live scan without reintroducing model-choice cards or an account bypass | Physical BLE discovery, device names, or account activation |
| Hosted Apple shell-contract correction | Exact-head run `37233895083` on `2d1b35249f8c7e4621877a09a726ca2ea844312a` built both Apple products, then exposed only stale tests: the macOS suite still bounded the active-tab closure by an obsolete one-line frame expression and expected superseded compact-navigation action labels, while the iOS UI suite still required ordinary text to stop above the floating bar. The contracts now bound the closure at `onDockEdgeChange`, require the current `Move to left edge` / `Move to right edge` accessibility actions, verify that ordinary text uses the full viewport, and separately verify that accessibility text reserves space. The complete local Strand suite passes 2,446 tests with one intentional skip and zero failures; both corrected iPhone viewport cases pass 2/2. | Hosted failures were obsolete assertions against the delivered floating-overlay behavior, and the current tests protect both blank-footer removal and large-text safety without changing product source | Replacement hosted execution or physical VoiceOver behavior |
| Hosted iOS transient-feedback correction | Exact-head run `37240966560` on `db9ccda25e8ea55f01273972f998172beac34c0b` passed the macOS build/tests and 43 of 44 executed iOS UI cases with one intentional skip. The pull-to-sync case successfully revealed `noop.today.pull-sync`, then queried that two-second accessibility element repeatedly until it disappeared before the final value read. The test now captures the visible status label once and evaluates that immutable snapshot; production timing and animation are unchanged. The exact case passes 3/3 locally. Xcode printed the complete passing test summary, then hung while finalizing its local result bundle and was terminated after the tests completed. | The only hosted iOS failure was a transient-element test race, and the corrected assertion survives repeated execution without weakening product behavior | Replacement hosted execution or physical pull interaction |
| Hosted iOS app-report review correction | Replacement head `ea7e34ccc8ae858b4a77e4282ca7cb03c8f115f5` passed every Android, macOS, package, policy, localization, and repository-control boundary. Apple run `37244321996` executed 44 iOS UI cases with one intentional skip and failed only `testAppReportRequiresConsentAndBuildsPrivateAttachmentReview`: the hosted simulator exceeded the prior 20-second review-readiness wait, then five dependent attachment and action assertions cascaded before the review was available. The test now waits up to 120 seconds for explicit readiness, returns after a bounded generation failure, waits for the required attachment rows, and scrolls to `noop.app-report.send` before validating the disclosure. The exact local xcresult reports 1 passed, 0 failed. Xcode later timed out while collecting simulator diagnostics, after the successful result and exit status. | The hosted failure was bounded to UI-test timing and visibility; the corrected case verifies the same privacy review and send contract without changing production behavior | Replacement hosted execution, upload service delivery, or physical-device performance |
| Android review remediation | Full and Demo unit variants each pass the six focused scan, supplier-Back, compact-navigation, RTL, scroll-tail, and connection-preservation classes; the Full run completed successfully in 2m17s and the Demo run in 2m42s | Both packaged product variants compile and enforce the corrected customer scanner plus compact-navigation behavior | Physical BLE, TalkBack, OEM insets, or touch comfort |
| Apple review remediation | Integrated iOS Simulator build succeeds. The final affected macOS wall passes 91/91 across Bluetooth consent, device state, customer-brand rendering, key-metric plurals, complete history, and shell contracts. StrandDesign remains 59/59 | Apple source compiles with family persistence, supplier return, macOS history routing, iPad hover, localized plurals, exclusive drag/tap, and physical RTL dock mapping | Signed install, physical pointer/VoiceOver behavior, or real BLE |
| Expanded terminology boundary | Audit unit coverage adds source-key fallback, all five shipped Apple catalogs, and Android main/demo/debug resources. Repository summary reports zero customer-visible retired-vendor values and zero forbidden mappings | Static shipped localization values and reviewed fallback paths are neutral across the packaged source sets | Future unreviewed server text or physical-device advertisements |
| Final October 5 repository wall | Complete Tools test root passes 379 tests with one intentional skip; release controls pass 9/9; required CI verifies 10/10 contexts; all 122 operations records validate; trust, calibration, terminology, localization, claims, legal, privacy, shell, Python, and diff checks pass | The final local source tree satisfies every repository-controlled release policy | Hosted runner execution, protected merge, signing, or physical devices |
| Diff hygiene | `git diff --check` passed before the product commit | No whitespace-error regression | Runtime behavior |

The first combined iPhone onboarding run exposed a test-query defect: the
global accessibility query found the covered onboarding page's `Back` element
under the scan sheet. The wizard's own back control was already hidden. It now
has a stable identifier, and the scan-only tests query that exact control. Both
previously affected cases then passed.

The reviewed terminology snapshot contains 18,649 classified occurrences
across 1,651 groups, with the customer category reduced to 886 and no
forbidden active use or customer-visible localization value. The active
allowlist SHA-256 is
`2c4e7f58aa2cd1e4257165788b88137747be277d5e447f0f90f858c3169af904`;
the legacy inventory SHA-256 is
`9bb90d4578acc020b05557bc5820211b92ac48d67839cb73b0b3724b0a899936`;
and the exact terminology-audit SHA-256 is
`8c3149dfa7fa1de08289e81cf1bbf56e675a2924c4e9fc2344b294cb93074f49`.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Health formula or calibration impact: none.
- Data retention, source arbitration, or provenance impact: none.
- Account protocol or OTP impact: none.
- Network or cloud API impact: none.
- New health claim: none.
- No credentials, personal data, device addresses, raw sensor frames, or
  health values were added to logs or repository evidence.

## Physical device and deployment

### Cloud and managed configuration

- No cloud source, migration, image, infrastructure, or managed runtime input
  changed in this round.
- Private synthetic staging remains at protected source merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c` and immutable image digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`.
- No cloud rebuild, deployment, migration, or apply is required.
- Ignored local managed configuration remains at
  `Config/ManagedCloudSecrets.xcconfig` and
  `android/managed-cloud.properties`; neither file is part of this change.

### Physical boundary

- No signed iPhone or Android candidate was installed.
- No physical WHOOP or supplier band was scanned, paired, claimed, switched,
  vibrated, double-tapped, backgrounded, or measured.
- No battery, retention, notification-delivery, background, haptic, sensor
  accuracy, or accessibility-service claim is made.
- The next physical round must start from clean protected `main`, verify the
  vendored neutral SDK source revision
  `b02808372b7c537f22058c7ebc75d92c750373be` and manifest SHA-256
  `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`,
  then validate WHOOP before the quarantined exact-model supplier adapter.

### Git and release state

- The product commit is based exactly on GitHub protected base
  `1cd401f69dd8b4df75872a830ed33a84918ea344`.
- A separate local `origin/main` worktree contains unrelated concurrent work
  and was intentionally not merged into this candidate.
- PR `#33` must receive the normal replacement push and every required hosted
  context. No workflow is to be manually dispatched or re-run.
- Exact head `2d1b35249f8c7e4621877a09a726ca2ea844312a` completed all hosted
  work and exposed the bounded Apple test-contract drift recorded above. The
  corrected remote replacement is
  `e7c35610c3930916c95ceda6a08e96fe369474fe`. Remote head
  `db9ccda25e8ea55f01273972f998172beac34c0b` then passed every hosted
  Android, macOS, package, policy, and repository-control boundary and failed
  only the bounded transient iOS query recorded above. The local test-only
  correction was pushed as `ea7e34ccc8ae858b4a77e4282ca7cb03c8f115f5`.
  That exact head again passed every non-iOS boundary and exposed only the
  bounded app-report review wait recorded above. The local timing correction
  and October 5 review remediation must be committed, pushed normally, and run
  through the same protected contexts.
- Merge only the exact green PR head through protected `main`, then verify the
  resulting protected-main SHA before handing off physical validation.

## Decisions

- Remove delayed section-level alpha from the reorderable Today feed because
  invisible measured content is incompatible with stable scrolling.
- Keep every named primary destination visible in expanded navigation and use
  a compact disclosure only after meaningful reading progress.
- Persist only the preferred compact corner; do not persist transient expanded
  state or scroll position.
- Keep complete metric history and the separate Add Device catalog reachable;
  the unified customer scan changes presentation, not source authority.
- Route every production band-entry action through one generation-agnostic
  scanner; keep broader source selection restricted to development/test scope.
- Enforce neutral customer copy at both static localization and dynamic
  rendering boundaries without renaming protocol or persisted identifiers.
- Treat cloud deployment as a verified no-op because no cloud source,
  migration, image, infrastructure, or managed runtime input changed.

## Open risks and honest limitations

- Replacement hosted PR contexts, review-thread resolution, and protected-main
  integration remain pending.
- The exact signed iPhone and Android candidates have not been installed.
- Physical BLE discovery, account claim, source switching, background
  collection, retention, haptics, battery behavior, notification delivery,
  sensor accuracy, and physical accessibility service behavior remain
  unvalidated.
- Simulator and source-contract evidence cannot establish supplier-band or
  WHOOP behavior on hardware.

## Next round

1. Regenerate and repin the reviewed terminology inventory after this durable
   record, then run the complete local release-control wall.
2. Push one exact replacement to PR `#33`, wait for every required protected
   context, and resolve only review threads backed by the final code and
   evidence.
3. Merge normally only when the exact head is green, then verify protected
   `main` and its naturally triggered checks.
4. Update the Downloads physical-testing handoff with the exact protected-main
   merge SHA and run the signed iPhone and Android physical-validation matrix
   from clean protected `main`, comparison transport first.

## Privacy check

- [x] No credentials, personal identifiers, health records, BLE addresses,
      signing material, supplier binaries, firmware, or private reference
      inputs are present.
