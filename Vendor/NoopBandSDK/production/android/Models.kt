package com.noop.bandsdk

import java.security.MessageDigest
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

enum class BandDisconnectReason(val wireValue: String) {
    USER_PAUSED("userPaused"),
    COLLECTOR_HANDOFF("collectorHandoff"),
    TRANSPORT_REPLACED("transportReplaced"),
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

enum class BandOperationClass(val wireValue: String) {
    HISTORY("history"),
    BATTERY("battery"),
    WEAR_STATE("wearState"),
    HAPTIC("haptic"),
    ALARM("alarm"),
    SAMPLING("sampling"),
    FIRMWARE("firmware"),
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

enum class BandUnit(val wireValue: String) {
    BEATS_PER_MINUTE("beatsPerMinute"),
    MILLISECONDS("milliseconds"),
    COUNT("count"),
    PERCENT("percent"),
    BREATHS_PER_MINUTE("breathsPerMinute"),
    CELSIUS("celsius"),
    GRAVITY("gravity"),
}

internal fun requiredUnit(stream: BandStreamKind): BandUnit = when (stream) {
    BandStreamKind.HEART_RATE -> BandUnit.BEATS_PER_MINUTE
    BandStreamKind.RR_INTERVAL -> BandUnit.MILLISECONDS
    BandStreamKind.STEPS -> BandUnit.COUNT
    BandStreamKind.SPO2 -> BandUnit.PERCENT
    BandStreamKind.RESPIRATION -> BandUnit.BREATHS_PER_MINUTE
    BandStreamKind.TEMPERATURE -> BandUnit.CELSIUS
    BandStreamKind.ACCELERATION -> BandUnit.GRAVITY
}

enum class BandSampleQuality(val wireValue: String) {
    ACCEPTED("accepted"),
    DEGRADED("degraded"),
    REJECTED("rejected"),
}

enum class BandCadenceKind(val wireValue: String) {
    PERIODIC("periodic"),
    EVENT_DRIVEN("eventDriven"),
    AGGREGATE_WINDOW("aggregateWindow"),
}

enum class BandQualitySemantics(val wireValue: String) {
    ACCEPTED_OR_DEGRADED("acceptedOrDegraded"),
}

enum class BandTimestampSemantics(val wireValue: String) {
    DEVICE_MILLISECONDS("deviceMilliseconds"),
}

data class BandStreamSemantics(
    val lane: BandProvenanceLane,
    val stream: BandStreamKind,
    val unit: BandUnit,
    val cadence: BandCadenceKind,
    val nominalIntervalMilliseconds: Int?,
    val quality: BandQualitySemantics,
    val timestamp: BandTimestampSemantics,
    val parserRevision: String,
    val calibrationRevision: String,
) {
    fun validate() {
        val cadenceIsValid = when (cadence) {
            BandCadenceKind.EVENT_DRIVEN ->
                nominalIntervalMilliseconds == null
            BandCadenceKind.PERIODIC,
            BandCadenceKind.AGGREGATE_WINDOW,
            ->
                nominalIntervalMilliseconds in 1..86_400_000
        }
        if (
            unit != requiredUnit(stream) ||
            !cadenceIsValid ||
            !parserRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            !calibrationRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            )
        ) {
            fail(BandFailureCategory.INCOMPATIBLE)
        }
    }
}

data class BandPairingCandidate(
    val handle: String,
    val compatible: Boolean,
    val identifyEligible: Boolean,
) {
    override fun toString(): String =
        "BandPairingCandidate(" +
            "compatible=$compatible, " +
            "identifyEligible=$identifyEligible" +
            ")"

    fun validate() {
        if (
            !handle.hasValidUtf8Length(BandContractLimits.OPAQUE_HANDLE_LENGTH)
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }
}

class BandScanToken internal constructor(
    internal val sessionNonce: UUID,
    val generation: Long,
) {
    override fun toString(): String = "BandScanToken"
}

class BandConnectionToken internal constructor(
    internal val sessionNonce: UUID,
    internal val generation: Long,
    internal val sequence: Long,
    internal val candidateHandle: String,
) {
    override fun toString(): String = "BandConnectionToken"
}

class BandReconnectToken internal constructor(
    internal val sessionNonce: UUID,
    val generation: Long,
    internal val sequence: Long,
) {
    override fun toString(): String = "BandReconnectToken"
}

class BandLiveToken internal constructor(
    internal val sessionNonce: UUID,
    internal val generation: Long,
    internal val sequence: Long,
) {
    override fun toString(): String = "BandLiveToken"
}

data class BandIdentity(
    val sourceIdentity: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
    val protocolVersion: String,
    val wrapperRevision: String,
) {
    override fun toString(): String = "BandIdentity"

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
    val reportRevision: String,
    val protocolVersion: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
    val historyDays: Int,
    val capabilities: Set<BandCapability>,
    val liveStreams: Set<BandStreamKind>,
    val historyStreams: Set<BandStreamKind>,
    val operationsAllowedDuringLive: Set<BandOperationClass>,
    val streamSemantics: List<BandStreamSemantics>,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BandCapabilityReport) return false
        return schemaVersion == other.schemaVersion &&
            reportRevision == other.reportRevision &&
            protocolVersion == other.protocolVersion &&
            hardwareRevision == other.hardwareRevision &&
            firmwareVersion == other.firmwareVersion &&
            historyDays == other.historyDays &&
            capabilities == other.capabilities &&
            liveStreams == other.liveStreams &&
            historyStreams == other.historyStreams &&
            operationsAllowedDuringLive == other.operationsAllowedDuringLive &&
            streamSemanticFrequencies() ==
                other.streamSemanticFrequencies()
    }

    override fun hashCode(): Int {
        var result = schemaVersion
        result = 31 * result + reportRevision.hashCode()
        result = 31 * result + protocolVersion.hashCode()
        result = 31 * result + hardwareRevision.hashCode()
        result = 31 * result + firmwareVersion.hashCode()
        result = 31 * result + historyDays
        result = 31 * result + capabilities.hashCode()
        result = 31 * result + liveStreams.hashCode()
        result = 31 * result + historyStreams.hashCode()
        result = 31 * result + operationsAllowedDuringLive.hashCode()
        result = 31 * result + streamSemanticFrequencies().hashCode()
        return result
    }

    private fun streamSemanticFrequencies(): Map<BandStreamSemantics, Int> =
        streamSemantics.groupingBy { it }.eachCount()

    fun validate() {
        immutableSnapshot().validateSnapshot()
    }

    private fun validateSnapshot() {
        val expectedSemantics =
            liveStreams.map { BandStreamSemanticKey(BandProvenanceLane.LIVE, it) } +
                historyStreams.map {
                    BandStreamSemanticKey(BandProvenanceLane.HISTORY, it)
                }
        val actualSemantics = streamSemantics.map {
            BandStreamSemanticKey(it.lane, it.stream)
        }
        if (
            schemaVersion != SUPPORTED_SCHEMA_VERSION ||
            !reportRevision.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            protocolVersion != SUPPORTED_PROTOCOL_VERSION ||
            !hardwareRevision.hasValidUtf8Length(32) ||
            !firmwareVersion.hasValidUtf8Length(
                BandContractLimits.REVISION_LENGTH,
            ) ||
            historyDays !in 0..255 ||
            capabilities.isEmpty() ||
            (historyStreams.isNotEmpty() && historyDays == 0) ||
            BandOperationClass.FIRMWARE in operationsAllowedDuringLive ||
            actualSemantics.toSet().size != streamSemantics.size ||
            actualSemantics.toSet() != expectedSemantics.toSet() ||
            (liveStreams + historyStreams).any {
                requiredCapability(it) !in capabilities
            }
        ) {
            fail(BandFailureCategory.INCOMPATIBLE)
        }
        streamSemantics.forEach(BandStreamSemantics::validate)
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
        operationsAllowedDuringLive = operationsAllowedDuringLive.boundedSnapshot(
            BandOperationClass.entries.size,
        ),
        streamSemantics = streamSemantics.boundedSnapshot(
            BandStreamKind.entries.size * BandProvenanceLane.entries.size,
        ),
    )

    companion object {
        const val SUPPORTED_SCHEMA_VERSION = 3
        const val SUPPORTED_PROTOCOL_VERSION = "noop-band-v1"
        internal val MAXIMUM_STREAM_SEMANTICS =
            BandStreamKind.entries.size * BandProvenanceLane.entries.size

        internal fun virtualStreamSemantics(
            liveStreams: Set<BandStreamKind>,
            historyStreams: Set<BandStreamKind>,
        ): List<BandStreamSemantics> {
            fun semantics(
                lane: BandProvenanceLane,
                stream: BandStreamKind,
            ): BandStreamSemantics {
                val cadence: BandCadenceKind
                val nominalIntervalMilliseconds: Int?
                when (stream) {
                    BandStreamKind.RR_INTERVAL -> {
                        cadence = BandCadenceKind.EVENT_DRIVEN
                        nominalIntervalMilliseconds = null
                    }
                    BandStreamKind.STEPS -> {
                        cadence = BandCadenceKind.AGGREGATE_WINDOW
                        nominalIntervalMilliseconds = 60_000
                    }
                    BandStreamKind.ACCELERATION -> {
                        cadence = BandCadenceKind.PERIODIC
                        nominalIntervalMilliseconds = 40
                    }
                    else -> {
                        cadence = BandCadenceKind.PERIODIC
                        nominalIntervalMilliseconds =
                            if (stream == BandStreamKind.HEART_RATE) {
                                1_000
                            } else {
                                60_000
                            }
                    }
                }
                return BandStreamSemantics(
                    lane = lane,
                    stream = stream,
                    unit = requiredUnit(stream),
                    cadence = cadence,
                    nominalIntervalMilliseconds =
                        nominalIntervalMilliseconds,
                    quality =
                        BandQualitySemantics.ACCEPTED_OR_DEGRADED,
                    timestamp =
                        BandTimestampSemantics.DEVICE_MILLISECONDS,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
                )
            }
            return liveStreams.map {
                semantics(BandProvenanceLane.LIVE, it)
            } + historyStreams.map {
                semantics(BandProvenanceLane.HISTORY, it)
            }
        }
    }
}

private data class BandStreamSemanticKey(
    val lane: BandProvenanceLane,
    val stream: BandStreamKind,
)

data class BandSampleIdentity(
    val stream: BandStreamKind,
    val sequence: Long,
    val deviceTimeMilliseconds: Long,
) {
    override fun toString(): String = "BandSampleIdentity"
}

data class BandSample(
    val identity: BandSampleIdentity,
    val value: Double,
    val unit: BandUnit,
    val quality: BandSampleQuality,
) {
    override fun toString(): String = "BandSample"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BandSample) return false
        return identity == other.identity &&
            value == other.value &&
            unit == other.unit &&
            quality == other.quality
    }

    override fun hashCode(): Int {
        var result = identity.hashCode()
        val normalizedValue = if (value == 0.0) 0.0 else value
        result = 31 * result + normalizedValue.hashCode()
        result = 31 * result + unit.hashCode()
        result = 31 * result + quality.hashCode()
        return result
    }

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

    internal fun hasEquivalentPayload(other: BandSample): Boolean =
        identity == other.identity &&
            value == other.value &&
            unit == other.unit &&
            quality == other.quality
}

data class BandSampleFingerprint(
    val identity: BandSampleIdentity,
    val payloadFingerprint: String,
) {
    constructor(sample: BandSample) : this(
        identity = sample.identity,
        payloadFingerprint = samplePayloadFingerprint(sample),
    )

    override fun toString(): String = "BandSampleFingerprint"

    fun validate() {
        if (
            identity.sequence < 0 ||
            identity.deviceTimeMilliseconds <
            BandContractLimits.MINIMUM_DEVICE_TIME_MILLISECONDS ||
            payloadFingerprint.length != 64 ||
            payloadFingerprint.any {
                it !in '0'..'9' && it !in 'a'..'f'
            }
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }

    internal fun matches(sample: BandSample): Boolean =
        identity == sample.identity &&
            payloadFingerprint == samplePayloadFingerprint(sample)
}

private fun samplePayloadFingerprint(sample: BandSample): String {
    val normalizedBits = if (sample.value == 0.0) {
        0L
    } else {
        java.lang.Double.doubleToRawLongBits(sample.value)
    }
    val bits = java.lang.Long.toUnsignedString(normalizedBits, 16)
        .padStart(16, '0')
    val canonical =
        "v2|$bits|${sample.unit.wireValue}|${sample.quality.wireValue}"
    val digest = MessageDigest.getInstance("SHA-256").digest(
        canonical.toByteArray(Charsets.UTF_8),
    )
    val hex = "0123456789abcdef"
    return buildString(digest.size * 2) {
        digest.forEach { byte ->
            val value = byte.toInt() and 0xff
            append(hex[value ushr 4])
            append(hex[value and 0x0f])
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
    override fun toString(): String = "BandSampleBatch"

    fun validate(expectedLane: BandProvenanceLane) {
        val immutableSamples = samples.boundedSnapshot(
            BandContractLimits.SAMPLES_PER_BATCH,
            BandSample::class.java,
        )
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
            immutableSamples.isEmpty()
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        immutableSamples.forEach(BandSample::validate)
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
    override fun toString(): String = "BandHistoryRange"

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
    override fun toString(): String = "BandHistoryChunk"

    fun validate() {
        val immutableChunk = immutableSnapshot()
        immutableChunk.validateSnapshot()
    }

    private fun validateSnapshot() {
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
        retainedRange?.let { retained ->
            if (
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
        if (overflowed) {
            val retained = retainedRange
                ?: fail(BandFailureCategory.INVALID_INPUT)
            val lost = firstLostRange
                ?: fail(BandFailureCategory.INVALID_INPUT)
            if (
                lost.endDeviceTimeMilliseconds >=
                retained.startDeviceTimeMilliseconds
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

internal inline fun <reified T : Any> List<T>.boundedSnapshot(
    maximumSize: Int,
): List<T> = boundedSnapshot(maximumSize, T::class.java)

@PublishedApi
internal fun <T : Any> List<T>.boundedSnapshot(
    maximumSize: Int,
    elementType: Class<T>,
): List<T> {
    val expectedSize = try {
        size
    } catch (_: BandException) {
        fail(BandFailureCategory.INVALID_INPUT)
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
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
            val element: Any? = iterator.next()
            if (element == null || !elementType.isInstance(element)) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
            snapshot += elementType.cast(element)
        }
    } catch (_: BandException) {
        fail(BandFailureCategory.INVALID_INPUT)
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (snapshot.size != expectedSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    return snapshot
}

internal inline fun <reified T : Any> Set<T>.boundedSnapshot(
    maximumSize: Int,
): Set<T> = boundedSnapshot(maximumSize, T::class.java)

@PublishedApi
internal fun <T : Any> Set<T>.boundedSnapshot(
    maximumSize: Int,
    elementType: Class<T>,
): Set<T> {
    val expectedSize = try {
        size
    } catch (_: BandException) {
        fail(BandFailureCategory.INVALID_INPUT)
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (maximumSize < 0 || expectedSize < 0 || expectedSize > maximumSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    val snapshot = LinkedHashSet<T>(expectedSize)
    var iteratorSteps = 0
    try {
        val iterator = iterator()
        while (iterator.hasNext()) {
            if (iteratorSteps >= maximumSize) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
            iteratorSteps += 1
            val element: Any? = iterator.next()
            if (element == null || !elementType.isInstance(element)) {
                fail(BandFailureCategory.INVALID_INPUT)
            }
            snapshot += elementType.cast(element)
        }
    } catch (_: BandException) {
        fail(BandFailureCategory.INVALID_INPUT)
    } catch (_: RuntimeException) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    if (snapshot.size != expectedSize) {
        fail(BandFailureCategory.INVALID_INPUT)
    }
    return snapshot
}

data class BandHistoryCheckpoint @JvmOverloads constructor(
    val sourceIdentity: String,
    val acknowledgedCursor: String?,
    val lastHistoryComplete: Boolean?,
    val durableSampleIdentities: Set<BandSampleIdentity>,
    val durableSampleFingerprints: Set<BandSampleFingerprint> = emptySet(),
) {
    override fun toString(): String = "BandHistoryCheckpoint"

    fun validate() {
        val immutableIdentities = durableSampleIdentities.boundedSnapshot(
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES,
            BandSampleIdentity::class.java,
        )
        val immutableFingerprints = durableSampleFingerprints.boundedSnapshot(
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES,
            BandSampleFingerprint::class.java,
        )
        val fingerprintIdentities =
            immutableFingerprints.map(BandSampleFingerprint::identity)
        if (
            !sourceIdentity.hasValidUtf8Length(
                BandContractLimits.SOURCE_IDENTITY_LENGTH,
            ) ||
            acknowledgedCursor?.let {
                !it.hasValidUtf8Length(BandContractLimits.CURSOR_LENGTH)
            } ?: false ||
            immutableIdentities.any {
                it.sequence < 0 ||
                    it.deviceTimeMilliseconds <
                    BandContractLimits.MINIMUM_DEVICE_TIME_MILLISECONDS
            } ||
            fingerprintIdentities.toSet().size !=
            immutableFingerprints.size ||
            !immutableIdentities.containsAll(fingerprintIdentities)
        ) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        immutableFingerprints.forEach(BandSampleFingerprint::validate)
    }

    internal fun immutableSnapshot(): BandHistoryCheckpoint {
        val immutableIdentities = durableSampleIdentities.boundedSnapshot(
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES,
            BandSampleIdentity::class.java,
        )
        val immutableFingerprints = durableSampleFingerprints.boundedSnapshot(
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES,
            BandSampleFingerprint::class.java,
        )
        return copy(
            durableSampleIdentities = immutableIdentities,
            durableSampleFingerprints = immutableFingerprints,
        )
    }
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
    val capabilityReportRevision: String,
    val parserRevision: String,
    val calibrationRevision: String,
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
    val capabilityReportRevision: String,
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
) {
    override fun toString(): String = "BandSessionSnapshot"
}

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
