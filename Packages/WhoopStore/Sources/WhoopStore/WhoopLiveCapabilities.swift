import Foundation

/// Metrics NOOP can honestly derive from a live WHOOP connection without a cloud/CSV import.
/// Calibrated SpO2 percentage is intentionally absent: the decoded WHOOP optical values are raw ADC,
/// and converting those to a percentage would require a validated calibration curve we do not have.
/// Steps are also absent: the reverse-engineered motion counter is not a validated pedometer.
public enum WhoopLiveCapabilities {
    public static let base: Set<Metric> = [.hr, .hrv, .skinTemp, .sleep, .strainLoad]

    public static func metrics(forModel model: String) -> Set<Metric> {
        _ = model
        return base
    }

    public static func encoded(forModel model: String) -> String {
        metrics(forModel: model).map(\.rawValue).sorted().joined(separator: ",")
    }

    public static func withoutUnvalidatedLiveMetrics(
        _ capabilities: Set<Metric>
    ) -> Set<Metric> {
        capabilities.subtracting([.spo2, .steps])
    }

    public static func stripUnvalidatedLiveTokens(
        fromEncoded encoded: String
    ) -> String {
        let rejected = Set([Metric.spo2.rawValue, Metric.steps.rawValue])
        return encoded.split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !rejected.contains($0) }
            .joined(separator: ",")
    }

    /// Retained for the historical migration that removed only the SpO2 token.
    public static func withoutCalibratedSpo2(_ capabilities: Set<Metric>) -> Set<Metric> {
        capabilities.subtracting([.spo2])
    }

    /// Retained for the historical migration that removed only the SpO2 token.
    public static func stripSpo2Token(fromEncoded encoded: String) -> String {
        encoded.split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != Metric.spo2.rawValue }
            .joined(separator: ",")
    }
}
