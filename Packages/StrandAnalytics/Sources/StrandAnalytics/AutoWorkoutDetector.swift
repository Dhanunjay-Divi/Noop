import Foundation
import WhoopProtocol

// AutoWorkoutDetector.swift — opt-in MVP "did you just work out?" detector.
//
// Faithful Swift twin of android/.../com/noop/analytics/AutoWorkoutDetector.kt — the two MUST
// stay BYTE-PARITY on the detection logic (same thresholds, same span/merge/overlap rules, same
// outputs), verified by the mirrored unit tests on each platform.
//
// This is DELIBERATELY SEPARATE from `WorkoutDetector` (the internal scoring detector). This one is
// the canonical PURE detector. This component never performs I/O; the app-level Off / Ask / Auto-save
// policy decides whether a candidate is ignored, shown for approval, or persisted as a Detected row.
//
// The thresholds here are intentionally CONSERVATIVE (low sensitivity): a sustained ≥ 10-min
// elevation of HR ≥ resting + 30 bpm, brief (≤ 90 s) dips tolerated, near windows merged. A window
// is offered only after the stream contains > 90 s of post-session quiet; an elevated span at the
// end of the available data is still in progress and is never suggested. Tuned
// to avoid false positives from stress / caffeine / a brief flight of stairs, at the cost of
// missing the odd short or gentle session — exactly right for a SUGGESTION you can decline. An
// OPTIONAL continuous motion signal, when one is readily available, is required as confirmation;
// with no motion series it runs HR-only.
//
// Pure / headless: no I/O, no clock. All ts/start/end are unix SECONDS. NOT medical advice.

/// A candidate workout window the user can accept (Save) or reject (dismiss). All fields are
/// derived purely from the HR samples inside the window. Mirrors the Kotlin `DetectedWorkout`.
public struct DetectedWorkout: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    /// Whole minutes, floor of (endSec - startSec) / 60 — what the prompt shows.
    public let durationMin: Int
    /// Optional, explicitly advisory broad-type hint added by the repository after the window detector
    /// reads the stored activity-class/motion streams. The detector itself always emits nil here.
    public let suggestedClass: CoarseWorkoutClass?
    public let suggestionConfidence: Double?

    public init(startSec: Int, endSec: Int, avgBpm: Int, peakBpm: Int, durationMin: Int,
                suggestedClass: CoarseWorkoutClass? = nil, suggestionConfidence: Double? = nil) {
        self.startSec = startSec
        self.endSec = endSec
        self.avgBpm = avgBpm
        self.peakBpm = peakBpm
        self.durationMin = durationMin
        self.suggestedClass = suggestedClass
        self.suggestionConfidence = suggestionConfidence
    }
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude windows that overlap a
/// session the user has already logged (so we never re-suggest one). Mirrors the Kotlin
/// `Pair<Long, Long>` saved-workout argument.
public struct SavedWorkoutSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public init(startSec: Int, endSec: Int) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public enum AutoWorkoutDetector {

    // MARK: - Constants (keep byte-identical with the Kotlin twin)

    /// Elevated gate: bpm must be at least restingHR + this margin to count as "working".
    public static let elevatedMarginBPM = 30
    /// WHOOP's Jan 2026 baseline: a candidate must hold the elevated gate for at least 10 minutes.
    public static let minSustainedMin: Double = 10.0
    /// A dip below the gate no longer than this does NOT break the span (a red light, a sip of water).
    public static let maxDipS = 90
    /// WHOOP's June 2026 fragment rule: nearby detected fragments within an hour form one activity.
    public static let mergeGapS = 60 * 60
    /// When an OPTIONAL continuous motion series is supplied, a window must ALSO show elevated motion
    /// to qualify (confirmation). "Elevated motion" = the window's mean per-second motion intensity
    /// (L2 gravity-delta) is at least this. Ignored entirely in HR-only mode. Matches the Kotlin twin.
    public static let motionConfirmMean = 0.05
    /// Do not treat a handful of historical motion packets as proof that a whole candidate was still.
    /// Below this coverage the detector honestly falls back to HR-only instead of creating a false
    /// negative from missing sensor data.
    public static let motionConfirmationMinSamples = 30
    public static let motionConfirmationMinSpanS = 60
    /// A candidate needs enough actual HR observations to justify its wall-clock span. This prevents a
    /// handful of samples separated by radio/off-wrist gaps from looking like a sustained workout.
    public static let maxHRSampleGapS = 60
    public static let minHRSamples = 60
    public static let maxSecondsPerHRSample = 15
    /// Resting-HR fallback when the caller has no nightly RHR for the day.
    public static let defaultRestingHR = 60

    /// Use a valid personal RHR when present. Otherwise use the lower decile of the observed window,
    /// bounded to 60–100 bpm; this is more conservative than assuming every new user rests at 60.
    public static func effectiveRestingBPM(_ restingBpm: Int?, hr: [(ts: Int, bpm: Int)]) -> Int {
        if let restingBpm, (30...120).contains(restingBpm) { return restingBpm }
        let values = hr.map { $0.bpm }.filter { (30...220).contains($0) }.sorted()
        guard !values.isEmpty else { return defaultRestingHR }
        let index = Int((Double(values.count - 1) * 0.10).rounded(.down))
        return min(100, max(defaultRestingHR, values[index]))
    }

    public static func hasSufficientHRCoverage(_ window: [(ts: Int, bpm: Int)],
                                               start: Int, end: Int) -> Bool {
        guard end > start else { return false }
        let ordered = window.sorted { $0.ts < $1.ts }
        let required = max(minHRSamples,
                           Int(ceil(Double(end - start) / Double(maxSecondsPerHRSample))))
        guard ordered.count >= required else { return false }
        for (a, b) in zip(ordered, ordered.dropFirst()) where b.ts - a.ts > maxHRSampleGapS {
            return false
        }
        return true
    }

    // MARK: - Inputs

    /// One motion-intensity reading aligned to the HR timeline (optional confirmation signal).
    /// `intensity` is on the same L2-gravity-delta scale as `WorkoutDetector.activitySeries`.
    /// (The Kotlin twin takes raw `GravitySample`s and derives this internally; the Swift call site
    /// — `Repository.autoDetectCandidate` — has the gravity already decoded, so it passes the points.)
    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) {
            self.ts = ts
            self.intensity = intensity
        }
    }

    public enum MotionConfirmation: Equatable, Sendable {
        case unavailable
        case confirmed(mean: Double)
        case rejected(mean: Double)
    }

    /// Decide whether motion is both sufficiently observed and high enough to corroborate a candidate.
    /// Coverage must include at least 30 points spanning the smaller of five minutes or one quarter of
    /// the workout. Sparse/missing motion is `.unavailable` and therefore cannot veto an HR candidate.
    public static func motionConfirmation(_ motion: [MotionPoint], start: Int, end: Int) -> MotionConfirmation {
        guard end > start else { return .unavailable }
        let inWindow = motion.filter { $0.ts >= start && $0.ts <= end }
        guard inWindow.count >= motionConfirmationMinSamples,
              let first = inWindow.first?.ts,
              let last = inWindow.last?.ts else { return .unavailable }
        let requiredSpan = min(5 * 60, max(motionConfirmationMinSpanS, (end - start) / 4))
        guard last - first >= requiredSpan else { return .unavailable }
        let mean = inWindow.reduce(0.0) { $0 + $1.intensity } / Double(inWindow.count)
        return mean >= motionConfirmMean ? .confirmed(mean: mean) : .rejected(mean: mean)
    }

    /// Per-second motion intensity = L2 magnitude of the gravity change vs the previous record.
    /// First row → 0. Empty input → []. Mirrors the Kotlin `motionIntensityByTs` (and
    /// `WorkoutDetector.activitySeries`) so a caller can build the optional `motion` argument.
    public static func motionPoints(_ gravity: [GravitySample]) -> [MotionPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var out: [MotionPoint] = []
        out.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0, prev == nil {
                intensity = 0.0
            } else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else {
                intensity = 0.0
            }
            out.append(MotionPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return out
    }

    // MARK: - Public API

    /// Detect candidate sustained-elevated-HR workout windows.
    ///
    /// Algorithm (kept byte-identical with the Kotlin twin):
    ///  1. Sort HR ascending. Floor = restingHR + `elevatedMarginBPM`. A sample is "elevated" when
    ///     bpm >= floor.
    ///  2. Grow a contiguous span across elevated samples. A run of NON-elevated samples is tolerated
    ///     (does not end the span) ONLY while the dip's wall-clock duration (from the first sub-threshold
    ///     sample) stays <= `maxDipS`; a longer dip closes the span. The span's [start, end] are the
    ///     first/last ELEVATED sample timestamps.
    ///  3. Keep a span only when it lasts >= `minSustainedMin` AND a later below-threshold quiet tail
    ///     exceeds `maxDipS`. An open span at end-of-input is still in progress and is not emitted.
    ///  4. Merge two kept spans when the gap between them is <= `mergeGapS`.
    ///  5. If a motion series is supplied, drop a window unless its mean motion intensity over the
    ///     window is >= `motionConfirmMean` (confirmation). With no motion series, HR-only — keep it.
    ///  6. Drop a window that OVERLAPS any saved span (touching endpoints count) — never re-suggest one.
    ///  7. Emit a `DetectedWorkout` per surviving window (avg/peak bpm + whole-minute duration).
    ///
    /// - Parameters:
    ///   - hr: the day's (or last day or two's) HR samples `[(ts, bpm)]`; any order; empty → [].
    ///   - restingBpm: the nightly resting HR for the day; nil → `defaultRestingHR` (60).
    ///   - motion: OPTIONAL continuous motion series for confirmation; nil/empty → HR-only.
    ///   - savedSpans: already-saved workout windows to exclude by overlap.
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [MotionPoint]? = nil,
                              savedSpans: [SavedWorkoutSpan] = []) -> [DetectedWorkout] {
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty { return [] }

        let floor = effectiveRestingBPM(restingBpm, hr: seg) + elevatedMarginBPM

        // --- 1 + 2 + 3: grow sustained spans tolerating brief dips ---
        // A span is [spanStart, spanEnd] over ELEVATED-sample timestamps. `dipStart` marks where the
        // current sub-threshold run began (nil = not in a dip); a dip longer than maxDipS closes the span.
        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int? = nil
        var spanEnd = 0
        var dipStart: Int? = nil

        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minSustainedMin * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }

        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil   // the dip (if any) is bridged
            } else if spanStart != nil {
                // In a span: tolerate the dip until it runs longer than maxDipS. `dipStart` is the
                // first sub-threshold sample of the current dip (set once, cleared on the next elevated).
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        // Deliberately DO NOT close an open span at end-of-input. Until a below-threshold tail lasts
        // longer than maxDipS, the workout may still be in progress and its endpoint is not stable.
        // The next scan will close it once enough post-session HR has arrived.

        if spans.isEmpty { return [] }

        // --- 4: merge spans whose gap is <= mergeGapS (spans are start-ascending by build) ---
        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd <= mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        // --- 5 + 6 + 7 ---
        let motionSeries = (motion?.isEmpty ?? true) ? nil : motion
        var results: [DetectedWorkout] = []
        for (start, end) in merged {
            // 6: never re-suggest a window overlapping an already-saved workout.
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) { continue }

            let window = seg.filter { $0.ts >= start && $0.ts <= end }
            if window.isEmpty { continue }
            if !hasSufficientHRCoverage(window, start: start, end: end) { continue }

            // 5: motion confirmation when a sufficiently-covered series was supplied. Sparse motion
            // cannot honestly say the wearer was still, so it falls back to HR-only.
            if let motionSeries = motionSeries {
                if case .rejected = motionConfirmation(motionSeries, start: start, end: end) { continue }
            }

            let bpms = window.map { $0.bpm }
            let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
            let peak = bpms.max() ?? avg
            let durMin = (end - start) / 60
            results.append(DetectedWorkout(startSec: start, endSec: end,
                                           avgBpm: avg, peakBpm: peak, durationMin: durMin))
        }
        return results
    }

    /// Two closed [aStart, aEnd] / [bStart, bEnd] intervals overlap (touching endpoints count).
    /// Mirrors the Kotlin `overlaps`.
    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }
}
