import Foundation
import WhoopProtocol

// AutoWorkoutDetector+Trace.swift - the Workouts & GPS test-mode auto-detect trace + line formatters.
//
// detectTrace(...) is the side-effect-free twin of AutoWorkoutDetector.detect(...): it returns the SAME
// [DetectedWorkout] detect would (it reuses detect verbatim), plus a trace that names the detector's inputs
// (HR sample count, resting floor), the thresholds it applied (elevated margin, sustained minutes, dip /
// merge / motion-confirm constants), and WHY each candidate window was offered or dropped (too short,
// motion-not-confirmed, overlaps a saved session). So a "my workout went missing / auto-detect didn't fire"
// report shows exactly which gate kept or dropped each window.
//
// WorkoutsTrace adds the line formatters the app-target emitters use for the session lifecycle, the GPS-fix
// count and the cross-source dedup decisions (the app layer owns the live state, this owns the line shape so
// the two platforms read identically and a fixture pins them). Everything here is pure, no clock, no I/O, no
// PII (counts / bpm / seconds / sport keys only). The Workouts test mode gates each call behind
// TestCentre.active(.workouts) at the call site; when the mode is off it is never called, so there is zero
// cost. No em-dashes. The Kotlin twin is AutoWorkoutDetectorTrace / WorkoutsTrace.

extension AutoWorkoutDetector {

    /// Side-effect-free diagnostic twin of `detect(...)`: returns the SAME `[DetectedWorkout]` detect would,
    /// plus the trace. The returned windows ARE `detect(...)`'s verbatim, so the trace can never disagree
    /// with what the Today card actually suggests. The trace logs the inputs + the thresholds, then walks the
    /// detector's own gates (sustained-minutes, motion-confirm, saved-overlap) to name why each merged window
    /// survived or dropped, mirroring the algorithm exactly. The Kotlin twin is
    /// `AutoWorkoutDetectorTrace.detectTrace`.
    ///
    /// - Parameters mirror `detect(...)` exactly. `path` tags the call ("autoDetect" / "manualReview") so a
    ///   report shows which entry point produced it.
    public static func detectTrace(hr: [(ts: Int, bpm: Int)],
                                   restingBpm: Int?,
                                   motion: [MotionPoint]? = nil,
                                   savedSpans: [SavedWorkoutSpan] = [],
                                   path: String = "autoDetect")
        -> (results: [DetectedWorkout], trace: [String]) {

        // The result the Today card reads, verbatim, so the trace cannot diverge from it.
        let results = detect(hr: hr, restingBpm: restingBpm, motion: motion, savedSpans: savedSpans)

        var lines: [String] = []
        let seg = cleanHR(hr)
        let effectiveResting = effectiveRestingBPM(restingBpm, hr: seg)
        let floor = effectiveResting + elevatedMarginBPM
        let hasMotion = !(motion?.isEmpty ?? true)
        let restingLabel = restingBpm.map(String.init) ?? "observedLowerDecile(\(effectiveResting))"

        // Inputs the detector saw.
        lines.append("autoDetect path=\(path) hrSamples=\(hr.count) validUniqueHr=\(seg.count) "
            + "restingBpm=\(restingLabel) "
            + "elevatedFloor=\(floor)bpm motion=\(hasMotion ? "supplied" : "hrOnly") savedSpans=\(savedSpans.count) "
            + "detectorVersion=\(detectorVersion) eventConfidence=uncalibrated")

        // Thresholds applied (the autoDetectThresholds capture). Stated once so a report carries the
        // calibration the windows were judged against.
        lines.append("autoDetect thresholds elevatedMargin=\(elevatedMarginBPM)bpm "
            + "minSustainedMin=\(minSustainedMin) maxDipS=\(maxDipS) finalizationQuietS=>\(maxDipS) "
            + "mergeGapS=\(mergeGapS) "
            + "motionConfirmMean=\(motionConfirmMean) maxMotionGapS=\(motionConfirmationMaxGapS) "
            + "maxHrGapS=\(maxHRSampleGapS) "
            + "maxSecondsPerHrSample=\(maxSecondsPerHRSample)")

        // Rebuild the SAME merged windows the detector forms (sustained spans tolerating dips, then merge),
        // so we can name why each survived or dropped WITHOUT changing the returned `results`. This mirrors
        // detect(...)'s steps 1-4 exactly; the per-window verdict below mirrors steps 5-6.
        if seg.isEmpty {
            lines.append("autoDetect result windows=0 (no HR samples)")
            return (results, lines)
        }

        let spans = finalizedElevatedSpans(seg, floor: floor)
        // Match detect(...): an open EOF span is still in progress, not a finalized candidate.

        if spans.isEmpty {
            let reason = seg.contains(where: { $0.bpm >= floor })
                ? "awaitingQuietTailOrContinuousCoverage" : "noSustainedSpan"
            lines.append("autoDetect why=\(reason) "
                + "(requires >=\(minSustainedMin)min above \(floor)bpm then >\(maxDipS)s below it)")
            lines.append("autoDetect result windows=0")
            return (results, lines)
        }

        // Merge spans whose gap is <= mergeGapS (same as detect step 4).
        let merged = mergeSpans(spans)

        // Per-window verdict (the autoDetectWhy capture), mirroring detect steps 5-6.
        let motionSeries = hasMotion ? motion : nil
        for (start, end) in merged {
            let durMin = Int((Double(end) - Double(start)) / 60.0)
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) {
                lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=overlapsSavedWorkout")
                continue
            }
            let window = seg.filter { $0.ts >= start && $0.ts <= end }
            if !hasSufficientHRCoverage(window, start: start, end: end) {
                lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=insufficientHrCoverage")
                continue
            }
            if let motionSeries {
                switch motionConfirmation(motionSeries, start: start, end: end) {
                case .rejected(let meanMotion):
                    lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=motionNotConfirmed "
                        + "(mean=\((meanMotion * 1000).rounded() / 1000) < \(motionConfirmMean))")
                    continue
                case .unavailable:
                    lines.append("autoDetect window durMin=\(durMin) motion=unavailable (sparse; HR-only fallback)")
                case .confirmed:
                    break
                }
            }
            let provenance: String
            if let motionSeries,
               case .confirmed = motionConfirmation(motionSeries, start: start, end: end) {
                provenance = AutoWorkoutEvidenceProvenance.heartRateAndMotion.rawValue
            } else {
                provenance = AutoWorkoutEvidenceProvenance.heartRateOnly.rawValue
            }
            lines.append("autoDetect window durMin=\(durMin) verdict=offered provenance=\(provenance)")
        }
        lines.append("autoDetect result windows=\(results.count) "
            + "(offered the most recent that is not saved or dismissed)")
        return (results, lines)
    }
}

/// Pure line formatters + the live-readout parser for the Workouts & GPS test mode. The app-target emitters
/// (AppModel session lifecycle, GpsWorkoutRecorder fixes, Repository cross-source dedup) own the live state;
/// these own the line SHAPE so both platforms read identically and a fixture pins them. WorkoutsReadout
/// parses the `.workouts`-tagged log tail back into the `lastSessionSummary` id the panel binds. No state,
/// no side effects, no PII (counts / seconds / sport keys only). No em-dashes. The Kotlin twin is WorkoutsTrace.
public enum WorkoutsTrace {

    /// A session-lifecycle line. `event` is "start" / "end" / "discarded"; the counts are the captured HR
    /// window size and (for an end) the duration + whether a GPS route landed, so the lifecycle of a missing
    /// workout is visible end to end. Sport is the normalised key, never free text.
    public static func sessionLine(event: String,
                                   sportKey: String,
                                   hrSamples: Int,
                                   durationSec: Int? = nil,
                                   gpsPoints: Int? = nil) -> String {
        var line = "session event=\(event) sport=\(sportKey) hrSamples=\(hrSamples)"
        if let durationSec { line += " durationSec=\(durationSec)" }
        if let gpsPoints { line += " gpsPoints=\(gpsPoints)" }
        return line
    }

    /// A GPS-fix-progress line: the raw fixes seen, how many the accuracy / speed filter accepted, and the
    /// running distance. So a route that under-records (a weak signal, a denied permission) is visible.
    ///
    /// `rawFixes` is OPTIONAL: macOS sees the pre-filter raw stream and passes a real count, so the line can
    /// show a true accept rate. Android's LocationTracker pre-filters upstream, so the raw count is NOT
    /// available at the GpsSession seam (every fix here is already accepted); it passes nil and the line
    /// renders `rawFixes=n/a` rather than implying an accept rate the platform cannot actually measure.
    public static func gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double) -> String {
        "gps rawFixes=\(rawFixes.map(String.init) ?? "n/a") accepted=\(acceptedPoints) "
            + "distanceM=\(Int(distanceM.rounded())) (filter: accuracy+speed gate)"
    }

    /// An engine detected-bout decision line: the IntelligenceEngine derives a workout bout from the raw HR
    /// stream, then either PERSISTS it (source "-noop", sport "detected") or DROPS it because it overlaps a
    /// real session the user already logged (manual / imported), so the same bout is never counted twice.
    /// This is the "auto workout appeared then vanished" seam (#975): a bout can persist on one pass then be
    /// dropped on the next once the manual row lands, and without this line the export shows NO workouts
    /// trace for the auto path at all. `verdict` is "persisted" / "droppedOverlap"; `durMin` is the whole-
    /// minute bout length; on a drop, `overlapSource` names the real row it collided with. No PII (a source
    /// label + minutes + bpm only). Mirrors the Kotlin `WorkoutsTrace.detectedBoutLine`.
    public static func detectedBoutLine(verdict: String,
                                        durMin: Int,
                                        avgBpm: Int,
                                        overlapSource: String? = nil) -> String {
        var line = "detectedBout verdict=\(verdict) durMin=\(durMin) avgBpm=\(avgBpm)"
        if let overlapSource { line += " overlapSource=\(overlapSource)" }
        return line
    }

    /// A cross-source dedup decision line: two same-activity rows from different sources were collapsed to
    /// the richer one. Reports the sources, the kept richness, and the overlap, so a "my workout shows twice"
    /// or "the richer one disappeared" report shows exactly which pair merged and which won.
    public static func dedupLine(sportKey: String,
                                 keptSource: String,
                                 droppedSource: String,
                                 keptRichness: Int,
                                 droppedRichness: Int) -> String {
        "dedup sport=\(sportKey) kept=\(keptSource)(richness=\(keptRichness)) "
            + "dropped=\(droppedSource)(richness=\(droppedRichness)) (same activity, richer kept)"
    }
}

/// Pure values for the Workouts & GPS live-readout panel. Parses the `.workouts`-tagged log tail the
/// emitters write, so the panel reflects exactly the last session without the app layer exposing new
/// published properties. No state, no side effects, no em-dashes. The Kotlin twin is the WorkoutsReadout object.
public enum WorkoutsReadout {

    /// The last session summary for the `lastSessionSummary` id: the most recent session-lifecycle line's
    /// fragment (event + sport + counts), or nil when none is present. So the panel reads the same outcome
    /// the lifecycle emitter wrote.
    public static func lastSessionSummary(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "session ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }
}
