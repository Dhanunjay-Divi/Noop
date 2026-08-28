import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One resolved vital-sign tile: the latest value across the source precedence, banded against the
/// user's own trailing baseline (population fallback until 14 trusted nights), plus the day + source
/// that supplied it so the caption can name them honestly. The view layer reads only this — all of the
/// source resolution + banding lives in `BodyVitalSigns` so it stays pure and testable.
struct BodyVitalReading: Identifiable {
    let key: String
    let label: String
    let unit: String
    let value: Double?
    let format: (Double) -> String
    let banding: VitalBands.Result
    let metricColor: Color
    let day: String?
    let source: DailyMetricSource?
    let missingCaption: String
    /// Trailing values for this vital (oldest → newest), so the tile can draw a metric-tinted
    /// sparkline with a glowing "now" end-cap like Today's Key-Metrics tiles. Presentation-only:
    /// the resolved value, banding and source are unchanged — this is just the trend for the trail.
    /// Defaulted so existing call sites (previews/tests) keep compiling unchanged.
    var sparkline: [Double]? = nil

    var id: String { key }

    /// Semantic glyph paired with the visible vital name on every tile.
    var systemImage: String {
        switch key {
        case "resp":    return "lungs.fill"
        case "spo2":    return "drop.fill"
        case "spo2raw": return "waveform.path.ecg"
        case "rhr":     return "heart.text.square.fill"
        case "hrv":     return "waveform.path.ecg"
        case "skin":    return "thermometer.medium"
        case "sleep":   return "bed.double.fill"
        default:        return "waveform.path"
        }
    }

    var formattedValue: String? {
        value.map(displayValue)
    }

    func displayValue(_ value: Double) -> String {
        unit.isEmpty ? format(value) : "\(format(value)) \(unit)"
    }

    /// Colour communicates state: in-range = the metric's category colour,
    /// out-of-range = critical red, no data = tertiary.
    var accent: Color {
        switch banding.band {
        case .noData:     return StrandPalette.textTertiary
        case .inRange:    return metricColor
        case .outOfRange: return StrandPalette.statusCritical
        }
    }

    /// The tile caption: "<day> · <source> · <state>". Falls back to a metric-specific "no value"
    /// line when nothing resolved, so an empty tile still says why instead of a bare dash.
    var stateCaption: String {
        guard let day else { return missingCaption }
        var parts = [Self.dayLabel(day)]
        if let sourceText = Self.sourceLabel(source, key: key) {
            parts.append(sourceText)
        }
        parts.append(stateText)
        return parts.joined(separator: " · ")
    }

    var accessibilityText: String {
        guard let v = formattedValue else { return String(localized: "\(label): no data") }
        return String(localized: "\(label): \(v), \(stateCaption)")
    }

    /// Which yardstick judged the value: your own baseline vs the typical adult range. String(localized:)
    /// — StatTile's caption is a plain String rendered via Text(String), which never consults the catalog.
    private var stateText: String {
        // Raw SpO₂ is a device-dependent ADC, not a clinical value — never claim an in/out-of-range
        // judgment. Show a plain "uncalibrated" note when a value decoded, "No data" otherwise. (#93)
        if key == "spo2raw" {
            return banding.band == .noData ? String(localized: "No data")
                                           : String(localized: "Uncalibrated")
        }
        switch (banding.band, banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In your range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical range")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }

    /// Short provenance word for the caption. The local-cache fallback stays unnamed (previews/tests),
    /// and computed skin temp reads "Overnight computed" since that figure is a nightly derivation.
    private static func sourceLabel(_ source: DailyMetricSource?, key: String) -> String? {
        guard let source else { return nil }
        switch source {
        case .whoopImport:
            return String(localized: "Imported")
        case .noopComputed:
            if key == "skin" { return String(localized: "Overnight computed") }
            return String(localized: "NOOP computed")
        case .appleHealth:
            return String(localized: "Apple Health")
        case .localCache:
            return nil
        }
    }

    static func dayLabel(_ day: String) -> String {
        if day == BodyVitalSigns.logicalDayKey(Date()) { return String(localized: "Today") }
        guard let date = BodyVitalSigns.dayParser.date(from: day) else { return day }
        return BodyVitalSigns.dayFormatter.string(from: date)
    }
}

/// Honest aggregate for the Health Monitor's latest-reading grid. It deliberately counts only
/// finite, available, calibrated readings. Raw optical ADC and missing values never affect the
/// numerator or denominator.
struct VitalRangeSummary: Equatable, Sendable {
    let inRangeCount: Int
    let availableCount: Int

    var allAvailableInRange: Bool {
        availableCount > 0 && inRangeCount == availableCount
    }

    var message: String {
        guard availableCount > 0 else {
            return String(localized: "No current range comparisons available")
        }
        if availableCount == 1 {
            return inRangeCount == 1
                ? String(localized: "The available reading is within its current range")
                : String(localized: "The available reading is outside its current range")
        }
        return String(localized:
            "\(inRangeCount) of \(availableCount) available readings are within their current ranges")
    }
}

/// Builds the body vital-sign readings from source-tagged daily rows. Pure + namespaced so the
/// resolution (per-metric source precedence) and banding can be unit-tested without a Repository.
enum BodyVitalSigns {
    /// Preview/test convenience: wrap plain rows (optionally a separate "today") as local-cache rows.
    static func readings(days: [DailyMetric],
                         today: DailyMetric?,
                         temperatureUnit: TemperatureUnit) -> [BodyVitalReading] {
        var sourceRows = days.map { SourcedDailyMetric(metric: $0, source: .localCache) }
        if let today, !days.contains(where: { $0.day == today.day }) {
            sourceRows.append(SourcedDailyMetric(metric: today, source: .localCache))
        }
        return readings(sourceRows: sourceRows, temperatureUnit: temperatureUnit)
    }

    static func readings(sourceRows: [SourcedDailyMetric],
                         temperatureUnit: TemperatureUnit,
                         now: Date = Date(),
                         sleepOverrideDays: Set<String> = []) -> [BodyVitalReading] {
        let logicalDay = logicalDayKey(now)

        // Resolve one metric to a per-day series using explicit source precedence. Sleep is the one
        // deliberate exception: a user-edited day uses the recomputed daily sleep aggregate ahead of
        // the imported value so the Health card matches the corrected session and the rest of NOOP.
        func points(key: String, _ value: (DailyMetric) -> Double?) -> [VitalPoint] {
            var byDay: [String: VitalPoint] = [:]
            for row in sourceRows {
                guard let v = value(row.metric) else { continue }
                let precedence = key == "sleep" && sleepOverrideDays.contains(row.metric.day)
                    ? DailyMetricSource.editedSleepPrecedence
                    : DailyMetricSource.vitalPrecedence(for: key)
                guard let candidateRank = precedence.firstIndex(of: row.source) else { continue }
                if let existing = byDay[row.metric.day],
                   let existingRank = precedence.firstIndex(of: existing.source),
                   existingRank <= candidateRank {
                    continue
                }
                byDay[row.metric.day] = VitalPoint(
                    day: row.metric.day,
                    value: v,
                    source: row.source
                )
            }
            return byDay.values.sorted { $0.day < $1.day }
        }

        // Prefer the logical day's value; otherwise the most recent day that has one — so a vital still
        // shows after a day with no wear instead of blanking to "-".
        func latest(_ pts: [VitalPoint]) -> VitalPoint? {
            pts.last(where: { $0.day == logicalDay }) ?? pts.last
        }

        func history(before day: String?, _ pts: [VitalPoint]) -> [Double?] {
            VitalBands.calendarSeries(pts.filter { point in
                guard let day else { return true }
                return point.day < day
            }.map { ($0.day, Optional($0.value)) })
        }

        let respPoints = points(key: "resp", \.respRateBpm)
        let spo2Points = points(key: "spo2", \.spo2Pct)
        // WHOOP 4.0 raw SpO₂: the (red + IR) / 2 ADC mean per night, present only when both channels
        // decoded for the day. On-device only, so this resolves to the NOOP-computed row. (#93)
        let spo2rawPoints = points(key: "spo2raw") { m in
            guard let r = m.spo2Red, let i = m.spo2Ir else { return nil }
            return (Double(r) + Double(i)) / 2.0
        }
        let rhrPoints = points(key: "rhr") { $0.restingHr.map(Double.init) }
        let hrvPoints = points(key: "hrv", \.avgHrv)
        let skinPoints = points(key: "skin", \.skinTempDevC)
        let sleepPoints = points(key: "sleep") { metric in
            metric.totalSleepMin.map { $0 / 60.0 }
        }

        let respRow = latest(respPoints)
        let spo2Row = latest(spo2Points)
        let spo2rawRow = latest(spo2rawPoints)
        let rhrRow = latest(rhrPoints)
        let hrvRow = latest(hrvPoints)
        let skinRow = latest(skinPoints)
        let sleepRow = latest(sleepPoints)

        // Trailing values (oldest → newest) feeding each tile's sparkline trail. A 2+ point series
        // draws; the tile hides the trail otherwise. Presentation-only — built from the same resolved
        // points already used for the value, just kept as a series rather than collapsed to `latest`.
        func trail(_ pts: [VitalPoint], window: Int = 14) -> [Double] {
            pts.suffix(window).map(\.value)
        }

        // Skin temp is bimodal: CSV imports store ABSOLUTE °C, the on-device pipeline a ±°C DEVIATION —
        // partition the history to the displayed value's kind and pick the matching config + population
        // fallback (±0.6 °C mirrors the illness watch's flag threshold).
        let skin = skinRow?.value
        let skinIsAbsolute = skin.map(VitalBands.isAbsoluteSkinTemp) ?? true
        let skinResult: VitalBands.Result
        if let skin {
            skinResult = VitalBands.band(
                value: skin,
                history: VitalBands.skinTempHistory(matching: skin, in: history(before: skinRow?.day, skinPoints)),
                populationRange: skinIsAbsolute ? 33...36 : (-0.6)...0.6,
                cfg: skinIsAbsolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg
            )
        } else {
            skinResult = VitalBands.Result(band: .noData, basis: .population, nights: 0)
        }

        // Resolve the skin-temp label + converter once, honouring the °C/°F preference. An ABSOLUTE
        // reading uses the full C→F formula (×9/5 + 32); a ±DEVIATION must omit the offset.
        let skinUnitLabel = UnitFormatter.temperatureUnit(temperatureUnit)
        let skinFormat: (Double) -> String = { c in
            let full = skinIsAbsolute
                ? UnitFormatter.temperatureFromCelsius(c, unit: temperatureUnit, decimals: 1)
                : UnitFormatter.temperatureDeltaFromCelsius(c, unit: temperatureUnit, decimals: 1)
            return full.replacingOccurrences(of: " " + skinUnitLabel, with: "")
        }

        return [
            BodyVitalReading(
                key: "resp",
                label: String(localized: "Resp Rate"),
                unit: "rpm",
                value: respRow?.value,
                format: { String(format: "%.1f", $0) },
                banding: VitalBands.band(
                    value: respRow?.value,
                    history: history(before: respRow?.day, respPoints),
                    populationRange: 12...20,
                    cfg: Baselines.respCfg
                ),
                metricColor: StrandPalette.metricCyan,
                day: respRow?.day,
                source: respRow?.source,
                missingCaption: String(localized: "No respiratory-rate value"),
                sparkline: trail(respPoints)
            ),
            BodyVitalReading(
                key: "spo2",
                label: String(localized: "Blood O₂"),
                unit: "%",
                value: spo2Row?.value,
                format: { String(format: "%.0f", $0) },
                // Population-only on purpose: an absolute <95% floor is meaningful regardless of
                // personal baseline (no "spo2" MetricCfg exists).
                banding: VitalBands.band(
                    value: spo2Row?.value,
                    history: [],
                    populationRange: 95...100,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2Row?.day,
                source: spo2Row?.source,
                missingCaption: String(localized: "No SpO₂ import or Health value"),
                sparkline: trail(spo2Points)
            ),
            BodyVitalReading(
                key: "spo2raw",
                label: String(localized: "Raw SpO₂"),
                unit: "ADC",
                value: spo2rawRow?.value,
                format: { String(format: "%.0f", $0) },
                // Unbanded on purpose: this is the WHOOP 4.0 raw PPG ADC mean, device/placement-dependent
                // with no clinical range — NOT a calibrated blood-oxygen %. Banding over the full u16 span
                // just keeps the tile cyan (never "off range") while `stateText` labels it uncalibrated, so
                // we never fabricate an in-range / out-of-range clinical judgment on raw sensor data. (#93)
                banding: VitalBands.band(
                    value: spo2rawRow?.value,
                    history: [],
                    populationRange: 0...65535,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2rawRow?.day,
                source: spo2rawRow?.source,
                missingCaption: String(localized: "No raw SpO₂ decode for the night"),
                sparkline: trail(spo2rawPoints)
            ),
            BodyVitalReading(
                key: "rhr",
                label: String(localized: "Resting HR"),
                unit: "bpm",
                value: rhrRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: rhrRow?.value,
                    history: history(before: rhrRow?.day, rhrPoints),
                    populationRange: 40...60,
                    cfg: Baselines.restingHRCfg
                ),
                metricColor: StrandPalette.metricRose,
                day: rhrRow?.day,
                source: rhrRow?.source,
                missingCaption: String(localized: "No resting HR value"),
                sparkline: trail(rhrPoints)
            ),
            BodyVitalReading(
                key: "hrv",
                label: String(localized: "HRV"),
                unit: "ms",
                value: hrvRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: hrvRow?.value,
                    history: history(before: hrvRow?.day, hrvPoints),
                    populationRange: 40...120,
                    cfg: Baselines.hrvCfg
                ),
                metricColor: StrandPalette.metricPurple,
                day: hrvRow?.day,
                source: hrvRow?.source,
                missingCaption: String(localized: "No HRV value"),
                sparkline: trail(hrvPoints)
            ),
            BodyVitalReading(
                key: "skin",
                label: String(localized: "Skin Temp"),
                unit: skinUnitLabel,
                value: skin,
                format: skinFormat,
                banding: skinResult,
                metricColor: StrandPalette.metricAmber,
                day: skinRow?.day,
                source: skinRow?.source,
                missingCaption: String(localized: "No nightly skin-temp value"),
                // Keep the trail on the displayed value's kind — absolute °C and ±deviation must not
                // mix on one sparkline (matches the banding partition above).
                sparkline: trail(skinPoints.filter { VitalBands.isAbsoluteSkinTemp($0.value) == skinIsAbsolute })
            ),
            BodyVitalReading(
                key: "sleep",
                label: String(localized: "Sleep"),
                unit: "",
                value: sleepRow?.value,
                format: Self.sleepDuration,
                // Sleep duration remains population-banded. A personal baseline can faithfully say
                // "usual", but it cannot make chronically short sleep "healthy".
                banding: VitalBands.band(
                    value: sleepRow?.value,
                    history: [],
                    populationRange: 7...9,
                    cfg: nil
                ),
                metricColor: StrandPalette.restColor,
                day: sleepRow?.day,
                source: sleepRow?.source,
                missingCaption: String(localized: "No primary sleep duration"),
                sparkline: trail(sleepPoints)
            ),
        ]
    }

    private static func sleepDuration(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// The newest day any resolved reading was sourced from - drives the section's "Latest" trailing label.
    static func latestDayLabel(_ readings: [BodyVitalReading]) -> String? {
        readings.compactMap(\.day).max().map(BodyVitalReading.dayLabel)
    }

    /// Aggregate only calibrated, finite readings. A raw SpO₂ ADC can be useful in diagnostics but
    /// has no health range, and a missing tile is absence rather than an out-of-range observation.
    static func rangeSummary(_ readings: [BodyVitalReading]) -> VitalRangeSummary {
        let available = readings.filter { reading in
            reading.key != "spo2raw"
                && reading.value?.isFinite == true
                && reading.banding.band != .noData
        }
        return VitalRangeSummary(
            inRangeCount: available.filter { $0.banding.band == .inRange }.count,
            availableCount: available.count
        )
    }

    /// The LOGICAL local day for `now` (rolls at 04:00 local). Self-contained so this helper stays pure
    /// and independent of the @MainActor Repository — same boundary, mirrored here for the readings build.
    static func logicalDayKey(_ now: Date, rolloverHour: Int = 4) -> String {
        localDayFormatter.string(from: now.addingTimeInterval(-Double(rolloverHour) * 3_600))
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // `day` is a calendar-only key parsed at UTC midnight. Format it in UTC as well so users west
        // of Greenwich do not see a measurement recorded on the 22nd labelled as the 21st.
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM"
        return f
    }()
}

private struct VitalPoint: Equatable {
    let day: String
    let value: Double
    let source: DailyMetricSource
}

private extension DailyMetricSource {
    static let editedSleepPrecedence: [DailyMetricSource] = [
        .noopComputed, .whoopImport, .appleHealth, .localCache,
    ]

    /// Source precedence for a vital, highest first. Skin temp deliberately omits Apple Health — it
    /// has no 1:1 Apple equivalent for the strap's ±deviation reading, so an Apple absolute value must
    /// not stand in for it. localCache is always last (previews/tests).
    static func vitalPrecedence(for key: String) -> [DailyMetricSource] {
        switch key {
        case "skin":
            return [.whoopImport, .noopComputed, .localCache]
        default:
            return [.whoopImport, .noopComputed, .appleHealth, .localCache]
        }
    }
}
