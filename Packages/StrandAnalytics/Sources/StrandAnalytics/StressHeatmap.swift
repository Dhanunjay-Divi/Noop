import Foundation

// StressHeatmap.swift — pure week×hour aggregation of the intraday autonomic-load timeline (R7).
//
// The Autonomic Load screen already shows TODAY's hour-by-hour read (`DaytimeStress`) and a daily trend.
// This engine answers the pattern question those two can't: **which hours of which days are habitually
// loaded?** ("Wednesday afternoons run hot", "you unwind after 21:00"). That is the coachable insight a
// heatmap exists for, and it is derived entirely from data NOOP already computes — no new sensor, no new
// claim, nothing fabricated: an hour with no usable signal stays `nil` and renders as an empty cell.
//
// Pure + closed-form so it is unit-tested and BYTE-IDENTICAL to the Android twin
// (com.noop.analytics.StressHeatmap). Bands match the app's shared 0–3 scale (StressBand): <1 low,
// <2 medium, ≥2 high.
//
// APPROXIMATE and non-clinical, exactly like the underlying score: this is a wellness pattern view of an
// autonomic-load proxy, never a stress diagnosis and never a medical reading.
public enum StressHeatmap {

    // MARK: - Bands (mirror StressBand / DaytimeStress.highBandFloor)

    /// Upper bound (exclusive) of the LOW band on the shared 0–3 scale.
    public static let lowBandCeiling: Double = 1.0
    /// Upper bound (exclusive) of the MEDIUM band; at/above this is HIGH (= DaytimeStress.highBandFloor).
    public static let highBandFloor: Double = 2.0

    public enum Band: String, Equatable, Sendable {
        case low, medium, high
    }

    /// Band for a 0–3 level. Matches the UI's `StressBand(score:)` cut points exactly.
    public static func band(_ level: Double) -> Band {
        if level < lowBandCeiling { return .low }
        if level < highBandFloor { return .medium }
        return .high
    }

    // MARK: - Input / output

    /// One day's hourly levels: `levels[h]` is the 0–3 autonomic load for local hour `h` (0…23), or nil
    /// when that hour had no usable signal. Callers build this from `DaytimeStress.Result.hours`.
    public struct DayColumn: Equatable, Sendable {
        /// Local day key, `yyyy-MM-dd`.
        public let day: String
        /// Sparse hour → level map (0…23 keys). Hours absent from the map are treated as no-data.
        public let levels: [Int: Double]
        public init(day: String, levels: [Int: Double]) {
            self.day = day
            self.levels = levels
        }
    }

    /// One grid cell. `level == nil` ⇒ no usable signal for that day/hour (render as an empty slot).
    public struct Cell: Equatable, Sendable {
        public let day: String
        /// Column index in the supplied order (0 = first/oldest column given).
        public let dayIndex: Int
        /// Local hour-of-day row, 0…23.
        public let hour: Int
        public let level: Double?
        public init(day: String, dayIndex: Int, hour: Int, level: Double?) {
            self.day = day
            self.dayIndex = dayIndex
            self.hour = hour
            self.level = level
        }
        /// Band for the cell, or nil when there's no level (never guesses a band).
        public var band: Band? { level.map { StressHeatmap.band($0) } }
    }

    /// The pattern read-out over a grid: which hour runs hottest/calmest across the window, plus honest
    /// coverage so the UI can gate the narrative until there is enough data.
    public struct Summary: Equatable, Sendable {
        /// Hour-of-day (0…23) with the highest mean level, or nil when nothing is scored.
        public let peakHour: Int?
        /// Mean level at `peakHour`.
        public let peakHourMean: Double?
        /// Hour-of-day with the lowest mean level, or nil.
        public let calmestHour: Int?
        /// Mean level at `calmestHour`.
        public let calmestHourMean: Double?
        /// Mean level across every scored cell, or nil.
        public let overallMean: Double?
        /// Scored cells ÷ total cells, 0…1 — the honesty gate (sparse wear ⇒ low coverage).
        public let coverage: Double
        public let scoredCells: Int
        public let totalCells: Int
        public init(peakHour: Int?, peakHourMean: Double?, calmestHour: Int?, calmestHourMean: Double?,
                    overallMean: Double?, coverage: Double, scoredCells: Int, totalCells: Int) {
            self.peakHour = peakHour
            self.peakHourMean = peakHourMean
            self.calmestHour = calmestHour
            self.calmestHourMean = calmestHourMean
            self.overallMean = overallMean
            self.coverage = coverage
            self.scoredCells = scoredCells
            self.totalCells = totalCells
        }
        /// Empty read — no columns or nothing scored.
        public static let empty = Summary(peakHour: nil, peakHourMean: nil, calmestHour: nil,
                                          calmestHourMean: nil, overallMean: nil, coverage: 0,
                                          scoredCells: 0, totalCells: 0)
    }

    // MARK: - Grid

    /// Default row window: the same waking band the intraday timeline uses (06:00–22:00 inclusive of 6,
    /// exclusive of 22), so the heatmap and the timeline agree on what a "day" covers.
    public static let defaultStartHour: Int = DaytimeStress.wakingStartHour
    public static let defaultEndHour: Int = DaytimeStress.wakingEndHour

    /// Build the grid in row-major order (for each hour, each column) so a UI can lay out rows directly.
    /// Hours outside `[startHour, endHour)` are omitted. An out-of-order or clamped window yields [].
    public static func grid(columns: [DayColumn],
                            startHour: Int = defaultStartHour,
                            endHour: Int = defaultEndHour) -> [Cell] {
        let lo = max(0, min(23, startHour))
        let hi = max(0, min(24, endHour))
        guard hi > lo, !columns.isEmpty else { return [] }
        var out: [Cell] = []
        out.reserveCapacity((hi - lo) * columns.count)
        for hour in lo..<hi {
            for (i, col) in columns.enumerated() {
                out.append(Cell(day: col.day, dayIndex: i, hour: hour, level: col.levels[hour]))
            }
        }
        return out
    }

    /// Mean level per hour-of-day across all columns (only scored cells contribute). Hours with no scored
    /// cell are absent from the result — never zero-filled.
    public static func meanByHour(_ cells: [Cell]) -> [Int: Double] {
        var sums: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        for c in cells {
            guard let l = c.level else { continue }
            sums[c.hour, default: 0] += l
            counts[c.hour, default: 0] += 1
        }
        var out: [Int: Double] = [:]
        for (hour, sum) in sums {
            if let n = counts[hour], n > 0 { out[hour] = sum / Double(n) }
        }
        return out
    }

    /// Pattern summary over a grid. Ties on peak/calmest resolve to the EARLIER hour so the result is
    /// deterministic (and identical to the Kotlin twin).
    public static func summary(_ cells: [Cell]) -> Summary {
        guard !cells.isEmpty else { return .empty }
        let byHour = meanByHour(cells)
        let scored = cells.compactMap(\.level)
        let total = cells.count
        guard !scored.isEmpty, !byHour.isEmpty else {
            return Summary(peakHour: nil, peakHourMean: nil, calmestHour: nil, calmestHourMean: nil,
                           overallMean: nil, coverage: 0, scoredCells: 0, totalCells: total)
        }
        // Deterministic tie-break: sort by (mean, hour) and take the ends.
        let ascending = byHour.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value < b.value
        }
        let calmest = ascending.first
        // For the peak, prefer the highest mean but the EARLIEST hour among equals.
        let peak = ascending.reversed().min { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        let overall = scored.reduce(0, +) / Double(scored.count)
        return Summary(peakHour: peak?.key,
                       peakHourMean: peak?.value,
                       calmestHour: calmest?.key,
                       calmestHourMean: calmest?.value,
                       overallMean: overall,
                       coverage: Double(scored.count) / Double(total),
                       scoredCells: scored.count,
                       totalCells: total)
    }
}
