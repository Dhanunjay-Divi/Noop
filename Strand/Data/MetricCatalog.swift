import Foundation
import StrandAnalytics

/// One day's energy read, resolved without mixing source partitions.
///
/// Apple Health exposes two non-overlapping components (`activeEnergyBurned` and
/// `basalEnergyBurned`). Their sum is a truthful total only when BOTH are present.
/// `DailyMetric.activeKcalEst`, despite its legacy name, is a combined HR-derived
/// estimate over observed seconds; it must never be labelled Active Energy or added
/// to either Apple component. Keeping this rule in one pure value type prevents the
/// Today cards and metric dossier from drifting into different calorie arithmetic.
struct DailyEnergyBreakdown: Equatable {
    enum Coverage: Equatable {
        case completeApple
        case activeOnly
        case restingOnly
        case combinedEstimateOnly
        case unavailable
    }

    let activeKcal: Double?
    let restingKcal: Double?
    let totalKcal: Double?
    let coverage: Coverage

    /// The number that receives the large type in a compact KPI card. A partial
    /// Apple read leads with the component that actually exists; it never invents
    /// a total. Strap-only data leads with the combined estimate as one indivisible
    /// number because its active/resting split is not mathematically available.
    var headlineKcal: Double? {
        totalKcal ?? activeKcal ?? restingKcal
    }

    var isPartial: Bool {
        coverage == .activeOnly || coverage == .restingOnly
    }

    /// Resolve Apple Health first when it supplied either component. The wearable
    /// total is used only when Apple supplied neither, which is the no-double-counting
    /// boundary: values from different producers are never assembled into one total.
    static func resolve(appleActiveKcal: Double?, appleRestingKcal: Double?,
                        wearableCombinedKcal: Double?) -> DailyEnergyBreakdown {
        let active = valid(appleActiveKcal, allowsZero: true)
        let resting = valid(appleRestingKcal, allowsZero: false)
        let combined = valid(wearableCombinedKcal, allowsZero: false)

        switch (active, resting) {
        case let (.some(a), .some(r)):
            return DailyEnergyBreakdown(activeKcal: a, restingKcal: r,
                                        totalKcal: a + r, coverage: .completeApple)
        case let (.some(a), .none):
            return DailyEnergyBreakdown(activeKcal: a, restingKcal: nil,
                                        totalKcal: nil, coverage: .activeOnly)
        case let (.none, .some(r)):
            return DailyEnergyBreakdown(activeKcal: nil, restingKcal: r,
                                        totalKcal: nil, coverage: .restingOnly)
        case (.none, .none):
            guard let combined else {
                return DailyEnergyBreakdown(activeKcal: nil, restingKcal: nil,
                                            totalKcal: nil, coverage: .unavailable)
            }
            return DailyEnergyBreakdown(activeKcal: nil, restingKcal: nil,
                                        totalKcal: combined, coverage: .combinedEstimateOnly)
        }
    }

    /// Sum only paired, finite Apple components. Kept as a pure seam for the
    /// Repository's derived Total Energy trend and its no-double-counting tests.
    static func appleTotalSeries(active: [(day: String, value: Double)],
                                 resting: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        let activeByDay = Dictionary(active.filter { valid($0.value, allowsZero: true) != nil }
            .map { ($0.day, $0.value) }, uniquingKeysWith: { _, newer in newer })
        let restingByDay = Dictionary(resting.filter { valid($0.value, allowsZero: false) != nil }
            .map { ($0.day, $0.value) }, uniquingKeysWith: { _, newer in newer })
        return Set(activeByDay.keys).intersection(restingByDay.keys).sorted().compactMap { day in
            guard let a = activeByDay[day], let r = restingByDay[day] else { return nil }
            return (day, a + r)
        }
    }

    private static func valid(_ value: Double?, allowsZero: Bool) -> Double? {
        guard let value, value.isFinite else { return nil }
        let isValid = allowsZero ? value >= 0 : value > 0
        guard isValid else { return nil }
        return value
    }
}

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop", an import partition, or another explicit producer
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    /// A short, plain-English one-liner for the metric (tile subtitle / catalog blurb). Optional —
    /// only the three headline scores (Charge / Effort / Rest) carry one today; everything else is nil.
    var description: String? = nil
    var id: String { source + ":" + key }

    /// Human label for the metric's source partition (catalog row caption / detail subtitle).
    var sourceLabel: String {
        switch source {
        case "apple-health": return "Apple Health"
        case "xiaomi-band":  return "Mi Band"
        case "nutrition-log", "nutrition-csv": return String(localized: "Nutrition")
        case "noop-mood":    return String(localized: "Mood")
        // `my-whoop` is the local strap namespace. Its series can resolve to directly measured
        // strap rows OR to a sibling `-noop` series calculated on-device; calling the whole namespace
        // "Whoop" made independent Charge/Effort/Rest values look official. Keep that boundary visible.
        case "my-whoop":     return String(localized: "Noop Band")
        case let s where s.hasSuffix("-noop"):
            return "NOOP"
        case "whoop", "whoop-official-reference":
            return String(localized: "Imported")
        default:
            return source
        }
    }

    /// True for the Effort metric (#268). Its stored value is 0–100; the effort-scale toggle converts
    /// the DISPLAYED number + unit onto WHOOP's 0–21 axis. Mirrors the Android `MetricSpec.whoopEffort`
    /// gate (`key == "strain"`) - the only value-converting metric in the catalog.
    private var isEffort: Bool { key == "strain" }
    /// Fitness Age is stored as continuous years but presented as `year.month`, where the suffix is a
    /// calendar-month count (`23.11` = 23 years, 11 months), on every catalog-driven surface.
    private var isFitnessAge: Bool { key == "fitness_age" }
    /// The database convention for sleep efficiency is a 0–1 fraction, while the catalog presents it
    /// as a percentage. Keep conversion at the descriptor boundary so charts, tables and stat tiles all
    /// say 90% for a stored 0.90 (rather than the misleading 1% produced by plain rounding).
    private var isFractionPercent: Bool { key == "sleep_efficiency" }

    /// #111: the skin_temp metric's stored value is EITHER an absolute skin temperature (WHOOP export gives
    /// absolute °C) OR a signed DEVIATION from the personal baseline (±°C, the live/computed pipeline) —
    /// `VitalBands.isAbsoluteSkinTemp(v)` (v >= 20 °C) tells them apart per value. A DEVIATION must convert
    /// to °F by ×9/5 with NO +32 offset; adding +32 to a deviation produced nonsense ONLY in Fahrenheit
    /// (a −4.2 °C deviation rendered as "24.4 °F" - the bug), while Celsius appended the raw deviation and
    /// looked fine. An ABSOLUTE reading still uses the full C→F (×9/5 + 32). Key-based, mirroring `isEffort`
    /// and the Android HealthScreen per-value branch.
    private var isSkinTemp: Bool { key == "skin_temp" }

    func format(_ v: Double) -> String {
        if isFitnessAge { return FitnessAgePresentation.value(v) }
        let displayValue = isFractionPercent ? v * 100 : v
        let n = decimals == 0
            ? String(Int(displayValue.rounded()))
            : String(format: "%.\(decimals)f", displayValue)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Effort-aware plain format (#268): the Effort metric's stored 0–100 value is shown on the selected
    /// scale (its number + "/100"→"/21" unit); every other metric is scale-agnostic and falls through to
    /// the unit-less `format` above. Callers that don't carry an effort scale get `.hundred` (no change).
    func format(_ v: Double, effortScale: EffortScale) -> String {
        guard isEffort else { return format(v) }
        let n = UnitFormatter.effortDisplay(v, scale: effortScale)
        return "\(n) \(displayUnit(effortScale: effortScale))"
    }

    /// Unit-aware format: for the three SI-stored metrics that have a non-metric counterpart
    /// (weight/lean_mass in kg, skin_temp in °C) convert + relabel via `UnitFormatter`. The Effort
    /// metric follows its own 0–100↔0–21 scale (#268). Every other metric (%, bpm, ms, min, …) is
    /// scale-agnostic and falls through to the plain `format` above, so each toggle only ever touches
    /// the values that actually have a converted form.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                effortScale: EffortScale = .hundred, mass: MassUnit? = nil) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(
            v, unit: mass ?? (system == .imperial ? .pounds : .kilograms)
        )
        case "cm":  return UnitFormatter.heightFromCentimeters(v, system: system)
        case "°C":
            // #111: a skin-temp DEVIATION (v < 20 °C) scales without the +32 offset; an absolute reading
            // (WHOOP export, v >= 20 °C) keeps the full C→F. Every other °C metric is absolute.
            if isSkinTemp && !VitalBands.isAbsoluteSkinTemp(v) {
                return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
            }
            return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return isEffort ? format(v, effortScale: effortScale) : format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values (e.g. the Δ StatTile). A temperature
    /// delta scales by 9/5 with NO +32 offset; mass/distance deltas scale by their plain factor; an
    /// Effort delta rescales 0–100→0–21 on the WHOOP scale (#268, no offset — it's a magnitude). The
    /// caller supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred, mass: MassUnit? = nil) -> String {
        if isFitnessAge {
            return FitnessAgePresentation.duration(
                totalMonths: Int((v * 12).rounded())
            )
        }
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(
            v, unit: mass ?? (system == .imperial ? .pounds : .kilograms)
        )
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:
            if isFractionPercent {
                let pct = v * 100
                let n = decimals == 0 ? String(Int(pct.rounded())) : String(format: "%.\(decimals)f", pct)
                return "\(n) \(unit)"
            }
            guard isEffort else { return format(v) }
            // A delta on the 0–100 axis rescales by the same ×21/100 factor (the offset-free `effortValue`).
            let n = UnitFormatter.effortDisplay(v, scale: effortScale)
            return "\(n) \(displayUnit(effortScale: effortScale))"
        }
    }

    /// The unit LABEL as displayed (e.g. the trailing chip in the Metric Explorer list), mapped to the
    /// active system. Only the convertible units change; everything else returns its stored label.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred, mass: MassUnit? = nil) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(
            mass ?? (system == .imperial ? .pounds : .kilograms)
        )
        case "cm":  return system == .imperial ? "ft / in" : "cm"
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return isEffort ? displayUnit(effortScale: effortScale) : unit
        }
    }

    /// The Effort metric's unit LABEL on the selected scale - "/100" or "/21" (#268). Non-Effort metrics
    /// return their stored label unchanged. Mirrors the Android `MetricSpec.displayUnit` swap.
    func displayUnit(effortScale: EffortScale) -> String {
        guard isEffort else { return unit }
        return "/" + UnitFormatter.effortScaleMax(effortScale)
    }
}

struct DayTrackedMetric: Identifiable, Equatable {
    let descriptor: MetricDescriptor
    let value: Double
    var id: String { descriptor.id }
}

/// Canonical catalog - mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", String(localized: "VO₂ Max"), "Heart", "", "apple-health", "lungs.fill", 1, true),
        d("fitness_age", String(localized: "Fitness Age"), "Heart", "", "my-whoop", "figure.run", 0, false),
        d("vo2max_est", String(localized: "VO₂ Max (estimated)"), "Heart", "", "my-whoop", "lungs", 1, true),
        d("vitality", String(localized: "Vitality"), "Heart", "", "my-whoop", "sparkles", 0, true),
        d("body_age", String(localized: "Wellness Age"), "Heart", "yrs", "my-whoop", "figure.stand", 0, false),

        // ── Charge (was Recovery)
        d("recovery", String(localized: "Recovery"), "Charge", "%", "my-whoop", "heart.circle", 0, true,
          String(localized: "How recovered you are, led by HRV versus your personal baseline.")),
        d("hrv", String(localized: "Heart Rate Variability"), "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", String(localized: "Respiratory Rate"), "Charge", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", String(localized: "Skin Temperature"), "Charge", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Rest (was Sleep)
        d("sleep_performance", String(localized: "Sleep Score"), "Rest", "%", "my-whoop", "moon.stars", 0, true,
          String(localized: "How restorative your sleep was: duration, efficiency, deep+REM, timing.")),
        d("in_bed_min", String(localized: "Time in Bed"), "Rest", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", String(localized: "Hours vs Needed"), "Rest", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", String(localized: "Sleep Consistency"), "Rest", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", String(localized: "Restorative Sleep"), "Rest", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", String(localized: "Restorative Sleep"), "Rest", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", String(localized: "Sleep Efficiency"), "Rest", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", String(localized: "Sleep Need"), "Rest", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", String(localized: "Sleep Debt"), "Rest", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", String(localized: "Effort"), "Effort", "/100", "my-whoop", "flame", 1, nil,
          String(localized: "Cardiovascular load for the day, on a 0-100 scale (was 0-21).")),
        d("steps", String(localized: "Steps"), "Effort", "", "apple-health", "figure.walk", 0, true),
        // WHOOP 5.0 / MG exposes a motion-derived daily estimate from @57. Declared AFTER apple-health:
        // the bare-key `first { key == "steps" }` resolvers (LabBookView, CompareView, the TabRoute
        // `.metric` fallback) keep their prior apple-health default, so this entry's position never
        // changes where any of them tap through. The Today card/tile route to it EXPLICITLY by source
        // (`.metricSourced` / `todayStepsMetric`), which is what actually needs it.
        d("steps", String(localized: "Steps (motion estimate)"), "Effort", "steps", "my-whoop", "figure.walk.motion", 0, true,
          String(localized: "Estimated on device from Noop Band motion-counter ticks and your step-scale setting. Not a validated pedometer count.")),
        // On-device calibrated steps ESTIMATE for a WHOOP 4.0 (no readable step count over BLE): the strap's daily
        // motion volume scaled by a personal calibration. Stored under the computed "-noop" source, so
        // it reads through the same exploreSeries fallback fitness_age/vitality use. Distinct from the
        // @57 motion estimate above — both are labelled so neither is mistaken for a measured count.
        d("steps_est", String(localized: "Steps (estimated)"), "Effort", "steps", "my-whoop", "figure.walk.motion", 0, true,
          String(localized: "Estimated from Noop Band motion, calibrated to your phone. Not a measured step count.")),
        d("hr_zones13_min", String(localized: "HR Zones 1-3"), "Effort", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", String(localized: "HR Zones 4-5"), "Effort", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", String(localized: "HR Zones (All)"), "Effort", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", String(localized: "Strength Activity Time"), "Effort", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", String(localized: "Active Energy"), "Effort", "kcal", "apple-health", "flame.fill", 0, nil),
        d("basal_kcal", String(localized: "Resting Energy"), "Effort", "kcal", "apple-health", "bed.double.fill", 0, nil),
        d("total_kcal", String(localized: "Total Energy"), "Effort", "kcal", "apple-health", "flame.circle.fill", 0, nil,
          String(localized: "Active plus resting energy, shown only when Apple Health supplied both components.")),

        // ── Health / Body
        d("weight", String(localized: "Weight"), "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", String(localized: "Body Fat"), "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", String(localized: "Lean Body Mass"), "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("body_temp", String(localized: "Body Temperature"), "Health", "°C", "apple-health", "thermometer.medium", 1, nil,
          String(localized: "An absolute body-temperature reading imported from Apple Health; not wrist skin-temperature deviation.")),
        d("wrist_temp", String(localized: "Sleeping Wrist Temperature"), "Health", "°C", "apple-health", "applewatch", 1, nil,
          String(localized: "An absolute sleeping wrist-temperature reading from Apple Health, kept separate from body temperature and WHOOP skin-temperature deviation.")),
        d("stress", String(localized: "Day Stress"), "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (editable manual meals + migrated CSV daily summaries).
        d("calories_in", String(localized: "Calories In"), "Nutrition", "kcal", "nutrition-log", "fork.knife", 0, nil),
        d("protein_g", String(localized: "Protein"), "Nutrition", "g", "nutrition-log", "p.circle", 0, nil),
        d("carbs_g", String(localized: "Carbs"), "Nutrition", "g", "nutrition-log", "c.circle", 0, nil),
        d("fat_g", String(localized: "Fat"), "Nutrition", "g", "nutrition-log", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", String(localized: "Mood"), "Mind", "/5", "noop-mood", "face.smiling", 0, true),

        // ── Mi Band (imported from Mi Fitness). Same metricSeries mechanism as Apple Health /
        //    Nutrition, so these light up Explore, Compare and the correlation scan. Distinct
        //    `source` keeps them comparable against the WHOOP/Apple versions rather than colliding.
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "xiaomi-band", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "xiaomi-band", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "xiaomi-band", "flame", 0, nil),
        d("vitality", String(localized: "Vitality"), "Heart", "", "xiaomi-band", "sparkles", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "xiaomi-band", "heart", 0, false),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "xiaomi-band", "drop", 0, true),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "xiaomi-band", "moon.zzz", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "xiaomi-band", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "xiaomi-band", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "xiaomi-band", "moon", 0, nil),
        d("sleep_score", String(localized: "Sleep Score"), "Rest", "", "xiaomi-band", "moon.stars", 0, true),
        d("steps", String(localized: "Steps"), "Effort", "", "xiaomi-band", "figure.walk", 0, true),
        d("intensity_min", String(localized: "Intensity Minutes"), "Effort", "min", "xiaomi-band", "figure.run", 0, true),
        d("stress", String(localized: "Stress"), "Health", "/100", "xiaomi-band", "gauge.with.dots.needle.50percent", 0, false),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    static func metric(key: String, source: String) -> MetricDescriptor? {
        all.first { $0.key == key && $0.source == source }
    }

    /// The source the Today steps tile taps through to, matching the value it displays. A measured
    /// pedometer count imported from Apple Health always outranks WHOOP 5/MG's @57 motion-derived
    /// estimate; the calibrated WHOOP 4 fallback is last. This ordering is shared with Android.
    static func todayStepsMetric(hasMotionDerivedSteps: Bool, hasImportedSteps: Bool = false) -> MetricDescriptor? {
        if hasImportedSteps { return metric(key: "steps", source: "apple-health") }
        if hasMotionDerivedSteps { return metric(key: "steps", source: "my-whoop") }
        return metric(key: "steps_est", source: "my-whoop")
    }

    /// One-value form of the measured-first steps contract. Keeping the arbitration here prevents a
    /// card, dashboard row and route from independently drifting back to motion-first precedence.
    static func todayStepsValue<T>(imported: T?, motionDerived: T?, calibratedEstimate: T?) -> T? {
        imported ?? motionDerived ?? calibratedEstimate
    }

    /// Per-day form used by Today sparklines. Sources are merged by day rather than choosing one whole
    /// series, so a measured import wins every overlapping day while motion estimates still fill gaps.
    static func todayStepsSeries(
        imported: [(day: String, value: Double)],
        motionDerived: [(day: String, value: Double)],
        calibratedEstimate: [(day: String, value: Double)]
    ) -> [(day: String, value: Double)] {
        func byDay(_ points: [(day: String, value: Double)]) -> [String: Double] {
            Dictionary(points.filter { $0.value.isFinite && $0.value >= 0 }
                .map { ($0.day, $0.value) }, uniquingKeysWith: { _, newer in newer })
        }
        let importedByDay = byDay(imported)
        let motionByDay = byDay(motionDerived)
        let estimateByDay = byDay(calibratedEstimate)
        return Set(importedByDay.keys).union(motionByDay.keys).union(estimateByDay.keys)
            .sorted()
            .compactMap { day in
                todayStepsValue(imported: importedByDay[day], motionDerived: motionByDay[day],
                                calibratedEstimate: estimateByDay[day]).map { (day, $0) }
            }
    }

    /// #616: the calorie twin of `todayStepsMetric` — route the tapped detail to the source that MATCHES
    /// the value the tile shows (imported-first, like Android). The imported Apple-Health detail
    /// (`active_kcal` / apple-health) when the day has an imported value, else NOOP's on-device HR-estimate
    /// detail (`energy_kcal` / my-whoop, which `exploreSeries` fuses from `activeKcalEst`). Without this the
    /// Calories card always opened the imported-only detail, so an on-device (WHOOP 5.0) user with no import
    /// saw an empty/disagreeing chart. Defaults to the on-device detail when no import is present.
    static func todayCaloriesMetric(hasImportedKcal: Bool, hasOnDeviceKcal: Bool = false) -> MetricDescriptor? {
        if hasImportedKcal { return metric(key: "active_kcal", source: "apple-health") }
        if hasOnDeviceKcal { return metric(key: "energy_kcal", source: "my-whoop") }
        return metric(key: "energy_kcal", source: "my-whoop")
    }

    /// Route an energy KPI to the series represented by its large number. A complete Apple split opens
    /// Total Energy; a partial split opens its one real component; a strap-only combined estimate opens
    /// the existing NOOP/strap energy series. This keeps card, chart title, units and arithmetic aligned.
    static func todayEnergyMetric(for breakdown: DailyEnergyBreakdown) -> MetricDescriptor? {
        switch breakdown.coverage {
        case .completeApple:
            return metric(key: "total_kcal", source: "apple-health")
        case .activeOnly:
            return metric(key: "active_kcal", source: "apple-health")
        case .restingOnly:
            return metric(key: "basal_kcal", source: "apple-health")
        case .combinedEstimateOnly, .unavailable:
            return metric(key: "energy_kcal", source: "my-whoop")
        }
    }

    /// Localized display name for a catalog category, mapped AT THE RENDER SITE only. The
    /// catalog's `category` VALUES stay English identifiers on purpose (`inCategory` and the
    /// colour-world / gradient switches compare them raw), so screens must never feed this
    /// function's output back into matching logic. Unknown values pass through untranslated.
    static func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "Heart":     return String(localized: "Heart")
        // "Charge" and "Rest" remain stable internal grouping keys. The UI uses
        // familiar health language so a battery term is never mistaken for a
        // physiological metric and a sleep score is not confused with an action.
        case "Charge":    return String(localized: "Recovery")
        case "Rest":      return String(localized: "Sleep")
        case "Effort":    return String(localized: "Effort")
        case "Health":    return String(localized: "Health")
        case "Nutrition": return String(localized: "Nutrition")
        case "Mind":      return String(localized: "Mind")
        default:          return category
        }
    }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?, _ description: String? = nil) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter,
                         description: description)
    }
}
