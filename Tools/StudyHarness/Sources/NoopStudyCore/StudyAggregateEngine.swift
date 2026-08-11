import Foundation
import StrandAnalytics

struct SubjectMetricComparison {
    let subjectID: String
    let metric: WhoopComparableMetric
    let sourceMode: StudySourceMode
    let revision: String
    let eligibleOfficialDays: Int
    let official: [Double]
    let noop: [Double]

    var pairCount: Int { official.count }
    var errors: [Double] { zip(noop, official).map(-) }
    var absoluteErrors: [Double] { errors.map(abs) }
    var bias: Double { mean(errors) }
    var mae: Double { mean(absoluteErrors) }
    var rmse: Double { rootMeanSquare(errors) }
    var medianAbsoluteError: Double { percentile(absoluteErrors, 0.5) }
    var correlation: Double? { pearson(noop, official) }
}

enum StudySubjectComparator {
    static func compare(
        subjectID: String,
        reference: StudySubjectReference,
        prediction: StudyPredictionSet
    ) -> [SubjectMetricComparison] {
        var comparisons: [SubjectMetricComparison] = []
        for metric in WhoopComparableMetric.allCases {
            guard let official = reference.valuesByMetric[metric],
                  let local = prediction.valuesByMetric[metric],
                  let revision = prediction.revisionByMetric[metric]
            else { continue }

            let observations =
                official.map {
                    ReferenceMetricObservation.whoopExport(
                        day: $0.key,
                        metric: metric,
                        value: $0.value,
                        schemaRevision: "strand-import-study-v1"
                    )
                }
                + local.map {
                    ReferenceMetricObservation.noopComputed(
                        day: $0.key,
                        metric: metric,
                        value: $0.value,
                        algorithmVersion: revision
                    )
                }
            let report = WhoopReferenceCalibration.report(
                metric: metric,
                observations: observations,
                noopAlgorithmVersion: revision
            )
            let officialPairs = report.pairs.map(\.official.value)
            let noopPairs = report.pairs.map(\.noop.value)
            comparisons.append(SubjectMetricComparison(
                subjectID: subjectID,
                metric: metric,
                sourceMode: prediction.sourceMode,
                revision: revision,
                eligibleOfficialDays: official.count,
                official: officialPairs,
                noop: noopPairs
            ))
        }
        return comparisons
    }
}

public enum StudyAggregateEngine {
    static func aggregate(
        _ comparisons: [SubjectMetricComparison],
        includeCalibrationFit: Bool = true
    ) -> [AggregateMetricReport] {
        let grouped = Dictionary(grouping: comparisons) {
            MetricMode(metric: $0.metric, mode: $0.sourceMode)
        }
        return grouped.keys.sorted().compactMap { key in
            aggregate(
                grouped[key] ?? [],
                metric: key.metric,
                mode: key.mode,
                includeCalibrationFit: includeCalibrationFit
            )
        }
    }

    private static func aggregate(
        _ subjects: [SubjectMetricComparison],
        metric: WhoopComparableMetric,
        mode: StudySourceMode,
        includeCalibrationFit: Bool
    ) -> AggregateMetricReport? {
        let pairedSubjects = subjects.filter { $0.pairCount > 0 }
        guard !pairedSubjects.isEmpty else { return nil }
        let allOfficial = pairedSubjects.flatMap(\.official)
        let allNoop = pairedSubjects.flatMap(\.noop)
        let errors = zip(allNoop, allOfficial).map(-)
        let absErrors = errors.map(abs)
        let subjectMAE = pairedSubjects.map(\.mae)
        let subjectMedianAE = pairedSubjects.map(\.medianAbsoluteError)
        let eligible = subjects.reduce(0) { $0 + $1.eligibleOfficialDays }
        let pairs = errors.count

        let macroR = fisherMean(pairedSubjects.compactMap(\.correlation))
        let errorSD = sampleStandardDeviation(errors)
        let loa = errorSD.map {
            LimitsOfAgreement(lower: mean(errors) - 1.96 * $0, upper: mean(errors) + 1.96 * $0)
        }
        let fit = includeCalibrationFit ? affineFit(x: allNoop, y: allOfficial) : nil

        return AggregateMetricReport(
            metric: metric,
            sourceMode: mode,
            algorithmRevisions: Array(Set(pairedSubjects.map(\.revision))).sorted(),
            subjectCount: pairedSubjects.count,
            pairedDayCount: pairs,
            eligibleDayCount: eligible,
            coveragePercent: eligible > 0 ? 100.0 * Double(pairs) / Double(eligible) : 0,
            macroBias: mean(pairedSubjects.map(\.bias)),
            macroMeanAbsoluteError: mean(subjectMAE),
            macroRootMeanSquaredError: mean(pairedSubjects.map(\.rmse)),
            macroMAE95CI: bootstrapMeanCI(subjectMAE),
            medianSubjectAbsoluteError: percentile(subjectMedianAE, 0.5),
            subjectAbsoluteErrorIQR: ConfidenceInterval(
                lower: percentile(subjectMedianAE, 0.25),
                upper: percentile(subjectMedianAE, 0.75)
            ),
            pooledBias: mean(errors),
            pooledMeanAbsoluteError: mean(absErrors),
            pooledMedianAbsoluteError: percentile(absErrors, 0.5),
            pooledRootMeanSquaredError: rootMeanSquare(errors),
            pooledP90AbsoluteError: percentile(absErrors, 0.90),
            pooledP95AbsoluteError: percentile(absErrors, 0.95),
            macroFisherPearsonCorrelation: macroR,
            pooledPearsonCorrelation: pearson(allNoop, allOfficial),
            pooledSpearmanCorrelation: spearman(allNoop, allOfficial),
            pooledConcordanceCorrelation: concordance(allNoop, allOfficial),
            blandAltman95Limits: loa,
            calibrationIntercept: fit?.intercept,
            calibrationSlope: fit?.slope,
            recoveryBandConfusion: metric == .recoveryScore
                ? scoreBandConfusion(official: allOfficial, noop: allNoop)
                : nil
        )
    }
}

private struct MetricMode: Hashable, Comparable {
    let metric: WhoopComparableMetric
    let mode: StudySourceMode

    static func < (lhs: MetricMode, rhs: MetricMode) -> Bool {
        if lhs.mode.rawValue != rhs.mode.rawValue {
            return lhs.mode.rawValue < rhs.mode.rawValue
        }
        return lhs.metric.rawValue < rhs.metric.rawValue
    }
}

private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func rootMeanSquare(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let position = min(1, max(0, p)) * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    guard lower != upper else { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
}

private func sampleStandardDeviation(_ values: [Double]) -> Double? {
    guard values.count >= 2 else { return nil }
    let center = mean(values)
    let variance = values.reduce(0) { $0 + ($1 - center) * ($1 - center) }
        / Double(values.count - 1)
    return variance.squareRoot()
}

private func pearson(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= 3 else { return nil }
    let mx = mean(x)
    let my = mean(y)
    var covariance = 0.0
    var sx = 0.0
    var sy = 0.0
    for (a, b) in zip(x, y) {
        let dx = a - mx
        let dy = b - my
        covariance += dx * dy
        sx += dx * dx
        sy += dy * dy
    }
    guard sx > 1e-12, sy > 1e-12 else { return nil }
    return min(1, max(-1, covariance / (sx * sy).squareRoot()))
}

private func spearman(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= 3 else { return nil }
    return pearson(ranks(x), ranks(y))
}

private func ranks(_ values: [Double]) -> [Double] {
    let indexed = values.enumerated().sorted {
        $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element
    }
    var output = Array(repeating: 0.0, count: values.count)
    var start = 0
    while start < indexed.count {
        var end = start + 1
        while end < indexed.count && indexed[end].element == indexed[start].element {
            end += 1
        }
        let averageRank = (Double(start + 1) + Double(end)) / 2.0
        for index in start..<end { output[indexed[index].offset] = averageRank }
        start = end
    }
    return output
}

private func concordance(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= 2 else { return nil }
    let mx = mean(x)
    let my = mean(y)
    let n = Double(x.count)
    let vx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) } / n
    let vy = y.reduce(0) { $0 + ($1 - my) * ($1 - my) } / n
    let covariance = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / n
    let denominator = vx + vy + (mx - my) * (mx - my)
    guard denominator > 1e-12 else { return nil }
    return 2 * covariance / denominator
}

private func fisherMean(_ correlations: [Double]) -> Double? {
    guard !correlations.isEmpty else { return nil }
    let z = correlations.map {
        let bounded = min(0.999_999, max(-0.999_999, $0))
        return 0.5 * log((1 + bounded) / (1 - bounded))
    }
    return tanh(mean(z))
}

private func affineFit(x: [Double], y: [Double]) -> (intercept: Double, slope: Double)? {
    guard x.count == y.count, x.count >= 2 else { return nil }
    let mx = mean(x)
    let my = mean(y)
    var covariance = 0.0
    var variance = 0.0
    for (a, b) in zip(x, y) {
        covariance += (a - mx) * (b - my)
        variance += (a - mx) * (a - mx)
    }
    guard variance > 1e-12 else { return nil }
    let slope = covariance / variance
    return (my - slope * mx, slope)
}

private func scoreBandConfusion(
    official: [Double],
    noop: [Double]
) -> ScoreBandConfusion {
    func band(_ value: Double) -> Int {
        if value < 34 { return 0 }
        if value < 67 { return 1 }
        return 2
    }
    var matrix = Array(repeating: Array(repeating: 0, count: 3), count: 3)
    var correct = 0
    for (truth, estimate) in zip(official, noop) {
        let i = band(truth)
        let j = band(estimate)
        matrix[i][j] += 1
        if i == j { correct += 1 }
    }
    return ScoreBandConfusion(
        matrix: matrix,
        accuracy: official.isEmpty ? 0 : Double(correct) / Double(official.count)
    )
}

private struct DeterministicGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e3779b97f4a7c15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64 keeps the low bits well mixed. The previous LCG alternated
        // its lowest bit, so a two-subject bootstrap always sampled one of
        // each subject and collapsed the confidence interval to a point.
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private func bootstrapMeanCI(_ subjectValues: [Double]) -> ConfidenceInterval {
    guard !subjectValues.isEmpty else { return ConfidenceInterval(lower: 0, upper: 0) }
    guard subjectValues.count > 1 else {
        return ConfidenceInterval(lower: subjectValues[0], upper: subjectValues[0])
    }
    var generator = DeterministicGenerator(seed: UInt64(subjectValues.count) ^ 0x4e4f4f50)
    var means: [Double] = []
    means.reserveCapacity(2_000)
    for _ in 0..<2_000 {
        var sample = 0.0
        for _ in subjectValues.indices {
            let index = Int(generator.next() % UInt64(subjectValues.count))
            sample += subjectValues[index]
        }
        means.append(sample / Double(subjectValues.count))
    }
    return ConfidenceInterval(
        lower: percentile(means, 0.025),
        upper: percentile(means, 0.975)
    )
}
