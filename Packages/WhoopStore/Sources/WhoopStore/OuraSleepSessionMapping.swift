import Foundation
import OuraProtocol

/// Reshapes an anchored Oura SleepNet hypnogram into the stage-rich session shape consumed by NOOP's
/// sleep screens. This is ring-provided classification, not a NOOP-derived sleep score.
/// Adapted from Dhanunjay-Divi/Noop's clean-room Oura pipeline; see repository attribution and notice files.
public enum OuraSleepSessionMapping {
    /// Marker embedded in stage segments so a source-neutral cache row can still disclose that the ring,
    /// rather than NOOP's local stager, supplied the phases. Unknown JSON keys are ignored by old readers.
    public static let provenanceToken = "oura"
    public static let minimumObservedSeconds = 10 * 60
    public static let minimumAsleepSeconds = 5 * 60

    public static func hasOuraProvenance(_ session: CachedSleepSession) -> Bool {
        session.stagesJSON?.contains("\"source\":\"\(provenanceToken)\"") == true
    }

    static func token(_ stage: OuraSleepStage) -> String {
        switch stage {
        case .deep:  return "deep"
        case .light: return "light"
        case .rem:   return "rem"
        case .awake: return "wake"
        }
    }

    /// Adjacent equal 30-second codes merge into fixed-key-order JSON segments. Gaps remain gaps because
    /// only exactly adjacent codes merge; erased pages have already been removed after time-axis layout.
    public static func session(
        fromCodes codes: [(ts: Int, stage: OuraSleepStage)],
        secondsPerCode: Int = 30
    ) -> CachedSleepSession? {
        guard let first = codes.first, let last = codes.last else { return nil }

        struct Segment {
            var start: Int
            var end: Int
            let stage: OuraSleepStage
        }
        var segments: [Segment] = []
        for code in codes {
            let end = code.ts + secondsPerCode
            if var previous = segments.last,
               previous.stage == code.stage,
               previous.end == code.ts {
                previous.end = end
                segments[segments.count - 1] = previous
            } else {
                segments.append(Segment(start: code.ts, end: end, stage: code.stage))
            }
        }

        var asleepSeconds = 0
        var awakeSeconds = 0
        var hasCoverageGap = false
        var previousTimestamp: Int?
        for code in codes {
            if let previousTimestamp,
               code.ts != previousTimestamp + secondsPerCode {
                hasCoverageGap = true
            }
            if code.stage == .awake {
                awakeSeconds += secondsPerCode
            } else {
                asleepSeconds += secondsPerCode
            }
            previousTimestamp = code.ts
        }
        let inBedSeconds = asleepSeconds + awakeSeconds
        // A tiny/all-awake fragment is useful as raw phase evidence but is not a credible sleep session.
        // Do not let it become a rich imported row that can displace a complete locally staged night.
        guard inBedSeconds >= minimumObservedSeconds,
              asleepSeconds >= minimumAsleepSeconds else { return nil }

        let json = "[" + segments.map {
            "{\"start\":\($0.start),\"end\":\($0.end),\"stage\":\"\(token($0.stage))\"," +
                "\"source\":\"\(provenanceToken)\"}"
        }.joined(separator: ",") + "]"

        // Efficiency is asleep / time in bed only when every epoch in the window is known. Treating an
        // erased flash page as absent from the denominator would silently inflate the night's result.
        let efficiency = !hasCoverageGap && inBedSeconds > 0
            ? Double(asleepSeconds) / Double(inBedSeconds)
            : nil

        return CachedSleepSession(
            startTs: first.ts,
            endTs: last.ts + secondsPerCode,
            efficiency: efficiency,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: json
        )
    }
}
