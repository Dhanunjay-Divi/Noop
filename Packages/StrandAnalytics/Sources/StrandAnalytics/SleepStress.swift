import Foundation
import WhoopProtocol

/// Evidence-gated overnight autonomic load on the same 0...3 scale as DaytimeStress.
///
/// Every published point needs both dense heart rate and a clean R-R-derived RMSSD value.
/// The whole result fails closed unless at least 60% of the sleep window is covered. This is
/// a NOOP estimate, not WHOOP's proprietary Sleep Stress score or a clinical measurement.
public enum SleepStress {
    public static let bucketSeconds = 300
    public static let minHRSamplesPerBucket = 60
    public static let minCoveredBuckets = 6
    public static let minCoverageFraction = 0.60
    public static let mediumBandFloor = 1.0
    public static let highBandFloor = 2.0

    /// A sleep-specific offset keeps an ordinary resting window in the low band. Excursions
    /// in HR and/or drops in RMSSD must rise materially above the night's calm reference.
    static let sleepBaselineOffset = 2.0

    public enum Band: String, Equatable, Sendable {
        case low
        case medium
        case high
    }

    public struct Point: Equatable, Sendable {
        public let startTs: Int
        public let level: Double
        public let meanHR: Double
        public let rmssd: Double

        public var band: Band {
            if level >= SleepStress.highBandFloor { return .high }
            if level >= SleepStress.mediumBandFloor { return .medium }
            return .low
        }

        public init(startTs: Int, level: Double, meanHR: Double, rmssd: Double) {
            self.startTs = startTs
            self.level = level
            self.meanHR = meanHR
            self.rmssd = rmssd
        }
    }

    public struct Result: Equatable, Sendable {
        public let points: [Point]
        public let eligibleBucketCount: Int
        public let coverageFraction: Double

        public func bucketCount(in band: Band) -> Int {
            points.lazy.filter { $0.band == band }.count
        }

        public func fraction(in band: Band) -> Double {
            guard !points.isEmpty else { return 0 }
            return Double(bucketCount(in: band)) / Double(points.count)
        }

        public func durationSeconds(in band: Band) -> Int {
            bucketCount(in: band) * SleepStress.bucketSeconds
        }

        public init(points: [Point], eligibleBucketCount: Int, coverageFraction: Double) {
            self.points = points
            self.eligibleBucketCount = eligibleBucketCount
            self.coverageFraction = coverageFraction
        }
    }

    /// Returns nil unless the night has enough jointly-covered HR and clean R-R windows.
    public static func analyze(
        hr: [HRSample],
        rr: [RRInterval],
        startTs: Int,
        endTs: Int
    ) -> Result? {
        guard endTs > startTs else { return nil }
        let eligibleCount = (endTs - startTs) / bucketSeconds
        guard eligibleCount >= minCoveredBuckets else { return nil }

        var hrByBucket = Array(repeating: [Double](), count: eligibleCount)
        var rrByBucket = Array(repeating: [Double](), count: eligibleCount)

        for sample in hr where sample.ts >= startTs && sample.ts < endTs {
            let index = (sample.ts - startTs) / bucketSeconds
            if index >= 0 && index < eligibleCount {
                hrByBucket[index].append(Double(sample.bpm))
            }
        }
        for sample in rr where sample.ts >= startTs && sample.ts < endTs {
            let index = (sample.ts - startTs) / bucketSeconds
            if index >= 0 && index < eligibleCount {
                rrByBucket[index].append(Double(sample.rrMs))
            }
        }

        struct Aggregate {
            let index: Int
            let meanHR: Double
            let rmssd: Double
        }

        var aggregates: [Aggregate] = []
        aggregates.reserveCapacity(eligibleCount)
        for index in 0..<eligibleCount {
            let hrs = hrByBucket[index]
            guard hrs.count >= minHRSamplesPerBucket else { continue }
            let hrv = HRVAnalyzer.analyze(rawRR: rrByBucket[index])
            guard hrv.nClean >= HRVAnalyzer.minBeats,
                  let rmssd = hrv.rmssd, rmssd.isFinite else { continue }
            let meanHR = hrs.reduce(0, +) / Double(hrs.count)
            guard meanHR.isFinite else { continue }
            aggregates.append(Aggregate(index: index, meanHR: meanHR, rmssd: rmssd))
        }

        let coverage = Double(aggregates.count) / Double(eligibleCount)
        guard aggregates.count >= minCoveredBuckets,
              coverage >= minCoverageFraction else { return nil }

        let heartRates = aggregates.map(\.meanHR)
        let rmssdValues = aggregates.map(\.rmssd)
        let calmHR = quantile(heartRates.sorted(), q: 0.25)
        let calmRMSSD = quantile(rmssdValues.sorted(), q: 0.75)
        let sdHR = standardDeviation(heartRates)
        let sdRMSSD = standardDeviation(rmssdValues)

        let points = aggregates.map { aggregate in
            var raw = 0.0
            if sdHR > 0.0001 {
                raw += (aggregate.meanHR - calmHR) / sdHR
            }
            if sdRMSSD > 0.0001 {
                raw += (calmRMSSD - aggregate.rmssd) / sdRMSSD
            }
            let level = 3.0 / (1.0 + exp(-(raw - sleepBaselineOffset)))
            return Point(
                startTs: startTs + aggregate.index * bucketSeconds,
                level: min(max(level, 0), 3),
                meanHR: aggregate.meanHR,
                rmssd: aggregate.rmssd)
        }

        return Result(
            points: points,
            eligibleBucketCount: eligibleCount,
            coverageFraction: coverage)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count)
        return variance.squareRoot()
    }

    private static func quantile(_ sorted: [Double], q: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
