import Foundation
import WhoopStore

/// Calendar-aware adapter from cached daily rows to `IllnessSignalEngine`.
///
/// Each signal gets its own freshness and baseline check. Missing calendar days stay missing, a stale
/// metric cannot borrow freshness from another metric, and an untrusted metric cannot contribute to the
/// score. This is still a wellness pattern detector, not a health-status or diagnostic assessment.
public enum IllnessSignalPipeline {
    public static let maximumSignalAgeDays = 2
    public static let recentWindowDays = 2
    public static let baselineGapDays = 1
    public static let baselineWindowDays = 28

    public struct MetricAssessment: Equatable, Sendable {
        public let reading: IllnessSignalEngine.SignalReading
        public let baselineTrusted: Bool
        public let latestDay: String
        public let recentMean: Double
        public let baseline: Double?
        public let delta: Double?
        public let ratio: Double?

        public init(reading: IllnessSignalEngine.SignalReading,
                    baselineTrusted: Bool,
                    latestDay: String,
                    recentMean: Double,
                    baseline: Double?,
                    delta: Double?,
                    ratio: Double?) {
            self.reading = reading
            self.baselineTrusted = baselineTrusted
            self.latestDay = latestDay
            self.recentMean = recentMean
            self.baseline = baseline
            self.delta = delta
            self.ratio = ratio
        }
    }

    public struct Prepared: Equatable, Sendable {
        public let restingHR: MetricAssessment?
        public let skinTemp: VitalBands.SkinTempIllnessAssessment?
        public let skinTempLatestDay: String?
        public let hrv: MetricAssessment?
        public let respiration: MetricAssessment?

        public var inputs: IllnessSignalEngine.Inputs {
            IllnessSignalEngine.Inputs(
                restingHR: restingHR?.reading,
                skinTemp: skinTemp.map {
                    IllnessSignalEngine.SignalReading(
                        zIllnessward: $0.reading.zIllnessward,
                        present: $0.reading.present && $0.baselineTrusted
                    )
                },
                hrv: hrv?.reading,
                respiration: respiration?.reading
            )
        }

        /// Number of fresh signals backed by their own trusted baseline. This is intentionally independent
        /// of whether a signal is anomalous; a normal trusted reading still proves calibration.
        public var trustedSignalCount: Int {
            [
                restingHR?.reading.present == true,
                skinTemp?.reading.present == true && skinTemp?.baselineTrusted == true,
                hrv?.reading.present == true,
                respiration?.reading.present == true,
            ].filter { $0 }.count
        }

        public var baselineTrusted: Bool {
            trustedSignalCount >= IllnessSignalEngine.minCorroboratingSignals
        }

        public var firedLabels: [String: String] {
            var labels: [String: String] = [:]
            if let value = restingHR,
               value.reading.present,
               let delta = value.delta,
               delta > 0 {
                labels["restingHR"] = "RHR +\(Int(delta.rounded()))"
            }
            if let value = skinTemp,
               value.reading.present,
               value.baselineTrusted,
               let delta = value.deltaFromBaselineC,
               delta > 0 {
                labels["skinTemp"] = "skin temp +\(String(format: "%.1f", delta)) °C"
            }
            if let value = hrv,
               value.reading.present,
               let ratio = value.ratio,
               ratio < 0 {
                labels["hrv"] = "HRV -\(Int((-ratio * 100).rounded()))%"
            }
            if respiration?.reading.present == true {
                labels["respiration"] = "respiration up"
            }
            return labels
        }

        public var distanceFeatures: IllnessDistance.FeatureVector {
            IllnessDistance.FeatureVector(
                restingHR: restingHR?.reading.present == true
                    ? restingHR?.reading.zIllnessward : nil,
                rmssd: hrv?.reading.present == true ? hrv?.reading.zIllnessward : nil,
                skinTemp: skinTemp?.reading.present == true && skinTemp?.baselineTrusted == true
                    ? skinTemp?.reading.zIllnessward : nil,
                respiration: respiration?.reading.present == true
                    ? respiration?.reading.zIllnessward : nil
            )
        }
    }

    /// Prepare the freshest usable reading for each signal against an exact calendar baseline window.
    /// A newer malformed/non-finite value makes that signal unavailable rather than silently falling back
    /// to an older value.
    public static func prepare(days: [DailyMetric], todayKey: String) -> Prepared {
        guard let today = Baselines.isoEpochDay(todayKey) else {
            return Prepared(restingHR: nil, skinTemp: nil, skinTempLatestDay: nil,
                            hrv: nil, respiration: nil)
        }

        var rowsByEpoch: [Int: DailyMetric] = [:]
        for row in days {
            guard let epoch = Baselines.isoEpochDay(row.day), epoch <= today else { continue }
            rowsByEpoch[epoch] = row
        }

        let restingHR = metricAssessment(
            rowsByEpoch: rowsByEpoch,
            today: today,
            selector: { $0.restingHr.map(Double.init) },
            cfg: Baselines.restingHRCfg,
            illnessUp: true
        )
        let hrv = metricAssessment(
            rowsByEpoch: rowsByEpoch,
            today: today,
            selector: \.avgHrv,
            cfg: Baselines.hrvCfg,
            illnessUp: false
        )
        let respiration = metricAssessment(
            rowsByEpoch: rowsByEpoch,
            today: today,
            selector: \.respRateBpm,
            cfg: Baselines.respCfg,
            illnessUp: true
        )
        let skin = skinAssessment(rowsByEpoch: rowsByEpoch, today: today)

        return Prepared(
            restingHR: restingHR,
            skinTemp: skin?.assessment,
            skinTempLatestDay: skin?.latestDay,
            hrv: hrv,
            respiration: respiration
        )
    }

    private static func metricAssessment(
        rowsByEpoch: [Int: DailyMetric],
        today: Int,
        selector: (DailyMetric) -> Double?,
        cfg: MetricCfg,
        illnessUp: Bool
    ) -> MetricAssessment? {
        guard let latest = latestRawValue(
            rowsByEpoch: rowsByEpoch,
            today: today,
            selector: selector
        ) else { return nil }
        guard today - latest.epoch <= maximumSignalAgeDays,
              latest.value.isFinite,
              cfg.minVal <= latest.value,
              latest.value <= cfg.maxVal else { return nil }

        let recent = ((latest.epoch - recentWindowDays + 1)...latest.epoch).compactMap {
            validValue(rowsByEpoch[$0].flatMap(selector), cfg: cfg)
        }
        guard !recent.isEmpty else { return nil }
        let recentMean = recent.reduce(0, +) / Double(recent.count)

        let baselineEnd = latest.epoch - recentWindowDays - baselineGapDays
        let baselineStart = baselineEnd - baselineWindowDays + 1
        let history: [Double?] = (baselineStart...baselineEnd).map {
            validValue(rowsByEpoch[$0].flatMap(selector), cfg: cfg)
        }
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard state.usable else {
            return MetricAssessment(
                reading: .init(zIllnessward: 0, present: false),
                baselineTrusted: false,
                latestDay: latest.day,
                recentMean: recentMean,
                baseline: nil,
                delta: nil,
                ratio: nil
            )
        }

        let deviation = Baselines.deviation(recentMean, state: state)
        guard deviation.z.isFinite, deviation.delta.isFinite, deviation.ratio.isFinite else {
            return nil
        }
        return MetricAssessment(
            reading: .init(
                zIllnessward: illnessUp ? deviation.z : -deviation.z,
                present: state.trusted
            ),
            baselineTrusted: state.trusted,
            latestDay: latest.day,
            recentMean: recentMean,
            baseline: state.baseline,
            delta: deviation.delta,
            ratio: deviation.ratio
        )
    }

    private static func skinAssessment(
        rowsByEpoch: [Int: DailyMetric],
        today: Int
    ) -> (assessment: VitalBands.SkinTempIllnessAssessment, latestDay: String)? {
        guard let latest = latestRawValue(
            rowsByEpoch: rowsByEpoch,
            today: today,
            selector: \.skinTempDevC
        ), today - latest.epoch <= maximumSignalAgeDays,
           validSkinValue(latest.value) else { return nil }

        let recent: [Double?] = ((latest.epoch - recentWindowDays + 1)...latest.epoch).map {
            rowsByEpoch[$0]?.skinTempDevC
        }
        let baselineEnd = latest.epoch - recentWindowDays - baselineGapDays
        let baselineStart = baselineEnd - baselineWindowDays + 1
        let baseline: [Double?] = (baselineStart...baselineEnd).map {
            rowsByEpoch[$0]?.skinTempDevC
        }
        guard let assessment = VitalBands.skinTempIllnessAssessment(
            recent: recent,
            baseline: baseline
        ) else { return nil }
        return (assessment, latest.day)
    }

    private static func latestRawValue(
        rowsByEpoch: [Int: DailyMetric],
        today: Int,
        selector: (DailyMetric) -> Double?
    ) -> (epoch: Int, day: String, value: Double)? {
        for epoch in rowsByEpoch.keys.filter({ $0 <= today }).sorted(by: >) {
            guard let row = rowsByEpoch[epoch], let value = selector(row) else { continue }
            return (epoch, row.day, value)
        }
        return nil
    }

    private static func validValue(_ value: Double?, cfg: MetricCfg) -> Double? {
        guard let value, value.isFinite, cfg.minVal <= value, value <= cfg.maxVal else {
            return nil
        }
        return value
    }

    private static func validSkinValue(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        if VitalBands.isAbsoluteSkinTemp(value) {
            guard let cfg = Baselines.metricCfg["skin_temp"] else { return false }
            return cfg.minVal <= value && value <= cfg.maxVal
        }
        return VitalBands.skinTempDeviation(from: value) != nil
    }
}
