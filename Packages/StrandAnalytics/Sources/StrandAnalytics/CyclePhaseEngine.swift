import Foundation

// CyclePhaseEngine.swift — on-device menstrual-cycle PHASE AWARENESS from the nightly skin-temperature
// series, corroborated by the luteal resting-HR rise and the luteal HRV drop. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of a publicly documented method (wrist skin-temperature cycle tracking,
// e.g. PMC11294004, and the broader biphasic-ovulatory-shift literature): skin temperature runs roughly
// 0.3–0.5 °C HIGHER in the luteal phase than the follicular phase, with a nadir around ovulation,
// mirrored by a luteal RESTING-HR RISE and a luteal HRV (RMSSD) DROP. NOOP re-derives this from the
// user's OWN banked nightly signals against their OWN baseline — it reproduces no competitor's model.
//
// WELLNESS / AWARENESS ONLY — APPROXIMATE. This is NOT contraception, NOT a fertility/ovulation predictor,
// NOT a medical device, and NOT a diagnosis. It never frames a "fertile window" or "safe days," never
// emits a single confident period DATE (only a probabilistic WINDOW), and never diagnoses PCOS,
// pregnancy, perimenopause or any condition - when the signal is flat/irregular it says "no clear
// pattern," never a verdict. All of this is the load-bearing legal/ethical framing.
public enum CyclePhaseEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Weights for the fused luteal index z = wTemp·zTemp + wRHR·zRHR + wHRV·(−zHRV). Temperature is
    /// dominant (it is the pillar's signal); RHR and HRV corroborate. The HRV term is NEGATED so a drop
    /// pushes the index UP (luteal-ward), matching temp ↑ and RHR ↑.
    public static let wTemp: Double = 0.6
    public static let wRHR: Double = 0.2
    public static let wHRV: Double = 0.2

    /// A night counts as "elevated" (luteal-ward) when its fused index sits at least this many spreads
    /// above the personal series mean. Robust spread = the series' median absolute deviation (MAD), so a
    /// few extreme nights don't widen the gate.
    public static let elevationK: Double = 0.5

    /// Plausibility clamp on the estimated cycle length (days). Anything outside is treated as "no clear
    /// pattern" rather than a fabricated cadence.
    public static let minCycleDays: Int = 21
    public static let maxCycleDays: Int = 40
    /// Typical cycle length used as the prior for the next-period WINDOW when the personal median isn't
    /// yet reliable. Deliberately a textbook average, not a claim about this user.
    public static let defaultCycleDays: Int = 28

    /// Minimum number of nights of usable data before the engine will classify at all (~1.5 cycles).
    public static let minNightsToClassify: Int = 42

    /// Half-width (days) of the peri-ovulatory band around the estimated elevation onset — the days
    /// straddling the follicular→luteal temperature shift.
    public static let periOvulatoryHalfWidth: Int = 2
    /// Reject a one-night heat, illness, fit, or sleep artifact: a shift needs at least two of the
    /// trailing three nights above the personal threshold.
    public static let elevationConfirmationNights: Int = 3
    public static let elevationRequiredNights: Int = 2
    /// Forecast windows expand from the person's observed interval spread, within honest bounds.
    public static let minPersonalWindowHalfWidth: Int = 2
    public static let maxPersonalWindowHalfWidth: Int = 7
    /// With at least three intervals, a wider range is not precise enough for a useful forecast.
    /// This is an uncertainty gate, not a diagnosis or an "irregular cycle" label.
    public static let maxForecastableIntervalRange: Int = 12

    // MARK: - Inputs

    /// One night's already-standardized inputs. `tempZ` / `rhrZ` / `hrvZ` are z-scores from
    /// `Baselines.deviation` against each metric's personal baseline (the caller computes them so the
    /// engine stays I/O-free). `day` is a "yyyy-MM-dd" key, oldest→newest in the array. A missing signal
    /// is nil and simply doesn't contribute to that night's fused index.
    public struct Night: Equatable, Sendable {
        public let day: String
        public let tempZ: Double?
        public let rhrZ: Double?
        public let hrvZ: Double?
        public init(day: String, tempZ: Double?, rhrZ: Double?, hrvZ: Double?) {
            self.day = day; self.tempZ = tempZ; self.rhrZ = rhrZ; self.hrvZ = hrvZ
        }
    }

    // MARK: - Output

    public enum Phase: String, Equatable, Sendable, Codable {
        case follicular
        case periOvulatory
        case luteal
        case unknown        // no clear pattern — NEVER a fabricated phase
        case learning       // not enough data yet
    }

    public enum Confidence: String, Equatable, Sendable, Codable {
        case learning       // < minNightsToClassify, or baseline not usable
        case building       // useful logged cadence or a coarse sensor pattern, not yet sensor-solid
        case solid          // a stable repeating shift detected
    }

    public enum NoteKind: String, Equatable, Sendable, Codable {
        case learningNightly
        case noClearPattern
        case noClearContext
        case logShiftMismatch
        case phaseFollicular
        case phaseMidCycle
        case phaseLuteal
        case staleLog
        case unreliableLogs
        case forecastPassed
        case broadPrior
        case personalIntervals
        case startLogging
        case turnOnAwareness

        public var english: String {
            switch self {
            case .learningNightly:
                return "Learning your pattern from your nightly temperature - keep wearing it overnight."
            case .noClearPattern:
                return "No clear temperature pattern yet."
            case .noClearContext:
                return "No clear temperature pattern yet - this can happen with irregular cycles, "
                    + "hormonal birth control, or shift work."
            case .logShiftMismatch:
                return "Your temperature shift came at a different time than your logged date - "
                    + "the logged start may be off."
            case .phaseFollicular:
                return "Follicular range - temperature sitting at your baseline."
            case .phaseMidCycle:
                return "Around your mid-cycle shift - temperature is turning."
            case .phaseLuteal:
                return "Luteal range - temperature is running above your baseline."
            case .staleLog:
                return "Your last logged start is over 40 days old. Log the latest start to refresh "
                    + "this estimate; NOOP will not roll an old date forward."
            case .unreliableLogs:
                return "Recent logged cycle lengths vary too much or include an interval outside the "
                    + "supported range for a useful period forecast. "
                    + "Cycle day still counts from your latest start."
            case .forecastPassed:
                return "The estimated window from your last log has passed. Log the next start when it happens; "
                    + "NOOP will not roll an old date forward."
            case .broadPrior:
                return "Cycle day is anchored to your logged start. The broad period window uses a 28-day prior "
                    + "while nightly temperature calibration continues."
            case .personalIntervals:
                return "Cycle day is anchored to your latest start. The period window uses your recent logged "
                    + "intervals and expands with their variability."
            case .startLogging:
                return "Log a period start and wear Noop Band overnight to begin a private estimate."
            case .turnOnAwareness:
                return "Turn on cycle awareness to read a coarse phase from your nightly temperature."
            }
        }
    }

    /// A detected follicular→luteal temperature shift onset (for the curve markers).
    public struct ShiftMarker: Equatable, Sendable {
        public let day: String
        public init(day: String) { self.day = day }
    }

    /// A probabilistic next-period WINDOW. Always a range of days, never a single confident date.
    public struct NextPeriodWindow: Equatable, Sendable {
        public let earliestDay: String
        public let latestDay: String
        public init(earliestDay: String, latestDay: String) {
            self.earliestDay = earliestDay; self.latestDay = latestDay
        }
    }

    public struct Result: Equatable, Sendable {
        public let phase: Phase
        public let confidence: Confidence
        /// Inclusive cycle-day estimate as a RANGE, not a point (nil when unknown/learning).
        public let cycleDayLow: Int?
        public let cycleDayHigh: Int?
        /// Estimated personal cycle length in days (nil until a repeat is seen).
        public let cycleLengthDays: Int?
        /// Probabilistic next-period window (nil unless a usable cadence + recent elevation exist).
        public let nextPeriodWindow: NextPeriodWindow?
        /// Temperature-shift onsets across the window (oldest→newest) for the detail curve.
        public let shiftMarkers: [ShiftMarker]
        /// A short, non-clinical status line.
        public let note: String
        /// Stable presentation categories. UI localizes these and falls back to `note` for custom/debug data.
        public let noteKinds: [NoteKind]

        public init(phase: Phase, confidence: Confidence, cycleDayLow: Int?, cycleDayHigh: Int?,
                    cycleLengthDays: Int?, nextPeriodWindow: NextPeriodWindow?,
                    shiftMarkers: [ShiftMarker], note: String, noteKinds: [NoteKind] = []) {
            self.phase = phase; self.confidence = confidence
            self.cycleDayLow = cycleDayLow; self.cycleDayHigh = cycleDayHigh
            self.cycleLengthDays = cycleLengthDays; self.nextPeriodWindow = nextPeriodWindow
            self.shiftMarkers = shiftMarkers; self.note = note; self.noteKinds = noteKinds
        }
    }

    /// Standing awareness-only line shown on every cycle surface (legal/ethical framing).
    public static let awarenessLine =
        "For awareness only. Not a medical device, not contraception, not a substitute for professional care."

    // MARK: - Classify

    /// Classify the most recent night from the trailing series.
    ///
    /// - Parameters:
    ///   - nights: oldest→newest nightly inputs.
    ///   - baselineUsable: whether the personal skin-temp baseline is at least `usable` (the caller
    ///     passes `BaselineState.usable`). Below this we stay in `.learning` and never invent a phase.
    ///   - loggedPeriodStarts: optional "yyyy-MM-dd" period-start days the user logged. When present, the
    ///     most recent one anchors cycle-day 1 and we CROSS-VALIDATE it against the detected shift, flagging
    ///     a mistimed log rather than trusting it blindly. Optional — the engine works temperature-only.
    ///   - asOfDay: optional current civil day. Sensor classification still uses the latest measured night,
    ///     while logged cycle-day/window calculations advance to this date even when no wearable night exists.
    public static func classify(_ nights: [Night],
                                baselineUsable: Bool,
                                loggedPeriodStarts: [String] = [],
                                asOfDay explicitAsOfDay: String? = nil) -> Result {
        // Explicitly logged starts can provide a bounded cycle-day range and a broad next-period window
        // before temperature calibration completes. They never create a sensor-derived phase: phase stays
        // `learning` until the baseline + night-count gate below is satisfied.
        let fallbackAsOfDay = nights.map(\.day).filter { parseDay($0) != nil }.max()
            ?? loggedPeriodStarts.filter { parseDay($0) != nil }.max()
        let asOfDay = explicitAsOfDay.flatMap { parseDay($0) == nil ? nil : $0 }
            ?? fallbackAsOfDay
        let loggedEstimate = asOfDay.flatMap {
            estimateFromLoggedStarts(loggedPeriodStarts, asOfDay: $0)
        }

        // Gate: need a usable baseline and ~1.5 cycles of data.
        guard baselineUsable, nights.count >= minNightsToClassify else {
            if let loggedEstimate {
                return Result(
                    phase: .learning,
                    confidence: .building,
                    cycleDayLow: loggedEstimate.cycleDayLow,
                    cycleDayHigh: loggedEstimate.cycleDayHigh,
                    cycleLengthDays: loggedEstimate.cycleLengthDays,
                    nextPeriodWindow: loggedEstimate.nextPeriodWindow,
                    shiftMarkers: [],
                    note: loggedEstimate.note,
                    noteKinds: [loggedEstimate.noteKind]
                )
            }
            let noteKinds: [NoteKind] = [.learningNightly]
            return Result(phase: .learning, confidence: .learning, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: [],
                          note: noteText(noteKinds), noteKinds: noteKinds)
        }

        // Fuse each night into a single luteal index; nil where no signal at all.
        let fused: [(day: String, value: Double?)] = nights.map { n in
            (n.day, fusedIndex(tempZ: n.tempZ, rhrZ: n.rhrZ, hrvZ: n.hrvZ))
        }
        let values = fused.compactMap { $0.value }
        guard values.count >= minNightsToClassify else {
            if let loggedEstimate {
                return Result(
                    phase: .learning,
                    confidence: .building,
                    cycleDayLow: loggedEstimate.cycleDayLow,
                    cycleDayHigh: loggedEstimate.cycleDayHigh,
                    cycleLengthDays: loggedEstimate.cycleLengthDays,
                    nextPeriodWindow: loggedEstimate.nextPeriodWindow,
                    shiftMarkers: [],
                    note: loggedEstimate.note,
                    noteKinds: [loggedEstimate.noteKind]
                )
            }
            let noteKinds: [NoteKind] = [.learningNightly]
            return Result(phase: .learning, confidence: .learning, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: [],
                          note: noteText(noteKinds), noteKinds: noteKinds)
        }

        let center = median(values)
        let spread = max(1e-9, medianAbsoluteDeviation(values, center: center))

        // Per-night elevated evidence.
        let rawElevated: [Bool] = fused.map { row in
            guard let v = row.value else { return false }
            return (v - center) >= elevationK * spread
        }

        // Confirm with a trailing majority. This costs at most one night at a sustained transition and
        // prevents a single hot or restless night from becoming a cycle shift.
        let elevated: [Bool] = rawElevated.indices.map { index in
            let lower = max(0, index - elevationConfirmationNights + 1)
            return rawElevated[lower...index].filter { $0 }.count >= elevationRequiredNights
        }

        // Detect rising EDGES (follicular→luteal onsets) from the confirmed state.
        var onsets: [Int] = []
        for i in fused.indices {
            if elevated[i] && (i == 0 || !elevated[i - 1]) { onsets.append(i) }
        }
        let shiftMarkers = onsets.map { ShiftMarker(day: fused[$0].day) }

        // No detectable shift at all → honest "no clear pattern," never a fabricated phase.
        guard let lastOnsetIdx = onsets.last else {
            if let loggedEstimate {
                return Result(
                    phase: .unknown,
                    confidence: .building,
                    cycleDayLow: loggedEstimate.cycleDayLow,
                    cycleDayHigh: loggedEstimate.cycleDayHigh,
                    cycleLengthDays: loggedEstimate.cycleLengthDays,
                    nextPeriodWindow: loggedEstimate.nextPeriodWindow,
                    shiftMarkers: shiftMarkers,
                    note: noteText([.noClearPattern, loggedEstimate.noteKind]),
                    noteKinds: [.noClearPattern, loggedEstimate.noteKind]
                )
            }
            let noteKinds: [NoteKind] = [.noClearContext]
            return Result(phase: .unknown, confidence: .building, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: shiftMarkers,
                          note: noteText(noteKinds), noteKinds: noteKinds)
        }

        // Personal cycle length from the median gap between successive onsets (in calendar days).
        var onsetGaps: [Int] = []
        if onsets.count >= 2 {
            for k in 1..<onsets.count {
                if let d = daysBetween(fused[onsets[k - 1]].day, fused[onsets[k]].day) { onsetGaps.append(d) }
            }
        }
        let medianGap = onsetGaps.isEmpty ? nil : Int(median(onsetGaps.map(Double.init)).rounded())
        let sensorCycleLength: Int? = {
            guard let g = medianGap, g >= minCycleDays, g <= maxCycleDays else { return nil }
            return g
        }()
        let confidence: Confidence = sensorCycleLength != nil ? .solid : .building

        // Optional logged-period cross-validation (better mode). The most recent logged start that falls
        // on/before the latest night anchors cycle-day 1; we compare it to the detected onset.
        let lastNightDay = fused.last!.day
        var noteKinds: [NoteKind] = []
        let anchorDay = fused[lastOnsetIdx].day      // sensor-only anchor = the temperature shift onset
        let anchoredByLog = loggedEstimate?.cycleDayLow != nil
        if let loggedStart = mostRecentOnOrBefore(loggedPeriodStarts, day: lastNightDay),
           anchoredByLog {
            let delta = daysBetween(loggedStart, fused[lastOnsetIdx].day)
            // The temperature SHIFT (luteal onset) sits well after period-start in a normal cycle; an
            // implausible offset OR a logged start older than a full cycle before the latest night (a
            // newer period is overdue) means the log is likely mistimed — FLAG it, don't silently trust.
            let sinceLog = daysBetween(loggedStart, lastNightDay) ?? 0
            if (delta.map { $0 < 0 || $0 > maxCycleDays } ?? false) || sinceLog > maxCycleDays {
                noteKinds = [.logShiftMismatch]
            }
        }

        // Cycle-day estimate as a RANGE. If anchored by a log we count from day 1 at the log; in
        // temperature-only mode we count from the shift onset, which in a typical cycle is the start of
        // the luteal phase (~day 14–16), so we offset by a coarse follicular-length prior.
        let daysSinceAnchor = daysBetween(anchorDay, lastNightDay) ?? 0
        let (cycleDayLow, cycleDayHigh): (Int?, Int?) = {
            if anchoredByLog {
                return (loggedEstimate?.cycleDayLow, loggedEstimate?.cycleDayHigh)
            } else {
                // Shift onset ≈ luteal start; place it near a typical follicular length, widen the band.
                let lutealStartDay = (sensorCycleLength ?? defaultCycleDays) / 2
                let d = lutealStartDay + daysSinceAnchor
                return (max(1, d - 2), d + 2)             // ±2 day band (coarser without a log)
            }
        }()

        // Phase of the MOST RECENT night relative to the latest onset.
        let daysSinceOnset = daysBetween(fused[lastOnsetIdx].day, lastNightDay) ?? 0
        let phase: Phase
        if elevated[fused.count - 1] {
            // Currently in an elevated run → luteal, unless we're right at the onset edge (peri-ovulatory).
            phase = daysSinceOnset <= periOvulatoryHalfWidth ? .periOvulatory : .luteal
        } else {
            // Below the elevation gate. Near a known onset it's the peri-ovulatory dip; otherwise follicular.
            phase = daysSinceOnset <= periOvulatoryHalfWidth ? .periOvulatory : .follicular
        }

        // Probabilistic next-period WINDOW: the luteal→follicular temperature drop precedes menses, so a
        // period is likely roughly one cycle length on from the anchor. Always a RANGE, never a date.
        var window = loggedEstimate?.nextPeriodWindow
        if loggedEstimate == nil, let len = sensorCycleLength {
            // Next expected onset of menses ≈ anchor + cycle length. Window = ±2 days around it, but only
            // surfaced once we're within range and on/after the anchor.
            if let earliest = shiftDay(anchorDay, by: len - 2),
               let latest = shiftDay(anchorDay, by: len + 2),
               latest >= lastNightDay {
                window = NextPeriodWindow(earliestDay: max(lastNightDay, earliest), latestDay: latest)
            }
        }

        if noteKinds.isEmpty {
            noteKinds = [phaseNoteKind(phase)]
            if let loggedEstimate, loggedEstimate.forecastSuppressed {
                noteKinds.append(loggedEstimate.noteKind)
            }
        }

        // Period starts directly observe period cadence, so a usable logged cadence wins over spacing
        // between temperature shifts. When logs are stale or too variable, keep this nil rather than
        // falling back to a sensor interval and implying precision the direct history does not support.
        let cycleLength = loggedEstimate != nil
            ? loggedEstimate?.cycleLengthDays
            : sensorCycleLength
        return Result(phase: phase, confidence: confidence,
                      cycleDayLow: cycleDayLow, cycleDayHigh: cycleDayHigh,
                      cycleLengthDays: cycleLength, nextPeriodWindow: window,
                      shiftMarkers: shiftMarkers, note: noteText(noteKinds),
                      noteKinds: noteKinds)
    }

    // MARK: - Fusion

    /// Weighted fused luteal index for one night. The HRV z is negated (a drop is luteal-ward). Weights
    /// are renormalised over only the signals that are present, so a temp-only night still scores.
    public static func fusedIndex(tempZ: Double?, rhrZ: Double?, hrvZ: Double?) -> Double? {
        var weighted = 0.0
        var wSum = 0.0
        if let t = tempZ { weighted += wTemp * t; wSum += wTemp }
        if let r = rhrZ { weighted += wRHR * r; wSum += wRHR }
        if let h = hrvZ { weighted += wHRV * (-h); wSum += wHRV }
        guard wSum > 0 else { return nil }
        return weighted / wSum
    }

    // MARK: - Copy

    static func phaseNote(_ phase: Phase) -> String {
        switch phase {
        case .unknown:
            return "No clear pattern yet."
        case .learning:
            return "Learning your pattern - keep wearing it overnight."
        default:
            return phaseNoteKind(phase).english
        }
    }

    private static func phaseNoteKind(_ phase: Phase) -> NoteKind {
        switch phase {
        case .follicular: return .phaseFollicular
        case .periOvulatory: return .phaseMidCycle
        case .luteal: return .phaseLuteal
        case .unknown: return .noClearPattern
        case .learning: return .learningNightly
        }
    }

    private static func noteText(_ kinds: [NoteKind]) -> String {
        kinds.map(\.english).joined(separator: " ")
    }

    // MARK: - Logged-start estimate

    private struct LoggedEstimate {
        let cycleDayLow: Int?
        let cycleDayHigh: Int?
        let cycleLengthDays: Int?
        let nextPeriodWindow: NextPeriodWindow?
        let noteKind: NoteKind
        let forecastSuppressed: Bool

        var note: String { noteKind.english }
    }

    /// A deliberately bounded estimate from explicit period-start logs. One start uses a broad 28-day
    /// population prior only for the window; two or more starts use the median plausible personal gap.
    /// Neither path produces a phase, a fixed date, or a fertility claim.
    private static func estimateFromLoggedStarts(_ loggedPeriodStarts: [String],
                                                 asOfDay: String) -> LoggedEstimate? {
        guard parseDay(asOfDay) != nil else { return nil }
        let starts = Array(Set(loggedPeriodStarts.filter {
            $0 <= asOfDay && parseDay($0) != nil
        })).sorted()
        guard let latestStart = starts.last,
              let daysSinceStart = daysBetween(latestStart, asOfDay),
              daysSinceStart >= 0 else { return nil }

        var observedGaps: [Int] = []
        if starts.count >= 2 {
            for index in 1..<starts.count {
                guard let gap = daysBetween(starts[index - 1], starts[index]) else { continue }
                observedGaps.append(gap)
            }
        }
        // Judge the last six observed intervals before filtering. Silently dropping a recent short or
        // long interval can turn an irregular history into a falsely narrow forecast based on older,
        // in-range gaps. An out-of-range interval may represent irregularity or a missed/corrected log;
        // either way, it is uncertainty and suppresses the forecast until the recent history is coherent.
        let recentObservedGaps = Array(observedGaps.suffix(6))
        let recentPlausibleGaps = recentObservedGaps.filter {
            (minCycleDays...maxCycleDays).contains($0)
        }
        let hasOutOfRangeRecentGap = recentPlausibleGaps.count != recentObservedGaps.count
        let cadence = recentPlausibleGaps.isEmpty
            ? nil
            : Int(median(recentPlausibleGaps.map(Double.init)).rounded())
        let intervalRange = recentPlausibleGaps.isEmpty
            ? 0
            : (recentPlausibleGaps.max()! - recentPlausibleGaps.min()!)
        let forecastUnreliable = hasOutOfRangeRecentGap
            || (recentPlausibleGaps.count >= 3
                && intervalRange > maxForecastableIntervalRange)
        let personalLength = forecastUnreliable ? nil : cadence

        // A stale start must not be silently rolled forward through guessed cycles. Ask for the current
        // anchor instead of making an old log look current.
        guard daysSinceStart < maxCycleDays else {
            return LoggedEstimate(
                cycleDayLow: nil,
                cycleDayHigh: nil,
                cycleLengthDays: personalLength,
                nextPeriodWindow: nil,
                noteKind: .staleLog,
                forecastSuppressed: true
            )
        }

        let cycleDay = daysSinceStart + 1
        let cycleDayLow = max(1, cycleDay - 1)
        let cycleDayHigh = cycleDay + 1
        if forecastUnreliable {
            return LoggedEstimate(
                cycleDayLow: cycleDayLow,
                cycleDayHigh: cycleDayHigh,
                cycleLengthDays: nil,
                nextPeriodWindow: nil,
                noteKind: .unreliableLogs,
                forecastSuppressed: true
            )
        }

        let forecastCadence = personalLength ?? defaultCycleDays
        let uncertainty: Int = {
            guard !recentPlausibleGaps.isEmpty, let personalLength else { return 5 }
            if recentPlausibleGaps.count == 1 { return 4 }
            let deviations = recentPlausibleGaps.map { abs($0 - personalLength) }
            let mad = median(deviations.map(Double.init))
            let observed = deviations.max() ?? 0
            let spread = max(Double(observed), 1.5 * mad)
            return min(maxPersonalWindowHalfWidth,
                       max(minPersonalWindowHalfWidth, Int(ceil(spread))))
        }()

        var window: NextPeriodWindow?
        let latestForecastDay = shiftDay(latestStart, by: forecastCadence + uncertainty)
        if let earliest = shiftDay(latestStart, by: forecastCadence - uncertainty),
           let latest = latestForecastDay,
           latest >= asOfDay {
            window = NextPeriodWindow(earliestDay: max(asOfDay, earliest), latestDay: latest)
        }

        let noteKind: NoteKind
        let forecastPassed = latestForecastDay.map { $0 < asOfDay } ?? true
        if forecastPassed {
            noteKind = .forecastPassed
        } else if personalLength == nil {
            noteKind = .broadPrior
        } else {
            noteKind = .personalIntervals
        }
        return LoggedEstimate(
            cycleDayLow: cycleDayLow,
            cycleDayHigh: cycleDayHigh,
            cycleLengthDays: personalLength,
            nextPeriodWindow: window,
            noteKind: noteKind,
            forecastSuppressed: forecastPassed
        )
    }

    // MARK: - Small stats / day helpers (self-contained so the engine stays I/O-free and parity-clean)

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// Median absolute deviation about `center` — a robust spread estimate.
    static func medianAbsoluteDeviation(_ xs: [Double], center: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        return median(xs.map { abs($0 - center) })
    }

    /// Calendar days from `a` to `b` ("yyyy-MM-dd"), b − a. nil if either is unparseable. UTC, pure.
    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = parseDay(a), let db = parseDay(b) else { return nil }
        let secs = db.timeIntervalSince(da)
        return Int((secs / 86_400).rounded())
    }

    /// Most recent entry in `days` that is on or before `day` (string compare is valid for ISO dates).
    static func mostRecentOnOrBefore(_ days: [String], day: String) -> String? {
        days.filter { $0 <= day }.max()
    }

    static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= 31 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: comps) else { return nil }
        let roundTrip = cal.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == y, roundTrip.month == m, roundTrip.day == d else { return nil }
        return date
    }

    /// Shift a "yyyy-MM-dd" by `delta` days. UTC, deterministic. nil if unparseable.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        guard let base = parseDay(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}
