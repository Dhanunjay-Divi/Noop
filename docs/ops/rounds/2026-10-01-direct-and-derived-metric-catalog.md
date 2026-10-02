# Round: 2026-10-01 - Direct and derived metric catalog

## Status

- State: `locally verified after hosted-gate repair; replacement hosted checks pending`
- Owner: project team
- Branch: `codex/today-metric-catalog-fitness-age-20261001`
- Start commit: `232f746e045d2755947579c3408efc5c3b84ff69`
- End implementation commit: commit containing this round record
- Record commit or PR: PR `#27`

## Objective

Make the basic wearable measurements easy to find without turning Today into an
unbounded dashboard or presenting a computed estimate as a direct measurement.
Apple and Android should expose the same Today-ready choices, preserve Steps in
the fresh-install snapshot, and clearly distinguish source data from NOOP
insights.

## Scope

### In scope

- Today-ready metric choice, ordering, grouping, labels, values, trends, and
  detail routes on Apple and Android.
- Direct-versus-derived provenance language.
- Source-safe average HR, maximum HR, asleep time, measured VO2 max, and Steps
  handling.
- Focused builds, tests, localization generation, visual review, and durable
  operations evidence.

### Non-goals

- Adding every specialist metric to the bounded Today snapshot.
- Changing formulas, storage, retention, permissions, accounts, network paths,
  BLE transports, or firmware.
- Claiming physical Apple Watch, WHOOP, supplier-band, HealthKit, or Health
  Connect behavior from a simulator.

## Starting evidence

- Steps already existed in the full catalog and fresh-install defaults, but the
  editor did not clearly separate source measurements from computed insights.
- Average HR, maximum HR, asleep time, and measured VO2 max existed in source
  or history paths but were not all available as matched Today choices.
- The full metric-history catalog already covered specialist sleep, activity,
  body, nutrition, and mind signals and should remain the comprehensive path.
- Motion-derived wrist counts and `vo2max_est` already had explicit truth
  boundaries that the Today expansion had to preserve.

## Delivered

- Apple and Android now expose the same 18 Today-ready choices:
  Recovery, Sleep, Effort, HRV, resting heart rate, average heart rate, maximum
  heart rate, blood oxygen, respiratory rate, measured VO2 max, skin
  temperature, asleep time, Steps, calories, weight, hydration, stress, and
  vitality.
- The fresh-install six remain HRV, resting heart rate, blood oxygen,
  respiratory rate, Steps, and weight. Steps is therefore visible without
  opening the editor.
- The editor groups unselected choices under:
  - `Measured & imported`: a compatible wearable, Apple Health, Health Connect,
    or a confirmed log.
  - `Source-dependent`: measured when the selected source provides it, otherwise
    explicitly labelled as a NOOP estimate. Calories uses this lane.
  - `NOOP insights`: values computed from available measurements and history.
- Selected rows use compact metadata such as `Vitals · Measured` and
  `Wellbeing · NOOP`; the full provenance explanation remains in the group
  header.
- Average heart rate and maximum heart rate use the cross-source resolver with
  the active/imported compatible-band lane preferred and compatible Health data
  available as fallback.
- Measured VO2 max uses the Health measurement lane. It never falls back to or
  relabels NOOP's separate `vo2max_est` model output.
- Asleep time uses the daily total-asleep measurement. Detailed sleep stages,
  sleep need/debt, heart-rate zones, body composition, workouts, nutrition, and
  other specialist signals remain available in their dedicated screens and the
  full metric-history catalog instead of crowding Today.
- Primary Steps remains measured-source-only. Apple Health or Health Connect
  pedometer totals win; an exact registry-qualified supplier total may fill a
  missing day. Wrist-motion counters and calibrated motion estimates remain
  excluded from the primary Steps value and trend.
- WHOOP Steps is not exposed. The current WHOOP BLE counter is unvalidated and
  the supported WHOOP export parser has no Steps field, so neither path may
  manufacture a customer-facing total.
- Generic imported Apple records are labelled `Apple Health`, not `Apple
  Watch`. The flattened import currently does not retain source-device identity
  and can include iPhone, scale, or third-party app records.
- The comprehensive Apple catalog now contains an explicit source-qualified
  descriptor for every persisted Apple Health key: heart rate, HRV, respiratory
  rate, blood oxygen, VO2 max, sleep totals and stages, Steps, energy, hydration,
  weight, body composition, and body/wrist temperature.
- Android Trends and Compare use stable `source:key` identities. Duplicate keys
  from Apple Health, Health Connect, compatible bands, and NOOP remain separate,
  and fixed windows use calendar days rather than the last N stored records.
- Android measured Weight now resolves only a real Apple Health or Health
  Connect reading at or before the selected day. A future reading and the
  profile setup value cannot fill the measured card.
- Today remains limited to three through six selected cards. `Open all metric
  history` remains the route to the comprehensive catalog.
- All new labels and provenance copy are generated for the nine supported
  locales.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Android Full focused wall | `BUILD SUCCESSFUL` in 48 seconds; 29 tasks including Full resources, Kotlin compilation, and the focused catalog tests | Android enum/order parity, grouping, routing, measured-series contracts, resources, and compilation | Physical Health Connect, WHOOP, or supplier-band reads |
| Apple focused tests | `xcodebuild` exited 0 for `KeyMetricProgressSemanticsTests`, `KeyMetricPrefsTests`, and `LiquidKeyMetricTrendTests` | The 18-choice contract, default Steps visibility, origin classification, bounded-progress semantics, measured metric trends, and motion-only Steps exclusion | Signed-device HealthKit or BLE behavior |
| macOS app graph | `Strand` build exited 0 | The shared Apple catalog and classic Today exhaustive switches compile | Physical Apple Watch or wearable import behavior |
| iPhone Simulator graph | `NOOPiOS` build exited 0 for iPhone 17 Pro Simulator, including Watch and app extensions | Current Apple mobile graph compiles with the new choices and localization | Apple Watch sensor delivery, background sync, battery, or accuracy |
| iPhone visual review | Current 1206x2622 editor capture reviewed; Vision OCR confirmed `Vitals · Measured`, `Activity · Measured`, `Available Metrics`, and `18 supported` | The selected rows no longer wrap their provenance metadata and the source grouping is visible | Every locale, Dynamic Type size, or physical display |
| App-wide localization generation | `Generated 997 app-wide strings and 45 Android-only resources for 9 locales` | Apple and Android generated resources are synchronized, including the localized compact metadata and source-dependent provenance copy | Human linguistic review of every translation |
| Android source-qualified metric wall | Full Kotlin compilation passed; 137 focused tests passed across `TodayMetricTilesTest`, `KeyMetricPrefsTest`, `TodayExplainabilityTest`, `TodayChargeTapCollapseTest`, `WearableCapabilityCatalogTest`, `MetricHistoryCatalogTest`, and `ComparePrefsTest` | Source-qualified history identities, provider separation, calendar windows, measured Weight day bounds, supplier-native Steps arbitration, and WHOOP Steps fail-closed behavior compile and pass | Physical Health Connect, WHOOP, or supplier-band delivery |
| Apple source-qualified metric wall | 61 focused `StrandTests` passed plus 12 `WearableCapabilityCatalogTests` | Every persisted Apple Health key is catalogued, generic provenance remains Apple Health, origin copy compiles, and WHOOP Steps is not advertised | Signed-device HealthKit/Apple Watch delivery or physical accuracy |
| Localization regression gate | `FeedbackLocalization/generate.py --check` and `i18n_audit.py --ci origin/main` exited 0 | No new hardcoded Android UI copy, no new unextracted Apple copy, focus-locale completeness, and customer-facing brand boundary | Runtime layout in every locale |
| Android post-localization focused wall | `BUILD SUCCESSFUL` in 44 seconds for Full Kotlin compilation plus `KeyMetricPrefsTest` and `TodayMetricCatalogContractTest` | The generated formatter resource resolves and the metric catalog contracts remain green | Physical Health Connect, WHOOP, or supplier-band reads |
| Hosted exact-head triage | Exact head `fd8f10ac6964844655799b3d5a07f690b268d5d9` passed Swift packages, macOS, server, release controls, production shell, and review-sample shell. Its failing jobs isolated one stale Android performance-source assertion, one non-localized Android Compare formatter, two non-localized Apple accessibility labels, and stale Apple UI assumptions around the configured onboarding marker and replacement chart accessibility node. | The remaining hosted failures were bounded to source/test/localization contracts rather than missing metric-catalog implementation | A replacement exact head or physical-device behavior |
| Android hosted-gate repair | Bounded `compileFullDebugKotlin` plus focused `RuntimePerformanceContractTest` and `AndroidLocalizationPolicyTest` passed: `BUILD SUCCESSFUL` in 1 minute 43 seconds, 29 tasks | The performance contract now verifies the selected-day-bounded weight query, and Compare uses the generated localized metric metadata formatter | The complete replacement hosted Android wall or physical data delivery |
| Apple localization and chart repair | `FeedbackLocalization/generate.py --check` passed for 86 app-report strings across nine locales; `i18n_audit.py --ci github/main` passed with no new Android hardcoded literals, Apple unextracted literals, focus-locale gaps, or brand-boundary violations | Source accessibility labels and Android Compare metadata remain localizable, and the chart exposes one coherent accessibility element instead of a duplicate invisible selected-point node | Human review of every translation or signed-device VoiceOver behavior |
| Apple focused UI rerun | `testConfiguredProviderAndSyntheticBandCompleteFullOnboarding` passed in 55.620 seconds and `testRecoveryTrendSupportsExactDateScrubbing` passed in 16.244 seconds on the dedicated iPhone Simulator; Xcode reported `TEST SUCCEEDED` for 2 tests with zero failures before a post-test simulator-diagnostics timeout | The configured flow reaches visible Bluetooth, advances to the device chooser, and exact-date chart scrubbing changes the same chart semantic value without navigating away | Physical BLE, signed installation, or every production-shell UI case |
| Terminology and release-control ratchets | 18,596 classified occurrences across 1,643 path/category groups; zero forbidden mappings; reviewed allowlist digest `00db1a24683e00fb776e680a24d7cf58cb56cb47031057fd6c015f286582736d`; reviewed inventory digest `0dad0a30b11570e0e88747f9a9ca738bac9f7203396d75d68b0ececbe471f092`; exact 258-test release-control wall passed | New compatible-band resolver identifiers, persisted source IDs, tests, historical records, and generated line movement are explicitly classified and pinned without adding a customer-facing vendor-to-NOOP mapping | Removal of pre-existing compatibility terminology or physical transport behavior |
| Diff hygiene | `git diff --check` passed | No whitespace-error regression in the working patch | Runtime correctness outside the tested scope |

## Data, privacy, and medical truth

- No metric formula, schema, retention rule, account behavior, network path, or
  device permission was changed.
- Origin labels describe provenance, not accuracy certification.
- Higher average or maximum heart rate is not presented as better progress.
- VO2 max is shown as measured only when the measurement source exists.
- Steps is not inferred from heart rate and motion-only wrist evidence does not
  become a pedometer count.
- A source name is not inferred from a framework aggregate: Apple Health data
  is not called Apple Watch without retained device provenance.
- Profile setup weight is not presented as a dated measured reading.
- No personal health values, credentials, device identifiers, or private
  supplier artifacts were added to repository evidence.

## Physical device and deployment

- Install/update action: unsigned iPhone Simulator candidate only.
- Generalized device and OS class: iPhone 17 Pro Simulator on iOS 26.5.
- BLE/background/haptic/battery scenarios exercised: none.
- Apple Watch, WHOOP, supplier-band, HealthKit, and Health Connect physical
  validation remains required under
  `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.
- No firmware was flashed and no physical-device claim is made.

## Git and release state

- Exact hosted head `fd8f10ac6964844655799b3d5a07f690b268d5d9`
  exposed bounded stale contract and localization failures after the metric
  implementation itself had passed the focused local walls.
- The replacement repair is locally verified on the same active branch.
- A replacement push, exact-head required checks, protected integration, and
  clean-main verification remain pending.
- No deployment, store upload, signed build, firmware action, or production
  traffic was dispatched.

## Observability review

- This repair changes localized presentation and test observation only. It
  does not add a persistence, import, network, account, BLE, background, or
  long-running runtime boundary.
- Existing `AppDiagnosticsRecorder` paths remain unchanged. Adding a runtime
  event for a localized label or XCTest element re-query would add noise
  without diagnosing a customer operation.
- No health values, source identifiers, device identifiers, raw errors, or
  user content were added to logs or evidence.

## Decisions

- Keep Today bounded to three through six cards; use full metric history for the
  comprehensive catalog.
- Classify Recovery, Sleep, Effort, Stress, and Vitality as NOOP insights; keep
  direct readings and confirmed logs under measured/imported source data.
- Show only measured VO2 max in the direct tile and keep `vo2max_est` separately
  named.
- Keep primary Steps measured-source-only and retain motion estimates only in
  explicitly labelled diagnostic/research paths.

## Open risks and honest limitations

- Android visual review remains pending an attached emulator or phone.
- Physical-source availability differs by watch model, band firmware, granted
  permissions, wear time, and export contents; missing source data must remain
  missing rather than fabricated.
- WHOOP Steps remains unavailable until a validated transport or import field
  exists. This is an intentional truth boundary, not an incomplete UI route.
- Average/max heart rate, VO2 max, sleep, and Steps still require signed
  physical-device source validation before release claims.

## Next round

1. Integrate the consolidated branch through protected review and exact-head
   checks.
2. Run the signed iPhone and Android physical-source matrix from the band
   validation handoff.
3. Record Apple Watch, WHOOP, supplier-band, HealthKit, and Health Connect
   availability and missing-data behavior without weakening source gates.

## Hosted check follow-up

- Exact head `fd8f10ac6964844655799b3d5a07f690b268d5d9`
  completed 38 checks. Swift packages, macOS, server, runtime license,
  production shell, review-sample shell, and trusted release controls passed.
- The complete Android wall failed only the stale
  `RuntimePerformanceContractTest` source assertion after measured Weight had
  correctly moved to `latestAppleDailyWeightAtOrBefore(..., selectedDayKey)`.
  The repaired focused wall passes.
- The i18n job identified the Android Compare interpolation and two Apple
  source accessibility labels. All now use generated/localized formatters, and
  the complete local i18n audit passes.
- Apple UI failures were repaired by observing the visible Bluetooth boundary,
  waiting for the actual device chooser, re-querying the SwiftUI chart semantic
  node after selection, and removing its duplicate one-pixel accessibility
  overlay. The two focused UI cases pass together.
- Replacement exact-head hosted checks remain required before protected
  integration.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
