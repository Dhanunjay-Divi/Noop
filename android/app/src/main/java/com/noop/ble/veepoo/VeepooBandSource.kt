package com.noop.ble.veepoo

import com.noop.bandsdk.BandCapability
import com.noop.bandsdk.BandCapabilityReport
import com.noop.bandsdk.BandConnectionToken
import com.noop.bandsdk.BandDisconnectReason
import com.noop.bandsdk.BandFailureCategory
import com.noop.bandsdk.BandIdentity
import com.noop.bandsdk.BandOperationClass
import com.noop.bandsdk.BandOperationToken
import com.noop.bandsdk.BandPairingCandidate
import com.noop.bandsdk.BandReconnectToken
import com.noop.bandsdk.BandScanToken
import com.noop.bandsdk.BandSessionMachine
import com.noop.ble.LiveHrSource
import com.noop.ble.NoopBandSdkBoundary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

fun interface VeepooReconnectCancellation {
    fun cancel()
}

interface VeepooReconnectScheduler : AutoCloseable {
    fun schedule(delayMilliseconds: Long, task: () -> Unit): VeepooReconnectCancellation

    override fun close() = Unit
}

private class ExecutorVeepooReconnectScheduler : VeepooReconnectScheduler {
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "noop-supplier-reconnect").apply { isDaemon = true }
    }

    override fun schedule(
        delayMilliseconds: Long,
        task: () -> Unit,
    ): VeepooReconnectCancellation {
        val future: ScheduledFuture<*> = executor.schedule(
            { task() },
            delayMilliseconds,
            TimeUnit.MILLISECONDS,
        )
        return VeepooReconnectCancellation { future.cancel(false) }
    }

    override fun close() {
        executor.shutdownNow()
    }
}

enum class VeepooAdapterState {
    IDLE,
    SCANNING,
    CANDIDATES_FOUND,
    CONNECTING,
    AWAITING_PAIRING_CONFIRMATION,
    AUTHENTICATING,
    READING_BATTERY,
    LIVE_DISPLAY_ONLY,
    RECONNECTING,
    FAILED,
    STOPPED,
}

private enum class VeepooTransportOwnership {
    ACTIVE,
    RELEASED_AFTER_FAILURE,
    RELEASED_AFTER_STOP,
}

data class VeepooCandidateRow(
    val handle: VeepooCandidateHandle,
    val ordinal: Int,
)

data class VeepooDisplayState(
    val adapterState: VeepooAdapterState = VeepooAdapterState.IDLE,
    val heartRate: Int? = null,
    val batteryPercent: Int? = null,
    val phoneReceiptMilliseconds: Long? = null,
    val active: Boolean = false,
)

interface VeepooManagedSource : LiveHrSource {
    val state: StateFlow<VeepooAdapterState>
    val candidates: StateFlow<List<VeepooCandidateRow>>
    val display: StateFlow<VeepooDisplayState>
    fun selectCandidate(handle: VeepooCandidateHandle): Boolean
    fun submitPairing(transportPassword: CharArray): Boolean
    fun takeProvisioningCommit(): VeepooProvisioningCommit?
}

class VeepooProvisioningCommit internal constructor(
    private val binding: VeepooBinding,
    val hardwareRevision: String,
    val firmwareVersion: String,
    password: CharArray,
) : AutoCloseable {
    private var password: CharArray? = password

    internal val peripheralId: String get() = binding.peripheralId

    @Synchronized
    internal fun saveCredential(
        save: (CharArray, VeepooRevisionBinding) -> Boolean,
    ): Boolean {
        val value = password ?: return false
        password = null
        val revisionBinding = VeepooRevisionBinding.from(
            hardwareRevision = hardwareRevision,
            firmwareVersion = firmwareVersion,
        )
        return try {
            revisionBinding != null && save(value, revisionBinding)
        } finally {
            value.fill('\u0000')
        }
    }

    @Synchronized
    override fun close() {
        password?.fill('\u0000')
        password = null
    }

    override fun toString(): String = "VeepooProvisioningCommit"
}

/**
 * Supplier-independent lifecycle adapter. All entry points and callbacks are serialized by this
 * monitor, and every supplier call is contained. Phone receipt time is exposed only in [display];
 * no supplier HR callback is converted into a neutral sample or repository write.
 */
class VeepooBandSource(
    private val deviceId: String,
    private val bridge: VeepooBridge,
    initialReconnectPassword: CharArray? = null,
    initialReconnectRevisionBinding: VeepooRevisionBinding? = null,
    private val compatibilityPolicy: VeepooCompatibilityPolicy =
        VeepooCompatibilityPolicy.invalid(),
    private val diagnostics: VeepooDiagnosticSink = AppVeepooDiagnosticSink,
    private val session: BandSessionMachine = NoopBandSdkBoundary.newSession(),
    private val onReconnectCredentialRejected: (VeepooBandSource) -> Unit = {},
    private val onReconnectRevisionBindingChanged:
        (VeepooBandSource, CharArray, VeepooRevisionBinding) -> Boolean =
        { _, _, _ -> false },
    private val onReconnectRevisionPersistenceUnavailable: (VeepooBandSource) -> Unit = {},
    private val onRuntimeUnavailable: (VeepooBandSource) -> Unit = {},
    private val reconnectScheduler: VeepooReconnectScheduler =
        ExecutorVeepooReconnectScheduler(),
) : VeepooManagedSource, VeepooBridge.Listener {
    private val mutableState = MutableStateFlow(VeepooAdapterState.IDLE)
    override val state: StateFlow<VeepooAdapterState> = mutableState.asStateFlow()
    private val mutableCandidates = MutableStateFlow<List<VeepooCandidateRow>>(emptyList())
    override val candidates: StateFlow<List<VeepooCandidateRow>> = mutableCandidates.asStateFlow()
    private val mutableDisplay = MutableStateFlow(VeepooDisplayState())
    override val display: StateFlow<VeepooDisplayState> = mutableDisplay.asStateFlow()

    private var attempt: VeepooAttemptToken? = null
    private var scanToken: BandScanToken? = null
    private var connectionToken: BandConnectionToken? = null
    private var reconnectToken: BandReconnectToken? = null
    private var operationToken: BandOperationToken? = null
    private var authenticationToken: VeepooAuthenticationToken? = null
    private var selectedHandle: VeepooCandidateHandle? = null
    private var binding: VeepooBinding? = null
    private var establishedIdentity: VeepooIdentity? = null
    private var establishedCapabilities: VeepooCapabilities? = null
    private var intent = VeepooConnectionIntent.PAIRING
    private var pendingPassword: CharArray? = null
    private var reconnectPassword: CharArray? = initialReconnectPassword?.copyOf()
    private var reconnectRevisionBinding: VeepooRevisionBinding? =
        initialReconnectRevisionBinding
    private var reconnectAddress: String? = null
    private var provisioningCommit: VeepooProvisioningCommit? = null
    private var reconnectCancellation: VeepooReconnectCancellation? = null
    private var reconnectAttemptCount = 0
    private var transportOwnership = VeepooTransportOwnership.ACTIVE
    private var transportReleaseComplete = false
    private var staleReported = false
    private var invalidLiveReported = false
    private val bridgeReady: Boolean

    init {
        initialReconnectPassword?.fill('\u0000')
        bridgeReady = contained(VeepooDiagnosticCategory.CLEANUP) { bridge.setListener(this) }
    }

    @Synchronized
    override fun scan() {
        if (transportOwnership != VeepooTransportOwnership.ACTIVE) return
        if (!bridgeReady) {
            failAttempt(VeepooDiagnosticCategory.DISCOVERY, VeepooDiagnosticFailure.UNAVAILABLE)
            return
        }
        cancelReconnectSchedule()
        reconnectAttemptCount = 0
        resetAttemptMaterial()
        val token = runSession { session.beginScan() } ?: return failAttempt(
            VeepooDiagnosticCategory.DISCOVERY,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        val current = VeepooAttemptToken.create()
        scanToken = token
        attempt = current
        intent = VeepooConnectionIntent.PAIRING
        mutableCandidates.value = emptyList()
        publishState(VeepooAdapterState.SCANNING)
        record(VeepooDiagnosticCategory.DISCOVERY, VeepooDiagnosticOutcome.BEGAN)
        if (!contained(VeepooDiagnosticCategory.DISCOVERY) { bridge.startScan(current) }) {
            failAttempt(VeepooDiagnosticCategory.DISCOVERY, VeepooDiagnosticFailure.INTERNAL)
        }
    }

    @Synchronized
    override fun connect(address: String) {
        if (transportOwnership != VeepooTransportOwnership.ACTIVE) return
        if (!bridgeReady) {
            failAttempt(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticFailure.UNAVAILABLE)
            return
        }
        val password = reconnectPassword
        val revisionBinding = reconnectRevisionBinding
        if (address.isBlank() || password == null || revisionBinding == null) {
            failAttempt(
                VeepooDiagnosticCategory.RECONNECT,
                if (address.isBlank()) VeepooDiagnosticFailure.INVALID_INPUT
                else VeepooDiagnosticFailure.AUTHENTICATION,
                reportRuntimeUnavailable =
                    address.isBlank() || password == null,
            )
            if (address.isNotBlank() && password != null && revisionBinding == null) {
                notifyReconnectCredentialRejected()
            }
            return
        }
        cancelReconnectSchedule()
        reconnectAttemptCount = 0
        resetAttemptMaterial(clearReconnectPassword = false)
        reconnectAddress = address
        val scan = runSession { session.beginScan() } ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        val connection = runSession {
            session.selectCandidate(
                BandPairingCandidate(DIRECT_HANDLE, compatible = true, identifyEligible = true),
                scan,
            )
        } ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        if (runSession {
                session.beginConnection(connection, session.snapshot().generation)
            } == null
        ) {
            failAttempt(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticFailure.INVALID_STATE)
            return
        }
        scanToken = null
        connectionToken = connection
        attempt = VeepooAttemptToken.create()
        intent = VeepooConnectionIntent.RECONNECT
        publishState(VeepooAdapterState.CONNECTING)
        record(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticOutcome.BEGAN)
        val current = requireNotNull(attempt)
        if (!contained(VeepooDiagnosticCategory.CONNECTION) {
                bridge.connect(VeepooConnectionTarget.KnownAddress(address), current, intent)
            }
        ) {
            scheduleReconnect(
                failure = VeepooDiagnosticFailure.INTERNAL,
                currentAttempt = current,
                address = address,
            )
        }
    }

    @Synchronized
    override fun selectCandidate(handle: VeepooCandidateHandle): Boolean {
        val current = attempt ?: return rejectSelection(VeepooDiagnosticFailure.INVALID_STATE)
        if (mutableState.value !in setOf(VeepooAdapterState.SCANNING, VeepooAdapterState.CANDIDATES_FOUND)) {
            return rejectSelection(VeepooDiagnosticFailure.INVALID_STATE)
        }
        val row = mutableCandidates.value.firstOrNull { it.handle === handle }
            ?: return rejectSelection(VeepooDiagnosticFailure.INVALID_INPUT)
        val scan = scanToken ?: return rejectSelection(VeepooDiagnosticFailure.INVALID_STATE)
        val connection = runSession {
            session.selectCandidate(
                BandPairingCandidate(
                    handle = handle.value,
                    compatible = true,
                    identifyEligible = true,
                ),
                scan,
            )
        } ?: run {
            failAttempt(VeepooDiagnosticCategory.SELECTION, VeepooDiagnosticFailure.INVALID_STATE)
            return false
        }
        scanToken = null
        connectionToken = connection
        selectedHandle = row.handle
        if (runSession {
                session.beginConnection(connection, session.snapshot().generation)
            } == null
        ) {
            failAttempt(VeepooDiagnosticCategory.CONNECTION, VeepooDiagnosticFailure.INVALID_STATE)
            return false
        }
        contained(VeepooDiagnosticCategory.DISCOVERY) { bridge.stopScan(current) }
        publishState(VeepooAdapterState.CONNECTING)
        record(VeepooDiagnosticCategory.SELECTION, VeepooDiagnosticOutcome.COMPLETED)
        return if (contained(VeepooDiagnosticCategory.CONNECTION) {
                bridge.connect(VeepooConnectionTarget.Discovered(handle), current, VeepooConnectionIntent.PAIRING)
            }
        ) {
            true
        } else {
            failAttempt(VeepooDiagnosticCategory.CONNECTION, VeepooDiagnosticFailure.INTERNAL)
            false
        }
    }

    @Synchronized
    override fun submitPairing(transportPassword: CharArray): Boolean {
        if (
            transportOwnership != VeepooTransportOwnership.ACTIVE ||
            intent != VeepooConnectionIntent.PAIRING ||
            mutableState.value != VeepooAdapterState.AWAITING_PAIRING_CONFIRMATION ||
            !validPassword(transportPassword)
        ) {
            record(
                VeepooDiagnosticCategory.PAIRING_CONFIRMATION,
                VeepooDiagnosticOutcome.REJECTED,
                VeepooDiagnosticFailure.INVALID_INPUT,
            )
            return false
        }
        clearPairingMaterial()
        pendingPassword = transportPassword.copyOf()
        return beginAuthentication(transportPassword)
    }

    @Synchronized
    override fun takeProvisioningCommit(): VeepooProvisioningCommit? {
        val value = provisioningCommit
        provisioningCommit = null
        return value
    }

    @Synchronized
    override fun stop() {
        when (transportOwnership) {
            VeepooTransportOwnership.RELEASED_AFTER_STOP -> return
            VeepooTransportOwnership.ACTIVE -> {
                transportOwnership = VeepooTransportOwnership.RELEASED_AFTER_STOP
                releaseTransport(VeepooDiagnosticOutcome.COMPLETED, null)
            }
            VeepooTransportOwnership.RELEASED_AFTER_FAILURE -> {
                // The coordinator is dropping an already-released terminal source.
                transportOwnership = VeepooTransportOwnership.RELEASED_AFTER_STOP
            }
        }
        publishState(VeepooAdapterState.STOPPED)
    }

    @Synchronized
    override fun onCandidate(attempt: VeepooAttemptToken, candidate: VeepooCandidate) {
        if (!accept(attempt) || mutableState.value !in
            setOf(VeepooAdapterState.SCANNING, VeepooAdapterState.CANDIDATES_FOUND)
        ) return
        if (!candidate.compatible || !candidate.identifyEligible) return
        if (mutableCandidates.value.any { it.handle.value == candidate.handle.value }) return
        if (mutableCandidates.value.size >= MAX_CANDIDATES) return
        mutableCandidates.value = mutableCandidates.value +
            VeepooCandidateRow(candidate.handle, mutableCandidates.value.size + 1)
        publishState(VeepooAdapterState.CANDIDATES_FOUND)
    }

    @Synchronized
    override fun onScanFinished(attempt: VeepooAttemptToken) {
        if (!accept(attempt)) return
        if (mutableCandidates.value.isNotEmpty()) {
            publishState(VeepooAdapterState.CANDIDATES_FOUND)
            return
        }
        scanToken?.let { runCatching { session.failScan(BandFailureCategory.NO_RESULT, it) } }
        scanToken = null
        failAttempt(VeepooDiagnosticCategory.DISCOVERY, VeepooDiagnosticFailure.NO_RESULT)
    }

    @Synchronized
    override fun onTransportConnected(attempt: VeepooAttemptToken) {
        if (!accept(attempt) || mutableState.value !in
            setOf(VeepooAdapterState.CONNECTING, VeepooAdapterState.RECONNECTING)
        ) return
        if (intent == VeepooConnectionIntent.PAIRING) {
            publishState(VeepooAdapterState.AWAITING_PAIRING_CONFIRMATION)
            record(VeepooDiagnosticCategory.PAIRING_CONFIRMATION, VeepooDiagnosticOutcome.BEGAN)
        } else {
            val password = reconnectPassword
            if (password == null) {
                failAttempt(
                    VeepooDiagnosticCategory.AUTHENTICATION,
                    VeepooDiagnosticFailure.AUTHENTICATION,
                    reportRuntimeUnavailable = false,
                )
                notifyReconnectCredentialRejected()
                return
            }
            beginAuthentication(password)
        }
    }

    @Synchronized
    override fun onAuthenticated(
        attempt: VeepooAttemptToken,
        authentication: VeepooAuthenticationToken,
        binding: VeepooBinding,
        identity: VeepooIdentity,
        capabilities: VeepooCapabilities,
    ) {
        if (!accept(attempt) || authenticationToken !== authentication) return stale()
        if (!binding.belongsTo(attempt)) return stale()
        authenticationToken = null
        when (compatibilityPolicy.evaluate(identity)) {
            VeepooCompatibilityDecision.APPROVED,
            VeepooCompatibilityDecision.QUALIFICATION_APPROVED,
            -> Unit
            VeepooCompatibilityDecision.INVALID_POLICY -> {
                failAttempt(VeepooDiagnosticCategory.CAPABILITY, VeepooDiagnosticFailure.INTERNAL)
                return
            }
            VeepooCompatibilityDecision.UNAPPROVED -> {
                val reconnect = intent == VeepooConnectionIntent.RECONNECT
                failAttempt(
                    if (reconnect) {
                        VeepooDiagnosticCategory.RECONNECT
                    } else {
                        VeepooDiagnosticCategory.CAPABILITY
                    },
                    if (reconnect) {
                        VeepooDiagnosticFailure.REJECTED
                    } else {
                        VeepooDiagnosticFailure.UNSUPPORTED
                    },
                )
                return
            }
        }
        if (!capabilities.liveHeartRate || !capabilities.battery) {
            failAttempt(VeepooDiagnosticCategory.CAPABILITY, VeepooDiagnosticFailure.UNSUPPORTED)
            return
        }
        if (identity.hardwareRevision.isBlank() || identity.firmwareVersion.isBlank()) {
            failAttempt(VeepooDiagnosticCategory.CAPABILITY, VeepooDiagnosticFailure.REJECTED)
            return
        }
        val observedRevisionBinding = VeepooRevisionBinding.from(
            hardwareRevision = identity.hardwareRevision,
            firmwareVersion = identity.firmwareVersion,
        )
        if (observedRevisionBinding == null) {
            failAttempt(VeepooDiagnosticCategory.CAPABILITY, VeepooDiagnosticFailure.REJECTED)
            return
        }
        val reconnectRevisionChanged =
            intent == VeepooConnectionIntent.RECONNECT &&
            reconnectRevisionBinding != observedRevisionBinding
        val connection = connectionToken
        val reconnect = reconnectToken
        if (reconnect != null) {
            if (
                this.binding?.peripheralId != binding.peripheralId ||
                establishedIdentity != identity ||
                establishedCapabilities != capabilities
            ) {
                failAttempt(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticFailure.REJECTED)
                return
            }
            connectionToken = runSession {
                session.resumeAfterReconnect(reconnect, reconnect.generation)
            } ?: return failAttempt(
                VeepooDiagnosticCategory.RECONNECT,
                VeepooDiagnosticFailure.INVALID_STATE,
            )
            reconnectToken = null
        } else {
            if (connection == null) {
                failAttempt(VeepooDiagnosticCategory.AUTHENTICATION, VeepooDiagnosticFailure.INVALID_STATE)
                return
            }
            val generation = session.snapshot().generation
            val neutralIdentity = BandIdentity(
                sourceIdentity = deviceId,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
                wrapperRevision = WRAPPER_REVISION,
            )
            val report = capabilityReport(neutralIdentity, capabilities)
            if (runSession {
                    session.completeConnection(neutralIdentity, connection, generation)
                    session.acceptCapabilities(report, connection, generation)
                } == null
            ) {
                failAttempt(VeepooDiagnosticCategory.CAPABILITY, VeepooDiagnosticFailure.REJECTED)
                return
            }
            this.binding = binding
            establishedIdentity = identity
            establishedCapabilities = capabilities
            reconnectAddress = binding.peripheralId
        }
        if (reconnectRevisionChanged) {
            val password = reconnectPassword ?: return failAttempt(
                VeepooDiagnosticCategory.RECONNECT,
                VeepooDiagnosticFailure.INVALID_STATE,
                reportRuntimeUnavailable = false,
            )
            val passwordCopy = password.copyOf()
            val persisted = try {
                runCatching {
                    onReconnectRevisionBindingChanged(
                        this,
                        passwordCopy,
                        observedRevisionBinding,
                    )
                }.getOrDefault(false)
            } finally {
                passwordCopy.fill('\u0000')
            }
            if (!persisted) {
                failAttempt(
                    VeepooDiagnosticCategory.RECONNECT,
                    VeepooDiagnosticFailure.UNAVAILABLE,
                    reportRuntimeUnavailable = false,
                )
                notifyReconnectRevisionPersistenceUnavailable()
                return
            }
            reconnectRevisionBinding = observedRevisionBinding
        }
        if (intent == VeepooConnectionIntent.PAIRING) {
            val password = pendingPassword ?: return failAttempt(
                VeepooDiagnosticCategory.AUTHENTICATION,
                VeepooDiagnosticFailure.INVALID_STATE,
            )
            reconnectPassword?.fill('\u0000')
            reconnectPassword = password.copyOf()
            reconnectRevisionBinding = observedRevisionBinding
            provisioningCommit?.close()
            provisioningCommit = VeepooProvisioningCommit(
                binding,
                identity.hardwareRevision,
                identity.firmwareVersion,
                password.copyOf(),
            )
            record(VeepooDiagnosticCategory.PAIRING_CONFIRMATION, VeepooDiagnosticOutcome.COMPLETED)
        }
        clearPairingMaterial()
        startBatteryThenLive(capabilities)
    }

    @Synchronized
    override fun onAuthenticationFailed(
        attempt: VeepooAttemptToken,
        authentication: VeepooAuthenticationToken,
        failure: VeepooFailure,
    ) {
        if (!accept(attempt) || authenticationToken !== authentication) return stale()
        authenticationToken = null
        if (
            intent == VeepooConnectionIntent.RECONNECT &&
            (reconnectToken != null || connectionToken != null) &&
            failure.isTransientReconnectFailure()
        ) {
            scheduleReconnect(
                failure = failure.toDiagnostic(),
                currentAttempt = attempt,
            )
            return
        }
        val reconcileCredential =
            intent == VeepooConnectionIntent.RECONNECT &&
                failure in setOf(VeepooFailure.AUTHENTICATION, VeepooFailure.REJECTED)
        failAttempt(
            VeepooDiagnosticCategory.AUTHENTICATION,
            failure.toDiagnostic(),
            reportRuntimeUnavailable = !reconcileCredential,
        )
        if (reconcileCredential) notifyReconnectCredentialRejected()
    }

    @Synchronized
    override fun onBattery(attempt: VeepooAttemptToken, reading: VeepooBatteryReading) {
        if (!accept(attempt) || mutableState.value != VeepooAdapterState.READING_BATTERY) return
        val token = operationToken ?: return
        if (reading.percent !in 0..100 || reading.observedAtMilliseconds < 0L) {
            failAttempt(VeepooDiagnosticCategory.BATTERY, VeepooDiagnosticFailure.REJECTED)
            return
        }
        if (runSession { session.completeOperation(token) } == null) {
            failAttempt(VeepooDiagnosticCategory.BATTERY, VeepooDiagnosticFailure.INVALID_STATE)
            return
        }
        operationToken = null
        cancelReconnectSchedule()
        reconnectAttemptCount = 0
        mutableDisplay.value = mutableDisplay.value.copy(batteryPercent = reading.percent)
        record(VeepooDiagnosticCategory.BATTERY, VeepooDiagnosticOutcome.COMPLETED)
        startLive()
    }

    @Synchronized
    override fun onLiveHeartRate(attempt: VeepooAttemptToken, reading: VeepooLiveHeartRate) {
        if (!accept(attempt) || mutableState.value != VeepooAdapterState.LIVE_DISPLAY_ONLY) return
        if (reading.beatsPerMinute !in 20..260 || reading.phoneReceiptMilliseconds < 0L) {
            if (!invalidLiveReported) {
                invalidLiveReported = true
                record(
                    VeepooDiagnosticCategory.LIVE_DISPLAY,
                    VeepooDiagnosticOutcome.REJECTED,
                    VeepooDiagnosticFailure.INVALID_INPUT,
                )
            }
            return
        }
        mutableDisplay.value = mutableDisplay.value.copy(
            heartRate = reading.beatsPerMinute,
            phoneReceiptMilliseconds = reading.phoneReceiptMilliseconds,
        )
    }

    @Synchronized
    override fun onConnectionDropped(attempt: VeepooAttemptToken) {
        if (
            !accept(attempt) ||
            transportOwnership != VeepooTransportOwnership.ACTIVE
        ) return
        if (
            intent == VeepooConnectionIntent.RECONNECT &&
            reconnectToken == null &&
            binding == null &&
            connectionToken != null
        ) {
            scheduleReconnect(
                failure = VeepooDiagnosticFailure.DISCONNECTED,
                currentAttempt = attempt,
            )
            return
        }
        if (reconnectToken != null && intent == VeepooConnectionIntent.RECONNECT) {
            scheduleReconnect(
                failure = VeepooDiagnosticFailure.DISCONNECTED,
                currentAttempt = attempt,
            )
            return
        }
        val connection = connectionToken ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        val currentBinding = binding ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        val reconnect = runSession {
            session.interruptForReconnect(connection, session.snapshot().generation)
        } ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.DISCONNECTED,
        )
        reconnectToken = reconnect
        connectionToken = null
        operationToken = null
        intent = VeepooConnectionIntent.RECONNECT
        publishState(VeepooAdapterState.RECONNECTING)
        record(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticOutcome.BEGAN)
        scheduleReconnect(
            failure = VeepooDiagnosticFailure.DISCONNECTED,
            currentAttempt = attempt,
            address = currentBinding.peripheralId,
            stopLive = true,
        )
    }

    @Synchronized
    override fun onFailure(attempt: VeepooAttemptToken, failure: VeepooFailure) {
        if (!accept(attempt)) return
        if (
            mutableState.value == VeepooAdapterState.READING_BATTERY &&
            failure.isTransientReconnectFailure() &&
            beginBatteryReconnect(attempt, failure.toDiagnostic())
        ) {
            return
        }
        if (
            mutableState.value == VeepooAdapterState.LIVE_DISPLAY_ONLY &&
            failure.isTransientReconnectFailure() &&
            beginLiveReconnect(failure.toDiagnostic())
        ) {
            return
        }
        if (
            intent == VeepooConnectionIntent.RECONNECT &&
            (reconnectToken != null || connectionToken != null) &&
            failure.isTransientReconnectFailure()
        ) {
            scheduleReconnect(
                failure = failure.toDiagnostic(),
                currentAttempt = attempt,
            )
            return
        }
        val reconcileCredential =
            intent == VeepooConnectionIntent.RECONNECT &&
                mutableState.value == VeepooAdapterState.AUTHENTICATING &&
                failure in setOf(VeepooFailure.AUTHENTICATION, VeepooFailure.REJECTED)
        failAttempt(
            categoryForState(),
            failure.toDiagnostic(),
            reportRuntimeUnavailable = !reconcileCredential,
        )
        if (reconcileCredential) notifyReconnectCredentialRejected()
    }

    private fun beginAuthentication(password: CharArray): Boolean {
        val current = attempt ?: return false
        val connection = connectionToken
        if (reconnectToken == null) {
            if (connection == null) return false
            if (
                session.snapshot().state != com.noop.bandsdk.BandSessionState.AUTHENTICATING
            ) {
                if (runSession {
                        session.beginAuthentication(connection, session.snapshot().generation)
                    } == null
                ) {
                    failAttempt(
                        VeepooDiagnosticCategory.AUTHENTICATION,
                        VeepooDiagnosticFailure.INVALID_STATE,
                    )
                    return false
                }
            }
        }
        val auth = VeepooAuthenticationToken.create()
        authenticationToken = auth
        publishState(VeepooAdapterState.AUTHENTICATING)
        record(VeepooDiagnosticCategory.AUTHENTICATION, VeepooDiagnosticOutcome.BEGAN)
        val privateCopy = password.copyOf()
        val invoked = contained(VeepooDiagnosticCategory.AUTHENTICATION) {
            bridge.authenticate(privateCopy, current, auth, intent)
        }
        privateCopy.fill('\u0000')
        if (!invoked) {
            authenticationToken = null
            if (intent == VeepooConnectionIntent.RECONNECT) {
                scheduleReconnect(
                    failure = VeepooDiagnosticFailure.INTERNAL,
                    currentAttempt = current,
                )
            } else {
                failAttempt(
                    VeepooDiagnosticCategory.AUTHENTICATION,
                    VeepooDiagnosticFailure.INTERNAL,
                )
            }
        }
        return invoked
    }

    private fun beginBatteryReconnect(
        currentAttempt: VeepooAttemptToken,
        failure: VeepooDiagnosticFailure,
    ): Boolean {
        val token = operationToken ?: return false
        val reconnect = runSession {
            session.failOperation(token, BandFailureCategory.DISCONNECTED)
        } ?: return false
        reconnectToken = reconnect
        connectionToken = null
        operationToken = null
        intent = VeepooConnectionIntent.RECONNECT
        record(VeepooDiagnosticCategory.BATTERY, VeepooDiagnosticOutcome.FAILED, failure)
        scheduleReconnect(
            failure = failure,
            currentAttempt = currentAttempt,
        )
        return true
    }

    private fun beginLiveReconnect(failure: VeepooDiagnosticFailure): Boolean {
        val currentAttempt = attempt ?: return false
        val connection = connectionToken ?: return false
        val currentBinding = binding ?: return false
        val reconnect = runSession {
            session.interruptForReconnect(connection, session.snapshot().generation)
        } ?: return false
        reconnectToken = reconnect
        connectionToken = null
        operationToken = null
        intent = VeepooConnectionIntent.RECONNECT
        record(VeepooDiagnosticCategory.LIVE_DISPLAY, VeepooDiagnosticOutcome.FAILED, failure)
        scheduleReconnect(
            failure = failure,
            currentAttempt = currentAttempt,
            address = currentBinding.peripheralId,
            stopLive = true,
        )
        return true
    }

    private fun scheduleReconnect(
        failure: VeepooDiagnosticFailure,
        currentAttempt: VeepooAttemptToken,
        address: String? = reconnectAddress ?: binding?.peripheralId,
        stopLive: Boolean = false,
    ) {
        if (transportOwnership != VeepooTransportOwnership.ACTIVE) return
        disconnectAttemptForRetry(currentAttempt, stopLive)
        val targetAddress = address ?: return failAttempt(
            VeepooDiagnosticCategory.RECONNECT,
            VeepooDiagnosticFailure.INVALID_STATE,
        )
        cancelReconnectSchedule()
        if (reconnectAttemptCount >= RECONNECT_DELAYS_MILLISECONDS.size) {
            failAttempt(VeepooDiagnosticCategory.RECONNECT, failure)
            return
        }
        val delay = RECONNECT_DELAYS_MILLISECONDS[reconnectAttemptCount]
        reconnectAttemptCount += 1
        publishState(VeepooAdapterState.RECONNECTING)
        record(VeepooDiagnosticCategory.RECONNECT, VeepooDiagnosticOutcome.BEGAN)
        reconnectCancellation = reconnectScheduler.schedule(delay) {
            synchronized(this) {
                if (
                    transportOwnership == VeepooTransportOwnership.ACTIVE &&
                    (reconnectToken != null || connectionToken != null)
                ) {
                    reconnectCancellation = null
                    startReconnectAttempt(targetAddress)
                }
            }
        }
    }

    private fun startReconnectAttempt(address: String) {
        val nextAttempt = VeepooAttemptToken.create()
        attempt = nextAttempt
        intent = VeepooConnectionIntent.RECONNECT
        if (!contained(VeepooDiagnosticCategory.RECONNECT) {
                bridge.connect(
                    VeepooConnectionTarget.KnownAddress(address),
                    nextAttempt,
                    VeepooConnectionIntent.RECONNECT,
                )
            }
        ) {
            scheduleReconnect(
                failure = VeepooDiagnosticFailure.INTERNAL,
                currentAttempt = nextAttempt,
                address = address,
            )
        }
    }

    private fun cancelReconnectSchedule() {
        reconnectCancellation?.cancel()
        reconnectCancellation = null
    }

    private fun notifyReconnectCredentialRejected() {
        runCatching { onReconnectCredentialRejected(this) }
    }

    private fun notifyReconnectRevisionPersistenceUnavailable() {
        runCatching { onReconnectRevisionPersistenceUnavailable(this) }
    }

    private fun notifyRuntimeUnavailable() {
        runCatching { onRuntimeUnavailable(this) }
    }

    private fun startBatteryThenLive(capabilities: VeepooCapabilities) {
        if (capabilities.battery) {
            val token = runSession {
                session.beginOperation(BandOperationClass.BATTERY, BandCapability.BATTERY)
            } ?: return failAttempt(
                VeepooDiagnosticCategory.BATTERY,
                VeepooDiagnosticFailure.INVALID_STATE,
            )
            operationToken = token
            publishState(VeepooAdapterState.READING_BATTERY)
            record(VeepooDiagnosticCategory.BATTERY, VeepooDiagnosticOutcome.BEGAN)
            val current = attempt ?: return
            if (!contained(VeepooDiagnosticCategory.BATTERY) { bridge.readBattery(current) }) {
                if (!beginBatteryReconnect(current, VeepooDiagnosticFailure.INTERNAL)) {
                    failAttempt(
                        VeepooDiagnosticCategory.BATTERY,
                        VeepooDiagnosticFailure.INTERNAL,
                    )
                }
            }
        } else if (capabilities.liveHeartRate) {
            startLive()
        } else {
            publishState(VeepooAdapterState.IDLE)
        }
    }

    private fun startLive() {
        val current = attempt ?: return
        publishState(VeepooAdapterState.LIVE_DISPLAY_ONLY)
        record(VeepooDiagnosticCategory.LIVE_DISPLAY, VeepooDiagnosticOutcome.BEGAN)
        if (!contained(VeepooDiagnosticCategory.LIVE_DISPLAY) {
                bridge.startLiveHeartRate(current)
            }
        ) {
            failAttempt(VeepooDiagnosticCategory.LIVE_DISPLAY, VeepooDiagnosticFailure.INTERNAL)
        }
    }

    private fun capabilityReport(
        identity: BandIdentity,
        capabilities: VeepooCapabilities,
    ): BandCapabilityReport = BandCapabilityReport(
        schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
        reportRevision = WRAPPER_REVISION,
        protocolVersion = identity.protocolVersion,
        hardwareRevision = identity.hardwareRevision,
        firmwareVersion = identity.firmwareVersion,
        historyDays = 0,
        capabilities = buildSet {
            if (capabilities.battery) add(BandCapability.BATTERY)
            if (capabilities.liveHeartRate) add(BandCapability.HEART_RATE)
        },
        // Supplier HR has phone-receipt time only. It is a display capability, not a neutral live stream.
        liveStreams = emptySet(),
        historyStreams = emptySet(),
        operationsAllowedDuringLive = emptySet(),
        streamSemantics = emptyList(),
    )

    private fun failAttempt(
        category: VeepooDiagnosticCategory,
        failure: VeepooDiagnosticFailure,
        reportRuntimeUnavailable: Boolean = true,
    ) {
        if (transportOwnership != VeepooTransportOwnership.ACTIVE) return
        transportOwnership = VeepooTransportOwnership.RELEASED_AFTER_FAILURE
        releaseTransport(VeepooDiagnosticOutcome.FAILED, failure)
        publishState(VeepooAdapterState.FAILED)
        record(category, VeepooDiagnosticOutcome.FAILED, failure)
        if (reportRuntimeUnavailable) notifyRuntimeUnavailable()
    }

    private fun releaseTransport(
        outcome: VeepooDiagnosticOutcome,
        failure: VeepooDiagnosticFailure?,
    ) {
        if (transportReleaseComplete) return
        transportReleaseComplete = true
        cancelReconnectSchedule()
        reconnectScheduler.close()
        val current = attempt
        attempt = null
        if (current != null) {
            contained(VeepooDiagnosticCategory.CLEANUP) { bridge.stopScan(current) }
            contained(VeepooDiagnosticCategory.CLEANUP) { bridge.stopLiveHeartRate(current) }
            contained(VeepooDiagnosticCategory.CLEANUP) { bridge.disconnect(current) }
        }
        contained(VeepooDiagnosticCategory.CLEANUP) { bridge.close() }
        runCatching {
            val snapshot = session.snapshot()
            if (snapshot.state !in setOf(
                    com.noop.bandsdk.BandSessionState.IDLE,
                    com.noop.bandsdk.BandSessionState.CLOSED,
                )
            ) {
                session.disconnect(BandDisconnectReason.USER_PAUSED, snapshot.generation)
            }
            session.close()
        }
        provisioningCommit?.close()
        provisioningCommit = null
        clearPairingMaterial()
        reconnectPassword?.fill('\u0000')
        reconnectPassword = null
        reconnectRevisionBinding = null
        reconnectAddress = null
        scanToken = null
        connectionToken = null
        reconnectToken = null
        reconnectAttemptCount = 0
        operationToken = null
        authenticationToken = null
        binding = null
        establishedIdentity = null
        establishedCapabilities = null
        mutableCandidates.value = emptyList()
        mutableDisplay.value = VeepooDisplayState()
        record(VeepooDiagnosticCategory.CLEANUP, outcome, failure)
    }

    private fun disconnectAttemptForRetry(
        currentAttempt: VeepooAttemptToken,
        stopLive: Boolean = false,
    ) {
        if (attempt === currentAttempt) attempt = null
        authenticationToken = null
        if (stopLive) {
            contained(VeepooDiagnosticCategory.LIVE_DISPLAY) {
                bridge.stopLiveHeartRate(currentAttempt)
            }
        }
        contained(VeepooDiagnosticCategory.RECONNECT) {
            bridge.disconnect(currentAttempt)
        }
    }

    private fun resetAttemptMaterial(clearReconnectPassword: Boolean = true) {
        cancelReconnectSchedule()
        reconnectAttemptCount = 0
        provisioningCommit?.close()
        provisioningCommit = null
        clearPairingMaterial()
        if (clearReconnectPassword) {
            reconnectPassword?.fill('\u0000')
            reconnectPassword = null
        }
        binding = null
        establishedIdentity = null
        establishedCapabilities = null
        selectedHandle = null
        authenticationToken = null
        staleReported = false
        invalidLiveReported = false
    }

    private fun clearPairingMaterial() {
        pendingPassword?.fill('\u0000')
        pendingPassword = null
    }

    private fun accept(value: VeepooAttemptToken): Boolean {
        if (attempt === value) return true
        stale()
        return false
    }

    private fun stale() {
        if (!staleReported) {
            staleReported = true
            record(VeepooDiagnosticCategory.CONNECTION, VeepooDiagnosticOutcome.STALE)
        }
    }

    private fun rejectSelection(failure: VeepooDiagnosticFailure): Boolean {
        record(VeepooDiagnosticCategory.SELECTION, VeepooDiagnosticOutcome.REJECTED, failure)
        return false
    }

    private fun publishState(value: VeepooAdapterState) {
        mutableState.value = value
        mutableDisplay.value = mutableDisplay.value.copy(
            adapterState = value,
            batteryPercent = mutableDisplay.value.batteryPercent
                .takeUnless { value == VeepooAdapterState.RECONNECTING },
            heartRate = mutableDisplay.value.heartRate
                .takeIf { value == VeepooAdapterState.LIVE_DISPLAY_ONLY },
            phoneReceiptMilliseconds = mutableDisplay.value.phoneReceiptMilliseconds
                .takeIf { value == VeepooAdapterState.LIVE_DISPLAY_ONLY },
            active = value != VeepooAdapterState.IDLE &&
                value != VeepooAdapterState.STOPPED &&
                value != VeepooAdapterState.FAILED,
        )
    }

    private fun categoryForState(): VeepooDiagnosticCategory = when (mutableState.value) {
        VeepooAdapterState.SCANNING,
        VeepooAdapterState.CANDIDATES_FOUND,
        -> VeepooDiagnosticCategory.DISCOVERY
        VeepooAdapterState.CONNECTING -> VeepooDiagnosticCategory.CONNECTION
        VeepooAdapterState.AWAITING_PAIRING_CONFIRMATION ->
            VeepooDiagnosticCategory.PAIRING_CONFIRMATION
        VeepooAdapterState.AUTHENTICATING -> VeepooDiagnosticCategory.AUTHENTICATION
        VeepooAdapterState.READING_BATTERY -> VeepooDiagnosticCategory.BATTERY
        VeepooAdapterState.LIVE_DISPLAY_ONLY -> VeepooDiagnosticCategory.LIVE_DISPLAY
        VeepooAdapterState.RECONNECTING -> VeepooDiagnosticCategory.RECONNECT
        else -> VeepooDiagnosticCategory.CLEANUP
    }

    private fun contained(category: VeepooDiagnosticCategory, call: () -> Unit): Boolean =
        try {
            call()
            true
        } catch (_: Throwable) {
            record(category, VeepooDiagnosticOutcome.FAILED, VeepooDiagnosticFailure.INTERNAL)
            false
        }

    private fun <T> runSession(call: () -> T): T? = try {
        call()
    } catch (_: Throwable) {
        null
    }

    private fun record(
        category: VeepooDiagnosticCategory,
        outcome: VeepooDiagnosticOutcome,
        failure: VeepooDiagnosticFailure? = null,
    ) {
        diagnostics.record(VeepooDiagnosticEvent(category, outcome, failure))
    }

    private fun validPassword(value: CharArray): Boolean =
        value.size == 4 && value.all { it in '0'..'9' }

    private fun VeepooFailure.toDiagnostic(): VeepooDiagnosticFailure = when (this) {
        VeepooFailure.UNAVAILABLE -> VeepooDiagnosticFailure.UNAVAILABLE
        VeepooFailure.PERMISSION -> VeepooDiagnosticFailure.PERMISSION
        VeepooFailure.NO_RESULT -> VeepooDiagnosticFailure.NO_RESULT
        VeepooFailure.TIMEOUT -> VeepooDiagnosticFailure.TIMEOUT
        VeepooFailure.REJECTED -> VeepooDiagnosticFailure.REJECTED
        VeepooFailure.AUTHENTICATION -> VeepooDiagnosticFailure.AUTHENTICATION
        VeepooFailure.DISCONNECTED -> VeepooDiagnosticFailure.DISCONNECTED
        VeepooFailure.UNSUPPORTED -> VeepooDiagnosticFailure.UNSUPPORTED
        VeepooFailure.INTERNAL -> VeepooDiagnosticFailure.INTERNAL
    }

    private fun VeepooFailure.isTransientReconnectFailure(): Boolean = when (this) {
        VeepooFailure.NO_RESULT,
        VeepooFailure.TIMEOUT,
        VeepooFailure.DISCONNECTED,
        VeepooFailure.INTERNAL,
        -> true
        VeepooFailure.UNAVAILABLE,
        VeepooFailure.PERMISSION,
        VeepooFailure.REJECTED,
        VeepooFailure.AUTHENTICATION,
        VeepooFailure.UNSUPPORTED,
        -> false
    }

    companion object {
        private const val DIRECT_HANDLE = "known-device"
        private const val WRAPPER_REVISION = VeepooCompatibilityPolicy.WRAPPER_REVISION
        private const val MAX_CANDIDATES = 24
        private val RECONNECT_DELAYS_MILLISECONDS =
            longArrayOf(2_000L, 5_000L, 15_000L)
    }
}
