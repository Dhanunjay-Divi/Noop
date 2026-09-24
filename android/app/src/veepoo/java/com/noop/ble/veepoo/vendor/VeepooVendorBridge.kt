package com.noop.ble.veepoo.vendor

import com.noop.ble.veepoo.VeepooAttemptToken
import com.noop.ble.veepoo.VeepooAuthenticationToken
import com.noop.ble.veepoo.VeepooBatteryReading
import com.noop.ble.veepoo.VeepooBinding
import com.noop.ble.veepoo.VeepooBridge
import com.noop.ble.veepoo.VeepooCandidate
import com.noop.ble.veepoo.VeepooCandidateHandle
import com.noop.ble.veepoo.VeepooCapabilities
import com.noop.ble.veepoo.VeepooConnectionIntent
import com.noop.ble.veepoo.VeepooConnectionTarget
import com.noop.ble.veepoo.VeepooFailure
import com.noop.ble.veepoo.VeepooIdentity
import com.noop.ble.veepoo.VeepooLiveHeartRate
import java.util.concurrent.atomic.AtomicLong

internal fun interface VeepooVendorConnectionRegistration {
    fun unregister()
}

internal interface VeepooVendorScanCallback {
    fun onCandidate(address: String)
    fun onFinished()
    fun onFailure(failure: VeepooFailure)
}

internal interface VeepooVendorConnectionCallback {
    fun onConnected(oadMode: Boolean)
    fun onNotifyReady()
    fun onDisconnected()
    fun onFailure(failure: VeepooFailure)
}

internal data class VeepooVendorIdentity(
    val deviceNumber: Int,
    val hardwareRevision: String?,
    val firmwareVersion: String?,
)

internal interface VeepooVendorAuthenticationCallback {
    fun onIdentity(identity: VeepooVendorIdentity)
    fun onHeartRateCapability(supported: Boolean)
    fun onComplete()
    fun onFailure(failure: VeepooFailure)
}

internal interface VeepooVendorBatteryCallback {
    fun onReading(percent: Int)
    fun onFailure(failure: VeepooFailure)
}

internal interface VeepooVendorHeartRateCallback {
    fun onReading(beatsPerMinute: Int)
    fun onFailure(failure: VeepooFailure)
}

internal interface VeepooVendorClient {
    fun initialize()
    fun startScan(callback: VeepooVendorScanCallback)
    fun stopScan()
    fun connect(
        address: String,
        requireDeviceConfirmation: Boolean,
        callback: VeepooVendorConnectionCallback,
    ): VeepooVendorConnectionRegistration

    fun authenticate(password: CharArray, callback: VeepooVendorAuthenticationCallback)
    fun cancelAuthentication()
    fun readBattery(callback: VeepooVendorBatteryCallback)
    fun startLiveHeartRate(callback: VeepooVendorHeartRateCallback)
    fun stopLiveHeartRate()
    fun disconnect()
    fun close()
}

/**
 * Owns app-facing attempt fencing independently of the supplier callback lifecycle.
 *
 * Addresses remain private in this source set. Candidate handles and every public
 * `toString` surface are opaque.
 */
internal class VeepooVendorBridge(
    private val client: VeepooVendorClient,
    private val clockMilliseconds: () -> Long = System::currentTimeMillis,
) : VeepooBridge {
    private data class CandidateRecord(
        val address: String,
        val attempt: VeepooAttemptToken,
    )

    private class ConnectionState(
        val attempt: VeepooAttemptToken,
        val address: String,
        val binding: VeepooBinding,
        val intent: VeepooConnectionIntent,
    ) {
        var registration: VeepooVendorConnectionRegistration? = null
        var connectReady = false
        var notifyReady = false
        var transportDelivered = false
        var terminalCallbackDelivered = false
        var authenticated = false
        var liveHeartRateSupported = false
        var batteryRead = false
        var batteryOperation = 0L
        var liveOperation = 0L
        var liveActive = false
        var authentication: AuthenticationState? = null
    }

    private class AuthenticationState(
        val token: VeepooAuthenticationToken,
        val operation: Long,
    ) {
        var identity: VeepooVendorIdentity? = null
        var liveHeartRateSupported: Boolean? = null
        var completed = false
    }

    private val lock = Any()
    private val candidateSequence = AtomicLong()
    private val candidates = linkedMapOf<String, CandidateRecord>()
    private var listener: VeepooBridge.Listener? = null
    private var closed = false
    private var scanAttempt: VeepooAttemptToken? = null
    private var scanOperation = 0L
    private var authenticationOperation = 0L
    private var connection: ConnectionState? = null
    private val initializationFailure: VeepooFailure? = try {
        client.initialize()
        null
    } catch (failure: Throwable) {
        failure.toVeepooFailure()
    }

    override fun setListener(listener: VeepooBridge.Listener) {
        synchronized(lock) {
            if (!closed) this.listener = listener
        }
    }

    override fun startScan(attempt: VeepooAttemptToken) {
        val state = synchronized(lock) {
            if (closed) return
            val stopPrevious = scanAttempt != null
            scanOperation += 1
            scanAttempt = attempt
            candidates.clear()
            Triple(scanOperation, stopPrevious, initializationFailure)
        }
        val initializationFailure = state.third
        if (initializationFailure != null) {
            failScan(attempt, state.first, initializationFailure)
            return
        }
        if (state.second) {
            runCatching { client.stopScan() }
        }
        val callback = object : VeepooVendorScanCallback {
            override fun onCandidate(address: String) {
                val candidate = synchronized(lock) {
                    if (
                        closed ||
                        scanAttempt !== attempt ||
                        scanOperation != state.first ||
                        address.isBlank() ||
                        candidates.values.any { it.address == address }
                    ) {
                        return
                    }
                    val handleValue = "candidate-${candidateSequence.incrementAndGet()}"
                    candidates[handleValue] = CandidateRecord(address, attempt)
                    VeepooCandidate(
                        handle = VeepooCandidateHandle(handleValue),
                        compatible = true,
                        identifyEligible = true,
                    )
                }
                dispatch { it.onCandidate(attempt, candidate) }
            }

            override fun onFinished() {
                val accepted = synchronized(lock) {
                    if (
                        closed ||
                        scanAttempt !== attempt ||
                        scanOperation != state.first
                    ) {
                        false
                    } else {
                        scanAttempt = null
                        true
                    }
                }
                if (accepted) dispatch { it.onScanFinished(attempt) }
            }

            override fun onFailure(failure: VeepooFailure) {
                failScan(attempt, state.first, failure)
            }
        }
        try {
            client.startScan(callback)
        } catch (failure: Throwable) {
            failScan(attempt, state.first, failure.toVeepooFailure())
        }
    }

    override fun stopScan(attempt: VeepooAttemptToken) {
        val shouldStop = synchronized(lock) {
            if (closed || scanAttempt !== attempt) {
                false
            } else {
                scanAttempt = null
                scanOperation += 1
                true
            }
        }
        if (shouldStop) runCatching { client.stopScan() }
    }

    override fun connect(
        target: VeepooConnectionTarget,
        attempt: VeepooAttemptToken,
        intent: VeepooConnectionIntent,
    ) {
        var rejected = false
        var priorConnection: ConnectionState? = null
        val nextConnection = synchronized(lock) {
            if (closed) return
            val address = when (target) {
                is VeepooConnectionTarget.KnownAddress -> target.value.takeIf(String::isNotBlank)
                is VeepooConnectionTarget.Discovered -> {
                    candidates.remove(target.handle.value)
                        ?.takeIf { it.attempt === attempt }
                        ?.address
                }
            }
            if (address == null || initializationFailure != null) {
                rejected = true
                null
            } else {
                priorConnection = connection
                scanAttempt = null
                scanOperation += 1
                candidates.clear()
                ConnectionState(
                    attempt = attempt,
                    address = address,
                    binding = VeepooBinding.create(address, attempt),
                    intent = intent,
                ).also { connection = it }
            }
        }
        if (rejected || nextConnection == null) {
            dispatch {
                it.onFailure(
                    attempt,
                    initializationFailure ?: VeepooFailure.REJECTED,
                )
            }
            return
        }
        priorConnection?.let { cleanupConnection(it, disconnect = true) }

        val callback = object : VeepooVendorConnectionCallback {
            override fun onConnected(oadMode: Boolean) {
                if (oadMode) {
                    failConnection(nextConnection, VeepooFailure.UNSUPPORTED)
                    return
                }
                val deliver = synchronized(lock) {
                    if (!accepts(nextConnection)) {
                        false
                    } else {
                        nextConnection.connectReady = true
                        transportReady(nextConnection)
                    }
                }
                if (deliver) {
                    dispatch { it.onTransportConnected(attempt) }
                }
            }

            override fun onNotifyReady() {
                val deliver = synchronized(lock) {
                    if (!accepts(nextConnection)) {
                        false
                    } else {
                        nextConnection.notifyReady = true
                        transportReady(nextConnection)
                    }
                }
                if (deliver) {
                    dispatch { it.onTransportConnected(attempt) }
                }
            }

            override fun onDisconnected() {
                failConnection(nextConnection, VeepooFailure.DISCONNECTED)
            }

            override fun onFailure(failure: VeepooFailure) {
                failConnection(nextConnection, failure)
            }
        }

        val registration = try {
            client.connect(
                address = nextConnection.address,
                requireDeviceConfirmation = intent == VeepooConnectionIntent.PAIRING,
                callback = callback,
            )
        } catch (failure: Throwable) {
            failConnection(nextConnection, failure.toVeepooFailure())
            return
        }
        val retained = synchronized(lock) {
            if (connection === nextConnection && !closed) {
                nextConnection.registration = registration
                true
            } else {
                false
            }
        }
        if (!retained) runCatching { registration.unregister() }
    }

    override fun authenticate(
        password: CharArray,
        attempt: VeepooAttemptToken,
        authentication: VeepooAuthenticationToken,
        intent: VeepooConnectionIntent,
    ) {
        val validPassword =
            password.size == TRANSPORT_PASSWORD_LENGTH && password.all { it in '0'..'9' }
        var immediateFailure: VeepooFailure? = null
        val stateAndAuthentication = synchronized(lock) {
            val state = connection
            when {
                closed || state == null || state.attempt !== attempt -> null
                state.terminalCallbackDelivered || !state.transportDelivered ->
                    null.also { immediateFailure = VeepooFailure.DISCONNECTED }
                state.intent != intent || !validPassword ->
                    null.also { immediateFailure = VeepooFailure.REJECTED }
                else -> {
                    authenticationOperation += 1
                    val authState = AuthenticationState(authentication, authenticationOperation)
                    state.authentication = authState
                    state.authenticated = false
                    state.batteryRead = false
                    state.liveActive = false
                    state to authState
                }
            }
        }
        if (stateAndAuthentication == null) {
            immediateFailure?.let { failure ->
                dispatch {
                    it.onAuthenticationFailed(attempt, authentication, failure)
                }
            }
            return
        }

        runCatching { client.cancelAuthentication() }
        val state = stateAndAuthentication.first
        val authState = stateAndAuthentication.second
        val callback = object : VeepooVendorAuthenticationCallback {
            override fun onIdentity(identity: VeepooVendorIdentity) {
                synchronized(lock) {
                    if (accepts(state, authState)) authState.identity = identity
                }
                deliverAuthenticationIfReady(state, authState)
            }

            override fun onHeartRateCapability(supported: Boolean) {
                synchronized(lock) {
                    if (accepts(state, authState)) {
                        authState.liveHeartRateSupported = supported
                    }
                }
                deliverAuthenticationIfReady(state, authState)
            }

            override fun onComplete() {
                synchronized(lock) {
                    if (accepts(state, authState)) authState.completed = true
                }
                deliverAuthenticationIfReady(state, authState)
            }

            override fun onFailure(failure: VeepooFailure) {
                failAuthentication(state, authState, failure)
            }
        }
        val privatePassword = password.copyOf()
        try {
            client.authenticate(privatePassword, callback)
        } catch (failure: Throwable) {
            failAuthentication(state, authState, failure.toVeepooFailure())
        } finally {
            privatePassword.fill('\u0000')
        }
    }

    override fun readBattery(attempt: VeepooAttemptToken) {
        var immediateFailure: VeepooFailure? = null
        val stateAndOperation = synchronized(lock) {
            val state = connection
            when {
                closed || state == null || state.attempt !== attempt -> null
                state.terminalCallbackDelivered -> null
                !state.authenticated ->
                    null.also { immediateFailure = VeepooFailure.REJECTED }
                else -> {
                    state.batteryOperation += 1
                    state.batteryRead = false
                    state to state.batteryOperation
                }
            }
        }
        if (stateAndOperation == null) {
            immediateFailure?.let { failure ->
                dispatch { it.onFailure(attempt, failure) }
            }
            return
        }
        val state = stateAndOperation.first
        val operation = stateAndOperation.second
        val callback = object : VeepooVendorBatteryCallback {
            override fun onReading(percent: Int) {
                val accepted = synchronized(lock) {
                    if (
                        !accepts(state) ||
                        state.batteryOperation != operation ||
                        percent !in 0..100
                    ) {
                        false
                    } else {
                        state.batteryOperation += 1
                        state.batteryRead = true
                        true
                    }
                }
                if (!accepted) {
                    if (percent !in 0..100) {
                        failBattery(state, operation, VeepooFailure.REJECTED)
                    }
                    return
                }
                val observedAt = clockMilliseconds()
                if (observedAt < 0L) {
                    failBattery(state, operation + 1, VeepooFailure.INTERNAL)
                    return
                }
                dispatch {
                    it.onBattery(
                        attempt,
                        VeepooBatteryReading(percent, observedAt),
                    )
                }
            }

            override fun onFailure(failure: VeepooFailure) {
                failBattery(state, operation, failure)
            }
        }
        try {
            client.readBattery(callback)
        } catch (failure: Throwable) {
            failBattery(state, operation, failure.toVeepooFailure())
        }
    }

    override fun startLiveHeartRate(attempt: VeepooAttemptToken) {
        var immediateFailure: VeepooFailure? = null
        val stateAndOperation = synchronized(lock) {
            val state = connection
            when {
                closed || state == null || state.attempt !== attempt -> null
                state.terminalCallbackDelivered -> null
                !state.authenticated || !state.batteryRead ->
                    null.also { immediateFailure = VeepooFailure.REJECTED }
                !state.liveHeartRateSupported ->
                    null.also { immediateFailure = VeepooFailure.UNSUPPORTED }
                state.liveActive -> null
                else -> {
                    state.liveOperation += 1
                    state.liveActive = true
                    state to state.liveOperation
                }
            }
        }
        if (stateAndOperation == null) {
            immediateFailure?.let { failure ->
                dispatch { it.onFailure(attempt, failure) }
            }
            return
        }
        val state = stateAndOperation.first
        val operation = stateAndOperation.second
        val callback = object : VeepooVendorHeartRateCallback {
            override fun onReading(beatsPerMinute: Int) {
                val accepted = synchronized(lock) {
                    accepts(state) &&
                        state.liveOperation == operation &&
                        state.liveActive
                }
                if (!accepted) return
                if (beatsPerMinute !in MIN_HEART_RATE..MAX_HEART_RATE) {
                    failLiveHeartRate(state, operation, VeepooFailure.REJECTED)
                    return
                }
                val receivedAt = clockMilliseconds()
                if (receivedAt < 0L) {
                    failLiveHeartRate(state, operation, VeepooFailure.INTERNAL)
                    return
                }
                dispatch {
                    it.onLiveHeartRate(
                        attempt,
                        VeepooLiveHeartRate(beatsPerMinute, receivedAt),
                    )
                }
            }

            override fun onFailure(failure: VeepooFailure) {
                failLiveHeartRate(state, operation, failure)
            }
        }
        try {
            client.startLiveHeartRate(callback)
        } catch (failure: Throwable) {
            failLiveHeartRate(state, operation, failure.toVeepooFailure())
        }
    }

    override fun stopLiveHeartRate(attempt: VeepooAttemptToken) {
        val shouldStop = synchronized(lock) {
            val state = connection
            if (closed || state == null || state.attempt !== attempt || !state.liveActive) {
                false
            } else {
                state.liveActive = false
                state.liveOperation += 1
                true
            }
        }
        if (shouldStop) runCatching { client.stopLiveHeartRate() }
    }

    override fun disconnect(attempt: VeepooAttemptToken) {
        val state = synchronized(lock) {
            val active = connection
            if (active == null || active.attempt !== attempt) {
                null
            } else {
                connection = null
                active.authentication = null
                active.batteryOperation += 1
                active.liveOperation += 1
                active.liveActive = false
                candidates.clear()
                active
            }
        }
        if (state != null) cleanupConnection(state, disconnect = true)
    }

    override fun close() {
        val state = synchronized(lock) {
            if (closed) return
            closed = true
            scanAttempt = null
            scanOperation += 1
            candidates.clear()
            val active = connection
            connection = null
            active?.let {
                it.authentication = null
                it.batteryOperation += 1
                it.liveOperation += 1
                it.liveActive = false
            }
            listener = null
            active
        }
        runCatching { client.stopScan() }
        if (state != null) cleanupConnection(state, disconnect = true)
        runCatching { client.close() }
    }

    private fun failScan(
        attempt: VeepooAttemptToken,
        operation: Long,
        failure: VeepooFailure,
    ) {
        val accepted = synchronized(lock) {
            if (
                closed ||
                scanAttempt !== attempt ||
                scanOperation != operation
            ) {
                false
            } else {
                scanAttempt = null
                true
            }
        }
        if (accepted) dispatch { it.onFailure(attempt, failure) }
    }

    private fun transportReady(state: ConnectionState): Boolean {
        if (
            !state.connectReady ||
            !state.notifyReady ||
            state.transportDelivered ||
            state.terminalCallbackDelivered
        ) {
            return false
        }
        state.transportDelivered = true
        return true
    }

    private fun failConnection(
        state: ConnectionState,
        failure: VeepooFailure,
    ) {
        val dropped = synchronized(lock) {
            if (!accepts(state)) {
                null
            } else {
                state.terminalCallbackDelivered = true
                state.authentication = null
                state.batteryOperation += 1
                state.liveOperation += 1
                state.liveActive = false
                state.transportDelivered
            }
        } ?: return
        runCatching { client.cancelAuthentication() }
        if (dropped) {
            dispatch { it.onConnectionDropped(state.attempt) }
        } else {
            dispatch { it.onFailure(state.attempt, failure) }
        }
    }

    private fun deliverAuthenticationIfReady(
        state: ConnectionState,
        authentication: AuthenticationState,
    ) {
        var rejected = false
        val delivery = synchronized(lock) {
            if (
                !accepts(state, authentication) ||
                !authentication.completed ||
                authentication.identity == null ||
                authentication.liveHeartRateSupported == null
            ) {
                null
            } else {
                val identity = requireNotNull(authentication.identity)
                val hardwareRevision = identity.hardwareRevision.validIdentityPart()
                val firmwareVersion = identity.firmwareVersion.validIdentityPart()
                if (
                    identity.deviceNumber < 0 ||
                    hardwareRevision == null ||
                    firmwareVersion == null
                ) {
                    state.authentication = null
                    rejected = true
                    null
                } else {
                    state.authentication = null
                    state.authenticated = true
                    state.liveHeartRateSupported =
                        requireNotNull(authentication.liveHeartRateSupported)
                    state.batteryRead = false
                    AuthenticationDelivery(
                        authentication.token,
                        state.binding,
                        VeepooIdentity(
                            printedDeviceNumber = identity.deviceNumber.toString(),
                            hardwareRevision = hardwareRevision,
                            firmwareVersion = firmwareVersion,
                        ),
                        VeepooCapabilities(
                            liveHeartRate = state.liveHeartRateSupported,
                            battery = true,
                        ),
                    )
                }
            }
        }
        if (delivery == null && !rejected) return
        runCatching { client.cancelAuthentication() }
        if (rejected) {
            dispatch {
                it.onAuthenticationFailed(
                    state.attempt,
                    authentication.token,
                    VeepooFailure.REJECTED,
                )
            }
            return
        }
        requireNotNull(delivery)
        dispatch {
            it.onAuthenticated(
                state.attempt,
                delivery.token,
                delivery.binding,
                delivery.identity,
                delivery.capabilities,
            )
        }
    }

    private fun failAuthentication(
        state: ConnectionState,
        authentication: AuthenticationState,
        failure: VeepooFailure,
    ) {
        val accepted = synchronized(lock) {
            if (!accepts(state, authentication)) {
                false
            } else {
                state.authentication = null
                true
            }
        }
        if (!accepted) return
        runCatching { client.cancelAuthentication() }
        dispatch {
            it.onAuthenticationFailed(
                state.attempt,
                authentication.token,
                failure,
            )
        }
    }

    private fun failBattery(
        state: ConnectionState,
        operation: Long,
        failure: VeepooFailure,
    ) {
        val accepted = synchronized(lock) {
            if (!accepts(state) || state.batteryOperation != operation) {
                false
            } else {
                state.batteryOperation += 1
                state.batteryRead = false
                true
            }
        }
        if (accepted) dispatch { it.onFailure(state.attempt, failure) }
    }

    private fun failLiveHeartRate(
        state: ConnectionState,
        operation: Long,
        failure: VeepooFailure,
    ) {
        val accepted = synchronized(lock) {
            if (
                !accepts(state) ||
                state.liveOperation != operation ||
                !state.liveActive
            ) {
                false
            } else {
                state.liveOperation += 1
                state.liveActive = false
                true
            }
        }
        if (accepted) dispatch { it.onFailure(state.attempt, failure) }
    }

    private fun cleanupConnection(
        state: ConnectionState,
        disconnect: Boolean,
    ) {
        runCatching { client.cancelAuthentication() }
        runCatching { client.stopLiveHeartRate() }
        runCatching { state.registration?.unregister() }
        state.registration = null
        if (disconnect) runCatching { client.disconnect() }
    }

    private fun accepts(state: ConnectionState): Boolean =
        !closed &&
            connection === state &&
            !state.terminalCallbackDelivered

    private fun accepts(
        state: ConnectionState,
        authentication: AuthenticationState,
    ): Boolean =
        accepts(state) &&
            state.authentication === authentication &&
            authentication.operation == authenticationOperation

    private fun String?.validIdentityPart(): String? {
        val value = this?.trim()?.takeIf(String::isNotEmpty) ?: return null
        return value.takeIf {
            it.length <= MAX_IDENTITY_COMPONENT_LENGTH &&
                it.none(Char::isISOControl)
        }
    }

    private fun dispatch(action: (VeepooBridge.Listener) -> Unit) {
        val target = synchronized(lock) {
            if (closed) null else listener
        }
        if (target != null) runCatching { action(target) }
    }

    private data class AuthenticationDelivery(
        val token: VeepooAuthenticationToken,
        val binding: VeepooBinding,
        val identity: VeepooIdentity,
        val capabilities: VeepooCapabilities,
    )

    companion object {
        private const val TRANSPORT_PASSWORD_LENGTH = 4
        private const val MAX_IDENTITY_COMPONENT_LENGTH = 64
        private const val MIN_HEART_RATE = 20
        private const val MAX_HEART_RATE = 300
    }
}

internal fun Throwable.toVeepooFailure(): VeepooFailure = when (this) {
    is SecurityException -> VeepooFailure.PERMISSION
    is UnsupportedOperationException -> VeepooFailure.UNSUPPORTED
    is IllegalArgumentException -> VeepooFailure.REJECTED
    else -> VeepooFailure.INTERNAL
}
