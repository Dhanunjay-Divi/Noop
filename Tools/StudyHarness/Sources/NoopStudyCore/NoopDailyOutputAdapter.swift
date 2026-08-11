import Foundation
import StrandAnalytics

public enum NoopDailyOutputAdapter {
    public static func load(
        from url: URL,
        expectedSubjectID: String
    ) throws -> StudyPredictionSet {
        let output: NoopDailyOutputFile
        do {
            output = try JSONDecoder().decode(
                NoopDailyOutputFile.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw StudyError.malformedManifest("Invalid NOOP daily output: \(error.localizedDescription)")
        }
        guard output.schemaVersion == 1 else {
            throw StudyError.unsupportedSchema(output.schemaVersion)
        }
        guard output.subjectID == expectedSubjectID else {
            throw StudyError.outputSubjectMismatch(
                expected: expectedSubjectID,
                actual: output.subjectID
            )
        }
        let pipelineRevision = output.measurementPipelineRevision
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pipelineRevision.isEmpty else {
            throw StudyError.missingMetricRevision("measurementPipelineRevision")
        }

        var seenDays = Set<String>()
        var values: [WhoopComparableMetric: [String: Double]] = [:]
        var revisions: [WhoopComparableMetric: String] = [:]

        for key in output.metricRevisions.keys where WhoopComparableMetric(rawValue: key) == nil {
            throw StudyError.unknownMetric(key)
        }

        for row in output.days {
            guard StudyDay.valid(row.day) else {
                throw StudyError.invalidMetricValue(metric: "day", day: row.day)
            }
            guard seenDays.insert(row.day).inserted else {
                throw StudyError.duplicateOutputDay(row.day)
            }
            for (key, value) in row.metrics {
                guard let metric = WhoopComparableMetric(rawValue: key) else {
                    throw StudyError.unknownMetric(key)
                }
                guard value.isFinite, plausibleRange(metric).contains(value) else {
                    throw StudyError.invalidMetricValue(metric: key, day: row.day)
                }
                values[metric, default: [:]][row.day] = value
                revisions[metric] = try revision(
                    for: metric,
                    scoreRevisions: output.metricRevisions,
                    measurementPipelineRevision: pipelineRevision
                )
            }
        }

        return StudyPredictionSet(
            sourceMode: .pairedOnDevice,
            valuesByMetric: values,
            revisionByMetric: revisions
        )
    }

    private static func revision(
        for metric: WhoopComparableMetric,
        scoreRevisions: [String: String],
        measurementPipelineRevision: String
    ) throws -> String {
        switch metric {
        case .recoveryScore, .effortScore, .restScore:
            let revision = scoreRevisions[metric.rawValue]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let revision, !revision.isEmpty else {
                throw StudyError.missingMetricRevision(metric.rawValue)
            }
            return revision
        default:
            return measurementPipelineRevision
        }
    }

    private static func plausibleRange(
        _ metric: WhoopComparableMetric
    ) -> ClosedRange<Double> {
        switch metric {
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
}
