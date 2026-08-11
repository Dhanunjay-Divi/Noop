import Foundation
import WhoopProtocol

/// Pure, source-agnostic enrichment for an imported workout's heart-rate trace.
///
/// HealthKit, Health Connect, FIT and future adapters can all supply a workout-scoped HR stream, but
/// the persisted `WorkoutRow` expects the same four derived values regardless of source. Keeping the
/// derivation here prevents the iOS bridge from growing its own zone or Effort formula and makes the
/// privacy-sensitive HealthKit query layer independently testable.
public struct WorkoutHeartRateMetrics: Equatable, Sendable {
    public let avgHR: Int?
    public let maxHR: Int?
    public let strain: Double?
    /// Stable JSON object with `z1`...`z5` percentages. Percentages use the workout duration as the
    /// denominator, so unmeasured time and time below Zone 1 are never silently redistributed.
    public let zonesJSON: String?

    public init(avgHR: Int?, maxHR: Int?, strain: Double?, zonesJSON: String?) {
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.strain = strain
        self.zonesJSON = zonesJSON
    }
}

public enum WorkoutHeartRateEnrichment {
    /// Matches the physiological gate used by NOOP's live/watch HR paths. Rejecting impossible values
    /// here prevents one malformed source sample from becoming a displayed peak or Zone 5 interval.
    public static let plausibleBPMRange = 30...220
    /// Broad physiological/configuration guard for a user-supplied or age-estimated HR max. Values
    /// outside this range are not safe denominators for zones or HR-reserve Effort.
    public static let plausibleMaxHRRange = 80.0...240.0

    /// Derive the metrics a `WorkoutRow` can safely carry from a workout-scoped HR stream.
    ///
    /// - Parameters:
    ///   - samples: HR samples associated with this workout. Values outside the workout or the
    ///     physiological gate are ignored.
    ///   - workoutStart/workoutEnd: Unix-second bounds of the imported workout.
    ///   - maxHR: The user's configured/age-estimated HR max, shared with the rest of NOOP.
    ///   - restingHR: A same-day resting HR when available; invalid values fall back to the scorer's
    ///     documented default rather than making HR reserve negative.
    ///   - sex: Passed to the shared Effort engine (relevant to its optional Banister method).
    ///   - statisticsAverage/statisticsMaximum: Source-native scoped statistics (for example,
    ///     `HKStatisticsQuery`). Valid source statistics win for Avg/Max; the samples are the fallback
    ///     and remain the only input to zones/Effort.
    public static func summarize(
        samples: [HRSample],
        workoutStart: Int,
        workoutEnd: Int,
        maxHR: Double,
        restingHR: Double? = nil,
        sex: String = "male",
        statisticsAverage: Double? = nil,
        statisticsMaximum: Double? = nil
    ) -> WorkoutHeartRateMetrics {
        guard workoutEnd > workoutStart else {
            return WorkoutHeartRateMetrics(
                avgHR: validStatistic(statisticsAverage),
                maxHR: validStatistic(statisticsMaximum),
                strain: nil,
                zonesJSON: nil
            )
        }

        let clean = samples
            .filter { sample in
                sample.ts >= workoutStart && sample.ts < workoutEnd
                    && plausibleBPMRange.contains(sample.bpm)
            }
            .sorted { lhs, rhs in
                lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts
            }

        // Collapse first, then duration-weight the sample fallback. An arithmetic mean over irregular
        // timestamps over-represents bursty providers; source-native Health statistics still win.
        let integrated = collapseSameSecond(clean)
        // One workout-bounded duration vector drives every time-weighted result below. General-purpose
        // zone/Effort integrators infer a tail interval because they do not know the caller's boundary;
        // doing that independently here used to credit the final sample beyond `workoutEnd`. Durations
        // retain the scorer's preceding-cadence tail and two-minute dropout ceiling, but every element is
        // clipped to the half-open workout interval [workoutStart, workoutEnd).
        let durationsSeconds = boundedDurationsSeconds(
            integrated, workoutStart: workoutStart, workoutEnd: workoutEnd)
        let durationsMinutes = durationsSeconds.map { $0 / 60.0 }
        let durationTotalMinutes = durationsMinutes.reduce(0, +)
        let sampledAverage: Int? = durationTotalMinutes > 0 ? Int(
            (zip(integrated, durationsMinutes).reduce(0.0) { partial, pair in
                partial + Double(pair.0.bpm) * pair.1
            } / durationTotalMinutes).rounded()
        ) : nil
        let sampledMaximum = integrated.map(\.bpm).max()
        let average = validStatistic(statisticsAverage) ?? sampledAverage
        let maximumCandidate = validStatistic(statisticsMaximum) ?? sampledMaximum
        // A maximum below the average is mathematically impossible and signals partial/corrupt source
        // statistics. Keep the independently useful average, but do not manufacture a peak to match it.
        let maximum: Int? = if let average, let maximumCandidate, maximumCandidate < average {
            nil
        } else {
            maximumCandidate
        }

        guard maxHR.isFinite, plausibleMaxHRRange.contains(maxHR),
              hasRepresentativeCoverage(integrated, durationsSeconds: durationsSeconds,
                                        start: workoutStart, end: workoutEnd) else {
            return WorkoutHeartRateMetrics(avgHR: average, maxHR: maximum,
                                           strain: nil, zonesJSON: nil)
        }

        let zoneSet = HRZones.zones(maxHR: maxHR)
        let timeInZone = HRZones.timeInZone(
            integrated, durationsSeconds: durationsSeconds, zoneSet: zoneSet)
        // Convert endpoints before subtraction: `workoutEnd - workoutStart` can overflow for adversarial
        // Int endpoints even though their Double difference is finite.
        let denominator = Double(workoutEnd) - Double(workoutStart)
        let zonePercentages = denominator > 0
            ? timeInZone.seconds.map { min(max($0 / denominator * 100, 0), 100) }
            : []
        let zonesJSON = stableZoneJSON(zonePercentages)

        let usableRestingHR: Double = {
            guard let restingHR, restingHR.isFinite,
                  restingHR >= Double(plausibleBPMRange.lowerBound) - 0.5,
                  restingHR <= Double(plausibleBPMRange.upperBound) + 0.499_999,
                  restingHR < maxHR else { return StrainScorer.defaultRestingHR }
            return restingHR
        }()
        let strain = StrainScorer.strain(
            integrated, durationsMinutes: durationsMinutes, maxHR: maxHR,
            restingHR: usableRestingHR, sex: sex)
        return WorkoutHeartRateMetrics(avgHR: average, maxHR: maximum,
                                       strain: strain, zonesJSON: zonesJSON)
    }

    private static func validStatistic(_ value: Double?) -> Int? {
        guard let value, value.isFinite,
              value >= Double(plausibleBPMRange.lowerBound) - 0.5,
              value <= Double(plausibleBPMRange.upperBound) + 0.499_999 else { return nil }
        let rounded = Int(value.rounded())
        return plausibleBPMRange.contains(rounded) ? rounded : nil
    }

    private static func collapseSameSecond(_ samples: [HRSample]) -> [HRSample] {
        guard !samples.isEmpty else { return [] }
        var result: [HRSample] = []
        var timestamp = samples[0].ts
        var sum = 0
        var count = 0

        func appendCurrent() {
            guard count > 0 else { return }
            result.append(HRSample(ts: timestamp,
                                   bpm: Int((Double(sum) / Double(count)).rounded())))
        }

        for sample in samples {
            if sample.ts != timestamp {
                appendCurrent()
                timestamp = sample.ts
                sum = 0
                count = 0
            }
            sum += sample.bpm
            count += 1
        }
        appendCurrent()
        return result
    }

    /// Per-sample hold durations clipped to this workout's half-open interval. Interior samples hold
    /// until their successor (capped at the shared dropout ceiling); the final sample reuses the prior
    /// real cadence, then clips that inferred tail at `workoutEnd`. A single reading retains the shared
    /// one-second fallback. All timestamp arithmetic converts to Double before subtraction so extreme
    /// Int endpoints cannot trap.
    private static func boundedDurationsSeconds(
        _ samples: [HRSample], workoutStart: Int, workoutEnd: Int
    ) -> [Double] {
        guard !samples.isEmpty, workoutEnd > workoutStart else { return [] }
        let maximumHoldSeconds = StrainScorer.maxSampleGapMin * 60.0
        var inferred: [Double] = []
        inferred.reserveCapacity(samples.count)

        if samples.count == 1 {
            inferred.append(StrainScorer.fallbackSampleMin * 60.0)
        } else {
            for index in 0..<(samples.count - 1) {
                let gap = Double(samples[index + 1].ts) - Double(samples[index].ts)
                let seconds = gap > 0 && gap.isFinite
                    ? min(gap, maximumHoldSeconds)
                    : StrainScorer.fallbackSampleMin * 60.0
                inferred.append(seconds)
            }
            inferred.append(inferred[inferred.count - 1])
        }

        let lowerBound = Double(workoutStart)
        let upperBound = Double(workoutEnd)
        return zip(samples, inferred).map { pair in
            let (sample, inferredSeconds) = pair
            let sampleStart = max(Double(sample.ts), lowerBound)
            let remaining = upperBound - sampleStart
            guard remaining.isFinite, remaining > 0 else { return 0 }
            return min(inferredSeconds, remaining)
        }
    }

    /// A couple of isolated readings can support a source-native Avg/Max statistic, but they cannot
    /// honestly describe the workout's zone distribution. Require both time span and integrated
    /// coverage: half of short workouts, capped at five minutes for long workouts, with a ten-second
    /// floor. The shared Effort engine applies its own stricter 10-minute/20-sample gate afterwards.
    private static func hasRepresentativeCoverage(
        _ samples: [HRSample], durationsSeconds: [Double], start: Int, end: Int
    ) -> Bool {
        // At least the shared sparse-stream floor is required. Two far-apart samples can span several
        // minutes yet cannot truthfully describe everything between them, even if a hold-last-value
        // integrator can produce a number.
        guard samples.count >= StrainScorer.minSparseReadings,
              let first = samples.first, let last = samples.last else { return false }
        guard durationsSeconds.count == samples.count else { return false }
        let duration = Double(end) - Double(start)
        let required = min(300, max(10, duration * 0.5))
        let span = Double(last.ts) - Double(first.ts)
        guard span >= required else { return false }
        let connectedCoverage = (0..<(samples.count - 1)).reduce(0.0) { total, index in
            let gap = Double(samples[index + 1].ts) - Double(samples[index].ts)
            guard gap > 0, gap <= StrainScorer.maxSampleGapMin * 60 else { return total }
            return total + durationsSeconds[index]
        }
        guard connectedCoverage >= required else { return false }
        return durationsSeconds.reduce(0, +) >= required
    }

    private static func stableZoneJSON(_ percentages: [Double]) -> String? {
        guard percentages.count == 5, percentages.contains(where: { $0 > 0 }) else { return nil }
        var object: [String: Double] = [:]
        for (offset, value) in percentages.enumerated() {
            object["z\(offset + 1)"] = (value * 100).rounded() / 100
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
