package com.noop.ble.veepoo

import java.util.concurrent.atomic.AtomicLong

class VeepooAttemptToken private constructor(
    @Suppress("unused") private val sequence: Long,
) {
    override fun toString(): String = "VeepooAttemptToken"

    companion object {
        private val next = AtomicLong()
        fun create(): VeepooAttemptToken = VeepooAttemptToken(next.incrementAndGet())
    }
}

class VeepooAuthenticationToken private constructor(
    @Suppress("unused") private val sequence: Long,
) {
    override fun toString(): String = "VeepooAuthenticationToken"

    companion object {
        private val next = AtomicLong()
        fun create(): VeepooAuthenticationToken =
            VeepooAuthenticationToken(next.incrementAndGet())
    }
}

class VeepooCandidateHandle internal constructor(
    internal val value: String,
) {
    override fun toString(): String = "VeepooCandidateHandle"
}

data class VeepooCandidate(
    val handle: VeepooCandidateHandle,
    val compatible: Boolean,
    val identifyEligible: Boolean,
) {
    override fun toString(): String = "VeepooCandidate"
}

sealed interface VeepooConnectionTarget {
    class KnownAddress(internal val value: String) : VeepooConnectionTarget {
        override fun toString(): String = "VeepooConnectionTarget.KnownAddress"
    }

    class Discovered(internal val handle: VeepooCandidateHandle) : VeepooConnectionTarget {
        override fun toString(): String = "VeepooConnectionTarget.Discovered"
    }
}

enum class VeepooConnectionIntent {
    PAIRING,
    RECONNECT,
}

class VeepooBinding private constructor(
    internal val peripheralId: String,
    private val attempt: VeepooAttemptToken,
) {
    internal fun belongsTo(value: VeepooAttemptToken): Boolean = attempt === value
    override fun toString(): String = "VeepooBinding"

    companion object {
        internal fun create(peripheralId: String, attempt: VeepooAttemptToken): VeepooBinding {
            require(peripheralId.isNotBlank())
            return VeepooBinding(peripheralId, attempt)
        }
    }
}

data class VeepooIdentity(
    val modelCode: String,
    val hardwareRevision: String,
    val firmwareVersion: String,
) {
    override fun toString(): String = "VeepooIdentity"
}

data class VeepooCapabilities(
    val liveHeartRate: Boolean,
    val battery: Boolean,
) {
    override fun toString(): String = "VeepooCapabilities"
}

data class VeepooBatteryReading(
    val percent: Int,
    val observedAtMilliseconds: Long,
) {
    override fun toString(): String = "VeepooBatteryReading"
}

data class VeepooLiveHeartRate(
    val beatsPerMinute: Int,
    val phoneReceiptMilliseconds: Long,
) {
    override fun toString(): String = "VeepooLiveHeartRate"
}

enum class VeepooFailure {
    UNAVAILABLE,
    PERMISSION,
    NO_RESULT,
    TIMEOUT,
    REJECTED,
    AUTHENTICATION,
    DISCONNECTED,
    UNSUPPORTED,
    INTERNAL,
}

interface VeepooBridge {
    /**
     * Implementations must keep a durable connection-status listener registered for the selected
     * address until [disconnect] or [close], and translate an unexpected link loss to
     * [Listener.onConnectionDropped]. A one-shot connect callback is not sufficient.
     */
    fun setListener(listener: Listener)
    fun startScan(attempt: VeepooAttemptToken)
    fun stopScan(attempt: VeepooAttemptToken)
    fun connect(
        target: VeepooConnectionTarget,
        attempt: VeepooAttemptToken,
        intent: VeepooConnectionIntent,
    )

    fun authenticate(
        password: CharArray,
        attempt: VeepooAttemptToken,
        authentication: VeepooAuthenticationToken,
        intent: VeepooConnectionIntent,
    )

    fun readBattery(attempt: VeepooAttemptToken)
    fun startLiveHeartRate(attempt: VeepooAttemptToken)
    fun stopLiveHeartRate(attempt: VeepooAttemptToken)
    fun disconnect(attempt: VeepooAttemptToken)
    fun close()

    interface Listener {
        fun onCandidate(attempt: VeepooAttemptToken, candidate: VeepooCandidate)
        fun onScanFinished(attempt: VeepooAttemptToken)
        fun onTransportConnected(attempt: VeepooAttemptToken)
        fun onAuthenticated(
            attempt: VeepooAttemptToken,
            authentication: VeepooAuthenticationToken,
            binding: VeepooBinding,
            identity: VeepooIdentity,
            capabilities: VeepooCapabilities,
        )

        fun onAuthenticationFailed(
            attempt: VeepooAttemptToken,
            authentication: VeepooAuthenticationToken,
            failure: VeepooFailure,
        )

        fun onBattery(attempt: VeepooAttemptToken, reading: VeepooBatteryReading)
        fun onLiveHeartRate(attempt: VeepooAttemptToken, reading: VeepooLiveHeartRate)
        fun onConnectionDropped(attempt: VeepooAttemptToken)
        fun onFailure(attempt: VeepooAttemptToken, failure: VeepooFailure)
    }
}
