import Foundation

// HydrationGoal.swift — pure daily hydration goal math for the opt-in Hydration tracker (MVP).
//
// LOCAL-ONLY, OPT-IN, MANUAL-FIRST: the user logs water with quick taps; this enum computes the day's
// target in ml. It is a plain, transparent guide built from a sex baseline plus a small bump scaled by
// the day's Effort (strain) — NEVER medical advice and never an invented measurement. The whole formula
// lives here so it is headless and unit-tested, and is BYTE-IDENTICAL to the Android twin
// (com.noop.analytics.HydrationGoal): same Int constants, same round-then-clamp, same integer rounding.
// Do not change a constant or a rule on one platform without the other.
//
//   GOAL(ml) = roundToNearest( sexBaseline + effortBump, 50 )
//     sexBaseline : male 2960, female 2160, unspecified/other 2560 ml (DRINK water: the
//                   EFSA/IOM total-water references 3700/2700/3200 minus the ~20% that
//                   comes from food, so this is what you must actually DRINK)
//     effortBump  : clamp(round(effort/100 · 700), 0…700); 0 when no Effort is available
//
// `effort` is the day's Effort/strain score on NOOP's native 0…100 scale (the value stored as
// `DailyMetric.strain`). The bump is intentionally modest (≤ 0.7 L) so a hard day nudges the target up
// without ever turning the guide into a hard rule.
public enum HydrationGoal {

    // MARK: - Constants (mirror these EXACTLY in the Android twin — they are Int there)

    // ACCURACY CORRECTION (2026-08-22, peer review — noop_WIP/research/AGENT-SCIENCE-ACCURACY.md §12):
    // 3700 / 2700 / 3200 ml are the IOM (2005) / EFSA **TOTAL WATER** Adequate Intakes — they INCLUDE the
    // ~20% of daily water that arrives in FOOD. NOOP's hydration tracker logs DRINKS (sip/cup/bottle), so
    // using a total-water AI as a "drink this much" target over-stated the goal by ~500–800 ml. The
    // beverage fraction below converts the AI onto the drink-water construct, which also brings the sex
    // fallback into agreement with the 35 ml/kg weight path (previously they could disagree by ~1 L for
    // the same person). Integer percent so Swift and Kotlin round identically.

    /// IOM/EFSA total-water Adequate Intakes (ml/day) — water from ALL sources, food included.
    public static let totalWaterAIMaleML = 3700
    public static let totalWaterAIFemaleML = 2700
    public static let totalWaterAIOtherML = 3200

    /// Share of total water intake that comes from beverages (~80%; the rest comes from food).
    public static let beverageFractionPercent = 80

    /// Baseline DRINK-water target by sex (ml) = total-water AI × beverage fraction, before the Effort
    /// bump. male ≈ 2960, female ≈ 2160, unspecified ≈ 2560.
    public static let baselineMaleML = totalWaterAIMaleML * beverageFractionPercent / 100
    public static let baselineFemaleML = totalWaterAIFemaleML * beverageFractionPercent / 100
    /// Used for "unspecified" / "other" / any unrecognised sex token.
    public static let baselineOtherML = totalWaterAIOtherML * beverageFractionPercent / 100

    /// The most the Effort bump can add (ml) — reached at Effort 100.
    public static let maxEffortBumpML = 700

    /// The goal is rounded to the nearest multiple of this (ml) for a clean read-out.
    public static let roundToML = 50

    // MARK: - Quick-log amounts (ml) — the three tap sizes

    public static let sipML = 30
    public static let cupML = 237     // a US cup (8 fl oz)
    public static let bottleML = 500  // a standard small water bottle

    // MARK: - Pieces (each pure + independently testable; mirror the Kotlin twin)

    /// Baseline ml for a sex token. Case- and whitespace-insensitive; "male"/"m" and "female"/"f" map to
    /// their baselines, anything else ("nonbinary", "other", "", unknown) maps to the unspecified baseline
    /// — we never guess a sex we weren't given.
    public static func baselineForSex(_ sex: String) -> Int {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male", "m":   return baselineMaleML
        case "female", "f": return baselineFemaleML
        default:            return baselineOtherML
        }
    }

    /// The Effort bump (ml) for a day's Effort score on the 0…100 scale: `round(effort/100 · 700)` then
    /// clamped to 0…700. `effort == nil` (no Effort yet today) yields 0 — never a fabricated bump. Rounds
    /// FIRST then clamps the OUTPUT (matching the Kotlin twin), so an out-of-range input can't blow past
    /// the cap. A non-finite effort is treated as "no Effort" (0).
    public static func effortBump(effort: Double?) -> Int {
        guard let effort, effort.isFinite else { return 0 }
        let raw = Int((effort / 100.0 * Double(maxEffortBumpML)).rounded())
        return min(maxEffortBumpML, max(0, raw))
    }

    /// Round `value` to the nearest multiple of `step` (step > 0). Half rounds up — `((value + step/2) /
    /// step) * step` on non-negative ints — matching the Kotlin twin and Swift's away-from-zero rounding.
    public static func roundToNearest(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return ((value + step / 2) / step) * step
    }

    // MARK: - The goal

    /// The day's hydration goal in ml: `roundToNearest(sexBaseline + effortBump, 50)`. Pure — feed it the
    /// profile sex token and the day's Effort score (or nil). The result is always a multiple of 50.
    public static func dailyGoalML(sex: String, effort: Double?) -> Int {
        roundToNearest(baselineForSex(sex) + effortBump(effort: effort), step: roundToML)
    }

    // MARK: - Display helpers

    /// Litres (ml / 1000) for the litre read-outs.
    public static func litres(fromML ml: Double) -> Double { ml / 1000.0 }

    /// "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L" - the dashboard card value, fixed-locale
    /// so the string is byte-identical to the Android twin (`String.format(Locale.US, "%.1f / %.1f L")`).
    public static func cardValueString(totalML: Double, goalML: Int) -> String {
        String(format: "%.1f / %.1f L", litres(fromML: totalML), litres(fromML: Double(goalML)))
    }

    /// Fraction of the goal met (0…1, clamped) for the progress ring.
    public static func fraction(totalML: Double, goalML: Int) -> Double {
        guard goalML > 0 else { return 0 }
        return min(1.0, max(0.0, totalML / Double(goalML)))
    }

    // MARK: - R3: metric-aware inputs (weight + heat) — mirror EXACTLY in the Kotlin twin
    //
    // These EXTEND the goal without changing `dailyGoalML(sex:effort:)` (that overload still returns the
    // sex-baseline result, so existing history/tests are unaffected). The metric-aware overload below uses
    // body weight when known (more personal than a flat sex baseline) and adds a heat bump on hot days.
    // Still a transparent wellness GUIDE — never medical advice, never a hard rule.
    //
    //   GOAL(ml) = roundToNearest( weightBaseline(sex,kg) + effortBump + heatBump, 50 )

    /// ~35 ml per kg body mass per day — the standard adult maintenance estimate.
    public static let mlPerKg = 35
    /// The weight-derived baseline is clamped to a sane adult range (ml) so a bad weight can't produce an
    /// absurd target.
    public static let weightBaselineFloorML = 1500
    public static let weightBaselineCeilML = 5000
    /// Heat bump: extra ml per whole °C of skin-temperature elevation above the personal baseline, capped.
    /// Only POSITIVE deviations add fluid; a cool day never reduces the guide below baseline.
    public static let heatBumpPerDegML = 300
    public static let maxHeatBumpML = 600

    /// Baseline ml: weight-based (`round(35·kg)` clamped to the sane range) when `weightKg` is a finite
    /// positive value, otherwise the sex baseline. `nil`/non-finite/≤0 weight ⇒ sex baseline (back-compat).
    public static func weightBaselineML(sex: String, weightKg: Double?) -> Int {
        guard let kg = weightKg, kg.isFinite, kg > 0 else { return baselineForSex(sex) }
        let raw = Int((Double(mlPerKg) * kg).rounded())
        return min(weightBaselineCeilML, max(weightBaselineFloorML, raw))
    }

    /// Heat bump (ml) from skin-temperature deviation in °C above baseline: `round(devC·300)` clamped to
    /// 0…600. `nil`/non-finite, an absolute imported skin temperature, an implausible deviation, or a
    /// non-positive deviation (at/below baseline) ⇒ 0.
    public static func heatBumpML(skinTempDevC: Double?) -> Int {
        guard let dev = VitalBands.skinTempDeviation(from: skinTempDevC), dev > 0 else { return 0 }
        let raw = Int((dev * Double(heatBumpPerDegML)).rounded())
        return min(maxHeatBumpML, max(0, raw))
    }

    /// The metric-aware daily goal (ml): `roundToNearest(weightBaseline + effortBump + heatBump, 50)`.
    /// Pure. With `weightKg == nil` and `skinTempDevC == nil` this equals `dailyGoalML(sex:effort:)`.
    public static func dailyGoalML(sex: String, weightKg: Double?, effort: Double?,
                                   skinTempDevC: Double?) -> Int {
        let raw = weightBaselineML(sex: sex, weightKg: weightKg)
            + effortBump(effort: effort)
            + heatBumpML(skinTempDevC: skinTempDevC)
        return roundToNearest(raw, step: roundToML)
    }

    // MARK: - R3: smart reminder schedule (pure; platform notification wiring consumes this)

    /// Evenly spaced reminder minutes-of-day within waking hours, so intake is paced across the day rather
    /// than crammed. Pure + deterministic so it is unit-testable and byte-identical to the Kotlin twin; the
    /// platform layer (UNUserNotificationCenter / WorkManager) schedules a local notification at each.
    ///
    /// - `wakeHour`/`sleepHour`: 0…23 local hours; reminders only fire in `[wakeHour, sleepHour)` (quiet
    ///   hours = sleep are never disturbed). `count` reminders are placed at the interior boundaries of
    ///   `count` equal segments (so none lands exactly at wake or sleep). Returns [] for a non-positive
    ///   count or a non-positive waking window.
    public static func reminderMinutesOfDay(wakeHour: Int, sleepHour: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let wake = max(0, min(23, wakeHour))
        let sleep = max(0, min(24, sleepHour))
        let startMin = wake * 60
        let endMin = sleep * 60
        guard endMin > startMin else { return [] }
        let span = endMin - startMin
        var out: [Int] = []
        // Interior boundaries of `count` equal segments: start + span·i/(count+1), i = 1…count.
        for i in 1...count {
            out.append(startMin + (span * i) / (count + 1))
        }
        return out
    }
}
