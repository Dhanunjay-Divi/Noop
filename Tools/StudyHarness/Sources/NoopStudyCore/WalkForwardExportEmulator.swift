import Foundation
import StrandAnalytics

public struct StudyPredictionSet: Equatable, Sendable {
    public let sourceMode: StudySourceMode
    public let valuesByMetric: [WhoopComparableMetric: [String: Double]]
    public let revisionByMetric: [WhoopComparableMetric: String]

    public init(
        sourceMode: StudySourceMode,
        valuesByMetric: [WhoopComparableMetric: [String: Double]],
        revisionByMetric: [WhoopComparableMetric: String]
    ) {
        self.sourceMode = sourceMode
        self.valuesByMetric = valuesByMetric
        self.revisionByMetric = revisionByMetric
    }
}

/// Leakage-safe exploration from WHOOP-processed, non-outcome daily features.
///
/// This is intentionally not the raw-device pipeline. Official Recovery, Day
/// Strain, Sleep Performance, Sleep Need, Sleep Consistency, and journal answers
/// are never inputs. A day's baseline is the state after strictly earlier days;
/// the current day updates state only after its prediction is produced.
public enum WalkForwardExportEmulator {
    public static let chargeRevision =
        "\(NoopScoreAlgorithmRevision.charge)+export-features-walk-forward-v1"
    public static let restRevision =
        "\(NoopScoreAlgorithmRevision.rest)+export-features-fixed-8h-v1"

    public static func predict(_ input: [ExportFeatureDay]) -> StudyPredictionSet {
        var hrvState: BaselineState?
        var rhrState: BaselineState?
        var respState: BaselineState?
        var restState: BaselineState?
        var chargeByDay: [String: Double] = [:]
        var restByDay: [String: Double] = [:]

        for row in input.sorted(by: { $0.day < $1.day }) {
            let rest = restScore(row)
            if let rest { restByDay[row.day] = rest }

            // Strictly prior state only. The current night is folded below.
            if let hrv = row.hrvRMSSD,
               let rhr = row.restingHeartRate,
               let hrvBaseline = hrvState,
               hrvBaseline.usable,
               let score = RecoveryScorer.recovery(
                   hrv: hrv,
                   rhr: rhr,
                   resp: row.respiratoryRate,
                   hrvBaseline: hrvBaseline,
                   rhrBaseline: rhrState?.usable == true ? rhrState : nil,
                   respBaseline: respState?.usable == true ? respState : nil,
                   sleepPerf: rest.map { $0 / 100.0 },
                   restQualityBaseline: restState?.usable == true ? restState : nil,
                   skinTempDev: nil
               ) {
                chargeByDay[row.day] = score
            }

            hrvState = Baselines.update(hrvState, value: row.hrvRMSSD, cfg: Baselines.hrvCfg)
            rhrState = Baselines.update(
                rhrState,
                value: row.restingHeartRate,
                cfg: Baselines.restingHRCfg
            )
            respState = Baselines.update(
                respState,
                value: row.respiratoryRate,
                cfg: Baselines.respCfg
            )
            restState = Baselines.update(
                restState,
                value: rest.map { $0 / 100.0 },
                cfg: Baselines.restQualityCfg
            )
        }

        return StudyPredictionSet(
            sourceMode: .exportFeatureEmulator,
            valuesByMetric: [
                .recoveryScore: chargeByDay,
                .restScore: restByDay,
            ],
            revisionByMetric: [
                .recoveryScore: chargeRevision,
                .restScore: restRevision,
            ]
        )
    }

    private static func restScore(_ row: ExportFeatureDay) -> Double? {
        guard let asleep = row.totalSleepMinutes, asleep > 0 else { return nil }
        let efficiency: Double
        if let percent = row.sleepEfficiencyPercent {
            efficiency = min(1, max(0, percent / 100.0))
        } else if let inBed = row.inBedMinutes, inBed > 0 {
            efficiency = min(1, max(0, asleep / inBed))
        } else {
            return nil
        }
        let deep = max(0, row.deepSleepMinutes ?? 0)
        let rem = max(0, row.remSleepMinutes ?? 0)
        return AnalyticsEngine.Rest.composite(
            tstSeconds: asleep * 60,
            inBedSeconds: (row.inBedMinutes ?? (asleep / max(efficiency, 0.01))) * 60,
            efficiency: efficiency,
            restorativeSeconds: (deep + rem) * 60,
            needHours: AnalyticsEngine.Rest.defaultNeedHours,
            consistency: nil,
            deepSeconds: deep * 60
        )
    }
}
