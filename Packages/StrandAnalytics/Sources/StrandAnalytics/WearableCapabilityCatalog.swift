/// Pure evidence contract for wearable acquisition. It is not a UI feature list, accuracy claim,
/// or medical claim. The Kotlin twin lives in `com.noop.analytics.WearableCapabilityCatalog`.
public enum WearableSource: String, CaseIterable, Sendable {
    case whoop4
    case whoop5
    case whoopMG
    case ouraRing4
    case ringConnGen3
    case humeBand2
    case appleWatch
}

public enum WearableAcquisitionLane: String, CaseIterable, Sendable {
    case directBLE
    case vendorCloud
    case healthKitBridge
    case healthConnectBridge
    case fileImport
}

/// Vendor documentation is evidence that a lane exists, not evidence that NOOP implements it.
public enum AcquisitionAvailability: String, CaseIterable, Sendable {
    case vendorDocumented
    case projectSupported
    case experimental
    case unavailable
}

public enum WearableMetric: String, CaseIterable, Sendable {
    case heartRate
    case rrIntervals
    case heartRateVariability
    case bloodOxygen
    case respiratoryRate
    case skinTemperature
    case wristTemperature
    case motion
    case opticalWaveform
    case steps
    case sleepStages
    case workouts
    case vo2Max
    case recoveryScore
    case strainScore
    case readinessScore
    case biologicalAge
    case ecgPackets
    case ecgInterpretation
    case bloodPressure
}

/// Provenance of one metric on one acquisition lane. Missing rows fail closed to `unsupported`.
public enum MetricCapabilityState: String, CaseIterable, Sendable {
    case measuredSignal
    case deviceDerived
    case vendorDerivedOnly
    case bridgeImported
    case notExposed
    case unsupported

    public var isExposed: Bool {
        switch self {
        case .measuredSignal, .deviceDerived, .bridgeImported: return true
        case .vendorDerivedOnly, .notExposed, .unsupported: return false
        }
    }
}

public enum WearableCapabilityConstraint: String, CaseIterable, Sendable {
    case reverseEngineeredBLE
    case singleCentralOwnership
    case directBLERequiresHardwareValidation
    case noPublicBLEProtocol
    case vendorCloudAccountRequired
    case vendorAppSyncRequired
    case bridgeSyncCanLag
    case bridgeOmitsVendorMetrics
    case bridgeCategoriesRequireDeviceValidation
    case healthKitEntitlementRequired
    case healthKitPerTypeConsentRequired
    case metricRequiresCompatibleDevice
    case backgroundDeliveryNotGuaranteed
    case hrvBridgeUsesSDNN
    case wristTemperatureIsPeripheral
    case vo2MaxIsEstimated
    case fileSchemaCanChange
    case firmwareSchemaCanChange
    case rawOpticalIsNotBloodOxygen
    case rawTemperatureRequiresCalibration
    case bandSleepStateIsNotFullStaging
    case vendorScoresRemainDistinct
    case ecgPacketAcquisitionExperimental
    case ecgInterpretationUnsupported
    case vascularTrendIsNotBloodPressure
    case bodyCompositionRequiresSeparateDevice
    case vendorDocumentationConflicts
    case bloodPressureUnsupported
}

public struct WearableCapabilityContract: Sendable, Equatable {
    public let source: WearableSource
    public let acquisition: [WearableAcquisitionLane: AcquisitionAvailability]
    public let metricCapabilities: [WearableMetric: [WearableAcquisitionLane: MetricCapabilityState]]
    public let constraints: Set<WearableCapabilityConstraint>

    public init(
        source: WearableSource,
        acquisition: [WearableAcquisitionLane: AcquisitionAvailability],
        metricCapabilities: [WearableMetric: [WearableAcquisitionLane: MetricCapabilityState]],
        constraints: Set<WearableCapabilityConstraint> = []
    ) {
        self.source = source
        self.acquisition = acquisition
        self.metricCapabilities = metricCapabilities
        self.constraints = constraints
    }

    public func availability(for lane: WearableAcquisitionLane) -> AcquisitionAvailability {
        acquisition[lane] ?? .unavailable
    }

    public func state(
        for metric: WearableMetric,
        via lane: WearableAcquisitionLane
    ) -> MetricCapabilityState {
        metricCapabilities[metric]?[lane] ?? .unsupported
    }

    /// A narrow implementation predicate: vendor-documented and experimental lanes do not count.
    public func hasProjectSupportedPath(for metric: WearableMetric) -> Bool {
        guard let perLane = metricCapabilities[metric] else { return false }
        return perLane.contains { lane, state in
            availability(for: lane) == .projectSupported && state.isExposed
        }
    }
}

public enum WearableCapabilityCatalog {
    public static let all: [WearableCapabilityContract] = [
        WearableCapabilityContract(
            source: .whoop4,
            acquisition: lanes(.projectSupported, .vendorDocumented, .vendorDocumented,
                               .unavailable, .projectSupported),
            metricCapabilities: matrix(
                (.heartRate, .directBLE, .deviceDerived),
                (.rrIntervals, .directBLE, .deviceDerived),
                (.bloodOxygen, .directBLE, .notExposed),
                (.respiratoryRate, .directBLE, .notExposed),
                (.skinTemperature, .directBLE, .measuredSignal),
                (.motion, .directBLE, .measuredSignal),
                (.steps, .directBLE, .notExposed),
                (.sleepStages, .directBLE, .deviceDerived),
                (.heartRateVariability, .fileImport, .bridgeImported),
                (.bloodOxygen, .fileImport, .bridgeImported),
                (.respiratoryRate, .fileImport, .bridgeImported),
                (.steps, .fileImport, .bridgeImported),
                (.workouts, .fileImport, .bridgeImported),
                (.recoveryScore, .fileImport, .bridgeImported),
                (.strainScore, .fileImport, .bridgeImported)
            ),
            constraints: [.reverseEngineeredBLE, .singleCentralOwnership,
                          .rawOpticalIsNotBloodOxygen, .rawTemperatureRequiresCalibration,
                          .fileSchemaCanChange,
                          .vendorScoresRemainDistinct, .bloodPressureUnsupported]
        ),
        WearableCapabilityContract(
            source: .whoop5,
            acquisition: lanes(.experimental, .vendorDocumented, .vendorDocumented,
                               .unavailable, .projectSupported),
            metricCapabilities: whoop5Matrix(includeECG: false),
            constraints: whoop5Constraints(includeECG: false)
        ),
        WearableCapabilityContract(
            source: .whoopMG,
            acquisition: lanes(.experimental, .vendorDocumented, .vendorDocumented,
                               .unavailable, .projectSupported),
            metricCapabilities: whoop5Matrix(includeECG: true),
            constraints: whoop5Constraints(includeECG: true)
        ),
        WearableCapabilityContract(
            source: .ouraRing4,
            acquisition: lanes(.experimental, .vendorDocumented, .vendorDocumented,
                               .vendorDocumented, .projectSupported),
            metricCapabilities: matrix(
                (.heartRate, .directBLE, .deviceDerived),
                (.rrIntervals, .directBLE, .deviceDerived),
                (.heartRateVariability, .directBLE, .deviceDerived),
                (.bloodOxygen, .directBLE, .deviceDerived),
                (.skinTemperature, .directBLE, .measuredSignal),
                (.motion, .directBLE, .measuredSignal),
                (.sleepStages, .directBLE, .deviceDerived),
                (.heartRate, .vendorCloud, .bridgeImported),
                (.heartRateVariability, .vendorCloud, .bridgeImported),
                (.bloodOxygen, .vendorCloud, .bridgeImported),
                (.respiratoryRate, .vendorCloud, .bridgeImported),
                (.skinTemperature, .vendorCloud, .bridgeImported),
                (.steps, .vendorCloud, .bridgeImported),
                (.sleepStages, .vendorCloud, .bridgeImported),
                (.workouts, .vendorCloud, .bridgeImported),
                (.vo2Max, .vendorCloud, .bridgeImported),
                (.readinessScore, .vendorCloud, .bridgeImported),
                (.heartRate, .fileImport, .bridgeImported),
                (.heartRateVariability, .fileImport, .bridgeImported),
                (.steps, .fileImport, .bridgeImported),
                (.sleepStages, .fileImport, .bridgeImported),
                (.workouts, .fileImport, .bridgeImported),
                (.readinessScore, .fileImport, .bridgeImported)
            ),
            constraints: [.singleCentralOwnership, .directBLERequiresHardwareValidation,
                          .vendorCloudAccountRequired, .bridgeOmitsVendorMetrics,
                          .fileSchemaCanChange, .vendorScoresRemainDistinct,
                          .bloodPressureUnsupported]
        ),
        WearableCapabilityContract(
            source: .ringConnGen3,
            acquisition: lanes(.unavailable, .unavailable, .vendorDocumented,
                               .unavailable, .unavailable),
            metricCapabilities: matrix(
                (.heartRate, .healthKitBridge, .bridgeImported),
                (.bloodOxygen, .healthKitBridge, .bridgeImported),
                (.steps, .healthKitBridge, .bridgeImported),
                (.sleepStages, .healthKitBridge, .bridgeImported),
                (.heartRate, .directBLE, .notExposed),
                (.rrIntervals, .directBLE, .notExposed),
                (.bloodOxygen, .directBLE, .notExposed),
                (.skinTemperature, .directBLE, .notExposed),
                (.motion, .directBLE, .notExposed),
                (.heartRateVariability, .vendorCloud, .vendorDerivedOnly),
                (.respiratoryRate, .vendorCloud, .vendorDerivedOnly),
                (.readinessScore, .vendorCloud, .vendorDerivedOnly)
            ),
            constraints: [.noPublicBLEProtocol, .vendorAppSyncRequired, .bridgeSyncCanLag,
                          .bridgeOmitsVendorMetrics, .vendorScoresRemainDistinct,
                          .vascularTrendIsNotBloodPressure, .vendorDocumentationConflicts,
                          .bloodPressureUnsupported]
        ),
        WearableCapabilityContract(
            source: .humeBand2,
            acquisition: lanes(.unavailable, .unavailable, .vendorDocumented,
                               .unavailable, .unavailable),
            metricCapabilities: matrix(
                (.heartRate, .healthKitBridge, .notExposed),
                (.heartRateVariability, .healthKitBridge, .notExposed),
                (.bloodOxygen, .healthKitBridge, .notExposed),
                (.skinTemperature, .healthKitBridge, .notExposed),
                (.steps, .healthKitBridge, .notExposed),
                (.sleepStages, .healthKitBridge, .notExposed),
                (.heartRate, .directBLE, .notExposed),
                (.rrIntervals, .directBLE, .notExposed),
                (.bloodOxygen, .directBLE, .notExposed),
                (.skinTemperature, .directBLE, .notExposed),
                (.motion, .directBLE, .notExposed),
                (.recoveryScore, .vendorCloud, .vendorDerivedOnly),
                (.strainScore, .vendorCloud, .vendorDerivedOnly),
                (.readinessScore, .vendorCloud, .vendorDerivedOnly),
                (.biologicalAge, .vendorCloud, .vendorDerivedOnly)
            ),
            constraints: [.noPublicBLEProtocol, .vendorAppSyncRequired, .bridgeSyncCanLag,
                          .bridgeCategoriesRequireDeviceValidation, .bridgeOmitsVendorMetrics,
                          .bodyCompositionRequiresSeparateDevice, .vendorDocumentationConflicts,
                          .vendorScoresRemainDistinct, .bloodPressureUnsupported]
        ),
        WearableCapabilityContract(
            source: .appleWatch,
            acquisition: lanes(.unavailable, .unavailable, .projectSupported,
                               .unavailable, .projectSupported),
            metricCapabilities: matrix(
                (.heartRate, .healthKitBridge, .bridgeImported),
                (.heartRateVariability, .healthKitBridge, .bridgeImported),
                (.bloodOxygen, .healthKitBridge, .bridgeImported),
                (.respiratoryRate, .healthKitBridge, .bridgeImported),
                (.wristTemperature, .healthKitBridge, .bridgeImported),
                (.steps, .healthKitBridge, .bridgeImported),
                (.sleepStages, .healthKitBridge, .bridgeImported),
                (.workouts, .healthKitBridge, .bridgeImported),
                (.vo2Max, .healthKitBridge, .bridgeImported),
                (.heartRate, .fileImport, .bridgeImported),
                (.heartRateVariability, .fileImport, .bridgeImported),
                (.steps, .fileImport, .bridgeImported),
                (.sleepStages, .fileImport, .bridgeImported),
                (.workouts, .fileImport, .bridgeImported),
                (.vo2Max, .fileImport, .bridgeImported),
                (.heartRate, .directBLE, .notExposed),
                (.rrIntervals, .directBLE, .notExposed),
                (.motion, .directBLE, .notExposed)
            ),
            constraints: [.healthKitEntitlementRequired, .healthKitPerTypeConsentRequired,
                          .metricRequiresCompatibleDevice, .bridgeSyncCanLag,
                          .backgroundDeliveryNotGuaranteed, .hrvBridgeUsesSDNN,
                          .wristTemperatureIsPeripheral, .vo2MaxIsEstimated,
                          .bloodPressureUnsupported]
        ),
    ]

    public static func contract(for source: WearableSource) -> WearableCapabilityContract? {
        all.first { $0.source == source }
    }

    private static func lanes(
        _ directBLE: AcquisitionAvailability,
        _ vendorCloud: AcquisitionAvailability,
        _ healthKitBridge: AcquisitionAvailability,
        _ healthConnectBridge: AcquisitionAvailability,
        _ fileImport: AcquisitionAvailability
    ) -> [WearableAcquisitionLane: AcquisitionAvailability] {
        [.directBLE: directBLE, .vendorCloud: vendorCloud, .healthKitBridge: healthKitBridge,
         .healthConnectBridge: healthConnectBridge, .fileImport: fileImport]
    }

    private static func matrix(
        _ rows: (WearableMetric, WearableAcquisitionLane, MetricCapabilityState)...
    ) -> [WearableMetric: [WearableAcquisitionLane: MetricCapabilityState]] {
        var result: [WearableMetric: [WearableAcquisitionLane: MetricCapabilityState]] = [:]
        for (metric, lane, state) in rows { result[metric, default: [:]][lane] = state }
        return result
    }

    private static func whoop5Matrix(
        includeECG: Bool
    ) -> [WearableMetric: [WearableAcquisitionLane: MetricCapabilityState]] {
        var result = matrix(
            (.heartRate, .directBLE, .deviceDerived),
            (.rrIntervals, .directBLE, .deviceDerived),
            (.bloodOxygen, .directBLE, .notExposed),
            (.respiratoryRate, .directBLE, .notExposed),
            (.skinTemperature, .directBLE, .measuredSignal),
            (.motion, .directBLE, .measuredSignal),
            (.opticalWaveform, .directBLE, .measuredSignal),
            (.steps, .directBLE, .deviceDerived),
            (.sleepStages, .directBLE, .deviceDerived),
            (.heartRate, .fileImport, .bridgeImported),
            (.heartRateVariability, .fileImport, .bridgeImported),
            (.bloodOxygen, .fileImport, .bridgeImported),
            (.respiratoryRate, .fileImport, .bridgeImported),
            (.skinTemperature, .fileImport, .bridgeImported),
            (.steps, .fileImport, .bridgeImported),
            (.sleepStages, .fileImport, .bridgeImported),
            (.workouts, .fileImport, .bridgeImported),
            (.recoveryScore, .fileImport, .bridgeImported),
            (.strainScore, .fileImport, .bridgeImported)
        )
        if includeECG { result[.ecgPackets, default: [:]][.directBLE] = .measuredSignal }
        return result
    }

    private static func whoop5Constraints(includeECG: Bool) -> Set<WearableCapabilityConstraint> {
        var result: Set<WearableCapabilityConstraint> = [
            .reverseEngineeredBLE, .singleCentralOwnership, .directBLERequiresHardwareValidation,
            .firmwareSchemaCanChange, .rawOpticalIsNotBloodOxygen,
            .rawTemperatureRequiresCalibration,
            .bandSleepStateIsNotFullStaging, .fileSchemaCanChange,
            .vendorScoresRemainDistinct, .bloodPressureUnsupported,
        ]
        if includeECG {
            result.formUnion([.ecgPacketAcquisitionExperimental, .ecgInterpretationUnsupported])
        }
        return result
    }
}
