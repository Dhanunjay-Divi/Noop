import Foundation

/// A locally persisted, holdout-validated personal model plus one separately provenanced estimate.
///
/// This record is presentation state only. It never replaces the official WHOOP observation or the raw
/// NOOP score in `WhoopStore`, and it is invalidated whenever its metric or algorithm revision changes.
public struct PersistedPersonalCalibration: Equatable, Codable, Sendable {
    public let model: PersonalCalibrationModel
    public let validation: PersonalCalibrationValidation
    public let confidence: PersonalCalibrationConfidence
    public let latestEstimate: CalibratedMetricEstimate
    public let savedAtUnixSeconds: Double
}

/// Durable local storage for validated personal calibration models.
///
/// UserDefaults is deliberate here: these are tiny, non-secret coefficients and provenance records, not
/// biometric history. Every load revalidates the complete record; malformed, stale-revision, weak, or
/// self-inconsistent payloads are deleted instead of being applied.
public final class PersonalCalibrationModelStore {
    private let defaults: UserDefaults
    private let namespace: String

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "noop.personalCalibration.v1"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    /// Save only a model that passed conservative chronological holdout validation and can produce a
    /// separately labeled estimate from a revision-verified raw NOOP observation.
    @discardableResult
    public func saveValidated(
        report: WhoopReferenceComparisonReport,
        savedAt: Date = Date()
    ) -> Bool {
        guard report.calibration.decision == .validated,
              report.calibration.confidence != .none,
              let model = report.calibration.model,
              let validation = report.calibration.validation,
              let raw = report.latestVerifiedNoopObservation,
              let estimate = model.apply(to: raw)
        else {
            remove(metric: report.metric, noopAlgorithmVersion: report.noopAlgorithmVersion)
            return false
        }

        let record = PersistedPersonalCalibration(
            model: model,
            validation: validation,
            confidence: report.calibration.confidence,
            latestEstimate: estimate,
            savedAtUnixSeconds: savedAt.timeIntervalSince1970)
        guard Self.isValid(
            record,
            metric: report.metric,
            noopAlgorithmVersion: report.noopAlgorithmVersion)
        else {
            remove(metric: report.metric, noopAlgorithmVersion: report.noopAlgorithmVersion)
            return false
        }

        guard let data = try? JSONEncoder().encode(record) else { return false }
        let storageKey = key(
            metric: report.metric,
            noopAlgorithmVersion: report.noopAlgorithmVersion)
        // Invalidate first so interruption can only remove calibration, never preserve an older
        // same-revision model after new validation evidence failed to persist.
        defaults.removeObject(forKey: storageKey)
        guard defaults.synchronize() else { return false }
        defaults.set(data, forKey: storageKey)
        let persisted = defaults.synchronize()
        if !persisted {
            defaults.removeObject(forKey: storageKey)
            _ = defaults.synchronize()
        }
        return persisted
    }

    public func load(
        metric: WhoopComparableMetric,
        noopAlgorithmVersion: String
    ) -> PersistedPersonalCalibration? {
        let storageKey = key(metric: metric, noopAlgorithmVersion: noopAlgorithmVersion)
        guard let data = defaults.data(forKey: storageKey),
              let record = try? JSONDecoder().decode(PersistedPersonalCalibration.self, from: data),
              Self.isValid(record, metric: metric,
                           noopAlgorithmVersion: noopAlgorithmVersion)
        else {
            defaults.removeObject(forKey: storageKey)
            _ = defaults.synchronize()
            return nil
        }
        return record
    }

    public func remove(metric: WhoopComparableMetric, noopAlgorithmVersion: String) {
        defaults.removeObject(
            forKey: key(metric: metric, noopAlgorithmVersion: noopAlgorithmVersion))
        _ = defaults.synchronize()
    }

    private func key(metric: WhoopComparableMetric, noopAlgorithmVersion: String) -> String {
        "\(namespace).\(metric.rawValue).\(noopAlgorithmVersion)"
    }

    private static func isValid(
        _ record: PersistedPersonalCalibration,
        metric: WhoopComparableMetric,
        noopAlgorithmVersion: String
    ) -> Bool {
        let model = record.model
        let validation = record.validation
        let estimate = record.latestEstimate

        guard model.modelVersion == PersonalCalibrationModel.modelVersion,
              model.metric == metric,
              model.basedOnNoopAlgorithmVersion == noopAlgorithmVersion,
              model.intercept.isFinite,
              abs(model.intercept) <= 400,
              model.slope.isFinite,
              (0.25...4.0).contains(model.slope),
              model.trainingCount >= 21,
              model.trainingCount == validation.trainingCount,
              model.trainedThroughDay == validation.trainingLastDay,
              validation.holdoutCount >= 7,
              let trainingCorrelation = validation.trainingCorrelation,
              trainingCorrelation.isFinite,
              trainingCorrelation >= 0.35,
              validation.rawHoldoutMAE.isFinite,
              validation.calibratedHoldoutMAE.isFinite,
              validation.rawHoldoutRMSE.isFinite,
              validation.calibratedHoldoutRMSE.isFinite,
              validation.relativeMAEImprovement.isFinite,
              validation.rawHoldoutMAE >= 0,
              validation.calibratedHoldoutMAE >= 0,
              validation.rawHoldoutRMSE >= 0,
              validation.calibratedHoldoutRMSE >= 0,
              validation.relativeMAEImprovement >= 0.05,
              validation.calibratedHoldoutMAE <= validation.rawHoldoutMAE,
              validation.calibratedHoldoutRMSE <= validation.rawHoldoutRMSE,
              WhoopReferenceCalibration.validDay(validation.trainingFirstDay),
              WhoopReferenceCalibration.validDay(validation.trainingLastDay),
              WhoopReferenceCalibration.validDay(validation.holdoutFirstDay),
              WhoopReferenceCalibration.validDay(validation.holdoutLastDay),
              validation.trainingFirstDay <= validation.trainingLastDay,
              validation.trainingLastDay < validation.holdoutFirstDay,
              validation.holdoutFirstDay <= validation.holdoutLastDay,
              estimate.metric == metric,
              estimate.rawNoopValue.isFinite,
              estimate.calibratedValue.isFinite,
              metric.plausibleRange.contains(estimate.rawNoopValue),
              metric.plausibleRange.contains(estimate.calibratedValue),
              case let .noopOnDevice(rawVersion) = estimate.rawProvenance,
              rawVersion == noopAlgorithmVersion,
              case let .noopPersonalCalibration(storedModelVersion, basedOnVersion)
                = estimate.calibratedProvenance,
              storedModelVersion == model.modelVersion,
              basedOnVersion == noopAlgorithmVersion,
              WhoopReferenceCalibration.validDay(estimate.day),
              estimate.day >= model.trainedThroughDay,
              record.confidence != .none,
              record.savedAtUnixSeconds.isFinite,
              record.savedAtUnixSeconds > 0
        else { return false }
        let expected = min(
            metric.plausibleRange.upperBound,
            max(metric.plausibleRange.lowerBound,
                model.intercept + model.slope * estimate.rawNoopValue))
        return abs(expected - estimate.calibratedValue) <= 1e-9
    }
}
