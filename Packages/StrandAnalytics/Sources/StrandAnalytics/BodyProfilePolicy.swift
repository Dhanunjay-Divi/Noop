import Foundation

/// Why optional weight-target progress is or is not suitable for the current profile.
///
/// This is a product-safety gate, not a diagnosis. NOOP never chooses a target or a
/// rate of change. Unsupported cases retain the user's stored preference but suppress
/// progress language until the inputs are suitable for the adult screening context.
public enum BodyWeightTargetAvailability: String, Equatable, Sendable {
    case available
    case measurementsUnconfirmed
    case adultScreeningUnavailable
    case currentWeightNeedsClinicalContext
    case targetNeedsClinicalContext
    case invalidMeasurement
}

/// Conservative policy for BMI display and optional user-selected weight targets.
///
/// Adult BMI is a limited height-and-weight screening calculation. Ages below 20
/// require age- and sex-specific interpretation, so this policy deliberately does not
/// expose the adult calculation for them.
public enum BodyProfilePolicy {
    public static let adultMinimumAge = 20
    public static let minimumAdultScreeningBMI = 18.5

    private static let plausibleWeightKg = 20.0...400.0
    private static let plausibleHeightCm = 100.0...250.0
    private static let plausibleBMI = 5.0...100.0

    public static func adultBMI(
        age: Int,
        weightKg: Double,
        heightCm: Double,
        measurementsConfirmed: Bool
    ) -> Double? {
        guard measurementsConfirmed,
              age >= adultMinimumAge,
              weightKg.isFinite,
              heightCm.isFinite,
              plausibleWeightKg.contains(weightKg),
              plausibleHeightCm.contains(heightCm) else { return nil }
        let metres = heightCm / 100
        let bmi = weightKg / (metres * metres)
        return bmi.isFinite && plausibleBMI.contains(bmi) ? bmi : nil
    }

    public static func targetAvailability(
        age: Int,
        currentWeightKg: Double,
        heightCm: Double,
        targetWeightKg: Double?,
        measurementsConfirmed: Bool
    ) -> BodyWeightTargetAvailability {
        guard measurementsConfirmed else { return .measurementsUnconfirmed }
        guard age >= adultMinimumAge else { return .adultScreeningUnavailable }
        guard let currentBMI = adultBMI(
            age: age,
            weightKg: currentWeightKg,
            heightCm: heightCm,
            measurementsConfirmed: true
        ) else { return .invalidMeasurement }
        guard currentBMI >= minimumAdultScreeningBMI else {
            return .currentWeightNeedsClinicalContext
        }
        guard let targetWeightKg else { return .available }
        guard let targetBMI = adultBMI(
            age: age,
            weightKg: targetWeightKg,
            heightCm: heightCm,
            measurementsConfirmed: true
        ) else { return .invalidMeasurement }
        return targetBMI >= minimumAdultScreeningBMI
            ? .available
            : .targetNeedsClinicalContext
    }
}
