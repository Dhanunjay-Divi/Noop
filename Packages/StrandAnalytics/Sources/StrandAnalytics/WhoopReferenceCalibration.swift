import Foundation
import WhoopStore

// MARK: - Official WHOOP reference comparison

/// Explicit revisions for the current transparent on-device score families. Bump the relevant value
/// whenever its formula changes; a personal model is never reused across revisions.
public enum NoopScoreAlgorithmRevision {
    /// Charge v2 personalizes the Rest-quality center and uses causal per-day baselines.
    public static let charge = "noop-charge-v2"
    public static let effort = "noop-effort-v2"
    public static let rest = "noop-rest-v1"
}

/// Metrics that can be compared without changing units or pretending that a proprietary WHOOP
/// calculation is known.
///
/// `effortScore` is NOOP's 0...100 representation of WHOOP's exported 0...21 Day Strain. The import
/// boundary already performs that documented scale conversion, so both sides compared here are 0...100.
/// Skin temperature is intentionally absent: the WHOOP export carries an absolute temperature while
/// NOOP currently stores a deviation from a personal baseline, so pairing them would be misleading.
public enum WhoopComparableMetric: String, CaseIterable, Codable, Sendable {
    case recoveryScore
    case effortScore
    case restScore
    case restingHeartRate
    case hrvRMSSD
    case respiratoryRate
    case bloodOxygenPercent
    case totalSleepMinutes
    case deepSleepMinutes
    case remSleepMinutes
    case lightSleepMinutes
    case sleepEfficiencyPercent

    /// Canonical WhoopStore metricSeries key used by the importer manifest and comparison loader.
    public var seriesKey: String {
        switch self {
        case .recoveryScore:         return "recovery"
        case .effortScore:           return "strain"
        case .restScore:             return "sleep_performance"
        case .restingHeartRate:      return "rhr"
        case .hrvRMSSD:              return "hrv"
        case .respiratoryRate:       return "resp_rate"
        case .bloodOxygenPercent:    return "spo2"
        case .totalSleepMinutes:     return "sleep_total_min"
        case .deepSleepMinutes:      return "sleep_deep_min"
        case .remSleepMinutes:       return "sleep_rem_min"
        case .lightSleepMinutes:     return "sleep_light_min"
        case .sleepEfficiencyPercent:return "sleep_efficiency"
        }
    }

    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .recoveryScore, .effortScore, .restScore, .sleepEfficiencyPercent:
            return 0...100
        case .restingHeartRate:
            return 25...250
        case .hrvRMSSD:
            return 1...500
        case .respiratoryRate:
            return 4...60
        case .bloodOxygenPercent:
            return 50...100
        case .totalSleepMinutes, .deepSleepMinutes, .remSleepMinutes, .lightSleepMinutes:
            return 0...1_440
        }
    }

    fileprivate func dailyValue(_ row: DailyMetric) -> Double? {
        switch self {
        case .recoveryScore:          return row.recovery
        case .effortScore:            return row.strain
        case .restScore:              return nil // Rest lives in metricSeries as sleep_performance.
        case .restingHeartRate:       return row.restingHr.map(Double.init)
        case .hrvRMSSD:               return row.avgHrv
        case .respiratoryRate:        return row.respRateBpm
        case .bloodOxygenPercent:     return row.spo2Pct
        case .totalSleepMinutes:      return row.totalSleepMin
        case .deepSleepMinutes:       return row.deepMin
        case .remSleepMinutes:        return row.remMin
        case .lightSleepMinutes:      return row.lightMin
        case .sleepEfficiencyPercent: return row.efficiency.map { $0 * 100.0 }
        }
    }
}

/// Immutable origin carried beside every value. An official reference and a local estimate remain
/// distinct throughout comparison and calibration; neither path overwrites the other.
public enum ReferenceMetricProvenance: Equatable, Codable, Sendable {
    /// A value read from a user-supplied WHOOP CSV export. `schemaRevision` identifies our parser/import
    /// mapping, not WHOOP's private model.
    case whoopCSVExport(schemaRevision: String?)
    /// A value locally computed from device streams by a named NOOP algorithm revision. "Independent"
    /// here means the official Recovery/Strain/Sleep Performance outcome is never reused as the local
    /// outcome; non-outcome physiology or sleep timing from an import may still seed personal context and
    /// must be disclosed by the product surface.
    case noopOnDevice(algorithmVersion: String)
    /// A presentation-only personal transform fitted against prior exported reference days.
    case noopPersonalCalibration(modelVersion: String, basedOnAlgorithmVersion: String)
}

/// One daily value with explicit metric and provenance.
///
/// Callers use the named factories rather than a generic initializer, making it difficult to accidentally
/// label a local estimate as an official reference.
public struct ReferenceMetricObservation: Equatable, Codable, Sendable {
    public let day: String
    public let metric: WhoopComparableMetric
    public let value: Double
    public let provenance: ReferenceMetricProvenance

    private init(day: String, metric: WhoopComparableMetric, value: Double,
                 provenance: ReferenceMetricProvenance) {
        self.day = day
        self.metric = metric
        self.value = value
        self.provenance = provenance
    }

    public static func whoopExport(day: String, metric: WhoopComparableMetric, value: Double,
                                   schemaRevision: String? = nil) -> Self {
        Self(day: day, metric: metric, value: value,
             provenance: .whoopCSVExport(schemaRevision: schemaRevision))
    }

    public static func noopComputed(day: String, metric: WhoopComparableMetric, value: Double,
                                    algorithmVersion: String) -> Self {
        Self(day: day, metric: metric, value: value,
             provenance: .noopOnDevice(algorithmVersion: algorithmVersion))
    }
}

/// A same-calendar-day official reference and locally derived NOOP estimate with separate provenance.
public struct PairedReferenceDay: Equatable, Codable, Sendable {
    public let day: String
    public let metric: WhoopComparableMetric
    public let official: ReferenceMetricObservation
    public let noop: ReferenceMetricObservation
}

/// Counts explaining exactly what entered (or did not enter) a comparison.
public struct ReferencePairingAudit: Equatable, Codable, Sendable {
    public let suppliedObservations: Int
    public let pairedDays: Int
    public let invalidOrWrongMetric: Int
    public let wrongNoopAlgorithmVersion: Int
    public let duplicateOfficialDays: Int
    public let duplicateNoopDays: Int
    public let unpairedOfficialDays: Int
    public let unpairedNoopDays: Int
    /// Stored reference rows excluded because they were not stamped by the named provenance-aware
    /// WHOOP importer revision.
    public let unverifiedStoredOfficialDays: Int
    /// Historical derived rows present in the requested range but excluded because the caller did not
    /// prove they were recomputed by the named current algorithm revision.
    public let unverifiedStoredNoopDays: Int
}

/// Error is always `NOOP − official`. Positive bias therefore means NOOP reads higher on average.
public struct ReferenceComparisonStatistics: Equatable, Codable, Sendable {
    public let sampleCount: Int
    public let firstDay: String
    public let lastDay: String
    public let officialMean: Double
    public let noopMean: Double
    public let bias: Double
    public let meanAbsoluteError: Double
    public let rootMeanSquaredError: Double
    /// Pearson r, only when there are at least three pairs and both series have non-trivial variance.
    public let correlation: Double?
}

public enum PersonalCalibrationDecision: String, Equatable, Codable, Sendable {
    case insufficientData
    case degenerateTrainingData
    case unstableRelationship
    case failedHoldoutValidation
    case validated
}

public enum PersonalCalibrationConfidence: String, Equatable, Codable, Sendable {
    case none
    case validated
    case strong
}

/// Validation is chronological: the newest paired days are held out and never used to fit the model.
public struct PersonalCalibrationValidation: Equatable, Codable, Sendable {
    public let trainingCount: Int
    public let holdoutCount: Int
    public let trainingFirstDay: String
    public let trainingLastDay: String
    public let holdoutFirstDay: String
    public let holdoutLastDay: String
    public let trainingCorrelation: Double?
    public let rawHoldoutMAE: Double
    public let calibratedHoldoutMAE: Double
    public let rawHoldoutRMSE: Double
    public let calibratedHoldoutRMSE: Double
    public let relativeMAEImprovement: Double
}

/// A validated personal affine transform: `official-like presentation = intercept + slope × raw NOOP`.
///
/// This is not a recovered WHOOP formula. It is an empirical, per-user display transform fitted only from
/// paired days supplied by that user and accepted only when it improves unseen chronological holdout days.
public struct PersonalCalibrationModel: Equatable, Codable, Sendable {
    public static let modelVersion = "noop-personal-affine-v1"

    public let metric: WhoopComparableMetric
    public let basedOnNoopAlgorithmVersion: String
    public let intercept: Double
    public let slope: Double
    public let trainingCount: Int
    public let trainedThroughDay: String
    public let modelVersion: String

    fileprivate init(metric: WhoopComparableMetric, basedOnNoopAlgorithmVersion: String,
                     intercept: Double, slope: Double, trainingCount: Int,
                     trainedThroughDay: String) {
        self.metric = metric
        self.basedOnNoopAlgorithmVersion = basedOnNoopAlgorithmVersion
        self.intercept = intercept
        self.slope = slope
        self.trainingCount = trainingCount
        self.trainedThroughDay = trainedThroughDay
        self.modelVersion = Self.modelVersion
    }

    /// Apply without mutating or replacing the raw estimate. A different metric/algorithm revision is
    /// rejected because a calibration cannot safely cross those boundaries.
    public func apply(to observation: ReferenceMetricObservation) -> CalibratedMetricEstimate? {
        guard observation.metric == metric,
              case let .noopOnDevice(algorithmVersion) = observation.provenance,
              algorithmVersion == basedOnNoopAlgorithmVersion,
              observation.value.isFinite,
              metric.plausibleRange.contains(observation.value)
        else { return nil }

        let transformed = intercept + slope * observation.value
        guard transformed.isFinite else { return nil }
        let bounded = min(metric.plausibleRange.upperBound,
                          max(metric.plausibleRange.lowerBound, transformed))
        return CalibratedMetricEstimate(
            day: observation.day,
            metric: metric,
            rawNoopValue: observation.value,
            calibratedValue: bounded,
            rawProvenance: observation.provenance,
            calibratedProvenance: .noopPersonalCalibration(
                modelVersion: modelVersion,
                basedOnAlgorithmVersion: basedOnNoopAlgorithmVersion))
    }
}

/// A calibrated presentation value that always retains the untouched raw NOOP estimate beside it.
public struct CalibratedMetricEstimate: Equatable, Codable, Sendable {
    public let day: String
    public let metric: WhoopComparableMetric
    public let rawNoopValue: Double
    public let calibratedValue: Double
    public let rawProvenance: ReferenceMetricProvenance
    public let calibratedProvenance: ReferenceMetricProvenance
}

public struct PersonalCalibrationResult: Equatable, Codable, Sendable {
    public let decision: PersonalCalibrationDecision
    public let confidence: PersonalCalibrationConfidence
    public let reason: String
    public let model: PersonalCalibrationModel?
    public let validation: PersonalCalibrationValidation?
}

/// Conservative defaults: 21 chronological training days plus at least 7 untouched validation days.
public struct PersonalCalibrationConfiguration: Equatable, Sendable {
    public var minimumPairs: Int
    public var minimumTrainingPairs: Int
    public var minimumHoldoutPairs: Int
    public var holdoutFraction: Double
    public var minimumTrainingCorrelation: Double
    public var minimumRelativeMAEImprovement: Double
    public var allowedSlope: ClosedRange<Double>
    public var strongConfidencePairs: Int
    public var strongConfidenceCorrelation: Double
    public var strongConfidenceMAEImprovement: Double

    public init(minimumPairs: Int = 28,
                minimumTrainingPairs: Int = 21,
                minimumHoldoutPairs: Int = 7,
                holdoutFraction: Double = 0.25,
                minimumTrainingCorrelation: Double = 0.35,
                minimumRelativeMAEImprovement: Double = 0.05,
                allowedSlope: ClosedRange<Double> = 0.25...4.0,
                strongConfidencePairs: Int = 90,
                strongConfidenceCorrelation: Double = 0.75,
                strongConfidenceMAEImprovement: Double = 0.10) {
        self.minimumPairs = minimumPairs
        self.minimumTrainingPairs = minimumTrainingPairs
        self.minimumHoldoutPairs = minimumHoldoutPairs
        self.holdoutFraction = holdoutFraction
        self.minimumTrainingCorrelation = minimumTrainingCorrelation
        self.minimumRelativeMAEImprovement = minimumRelativeMAEImprovement
        self.allowedSlope = allowedSlope
        self.strongConfidencePairs = strongConfidencePairs
        self.strongConfidenceCorrelation = strongConfidenceCorrelation
        self.strongConfidenceMAEImprovement = strongConfidenceMAEImprovement
    }

    public static let conservative = PersonalCalibrationConfiguration()
}

public struct WhoopReferenceComparisonReport: Equatable, Codable, Sendable {
    public let metric: WhoopComparableMetric
    public let noopAlgorithmVersion: String
    public let pairs: [PairedReferenceDay]
    public let audit: ReferencePairingAudit
    public let statistics: ReferenceComparisonStatistics?
    public let calibration: PersonalCalibrationResult
    /// Newest raw NOOP observation whose algorithm revision was verified for this report. This remains
    /// distinct from both the official reference and any presentation-only calibrated estimate.
    public let latestVerifiedNoopObservation: ReferenceMetricObservation?
}

public enum WhoopReferenceCalibrationError: Error, Equatable, Sendable {
    /// The official import and independent computation must never be read from the same namespace.
    case sourceNamespacesMustBeDistinct
    case missingSourceIdentifier
    case missingNoopAlgorithmVersion
}

/// Pure comparison/calibration engine plus a store-loading convenience API.
///
/// It never writes reference values, raw NOOP values, or calibrated values back to the database.
/// Consumers choose whether to display a validated personal transform and should always label it as such.
public enum WhoopReferenceCalibration {

    /// Compare already-provenanced observations for one metric and one NOOP algorithm revision.
    public static func report(
        metric: WhoopComparableMetric,
        observations: [ReferenceMetricObservation],
        noopAlgorithmVersion: String,
        configuration: PersonalCalibrationConfiguration = .conservative
    ) -> WhoopReferenceComparisonReport {
        var invalid = 0
        var wrongVersion = 0
        var officialByDay: [String: ReferenceMetricObservation] = [:]
        var noopByDay: [String: ReferenceMetricObservation] = [:]
        var duplicateOfficial = Set<String>()
        var duplicateNoop = Set<String>()

        for observation in observations {
            guard observation.metric == metric,
                  validDay(observation.day),
                  observation.value.isFinite,
                  metric.plausibleRange.contains(observation.value)
            else {
                invalid += 1
                continue
            }

            switch observation.provenance {
            case .whoopCSVExport:
                if officialByDay.updateValue(observation, forKey: observation.day) != nil {
                    duplicateOfficial.insert(observation.day)
                }
            case let .noopOnDevice(version):
                guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !noopAlgorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      version == noopAlgorithmVersion else {
                    wrongVersion += 1
                    continue
                }
                if noopByDay.updateValue(observation, forKey: observation.day) != nil {
                    duplicateNoop.insert(observation.day)
                }
            case .noopPersonalCalibration:
                // A calibrated output is never allowed to train itself.
                invalid += 1
            }
        }

        // Ambiguous duplicate days are removed rather than selected by array order.
        for day in duplicateOfficial { officialByDay.removeValue(forKey: day) }
        for day in duplicateNoop { noopByDay.removeValue(forKey: day) }

        let commonDays = Set(officialByDay.keys).intersection(noopByDay.keys).sorted()
        let pairs = commonDays.compactMap { day -> PairedReferenceDay? in
            guard let official = officialByDay[day], let noop = noopByDay[day] else { return nil }
            return PairedReferenceDay(day: day, metric: metric, official: official, noop: noop)
        }

        let audit = ReferencePairingAudit(
            suppliedObservations: observations.count,
            pairedDays: pairs.count,
            invalidOrWrongMetric: invalid,
            wrongNoopAlgorithmVersion: wrongVersion,
            duplicateOfficialDays: duplicateOfficial.count,
            duplicateNoopDays: duplicateNoop.count,
            unpairedOfficialDays: officialByDay.keys.filter { noopByDay[$0] == nil }.count,
            unpairedNoopDays: noopByDay.keys.filter { officialByDay[$0] == nil }.count,
            unverifiedStoredOfficialDays: 0,
            unverifiedStoredNoopDays: 0)

        return WhoopReferenceComparisonReport(
            metric: metric,
            noopAlgorithmVersion: noopAlgorithmVersion,
            pairs: pairs,
            audit: audit,
            statistics: statistics(pairs),
            calibration: calibration(metric: metric, pairs: pairs,
                                     noopAlgorithmVersion: noopAlgorithmVersion,
                                     configuration: configuration),
            latestVerifiedNoopObservation: noopByDay.keys.sorted().last.flatMap { noopByDay[$0] })
    }

    /// Load the official import namespace and its separately stored `-noop` namespace, then compare.
    ///
    /// Both verified day sets are mandatory provenance evidence because the current store schema does
    /// not stamp revisions on historical value rows. Official days must come from the provenance-aware
    /// importer manifest; NOOP days must come from a completed current-session raw-stream rescore receipt
    /// whose store write succeeded. Stored rows outside either set are audited and excluded rather than
    /// falsely relabeled.
    public static func report(
        store: WhoopStore,
        metric: WhoopComparableMetric,
        importedDeviceId: String,
        computedDeviceId: String,
        from: String,
        to: String,
        noopAlgorithmVersion: String,
        verifiedOfficialReferenceDays: Set<String>,
        verifiedCurrentNoopDays: Set<String>,
        whoopImportSchemaRevision: String? = nil,
        configuration: PersonalCalibrationConfiguration = .conservative
    ) async throws -> WhoopReferenceComparisonReport {
        guard !importedDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !computedDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw WhoopReferenceCalibrationError.missingSourceIdentifier }
        guard importedDeviceId != computedDeviceId
        else { throw WhoopReferenceCalibrationError.sourceNamespacesMustBeDistinct }
        guard !noopAlgorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw WhoopReferenceCalibrationError.missingNoopAlgorithmVersion }

        async let officialRows = loadValues(store: store, deviceId: importedDeviceId,
                                            metric: metric, from: from, to: to,
                                            useComputedDailyValues: false)
        async let noopRows = loadValues(store: store, deviceId: computedDeviceId,
                                        metric: metric, from: from, to: to,
                                        useComputedDailyValues: true)
        let (storedOfficial, storedNoop) = try await (officialRows, noopRows)
        let validOfficialDays = Set(verifiedOfficialReferenceDays.filter(validDay))
        let validNoopDays = Set(verifiedCurrentNoopDays.filter(validDay))
        let official = storedOfficial.filter { validOfficialDays.contains($0.day) }
        let noop = storedNoop.filter { validNoopDays.contains($0.day) }
        let unverifiedOfficialCount =
            Set(storedOfficial.map(\.day)).subtracting(validOfficialDays).count
        let unverifiedNoopCount = Set(storedNoop.map(\.day)).subtracting(validNoopDays).count

        let observations =
            official.map {
                ReferenceMetricObservation.whoopExport(
                    day: $0.day, metric: metric, value: $0.value,
                    schemaRevision: whoopImportSchemaRevision)
            }
            + noop.map {
                ReferenceMetricObservation.noopComputed(
                    day: $0.day, metric: metric, value: $0.value,
                    algorithmVersion: noopAlgorithmVersion)
            }

        let base = report(metric: metric, observations: observations,
                          noopAlgorithmVersion: noopAlgorithmVersion,
                          configuration: configuration)
        let audited = ReferencePairingAudit(
            suppliedObservations: base.audit.suppliedObservations,
            pairedDays: base.audit.pairedDays,
            invalidOrWrongMetric: base.audit.invalidOrWrongMetric,
            wrongNoopAlgorithmVersion: base.audit.wrongNoopAlgorithmVersion,
            duplicateOfficialDays: base.audit.duplicateOfficialDays,
            duplicateNoopDays: base.audit.duplicateNoopDays,
            unpairedOfficialDays: base.audit.unpairedOfficialDays,
            unpairedNoopDays: base.audit.unpairedNoopDays,
            unverifiedStoredOfficialDays: unverifiedOfficialCount,
            unverifiedStoredNoopDays: unverifiedNoopCount)
        return WhoopReferenceComparisonReport(
            metric: base.metric,
            noopAlgorithmVersion: base.noopAlgorithmVersion,
            pairs: base.pairs,
            audit: audited,
            statistics: base.statistics,
            calibration: base.calibration,
            latestVerifiedNoopObservation: base.latestVerifiedNoopObservation)
    }

    // MARK: - Store mapping

    private static func loadValues(
        store: WhoopStore,
        deviceId: String,
        metric: WhoopComparableMetric,
        from: String,
        to: String,
        useComputedDailyValues: Bool
    ) async throws -> [(day: String, value: Double)] {
        if useComputedDailyValues {
            // A completed current rescore writes every comparable local input into DailyMetric. Read that
            // surface exclusively so an old/re-imported metricSeries point cannot override the fresh row.
            // Rest is deterministically re-derived from that same row because it has no dedicated column.
            return try await store.dailyMetrics(deviceId: deviceId, from: from, to: to)
                .compactMap { row -> (day: String, value: Double)? in
                    let value = metric == .restScore
                        ? AnalyticsEngine.Rest.composite(daily: row)
                        : metric.dailyValue(row)
                    return value.map { (day: row.day, value: $0) }
                }
                .sorted { $0.day < $1.day }
        }

        let series = try await store.metricSeries(deviceId: deviceId, key: metric.seriesKey,
                                                  from: from, to: to)
        var byDay = Dictionary(series.map {
            let value = metric == .sleepEfficiencyPercent ? $0.value * 100.0 : $0.value
            return ($0.day, value)
        },
                               uniquingKeysWith: { _, latest in latest })

        // metricSeries is the lossless imported surface. Daily columns fill only absent days, mainly for
        // locally computed recovery/effort/vitals. `sleepEfficiencyPercent` is normalized from the store's
        // 0...1 fraction back to percent here.
        for row in try await store.dailyMetrics(deviceId: deviceId, from: from, to: to)
        where byDay[row.day] == nil {
            if let value = metric.dailyValue(row) { byDay[row.day] = value }
        }
        return byDay.keys.sorted().compactMap { day in
            byDay[day].map { (day: day, value: $0) }
        }
    }

    // MARK: - Statistics

    private static func statistics(_ pairs: [PairedReferenceDay]) -> ReferenceComparisonStatistics? {
        guard let first = pairs.first, let last = pairs.last else { return nil }
        let official = pairs.map(\.official.value)
        let noop = pairs.map(\.noop.value)
        let errors = zip(noop, official).map(-)
        let n = Double(pairs.count)
        let officialMean = official.reduce(0, +) / n
        let noopMean = noop.reduce(0, +) / n
        let mae = errors.reduce(0) { $0 + abs($1) } / n
        let rmse = (errors.reduce(0) { $0 + $1 * $1 } / n).squareRoot()
        return ReferenceComparisonStatistics(
            sampleCount: pairs.count,
            firstDay: first.day,
            lastDay: last.day,
            officialMean: officialMean,
            noopMean: noopMean,
            bias: errors.reduce(0, +) / n,
            meanAbsoluteError: mae,
            rootMeanSquaredError: rmse,
            correlation: pearson(x: noop, y: official))
    }

    // MARK: - Personal calibration

    private static func calibration(
        metric: WhoopComparableMetric,
        pairs: [PairedReferenceDay],
        noopAlgorithmVersion: String,
        configuration c: PersonalCalibrationConfiguration
    ) -> PersonalCalibrationResult {
        let minPairs = max(c.minimumPairs, c.minimumTrainingPairs + c.minimumHoldoutPairs)
        guard pairs.count >= minPairs else {
            return PersonalCalibrationResult(
                decision: .insufficientData, confidence: .none,
                reason: "Needs at least \(minPairs) paired days; \(pairs.count) are available.",
                model: nil, validation: nil)
        }

        let fraction = min(0.5, max(0.05, c.holdoutFraction))
        let fractionCount = Int((Double(pairs.count) * fraction).rounded(.up))
        let holdoutCount = max(c.minimumHoldoutPairs, fractionCount)
        let trainingCount = pairs.count - holdoutCount
        guard trainingCount >= c.minimumTrainingPairs, holdoutCount > 0 else {
            return PersonalCalibrationResult(
                decision: .insufficientData, confidence: .none,
                reason: "The configured chronological split leaves too few training or holdout days.",
                model: nil, validation: nil)
        }

        let training = Array(pairs.prefix(trainingCount))
        let holdout = Array(pairs.suffix(holdoutCount))
        let trainX = training.map(\.noop.value)
        let trainY = training.map(\.official.value)
        guard let fit = affineFit(x: trainX, y: trainY) else {
            return PersonalCalibrationResult(
                decision: .degenerateTrainingData, confidence: .none,
                reason: "Training values do not vary enough to fit a stable personal transform.",
                model: nil, validation: nil)
        }

        let trainCorrelation = pearson(x: trainX, y: trainY)
        guard let r = trainCorrelation,
              r >= c.minimumTrainingCorrelation,
              c.allowedSlope.contains(fit.slope)
        else {
            return PersonalCalibrationResult(
                decision: .unstableRelationship, confidence: .none,
                reason: "Training relationship is too weak or the fitted slope is outside the safety gate.",
                model: nil, validation: nil)
        }

        let model = PersonalCalibrationModel(
            metric: metric,
            basedOnNoopAlgorithmVersion: noopAlgorithmVersion,
            intercept: fit.intercept,
            slope: fit.slope,
            trainingCount: trainingCount,
            trainedThroughDay: training.last!.day)

        let holdoutOfficial = holdout.map(\.official.value)
        let holdoutRaw = holdout.map(\.noop.value)
        let holdoutCalibrated = holdout.map {
            min(metric.plausibleRange.upperBound,
                max(metric.plausibleRange.lowerBound, fit.intercept + fit.slope * $0.noop.value))
        }
        let rawMAE = meanAbsoluteError(predicted: holdoutRaw, actual: holdoutOfficial)
        let calibratedMAE = meanAbsoluteError(predicted: holdoutCalibrated, actual: holdoutOfficial)
        let rawRMSE = rootMeanSquaredError(predicted: holdoutRaw, actual: holdoutOfficial)
        let calibratedRMSE = rootMeanSquaredError(predicted: holdoutCalibrated, actual: holdoutOfficial)
        let improvement = rawMAE > 1e-12 ? (rawMAE - calibratedMAE) / rawMAE : 0

        let validation = PersonalCalibrationValidation(
            trainingCount: trainingCount,
            holdoutCount: holdoutCount,
            trainingFirstDay: training.first!.day,
            trainingLastDay: training.last!.day,
            holdoutFirstDay: holdout.first!.day,
            holdoutLastDay: holdout.last!.day,
            trainingCorrelation: trainCorrelation,
            rawHoldoutMAE: rawMAE,
            calibratedHoldoutMAE: calibratedMAE,
            rawHoldoutRMSE: rawRMSE,
            calibratedHoldoutRMSE: calibratedRMSE,
            relativeMAEImprovement: improvement)

        guard improvement >= c.minimumRelativeMAEImprovement,
              calibratedRMSE <= rawRMSE
        else {
            return PersonalCalibrationResult(
                decision: .failedHoldoutValidation, confidence: .none,
                reason: "The transform did not improve unseen chronological holdout days enough.",
                model: nil, validation: validation)
        }

        let strong = pairs.count >= c.strongConfidencePairs
            && r >= c.strongConfidenceCorrelation
            && improvement >= c.strongConfidenceMAEImprovement
        return PersonalCalibrationResult(
            decision: .validated,
            confidence: strong ? .strong : .validated,
            reason: "Validated on \(holdoutCount) later days that were not used for fitting.",
            model: model,
            validation: validation)
    }

    private static func affineFit(x: [Double], y: [Double]) -> (intercept: Double, slope: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var covariance = 0.0
        var varianceX = 0.0
        for (xi, yi) in zip(x, y) {
            let dx = xi - meanX
            covariance += dx * (yi - meanY)
            varianceX += dx * dx
        }
        guard varianceX > 1e-12 else { return nil }
        let slope = covariance / varianceX
        let intercept = meanY - slope * meanX
        guard slope.isFinite, intercept.isFinite else { return nil }
        return (intercept, slope)
    }

    private static func pearson(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var numerator = 0.0
        var sx = 0.0
        var sy = 0.0
        for (xi, yi) in zip(x, y) {
            let dx = xi - mx
            let dy = yi - my
            numerator += dx * dy
            sx += dx * dx
            sy += dy * dy
        }
        guard sx > 1e-12, sy > 1e-12 else { return nil }
        let r = numerator / (sx * sy).squareRoot()
        return min(1, max(-1, r))
    }

    private static func meanAbsoluteError(predicted: [Double], actual: [Double]) -> Double {
        guard predicted.count == actual.count, !predicted.isEmpty else { return 0 }
        return zip(predicted, actual).reduce(0) { $0 + abs($1.0 - $1.1) }
            / Double(predicted.count)
    }

    private static func rootMeanSquaredError(predicted: [Double], actual: [Double]) -> Double {
        guard predicted.count == actual.count, !predicted.isEmpty else { return 0 }
        return (zip(predicted, actual).reduce(0) {
            let d = $1.0 - $1.1
            return $0 + d * d
        } / Double(predicted.count)).squareRoot()
    }

    static func validDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: year, month: month, day: dayOfMonth)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == dayOfMonth
    }
}
