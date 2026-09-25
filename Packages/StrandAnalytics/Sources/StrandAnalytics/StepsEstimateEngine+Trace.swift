import Foundation
import WhoopProtocol

// StepsEstimateEngine+Trace.swift - the Steps test-mode diagnostic traces.
//
// Two pure, side-effect-free twins for the two ways NOOP produces a step number:
//
//  1. calibrationTrace(...) - the WHOOP-4 motion-volume path. Reports each calibration day's motion VOLUME
//     and phone reference count, then the fitted (or manual) calibration state (k / sampleDays / confidence
//     / manual) by reusing StepsEstimateEngine.calibrate VERBATIM, so the trace can never disagree with the
//     coefficient the Settings/Steps screen shows. When the fit is withheld it names the status (the
//     "Need N more days" reason), the same status the tile renders.
//
//  2. rawCounterTrace(...) - the WHOOP 5/MG raw path. Reuses StepsCounter.analyze so activity filtering,
//     wrap handling, the maxStepDelta boundary, and the retained raw total cannot diverge from production.
//     It reports only fixed categories and aggregate counts, never counter values or per-sample details.
//
// No clock, no I/O, no PII (counts and ratios only). A fixture pins the exact lines. The Steps test mode
// gates each call behind TestCentre.active(.steps) at the call site (IntelligenceEngine); when the mode is
// off neither is ever called, so there is zero cost. No em-dashes. The Kotlin twin is StepsEstimateEngineTrace.

extension StepsEstimateEngine {

    /// The WHOOP-4 motion-volume calibration trace. Given the per-day calibration points (each a motion
    /// volume + a phone reference step count) and the optional manual override, it logs:
    ///   - one `stepsCal point` line per usable day (the day's motion volume and phone reference count, plus
    ///     the implied steps/motion ratio that votes in the fit),
    ///   - the calibration outcome line, built by reusing `calibrate(...)` VERBATIM (so k / sampleDays /
    ///     confidence / manual are exactly what the Settings screen reads), or the `status(...)` line naming
    ///     why the fit was withheld (e.g. needsMoreDays have/need).
    ///
    /// Every number is the SAME expression the production fit uses, and the reported coefficient IS
    /// `calibrate(...)`'s, so the trace can never diverge from the headline. The Kotlin twin is
    /// `StepsEstimateEngineTrace.calibrationTrace`.
    public static func calibrationTrace(points: [CalibrationPoint],
                                        manualOverride: Double? = nil) -> [String] {
        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        var lines: [String] = []

        // Per-usable-day points: the SAME filter the fit applies (motion >= minMotionForFit && steps > 0),
        // so the trace shows exactly the days that voted. Phone reference count is the calibration anchor.
        let usable = points.filter { $0.motion >= minMotionForFit && $0.steps > 0 }
        for p in usable {
            let ratio = p.motion > 0 ? p.steps / p.motion : 0
            lines.append("stepsCal point motion=\(r2(p.motion)) phoneRef=\(Int(p.steps)) "
                + "ratio=\(r2(ratio)) (steps/motion votes weighted by motion)")
        }

        // The calibration outcome, read from calibrate(...) verbatim so it matches the stored coefficient.
        if let cal = calibrate(points, manualOverride: manualOverride), usable.count >= minCalibrationDays || cal.manual {
            lines.append("stepsCal fit k=\(r2(cal.coefficient)) sampleDays=\(cal.sampleDays) "
                + "confidence=\(r2(cal.confidence)) manual=\(cal.manual) "
                + "(k = motion-weighted median of steps/motion)")
        } else {
            // Withheld: name the status the tile shows (the "need N more days" reason), via status(...)
            // verbatim so the trace explains the blank tile with the SAME usable-day filter.
            let status = self.status(points, manualOverride: manualOverride)
            switch status {
            case let .needsMoreDays(have, need):
                lines.append("stepsCal withheld reason=needsMoreDays have=\(have) need=\(need) "
                    + "(no usable auto-fit and no manual k)")
            case let .manual(k, sampleDays):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=1.0 manual=true (user-set k)")
            case let .calibrated(k, sampleDays, confidence):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=\(r2(confidence)) manual=false (k = motion-weighted median of steps/motion)")
            }
        }
        return lines
    }

    /// The WHOOP 5/MG raw-counter trace for one day. It filters the same local-day window as production,
    /// then reuses `StepsCounter.analyze` for the wrap-aware and activity-class-aware result. Output is
    /// limited to bounded status/mode categories and aggregate counts; no day key, raw counter value,
    /// per-delta value, or user calibration value is emitted.
    ///
    /// - Parameters mirror the analyzeDay step block exactly: the day's step samples (any order), the local
    ///   day key, the tz offset, and the user's ticks-per-step. `daySteps` is the calendar-day stream the
    ///   production total prefers. The Kotlin twin is `StepsEstimateEngineTrace.rawCounterTrace`.
    public static func rawCounterTrace(daySteps: [StepSample],
                                       dayKey: String,
                                       tzOffsetSeconds: Int,
                                       ticksPerStep: Double,
                                       civilDayStartTs: Int? = nil,
                                       civilDayEndTsExclusive: Int? = nil) -> [String] {
        let civilBounds = AnalyticsEngine.validateCivilDayBounds(
            startTs: civilDayStartTs,
            endTsExclusive: civilDayEndTsExclusive
        )
        guard civilBounds != .invalid else {
            return []
        }
        let explicitCivilBounds: Range<Int>?
        if case .valid(let bounds) = civilBounds {
            explicitCivilBounds = bounds
        } else {
            explicitCivilBounds = nil
        }

        // The SAME filter + sort: keep only this LOCAL day's samples, time-ordered.
        let sorted = daySteps
            .filter {
                if let explicitCivilBounds {
                    return explicitCivilBounds.contains($0.ts)
                }
                return AnalyticsEngine.dayString(
                    $0.ts,
                    offsetSec: tzOffsetSeconds
                ) == dayKey
            }
            .sorted { $0.ts < $1.ts }

        let analysis = StepsCounter.analyze(sorted)
        let status: String
        if analysis.sampleCount == 0 {
            status = "noRawCounter"
        } else if analysis.sampleCount < 2 {
            status = "insufficientSamples"
        } else {
            status = "analyzed"
        }

        var lines = [
            "stepsRaw analysis status=\(status) mode=\(analysis.filterMode.rawValue) "
                + "counterSamples=\(analysis.sampleCount) deltaCount=\(analysis.deltaCount) "
                + "kept=\(analysis.keptDeltaCount) rejectedStill=\(analysis.rejectedStillDeltaCount) "
                + "rejectedUnknown=\(analysis.rejectedUnknownDeltaCount) "
                + "rejectedGap=\(analysis.rejectedGapDeltaCount) zero=\(analysis.zeroDeltaCount)"
        ]

        // #810: WHOOP 4.0 has no raw counter, while one sample means a counter exists but no delta can be
        // formed. Keep those states distinct through the fixed status category.
        if sorted.isEmpty {
            return lines
        }
        guard sorted.count >= 2 else {
            return lines
        }

        // The scaled total, the SAME expression analyzeDay produces for steps_est (ticks / ticksPerStep,
        // floored at 0.5 so a bad pref can at most double, never explode, the total).
        let scaled = analysis.rawTicks > 0
            ? Int((Double(analysis.rawTicks) / Swift.max(ticksPerStep, 0.5)).rounded())
            : 0
        // L7: production analyzeDay returns `scaled > 0 ? scaled : nil`, so a tiny rawTotal that rounds to 0
        // yields NO steps_est for the day. Render "none" (not 0) so the trace matches the nil headline rather
        // than implying a real zero-step measurement.
        let scaledText = scaled > 0 ? String(scaled) : "none"
        lines.append("stepsRaw total rawTicks=\(analysis.rawTicks) scaledSteps=\(scaledText)")
        return lines
    }
}
