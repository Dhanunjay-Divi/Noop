package com.noop.bandsdk

object BandContractLimits {
    const val OPAQUE_HANDLE_LENGTH = 128
    const val SOURCE_IDENTITY_LENGTH = 128
    const val REVISION_LENGTH = 64
    const val CURSOR_LENGTH = 256
    const val ACKNOWLEDGEMENT_TOKEN_LENGTH = 256
    const val SAMPLES_PER_BATCH = 4_096
    const val BATCHES_PER_HISTORY_CHUNK = 256
    const val SAMPLES_PER_HISTORY_CHUNK = 16_384
}

enum class BandCapability(val wireValue: String) {
    BATTERY("battery"),
    CHARGING("charging"),
    WEAR_STATE("wear_state"),
    STEPS("steps"),
    DISTANCE("distance"),
    CALORIES("calories"),
    HEART_RATE("heart_rate"),
    RR_INTERVALS("rr_intervals"),
    SLEEP("sleep"),
    SPO2("spo2"),
    RESPIRATION("respiration"),
    TEMPERATURE("temperature"),
    STRESS("stress"),
    WORKOUT_HISTORY("workout_history"),
    RAW_PPG("raw_ppg"),
    ACCELEROMETER("accelerometer"),
    GYROSCOPE("gyroscope"),
    HAPTICS("haptics"),
    ALARMS("alarms"),
    WEATHER("weather"),
    FIRMWARE_UPDATE("firmware_update"),
}

enum class BandSessionState(val wireValue: String) {
    IDLE("idle"),
    SCANNING("scanning"),
    CANDIDATE_SELECTED("candidateSelected"),
    CONNECTING("connecting"),
    AUTHENTICATING("authenticating"),
    NEGOTIATING_CAPABILITIES("negotiatingCapabilities"),
    READY("ready"),
    LIVE_COLLECTING("liveCollecting"),
    HISTORY_COLLECTING("historyCollecting"),
    EXECUTING_COMMAND("executingCommand"),
    UPDATING_FIRMWARE("updatingFirmware"),
    RECOVERING("recovering"),
    DISCONNECTING("disconnecting"),
    CLOSED("closed"),
    INCOMPATIBLE("incompatible"),
    REJECTED("rejected"),
    SECURITY_FAILURE("securityFailure"),
}

enum class BandFailureCategory(val wireValue: String) {
    UNAVAILABLE("unavailable"),
    PERMISSION("permission"),
    NO_RESULT("noResult"),
    TIMEOUT("timeout"),
    REJECTED("rejected"),
    INCOMPATIBLE("incompatible"),
    AUTHENTICATION("authentication"),
    STALE_CALLBACK("staleCallback"),
    DISCONNECTED("disconnected"),
    STORAGE("storage"),
    HISTORY_STALLED("historyStalled"),
    LOW_BATTERY("lowBattery"),
    UPDATE_NOT_ELIGIBLE("updateNotEligible"),
    UPDATE_INTERRUPTED("updateInterrupted"),
    UPDATE_VERIFICATION("updateVerification"),
    BUSY("busy"),
    INVALID_STATE("invalidState"),
    INVALID_INPUT("invalidInput"),
    UNSUPPORTED("unsupported"),
    CLOSED("closed"),
    INTERNAL_FAILURE("internalFailure"),
}

class BandException(
    val category: BandFailureCategory,
) : Exception(category.wireValue)

enum class BandOperationClass {
    HISTORY,
    BATTERY,
    WEAR_STATE,
    HAPTIC,
    ALARM,
    SAMPLING,
    FIRMWARE,
}

enum class BandProvenanceLane {
    LIVE,
    HISTORY,
}

enum class BandStreamKind {
    HEART_RATE,
    RR_INTERVAL,
    STEPS,
    SPO2,
    RESPIRATION,
    TEMPERATURE,
    ACCELERATION,
}

enum class BandUnit {
    BEATS_PER_MINUTE,
    MILLISECONDS,
    COUNT,
    PERCENT,
    BREATHS_PER_MINUTE,
    CELSIUS,
    GRAVITY,
}

enum class BandSampleQuality {
    ACCEPTED,
    DEGRADED,
    REJECTED,
}

data class BandPairingCandidate(
    val handle: String,
    val compatible: Boolean,
    val identifyEligible: Boolean,
) {
    fun validate() {
        if (
            handle.isEmpty() ||
            handle.length > BandContractLimits.OPAQUE_HANDLE_LENGTH
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

data class BandIdentity(
    val sourceIdentity: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
    val protocolVersion: String,
    val wrapperRevision: String,
) {
    fun validate() {
        if (
            sourceIdentity.isEmpty() ||
            sourceIdentity.length > BandContractLimits.SOURCE_IDENTITY_LENGTH ||
            hardwareRevision.isEmpty() ||
            hardwareRevision.length > 32 ||
            firmwareVersion.isEmpty() ||
            firmwareVersion.length > BandContractLimits.REVISION_LENGTH ||
            protocolVersion.isEmpty() ||
            protocolVersion.length > 32 ||
            wrapperRevision.isEmpty() ||
            wrapperRevision.length > BandContractLimits.REVISION_LENGTH
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

data class BandCapabilityReport(
    val schemaVersion: Int,
    val protocolVersion: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
    val historyDays: Int,
    val capabilities: Set<BandCapability>,
) {
    fun validate() {
        if (
            schemaVersion != SUPPORTED_SCHEMA_VERSION ||
            protocolVersion != SUPPORTED_PROTOCOL_VERSION ||
            hardwareRevision.isEmpty() ||
            hardwareRevision.length > 32 ||
            firmwareVersion.isEmpty() ||
            firmwareVersion.length > 64 ||
            historyDays !in 0..255 ||
            capabilities.isEmpty()
        ) {
            fail(BandFailureCategory.INCOMPATIBLE)
        }
    }

    companion object {
        const val SUPPORTED_SCHEMA_VERSION = 1
        const val SUPPORTED_PROTOCOL_VERSION = "noop-band-v1"
    }
}

data class BandSampleIdentity(
    val stream: BandStreamKind,
    val sequence: Long,
    val deviceTimeMilliseconds: Long,
)

data class BandSample(
    val identity: BandSampleIdentity,
    val value: Double,
    val unit: BandUnit,
    val quality: BandSampleQuality,
) {
    fun validate() {
        if (
            identity.sequence < 0 ||
            !value.isFinite() ||
            quality == BandSampleQuality.REJECTED
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val valid = when (identity.stream) {
            BandStreamKind.HEART_RATE ->
                unit == BandUnit.BEATS_PER_MINUTE && value in 20.0..260.0
            BandStreamKind.RR_INTERVAL ->
                unit == BandUnit.MILLISECONDS && value in 200.0..3_000.0
            BandStreamKind.STEPS ->
                unit == BandUnit.COUNT && value in 0.0..1_000_000.0
            BandStreamKind.SPO2 ->
                unit == BandUnit.PERCENT && value in 50.0..100.0
            BandStreamKind.RESPIRATION ->
                unit == BandUnit.BREATHS_PER_MINUTE && value in 2.0..80.0
            BandStreamKind.TEMPERATURE ->
                unit == BandUnit.CELSIUS && value in -20.0..60.0
            BandStreamKind.ACCELERATION ->
                unit == BandUnit.GRAVITY && value in -32.0..32.0
        }
        if (!valid) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

data class BandSampleBatch(
    val sourceIdentity: String,
    val lane: BandProvenanceLane,
    val parserRevision: String,
    val calibrationRevision: String,
    val samples: List<BandSample>,
) {
    fun validate(expectedLane: BandProvenanceLane) {
        if (
            lane != expectedLane ||
            sourceIdentity.isEmpty() ||
            sourceIdentity.length > BandContractLimits.SOURCE_IDENTITY_LENGTH ||
            parserRevision.isEmpty() ||
            parserRevision.length > BandContractLimits.REVISION_LENGTH ||
            calibrationRevision.isEmpty() ||
            calibrationRevision.length > BandContractLimits.REVISION_LENGTH ||
            samples.isEmpty() ||
            samples.size > BandContractLimits.SAMPLES_PER_BATCH
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        samples.forEach(BandSample::validate)
    }
}

data class BandHistoryChunk(
    val chunkIdentity: String,
    val previousCursor: String?,
    val nextCursor: String?,
    val complete: Boolean,
    val overflowed: Boolean,
    val acknowledgementToken: String,
    val batches: List<BandSampleBatch>,
) {
    fun validate() {
        if (
            chunkIdentity.isEmpty() ||
            chunkIdentity.length > BandContractLimits.OPAQUE_HANDLE_LENGTH ||
            previousCursor?.let {
                it.isEmpty() || it.length > BandContractLimits.CURSOR_LENGTH
            } == true ||
            nextCursor?.let {
                it.isEmpty() || it.length > BandContractLimits.CURSOR_LENGTH
            } == true ||
            acknowledgementToken.isEmpty() ||
            acknowledgementToken.length >
            BandContractLimits.ACKNOWLEDGEMENT_TOKEN_LENGTH ||
            batches.size > BandContractLimits.BATCHES_PER_HISTORY_CHUNK ||
            batches.sumOf { it.samples.size } >
            BandContractLimits.SAMPLES_PER_HISTORY_CHUNK
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        batches.forEach { it.validate(BandProvenanceLane.HISTORY) }
    }
}

data class BandOperationToken(
    val generation: Long,
    val sequence: Long,
    val operationClass: BandOperationClass,
)

data class HistoryAcceptance(
    val chunkIdentity: String,
    val acknowledgementToken: String,
    val nextCursor: String?,
    val acceptedSamples: Int,
    val duplicateSamples: Int,
)

data class DurableHistoryReceipt(
    val chunkIdentity: String,
    val acknowledgementToken: String,
    val nextCursor: String?,
    val committedSamples: Int,
    val committed: Boolean,
)

data class BandSessionSnapshot(
    val state: BandSessionState,
    val generation: Long,
    val activeOperation: BandOperationClass?,
    val liveActive: Boolean,
    val acknowledgedHistoryCursor: String?,
    val durableSampleCount: Int,
)

internal fun fail(category: BandFailureCategory): Nothing {
    throw BandException(category)
}
