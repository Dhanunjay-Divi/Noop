import Foundation

/// Transparent calendar-day training-load context.
///
/// Inputs must use one *additive* load unit throughout a series (for example session-RPE minutes,
/// TRIMP, or MET-minutes). Multiple sessions on the same day are summed. A bounded headline score
/// such as WHOOP/NOOP strain is nonlinear and must not be summed as though it were an impulse load.
///
/// ATL and CTL are exponentially weighted averages with 7- and 42-day time constants by default:
/// `alpha = 1 - exp(-1 / timeConstant)`. TSB is the descriptive difference `CTL - ATL`. These values
/// compare recent *recorded load* with a longer recorded-load baseline; they do not directly measure
/// fatigue, fitness, readiness, injury risk, or permission to train.
///
/// Formula and cold-start choices were independently implemented and cross-checked against the MIT
/// OpenStrap analytics implementation at commit `ebe45da6271ec99fbda353067b6deadc757ff2d8`
/// and the MIT `RuochenLyu/apple-health-analyst` project. No source code was copied.
public enum TrainingLoadModel {

    /// All day-count configuration stays within the same hard ceiling as timeline expansion. Besides
    /// bounding memory, this keeps every count conversion and window-index calculation far below `Int`
    /// overflow on every supported architecture.
    private static let maximumConfiguredDays = 36_600

    /// One additive load contribution. Several entries may share a day.
    public struct Entry: Sendable, Equatable {
        public let day: String
        public let load: Double

        public init(day: String, load: Double) {
            self.day = day
            self.load = load
        }
    }

    /// An observed calendar-day total. `0` is an explicitly observed rest day.
    public struct DailyLoad: Sendable, Equatable {
        public let day: String
        public let load: Double

        public init(day: String, load: Double) {
            self.day = day
            self.load = load
        }
    }

    public struct Aggregation: Sendable, Equatable {
        public let days: [DailyLoad]
        /// Entries rejected because their day was not canonical `YYYY-MM-DD`, or load was negative/non-finite.
        public let rejectedEntryCount: Int
    }

    /// Absence is unknown by default. Calling code must opt in before interpreting absent days as rest.
    public enum MissingDayPolicy: Sendable, Equatable {
        /// Do not manufacture zero load. A gap makes that day unavailable and restarts EWMA warm-up.
        case requireObserved
        /// Use zero for absent calendar days, while marking every affected output as estimated.
        case assumeRest
    }

    public struct Configuration: Sendable, Equatable {
        public let acuteTimeConstantDays: Double
        public let chronicTimeConstantDays: Double
        public let minimumHistoryDays: Int
        public let seedDays: Int
        public let rampWindowDays: Int
        public let stableRampFraction: Double
        /// Maximum inclusive first-to-last calendar span expanded into daily points. Defaults to ten
        /// years and is hard-capped at 100 years so untrusted dates cannot trigger unbounded allocation.
        public let maximumCalendarSpanDays: Int
        public let missingDayPolicy: MissingDayPolicy

        public init(acuteTimeConstantDays: Double = 7,
                    chronicTimeConstantDays: Double = 42,
                    minimumHistoryDays: Int = 14,
                    seedDays: Int = 7,
                    rampWindowDays: Int = 7,
                    stableRampFraction: Double = 0.10,
                    maximumCalendarSpanDays: Int = 3_660,
                    missingDayPolicy: MissingDayPolicy = .requireObserved) {
            precondition(acuteTimeConstantDays > 0 && acuteTimeConstantDays.isFinite
                         && acuteTimeConstantDays <= Double(TrainingLoadModel.maximumConfiguredDays))
            precondition(chronicTimeConstantDays > 0 && chronicTimeConstantDays.isFinite
                         && chronicTimeConstantDays <= Double(TrainingLoadModel.maximumConfiguredDays))
            precondition((1...TrainingLoadModel.maximumConfiguredDays).contains(minimumHistoryDays))
            precondition(seedDays >= 1 && seedDays <= minimumHistoryDays)
            precondition((1...TrainingLoadModel.maximumConfiguredDays).contains(rampWindowDays))
            precondition(stableRampFraction >= 0 && stableRampFraction.isFinite)
            precondition((1...TrainingLoadModel.maximumConfiguredDays).contains(maximumCalendarSpanDays))
            self.acuteTimeConstantDays = acuteTimeConstantDays
            self.chronicTimeConstantDays = chronicTimeConstantDays
            self.minimumHistoryDays = minimumHistoryDays
            self.seedDays = seedDays
            self.rampWindowDays = rampWindowDays
            self.stableRampFraction = stableRampFraction
            self.maximumCalendarSpanDays = maximumCalendarSpanDays
            self.missingDayPolicy = missingDayPolicy
        }
    }

    public enum DaySource: String, Sendable, Equatable {
        case observed
        case missing
        case assumedRest
    }

    public enum Quality: String, Sendable, Equatable {
        case unavailable
        case provisional
        case observed
        case estimated
    }

    public enum RampDirection: String, Sendable, Equatable {
        case building
        case steady
        case easing
        case unavailable
    }

    public struct Point: Sendable, Equatable {
        public let day: String
        /// The recorded daily total. Nil means no record existed for this calendar day.
        public let observedLoad: Double?
        /// The value folded into the model. Nil in strict mode; zero for an assumed rest day.
        public let effectiveLoad: Double?
        public let source: DaySource
        /// 7-day exponentially weighted recent load (default horizon); nil during warm-up/gaps.
        public let atl: Double?
        /// 42-day exponentially weighted load baseline (default horizon); nil during warm-up/gaps.
        public let ctl: Double?
        /// `CTL - ATL`, using the same day's estimates.
        public let tsb: Double?
        public let currentRampWindowLoad: Double?
        public let previousRampWindowLoad: Double?
        public let rampChange: Double?
        /// `(current - previous) / previous`; nil when the previous window total is zero.
        public let rampChangeFraction: Double?
        public let rampDirection: RampDirection
        /// Fraction of actually observed days in the trailing chronic-horizon calendar window.
        public let observedCoverage: Double
        public let assumedRestDaysInWindow: Int
        /// Assumptions folded into the current EWMA segment. Unlike window coverage, this stays nonzero
        /// while an assumed impulse can still influence the recursive state.
        public let assumedRestDaysInModelHistory: Int
        /// Consecutive effective calendar days behind this estimate; resets after a strict missing day.
        public let consecutiveHistoryDays: Int
        public let quality: Quality
        /// Cautious UI-ready context. It deliberately avoids fitness/fatigue/injury claims.
        public let interpretation: String
    }

    public struct Series: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable {
            case complete
            case empty
            case calendarSpanExceeded
        }

        /// Observed daily totals only; missing calendar dates are represented in `points`.
        public let observedDays: [DailyLoad]
        /// One point for every calendar day from first to last valid input.
        public let points: [Point]
        public let rejectedEntryCount: Int
        public let status: Status

        public var latest: Point? { points.last }
    }

    /// Validate entries and add all valid contributions that share a calendar day.
    public static func aggregate(_ entries: [Entry]) -> Aggregation {
        var totals: [String: Double] = [:]
        var rejected = 0
        for entry in entries {
            guard parseDay(entry.day) != nil, entry.load.isFinite, entry.load >= 0 else {
                rejected += 1
                continue
            }
            let total = totals[entry.day, default: 0] + entry.load
            guard total.isFinite else {
                // Keep the valid total accumulated so far and reject only the contribution that overflowed.
                rejected += 1
                continue
            }
            totals[entry.day] = total
        }
        let days = totals.keys.sorted().compactMap { day -> DailyLoad? in
            totals[day].map { DailyLoad(day: day, load: $0) }
        }
        return Aggregation(days: days, rejectedEntryCount: rejected)
    }

    public static func evaluate(entries: [Entry],
                                configuration: Configuration = Configuration()) -> Series {
        let aggregation = aggregate(entries)
        guard let first = aggregation.days.first.flatMap({ parseDay($0.day) }),
              let last = aggregation.days.last.flatMap({ parseDay($0.day) }) else {
            return Series(observedDays: aggregation.days, points: [],
                          rejectedEntryCount: aggregation.rejectedEntryCount, status: .empty)
        }

        let observedByDay = Dictionary(uniqueKeysWithValues: aggregation.days.map { ($0.day, $0.load) })
        let calendar = utcCalendar
        let span = calendar.dateComponents([.day], from: first, to: last).day.map { $0 + 1 }
        guard let span, span > 0, span <= configuration.maximumCalendarSpanDays else {
            return Series(observedDays: aggregation.days, points: [],
                          rejectedEntryCount: aggregation.rejectedEntryCount,
                          status: .calendarSpanExceeded)
        }
        var timeline: [(day: String, observed: Double?)] = []
        timeline.reserveCapacity(span)
        var date = first
        while date <= last {
            let key = dayKey(date)
            timeline.append((key, observedByDay[key]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }

        let acuteAlpha = 1 - exp(-1 / configuration.acuteTimeConstantDays)
        let chronicAlpha = 1 - exp(-1 / configuration.chronicTimeConstantDays)
        let coverageWindow = max(1, Int(configuration.chronicTimeConstantDays.rounded()))
        var segmentLoads: [Double] = []
        var atlState: Double?
        var ctlState: Double?
        var segmentAssumedDays = 0
        var effectiveLoads: [Double?] = []
        var sources: [DaySource] = []
        var points: [Point] = []

        for (index, item) in timeline.enumerated() {
            let source: DaySource
            let effective: Double?
            if let observed = item.observed {
                source = .observed
                effective = observed
            } else if configuration.missingDayPolicy == .assumeRest {
                source = .assumedRest
                effective = 0
            } else {
                source = .missing
                effective = nil
            }
            effectiveLoads.append(effective)
            sources.append(source)

            if let load = effective {
                segmentLoads.append(load)
                if source == .assumedRest { segmentAssumedDays += 1 }
                if segmentLoads.count == configuration.seedDays {
                    if let seed = finiteMean(segmentLoads) {
                        atlState = seed
                        ctlState = seed
                    } else {
                        // A finite input can still make an intermediate overflow if a future formula
                        // changes. Abstain and restart rather than publishing NaN/Infinity as health data.
                        segmentLoads.removeAll(keepingCapacity: true)
                        segmentAssumedDays = 0
                        atlState = nil
                        ctlState = nil
                    }
                } else if segmentLoads.count > configuration.seedDays,
                          let previousAtl = atlState, let previousCtl = ctlState {
                    let nextAtl = previousAtl + acuteAlpha * (load - previousAtl)
                    let nextCtl = previousCtl + chronicAlpha * (load - previousCtl)
                    if nextAtl.isFinite, nextCtl.isFinite {
                        atlState = nextAtl
                        ctlState = nextCtl
                    } else {
                        segmentLoads.removeAll(keepingCapacity: true)
                        segmentAssumedDays = 0
                        atlState = nil
                        ctlState = nil
                    }
                }
            } else {
                // A mathematically exact EWMA cannot be recovered when its input is unknown. Strict mode
                // therefore abstains and starts a new warm-up segment after the gap instead of silently
                // applying a zero impulse or compressing calendar time.
                segmentLoads.removeAll(keepingCapacity: true)
                segmentAssumedDays = 0
                atlState = nil
                ctlState = nil
            }

            let modelIsWarm = segmentLoads.count >= configuration.minimumHistoryDays
            let atl: Double?
            let ctl: Double?
            let tsb: Double?
            if modelIsWarm, let candidateAtl = atlState, let candidateCtl = ctlState,
               candidateAtl.isFinite, candidateCtl.isFinite {
                let candidateTsb = candidateCtl - candidateAtl
                if candidateTsb.isFinite {
                    atl = candidateAtl
                    ctl = candidateCtl
                    tsb = candidateTsb
                } else {
                    atl = nil
                    ctl = nil
                    tsb = nil
                }
            } else {
                atl = nil
                ctl = nil
                tsb = nil
            }

            let ramp = rampContext(effectiveLoads: effectiveLoads,
                                   windowDays: configuration.rampWindowDays,
                                   stableFraction: configuration.stableRampFraction)
            let coverageStart = max(0, index - coverageWindow + 1)
            let coverageSources = sources[coverageStart...index]
            let observedCount = coverageSources.filter { $0 == .observed }.count
            let assumedCount = coverageSources.filter { $0 == .assumedRest }.count
            let coverage = Double(observedCount) / Double(coverageSources.count)
            let quality: Quality
            if atl == nil || ctl == nil {
                quality = .unavailable
            } else if segmentAssumedDays > 0 {
                quality = .estimated
            } else if segmentLoads.count < coverageWindow {
                quality = .provisional
            } else {
                quality = .observed
            }

            points.append(Point(
                day: item.day,
                observedLoad: item.observed,
                effectiveLoad: effective,
                source: source,
                atl: atl,
                ctl: ctl,
                tsb: tsb,
                currentRampWindowLoad: ramp.current,
                previousRampWindowLoad: ramp.previous,
                rampChange: ramp.change,
                rampChangeFraction: ramp.fraction,
                rampDirection: ramp.direction,
                observedCoverage: coverage,
                assumedRestDaysInWindow: assumedCount,
                assumedRestDaysInModelHistory: segmentAssumedDays,
                consecutiveHistoryDays: segmentLoads.count,
                quality: quality,
                interpretation: interpretation(quality: quality, tsb: tsb,
                                               consecutiveDays: segmentLoads.count,
                                               minimumDays: configuration.minimumHistoryDays,
                                               assumedCount: segmentAssumedDays)
            ))
        }

        return Series(observedDays: aggregation.days, points: points,
                      rejectedEntryCount: aggregation.rejectedEntryCount, status: .complete)
    }

    private static func rampContext(effectiveLoads: [Double?], windowDays: Int,
                                    stableFraction: Double) ->
        (current: Double?, previous: Double?, change: Double?, fraction: Double?, direction: RampDirection) {
        // Division-first avoids `windowDays * 2` overflow even if this private helper is ever reused
        // independently of Configuration's public bounds.
        guard windowDays > 0, windowDays <= effectiveLoads.count / 2 else {
            return (nil, nil, nil, nil, .unavailable)
        }
        let currentStart = effectiveLoads.count - windowDays
        let previousStart = currentStart - windowDays
        let previousSlice = effectiveLoads[previousStart..<currentStart]
        let currentSlice = effectiveLoads[currentStart...]
        guard previousSlice.allSatisfy({ $0 != nil }), currentSlice.allSatisfy({ $0 != nil }) else {
            return (nil, nil, nil, nil, .unavailable)
        }
        guard let previous = finiteSum(previousSlice.compactMap { $0 }),
              let current = finiteSum(currentSlice.compactMap { $0 }) else {
            return (nil, nil, nil, nil, .unavailable)
        }
        let change = current - previous
        guard change.isFinite else { return (nil, nil, nil, nil, .unavailable) }
        guard previous > 0 else {
            let direction: RampDirection = current > 0 ? .building : .steady
            return (current, previous, change, nil, direction)
        }
        let fraction = change / previous
        guard fraction.isFinite else {
            return (current, previous, change, nil, .unavailable)
        }
        let direction: RampDirection
        if fraction > stableFraction {
            direction = .building
        } else if fraction < -stableFraction {
            direction = .easing
        } else {
            direction = .steady
        }
        return (current, previous, change, fraction, direction)
    }

    private static func interpretation(quality: Quality, tsb: Double?, consecutiveDays: Int,
                                       minimumDays: Int, assumedCount: Int) -> String {
        guard let tsb, tsb.isFinite else {
            return "Load comparison unavailable: \(consecutiveDays) of \(minimumDays) consecutive calendar days recorded."
        }
        if quality == .estimated {
            return "Estimate includes \(assumedCount) unobserved day\(assumedCount == 1 ? "" : "s") treated as rest; it describes recorded load only."
        }
        let comparison: String
        if tsb < -0.000_001 {
            comparison = "Recent recorded load is above the longer-term recorded-load baseline."
        } else if tsb > 0.000_001 {
            comparison = "Recent recorded load is below the longer-term recorded-load baseline."
        } else {
            comparison = "Recent and longer-term recorded load are similar."
        }
        if quality == .provisional {
            return "Provisional: \(comparison) This is load context, not a fitness or fatigue measurement."
        }
        return "\(comparison) This is load context, not a fitness or fatigue measurement."
    }

    /// Incremental mean for nonnegative finite loads. Unlike `sum / count`, this cannot overflow merely
    /// because several individually representable daily values are near `Double.greatestFiniteMagnitude`.
    private static func finiteMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var mean = 0.0
        for (index, value) in values.enumerated() {
            guard value.isFinite, value >= 0 else { return nil }
            let next = mean + (value - mean) / Double(index + 1)
            guard next.isFinite else { return nil }
            mean = next
        }
        return mean
    }

    /// A ramp total is itself part of the public result, so a mathematically unrepresentable sum is
    /// unavailable rather than Infinity. Inputs are already nonnegative, making overflow monotonic.
    private static func finiteSum(_ values: [Double]) -> Double? {
        var total = 0.0
        for value in values {
            guard value.isFinite, value >= 0 else { return nil }
            let next = total + value
            guard next.isFinite else { return nil }
            total = next
        }
        return total
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func parseDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let calendar = utcCalendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(date) == value else { return nil }
        return date
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
