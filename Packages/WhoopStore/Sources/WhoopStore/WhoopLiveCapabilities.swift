import Foundation

/// Metrics NOOP can honestly derive from a live WHOOP connection without a cloud/CSV import.
/// Calibrated SpO2 percentage is intentionally absent: the decoded WHOOP optical values are raw ADC,
/// and converting those to a percentage would require a validated calibration curve we do not have.
public enum WhoopLiveCapabilities {
    public static let base: Set<Metric> = [.hr, .hrv, .skinTemp, .sleep, .strainLoad]

    public static func isFiveOrMG(model: String) -> Bool {
        let value = model.lowercased()
        return value.contains("5") || value.contains("mg")
    }

    public static func metrics(forModel model: String) -> Set<Metric> {
        var result = base
        if isFiveOrMG(model: model) { result.insert(.steps) }
        return result
    }

    public static func encoded(forModel model: String) -> String {
        metrics(forModel: model).map(\.rawValue).sorted().joined(separator: ",")
    }

    public static func withoutCalibratedSpo2(_ capabilities: Set<Metric>) -> Set<Metric> {
        capabilities.subtracting([.spo2])
    }

    public static func stripSpo2Token(fromEncoded encoded: String) -> String {
        encoded.split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != Metric.spo2.rawValue }
            .joined(separator: ",")
    }
}
