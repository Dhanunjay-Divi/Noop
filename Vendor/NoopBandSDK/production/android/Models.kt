package com.noop.bandsdk

import java.util.Collections
import java.util.UUID

object BandContractLimits {
    const val OPAQUE_HANDLE_LENGTH = 128
    const val SOURCE_IDENTITY_LENGTH = 128
    const val REVISION_LENGTH = 64
    const val CURSOR_LENGTH = 256
    const val ACKNOWLEDGEMENT_TOKEN_LENGTH = 256
    const val SAMPLES_PER_BATCH = 4_096
    const val BATCHES_PER_HISTORY_CHUNK = 256
    const val SAMPLES_PER_HISTORY_CHUNK = 16_384
    const val HISTORY_CHECKPOINT_IDENTITIES = 65_536
    const val MAXIMUM_SAMPLE_SEQUENCE = Long.MAX_VALUE
    const val MINIMUM_DEVICE_TIME_MILLISECONDS = 0L
}

private fun String.hasValidUtf8Length(
    maximum: Int,
    allowEmpty: Boolean = false,
): Boolean {
    if (!allowEmpty && isEmpty()) {
        return false
    }
    var bytes = 0
    var index = 0
    while (index < length) {
        val codeUnit = this[index]
        val encodedBytes = when {
            codeUnit.code <= 0x7F -> 1
            codeUnit.code <= 0x7FF -> 2
            Character.isHighSurrogate(codeUnit) -> {
                if (
                    index + 1 >= length ||
                    !Character.isLowSurrogate(this[index + 1])
                ) {
                    return false
                }
                index += 1
                4
            }
            Character.isLowSurrogate(codeUnit) -> return false
            else -> 3
        }
        if (bytes > maximum - encodedBytes) {
            return false
        }
        bytes += encodedBytes
        index += 1
    }
    return true
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
    FIRMWARE_FAILURE("firmwareFailure"),
}

enum class BandConnectionPhase(val wireValue: String) {
    CONNECTION("connection"),
    AUTHENTICATION("authentication"),
}

enum class BandFailureCategory(val wireValue: String) {
    UNAVAILABLE("unavailable"),
    PERMISSION("permission"),
    NO_RESULT("noResult"),
    TIMEOUT("timeout"),
    REJECTED("rejected"),
    INCOMPATIBLE("incompatible"),
    AUTHENTICATION("authentication"),
    SECURITY_FAILURE("securityFailure"),
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

enum class BandFirmwareFailureDisposition {
    RECOVERABLE,
    TERMINAL,
}

enum class BandProvenanceLane {
    LIVE,
    HISTORY,
}

enum class BandStreamKind(val wireValue: String) {
    HEART_RATE("heartRate"),
    RR_INTERVAL("rrInterval"),
    STEPS("steps"),
    SPO2("spo2"),
    RESPIRATION("respiration"),
    TEMPERATURE("temperature"),
    ACCELERATION("acceleration"),
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
            !handle.hasValidUtf8Length(BandContractLimits.OPAQUE_HANDLE_LENGTH)
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

class BandConnectionToken internal constructor(
    internal val sessionNonce: UUID,
    internal val generation: Long,
    internal val sequence: Long,
    internal val candidateHandle: String,
)

data class BandIdentity(
    val sourceIdentity: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
    val protocolVersion: String,
    val wrapperRevision: String,
) {
    fun validate() {
        if (
            !sourceIdentity.hasValidUtf8Length(
                BandContractLimits.SOURCE_IDENTITY_LENGTH,
            ) ||
            !hardwareRevision.hasValidUtf8Length(32) ||
            !firmwareVersion.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            !protocolVersion.hasValidUtf8Length(32) ||
            !wrapperRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            )
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
    val liveStreams: Set<BandStreamKind>,
    val historyStreams: Set<BandStreamKind>,
) {
    fun validate() {
        if (
            schemaVersion != SUPPORTED_SCHEMA_VERSION ||
            protocolVersion != SUPPORTED_PROTOCOL_VERSION ||
            !hardwareRevision.hasValidUtf8Length(32) ||
            !firmwareVersion.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            historyDays !in 0..255 ||
            capabilities.isEmpty() ||
            (historyStreams.isNotEmpty() && historyDays == 0) ||
            (liveStreams + historyStreams).any {
                requiredCapability(it) !in capabilities
            }
        ) {
            fail(BandFailureCategory.INCOMPATIBLE)
        }
    }

    internal fun immutableSnapshot(): BandCapabilityReport = copy(
        capabilities = capabilities.boundedSnapshot(
            BandCapability.entries.size,
        ),
        liveStreams = liveStreams.boundedSnapshot(
            BandStreamKind.entries.size,
        ),
        historyStreams = historyStreams.boundedSnapshot(
            BandStreamKind.entries.size,
        ),
    )

    companion object {
        const val SUPPORTED_SCHEMA_VERSION = 2
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
            identity.deviceTimeMilliseconds <
            BandContractLimits.MINIMUM_DEVICE_TIME_MILLISECONDS ||
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
                unit == BandUnit.COUNT &&
                    value in 0.0..1_000_000.0 &&
                    value % 1.0 == 0.0
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
            !sourceIdentity.hasValidUtf8Length(
                BandContractLimits.SOURCE_IDENTITY_LENGTH,
            ) ||
            !parserRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            !calibrationRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            samples.isEmpty() ||
            samples.size > BandContractLimits.SAMPLES_PER_BATCH
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        samples.forEach(BandSample::validate)
    }

    internal fun immutableSnapshot(
        maximumSamples: Int = BandContractLimits.SAMPLES_PER_BATCH,
    ): BandSampleBatch = copy(
        samples = samples.boundedSnapshot(
            minOf(
                BandContractLimits.SAMPLES_PER_BATCH,
                maximumSamples,
            ),
        ),
    )
}

data class BandHistoryRange(
    val startDeviceTimeMilliseconds: Long,
    val endDeviceTimeMilliseconds: Long,
) {
    fun validate() {
        if (
            startDeviceTimeMilliseconds <
            BandContractLimits.MINIMUM_DEVICE_TIME_MILLISECONDS ||
            endDeviceTimeMilliseconds < startDeviceTimeMilliseconds
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

data class BandHistoryChunk(
    val chunkIdentity: String,
    val previousCursor: String?,
    val nextCursor: String?,
    val complete: Boolean,
    val overflowed: Boolean,
    val retainedRange: BandHistoryRange?,
    val firstLostRange: BandHistoryRange?,
    val acknowledgementToken: String,
    val batches: List<BandSampleBatch>,
) {
    fun validate() {
        if (
            !chunkIdentity.hasValidUtf8Length(
                BandContractLimits.OPAQUE_HANDLE_LENGTH,
            ) ||
            previousCursor?.let {
                !it.hasValidUtf8Length(BandContractLimits.CURSOR_LENGTH)
            } ?: false ||
            nextCursor?.let {
                !it.hasValidUtf8Length(BandContractLimits.CURSOR_LENGTH)
            } ?: false ||
            !acknowledgementToken.hasValidUtf8Length(
                BandContractLimits.ACKNOWLEDGEMENT_TOKEN_LENGTH,
            ) ||
            (overflowed && (
                retainedRange == null ||
                    firstLostRange == null
                )) ||
            (!overflowed && firstLostRange != null) ||
            batches.size > BandContractLimits.BATCHES_PER_HISTORY_CHUNK ||
            batches.sumOf { it.samples.size } >
            BandContractLimits.SAMPLES_PER_HISTORY_CHUNK
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        retainedRange?.validate()
        firstLostRange?.validate()
        batches.forEach { it.validate(BandProvenanceLane.HISTORY) }
        if (overflowed) {
            val retained = retainedRange
                ?: fail(BandFailureCategory.INVALID_INPUT)
            val lost = firstLostRange
                ?: fail(BandFailureCategory.INVALID_INPUT)
            if (
                lost.endDeviceTimeMilliseconds >=
                retained.startDeviceTimeMilliseconds ||
                batches.any { batch ->
                    batch.samples.any { sample ->
                        sample.identity.deviceTimeMilliseconds !in
                            retained.startDeviceTimeMilliseconds..
                            retained.endDeviceTimeMilliseconds
                    }
                }
            ) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
        }
    }

    internal fun immutableSnapshot(): BandHistoryChunk {
        val immutableBatches = batches.boundedSnapshot(
            BandContractLimits.BATCHES_PER_HISTORY_CHUNK,
        )
        var remainingSamples = BandContractLimits.SAMPLES_PER_HISTORY_CHUNK
        return copy(
            batches = immutableBatches.map { batch ->
                batch.immutableSnapshot(remainingSamples).also {
                    remainingSamples -= it.samples.size
                }
            },
        )
    }
}

private fun <T> List<T>.boundedSnapshot(maximumSize: Int): List<T> {
    val expectedSize = size
    if (maximumSize < 0 || expectedSize < 0 || expectedSize > maximumSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    val snapshot = ArrayList<T>(expectedSize)
    try {
        val iterator = iterator()
        while (iterator.hasNext()) {
            if (snapshot.size == maximumSize) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
            snapshot += iterator.next()
        }
    } catch (error: BandException) {
        throw error
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (snapshot.size != expectedSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    return snapshot
}

private fun <T> Set<T>.boundedSnapshot(maximumSize: Int): Set<T> {
    val expectedSize = try {
        size
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (maximumSize < 0 || expectedSize < 0 || expectedSize > maximumSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    val snapshot = LinkedHashSet<T>(expectedSize)
    try {
        val iterator = iterator()
        while (iterator.hasNext()) {
            if (snapshot.size == maximumSize) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
            snapshot += iterator.next()
        }
    } catch (error: BandException) {
        throw error
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (snapshot.size != expectedSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    return snapshot
}

data class BandHistoryCheckpoint(
    val sourceIdentity: String,
    val acknowledgedCursor: String?,
    val lastHistoryComplete: Boolean?,
    val durableSampleIdentities: Set<BandSampleIdentity>,
) {
    fun validate() {
        if (
            !sourceIdentity.hasValidUtf8Length(
                BandContractLimits.SOURCE_IDENTITY_LENGTH,
            ) ||
            acknowledgedCursor?.let {
                !it.hasValidUtf8Length(BandContractLimits.CURSOR_LENGTH)
            } ?: false ||
            durableSampleIdentities.size >
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES ||
            durableSampleIdentities.any {
                it.sequence < 0 ||
                    it.deviceTimeMilliseconds <
                    BandContractLimits.MINIMUM_DEVICE_TIME_MILLISECONDS
            }
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }

    internal fun immutableSnapshot(): BandHistoryCheckpoint = copy(
        durableSampleIdentities = durableSampleIdentities.boundedSnapshot(
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES,
        ),
    )
}

class BandOperationToken internal constructor(
    internal val sessionNonce: UUID,
    internal val generation: Long,
    internal val sequence: Long,
    internal val operationClass: BandOperationClass,
) {
    override fun toString(): String = "BandOperationToken"
}

class LiveAcceptance internal constructor(
    acceptedSamples: List<BandSample>,
    val duplicateSamples: Int,
    internal val sessionNonce: UUID,
    internal val generation: Long,
    internal val receiptSequence: Long,
) {
    val acceptedSamples: List<BandSample> =
        Collections.unmodifiableList(ArrayList(acceptedSamples))

    override fun toString(): String = "LiveAcceptance"
}

class AcceptedHistorySample internal constructor(
    val sourceIdentity: String,
    val lane: BandProvenanceLane,
    val parserRevision: String,
    val calibrationRevision: String,
    val sample: BandSample,
) {
    override fun toString(): String = "AcceptedHistorySample"
}

class DurableLiveReceipt(
    acceptance: LiveAcceptance,
    val committedSamples: Int,
    val committed: Boolean,
) {
    internal val sessionNonce: UUID = acceptance.sessionNonce
    internal val generation: Long = acceptance.generation
    internal val receiptSequence: Long = acceptance.receiptSequence

    override fun toString(): String = "DurableLiveReceipt"
}

class HistoryAcceptance internal constructor(
    val chunkIdentity: String,
    val acknowledgementToken: String,
    val nextCursor: String?,
    val complete: Boolean,
    val overflowed: Boolean,
    val retainedRange: BandHistoryRange?,
    val firstLostRange: BandHistoryRange?,
    acceptedSamples: List<AcceptedHistorySample>,
    val duplicateSamples: Int,
    internal val sessionNonce: UUID,
    internal val receiptSequence: Long,
) {
    val acceptedSamples: List<AcceptedHistorySample> =
        Collections.unmodifiableList(ArrayList(acceptedSamples))

    override fun toString(): String = "HistoryAcceptance"
}

class DurableHistoryReceipt(
    acceptance: HistoryAcceptance,
    val historyStateCommitted: Boolean,
    val committedSamples: Int,
    val committed: Boolean,
) {
    val chunkIdentity: String = acceptance.chunkIdentity
    val acknowledgementToken: String = acceptance.acknowledgementToken
    val nextCursor: String? = acceptance.nextCursor
    val complete: Boolean = acceptance.complete
    val overflowed: Boolean = acceptance.overflowed
    val retainedRange: BandHistoryRange? = acceptance.retainedRange
    val firstLostRange: BandHistoryRange? = acceptance.firstLostRange
    internal val sessionNonce: UUID = acceptance.sessionNonce
    internal val receiptSequence: Long = acceptance.receiptSequence

    override fun toString(): String = "DurableHistoryReceipt"
}

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

internal fun requiredCapability(
    stream: BandStreamKind,
): BandCapability = when (stream) {
    BandStreamKind.HEART_RATE -> BandCapability.HEART_RATE
    BandStreamKind.RR_INTERVAL -> BandCapability.RR_INTERVALS
    BandStreamKind.STEPS -> BandCapability.STEPS
    BandStreamKind.SPO2 -> BandCapability.SPO2
    BandStreamKind.RESPIRATION -> BandCapability.RESPIRATION
    BandStreamKind.TEMPERATURE -> BandCapability.TEMPERATURE
    BandStreamKind.ACCELERATION -> BandCapability.ACCELEROMETER
}
