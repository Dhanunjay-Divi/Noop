# Round 16 - Cycle tracking, metric reconciliation, and source polish

**Date:** 2026-08-24
**Status:** complete and locally verified

## Scope

This round closes four user-visible gaps on Apple and Android:

1. Sleep exposed `WHOOP` and `PROVIDER SCORE` as two competing hero badges.
2. Menstrual-cycle tracking was difficult to discover after changing the
   profile to Female and disappeared when wearable history was empty.
3. Fitness Age and Vitality could retain results from the previous profile
   after date-of-birth, sex, or waist changes.
4. The Daily Signal header crowded or dropped provenance on compact layouts and
   did not explain an active Noop Band history sync.

The previously restored large-text tab labels and the most-recent-populated
Trends landing week remain intact.

## Product Contract

- An imported Sleep score uses one neutral `Imported` badge. An on-device score
  keeps its source and confidence. Stored source metadata is not deleted.
- Menstrual-cycle setup appears directly below Sex in Profile and remains
  reachable from Health before the first wearable reading.
- Cycle awareness is private, opt-in, and non-diagnostic. It never presents a
  fertility, contraception, safe-day, or exact ovulation claim.
- User-logged period starts anchor cycle day and period cadence. Recent
  variability widens the estimated window; stale, implausible, or highly
  variable logs suppress the forecast instead of inventing precision.
- A temperature shift requires two elevated nights in a trailing three-night
  window, reducing one-night artifact sensitivity.
- Fitness Age and Vitality reconcile after relevant profile or active-device
  changes and on foreground return across a birthday. Failed reads, writes, or
  completion-marker persistence remain retryable.
- Daily Signal keeps source and state visible at compact widths. A Noop Band
  history transfer uses an indeterminate sweep because the protocol does not
  expose a truthful total; completion is confirmed briefly in green.

## Implementation Map

- `CyclePhaseEngine.swift` and `CyclePhaseEngine.kt`
  - Add confirmed shift detection, current-day log advancement, recent cadence
    variability, and fail-closed forecast gates.
- `SettingsView.swift`, `HealthView.swift`, `SkinTempCardsView.swift`
  - Add the discoverable profile row, no-history setup path, localized cycle
    ring, confidence, log history, and private symptom/flow workflow.
- Android `SettingsScreen`, `HealthScreen`, and `SkinTempCardsScreen`
  - Mirror the Apple behavior and presentation.
- `AppModel`, `IntelligenceEngine`, and `Repository`
  - Reconcile Apple age-dependent projections and publish a focused refresh
    sequence only after persistence boundaries are reached.
- Android `AppViewModel` and `AgeMetricReconciliationRunner`
  - Debounce, cancel stale work, bind recomputes to the captured device, and
    advance the completion marker only after a checked background commit.
- `LiquidTodayView` and Android `TodayScreen`
  - Keep the Daily Signal identity, source, and state aligned and add honest
    band-history sync feedback.
- `SleepView`, `SleepHeroLogic`, and `SleepScreen`
  - Replace provider-specific hero copy with the neutral imported source.
- `Tools/AppWideLocalization/appwide_strings.json`
  - Expand the generated app-wide catalog from 136 to 183 keys across all nine
    supported locales.

## Verification

- StrandAnalytics: **1,330 tests passed**.
- macOS app suite: **1,402 passed**, 1 intentional skip, 0 failures.
- iOS generic simulator Debug build: **passed**.
- iOS production-shell suite on iPhone 17 Pro: **21/21 passed**.
- Android Full Debug unit suite: **3,595 tests**, 0 failures, 6 skipped.
- Android Full Debug APK: **assembled**.
- Android managed Pixel API 35 instrumentation: **3/3 passed**.
- App-wide localization: **183 keys**, exact Apple/Android parity across nine
  locales; generator rerun was idempotent.
- i18n regression gate: **passed**, no new baseline debt.
- Health-claims gate: **clear across 1,042 files**.
- Runtime legal inventory: **152 components and 3 container inputs verified**.
- Independent reviews found one Android completion-marker durability issue; it
  was fixed and covered by a failed-write/retry regression. No other concrete
  reconciliation finding remained.
- `git diff --check`: **passed**.

The first macOS run caught the stale 136-key test total. The first iOS UI run
caught a stale assertion that expected `90 of 90 days` while the deterministic
fixture truthfully has Recovery on 89 of 90 days. Both test contracts were
corrected, focused reruns passed, and the complete suites then passed.

## Limitations

- This does not validate fertility, ovulation, pregnancy, contraception, or any
  medical use of the cycle model.
- Simulator and unit evidence do not validate physical Noop Band sync,
  background behavior, haptics, battery impact, or sensor accuracy.
- The new reproductive-health translations still require native-speaker review.
- The current NOOP owner declaration governs source rights.
