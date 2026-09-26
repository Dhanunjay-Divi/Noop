package com.noop.ble

import android.content.Context
import android.util.Log
import com.noop.data.DeviceRegistry
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.data.DeviceStatus
import com.noop.data.isActivatableLiveTransport
import com.noop.ble.veepoo.VeepooAdapterState
import com.noop.ble.veepoo.AppVeepooSupplierLifecycleDiagnosticSink
import com.noop.ble.veepoo.VeepooBandSource
import com.noop.ble.veepoo.VeepooBridgeProvider
import com.noop.ble.veepoo.VeepooCandidateHandle
import com.noop.ble.veepoo.VeepooCandidateRow
import com.noop.ble.veepoo.VeepooCompatibilityPolicy
import com.noop.ble.veepoo.VeepooCredentialAccess
import com.noop.ble.veepoo.VeepooCredentialCleanupAccess
import com.noop.ble.veepoo.VeepooCredentialCleanupRead
import com.noop.ble.veepoo.VeepooCredentialRead
import com.noop.ble.veepoo.VeepooDisplayState
import com.noop.ble.veepoo.VeepooManagedSource
import com.noop.ble.veepoo.VeepooProvisioningCommit
import com.noop.ble.veepoo.VeepooSupplierLifecycleDiagnosticSink
import com.noop.ble.veepoo.VeepooSupplierLifecycleFailure
import com.noop.ble.veepoo.VeepooSupplierLifecycleOutcome
import com.noop.ble.veepoo.VeepooSupplierLifecycleStage
import com.noop.ble.veepoo.VeepooSupplierLifecycleTrigger
import com.noop.ble.veepoo.recordSafely
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraWearState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

internal class VeepooPairingAdoption(
    private val registry: DeviceRegistry,
    private val credentials: VeepooCredentialAccess,
    private val cleanup: VeepooCredentialCleanupAccess,
    private val diagnostics: VeepooSupplierLifecycleDiagnosticSink,
) {
    suspend fun commit(
        deviceId: String,
        nickname: String?,
        provisioning: VeepooProvisioningCommit,
        now: Long,
    ): Boolean {
        diagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.ADOPTION,
            outcome = VeepooSupplierLifecycleOutcome.BEGAN,
        )
        return try {
            if (!cleanup.markPending(deviceId)) {
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
                )
                return false
            }
            val saved = runCatching {
                provisioning.saveCredential { password, revisionBinding ->
                    credentials.save(deviceId, password, revisionBinding)
                }
            }.getOrDefault(false)
            if (!saved) {
                val credentialCleared =
                    runCatching { credentials.clear(deviceId) }.getOrDefault(false)
                val cleanupCleared =
                    credentialCleared &&
                        runCatching { cleanup.clearPending(deviceId) }.getOrDefault(false)
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = if (credentialCleared && cleanupCleared) {
                        VeepooSupplierLifecycleOutcome.COMPLETED
                    } else {
                        VeepooSupplierLifecycleOutcome.FAILED
                    },
                    failure = if (credentialCleared && cleanupCleared) {
                        null
                    } else {
                        VeepooSupplierLifecycleFailure.CLEANUP_FAILED
                    },
                )
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.ADOPTION,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.SECURE_PERSISTENCE,
                )
                return false
            }

            val registered = registry.addAndSetActive(
                PairedDeviceRow(
                    id = deviceId,
                    brand = "NOOP",
                    model = "Supplier band",
                    nickname = nickname?.trim()?.takeIf(String::isNotEmpty),
                    peripheralId = provisioning.peripheralId,
                    sourceKind = SourceKind.veepoo.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                ),
                now,
            )
            if (!registered) {
                val cleared = runCatching { credentials.clear(deviceId) }.getOrDefault(false)
                val cleanupCleared =
                    cleared && runCatching { cleanup.clearPending(deviceId) }.getOrDefault(false)
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = if (cleared && cleanupCleared) {
                        VeepooSupplierLifecycleOutcome.COMPLETED
                    } else {
                        VeepooSupplierLifecycleOutcome.FAILED
                    },
                    failure = if (cleared && cleanupCleared) {
                        null
                    } else {
                        VeepooSupplierLifecycleFailure.CLEANUP_FAILED
                    },
                )
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.ADOPTION,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.REGISTRY_PERSISTENCE,
                )
                return false
            }

            if (!runCatching { cleanup.clearPending(deviceId) }.getOrDefault(false)) {
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
                )
            }
            diagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.ADOPTION,
                outcome = VeepooSupplierLifecycleOutcome.COMPLETED,
            )
            true
        } finally {
            provisioning.close()
        }
    }
}

internal object VeepooPendingCredentialCleanup {
    suspend fun reconcile(
        registry: DeviceRegistry,
        credentials: VeepooCredentialAccess,
        cleanup: VeepooCredentialCleanupAccess,
        diagnostics: VeepooSupplierLifecycleDiagnosticSink,
    ) {
        val pending = when (val read = runCatching { cleanup.pendingDeviceIds() }.getOrNull()) {
            is VeepooCredentialCleanupRead.Available -> read.deviceIds
            VeepooCredentialCleanupRead.Unavailable,
            null,
            -> {
                diagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
                )
                return
            }
        }
        if (pending.isEmpty()) return

        val registered = try {
            registry.all()
                .asSequence()
                .filter {
                    it.sourceKind == SourceKind.veepoo.name &&
                        it.status != DeviceStatus.archived.name
                }
                .mapTo(mutableSetOf()) { it.id }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            diagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            )
            return
        }
        for (deviceId in pending.sorted()) {
            val completed = if (deviceId in registered) {
                runCatching { cleanup.clearPending(deviceId) }.getOrDefault(false)
            } else {
                val credentialCleared =
                    runCatching { credentials.clear(deviceId) }.getOrDefault(false)
                credentialCleared &&
                    runCatching { cleanup.clearPending(deviceId) }.getOrDefault(false)
            }
            diagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                outcome = if (completed) {
                    VeepooSupplierLifecycleOutcome.COMPLETED
                } else {
                    VeepooSupplierLifecycleOutcome.FAILED
                },
                failure = if (completed) {
                    null
                } else {
                    VeepooSupplierLifecycleFailure.CLEANUP_FAILED
                },
            )
        }
    }
}

/**
 * Runs exactly ONE device's live BLE at a time, driven by [DeviceRegistry]'s active device id.
 *
 * Faithful Kotlin twin of Strand/BLE/SourceCoordinator.swift.
 *
 * WHOOP-FIRST, ZERO REGRESSION
 * ----------------------------
 * This coordinator is a deliberate NO-OP whenever the active device is the WHOOP (id "my-whoop", any
 * `brand == "WHOOP"` row, OR an unknown id). That is the default state and EVERY state where no generic
 * strap is paired: WHOOP is active, the coordinator does nothing, and the existing WHOOP flow
 * ([WhoopBleClient.connect] via [AppViewModel.connect]) runs exactly as it does today. It only ever
 * *acts* when the active device is a NON-WHOOP generic HR strap:
 *
 *   • switching TO a generic strap → [stopWhoop] (WHOOP's existing disconnect), then start the isolated
 *     [StandardHrSource] for that strap's deviceId.
 *   • switching BACK to WHOOP     → stop the [StandardHrSource], then [startWhoop] (WHOOP's existing scan
 *     entry) — but only if we had actually been on a strap, so a plain launch with WHOOP active does NOT
 *     re-trigger a redundant WHOOP scan.
 *
 * It never imports or references [WhoopBleClient] internals: the WHOOP start/stop are injected closures
 * from the composition root, so the two BLE flows stay fully decoupled (mirrors [StandardHrSource]'s
 * isolation). Live HR from a strap is pushed through [liveSink]; the app wires that to the SAME live
 * state the UI observes (e.g. `ble::publishExternalLiveHr`).
 *
 * On Android the registry exposes the active id as a one-shot suspend read (not a published flow like
 * Swift's `@Published activeDeviceId`), so the app calls [onActiveDeviceChanged] after any registry
 * mutation that can change the active device (the Devices screen's setActive — the next task), and
 * [start] reconciles once against the current active id at launch (a no-op for a single-WHOOP install).
 */
class SourceCoordinator(
    /** Android [Context] for the strap source's own scanner/GATT. Non-null in production (set at the
     *  composition root); nullable ONLY so the registry-driven paths (e.g. identity adoption) are
     *  exercisable on the plain JVM without Android — required at the single strap-path use site. */
    private val context: Context?,
    private val registry: DeviceRegistry,
    /** The store the strap source persists into. Non-null in production; nullable for the same JVM-test
     *  reason as [context] — required at the single strap-path use site, untouched by the WHOOP/adoption
     *  paths. */
    private val repository: WhoopRepository?,
    /** Push a strap's live HR/R-R into whatever the UI observes (e.g. `ble::publishExternalLiveHr`). */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Re-trigger WHOOP's EXISTING scan/connect entry point (e.g. `AppViewModel.connect`). */
    private val startWhoop: () -> Unit,
    /** Pause WHOOP via its EXISTING teardown (e.g. `AppViewModel.disconnect` → `ble.disconnect`). */
    private val stopWhoop: () -> Unit,
    /**
     * Pin the WHOOP connection to ONE strap by its persisted `peripheralId` (the MAC address), or null to
     * clear the pin back to "connect to the first WHOOP found". Wraps [WhoopBleClient.preferredAddress].
     * Called only on a WHOOP transition; nil on the legacy "my-whoop" path (unchanged). Default no-op keeps
     * the existing `SourceCoordinator(...)` call sites compiling unchanged. (MW-2/MW-3)
     */
    private val setWhoopPreferredAddress: (String?) -> Unit = {},
    /**
     * Re-point which device id live WHOOP samples store under. Wraps [WhoopBleClient.setActiveDeviceId].
     * Called ONLY when the active WHOOP is NOT the seeded "my-whoop" - the single-WHOOP path never invokes
     * it, so the id stays "my-whoop". Default no-op keeps existing call sites compiling unchanged. (MW-3)
     */
    private val setWhoopActiveDeviceId: (String) -> Unit = {},
    /** Background scope for the suspend registry reads + persist. SupervisorJob keeps one failure from
     *  cancelling the others; IO keeps DB work off the main thread. */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    /** Diagnostic sink for the multi-WHOOP identity-adoption "different strap connected" notice - the
     *  Android analogue of Swift's `live.append(log:)`. Defaults to logcat; tests inject a capturing
     *  closure to assert the wording. Inert on the single-WHOOP path (the message only fires on a
     *  registered-but-mismatched strap). */
    private val log: (String) -> Unit = { Log.i("SourceCoordinator", it) },
    /** Diagnostic sink for the ISOLATED generic-HR source's connect lifecycle. Wired at the composition
     *  root to [WhoopBleClient.externalLog] so generic-HR lines land in the SAME in-app strap log the user
     *  exports (issue #421 — the Polar/Wahoo/Coospo/Garmin-HRM path was previously invisible). Passed into
     *  [StandardHrSource] as its `log`; kept SEPARATE from [log] above (which defaults to logcat and only
     *  carries the multi-WHOOP adoption notice). Default no-op keeps existing call sites compiling. */
    private val straplog: (String) -> Unit = {},
    /**
     * Default-off app seam for the supplier-neutral NOOP Band SDK adapter. Production composition
     * roots leave this null until a reviewed supplier transport exists. Tests inject a source to prove
     * lifecycle ownership without registering a fake device kind or changing the WHOOP path.
     */
    private val noopBandSourceFactory: ((String, PairedDeviceRow?) -> LiveHrSource?)? = null,
    /** Optional supplier bridge. Null in normal builds; reflection loads it only in explicitly wired builds. */
    private val veepooBridgeProvider: VeepooBridgeProvider? = null,
    /** Plain-JVM seam for pairing lifecycle tests. Production always leaves this null. */
    private val veepooPairingSourceFactory: ((String) -> VeepooManagedSource)? = null,
    /** Plain-JVM seam for persisted supplier activation after secure credential validation. */
    private val veepooActiveSourceFactory:
        ((String, com.noop.ble.veepoo.VeepooStoredCredential) -> LiveHrSource)? = null,
    private val veepooCredentials: VeepooCredentialAccess? = null,
    private val veepooCredentialCleanup: VeepooCredentialCleanupAccess? = null,
    private val veepooLifecycleDiagnostics: VeepooSupplierLifecycleDiagnosticSink =
        AppVeepooSupplierLifecycleDiagnosticSink,
    private val supplierCredentialRetryDelaysMillis: List<Long> =
        listOf(1_000L, 5_000L, 15_000L),
    private val supplierCredentialRecoveryDelayMillis: Long? = null,
    /** Publish a verified registry correction through the process-wide active-source projection. */
    private val onDurableActiveDeviceChanged: (String) -> Unit = {},
    /** Push a strap's battery percent into the live state (e.g. `ble::publishExternalBattery`), so a
     *  generic strap / FTMS machine surfaces its charge where the WHOOP strap battery does. Default no-op
     *  keeps existing call sites + JVM tests compiling unchanged. */
    private val batterySink: (Int) -> Unit = {},
    /** Push the latest instantaneous speed/cadence/power from a connected standard fitness sensor
     *  (RSC/CSC/CPS), read ADDITIVELY alongside HR by [StandardHrSource], into the live state the in-workout
     *  UI observes (wired at the composition root to `ble::publishExternalSensorMetrics`). PURE ADDITIVE — it
     *  never touches HR/R-R/persistence/scoring, only the additive sensor readout. Forwarded only on the
     *  generic-HR strap path (a footpod / bike sensor / power meter rides StandardHrSource). Default no-op
     *  keeps existing call sites + JVM tests compiling unchanged. */
    private val sensorSink: (StandardHrSource.SensorMetrics) -> Unit = {},
) {
    private val veepooCompatibilityPolicy: VeepooCompatibilityPolicy by lazy(
        LazyThreadSafetyMode.SYNCHRONIZED,
    ) {
        context?.let {
            VeepooCompatibilityPolicy.loadFromAssets(
                it,
                allowUnlistedQualification =
                    com.noop.BuildConfig.DEBUG &&
                        com.noop.BuildConfig.VEEPOO_QUALIFICATION_MODE,
            )
        }
            ?: VeepooCompatibilityPolicy.invalid()
    }

    /** Latest instantaneous speed/cadence/power from the active standard fitness sensor (RSC/CSC/CPS),
     *  read ADDITIVELY alongside HR by [StandardHrSource]. The in-workout UI observes this to surface the
     *  values beside heart rate. PURE ADDITIVE — fed only by the generic-HR strap path; reset to empty when
     *  no strap source is live, so a stale readout can't outlive the link. Never carries HR / scoring. */
    private val _sensorMetrics = MutableStateFlow(StandardHrSource.SensorMetrics())
    val sensorMetrics: StateFlow<StandardHrSource.SensorMetrics> = _sensorMetrics.asStateFlow()

    /** The active Oura source's live adopt outcome, mirrored so the Add-Oura wizard can leave its Adopting
     *  step (success -> close, failed -> the honest Failed step). [AdoptPhase.Idle] whenever no Oura source
     *  is live, so a stale outcome never drives a wizard transition. Mirrors Swift `AppModel.ouraAdoptPhase`. */
    private val _ouraAdoptPhase = MutableStateFlow(OuraLiveSource.AdoptPhase.Idle)
    val ouraAdoptPhase: StateFlow<OuraLiveSource.AdoptPhase> = _ouraAdoptPhase.asStateFlow()

    /** The active Oura source's honest needs-pairing message (null when none). The wizard treats a non-null
     *  value during Adopting as an honest failure too (covers no-ack / ack!=OK paths). null whenever no Oura
     *  source is live. Mirrors Swift `AppModel.ouraNeedsPairing`. */
    private val _ouraNeedsPairing = MutableStateFlow<String?>(null)
    val ouraNeedsPairing: StateFlow<String?> = _ouraNeedsPairing.asStateFlow()

    /** The active Oura source's live wear/charge state (worn / charging / off), or null when no Oura source
     *  is live. Drives the Live screen's On-wrist / Off-wrist read (#628). Mirrors iOS `LiveState.ouraWearState`. */
    private val _ouraWearState = MutableStateFlow<OuraWearState?>(null)
    val ouraWearState: StateFlow<OuraWearState?> = _ouraWearState.asStateFlow()

    val veepooAvailable: Boolean
        get() =
            (veepooBridgeProvider != null || veepooPairingSourceFactory != null) &&
                veepooCredentials != null

    /**
     * A durable supplier row is usable when its credential exists, or when the protected store is
     * temporarily unavailable and cannot yet prove the credential missing. Any loaded password is
     * zeroed before this check returns.
     */
    fun hasUsableVeepooRegistration(deviceId: String): Boolean {
        val credentialStore = veepooCredentials ?: return false
        return when (val read = credentialStore.readForRetention(deviceId)) {
            is VeepooCredentialRead.Available -> {
                try {
                    true
                } finally {
                    read.credential.close()
                }
            }
            VeepooCredentialRead.Missing -> false
            VeepooCredentialRead.Unavailable -> true
        }
    }

    private val _veepooCandidates = MutableStateFlow<List<VeepooCandidateRow>>(emptyList())
    val veepooCandidates: StateFlow<List<VeepooCandidateRow>> = _veepooCandidates.asStateFlow()
    private val _veepooDisplay = MutableStateFlow(VeepooDisplayState())
    val veepooDisplay: StateFlow<VeepooDisplayState> = _veepooDisplay.asStateFlow()
    private val _veepooPairingState = MutableStateFlow(VeepooAdapterState.IDLE)
    val veepooPairingState: StateFlow<VeepooAdapterState> = _veepooPairingState.asStateFlow()

    /** Collects the active Oura source's adoptPhase / needsPairing into the mirrors above; cancelled and
     *  nulled on teardown so a forgotten ring never leaks a stale outcome. */
    private var ouraStateJob: kotlinx.coroutines.Job? = null
    private var veepooActiveDisplayJob: kotlinx.coroutines.Job? = null
    private var veepooPairingStateJob: kotlinx.coroutines.Job? = null
    private var veepooPairingSource: VeepooManagedSource? = null
    private var veepooPairingDeviceId: String? = null
    private val veepooPairingRequestGeneration = AtomicLong()
    private val veepooPairingGeneration = AtomicLong()
    private sealed interface PausedTransport {
        val deviceId: String

        data class Whoop(override val deviceId: String) : PausedTransport
        data class Strap(override val deviceId: String) : PausedTransport
    }

    private var veepooPairingPausedTransport: PausedTransport? = null
    private var pendingReconcileId: String? = null
    private var supplierCredentialRetryJob: Job? = null
    private var supplierCredentialRetryDeviceId: String? = null
    private val supplierCredentialRetryGeneration = AtomicLong()

    /** The single non-WHOOP source currently live — a generic HR strap, FTMS machine, Huami band, or Oura
     *  ring — held behind the [LiveHrSource] interface. null while WHOOP is active or nothing else is
     *  paired. Exactly one non-WHOOP source is ever live at a time, and the coordinator only ever connects /
     *  scans / stops it. Built by [makeSource]; each source owns its OWN scanner/GATT and never touches the
     *  WHOOP BLE client, so the WHOOP path cannot regress. (An Oura ring additionally surfaces only its OWN
     *  raw signals + open event tags — NOOP computes its own Charge/Rest — never Oura's encrypted scores.) */
    private var activeSource: LiveHrSource? = null
    /** The deviceId the active non-WHOOP source ([activeSource]) runs for. */
    private var activeStrapId: String? = null
    /** The WHOOP registry id we last pointed the connection at, so a WHOOP→WHOOP switch is detected and a
     *  repeat activation of the SAME WHOOP is a no-op. null until the first WHOOP activation. (MW-3) */
    private var activeWhoopId: String? = null
    /** True once we've transitioned onto a generic strap. While false (the default / WHOOP-active state)
     *  switching to WHOOP is a pure no-op — we never issue a redundant WHOOP (re)scan. */
    private var onStrap = false
    /** The last active id we reconciled, so a repeated [onActiveDeviceChanged] for the same id is a no-op
     *  (mirrors Swift's `removeDuplicates()` on the published active id). */
    private var lastSeenId: String? = null
    /** The address of the strap the WHOOP link is CURRENTLY connected to, learned from
     *  [connectedPeripheralChanged]. Lets a WHOOP→WHOOP make-active adopt IN PLACE when the newly-activated
     *  row is the same physical strap (#74 keep): a stop/start churn there would drop the live link and
     *  reconnect through the scan path. Cleared on disconnect (null address). */
    private var connectedWhoopAddress: String? = null
    /** Registry row that owns the current physical WHOOP connection. Captured after the address guard
     *  passes so a disconnect can stamp the correct row even if active-device selection changed. */
    private var connectedWhoopRegistryId: String? = null

    /** Serializes [reconcile] so two device switches — or [start] racing [onActiveDeviceChanged] — can't
     *  interleave on the multi-threaded [scope] (Dispatchers.IO is a pool) and leak a half-torn-down live
     *  source. The Swift twin gets this free from `@MainActor`; on Android we serialize the state machine
     *  explicitly. The persist launches stay OUTSIDE this lock (they touch no coordinator state). (ryanbr, #1031) */
    private val reconcileLock = Mutex()

    /**
     * Reconcile once against the CURRENT active id (launch). For a single-WHOOP install this resolves to
     * the WHOOP and is a pure no-op, so the existing WHOOP startup is untouched.
     */
    fun start() {
        scope.launch {
            reconcileLock.withLock {
                reconcilePendingSupplierCredentialCleanup()
                val id = registry.activeDeviceId() ?: WhoopBleClient.DEFAULT_DEVICE_ID
                reconcile(id)
            }
        }
    }

    /**
     * Called by the app after a registry mutation that can change the active device (Devices-screen
     * setActive). Resolves the device for [id] and reconciles which live source runs. Idempotent: a
     * repeated call for the same id is dropped (the `removeDuplicates()` equivalent).
     */
    fun onActiveDeviceChanged(id: String) {
        scope.launch { reconcileLock.withLock { reconcile(id) } }
    }

    suspend fun beginVeepooPairing(): Boolean {
        if (!veepooAvailable) return false
        val requestGeneration = veepooPairingRequestGeneration.incrementAndGet()
        return reconcileLock.withLock {
            if (veepooPairingRequestGeneration.get() != requestGeneration) {
                return@withLock false
            }
            reconcilePendingSupplierCredentialCleanup()
            cancelSupplierCredentialRetry()
            val generation = veepooPairingGeneration.incrementAndGet()
            clearVeepooPairingLocked(restoreTransport = false)
            if (!pauseActiveTransportForPairing()) return@withLock false
            val deviceId = "supplier-${UUID.randomUUID()}"
            val source = runCatching {
                veepooPairingSourceFactory?.invoke(deviceId) ?: run {
                    val provider = requireNotNull(veepooBridgeProvider)
                    VeepooBandSource(
                        deviceId = deviceId,
                        bridge = provider.create(requireNotNull(context)),
                        compatibilityPolicy = veepooCompatibilityPolicy,
                    )
                }
            }.getOrNull() ?: run {
                restorePausedTransportAfterPairingLocked()
                return@withLock false
            }
            veepooPairingSource = source
            veepooPairingDeviceId = deviceId
            mirrorVeepooPairing(source, generation)
            val scanStarted = runCatching {
                source.scan()
                true
            }.getOrDefault(false)
            if (!scanStarted) {
                clearVeepooPairingLocked(
                    restoreTransport = true,
                    expectedGeneration = generation,
                )
                return@withLock false
            }
            true
        }
    }

    suspend fun selectVeepooCandidate(handle: VeepooCandidateHandle): Boolean =
        reconcileLock.withLock {
            val source = veepooPairingSource ?: return@withLock false
            val selected = source.selectCandidate(handle)
            if (!selected) clearVeepooPairingLocked(restoreTransport = true)
            selected
        }

    fun submitVeepooPairing(transportPassword: CharArray): Boolean {
        val source = veepooPairingSource ?: return false
        return try {
            source.submitPairing(transportPassword)
        } finally {
            transportPassword.fill('\u0000')
        }
    }

    suspend fun commitVeepooPairing(nickname: String?): String? =
        reconcileLock.withLock {
            val generation = veepooPairingGeneration.get()
            val source = veepooPairingSource ?: return@withLock null
            val deviceId = veepooPairingDeviceId ?: return@withLock null
            val credentialStore = veepooCredentials
            val credentialCleanup = veepooCredentialCleanup
            if (credentialStore == null || credentialCleanup == null) {
                veepooLifecycleDiagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.ADOPTION,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    failure = VeepooSupplierLifecycleFailure.SECURE_PERSISTENCE,
                )
                clearVeepooPairingLocked(
                    restoreTransport = true,
                    expectedGeneration = generation,
                )
                return@withLock null
            }
            val commit = source.takeProvisioningCommit() ?: return@withLock null
            val now = System.currentTimeMillis() / 1000
            val adopted = VeepooPairingAdoption(
                registry = registry,
                credentials = credentialStore,
                cleanup = credentialCleanup,
                diagnostics = veepooLifecycleDiagnostics,
            ).commit(
                deviceId = deviceId,
                nickname = nickname,
                provisioning = commit,
                now = now,
            )
            if (!adopted) {
                clearVeepooPairingLocked(
                    restoreTransport = true,
                    expectedGeneration = generation,
                )
                return@withLock null
            }

            clearVeepooPairingLocked(
                restoreTransport = false,
                expectedGeneration = generation,
            )
            pendingReconcileId = null
            veepooPairingPausedTransport = null
            runCatching { onDurableActiveDeviceChanged(deviceId) }
            lastSeenId = null
            reconcile(deviceId)
            deviceId
        }

    /**
     * Stop and archive a supplier row as one durable lifecycle. A pending-cleanup marker is written before
     * the source stops, the registry archive commits while the credential remains usable, and secure
     * deletion follows. Post-archive cleanup failure leaves the marker for startup reconciliation.
     */
    suspend fun archiveVeepooDevice(id: String): Boolean = reconcileLock.withLock {
        val row = runCatching { registry.all().firstOrNull { it.id == id } }.getOrNull()
            ?: return@withLock false
        if (
            row.sourceKind != SourceKind.veepoo.name ||
            row.status == DeviceStatus.archived.name
        ) {
            return@withLock false
        }

        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.REMOVAL,
            outcome = VeepooSupplierLifecycleOutcome.BEGAN,
            trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
        )

        val credentialStore = veepooCredentials
        val credentialCleanup = veepooCredentialCleanup
        if (credentialStore == null || credentialCleanup == null) {
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            )
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.REMOVAL,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            )
            return@withLock false
        }
        val markedPending =
            runCatching { credentialCleanup.markPending(id) }.getOrDefault(false)
        if (!markedPending) {
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            )
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.REMOVAL,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            )
            return@withLock false
        }
        val wasDurablyActive = row.status == DeviceStatus.active.name
        val stoppedActiveSource = wasDurablyActive && activeStrapId == id
        if (stoppedActiveSource) {
            tearDownNonWhoopSource()
            activeStrapId = null
            // Keep onStrap true until the archive commits. WHOOP remains paused and must be resumed if this
            // removal is rolled back or reconciled to a fallback.
            onStrap = true
        }

        val archiveOutcome = registry.archiveSupplierAndSelectFallback(id)
        if (archiveOutcome == null) {
            val markerCleared =
                runCatching { credentialCleanup.clearPending(id) }.getOrDefault(false)
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                outcome = if (markerCleared) {
                    VeepooSupplierLifecycleOutcome.COMPLETED
                } else {
                    VeepooSupplierLifecycleOutcome.FAILED
                },
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = if (markerCleared) {
                    null
                } else {
                    VeepooSupplierLifecycleFailure.CLEANUP_FAILED
                },
            )
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.REMOVAL,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
                failure = VeepooSupplierLifecycleFailure.REGISTRY_PERSISTENCE,
            )
            if (stoppedActiveSource) reconcileCurrentDurableSource()
            return@withLock false
        }

        if (wasDurablyActive) {
            activeStrapId = null
            lastSeenId = null
            val fallback = archiveOutcome.activeDeviceId
            if (fallback != null) {
                runCatching { onDurableActiveDeviceChanged(fallback) }
                reconcile(fallback)
            } else {
                onStrap = false
            }
        }

        val credentialCleared =
            runCatching { credentialStore.clear(id) }.getOrDefault(false)
        val markerCleared = credentialCleared &&
            runCatching { credentialCleanup.clearPending(id) }.getOrDefault(false)
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
            outcome = if (credentialCleared && markerCleared) {
                VeepooSupplierLifecycleOutcome.COMPLETED
            } else {
                VeepooSupplierLifecycleOutcome.FAILED
            },
            trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
            failure = if (credentialCleared && markerCleared) {
                null
            } else {
                VeepooSupplierLifecycleFailure.CLEANUP_FAILED
            },
        )
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.REMOVAL,
            outcome = VeepooSupplierLifecycleOutcome.COMPLETED,
            trigger = VeepooSupplierLifecycleTrigger.DEVICE_REMOVAL,
        )
        true
    }

    fun cancelVeepooPairing() {
        veepooPairingRequestGeneration.incrementAndGet()
        val generation = veepooPairingGeneration.get()
        if (reconcileLock.tryLock()) {
            try {
                clearVeepooPairingLocked(
                    restoreTransport = true,
                    expectedGeneration = generation,
                )
            } finally {
                reconcileLock.unlock()
            }
            return
        }
        scope.launch {
            reconcileLock.withLock {
                clearVeepooPairingLocked(
                    restoreTransport = true,
                    expectedGeneration = generation,
                )
            }
        }
    }

    internal fun onVeepooAuthenticationRejected(id: String, source: LiveHrSource) {
        scope.launch {
            reconcileLock.withLock {
                if (activeStrapId == id) {
                    if (activeSource === source) {
                        detachTerminalSupplierSource(source)
                    } else {
                        // Removal rollback may have recreated this id while the rejection waited for the lock.
                        // That replacement uses the same rejected credential and must be stopped normally.
                        tearDownNonWhoopSource()
                        activeStrapId = null
                        onStrap = true
                    }
                }
                val credentialStore = veepooCredentials
                val cleared = credentialStore?.let {
                    runCatching { it.clear(id) }.getOrDefault(false)
                } ?: false
                veepooLifecycleDiagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_CLEANUP,
                    outcome = if (cleared) {
                        VeepooSupplierLifecycleOutcome.COMPLETED
                    } else {
                        VeepooSupplierLifecycleOutcome.FAILED
                    },
                    trigger = VeepooSupplierLifecycleTrigger.AUTHENTICATION_REJECTED,
                    failure = if (cleared) null else VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
                )
                reconcileUnavailableSupplier(
                    id = id,
                    trigger = VeepooSupplierLifecycleTrigger.AUTHENTICATION_REJECTED,
                    preferredTransportDeviceId = null,
                )
            }
        }
    }

    internal fun persistVeepooReconnectRevision(
        id: String,
        source: LiveHrSource,
        password: CharArray,
        revisionBinding: com.noop.ble.veepoo.VeepooRevisionBinding,
    ): Boolean {
        if (activeStrapId != id || activeSource !== source) return false
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.SECURE_WRITE,
            outcome = VeepooSupplierLifecycleOutcome.BEGAN,
            trigger = VeepooSupplierLifecycleTrigger.REVISION_REBIND,
        )
        val saved = veepooCredentials?.let { credentials ->
            runCatching {
                credentials.save(
                    deviceId = id,
                    password = password,
                    revisionBinding = revisionBinding,
                )
            }.getOrDefault(false)
        } ?: false
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.SECURE_WRITE,
            outcome = if (saved) {
                VeepooSupplierLifecycleOutcome.COMPLETED
            } else {
                VeepooSupplierLifecycleOutcome.FAILED
            },
            trigger = VeepooSupplierLifecycleTrigger.REVISION_REBIND,
            failure = if (saved) null else VeepooSupplierLifecycleFailure.SECURE_PERSISTENCE,
        )
        return saved
    }

    internal fun onVeepooRevisionPersistenceUnavailable(
        id: String,
        source: LiveHrSource,
    ) {
        scope.launch {
            reconcileLock.withLock {
                if (activeStrapId != id || activeSource !== source) return@withLock
                detachTerminalSupplierSource(source)
                lastSeenId = null
                scheduleSupplierCredentialRetry(id)
            }
        }
    }

    internal fun onVeepooRuntimeUnavailable(id: String, source: LiveHrSource) {
        scope.launch {
            reconcileLock.withLock {
                if (activeStrapId != id || activeSource !== source) return@withLock
                detachTerminalSupplierSource(source)
                reconcileUnavailableSupplier(
                    id = id,
                    trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                    preferredTransportDeviceId = null,
                )
            }
        }
    }

    /**
     * The BLE engine connected to a WHOOP strap at [address] (null on disconnect). Persist that stable
     * identity onto the CURRENTLY ACTIVE device when it's a WHOOP and hasn't adopted one yet — so the
     * legacy "my-whoop" learns its strap's address on first connect, and a freshly-paired WHOOP confirms
     * its identity. Faithful twin of macOS `SourceCoordinator.connectedPeripheralChanged(to:)` (the sink
     * fed by `BLEManager.connectedPeripheralUUID`), INCLUDING the different-strap guard.
     *
     * Guards (so this never corrupts the registry):
     *   • null address (a disconnect/never-connected republish) → ignore.
     *   • the active device is NOT a WHOOP (a generic strap is active) → ignore; this connection isn't ours.
     *   • the active WHOOP already has a DIFFERENT non-null peripheralId → a different strap connected; LOG
     *     it and do NOT clobber the stored identity (would mis-map another strap's samples onto this row).
     *   • it already matches → nothing to write.
     */
    fun connectedPeripheralChanged(address: String?) {
        // Track the live strap's address for the WHOOP->WHOOP adopt-in-place skip (#74). A null address is a
        // disconnect/never-connected republish: clear it so a later make-active can't wrongly match a stale
        // link, then fall through to the existing ignore.
        connectedWhoopAddress = address
        if (address == null) {
            val disconnectedId = connectedWhoopRegistryId
            connectedWhoopRegistryId = null
            if (disconnectedId != null) scope.launch { registry.touchLastSeen(disconnectedId) }
            return
        }
        scope.launch {
            val activeId = registry.activeDeviceId() ?: return@launch
            val devices = registry.all()
            val row = devices.firstOrNull { it.id == activeId }
            if (!isWhoop(activeId, devices) || row == null) return@launch

            val existing = row.peripheralId
            when {
                existing == null -> {
                    // First connect for this WHOOP row → adopt the strap's stable identity (its address).
                    registry.setPeripheralId(activeId, address)
                    connectedWhoopRegistryId = activeId
                    registry.touchLastSeen(activeId)
                }
                existing.equals(address, ignoreCase = true) -> {
                    // Already adopted this exact strap. Stamp only this real connection transition; high-
                    // rate sample packets never pass through the coordinator.
                    connectedWhoopRegistryId = activeId
                    registry.touchLastSeen(activeId)
                }
                else ->
                    // A DIFFERENT strap connected under this WHOOP row. Never silently overwrite — that would
                    // mis-map another physical strap's samples onto this device. Log and leave the stored id.
                    log(
                        "Multi-WHOOP: active device $activeId is registered to strap $existing but " +
                            "$address connected - not overwriting.",
                    )
            }
        }
    }

    private suspend fun reconcile(id: String) {
        if (supplierCredentialRetryDeviceId != null &&
            supplierCredentialRetryDeviceId != id
        ) {
            cancelSupplierCredentialRetry()
        }
        if (veepooPairingSource != null) {
            pendingReconcileId = id
            return
        }
        if (id == lastSeenId) return
        lastSeenId = id
        val devices = try {
            registry.all()
        } catch (_: Throwable) {
            lastSeenId = null
            straplog("SourceCoordinator: registry reconciliation failed")
            return
        }
        // CONTAIN every device-switch failure here. reconcile is the single entry point for both
        // start() (launch, against the PERSISTED active id) and onActiveDeviceChanged(), and it runs
        // inside a bare `scope.launch {}` — a SupervisorJob does NOT stop an uncaught throw from
        // killing the process, so before this guard a throw while activating a generic strap crashed
        // the app, and because the active id is persisted it crash-LOOPED on every launch (#421
        // regression: making a Polar H10 active bricked the app). A strap switch must never crash the
        // app. We log the exception into the EXPORTABLE strap log too, so the next shared log reveals
        // the exact underlying throw, and reset lastSeenId so the user can retry after switching away.
        try {
            val row = devices.firstOrNull { it.id == id }
            when {
                isWhoop(id, devices) &&
                    (row == null || row.isActivatableLiveTransport) ->
                    switchToWhoop(id, devices)
                row?.isActivatableLiveTransport == true -> switchToStrap(id, devices)
                else -> {
                    lastSeenId = null
                    straplog("SourceCoordinator: selected source is not a live transport")
                }
            }
        } catch (t: Throwable) {
            lastSeenId = null
            if (devices.firstOrNull { it.id == id }?.sourceKind == SourceKind.veepoo.name) {
                straplog("Supplier band: activation failed")
            } else {
                log("SourceCoordinator: device switch to '$id' failed: ${t.javaClass.simpleName}: ${t.message}")
                straplog("HR-strap: activating this device failed (${t.javaClass.simpleName}: ${t.message}) - " +
                    "staying on the previous source. Please share this log so we can fix it.")
            }
        }
    }

    /**
     * Active device is a WHOOP ([id]). Three churn-guarded sub-cases, mirroring macOS
     * `SourceCoordinator.switchToWhoop`:
     *   • Already streaming this exact WHOOP with no strap in between → pure no-op (the dormant default;
     *     the single-WHOOP launch lands here and touches nothing but the initial preferred-address).
     *   • Coming back from a generic strap → stop that source, point WHOOP at this id, resume its scan.
     *   • A DIFFERENT WHOOP → drop the current link, re-point (preferred address + deviceId), reconnect.
     */
    private fun switchToWhoop(id: String, devices: List<PairedDeviceRow>) {
        val peripheralId = devices.firstOrNull { it.id == id }?.peripheralId
        val pausedWhoop = veepooPairingPausedTransport as? PausedTransport.Whoop
        if (!onStrap && pausedWhoop?.deviceId == id) {
            veepooPairingPausedTransport = null
            pointWhoop(id, peripheralId)
            startWhoop()
            return
        }

        // Already streaming this exact WHOOP with no strap in between → nothing to do.
        if (!onStrap && activeWhoopId == id) return

        when {
            onStrap -> {
                // Coming back from a generic strap / FTMS machine: tear that source down first, then resume.
                tearDownNonWhoopSource()
                activeStrapId = null
                onStrap = false
                veepooPairingPausedTransport = null
                pointWhoop(id, peripheralId)
                startWhoop()
            }
            activeWhoopId == null -> {
                // First WHOOP activation of the session (the normal launch path). Set the targeting so the
                // existing WHOOP flow - kicked off elsewhere on launch - uses it. For the seeded "my-whoop"
                // (peripheralId null, id "my-whoop") this is setWhoopPreferredAddress(null) and NO
                // setActiveDeviceId / NO scan / NO disconnect: byte-for-byte today's behaviour.
                veepooPairingPausedTransport = null
                pointWhoop(id, peripheralId)
            }
            peripheralId != null && peripheralId.equals(connectedWhoopAddress, ignoreCase = true) -> {
                // WHOOP → the SAME physical strap (make-active on the row we're already connected to, e.g. the
                // pick-same-strap Add flow): adopt IN PLACE. A stop/start churn here would drop the #74-kept
                // live link and force a scan reconnect (wrong-family default + OS-bond status=133). Just
                // re-point the targeting so samples land under this id; the connection is untouched.
                veepooPairingPausedTransport = null
                pointWhoop(id, peripheralId)
            }
            else -> {
                // WHOOP → a DIFFERENT WHOOP: drop the current link, re-point, and reconnect.
                veepooPairingPausedTransport = null
                stopWhoop()
                pointWhoop(id, peripheralId)
                startWhoop()
            }
        }
    }

    /**
     * Apply the WHOOP targeting for the now-active WHOOP [id]. Always sets the preferred address (null for
     * the legacy "my-whoop" → connect to any WHOOP, unchanged). Re-points the sample deviceId ONLY for a
     * non-legacy WHOOP - the seeded "my-whoop" keeps the bootstrap-set id, so the single-WHOOP path never
     * calls setActiveDeviceId. Records [activeWhoopId] for future change detection. Mirrors macOS
     * `pointWhoop`.
     */
    private fun pointWhoop(id: String, peripheralId: String?) {
        setWhoopPreferredAddress(peripheralId)
        if (id != WhoopBleClient.DEFAULT_DEVICE_ID) {
            setWhoopActiveDeviceId(id)
        }
        activeWhoopId = id
    }

    /**
     * Active device is a generic strap. Pause WHOOP (once, on the WHOOP→strap edge) and run the isolated
     * [StandardHrSource] for this strap's deviceId. Re-running for the SAME id is a no-op.
     */
    private suspend fun switchToStrap(id: String, devices: List<PairedDeviceRow>) {
        if (activeStrapId == id && activeSource != null) return
        val row = devices.firstOrNull { it.id == id }
            ?.takeIf { it.isActivatableLiveTransport }
            ?: error("Selected source is not an activatable live transport")
        val supplier = row.sourceKind == SourceKind.veepoo.name
        val previousTransportDeviceId = currentTransportDeviceId(excluding = id)

        // Construct the supplier source before disturbing the source that is already running. A missing
        // provider, credential, or valid reflected bridge therefore leaves that transport live while the
        // durable active row is reconciled back to it.
        val source = try {
            makeSource(id, row)
        } catch (_: SupplierCredentialTemporarilyUnavailable) {
            quiesceCurrentTransportForSupplierRetry()
            lastSeenId = null
            val retryAlreadyActive =
                supplierCredentialRetryJob?.isActive == true &&
                    supplierCredentialRetryDeviceId == id
            if (!retryAlreadyActive) {
                veepooLifecycleDiagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_READ,
                    outcome = VeepooSupplierLifecycleOutcome.FAILED,
                    trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                    failure = VeepooSupplierLifecycleFailure.SECURE_READ_UNAVAILABLE,
                )
            }
            scheduleSupplierCredentialRetry(id)
            return
        } catch (failure: Throwable) {
            if (!supplier) throw failure
            straplog("Supplier band: adapter unavailable in this build")
            reconcileUnavailableSupplier(
                id = id,
                trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                preferredTransportDeviceId = previousTransportDeviceId,
            )
            return
        }

        val whoopAlreadyPaused =
            veepooPairingPausedTransport is PausedTransport.Whoop
        if (!onStrap && !whoopAlreadyPaused) stopWhoop()
        veepooPairingPausedTransport = null
        tearDownNonWhoopSource()

        val address = row.peripheralId

        // Publish ownership before connect so a synchronous provider callback still observes the source it
        // belongs to. A failed connect tears this assignment down and restores the prior transport.
        activeSource = source
        activeStrapId = id
        onStrap = true
        if (source is VeepooManagedSource) mirrorVeepooActiveDisplay(source)

        // CONNECT to the active strap's known BLE address, don't just scan. A bare scan discovers + lists
        // the strap but never connects - so a Polar H10 etc. showed up as "found" yet never streamed
        // (#421). connect(address) connects directly via getRemoteDevice; a bare scan is the fallback only
        // when the registry row has no address.
        try {
            if (!address.isNullOrEmpty()) source.connect(address) else source.scan()
        } catch (failure: Throwable) {
            tearDownNonWhoopSource()
            activeStrapId = null
            if (!supplier) throw failure
            reconcileUnavailableSupplier(
                id = id,
                trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                preferredTransportDeviceId = previousTransportDeviceId,
            )
        }
    }

    private fun currentTransportDeviceId(excluding: String? = null): String? {
        val current = veepooPairingPausedTransport?.deviceId ?: if (onStrap) {
            activeStrapId
        } else {
            activeWhoopId
        }
        return current?.takeUnless { it == excluding }
    }

    private fun quiesceCurrentTransportForSupplierRetry() {
        if (onStrap) {
            tearDownNonWhoopSource()
            activeStrapId = null
        } else {
            stopWhoop()
        }
        // The durable active id already points at the supplier. No previous transport may continue
        // publishing while its samples would be attributed to that supplier id.
        onStrap = true
    }

    private suspend fun reconcileUnavailableSupplier(
        id: String,
        trigger: VeepooSupplierLifecycleTrigger,
        preferredTransportDeviceId: String?,
    ) {
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.RECONCILIATION,
            outcome = VeepooSupplierLifecycleOutcome.BEGAN,
            trigger = trigger,
        )
        val fallback = registry.reconcileUnavailableSupplier(
            unavailableDeviceId = id,
            preferredTransportDeviceId = preferredTransportDeviceId,
        )
        if (fallback == null || fallback == id) {
            lastSeenId = null
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.RECONCILIATION,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = trigger,
                failure = VeepooSupplierLifecycleFailure.FALLBACK_UNAVAILABLE,
            )
            return
        }

        runCatching { onDurableActiveDeviceChanged(fallback) }
        lastSeenId = null
        reconcile(fallback)
        veepooLifecycleDiagnostics.recordSafely(
            stage = VeepooSupplierLifecycleStage.RECONCILIATION,
            outcome = VeepooSupplierLifecycleOutcome.COMPLETED,
            trigger = trigger,
        )
    }

    private suspend fun reconcileCurrentDurableSource() {
        val current = runCatching { registry.activeDeviceId() }.getOrNull()
        if (current == null) {
            onStrap = false
            lastSeenId = null
            return
        }
        lastSeenId = null
        reconcile(current)
    }

    /**
     * Build the isolated [LiveHrSource] for a device from its registered `sourceKind` — the ONE place that
     * maps a kind to a concrete driver. An FTMS gym machine runs the FtmsSource; an EXPERIMENTAL Huami
     * device (Amazfit / Zepp / Mi Band) runs the HuamiHrSource; an EXPERIMENTAL Oura ring runs the
     * OuraLiveSource; everything else is a generic HR strap on StandardHrSource. Adding a brand adds ONE arm
     * here (plus a conforming source); nothing else in the coordinator changes. Returns the source WITHOUT
     * connecting — the caller ([switchToStrap]) does the connect-by-address-else-scan bring-up. Mirrors
     * macOS `SourceCoordinator.makeSource(for:)`.
     */
    private fun makeSource(id: String, row: PairedDeviceRow?): LiveHrSource {
        noopBandSourceFactory?.invoke(id, row)?.let { return it }
        return when (row?.sourceKind) {
            SourceKind.ftms.name -> FtmsSource(
                context = requireSourceContext(),
                liveSink = { hr -> liveSink(hr, emptyList()) },  // machine HR → the existing live recorder
                onBattery = batterySink,                          // machine battery → the same live state
                log = straplog,
            )
            SourceKind.huami.name -> {
                val ctx = requireSourceContext()
                val repo = requireNotNull(repository) { "SourceCoordinator.repository is required to persist Huami samples" }
                HuamiHrSource(
                    context = ctx,
                    deviceId = id,
                    liveSink = { hr -> liveSink(hr, emptyList()) },   // Huami HR → the existing live recorder
                    persist = { batch: StreamBatch, deviceId: String ->
                        scope.launch { runCatching { repo.insert(batch, deviceId) } }
                    },
                    log = straplog,
                    onBattery = batterySink,
                )
            }
            SourceKind.oura.name -> makeOuraSource(
                id,
                requireSourceContext(),
                row,
            )
            SourceKind.veepoo.name -> {
                val credentials = requireNotNull(veepooCredentials) {
                    "Supplier credential store is unavailable"
                }
                val credential = when (val read = credentials.readForRetention(id)) {
                    is VeepooCredentialRead.Available -> read.credential
                    VeepooCredentialRead.Missing ->
                        error("Supplier transport credential is unavailable")
                    VeepooCredentialRead.Unavailable ->
                        throw SupplierCredentialTemporarilyUnavailable()
                }
                try {
                    veepooActiveSourceFactory?.invoke(id, credential)
                        ?: VeepooBandSource(
                            deviceId = id,
                            bridge = requireNotNull(veepooBridgeProvider) {
                                "Supplier adapter is unavailable"
                            }.create(requireSourceContext()),
                            initialReconnectPassword = credential.password,
                            initialReconnectRevisionBinding = credential.revisionBinding,
                            compatibilityPolicy = veepooCompatibilityPolicy,
                            onReconnectCredentialRejected = { source ->
                                onVeepooAuthenticationRejected(id, source)
                            },
                            onReconnectRevisionBindingChanged = { source, password, binding ->
                                persistVeepooReconnectRevision(
                                    id = id,
                                    source = source,
                                    password = password,
                                    revisionBinding = binding,
                                )
                            },
                            onReconnectRevisionPersistenceUnavailable = { source ->
                                onVeepooRevisionPersistenceUnavailable(id, source)
                            },
                            onRuntimeUnavailable = { source ->
                                onVeepooRuntimeUnavailable(id, source)
                            },
                        )
                } finally {
                    credential.close()
                }
            }
            else -> {
                val ctx = requireSourceContext()
                val repo = requireNotNull(repository) { "SourceCoordinator.repository is required to persist strap samples" }
                StandardHrSource(
                    context = ctx,
                    deviceId = id,
                    liveSink = liveSink,
                    persist = { batch: StreamBatch, deviceId: String ->
                        scope.launch { runCatching { repo.insert(batch, deviceId) } }
                    },
                    log = straplog,   // generic-HR lifecycle → the SAME exported strap log (issue #421)
                    onBattery = batterySink,  // strap battery → the same live state the WHOOP strap battery uses
                    sensorSink = { metrics ->
                        // Additive speed/cadence/power → the coordinator's own flow the in-workout UI observes,
                        // AND the optionally-injected sink (default no-op). Never HR / R-R / scoring.
                        _sensorMetrics.value = metrics
                        sensorSink(metrics)
                    },
                )
            }
        }
    }

    private fun requireSourceContext(): Context =
        requireNotNull(context) {
            "SourceCoordinator.context is required to run a strap source"
        }

    /**
     * Build the EXPERIMENTAL Oura ring source (gen3 / gen4 / gen5) for [id]. Also wires the adopt-outcome
     * mirror ([ouraStateJob]) and consumes the one-shot adopt consent — side effects the coordinator owns,
     * so they live here rather than in the plain FTMS / Huami / Standard arms of [makeSource]. Mirrors the
     * Oura branch of macOS `makeOuraSource`.
     */
    private fun makeOuraSource(id: String, ctx: Context, row: PairedDeviceRow?): OuraLiveSource {
        val repo = requireNotNull(repository) { "SourceCoordinator.repository is required to persist Oura samples" }
        // The ring generation is carried on the row's model ("Oura Ring 3/4/5"); recover it so the transport
        // clamps the MTU + picks the gen-appropriate live-HR enable command set. Defaults to gen3 if the
        // model is missing/unrecognised (OuraRingGen.from).
        val ringGen = OuraRingGen.from(row?.model ?: "")
        val source = OuraLiveSource(
            context = ctx,
            deviceId = id,
            ringGen = ringGen,
            liveSink = { hr, rr -> liveSink(hr, rr) },   // ring HR + R-R → the existing live recorder
            // The 16-byte application install key, read from the at-rest-encrypted key store keyed by this
            // ring's device id. INJECTED, never hardcoded; null drives OuraLiveSource's honest needs-pairing
            // path (no faked data). Read fresh on each connect so a key provisioned mid-session (the adopt
            // install) is picked up on the post-install re-auth.
            authKey = { OuraInstallKeyStore.load(ctx, id) },
            persist = { batch: StreamBatch, deviceId: String, done: (Boolean) -> Unit ->
                scope.launch {
                    try {
                        repo.insert(batch, deviceId)
                        done(true)
                    } catch (cancelled: CancellationException) {
                        done(false)
                        throw cancelled
                    } catch (_: Throwable) {
                        done(false)
                    }
                }
            },
            persistSleepSession = { session, deviceId, done ->
                // Ring-provided SleepNet staging is imported/measured data under the ring's own id. The
                // repository's normal richness merge can then prefer it over a computed sparse-motion night.
                scope.launch {
                    try {
                        repo.upsertSleepSessions(
                            listOf(
                                com.noop.data.SleepSession(
                                    deviceId = deviceId,
                                    startTs = session.startTs,
                                    endTs = session.endTs,
                                    efficiency = session.efficiency,
                                    stagesJSON = session.stagesJson,
                                ),
                            ),
                        )
                        done(true)
                    } catch (cancelled: CancellationException) {
                        done(false)
                        throw cancelled
                    } catch (_: Throwable) {
                        done(false)
                    }
                }
            },
            log = straplog,           // Oura connect/auth/stream lifecycle → the SAME exported strap log (#421)
            onBattery = batterySink,  // ring battery → the same live state the WHOOP strap battery uses
            onModel = { model -> scope.launch { registry.setModel(id, model) } },
        )
        // CONSUME the one-shot adopt-intent the wizard armed after its irreversible-consent gate AND its
        // second "Take over" confirm (and ONLY then). True permits the DANGEROUS post-factory-reset key
        // install for THIS session; the Advanced-key path and every later read-only reconnect read false, so
        // they NEVER provision a key (OURA_PROTOCOL.md s3.2). One-shot by design: a single consent provisions
        // ONE install. setAdoptIntent must run BEFORE connect (the driver is built per connect with
        // allowKeyInstall wired from it) — the caller connects only after this returns, so the order holds.
        if (OuraInstallKeyStore.consumePendingAdopt(ctx, id)) {
            source.setAdoptIntent(true)
            straplog("Oura: adopt consent granted - this session may install NOOP's key")
        }
        // Mirror this source's live adopt outcome + honest needs-pairing message so the wizard can leave its
        // Adopting step on a confirmed streaming (success) or an honest Failed. Reset on teardown.
        ouraStateJob?.cancel()
        ouraStateJob = scope.launch {
            launch { source.adoptPhase.collect { _ouraAdoptPhase.value = it } }
            launch { source.needsPairing.collect { _ouraNeedsPairing.value = it } }
            launch { source.ouraWearState.collect { _ouraWearState.value = it } }
        }
        return source
    }

    /** Stop the live non-WHOOP source (standard strap, FTMS machine, Huami device, or Oura ring) and drop
     *  the reference. Idempotent — exactly one source is ever live. */
    private fun tearDownNonWhoopSource() {
        activeSource?.stop()
        activeSource = null
        veepooActiveDisplayJob?.cancel()
        veepooActiveDisplayJob = null
        _veepooDisplay.value = VeepooDisplayState()
        // Stop mirroring the (now torn-down) Oura source and clear the mirrors so a stale adopt outcome /
        // needs-pairing message never outlives the source or drives a later wizard transition.
        ouraStateJob?.cancel(); ouraStateJob = null
        _ouraAdoptPhase.value = OuraLiveSource.AdoptPhase.Idle
        _ouraNeedsPairing.value = null
        _ouraWearState.value = null   // #628: no live Oura source -> no wear badge
        // A stale speed/cadence/power readout must not outlive the strap session (the source's own stop()
        // already pushes an empty SensorMetrics, but reset here too so leaving for WHOOP / FTMS / Huami —
        // none of which feed this flow — is clean and immediate).
        _sensorMetrics.value = StandardHrSource.SensorMetrics()
    }

    private fun detachTerminalSupplierSource(source: LiveHrSource) {
        if (activeSource !== source) return
        activeSource = null
        activeStrapId = null
        veepooActiveDisplayJob?.cancel()
        veepooActiveDisplayJob = null
        _veepooDisplay.value = VeepooDisplayState()
        _sensorMetrics.value = StandardHrSource.SensorMetrics()
        // WHOOP remains paused until durable fallback succeeds. If fallback is unavailable,
        // keeping this edge marked as a strap allows a same-device retry without redundant WHOOP churn.
        onStrap = true
    }

    private fun mirrorVeepooActiveDisplay(source: VeepooManagedSource) {
        veepooActiveDisplayJob?.cancel()
        veepooActiveDisplayJob = scope.launch {
            source.display.collect { _veepooDisplay.value = it }
        }
    }

    private fun mirrorVeepooPairing(
        source: VeepooManagedSource,
        generation: Long,
    ) {
        veepooPairingStateJob?.cancel()
        veepooPairingStateJob = scope.launch {
            launch {
                source.state.collect {
                    _veepooPairingState.value = it
                    if (it == VeepooAdapterState.FAILED) {
                        scope.launch {
                            reconcileLock.withLock {
                                if (
                                    veepooPairingGeneration.get() == generation &&
                                    veepooPairingSource === source
                                ) {
                                    clearVeepooPairingLocked(
                                        restoreTransport = true,
                                        expectedGeneration = generation,
                                    )
                                }
                            }
                        }
                    }
                }
            }
            launch {
                source.candidates.collect { _veepooCandidates.value = it }
            }
        }
    }

    private fun pauseActiveTransportForPairing(): Boolean {
        if (veepooPairingPausedTransport != null) return true
        return if (onStrap) {
            val id = activeStrapId
            if (id == null || activeSource == null) {
                // A supplier credential retry intentionally leaves the durable supplier selected with no
                // live transport. Pairing a replacement must still be possible from that honest idle state.
                return true
            }
            veepooPairingPausedTransport = PausedTransport.Strap(id)
            tearDownNonWhoopSource()
            activeStrapId = null
            // Keep onStrap true: WHOOP is already paused, so restoring this source must not stop it again.
            true
        } else {
            val id = activeWhoopId ?: WhoopBleClient.DEFAULT_DEVICE_ID
            veepooPairingPausedTransport = PausedTransport.Whoop(id)
            stopWhoop()
            true
        }
    }

    private fun clearVeepooPairingLocked(
        restoreTransport: Boolean,
        expectedGeneration: Long? = null,
    ) {
        if (
            expectedGeneration != null &&
            veepooPairingGeneration.get() != expectedGeneration
        ) {
            return
        }
        val hadPairing =
            veepooPairingSource != null ||
                veepooPairingStateJob != null ||
                veepooPairingPausedTransport != null
        runCatching { veepooPairingSource?.stop() }
        veepooPairingSource = null
        veepooPairingDeviceId = null
        veepooPairingStateJob?.cancel()
        veepooPairingStateJob = null
        _veepooCandidates.value = emptyList()
        _veepooPairingState.value = VeepooAdapterState.IDLE
        if (restoreTransport && hadPairing) restorePausedTransportAfterPairingLocked()
    }

    private fun scheduleSupplierCredentialRetry(id: String) {
        if (supplierCredentialRetryJob?.isActive == true &&
            supplierCredentialRetryDeviceId == id
        ) {
            return
        }
        cancelSupplierCredentialRetry()
        val generation = supplierCredentialRetryGeneration.incrementAndGet()
        supplierCredentialRetryDeviceId = id
        supplierCredentialRetryJob = scope.launch {
            try {
                for (delayMillis in supplierCredentialRetryDelaysMillis) {
                    if (delayMillis > 0) delay(delayMillis)
                    if (retrySupplierCredential(id)) return@launch
                }
                val recoveryDelay =
                    supplierCredentialRecoveryDelayMillis?.takeIf { it > 0L }
                        ?: return@launch
                while (true) {
                    delay(recoveryDelay)
                    if (retrySupplierCredential(id)) return@launch
                }
            } finally {
                if (
                    supplierCredentialRetryGeneration.get() == generation &&
                    supplierCredentialRetryDeviceId == id
                ) {
                    supplierCredentialRetryDeviceId = null
                    supplierCredentialRetryJob = null
                }
            }
        }
    }

    private suspend fun retrySupplierCredential(id: String): Boolean =
        try {
            reconcileLock.withLock {
                if (registry.activeDeviceId() != id) return@withLock true
                lastSeenId = null
                reconcile(id)
                if (activeStrapId != id || activeSource == null) {
                    return@withLock false
                }
                veepooLifecycleDiagnostics.recordSafely(
                    stage = VeepooSupplierLifecycleStage.SECURE_READ,
                    outcome = VeepooSupplierLifecycleOutcome.COMPLETED,
                    trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                )
                true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            veepooLifecycleDiagnostics.recordSafely(
                stage = VeepooSupplierLifecycleStage.SECURE_READ,
                outcome = VeepooSupplierLifecycleOutcome.FAILED,
                trigger = VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE,
                failure = VeepooSupplierLifecycleFailure.SECURE_READ_UNAVAILABLE,
            )
            false
        }

    private suspend fun reconcilePendingSupplierCredentialCleanup() {
        val credentials = veepooCredentials ?: return
        val cleanup = veepooCredentialCleanup ?: return
        VeepooPendingCredentialCleanup.reconcile(
            registry = registry,
            credentials = credentials,
            cleanup = cleanup,
            diagnostics = veepooLifecycleDiagnostics,
        )
    }

    private fun cancelSupplierCredentialRetry() {
        supplierCredentialRetryGeneration.incrementAndGet()
        supplierCredentialRetryJob?.cancel()
        supplierCredentialRetryJob = null
        supplierCredentialRetryDeviceId = null
    }

    private fun restorePausedTransportAfterPairingLocked() {
        val pending = pendingReconcileId
        pendingReconcileId = null
        val paused = veepooPairingPausedTransport
        veepooPairingPausedTransport = null
        if (pending != null) {
            lastSeenId = null
            scope.launch {
                reconcileLock.withLock {
                    reconcile(pending)
                }
            }
            return
        }
        if (paused == null) {
            // Pairing can start while a durable supplier is waiting on a transient secure-store read and
            // therefore has no transport to pause. Resume that durable selection after cancellation/failure.
            scope.launch {
                val current = runCatching { registry.activeDeviceId() }.getOrNull()
                    ?: return@launch
                reconcileLock.withLock {
                    lastSeenId = null
                    reconcile(current)
                }
            }
            return
        }
        when (paused) {
            is PausedTransport.Whoop -> startWhoop()
            is PausedTransport.Strap -> scope.launch {
                reconcileLock.withLock {
                    lastSeenId = null
                    reconcile(paused.deviceId)
                }
            }
        }
    }

    companion object {
        /**
         * Classify a device id as WHOOP vs a generic strap. WHOOP if the id is the canonical "my-whoop",
         * the registry row's `brand` is "WHOOP" (case-insensitive), OR the id is unknown - unknown ids
         * default to WHOOP so the coordinator stays dormant rather than ever stealing the WHOOP's BLE.
         * Mirrors Swift `SourceCoordinator.isWhoop`.
         */
        fun isWhoop(id: String, devices: List<PairedDeviceRow>): Boolean {
            if (id == WhoopBleClient.DEFAULT_DEVICE_ID) return true
            val device = devices.firstOrNull { it.id == id } ?: return true
            return isWhoop(device)
        }

        /** A device is WHOOP when its id is "my-whoop" or its brand is "WHOOP" (the seeded row's brand). */
        fun isWhoop(device: PairedDeviceRow): Boolean =
            device.id == WhoopBleClient.DEFAULT_DEVICE_ID ||
                device.brand.equals("WHOOP", ignoreCase = true)
    }

    private class SupplierCredentialTemporarilyUnavailable : Exception()
}
