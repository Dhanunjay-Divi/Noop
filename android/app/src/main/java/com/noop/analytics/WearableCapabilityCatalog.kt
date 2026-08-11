package com.noop.analytics

/** Pure Kotlin twin of StrandAnalytics/WearableCapabilityCatalog.swift. */
enum class WearableSource(val id: String) {
    WHOOP4("whoop4"), WHOOP5("whoop5"), WHOOP_MG("whoopMG"), OURA_RING4("ouraRing4"),
    RINGCONN_GEN3("ringConnGen3"), HUME_BAND2("humeBand2"), APPLE_WATCH("appleWatch"),
}

enum class WearableAcquisitionLane(val id: String) {
    DIRECT_BLE("directBLE"), VENDOR_CLOUD("vendorCloud"), HEALTH_KIT_BRIDGE("healthKitBridge"),
    HEALTH_CONNECT_BRIDGE("healthConnectBridge"), FILE_IMPORT("fileImport"),
}

/** Vendor documentation is evidence that a lane exists, not evidence that NOOP implements it. */
enum class AcquisitionAvailability(val id: String) {
    VENDOR_DOCUMENTED("vendorDocumented"), PROJECT_SUPPORTED("projectSupported"),
    EXPERIMENTAL("experimental"), UNAVAILABLE("unavailable"),
}

enum class WearableMetric(val id: String) {
    HEART_RATE("heartRate"), RR_INTERVALS("rrIntervals"),
    HEART_RATE_VARIABILITY("heartRateVariability"), BLOOD_OXYGEN("bloodOxygen"),
    RESPIRATORY_RATE("respiratoryRate"), SKIN_TEMPERATURE("skinTemperature"),
    WRIST_TEMPERATURE("wristTemperature"), MOTION("motion"),
    OPTICAL_WAVEFORM("opticalWaveform"), STEPS("steps"), SLEEP_STAGES("sleepStages"),
    WORKOUTS("workouts"), VO2_MAX("vo2Max"), RECOVERY_SCORE("recoveryScore"),
    STRAIN_SCORE("strainScore"), READINESS_SCORE("readinessScore"),
    BIOLOGICAL_AGE("biologicalAge"), ECG_PACKETS("ecgPackets"),
    ECG_INTERPRETATION("ecgInterpretation"), BLOOD_PRESSURE("bloodPressure"),
}

/** Provenance of one metric on one acquisition lane. Missing rows fail closed to UNSUPPORTED. */
enum class MetricCapabilityState(val id: String) {
    MEASURED_SIGNAL("measuredSignal"), DEVICE_DERIVED("deviceDerived"),
    VENDOR_DERIVED_ONLY("vendorDerivedOnly"), BRIDGE_IMPORTED("bridgeImported"),
    NOT_EXPOSED("notExposed"), UNSUPPORTED("unsupported");

    val isExposed: Boolean
        get() = this == MEASURED_SIGNAL || this == DEVICE_DERIVED || this == BRIDGE_IMPORTED
}

enum class WearableCapabilityConstraint(val id: String) {
    REVERSE_ENGINEERED_BLE("reverseEngineeredBLE"),
    SINGLE_CENTRAL_OWNERSHIP("singleCentralOwnership"),
    DIRECT_BLE_REQUIRES_HARDWARE_VALIDATION("directBLERequiresHardwareValidation"),
    NO_PUBLIC_BLE_PROTOCOL("noPublicBLEProtocol"),
    VENDOR_CLOUD_ACCOUNT_REQUIRED("vendorCloudAccountRequired"),
    VENDOR_APP_SYNC_REQUIRED("vendorAppSyncRequired"),
    BRIDGE_SYNC_CAN_LAG("bridgeSyncCanLag"),
    BRIDGE_OMITS_VENDOR_METRICS("bridgeOmitsVendorMetrics"),
    BRIDGE_CATEGORIES_REQUIRE_DEVICE_VALIDATION("bridgeCategoriesRequireDeviceValidation"),
    HEALTH_KIT_ENTITLEMENT_REQUIRED("healthKitEntitlementRequired"),
    HEALTH_KIT_PER_TYPE_CONSENT_REQUIRED("healthKitPerTypeConsentRequired"),
    METRIC_REQUIRES_COMPATIBLE_DEVICE("metricRequiresCompatibleDevice"),
    BACKGROUND_DELIVERY_NOT_GUARANTEED("backgroundDeliveryNotGuaranteed"),
    HRV_BRIDGE_USES_SDNN("hrvBridgeUsesSDNN"),
    WRIST_TEMPERATURE_IS_PERIPHERAL("wristTemperatureIsPeripheral"),
    VO2_MAX_IS_ESTIMATED("vo2MaxIsEstimated"),
    FILE_SCHEMA_CAN_CHANGE("fileSchemaCanChange"),
    FIRMWARE_SCHEMA_CAN_CHANGE("firmwareSchemaCanChange"),
    RAW_OPTICAL_IS_NOT_BLOOD_OXYGEN("rawOpticalIsNotBloodOxygen"),
    RAW_TEMPERATURE_REQUIRES_CALIBRATION("rawTemperatureRequiresCalibration"),
    BAND_SLEEP_STATE_IS_NOT_FULL_STAGING("bandSleepStateIsNotFullStaging"),
    VENDOR_SCORES_REMAIN_DISTINCT("vendorScoresRemainDistinct"),
    ECG_PACKET_ACQUISITION_EXPERIMENTAL("ecgPacketAcquisitionExperimental"),
    ECG_INTERPRETATION_UNSUPPORTED("ecgInterpretationUnsupported"),
    VASCULAR_TREND_IS_NOT_BLOOD_PRESSURE("vascularTrendIsNotBloodPressure"),
    BODY_COMPOSITION_REQUIRES_SEPARATE_DEVICE("bodyCompositionRequiresSeparateDevice"),
    VENDOR_DOCUMENTATION_CONFLICTS("vendorDocumentationConflicts"),
    BLOOD_PRESSURE_UNSUPPORTED("bloodPressureUnsupported"),
}

data class WearableCapabilityContract(
    val source: WearableSource,
    val acquisition: Map<WearableAcquisitionLane, AcquisitionAvailability>,
    val metricCapabilities: Map<WearableMetric, Map<WearableAcquisitionLane, MetricCapabilityState>>,
    val constraints: Set<WearableCapabilityConstraint> = emptySet(),
) {
    fun availability(lane: WearableAcquisitionLane): AcquisitionAvailability =
        acquisition[lane] ?: AcquisitionAvailability.UNAVAILABLE

    fun state(metric: WearableMetric, lane: WearableAcquisitionLane): MetricCapabilityState =
        metricCapabilities[metric]?.get(lane) ?: MetricCapabilityState.UNSUPPORTED

    /** Vendor-documented and experimental lanes deliberately do not count. */
    fun hasProjectSupportedPath(metric: WearableMetric): Boolean =
        metricCapabilities[metric]?.any { (lane, state) ->
            availability(lane) == AcquisitionAvailability.PROJECT_SUPPORTED && state.isExposed
        } == true
}

object WearableCapabilityCatalog {
    val all: List<WearableCapabilityContract> = listOf(
        WearableCapabilityContract(
            WearableSource.WHOOP4,
            lanes(Availability.P, Availability.V, Availability.V, Availability.U, Availability.P),
            matrix(
                row(Metric.HR, Lane.BLE, State.D), row(Metric.RR, Lane.BLE, State.D),
                row(Metric.SPO2, Lane.BLE, State.N), row(Metric.RESP, Lane.BLE, State.N),
                row(Metric.TEMP, Lane.BLE, State.M), row(Metric.MOTION, Lane.BLE, State.M),
                row(Metric.STEPS, Lane.BLE, State.N), row(Metric.SLEEP, Lane.BLE, State.D),
                row(Metric.HRV, Lane.FILE, State.B), row(Metric.SPO2, Lane.FILE, State.B),
                row(Metric.RESP, Lane.FILE, State.B), row(Metric.STEPS, Lane.FILE, State.B),
                row(Metric.WORKOUTS, Lane.FILE, State.B),
                row(Metric.RECOVERY, Lane.FILE, State.B), row(Metric.STRAIN, Lane.FILE, State.B),
            ),
            setOf(Constraint.RE, Constraint.SINGLE, Constraint.RAW_OPTICAL,
                Constraint.RAW_TEMP, Constraint.FILE,
                Constraint.SCORES, Constraint.BP),
        ),
        WearableCapabilityContract(
            WearableSource.WHOOP5,
            lanes(Availability.E, Availability.V, Availability.V, Availability.U, Availability.P),
            whoop5Matrix(false), whoop5Constraints(false),
        ),
        WearableCapabilityContract(
            WearableSource.WHOOP_MG,
            lanes(Availability.E, Availability.V, Availability.V, Availability.U, Availability.P),
            whoop5Matrix(true), whoop5Constraints(true),
        ),
        WearableCapabilityContract(
            WearableSource.OURA_RING4,
            lanes(Availability.E, Availability.V, Availability.V, Availability.V, Availability.P),
            matrix(
                row(Metric.HR, Lane.BLE, State.D), row(Metric.RR, Lane.BLE, State.D),
                row(Metric.HRV, Lane.BLE, State.D), row(Metric.SPO2, Lane.BLE, State.D),
                row(Metric.TEMP, Lane.BLE, State.M), row(Metric.MOTION, Lane.BLE, State.M),
                row(Metric.SLEEP, Lane.BLE, State.D),
                row(Metric.HR, Lane.CLOUD, State.B), row(Metric.HRV, Lane.CLOUD, State.B),
                row(Metric.SPO2, Lane.CLOUD, State.B), row(Metric.RESP, Lane.CLOUD, State.B),
                row(Metric.TEMP, Lane.CLOUD, State.B), row(Metric.STEPS, Lane.CLOUD, State.B),
                row(Metric.SLEEP, Lane.CLOUD, State.B), row(Metric.WORKOUTS, Lane.CLOUD, State.B),
                row(Metric.VO2, Lane.CLOUD, State.B), row(Metric.READINESS, Lane.CLOUD, State.B),
                row(Metric.HR, Lane.FILE, State.B), row(Metric.HRV, Lane.FILE, State.B),
                row(Metric.STEPS, Lane.FILE, State.B), row(Metric.SLEEP, Lane.FILE, State.B),
                row(Metric.WORKOUTS, Lane.FILE, State.B), row(Metric.READINESS, Lane.FILE, State.B),
            ),
            setOf(Constraint.SINGLE, Constraint.HARDWARE, Constraint.CLOUD_ACCOUNT,
                Constraint.OMITS, Constraint.FILE, Constraint.SCORES, Constraint.BP),
        ),
        WearableCapabilityContract(
            WearableSource.RINGCONN_GEN3,
            lanes(Availability.U, Availability.U, Availability.V, Availability.U, Availability.U),
            matrix(
                row(Metric.HR, Lane.HK, State.B), row(Metric.SPO2, Lane.HK, State.B),
                row(Metric.STEPS, Lane.HK, State.B), row(Metric.SLEEP, Lane.HK, State.B),
                row(Metric.HR, Lane.BLE, State.N), row(Metric.RR, Lane.BLE, State.N),
                row(Metric.SPO2, Lane.BLE, State.N), row(Metric.TEMP, Lane.BLE, State.N),
                row(Metric.MOTION, Lane.BLE, State.N),
                row(Metric.HRV, Lane.CLOUD, State.V), row(Metric.RESP, Lane.CLOUD, State.V),
                row(Metric.READINESS, Lane.CLOUD, State.V),
            ),
            setOf(Constraint.NO_BLE, Constraint.APP_SYNC, Constraint.LAG, Constraint.OMITS,
                Constraint.SCORES, Constraint.VASCULAR, Constraint.CONFLICTS, Constraint.BP),
        ),
        WearableCapabilityContract(
            WearableSource.HUME_BAND2,
            lanes(Availability.U, Availability.U, Availability.V, Availability.U, Availability.U),
            matrix(
                row(Metric.HR, Lane.HK, State.N), row(Metric.HRV, Lane.HK, State.N),
                row(Metric.SPO2, Lane.HK, State.N), row(Metric.TEMP, Lane.HK, State.N),
                row(Metric.STEPS, Lane.HK, State.N), row(Metric.SLEEP, Lane.HK, State.N),
                row(Metric.HR, Lane.BLE, State.N), row(Metric.RR, Lane.BLE, State.N),
                row(Metric.SPO2, Lane.BLE, State.N), row(Metric.TEMP, Lane.BLE, State.N),
                row(Metric.MOTION, Lane.BLE, State.N),
                row(Metric.RECOVERY, Lane.CLOUD, State.V), row(Metric.STRAIN, Lane.CLOUD, State.V),
                row(Metric.READINESS, Lane.CLOUD, State.V), row(Metric.AGE, Lane.CLOUD, State.V),
            ),
            setOf(Constraint.NO_BLE, Constraint.APP_SYNC, Constraint.LAG, Constraint.CATEGORIES,
                Constraint.OMITS, Constraint.POD, Constraint.CONFLICTS, Constraint.SCORES, Constraint.BP),
        ),
        WearableCapabilityContract(
            WearableSource.APPLE_WATCH,
            lanes(Availability.U, Availability.U, Availability.P, Availability.U, Availability.P),
            matrix(
                row(Metric.HR, Lane.HK, State.B), row(Metric.HRV, Lane.HK, State.B),
                row(Metric.SPO2, Lane.HK, State.B), row(Metric.RESP, Lane.HK, State.B),
                row(Metric.WRIST_TEMP, Lane.HK, State.B), row(Metric.STEPS, Lane.HK, State.B),
                row(Metric.SLEEP, Lane.HK, State.B), row(Metric.WORKOUTS, Lane.HK, State.B),
                row(Metric.VO2, Lane.HK, State.B),
                row(Metric.HR, Lane.FILE, State.B), row(Metric.HRV, Lane.FILE, State.B),
                row(Metric.STEPS, Lane.FILE, State.B), row(Metric.SLEEP, Lane.FILE, State.B),
                row(Metric.WORKOUTS, Lane.FILE, State.B), row(Metric.VO2, Lane.FILE, State.B),
                row(Metric.HR, Lane.BLE, State.N), row(Metric.RR, Lane.BLE, State.N),
                row(Metric.MOTION, Lane.BLE, State.N),
            ),
            setOf(Constraint.HK_ENTITLEMENT, Constraint.HK_CONSENT, Constraint.COMPATIBLE,
                Constraint.LAG, Constraint.BACKGROUND, Constraint.SDNN,
                Constraint.WRIST, Constraint.VO2_ESTIMATE, Constraint.BP),
        ),
    )

    fun contract(source: WearableSource): WearableCapabilityContract? = all.firstOrNull { it.source == source }

    private fun lanes(
        ble: AcquisitionAvailability, cloud: AcquisitionAvailability,
        healthKit: AcquisitionAvailability, healthConnect: AcquisitionAvailability,
        file: AcquisitionAvailability,
    ) = mapOf(Lane.BLE to ble, Lane.CLOUD to cloud, Lane.HK to healthKit,
        Lane.HC to healthConnect, Lane.FILE to file)

    private data class Row(val metric: WearableMetric, val lane: WearableAcquisitionLane,
                           val state: MetricCapabilityState)
    private fun row(metric: WearableMetric, lane: WearableAcquisitionLane,
                    state: MetricCapabilityState) = Row(metric, lane, state)
    private fun matrix(vararg rows: Row): Map<WearableMetric, Map<WearableAcquisitionLane, MetricCapabilityState>> =
        rows.groupBy { it.metric }.mapValues { (_, values) -> values.associate { it.lane to it.state } }

    private fun whoop5Matrix(includeEcg: Boolean): Map<WearableMetric, Map<WearableAcquisitionLane, MetricCapabilityState>> {
        val rows = mutableListOf(
            row(Metric.HR, Lane.BLE, State.D), row(Metric.RR, Lane.BLE, State.D),
            row(Metric.SPO2, Lane.BLE, State.N), row(Metric.RESP, Lane.BLE, State.N),
            row(Metric.TEMP, Lane.BLE, State.M), row(Metric.MOTION, Lane.BLE, State.M),
            row(Metric.OPTICAL, Lane.BLE, State.M), row(Metric.STEPS, Lane.BLE, State.D),
            row(Metric.SLEEP, Lane.BLE, State.D),
            row(Metric.HR, Lane.FILE, State.B), row(Metric.HRV, Lane.FILE, State.B),
            row(Metric.SPO2, Lane.FILE, State.B), row(Metric.RESP, Lane.FILE, State.B),
            row(Metric.TEMP, Lane.FILE, State.B), row(Metric.STEPS, Lane.FILE, State.B),
            row(Metric.SLEEP, Lane.FILE, State.B), row(Metric.WORKOUTS, Lane.FILE, State.B),
            row(Metric.RECOVERY, Lane.FILE, State.B), row(Metric.STRAIN, Lane.FILE, State.B),
        )
        if (includeEcg) rows += row(Metric.ECG, Lane.BLE, State.M)
        return matrix(*rows.toTypedArray())
    }

    private fun whoop5Constraints(includeEcg: Boolean): Set<WearableCapabilityConstraint> {
        val result = mutableSetOf(Constraint.RE, Constraint.SINGLE, Constraint.HARDWARE,
            Constraint.FIRMWARE, Constraint.RAW_OPTICAL, Constraint.RAW_TEMP,
            Constraint.BAND_SLEEP, Constraint.FILE,
            Constraint.SCORES, Constraint.BP)
        if (includeEcg) result += setOf(Constraint.ECG_EXPERIMENTAL, Constraint.ECG_UNSUPPORTED)
        return result
    }

    private object Availability {
        val V = AcquisitionAvailability.VENDOR_DOCUMENTED
        val P = AcquisitionAvailability.PROJECT_SUPPORTED
        val E = AcquisitionAvailability.EXPERIMENTAL
        val U = AcquisitionAvailability.UNAVAILABLE
    }
    private object Lane {
        val BLE = WearableAcquisitionLane.DIRECT_BLE; val CLOUD = WearableAcquisitionLane.VENDOR_CLOUD
        val HK = WearableAcquisitionLane.HEALTH_KIT_BRIDGE; val HC = WearableAcquisitionLane.HEALTH_CONNECT_BRIDGE
        val FILE = WearableAcquisitionLane.FILE_IMPORT
    }
    private object State {
        val M = MetricCapabilityState.MEASURED_SIGNAL; val D = MetricCapabilityState.DEVICE_DERIVED
        val V = MetricCapabilityState.VENDOR_DERIVED_ONLY; val B = MetricCapabilityState.BRIDGE_IMPORTED
        val N = MetricCapabilityState.NOT_EXPOSED
    }
    private object Metric {
        val HR = WearableMetric.HEART_RATE; val RR = WearableMetric.RR_INTERVALS
        val HRV = WearableMetric.HEART_RATE_VARIABILITY; val SPO2 = WearableMetric.BLOOD_OXYGEN
        val RESP = WearableMetric.RESPIRATORY_RATE; val TEMP = WearableMetric.SKIN_TEMPERATURE
        val WRIST_TEMP = WearableMetric.WRIST_TEMPERATURE; val MOTION = WearableMetric.MOTION
        val OPTICAL = WearableMetric.OPTICAL_WAVEFORM; val STEPS = WearableMetric.STEPS
        val SLEEP = WearableMetric.SLEEP_STAGES; val WORKOUTS = WearableMetric.WORKOUTS
        val VO2 = WearableMetric.VO2_MAX; val RECOVERY = WearableMetric.RECOVERY_SCORE
        val STRAIN = WearableMetric.STRAIN_SCORE; val READINESS = WearableMetric.READINESS_SCORE
        val AGE = WearableMetric.BIOLOGICAL_AGE; val ECG = WearableMetric.ECG_PACKETS
    }
    private object Constraint {
        val RE = WearableCapabilityConstraint.REVERSE_ENGINEERED_BLE
        val SINGLE = WearableCapabilityConstraint.SINGLE_CENTRAL_OWNERSHIP
        val HARDWARE = WearableCapabilityConstraint.DIRECT_BLE_REQUIRES_HARDWARE_VALIDATION
        val NO_BLE = WearableCapabilityConstraint.NO_PUBLIC_BLE_PROTOCOL
        val CLOUD_ACCOUNT = WearableCapabilityConstraint.VENDOR_CLOUD_ACCOUNT_REQUIRED
        val APP_SYNC = WearableCapabilityConstraint.VENDOR_APP_SYNC_REQUIRED
        val LAG = WearableCapabilityConstraint.BRIDGE_SYNC_CAN_LAG
        val OMITS = WearableCapabilityConstraint.BRIDGE_OMITS_VENDOR_METRICS
        val CATEGORIES = WearableCapabilityConstraint.BRIDGE_CATEGORIES_REQUIRE_DEVICE_VALIDATION
        val HK_ENTITLEMENT = WearableCapabilityConstraint.HEALTH_KIT_ENTITLEMENT_REQUIRED
        val HK_CONSENT = WearableCapabilityConstraint.HEALTH_KIT_PER_TYPE_CONSENT_REQUIRED
        val COMPATIBLE = WearableCapabilityConstraint.METRIC_REQUIRES_COMPATIBLE_DEVICE
        val BACKGROUND = WearableCapabilityConstraint.BACKGROUND_DELIVERY_NOT_GUARANTEED
        val SDNN = WearableCapabilityConstraint.HRV_BRIDGE_USES_SDNN
        val WRIST = WearableCapabilityConstraint.WRIST_TEMPERATURE_IS_PERIPHERAL
        val VO2_ESTIMATE = WearableCapabilityConstraint.VO2_MAX_IS_ESTIMATED
        val FILE = WearableCapabilityConstraint.FILE_SCHEMA_CAN_CHANGE
        val FIRMWARE = WearableCapabilityConstraint.FIRMWARE_SCHEMA_CAN_CHANGE
        val RAW_OPTICAL = WearableCapabilityConstraint.RAW_OPTICAL_IS_NOT_BLOOD_OXYGEN
        val RAW_TEMP = WearableCapabilityConstraint.RAW_TEMPERATURE_REQUIRES_CALIBRATION
        val BAND_SLEEP = WearableCapabilityConstraint.BAND_SLEEP_STATE_IS_NOT_FULL_STAGING
        val SCORES = WearableCapabilityConstraint.VENDOR_SCORES_REMAIN_DISTINCT
        val ECG_EXPERIMENTAL = WearableCapabilityConstraint.ECG_PACKET_ACQUISITION_EXPERIMENTAL
        val ECG_UNSUPPORTED = WearableCapabilityConstraint.ECG_INTERPRETATION_UNSUPPORTED
        val VASCULAR = WearableCapabilityConstraint.VASCULAR_TREND_IS_NOT_BLOOD_PRESSURE
        val POD = WearableCapabilityConstraint.BODY_COMPOSITION_REQUIRES_SEPARATE_DEVICE
        val CONFLICTS = WearableCapabilityConstraint.VENDOR_DOCUMENTATION_CONFLICTS
        val BP = WearableCapabilityConstraint.BLOOD_PRESSURE_UNSUPPORTED
    }
}
