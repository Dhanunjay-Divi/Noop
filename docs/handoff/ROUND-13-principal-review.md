# Round 13 — End-to-end principal review

**Date:** 2026-08-23
**Branch:** `codex/noop-production-handoff-20260823`
**Scope:** everything on the branch since `ui-v1-baseline` (828 files, +81k lines), reviewed cold.
**Mandate:** "review all work with fresh eyes end to end, don't miss anything, for everything question
yourself what's this / why this, fix what needs fixing, document the fixes, run the app with mock metrics."

Final state: **iOS BUILD SUCCEEDED · macOS BUILD SUCCEEDED · 1,322 engine tests 0 failures · 1,360 macOS
app tests 0 failures** (1 pre-existing skip).

---

## 0. Read this first: the tree was being written while it was reviewed

Another agent/process was **actively editing the same working tree throughout this review**. Evidence:

| Time | Observation |
|---|---|
| 05:36 | Full suite: 5 failures, incl. `MetricCatalogStepsTests` expecting `"NOOP / strap"` |
| later | Same two tests pass with **no edit from me** — HEAD already said `"Noop Band"` |
| — | `ScreenStateContractTests` count pin changed `61 → 71` between two of my runs |
| 13:25:48 | `CalendarMonthView.swift` grew 470 → 626 lines (my fixes survived) |
| 13:28:34 | `HealthView.swift` written mid-build → `cannot find 'HealthTimelineSection'`; the symbol existed 2 min later |
| 13:29:41 | `RootTabView.swift` rewritten, breaking `MoreListParityTests` |

**Consequences, stated honestly:**
1. Two of the five failures I first reported (`MetricCatalogStepsTests`, `StressModelCarryTests`) were
   **not real defects** — they were artifacts of reading a tree mid-write. Corrected here rather than
   claimed as fixes.
2. Transient build errors appeared in files I never touched.
3. **Any green result — including this one — has a shelf life.** Re-run before trusting it.

**Recommendation:** don't run two agents on one working tree. Give each its own clone/worktree and merge
through git. This is the highest-value process finding of the round.

---

## 1. Fixed — engines (behaviour and honesty)

### E1 · Android crash on non-finite Effort *(MEDIUM, real crash)*
`HydrationGoal.kt` `effortBump` lacked the `isFinite` guard its Swift twin has (`HydrationGoal.swift:76`).
NaN reached `roundToInt()`, which **throws `IllegalArgumentException` on Kotlin/JVM** — the same input
Swift absorbs and returns `0` for. Both an Android-only crash and a parity break.
**Fix:** `if (effort == null || !effort.isFinite()) return 0`.

### E2 · Withdrawn claim still in the header *(MEDIUM, false science)*
`RecoveryScorer` header still read "Z = 0 → ~58% (**WHOOP's published population-average recovery**)",
directly contradicting the nearby honesty note that had already withdrawn that attribution.
**Fix (both platforms):** the logistic is documented as an internal personal-baseline display mapping,
not a population statistic or cold-start fallback; D-025 later removed the unused fallback symbol.

### E3 · UK Biobank SRI hazard ratio applied to a proxy it wasn't derived from *(MEDIUM)*
`VitalityEngine` cited "most-regular vs least ≈ HR 0.70 (UK Biobank SRI)" for coefficient `0.450`, but the
input is `sleepConsistency` = **1 − CV of nightly duration**, which the same file admits is a stand-in
"when we only have durations, not full timing". Published SRI hazards come from sleep–wake **timing**
across 24-hour epochs. This is the same conflation `AnalyticsEngine` had already corrected — missed here,
and it feeds a user-facing "years of aging".
**Fix (both platforms):** attribution withdrawn, constant marked INTERNAL/UNCITED, with an explicit
instruction not to re-attribute it.
**Deliberate non-fix:** the numeric value is unchanged. Replacing an over-claimed constant with an
arbitrary attenuation would swap one uncited number for another while moving a headline user metric.
Logged as validation backlog: compute a real timing-based SRI, then re-fit.

### E4 · Stale hydration baselines in headers *(LOW)*
Headers still listed `3700/2700/3200` after the total-water → drink-water correction (actual
`2960/2160/2560`), overstating the goal by ~740 ml. **Fix:** headers corrected on both platforms with the
derivation and a "do not restore" note.

**Verified correct, no action:** Rest weights `0.50/0.10/0.20/0.20` sum to 1.0 and match Kotlin byte-for-byte;
hydration baselines confirmed by exact integer math (`3700×80/100=2960` etc.); `StressHeatmap` handles empty
input, clamps hours, never zero-fills; every engine *constant value* matches across Swift/Kotlin.

---

## 2. Fixed — the month calendar

### C1 · Colour valence was inverted for two of four metrics *(MAJOR, actively misleading)*
One shared ramp painted **low = red, high = good** for *all* metrics. So:
* a **rest day** (low Effort) was painted alarm-red, and
* a **high autonomic-load day** (high stress) was painted the positive tint.

The screen was telling users the opposite of the truth for half its metrics.
**Fix:** valence is now a property of the metric:

| Metric | Valence | Ramp | Legend |
|---|---|---|---|
| Recovery, Sleep | higher is better | red → amber → tint | Low / Middling / Strong |
| Load | higher is **worse** | tint → amber → **red** | Calm / Elevated / High |
| Effort | neither — a quantity | one hue, 3 intensities, **no red** | Easy / Moderate / Hard |

Legend swatches are now generated by calling `stepColor` itself, so legend and grid can never disagree.
**Verified visually** in all three modes (screenshots in `noop_WIP/screenshots/r13/`).

### C2 · Experimental proxy rendered as if it were a scored metric *(MAJOR, brand promise)*
`Load` is derived from resting HR + HRV only, and its readout carries `confidence` +
`limitations(experimentalNonClinicalProxy, singleSignalEstimate, staleSourceDay)` — **all discarded**, so it
looked exactly like Recovery under a plain "Load" label.
**Fix:** a provenance line renders whenever Load is selected: *"Load is an experimental estimate from
resting heart rate and HRV only, not a scored metric. Treat it as a hint."* The legend is no longer hidden
from assistive tech, because that sentence is information, not decoration.

### C3 · Title and subtitle hard-coded in English *(MAJOR, localization)*
`title: "Your month"` / `subtitle: "One ring per day"` were literals — **8 of 9 locales showed English**
even though `appwide.calendar.your_month` was already translated. **Fix:** both use catalog keys
(`appwide.calendar.subtitle` added in all 9 locales).

### C4 · Per-day VoiceOver was English-only *(MINOR)*
`spoken()` called `String(localized:)` on an **interpolated** string, producing a throwaway key present in
no catalog — every day cell spoke English regardless of locale, and `"Today, "` was glued on in a word
order that doesn't hold in other languages. **Fix:** four real format keys, translated ×9.

### C5 · Low-intensity contrast *(MINOR, a11y)*
The neutral ramp's floor of `0.38` alpha on a near-black canvas fell below the ~3:1 contrast a non-text UI
element needs — an easy day and its legend swatch were nearly invisible (caught by *looking* at the
screenshot). **Fix:** floor raised to `0.55` (ramp `0.55/0.75/0.95`).

### C6 · Thresholds — *investigated, NOT a defect*
The audit flagged `34/67` as diverging from "app bands 25/50/70/88". **Wrong:** `RecoveryScorer.bandRedMax
= 34.0` and `bandYellowMax = 67.0` are the canonical constants. The calendar agreed with the app all along.
**Improvement anyway:** the literals now reference those constants, so they cannot drift.

### C7 · `%s` vs `%@` format drift — *investigated, NOT a defect*
The generator's `apple_format` converts `%1$s → %1$@` and `%1$d → %1$lld`. Verified **zero**
non-positional specifiers in the source JSON.

---

## 3. Fixed — reproductive-health privacy

This was the most serious area, and the failing test was right for a reason I initially misread.

### P1 · A test caught a real capability change, not test drift
`AppleHealthAutomaticIngestionContractTests` asserted the opt-in copy contains *"never flow intensity,
symptoms, fertility or contraception data"*. The app has since gained **optional, user-typed flow and
symptom logging** (`CycleTrackingStore.Flow` / `.Symptom`, a delete-all control). The absolute promise
stopped being true, so the copy was changed — correctly — and the test failed.
**Verified the protections that matter still hold:** `menstrualFlow` is **not** in general `readTypes`
(count = 0); the cycle request is read-only (`toShare: Set<HKSampleType>()`); dedicated consent gate and
`cycleImportExplicitlyRequested` intact; flow/symptom detail is independently erasable.
**Fix:** the test now pins the *current* contract — optional-and-private disclosure, awareness-only
framing, no fertility-window claim, and independent erasure — instead of a withdrawn absolute.

### P2 · A privacy-scope doc comment that had become false *(MEDIUM)*
`CycleTrackerView`'s comment claimed the store "deliberately records one date per cycle—**not symptoms,
flow**, fertility, contraception, or diagnoses" — three lines above `selectedFlow` and `selectedSymptoms`.
A privacy-scope comment that lies is worse than none, because it is what the next reader trusts.
**Fix:** replaced with a precise ALWAYS / OPTIONAL / NEVER scope statement.

### P3 · A translated privacy disclosure silently became English-only *(MEDIUM, localization regression)*
The reworded disclosure had **no catalog entry**, so this reproductive-health text rendered in English in
all 9 locales, while the old (now-false) version sat orphaned in the catalog still promising something the
app no longer does.
**Fix:** new disclosure added in all 9 locales; orphan removed so it cannot be resurrected. Non-English
values are marked **`needs_review`** — machine-assisted translation of reproductive-health copy should get
native-speaker sign-off, and a flagged translation beats silent English.

> Note: the odd-looking "kept locally-never flow intensity" was **not** a typo — it is an artifact of the
> project's em-dash ban (§5). I nearly "fixed" it by adding an em dash, which the policy test would have
> rejected.

---

## 4. Fixed — cross-platform parity

### S1 · Ready-with-no-target rendered differently on each platform *(MEDIUM)*
Kotlin renders the **calibrating** state row when a `READY` plan carries no target; Swift fell through and
drew a **bare action line** with no range and no explanation. Both planners currently gate `target` before
emitting `.ready`, so it is a dead path *today* — but an un-mirrored fallback is exactly how a future
planner change becomes a silent divergence. **Fix:** Swift now mirrors Kotlin (same row, same strings, no
`action` argument).

### S2 · Two driver engines can tell contradictory stories — *documented, deferred*
The WHY section builds from `ReadinessEngine.signals`; the Charge breakdown elsewhere uses
`ChargeDrivers`/`RecoveryDrivers`. Both are legitimate, neither is hand-rolled in the view — but they can
name different drivers for the same day. **Not changed:** unifying them alters user-visible narrative and
needs a product decision. Logged as the top follow-up, with a test asserting the two orderings cannot
contradict.

**Verified good:** Android genuinely *renders* why/target/watch (`DailyPlanWhy/Target/WatchSection`) — the
enum was not merely declared. `minimumEffortDays = 7` matches copy and both platforms. No numeric
threshold divergence in these sections.

---

## 5. Fixed — my own violations and self-inflicted damage

Recorded because a review that hides its own mistakes is worthless.

### V1 · I introduced an em-dash and broke a policy test
`UserVisiblePunctuationPolicyTests` forbids U+2014 in localization resources. My Russian string used one.
**Fix:** em dash → colon, at the JSON source, then regenerated.

### V2 · I corrupted the String Catalog, then repaired it
I rewrote `Localizable.xcstrings` with `json.dump(indent=2)`. The Ruby generators strip their namespace
with a **line-based** regex (`^\s+"appwide\.[^"]+":`) that assumes **one entry per line**. Reformatting
made entries multi-line, so the strip removed only key lines and orphaned their bodies → invalid JSON
(6.6 MB file, "Extra data" at line 182476).
**Recovery:** restored the catalog from HEAD, re-ran all five generators (AppWide 87, Safety 204, Coach 49,
Nutrition 99, DailyPlan 50), then made the two bare-English edits with **format-preserving brace-counted
surgery** instead of a reformat. Validated: parses, 4,508 strings, 0 em-dashes.
**Lesson for anyone automating this file: never pretty-print `Localizable.xcstrings`.**

### V3 · I assumed prototype code was dead — it wasn't
I excluded `Strand/UIv2` wholesale. Both targets failed: the **shipping** `LiquidTodayView` renders
`V2HeroArc`, `V2SatelliteRing` and `V2Chip` from `UIv2/NoopV2Components.swift`, which also needs
`NoopV2Tokens.swift`. The audit and I both called it dead code; the compiler disagreed.
**Corrected to file-level excludes** (below), and flagged: production components living in a folder named
`UIv2` is a naming trap — **follow-up: move them out.**

---

## 6. Fixed — dead code removed from the shipping binary

`TodayV2View`, `V2MonthCalendar`, all of `UIv3`, all of `UIv4` — **1,648 lines** reachable only through
`--demo-screen` flags — were compiled into both app targets. Their ideas already graduated into the real
app (WHY / TARGET / WORTH-WATCHING sections; `CalendarMonthView` supersedes `V2MonthCalendar`).
**Fix:** excluded per-file in `project.yml` for both targets; dangling demo-harness arms removed. Files
remain in the repo for reference — restore by deleting the exclude lines.

**`StressHeatmap` is now consumer-free** (its only user was the excluded prototype). Kept deliberately:
pure, 11 tests, cross-platform twin, and an hourly-stress view is plausible. Flagged so it doesn't rot
unnoticed.

---

## 7. Fixed — stale contracts left by in-flight work

| Test | Was | Now | Why the code was right |
|---|---|---|---|
| `ScreenStateContractTests` (safety) | 182 | **204** | Deliberate count canary; new strings complete ×9 |
| `ScreenStateContractTests` (appwide) | 61 → 71 | **87** | Same, plus my 16 calendar keys |
| `ScreenStateContractTests` (tab bar) | `expandedReservedHeight = 88` | **76** | Bar body shrank 56 → 48pt; source comment updated coherently |
| `MoreListParityTests` (tab label) | `? "Train" : item.title` | localized title + `minimumScaleFactor` | See below |
| `TodayLayoutPrefsTests` ×4 | 9 sections | 12 sections | New sections insert at default position — the never-hide contract |

**Tab label, resolved on the evidence:** the in-flight edit removed the `"Train"` shortening but left its
comment *and* test asserting it — an incomplete change. But **`"Train"` was never in the String Catalog**,
so it shipped untranslated in all 9 locales. Their direction was the more correct one; I completed it
rather than reverting it: comment corrected, helper documented as a seam for a *translated* future
shortening, and the test now pins the localized label, `minimumScaleFactor(0.8)`, **and the absence of the
bare literal** so the untranslated shortening cannot quietly return.

---

## 8. Reviewed and approved without change

* **Fall response** — the constraint says "no fall detection", and `FallResponse.swift` exists. It is
  **honestly gated, not a violation**: a host-side contract for a *future validated band detector*; no
  production code constructs a candidate; the phone never derives a fall from history, HR or wellness
  scores; UI states "Not active" / "Supported band firmware required"; copy is explicit that NOOP "does not
  dispatch emergency services" and that "delayed history and wellness scores can never trigger it". This is
  how to stage a safety feature.
* **`FloatingQuickAddButton`** — supersedes the `TodayQuickActionButton` I wrote last round, and is better:
  44pt when compact, respects `accessibilityReduceTransparency`, doesn't shrink at accessibility Dynamic
  Type sizes, and its a11y hint enumerates the actions. Correctly dropped.
* **Calendar reachability** — reached from the top masthead icon (`noop.today.calendar`), matching the
  "top icons easily noticeable" preference.
* **No-fabrication guarantee in the calendar** — days without data render as empty outlines; the summary
  averages only real values and says so. Confirmed visually: days 24–31 empty, "23 days scored".
* **Date maths** — `leadingBlanks` vs `Calendar.firstWeekday`, weekday-symbol rotation, year/DST rollover:
  no dropped or duplicated day, no force-unwraps.

---

## 9. Follow-ups (ranked)

1. **Stop concurrent agents sharing one working tree** (§0) — process fix, blocks reliable verification.
2. **Native-speaker review** of the 8 `needs_review` cycle-disclosure translations (§3 P3).
3. **Decide WHY's driver engine**: unify on `ChargeDrivers` or document the split, plus a
   no-contradiction test (§4 S2).
4. **Move `NoopV2Components.swift` / `NoopV2Tokens.swift` out of `UIv2`** — production code in a prototype
   folder is a trap that already bit once (§5 V3).
5. **Real timing-based SRI**, then re-fit the sleep-regularity coefficient and restore a citation (§1 E3).
6. **Give `StressHeatmap` a consumer or retire it** (§6).
7. **Guard the catalog**: a test asserting `Localizable.xcstrings` stays one-entry-per-line would have
   caught V2 immediately (§5 V2).

---

## 10. Verification

```bash
cd /Users/divii/noop-sandbox/Noop && xcodegen generate

# iOS + macOS
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug \
  -derivedDataPath /tmp/dd build CODE_SIGNING_ALLOWED=NO          # ** BUILD SUCCEEDED **
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath /tmp/mac_dd build CODE_SIGNING_ALLOWED=NO   # ** BUILD SUCCEEDED **

# engines: 1,322 tests, 0 failures
(cd Packages/StrandAnalytics && swift test)

# app suite: 1,360 tests, 0 failures, 1 skipped
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/mac_dd CODE_SIGNING_ALLOWED=NO

# visual QA (new hook: preselects the metric so each valence can be captured)
xcrun simctl launch "iPhone 17 Pro" com.noopapp.noop \
  --demo-seed --demo-screen calendar --demo-calendar-metric load
```

Screenshots: `noop_WIP/screenshots/r13/{liquidtoday,calendar,calendar_effort,calendar_load}.png`.

### Reverting this round
Engine and privacy fixes are independent, one concern per hunk. To restore the prototypes to the build,
delete the `UIv2/…`, `UIv3`, `UIv4` exclude lines in `project.yml` (both target blocks) and re-add the
`todayv2`/`v2calendar`/`todayv3`/`todayv4` arms in `StrandiOSApp.swift`.
