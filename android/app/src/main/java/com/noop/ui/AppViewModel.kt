package com.noop.ui

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.alarm.SmartAlarmScheduler
import com.noop.alarm.SmartAlarmStore
import com.noop.alarm.WindDownScheduler
import com.noop.alarm.WindDownStore
import com.noop.analytics.Baselines
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.analytics.IllnessSignalEngine
import com.noop.analytics.IllnessSignalPipeline
import com.noop.automation.AlarmTapAutomationPrefs
import com.noop.automation.TapAutomationRuntime
import com.noop.automation.TapAutomationStore
import com.noop.analytics.IllnessWatch
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.V5HealthSignals
import com.noop.analytics.RegistryDayOwnerSource
import com.noop.analytics.RouteMath
import com.noop.analytics.SleepMark
import com.noop.analytics.SleepMarkType
import com.noop.analytics.Sport
import com.noop.analytics.Calories
import com.noop.analytics.ContextualVitalPolicy
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.StrainScorer
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutSport
import com.noop.analytics.WorkoutCautionPolicy
import com.noop.calendar.PlannedWorkoutCalendarStore
import com.noop.location.GpsSession
import kotlinx.coroutines.Job
import com.noop.ble.HrBroadcaster
import com.noop.ble.LiveState
import com.noop.ble.PuffinExperiment
import com.noop.ble.WhoopConnectionService
import com.noop.ble.WhoopModel
import androidx.health.connect.client.HealthConnectClient
import com.noop.data.DailyMetric
import com.noop.data.CycleTrackingStore
import com.noop.data.HrSample
import com.noop.data.MedicationStore
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.ActivityFileImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectReconciler
import com.noop.ingest.HealthConnectReconcileResult
import com.noop.ingest.HealthConnectSyncScheduler
import com.noop.ble.WhoopBleClient
import com.noop.ble.ForegroundRealtimeLeasePolicy
import com.noop.ingest.HealthConnectWriter
import com.noop.ingest.LiftingImporter
import com.noop.notif.AutoWorkoutCandidateNotifier
import com.noop.notif.AdaptiveDayEvaluator
import com.noop.notif.AdaptiveDayEvaluationGate
import com.noop.notif.AdaptiveDayNotifier
import com.noop.notif.AdaptivePlannedWorkoutScheduler
import com.noop.notif.AdaptiveDayTimeZoneStore
import com.noop.notif.ContextualVitalNotifier
import com.noop.notif.HydrationReminderPrefs
import com.noop.notif.HydrationReminderScheduler
import com.noop.notif.IllnessAlertNotifier
import com.noop.notif.ScheduledReportNotifier
import com.noop.notif.StrainTargetNotifier
import com.noop.notif.WorkoutCautionNotifier
import com.noop.notif.ScheduledReportPolicy
import com.noop.protocol.CommandNumber
import com.noop.safety.SafetySosDispatcher
import com.noop.safety.SafetySosGestureRuntime
import com.noop.sync.RemoteNoopAlgorithmRevision
import com.noop.widget.WidgetSnapshotFactory
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.ZonedDateTime
import kotlin.math.roundToInt

/**
 * Upgrade boundary for Charge formula changes that do not create a raw-input dirty marker.
 *
 * The revision string makes future formula updates fail open into one full-history pass. AppViewModel
 * writes completion only from the successful branch of the scoring call.
 */
internal object ChargeFormulaUpgradeGate {
    const val COMPLETED_REVISION_KEY = "noop.analysis.completedChargeFormulaRevision"
    const val HISTORY_DAYS = 4_000
    const val CURRENT_REVISION = RemoteNoopAlgorithmRevision.CHARGE

    fun needsRescore(completedRevision: String?): Boolean =
        completedRevision != CURRENT_REVISION
}

internal object ActiveZoneUpgradeGate {
    const val COMPLETED_REVISION_KEY = "noop.analysis.completedActiveZoneRevision"
    const val HISTORY_DAYS = 21
    const val CURRENT_REVISION = "noop-active-zone-v1"

    fun needsRescore(completedRevision: String?): Boolean =
        completedRevision != CURRENT_REVISION
}

internal data class TodayRestCompositeCacheKey(
    val dailyDataSignature: Int,
    val activeStrapId: String,
    val restDataVersion: Long,
)

/** Stable live fields the Today root is allowed to observe. Sensor values and sync counters stay in leaves. */
internal data class DashboardLiveSnapshot(
    val connected: Boolean,
    val bonded: Boolean,
    val encryptedBond: Boolean,
    val worn: Boolean,
    val batteryPct: Double?,
    val isGeneration5: Boolean,
    val charging: Boolean?,
)

internal fun LiveState.dashboardLiveSnapshot(): DashboardLiveSnapshot =
    DashboardLiveSnapshot(
        connected = connected,
        bonded = bonded,
        encryptedBond = encryptedBond,
        worn = worn,
        batteryPct = batteryPct,
        isGeneration5 = isGeneration5,
        charging = charging,
    )

internal fun Flow<LiveState>.dashboardLiveChanges(): Flow<DashboardLiveSnapshot> =
    map(LiveState::dashboardLiveSnapshot).distinctUntilChanged()

/** Exact history progress for small status leaves; ordinary sensor packets map to an equal value. */
internal data class HistorySyncStatusSnapshot(
    val backfilling: Boolean,
    val batches: Int,
    val rows: Int,
    val newestDataUnix: Long?,
    val startedAt: Long?,
    val lastDurableProgressAt: Long?,
    val lastSyncAt: Long?,
    val experimental: Boolean,
)

internal fun LiveState.historySyncStatusSnapshot(): HistorySyncStatusSnapshot =
    HistorySyncStatusSnapshot(
        backfilling = backfilling,
        batches = syncChunksThisSession,
        rows = syncRowsThisSession,
        newestDataUnix = syncDataNewestAt,
        startedAt = syncStartedAt,
        lastDurableProgressAt = syncLastDurableProgressAt,
        lastSyncAt = lastSyncAt,
        experimental = historySyncExperimental,
    )

internal fun Flow<LiveState>.historySyncStatusChanges(): Flow<HistorySyncStatusSnapshot> =
    map(LiveState::historySyncStatusSnapshot).distinctUntilChanged()

/**
 * The single app-wide view model. Holds the BLE client and the Room-backed
 * repository, re-publishes the BLE [LiveState], maintains a spike-filtered/smoothed
 * BPM for the big read-outs, and runs the on-device illness watch over cached
 * daily metrics. Mirrors the macOS AppModel responsibilities (LiveState bridge,
 * `bpm` smoothing, health-alert string) without any networking.
 */
/** Last Health Connect writeback outcome for the Data Sources UI (#660). [code] is a PII-safe
 *  category (see [NoopPrefs.HC_WB_OK] etc.); "" = never attempted. */
data class HcWritebackStatus(val code: String, val atMs: Long, val written: Int)

class AppViewModel(app: Application) : AndroidViewModel(app) {

    /** Process-wide context for prefs + the background-connection service. */
    private val appContext = app.applicationContext
    private var plannedWorkoutCalendarObserverRegistered = false
    private var plannedWorkoutCalendarEvaluationJob: Job? = null
    private var adaptiveDayInputEvaluationJob: Job? = null
    private val plannedWorkoutCalendarObserver =
        object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                onPlannedWorkoutCalendarChanged()
            }
        }

    /** The process owns the store + BLE client (see [NoopApplication]) so the connection can outlive
     *  this Activity-scoped ViewModel and keep streaming under [WhoopConnectionService]. */
    private val noopApp = app as NoopApplication

    // Offline store — process-wide, shared with the background service.
    private val repository: WhoopRepository = noopApp.repository

    // BLE client — process-owned; emits LiveState and persists decoded live + historical streams
    // into [repository] (same process-wide DB).
    val ble = noopApp.ble

    val repo: WhoopRepository get() = repository

    /** Current registry selection. Unlike the process-start BLE seed, this changes immediately when the
     *  user switches devices, so scans and accepted suggestions never stay pinned to the prior source. */
    private val _selectedDeviceId = MutableStateFlow(noopApp.activeDeviceId)
    val selectedDeviceId: StateFlow<String> = _selectedDeviceId.asStateFlow()

    /** The registry's active strap id (the same id the read path resolves to). Public so the Test Centre
     *  can read the right source for the CAPTURE-D data-volume snapshot. */
    val activeStrapId: String get() = deviceId

    // MARK: - Devices screen (multi-source Phase 1B)
    //
    // The Devices screen is a thin UI over the process-wide [DeviceRegistry]. Every mutation goes
    // through a registry op here, and (for setActive) the [SourceCoordinator] is told the active device
    // changed so it can swap the live BLE source — mirroring the macOS DevicesView, which observes the
    // registry's @Published active id directly. The registry's reads are one-shot suspend (not a Flow),
    // so the screen reloads the list after each op via [pairedDevices].

    /** The process-wide device registry — the single source of paired devices + the active one. */
    val deviceRegistry: com.noop.data.DeviceRegistry get() = noopApp.deviceRegistry

    /** All paired devices (oldest first), read fresh. The screen re-reads after every mutation. */
    suspend fun pairedDevices(): List<com.noop.data.PairedDeviceRow> = noopApp.deviceRegistry.all()

    /** Add (or update) a paired device. */
    suspend fun addPairedDevice(row: com.noop.data.PairedDeviceRow) = noopApp.deviceRegistry.add(row)

    /** Make [id] the single active device, then tell the [SourceCoordinator] so it swaps the live source
     *  (a no-op for a single-WHOOP install). Mirrors macOS DevicesView's `registry.setActive`. */
    suspend fun setActiveDevice(id: String) {
        val changed = id != deviceId
        noopApp.deviceRegistry.setActive(id)
        noopApp.noteActiveDeviceId(id)
        _selectedDeviceId.value = id
        noopApp.sourceCoordinator.onActiveDeviceChanged(id)
        refreshActiveDeviceName()
        if (changed) {
            analyzeKick.trySend(Unit)
            scheduleAgeMetricRecompute()
        }
    }

    /** The active band's display name (nickname, else collapsed brand+model), surfaced on the Live screen
     *  (MW-6). Null until the first registry read resolves; falls back to "WHOOP" in the UI when null. */
    private val _activeDeviceName = MutableStateFlow<String?>(null)
    val activeDeviceName: StateFlow<String?> = _activeDeviceName.asStateFlow()

    /** Re-read the active device row and republish its display name. Called at launch + after a setActive. */
    fun refreshActiveDeviceName() {
        viewModelScope.launch {
            val all = runCatching { noopApp.deviceRegistry.all() }.getOrDefault(emptyList())
            val active = all.firstOrNull { it.status == com.noop.data.DeviceStatus.active.name }
            _activeDeviceName.value = active?.let { displayName(it) }
        }
    }

    /** Archive (remove) a device — keeps its row + samples (invariant I4). H3 (#520): when the removed
     *  device is a WHOOP, also RELEASE the BLE link so the band can enter pairing mode — archiving the
     *  registry row alone left NOOP re-grabbing it (the 3s reconnect timer + the persisted pin still
     *  pointed at it), so it stayed connected and couldn't show its blue pairing LEDs. iOS already does
     *  this in forgetDevice; this brings Android to parity. A non-WHOOP source (FTMS/HR strap) is owned by
     *  the SourceCoordinator, not the WHOOP client, so it isn't touched here. */
    suspend fun archivePairedDevice(id: String) {
        val devices = runCatching { noopApp.deviceRegistry.all() }.getOrDefault(emptyList())
        val wasEligible = devices.any {
            it.id == id && it.status != com.noop.data.DeviceStatus.archived.name
        }
        noopApp.deviceRegistry.archive(id)
        if (com.noop.ble.SourceCoordinator.isWhoop(id, devices)) ble.releaseStrap()
        if (wasEligible) {
            analyzeKick.trySend(Unit)
            scheduleAgeMetricRecompute()
        }
    }

    /** Rename a device (blank clears the nickname → falls back to brand+model). */
    suspend fun renamePairedDevice(id: String, nickname: String?) =
        noopApp.deviceRegistry.rename(id, nickname)

    /** Permanently delete all of a device's recorded data (its registry row is kept). */
    suspend fun deletePairedDeviceData(id: String) {
        noopApp.deviceRegistry.deleteDeviceData(id)
        repository.noteWorkoutsChanged()
        noteAllMetricsChanged()
    }

    /**
     * A DISCOVERY-ONLY [StandardHrSource] for the Add-a-strap wizard. It runs its OWN scan and never
     * connects or persists here — the [SourceCoordinator] owns connection once a strap becomes active.
     * Both closures are no-ops; the wizard only reads its `discovered` / `scanning` StateFlows. Mirrors
     * the macOS AddDeviceSheet's throwaway StandardHRSource(persist: { _ in }).
     */
    fun makeStrapScanner(): com.noop.ble.StandardHrSource =
        com.noop.ble.StandardHrSource(
            context = appContext,
            deviceId = "scan-preview",
            liveSink = { _, _ -> },
            persist = { _, _ -> },
            // Route the throwaway scanner's diagnostics into the SAME exported strap log the active path
            // uses (issue #421 parity), so a tester's wizard scan is captured. The source self-prefixes
            // "HR-strap: "; [externalLog] redacts addresses. Privacy-safe: statuses / counts only.
            log = { ble.externalLog(it) },
        )

    /**
     * A DISCOVERY-ONLY [com.noop.ble.FtmsSource] for the Add-gym-equipment wizard. Runs its OWN scan and
     * never connects here — the [SourceCoordinator] owns connection once an FTMS machine becomes active.
     * The sinks are no-ops; the wizard only reads its `discovered` / `scanning` StateFlows. Mirrors the
     * macOS AddDeviceWizard's throwaway FTMSSource(feedsLive: false).
     */
    fun makeFtmsScanner(): com.noop.ble.FtmsSource =
        com.noop.ble.FtmsSource(
            context = appContext,
            liveSink = { },
            // Wizard scan diagnostics → the SAME exported strap log the active path uses (issue #421).
            // The source self-prefixes "FTMS: "; [externalLog] redacts addresses. Statuses / counts only.
            log = { ble.externalLog(it) },
        )

    /**
     * A DISCOVERY-ONLY EXPERIMENTAL [com.noop.ble.HuamiHrSource] for the Add-Amazfit/Mi-Band wizard. Runs
     * its OWN scan and never connects/persists here — the [SourceCoordinator] owns connection once a Huami
     * device becomes active. The sinks are no-ops; the wizard only reads its `discovered` / `scanning`
     * StateFlows. Mirrors the macOS AddDeviceWizard's throwaway HuamiHRSource(feedsLive: false).
     */
    fun makeHuamiScanner(): com.noop.ble.HuamiHrSource =
        com.noop.ble.HuamiHrSource(
            context = appContext,
            deviceId = "scan-preview",
            liveSink = { },
            // Wizard scan diagnostics → the SAME exported strap log the active path uses (issue #421).
            // The source self-prefixes "Huami: "; [externalLog] redacts addresses. Statuses / counts only.
            log = { ble.externalLog(it) },
        )

    /**
     * A DISCOVERY-ONLY EXPERIMENTAL [com.noop.ble.OuraLiveSource] for the Add-Oura wizard. Runs its OWN
     * scan (it owns its OWN scanner + GATT, never the WHOOP client) and never persists or feeds live state
     * here - the [SourceCoordinator] owns connection once the ring becomes active. The live sink / persist
     * are no-ops and the auth key is null (discovery has no need to authenticate), so the scanner only ever
     * surfaces nearby rings via its `discovered` / `scanning` StateFlows. Mirrors the macOS
     * AddDeviceWizard's discovery-only OuraLiveSource (deviceId "scan-preview", no-op persist).
     *
     * A concrete [com.noop.oura.OuraRingGen] is required by the constructor; gen3 (the verified-corpus
     * default) is fine for discovery since the wizard's pick step confirms the real generation from the
     * model the user selects. The MTU clamp / command set never run during a scan-only session.
     */
    fun makeOuraScanner(): com.noop.ble.OuraLiveSource =
        com.noop.ble.OuraLiveSource(
            context = appContext,
            deviceId = "scan-preview",
            ringGen = com.noop.oura.OuraRingGen.GEN3,
            liveSink = { _, _ -> },
            authKey = { null },
            persist = { _, _, done -> done(true) },
            // Route the scanner's diagnostics into the SAME exported strap log the active path uses
            // (issue #421 parity), so a tester's Oura wizard scan is captured. The source self-prefixes
            // "Oura: "; [externalLog] redacts addresses. Statuses / service UUIDs / counts only, never a
            // device address.
            log = { ble.externalLog(it) },
        )

    // MARK: - Add-a-device wizard (multi-WHOOP, MW-4) — thin pass-throughs to the BLE client.

    /** WHOOP straps surfaced by the wizard's present-scan ([presentWhoopScan]), WITHOUT auto-connecting.
     *  The wizard observes this directly so its pick list updates as straps appear. */
    val discoveredWhoops: StateFlow<List<com.noop.ble.WhoopBleClient.DiscoveredWhoop>> = ble.discoveredWhoops

    /** The active Oura ring's live adopt outcome, mirrored from the [com.noop.ble.SourceCoordinator]. The
     *  Add-Oura wizard observes this to leave its Adopting step: streaming -> success/close, failed -> the
     *  honest Failed step. Idle whenever no Oura source is live. Mirrors Swift `AppModel.ouraAdoptPhase`. */
    val ouraAdoptPhase: StateFlow<com.noop.ble.OuraLiveSource.AdoptPhase> =
        noopApp.sourceCoordinator.ouraAdoptPhase

    /** The active Oura ring's honest needs-pairing message (null when none), mirrored from the
     *  [com.noop.ble.SourceCoordinator]. The wizard treats a non-null value during Adopting as an honest
     *  failure too. Mirrors Swift `AppModel.ouraNeedsPairing`. */
    val ouraNeedsPairing: StateFlow<String?> = noopApp.sourceCoordinator.ouraNeedsPairing

    /** The active Oura ring's live wear/charge state (worn / charging / off), or null when no Oura source
     *  is live. The Live screen prefers this for its On-wrist / Off-wrist read (#628). Mirrors iOS
     *  `LiveState.ouraWearState`. */
    val ouraWearState: StateFlow<com.noop.oura.OuraWearState?> =
        noopApp.sourceCoordinator.ouraWearState

    /** #656: a journal day-offset (daysBack; -1 = Tomorrow) the Today journal widget asks the journal
     *  (Insights) to open at, so tapping a SPECIFIC day's bar lands on THAT day instead of always today.
     *  InsightsScreen consumes it on open and clears it via [requestJournalDay]`(null)`. */
    private val _pendingJournalDayOffset = kotlinx.coroutines.flow.MutableStateFlow<Long?>(null)
    val pendingJournalDayOffset: StateFlow<Long?> = _pendingJournalDayOffset
    fun requestJournalDay(offset: Long?) { _pendingJournalDayOffset.value = offset }

    /**
     * Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting (the
     * Add-a-device wizard's WHOOP path). [WhoopBleClient.prepareForPresentScan] KEEPS a live same-model
     * connection (#74, the Android half of the v5.2.3 iOS fix: the old unconditional
     * prepareForModelSwitch dropped a live strap mid-session, left it disconnected for good if the wizard
     * was dismissed without picking, and on a 5/MG risked the insufficient-auth re-bond refusal loop) and
     * only idles the engine on a genuine family switch. [WhoopBleClient.scanForWhoops] then takes over
     * the LE scanner in present-mode (accumulate, don't connect) without disturbing the kept link.
     * Mirrors the macOS AppModel.presentWhoopScan + BLEManager.prepareForPresentScan. The persisted
     * family selection is updated too so a later real connect to the chosen strap targets the right
     * family.
     */
    fun presentWhoopScan(model: WhoopModel) {
        _selectedModel.value = model
        ble.prepareForPresentScan(model)
        ble.scanForWhoops(model)
    }

    /** End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss. */
    fun stopWhoopScan() = ble.stopWhoopScan()

    /**
     * Register a paired device and (optionally) make it the active one — the Add-a-device wizard's single
     * write path. [addPairedDevice] upserts the row; when [makeActive] is true [setActiveDevice] promotes
     * it (which also tells the [SourceCoordinator] the active device changed, so it pins the WHOOP /
     * starts the strap source). Mirrors the macOS AppModel.registerDevice.
     */
    suspend fun registerDevice(device: com.noop.data.PairedDeviceRow, makeActive: Boolean) {
        addPairedDevice(device)
        if (makeActive) setActiveDevice(device.id)
    }

    /**
     * Store the 16-byte Oura application install key for a ring (keyed by its registry device id) in the
     * encrypted, Keystore-backed [com.noop.ble.OuraInstallKeyStore]. The Add-Oura wizard's Advanced path
     * calls this with the user-supplied key so the live [com.noop.ble.OuraLiveSource]'s authKey closure can
     * read it on the next connect. The key is unsigned bytes 0..255; a wrong-length key is rejected by the
     * store. Mirrors the macOS OuraKeyStore.save. The key is never logged.
     */
    fun saveOuraInstallKey(deviceId: String, key: IntArray): Boolean =
        com.noop.ble.OuraInstallKeyStore.save(appContext, deviceId, key)

    /**
     * Arm (or clear) the one-shot adopt-intent for an Oura ring (keyed by its registry device id). The
     * Add-Oura wizard's DESTRUCTIVE factory-reset-and-adopt path calls this with true AFTER its
     * irreversible-consent gate and second destructive confirm, BEFORE registering the ring active, so the
     * [com.noop.ble.SourceCoordinator] consumes it when it builds the live source and permits the dangerous
     * post-factory-reset key install for that one session (OURA_PROTOCOL.md s3.2). The Advanced-key path
     * NEVER calls this (it authenticates with the user's own key and must not reset the ring). One-shot:
     * the source consumes it on the next connect.
     */
    fun armOuraAdopt(deviceId: String) =
        com.noop.ble.OuraInstallKeyStore.setPendingAdopt(appContext, deviceId, true)

    // Body profile (age/sex/weight/height + HR-max override) — the same SharedPreferences
    // store the Settings screen edits. Feeds the on-device scorer's HRmax/zones/calories.
    private val profileStore = ProfileStore.from(app.applicationContext)
    /** Repository-backed revisions also advance for background imports/scoring without an Activity owner. */
    val metricDataVersion: StateFlow<Long> = repository.metricDataVersion
    val ageMetricDataVersion: StateFlow<Long> = metricDataVersion
    val restDataVersion: StateFlow<Long> = repository.restDataVersion
    val workoutDataVersion: StateFlow<Long> = repository.workoutDataVersion
    private var lastAgeMetricReconciliationTarget: AgeMetricReconciliationTarget? =
        NoopPrefs.of(appContext).let { prefs ->
            val profileState = prefs.getString(AGE_METRIC_RECONCILED_PROFILE_STATE_KEY, null)
            val reconciledDeviceId = prefs.getString(AGE_METRIC_RECONCILED_DEVICE_ID_KEY, null)
            if (profileState != null && reconciledDeviceId != null) {
                AgeMetricReconciliationTarget(profileState, reconciledDeviceId)
            } else null
        }
    private val ageMetricReconciliationRunner by lazy {
        AgeMetricReconciliationRunner(
            scope = viewModelScope,
            currentTarget = {
                AgeMetricReconciliationTarget(
                    profileState = profileStore.ageMetricStateToken,
                    deviceId = deviceId,
                )
            },
            profileSnapshot = ::currentProfile,
            recomputeMetrics = { profile, requestedDeviceId ->
                val outcome = IntelligenceEngine.recomputeAgeMetricsOnly(
                    repository, profile, requestedDeviceId,
                )
                AgeMetricReconciliationOutcome(
                    fitnessFinished = outcome.fitnessFinished,
                    vitalityFinished = outcome.vitalityFinished,
                )
            },
            publishCompletedWork = ::noteAgeMetricsChanged,
            persistCompletedTarget = { target ->
                withContext(Dispatchers.IO) {
                    NoopPrefs.of(appContext).edit()
                        .putString(
                            AGE_METRIC_RECONCILED_PROFILE_STATE_KEY,
                            target.profileState,
                        )
                        .putString(
                            AGE_METRIC_RECONCILED_DEVICE_ID_KEY,
                            target.deviceId,
                        )
                        .commit()
                }
            },
            markCompletedTarget = { target ->
                lastAgeMetricReconciliationTarget = target
            },
        )
    }

    /** The currently selected strap source id (raw streams + imported history live under this). Seeded
     *  from [NoopApplication.activeDeviceId], then updated by its asynchronous registry projection and
     *  [setActiveDevice]. Public so the Today screen's workout union can follow a re-paired strap's fresh
     *  source instead of stranding its recordings under the legacy fallback (#814 Workouts twin). */
    val deviceId: String get() = _selectedDeviceId.value

    /** Live connection + biometric snapshot, surfaced straight from the BLE client. */
    val live: StateFlow<LiveState> = ble.state
    /** Slow-changing Today-root state. Exact history progress is collected only by status leaves. */
    internal val dashboardLive: StateFlow<DashboardLiveSnapshot> = live
        .dashboardLiveChanges()
        .stateIn(
            viewModelScope,
            SharingStarted.Eagerly,
            live.value.dashboardLiveSnapshot(),
        )
    /** Shared exact sync projection. It emits for progress, not for HR/R-R sensor cadence. */
    internal val historySyncStatus: StateFlow<HistorySyncStatusSnapshot> = live
        .historySyncStatusChanges()
        .stateIn(
            viewModelScope,
            SharingStarted.Eagerly,
            live.value.historySyncStatusSnapshot(),
        )
    /** Low-frequency projection for history consumers that need to refresh after an offload without
     *  collecting the full live state (which republishes every heart-rate packet). */
    val lastHistorySyncAt: StateFlow<Long?> = live
        .map { it.lastSyncAt }
        .stateIn(viewModelScope, SharingStarted.Eagerly, live.value.lastSyncAt)
    /** Low-frequency write-boundary projection for retained screens. */
    val historyBackfillActive: StateFlow<Boolean> = live
        .map { it.backfilling }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.Eagerly, live.value.backfilling)

    /** Which strap the user is pairing — drives the scan filter in [connect]. Defaults to WHOOP 4.0. */
    private val _selectedModel = MutableStateFlow(WhoopModel.WHOOP4)
    val selectedModel: StateFlow<WhoopModel> = _selectedModel.asStateFlow()
    fun setSelectedModel(model: WhoopModel) {
        if (model == _selectedModel.value) return
        _selectedModel.value = model
        // Switching straps: forget the saved one so launch auto-reconnect (#67) doesn't target the old strap.
        NoopPrefs.clearLastDevice(appContext)
        // Drop the previous strap's sticky bond/connection so the next scan targets the new family's
        // service and bonds it fresh (lets a user move between a WHOOP 4 and a 5/MG).
        ble.prepareForModelSwitch()
    }

    // MARK: - Smoothed BPM (median over a short window, mirrors AppModel.bpm)

    private val hrWindow = ArrayDeque<Int>()
    private val hrWindowSize = 5
    private val _bpm = MutableStateFlow<Int?>(null)
    /** Spike-filtered, smoothed heart rate for the hero number. Null until data arrives. */
    val bpm: StateFlow<Int?> = _bpm.asStateFlow()
    /** Manual-workout capture has its own packet-identity cursor. It stores raw sensor BPM and never
     *  mistakes a battery/connection StateFlow republish for another heart-rate observation. */
    private var workoutHeartRateCursor = WorkoutHeartRateCursor(
        consumedSequence = ble.state.value.heartRateSampleSequence,
    )
    /** Sustained, artifact-gated policy for the active manual workout. */
    private var workoutCautionPolicy: WorkoutCautionPolicy? = null

    // MARK: - Illness watch banner

    private val _healthAlert = MutableStateFlow<String?>(null)
    /** Non-null when the illness watch flags an early-warning pattern. Drives the banner. */
    val healthAlert: StateFlow<String?> = _healthAlert.asStateFlow()

    // Declared BEFORE the init block on purpose: the recentDays collector launched from init
    // runs synchronously on Main.immediate and reads this on its very first (cached) emission —
    // a declaration after init would still be null there (JVM initializes fields in declaration
    // order) and crash the constructor. Opt-OUT, default ON (Android has always run the watch);
    // port of macOS behavior.illnessWatch, which is opt-in.
    private val _illnessWatchEnabled = MutableStateFlow(NoopPrefs.illnessWatch(appContext))
    /** Whether the illness early-warning runs (banner + notification). */
    val illnessWatchEnabled: StateFlow<Boolean> = _illnessWatchEnabled.asStateFlow()

    // Fresh oxygen/body-temperature and slow VO2 reviews are separate, explicit opt-ins. Declared before
    // init because the recentDays collector reads both on its synchronous first cached emission.
    private val _contextualVitalReviewEnabled =
        MutableStateFlow(NoopPrefs.contextualVitalReview(appContext))
    val contextualVitalReviewEnabled: StateFlow<Boolean> =
        _contextualVitalReviewEnabled.asStateFlow()
    private val _contextualVo2ReviewEnabled =
        MutableStateFlow(NoopPrefs.contextualVo2Review(appContext))
    val contextualVo2ReviewEnabled: StateFlow<Boolean> =
        _contextualVo2ReviewEnabled.asStateFlow()
    private val _adaptiveDayGuidanceEnabled =
        MutableStateFlow(AdaptiveDayConsentGate.guidance(appContext))
    val adaptiveDayGuidanceEnabled: StateFlow<Boolean> =
        _adaptiveDayGuidanceEnabled.asStateFlow()

    // Cycle awareness (v5 skin-temp suite) — OPT-IN, default OFF (manual-first). Declared BEFORE init for
    // the same reason as _illnessWatchEnabled: the recentDays collector reads it on its synchronous first
    // (cached) emission. Gates whether CyclePhaseEngine actually classifies in the v5 analytics pass.
    private val _cycleTrackingEnabled = MutableStateFlow(NoopPrefs.cycleTracking(appContext))
    /** Whether cycle-phase awareness is enabled (reads a coarse phase from nightly skin temperature). */
    val cycleTrackingEnabled: StateFlow<Boolean> = _cycleTrackingEnabled.asStateFlow()

    // User-entered cycle-day-1 anchors. These are loaded from the isolated local `noop-cycle /
    // period_start` metric series and exposed only so the private tracker sheet can render its history.
    // Declared before init because the recentDays collector populates it on its first cached emission.
    private val _periodStarts = MutableStateFlow<List<String>>(emptyList())
    /** Logged period starts, oldest first. Dates only; local Room storage, no account or cloud. */
    val periodStarts: StateFlow<List<String>> = _periodStarts.asStateFlow()
    private val _cycleDailyLogs =
        MutableStateFlow<List<CycleTrackingStore.DailyLog>>(emptyList())
    /** Optional flow/symptom details, oldest first and local to this device. */
    val cycleDailyLogs: StateFlow<List<CycleTrackingStore.DailyLog>> =
        _cycleDailyLogs.asStateFlow()

    // The v5 Health-hub skin-temp-suite engine snapshot (Cycle / Body clock / Illness heads-up), recomputed
    // from the cached merged days each analytics pass and published for HealthScreen's skin-temp section.
    // Declared BEFORE init for the same first-emission-ordering reason as the toggles above.
    private val _v5Signals = MutableStateFlow<V5HealthSignals.Snapshot?>(null)
    /** Published engine RESULTS for the Health hub's skin-temp suite (null until the first pass runs). */
    val v5Signals: StateFlow<V5HealthSignals.Snapshot?> = _v5Signals.asStateFlow()
    /** Keeps the illness banner, cycle history, and v5 snapshot on one completed assessment. */
    private val healthSignalRefreshMutex = Mutex()

    // Battery alerts (low ≤15% + charge-complete 100%). Opt-OUT, default ON; the actual firing
    // happens in BatteryAlertNotifier off the live-state stream — this flag just gates it (#368).
    private val _batteryAlertsEnabled = MutableStateFlow(NoopPrefs.batteryAlerts(appContext))
    /** Whether strap low/full battery notifications fire. */
    val batteryAlertsEnabled: StateFlow<Boolean> = _batteryAlertsEnabled.asStateFlow()

    // Predictive ~24h-runtime warning: a sub-gate under batteryAlerts (default ON), so the naggier
    // once-per-discharge-cycle alert can be silenced without losing the 15% safety net.
    private val _predictiveBatteryAlertsEnabled = MutableStateFlow(NoopPrefs.predictiveBatteryAlerts(appContext))
    /** Whether the predictive ~24h-runtime warning fires (in addition to batteryAlertsEnabled). */
    val predictiveBatteryAlertsEnabled: StateFlow<Boolean> = _predictiveBatteryAlertsEnabled.asStateFlow()

    // Declared BEFORE the init block for the SAME reason as _illnessWatchEnabled above: the bond
    // collector launched from init runs synchronously on Main.immediate and reads _smartAlarmEnabled on
    // its first (cached) emission. A declaration after init is null there and NPEs the constructor on a
    // cold start where the strap is already bonded - the #84 "crashes once, fine on the retry" race on
    // fast devices (S24+). Port of macOS BehaviorStore (Swift two-phase init makes this safe for free).
    private val _smartAlarmEnabled = MutableStateFlow(NoopPrefs.smartAlarmEnabled(appContext))
    val smartAlarmEnabled: StateFlow<Boolean> = _smartAlarmEnabled.asStateFlow()
    private val _smartAlarmMinutes = MutableStateFlow(NoopPrefs.smartAlarmMinutes(appContext))
    val smartAlarmMinutes: StateFlow<Int> = _smartAlarmMinutes.asStateFlow()
    // Enabled weekdays for the strap alarm (Calendar.DAY_OF_WEEK 1=Sun…7=Sat). Empty = every day.
    // Declared alongside the other _smartAlarm* fields (above init) for the same #84 reason. Mirrors
    // macOS BehaviorStore.smartAlarmWeekdays (#539).
    private val _smartAlarmWeekdays = MutableStateFlow(NoopPrefs.smartAlarmWeekdays(appContext))
    val smartAlarmWeekdays: StateFlow<Set<Int>> = _smartAlarmWeekdays.asStateFlow()
    // Per-weekday wake-time OVERRIDES (#554 reimpl): DAY_OF_WEEK → minute-of-day; a day with no entry uses
    // the default time. Declared above init for the same #84 reason. Empty = no overrides (pre-#554).
    private val _smartAlarmDayOverrides = MutableStateFlow(NoopPrefs.smartAlarmDayOverrides(appContext))
    val smartAlarmDayOverrides: StateFlow<Map<Int, Int>> = _smartAlarmDayOverrides.asStateFlow()

    // Sustained workout-exertion guidance. It only consumes fresh samples inside an explicitly tracked
    // workout or Live Session; the policy rejects isolated jumps and requires dwell before any cue.
    private val _zoneCoaching = MutableStateFlow(NoopPrefs.zoneCoaching(appContext))
    val zoneCoaching: StateFlow<Boolean> = _zoneCoaching.asStateFlow()
    private val _zoneCoachRecovery = MutableStateFlow(NoopPrefs.zoneCoachRecovery(appContext))
    /** Whether to buzz once after a delivered high-effort cue when accepted HR settles below reset. */
    val zoneCoachRecovery: StateFlow<Boolean> = _zoneCoachRecovery.asStateFlow()
    // Double-tap action (parity since 4.2.8) — persisted in SharedPreferences (NoopPrefs). Default NONE,
    // manual-first. The Automations screen edits this; the live double-tap dispatch (init collector below)
    // reads it. Port of macOS BehaviorStore.doubleTapAction + AppModel.runMacAction (the Apple-applicable
    // subset only — no lockScreen / runShortcut on Android).
    private val _doubleTapAction =
        MutableStateFlow(DoubleTapAction.fromRaw(NoopPrefs.of(appContext).getString(DOUBLE_TAP_ACTION_KEY, null)))
    /** What a strap double-tap triggers. */
    val doubleTapAction: StateFlow<DoubleTapAction> = _doubleTapAction.asStateFlow()

    /** Last strap [LiveState.lastEvent] the double-tap dispatch acted on, so a single physical tap fires
     *  exactly once: a DOUBLE_TAP event lingers in lastEvent (it's the most-recent event) and the
     *  collector re-runs on every LiveState emission, so we only dispatch on a FRESH transition into a
     *  DOUBLE_TAP event. Mirrors the iOS AppModel debounce (lastDoubleTapAt). Seeded with whatever event
     *  is already current so a ViewModel recreated right after a double-tap (e.g. a screen rotation, the
     *  process-owned BLE client keeps the old lastEvent) treats it as already-handled, not a fresh tap. */
    private var lastDispatchedGestureSequence: Long = ble.state.value.gestureSequence

    // PHONE smart alarm (#207) — distinct from the strap-firmware buzz alarm above. The state lives in
    // its own [SmartAlarmStore]; the GUARANTEED wake is an exact OS alarm via [SmartAlarmScheduler],
    // independent of Bluetooth, sleep detection, or this process being alive. The overnight watcher
    // (WhoopConnectionService) may only move it EARLIER within the window.
    private val phoneAlarmStore = SmartAlarmStore.from(appContext)
    private val _phoneAlarmEnabled = MutableStateFlow(phoneAlarmStore.enabled)
    /** Whether the phone smart alarm is armed (a guaranteed OS alarm is scheduled). */
    val phoneAlarmEnabled: StateFlow<Boolean> = _phoneAlarmEnabled.asStateFlow()
    private val _phoneAlarmTargetMinutes = MutableStateFlow(phoneAlarmStore.targetMinutes)
    /** Earliest acceptable wake time, minutes since midnight. */
    val phoneAlarmTargetMinutes: StateFlow<Int> = _phoneAlarmTargetMinutes.asStateFlow()
    private val _phoneAlarmWindowMinutes = MutableStateFlow(phoneAlarmStore.windowMinutes)
    /** How long after the target the guaranteed hard deadline sits. */
    val phoneAlarmWindowMinutes: StateFlow<Int> = _phoneAlarmWindowMinutes.asStateFlow()
    // "Buzz WHOOP 4" companion (#536): arm the strap's firmware alarm at the phone alarm's EARLIEST wake
    // time, so the strap buzzes first and the OS alarm fires at the hard deadline as backup. Declared here
    // with the phone-alarm flows (BEFORE init) so the init bond collector can read it. Default OFF.
    private val _buzzWhoop4Enabled = MutableStateFlow(NoopPrefs.buzzWhoop4WithAlarm(appContext))
    /** Whether the strap should also buzz at the phone smart alarm's earliest wake time (#536). */
    val buzzWhoop4Enabled: StateFlow<Boolean> = _buzzWhoop4Enabled.asStateFlow()

    // Wind-down nudge (#207) — cross-platform, NON-safety-critical. A gentle evening notification
    // derived from the user's earliest wake time. Inexact daily alarm; no exact-alarm permission.
    private val windDownStore = WindDownStore.from(appContext).also {
        it.migrateWakeMinutesIfNeeded(phoneAlarmStore.targetMinutes)
    }
    private val _windDownEnabled = MutableStateFlow(windDownStore.enabled)
    /** Whether the evening wind-down nudge is scheduled. */
    val windDownEnabled: StateFlow<Boolean> = _windDownEnabled.asStateFlow()
    private val _windDownSleepNeedMinutes = MutableStateFlow(windDownStore.sleepNeedMinutes)
    /** User-controlled baseline sleep target; the planner never silently changes it. */
    val windDownSleepNeedMinutes: StateFlow<Int> = _windDownSleepNeedMinutes.asStateFlow()
    private val _windDownGoalMode = MutableStateFlow(windDownStore.goalMode)
    /** Transparent planner behavior: fixed target, recent-balance adjustment, or extra opportunity. */
    val windDownGoalMode: StateFlow<com.noop.analytics.SleepGoalMode> =
        _windDownGoalMode.asStateFlow()
    private val _windDownLeadMinutes = MutableStateFlow(windDownStore.leadMinutes)
    /** Time reserved to settle before the suggested bedtime. */
    val windDownLeadMinutes: StateFlow<Int> = _windDownLeadMinutes.asStateFlow()
    private val _windDownWakeMinutes = MutableStateFlow(windDownStore.wakeMinutes)
    /** Planner-owned default wake time; independent of phone and band alarm schedules. */
    val windDownWakeMinutes: StateFlow<Int> = _windDownWakeMinutes.asStateFlow()
    private val _windDownWakeOverrides =
        MutableStateFlow(windDownStore.perDayWakeOverrides)
    /** Planner-only Calendar.DAY_OF_WEEK overrides. */
    val windDownWakeOverrides: StateFlow<Map<Int, Int>> =
        _windDownWakeOverrides.asStateFlow()
    private val _windDownRecoveryMinutes = MutableStateFlow(windDownStore.recoveryMinutes)
    /** Planner-derived bounded addition from recent debt (0–60 minutes). */
    val windDownRecoveryMinutes: StateFlow<Int> = _windDownRecoveryMinutes.asStateFlow()

    // MARK: - Today's cached metrics

    private val _today = MutableStateFlow<DailyMetric?>(null)
    val today: StateFlow<DailyMetric?> = _today.asStateFlow()

    /**
     * #849: Today's heavy history-wide reload guard. The Today screen runs a couple of expensive
     * history-wide passes (the workouts/sources footer, which derives HR per imported workout from raw strap
     * samples, and the pinned Stress / Fitness-age / Vitality reads over the whole metric history). Those run
     * in screen-level `LaunchedEffect(days)` blocks, which re-fire on EVERY re-mount of the screen
     * (tab-away + return, or an Apple-Health import that recreates it) even when the underlying data is
     * unchanged (`remember`/`LaunchedEffect` reset on a fresh composition). That repeated full reload is the
     * lag users see returning to Today after an import. This holds the content signature of the `days` list
     * the footer was last loaded for; the screen skips the reload when the signature is unchanged. It lives
     * on the long-lived ViewModel (not in the screen's `remember`), so it SURVIVES the re-mount that resets
     * the screen's local state. `null` = never loaded this process. Pure load-bookkeeping; never drives UI.
     */
    var todayFooterLoadedSig: Int? = null
    var todayFooterLoadedDeviceId: String? = null

    /**
     * #849: the last computed Today footer state, cached so a re-mount can RESTORE it without recomputing.
     * The Android bottom-tab NavHost disposes + recreates the Today composable on a tab switch (its plain
     * `remember` state resets), so simply skipping the reload would blank the footer. Seeding the screen's
     * `footer` from this cache on first composition keeps it populated while the redundant heavy reload is
     * skipped. Updated in lockstep with [todayFooterLoadedSig]. `null` = nothing cached yet this process.
     */
    var todayFooterCache: TodayFooterState? = null

    /**
     * #849: the same re-mount guard for Today's pinned "Your cards" reads (Stress / Fitness age / Vitality),
     * which scan the whole metric history. Signature + last-computed values are cached on the ViewModel so a
     * re-mount restores them and skips the redundant reload, exactly like the footer above. `null` = not yet
     * loaded this process; the cached triple is restored into the screen's local state on first composition.
     */
    var todayCardsLoadedSig: Int? = null
    var todayCardsLoadedDeviceId: String? = null
    var todayCardsLoadedProfileSig: String? = null
    var todayCardsLoadedAgeMetricVersion: Long? = null
    var todayStressCache: Double? = null
    var todayFitnessAgeCache: Double? = null
    var todayVitalityCache: Double? = null

    /**
     * The Rest number and its sparkline consume the same resolved sleep_performance history. Keep that
     * compact day/value map across Today re-mounts so one Room read serves both outputs and a day swipe
     * performs only in-memory filtering.
     */
    internal var todayRestCompositeLoadedKey: TodayRestCompositeCacheKey? = null
    internal var todayRestCompositeCache: Map<String, Double> = emptyMap()

    /**
     * Recent daily metrics (newest last), backing the Today grid + illness watch.
     * MERGED: imported "my-whoop" rows win per day; on-device computed "my-whoop-noop"
     * rows (from [IntelligenceEngine]) gap-fill, so recovery/strain/sleep populate from
     * the strap with no WHOOP import.
     */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    val recentDays: StateFlow<List<DailyMetric>> =
        // #797: bound the dashboard merge window. The unbounded daysMergedFlow re-merged the WHOLE daily
        // history on every DB change; a years-deep import made that a heavy refresh feeding Today / Trends /
        // illness watch. recentDaysMergedFlow caps each source to RECENT_DAYS_CAP most-recent days first, so
        // the merge stays bounded while every current surface (deepest Trends range, 7-day Fitness Age /
        // Vitality windows) keeps its data. Same oldest-first ordering as before.
        selectedDeviceId.flatMapLatest { repository.recentDaysMergedFlow(it) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /**
     * #386 self-heal: a "kick" the app-resume hook sends to wake the 15-min analyze loop early, so an
     * OEM-killed overnight re-score tick catches up the moment the user opens NOOP instead of showing a
     * stale Today card until the next sync/tick. The loop re-runs its durable dirty-marker-gated
     * analyzeRecent — an O(1) no-op when inputs are unchanged, a real catch-up when a kill left
     * unscored data (an unacknowledged generation survives failure or process death). `recentDays` is a reactive Room
     * flow, so the caught-up rows refresh the card on their own.
     *
     * A CONFLATED Channel, deliberately (NOT a replay=0 SharedFlow): a kick sent while the loop is busy
     * scoring — outside its `receive()` window — is RETAINED and delivered on the next receive, so a
     * resume that races the score is never dropped. Conflation coalesces rapid resumes to one wake, and
     * `trySend` never suspends the main-thread resume callback.
     */
    private val analyzeKick = Channel<Unit>(Channel.CONFLATED)

    /**
     * #78 hole-4: the app-foreground hook for the bond-loop salvage probe. Every activity resume runs
     * [WhoopBleClient.salvageProbeIfBondLoopPaused], which no-ops unless the #747 give-up pause is
     * latched AND its 10-minute floor has passed - so this is one cheap StateFlow read per resume in the
     * healthy case, and the self-heal path for a paused strap the user has since freed. Registered on the
     * Application (no lifecycle-process dependency needed); unregistered in [onCleared]. The iOS twin
     * observes didBecomeActive inside BLEManager itself. Also emits [analyzeKick] (#386 self-heal).
     */
    private val salvageProbeLifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: android.app.Activity) {
            ble.salvageProbeIfBondLoopPaused()
            // The process-wide Application hook reconciles notification/channel revocation first.
            // Mirror its persisted fail-closed result into this Activity-scoped UI on every resume.
            _windDownEnabled.value = windDownStore.enabled
            // #386 self-heal: nudge the analyze loop so a night the killed overnight tick never scored is
            // caught up now. Gated + coalesced downstream, so a healthy resume costs one indexed
            // generation snapshot.
            analyzeKick.trySend(Unit)
            viewModelScope.launch { refreshAdaptiveHydrationContext() }
            viewModelScope.launch { refreshCycleTracking() }
            onPlannedWorkoutCalendarChanged()
            refreshAgeMetricsIfProfileChanged()
        }
        override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: android.os.Bundle?) {}
        override fun onActivityStarted(activity: android.app.Activity) {}
        override fun onActivityPaused(activity: android.app.Activity) {}
        override fun onActivityStopped(activity: android.app.Activity) {}
        override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: android.os.Bundle) {}
        override fun onActivityDestroyed(activity: android.app.Activity) {}
    }

    init {
        // The registry seed resolves on Application's IO scope so Activity startup never blocks on Room.
        // Follow that process-wide projection here: a multi-device install may mount on the canonical
        // fallback for one frame, then every repository flow and active-device label switches together.
        viewModelScope.launch {
            noopApp.activeDeviceIdFlow.collect { resolved ->
                if (resolved == _selectedDeviceId.value) return@collect
                _selectedDeviceId.value = resolved
                refreshActiveDeviceName()
                analyzeKick.trySend(Unit)
                scheduleAgeMetricRecompute()
            }
        }
        // Multi-source coordinator (Phase 1B): reconcile the live source against the registry's active
        // device ONCE at launch. DORMANT for a single-WHOOP install (the default) — it no-ops and the
        // existing WHOOP flow below runs unchanged; it only acts when a non-WHOOP strap is the active
        // device. The Devices screen (next task) calls onActiveDeviceChanged after a setActive.
        noopApp.sourceCoordinator.start()
        // #78 hole-4: wire the app-foreground salvage probe (see salvageProbeLifecycleCallbacks above).
        noopApp.registerActivityLifecycleCallbacks(salvageProbeLifecycleCallbacks)
        reconcilePlannedWorkoutCalendarObserver()
        // Resolve the active band's name for the Live screen header (MW-6). Falls back to "WHOOP" in the
        // UI until this first read lands.
        refreshActiveDeviceName()
        // #577 — surface the strap's smart-alarm wake as a local notification too (iOS AppModel.postSmartAlarm
        // twin), so a pocketed phone doesn't miss the wrist buzz. Self-gates on the wrist-alerts master.
        ble.onSmartAlarmFired = {
            AlarmTapAutomationPrefs.armForActiveAlarm(appContext)
            com.noop.notif.SmartAlarmNotifier.onFired(appContext)
        }
        // Smooth HR from each LiveState emission, and re-arm the strap's firmware alarm whenever it
        // (re)bonds. A smart-alarm time changed while the strap was away never reached it — the send
        // is gated on bond — so the strap kept the OLD time and fired at it (#59). Gated on enabled so
        // a disabled alarm doesn't disarm on every reconnect.
        viewModelScope.launch {
            var lastBonded = false
            // StateFlow republishes for battery, wear, sync, logs, etc. Only an advancing packet sequence
            // is a real HR observation; seed at the current sequence so constructor replay is display context.
            var lastHeartRateSequence = ble.state.value.heartRateSampleSequence
            ble.state.collect { state ->
                if (state.heartRateSampleSequence != lastHeartRateSequence) {
                    lastHeartRateSequence = state.heartRateSampleSequence
                    state.heartRate?.let { raw ->
                        ingestHr(raw)
                        captureWorkoutSample(
                            sequence = state.heartRateSampleSequence,
                            rawBpm = raw,
                            receivedAtSec = System.currentTimeMillis() / 1_000L,
                        )
                    }
                }
                // #39 parity with iOS: clear the smoothed median on a true disconnect (no HR AND no R-R) so the
                // Health hero falls to "-" rather than freezing on the last value; a transient gap with R-R
                // still flowing keeps the median (matches AppModel.ingestHR's disconnect guard).
                if (state.heartRate == null && state.rr.isEmpty()) resetSmoothing()
                dispatchDoubleTap(state)
                if (state.bonded && !lastBonded) {
                    // #59/#536: re-arm the strap on (re)bond. One reconcile covers BOTH the smart wake-alarm
                    // and the Buzz-WHOOP companion, arming the single slot to the earliest either wants (#5).
                    reconcileStrapAlarm()
                    // Remember this strap so we can reconnect to it directly on the next launch (#67),
                    // e.g. after an APK update restarts the process.
                    ble.lastDeviceAddress?.let { NoopPrefs.setLastDevice(appContext, it, _selectedModel.value) }
                }
                lastBonded = state.bonded
            }
        }
        // Multi-WHOOP identity adoption: feed the connected strap's BLE address into the coordinator so the
        // active WHOOP row adopts it on first connect (and a different-but-registered strap is logged, not
        // overwritten). The Kotlin analogue of Swift's `connectedPeripheralUUID.removeDuplicates().sink`
        // (SourceCoordinator.swift:111-114) — connectedPeripheralAddress is a StateFlow, which already only
        // emits distinct values (operator fusion), so no distinctUntilChanged is needed. Inert on the
        // single-WHOOP path: my-whoop simply learns its strap's address once.
        viewModelScope.launch {
            ble.connectedPeripheralAddress
                .collect { addr -> noopApp.sourceCoordinator.connectedPeripheralChanged(addr) }
        }
        // Re-arm the strap's firmware alarm once per process-alive day. The firmware alarm is a single
        // absolute instant with NO recurrence and was previously re-armed ONLY on the bond edge — so a
        // strap that stays continuously bonded (a phone in range overnight) would fire once and then
        // never re-arm, going silent from day two. While the process is alive this loop recomputes the
        // next future occurrence each day and re-arms it.
        //
        // SAFETY: this is only the SECONDARY strap-buzz cue — the GUARANTEED wake is a separate exact OS
        // alarm via [SmartAlarmScheduler], which re-arms itself daily and survives process death. So a
        // process-alive loop is the right minimal scope here (parity with macOS's live re-arm Timer and
        // iOS's foreground re-arm). [reconcileStrapAlarm] re-evaluates BOTH features and only ever arms a
        // FUTURE instant (today's wake, or tomorrow's if already passed), so the daily tick can only move
        // the armed time equal-or-later (and harmlessly re-asserts a disarm when neither feature is on).
        viewModelScope.launch {
            while (isActive) {
                delay(STRAP_ALARM_REARM_INTERVAL_MS) // daily
                reconcileStrapAlarm()  // #5/#59/#536: one reconcile covers both strap-alarm features
            }
        }
        // Keep adaptive hydration timing current without polling. A scored Effort change or a confirmed
        // NOOP hydration mutation triggers one local read; missing values remain null and therefore leave
        // the user's base interval untouched. Health Connect changes are also refreshed on app resume and
        // when the Hydration screen reads its merged total.
        viewModelScope.launch {
            combine(today, HydrationStore.mutationSeq) { todayRow, _ -> todayRow }
                .collectLatest { refreshAdaptiveHydrationContext(it) }
        }
        // SharedPreferences writes are not observable on their own. ProfileStore emits one process-wide
        // revision for DOB/sex/waist edits; debounce quick stepper changes, reconcile stored provenance,
        // then wake every metric-series-only surface with one focused version.
        viewModelScope.launch {
            var skippedInitialReplay = false
            ProfileStore.ageMetricProfileChanges.collect {
                if (!skippedInitialReplay) {
                    skippedInitialReplay = true
                    return@collect
                }
                scheduleAgeMetricRecompute()
                reconcileHealthConnectBmiProjection()
            }
        }
        // Recompute the illness banner + today's row whenever cached days change.
        viewModelScope.launch {
            recentDays
                .onEach { AdaptiveDayEvaluationGate.invalidate() }
                .collectLatest { days ->
                // Only treat a row as "today" if its date is the phone's ACTUAL local calendar day.
                // Was days.lastOrNull() — the newest stored row regardless of date — so after importing
                // historical data the newest import (e.g. months old) showed as today's synthesis (#23).
                // Resolve via the LOGICAL day (rolls at 04:00 local), so between midnight and 4am we keep
                // showing the prior logical day's row instead of an empty new-calendar-day row (#144).
                // Presentation-only: stored row keys are untouched.
                //
                // Non-UTC pre-04:00 carve-out (#304): a user who sleeps before midnight and wakes before
                // the 04:00 rollover has the just-finished night banked under the NEW local calendar day
                // (sleep is keyed by the local wake-day), while the logical key still points at yesterday.
                // So: if the local calendar day differs from the logical day AND a row for the local day
                // has a banked night (totalSleepMin != null), prefer it; otherwise fall back to the
                // logical-day row, preserving the #144 anti-blank guard (no night yet ⇒ keep yesterday's).
                val logicalKey = logicalDayKeyNow()       // ISO yyyy-MM-dd, local logical day
                val localKey = java.time.LocalDate.now().toString()
                val illnessTodayKey = maxOf(logicalKey, localKey)
                _today.value = resolveTodayRow(days, logicalKey, localKey)
                refreshHealthSignalState()
                // Optional contextual reviews are independent of the illness score. They consume only
                // explicit, source-preserving data and have their own restart-safe cooldown gate.
                runCatching { evaluateContextualVitalInterventions(illnessTodayKey) }
                evaluateAdaptiveDayGuidance(days)
                _today.value?.let { todayRow ->
                    // Morning recap delivery intentionally does not live in this generic database
                    // collector. An old/imported row can republish here on launch; the recap is posted
                    // only by WhoopBleClient after a fresh offload's scoring transaction commits.
                    // #593: evidence-gated Effort-marker nudge. The legacy three-bucket recovery mapping
                    // is intentionally gone. A personal-history range exists only after today's explicit
                    // "as usual" check-in and a current solid multi-signal readiness read. Otherwise the
                    // target is null and the notifier stays silent. Everything remains on canonical 0-100.
                    val dailyPlan = DailyActionPlanner.plan(
                        today = todayRow.day,
                        readiness = ReadinessEngine.evaluate(days, today = todayRow.day),
                        checkIn = NoopPrefs.dailyActionCheckIn(appContext, todayRow.day),
                        recentEffort = days.map {
                            DailyActionPlanner.EffortDay(day = it.day, effort = it.strain)
                        },
                    )
                    StrainTargetNotifier.onStrainTarget(
                        context = appContext,
                        day = todayRow.day,
                        dayEffort = todayRow.strain,
                        targetRange = dailyPlan.target,
                    )
                }
                // Keep the home-screen widget fresh while the app is open — covers users who turned
                // the background service off (the service is the widget's heartbeat otherwise).
                // Throttled + no-op without a placed widget; never let a Glance hiccup kill the collector.
                runCatching {
                    val live = ble.state.value
                    // #911: resolve the widget anchor through the SHARED `widgetAnchorRow`, the SAME
                    // selector the background-service producer (WhoopConnectionService) uses, so the two
                    // producers can never drift. It anchors on today's logical-day row (rolls at 04:00,
                    // #304 carve-out) and, when today isn't scored yet, carries over the freshest
                    // STRICTLY-PRIOR scored day for the recovery-derived fields so the widget doesn't blank
                    // right after the rollover and never re-surfaces a stale scored row AS today. Only the
                    // widget reads the anchor here (the notification's honest-null contract lives in the
                    // service), keeping the two symmetric.
                    val anchorRow = widgetAnchorRow(days, logicalKey, localKey)
                    val vitalsRow = WidgetSnapshotFactory.vitalsRow(days, logicalKey, localKey)
                    WidgetSnapshotStore.push(
                        appContext,
                        WidgetSnapshotFactory.make(
                            anchorRow = anchorRow,
                            vitalsRow = vitalsRow,
                            heartRate = live.heartRate,
                            batteryPct = live.batteryPct?.roundToInt(),
                            connected = live.connected,
                            updatedAtMs = System.currentTimeMillis(),
                        ),
                    )
                }
                }
        }

        // Turn the strap's offloaded raw data into dashboard scores on launch and every
        // 15 minutes, so recovery / strain / sleep populate from the strap itself with no
        // import. IntelligenceEngine computes, persists under "my-whoop-noop", and the
        // merged daysMergedFlow above republishes the freshly computed scores to the UI.
        // Mirrors macOS AppModel's launch + 15-min analyze loop.
        viewModelScope.launch {
            // Vitality v2 migration must not depend on the raw-HR watermark: an upgraded install can have
            // unchanged raw data while a released v1 score still depended on provenance-free @57 steps.
            // This lightweight persisted-days pass removes or refreshes only computed Vitality rows before
            // the heavy scorer's normal offload grace/fingerprint gates.
            // DemoSeeder already writes v2-tagged synthetic rows and can race ViewModel creation on its
            // background seed coroutine; the released-data migration is intentionally production-only.
            if (!com.noop.BuildConfig.ENABLE_DEMO) {
                runCatching {
                    IntelligenceEngine.recomputeVitalityOnly(
                        repo = repository,
                        profile = currentProfile(),
                        profileProvider = ::currentProfile,
                        importedDeviceId = deviceId,
                    )
                }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
            }
            delay(FIRST_OFFLOAD_GRACE_MS) // give the first offload a moment
            // One-shot on-upgrade #547 timestamp heal: a bad strap clock/flash (pikapik) wrote raw +
            // computed rows with garbage timestamps (far-past / a 2027 spike / a future date) BEFORE the
            // ingest gate existed — one ~12h polluted block was re-attributed to every day (the repeated
            // 721-min sleep block) and a future-dated row surfaced as "last night · 12 Jul". Purge those
            // rows ONCE so the analyzeRecent pass below recomputes the real days cleanly. Guarded by a
            // persisted flag (re-running is harmless — the deletes are idempotent). Runs BEFORE the rescore.
            runCatching {
                // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547
                // re-pollution): a wandering-clock strap re-sends bad-dated records across syncs, so a single
                // on-upgrade pass can't be the only defence. The pending flag is cleared once the re-heal runs.
                if (!NoopPrefs.tsHealDone(appContext) || NoopPrefs.tsHealPending(appContext)) {
                    val purged = repository.healImplausibleTimestamps()
                    if (purged > 0) {
                        ble.externalLog(
                            "Heal #547: purged $purged row(s) with an implausible timestamp " +
                                "(bad strap clock - far-past or future-dated); rescoring clean days.",
                        )
                    }
                    NoopPrefs.setTsHealDone(appContext)
                    NoopPrefs.setTsHealPending(appContext, false)
                }
            }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
            // One-shot on-upgrade Effort rescore (#313): recompute strain from source across the FULL
            // history once, so any deep-history rows an older build left on the 0–21 axis regenerate on
            // the 0–100 axis. Guarded by a persisted flag, so it's a no-op on every subsequent launch.
            runCatching {
                IntelligenceEngine.runEffortRescoreIfNeeded(
                    repo = repository,
                    profileProvider = ::currentProfile,
                    importedDeviceId = deviceId,
                    maxHROverride = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble(),
                    flagGet = { NoopPrefs.effortRescoreDone(appContext) },
                    flagSet = { NoopPrefs.setEffortRescoreDone(appContext) },
                )
            }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
            while (isActive) {
                // #547 RE-POLLUTION: a sync since the last tick may have flagged a re-heal (its ingest gate
                // dropped bad-clock records). Re-run the purge BEFORE this tick's rescore so the affected days
                // recompute clean — not gated behind the one-shot done flag. Idempotent on a clean DB.
                runCatching {
                    if (NoopPrefs.tsHealPending(appContext)) {
                        val purged = repository.healImplausibleTimestamps()
                        if (purged > 0) {
                            ble.externalLog(
                                "Heal #547: purged $purged row(s) with an implausible timestamp " +
                                    "(bad strap clock detected this sync); rescoring clean days.",
                            )
                        }
                        NoopPrefs.setTsHealPending(appContext, false)
                    }
                }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
                // #836 parity (Android): the 15-min tick normally skips when raw inputs are unchanged. A
                // formula-only upgrade does not create a dirty marker, so the explicit Charge revision
                // overrides the skip and expands this one pass to full history. The completion marker is
                // written only from onSuccess below; interruption/failure therefore retries next iteration.
                val prefs = NoopPrefs.of(appContext)
                val chargeUpgradePending = ChargeFormulaUpgradeGate.needsRescore(
                    prefs.getString(ChargeFormulaUpgradeGate.COMPLETED_REVISION_KEY, null),
                )
                val activeZoneUpgradePending = ActiveZoneUpgradeGate.needsRescore(
                    prefs.getString(ActiveZoneUpgradeGate.COMPLETED_REVISION_KEY, null),
                )
                // Compatibility for explicit repair controls such as changing the HRV scoring window.
                // They historically wrote an empty watermark to request one pass. Preserve that O(1)
                // signal without bringing the COUNT/MAX fingerprint scan back to launch/resume.
                val explicitRescorePending =
                    prefs.getString(NoopPrefs.KEY_ANALYZE_WATERMARK, null) == ""
                val analysisSourceId = deviceId
                val registeredAnalysisSources = try {
                    noopApp.deviceRegistry.all()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    emptyList()
                }
                val analysisSourceIds = repository.analysisDirtySourceIds(
                    activeSourceId = analysisSourceId,
                    registeredDevices = registeredAnalysisSources,
                )
                val analysisLease = repository.claimAnalysisInput(
                    sourceIds = analysisSourceIds,
                    force = chargeUpgradePending ||
                        activeZoneUpgradePending ||
                        explicitRescorePending,
                )
                if (analysisLease != null) {
                    val analysisNowSeconds = System.currentTimeMillis() / 1_000L
                    val requestedAnalysisDays = if (chargeUpgradePending) {
                        ChargeFormulaUpgradeGate.HISTORY_DAYS
                    } else {
                        ActiveZoneUpgradeGate.HISTORY_DAYS
                    }
                    val analysisPlan = IntelligenceEngine.analysisScoringPlan(
                        requestedMaxDays = requestedAnalysisDays,
                        claims = analysisLease.claims,
                        nowSeconds = analysisNowSeconds,
                    )
                    val analysisDiagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
                        "analysis.recent",
                        fields = mapOf(
                            "charge_upgrade" to chargeUpgradePending.toString(),
                            "active_zone_upgrade" to activeZoneUpgradePending.toString(),
                            "explicit_rescore" to explicitRescorePending.toString(),
                            "change_gate_ok" to analysisLease.dirtyGateSucceeded.toString(),
                            "pass_kind" to analysisPlan.passKind.name.lowercase(),
                            "scan_days" to analysisPlan.maxDays.toString(),
                        ),
                    )
                    runCatching {
                        repository.runClaimedAnalysis(analysisLease) { analysisConsumption ->
                            IntelligenceEngine.analyzeRecent(
                                repo = repository,
                                profileProvider = ::currentProfile,
                                maxDays = analysisPlan.maxDays,
                                nowSeconds = analysisPlan.anchorNowSeconds,
                                analysisTimezoneOffsetSeconds =
                                    analysisPlan.timezoneOffsetSeconds,
                                historicalCatchUp = analysisPlan.isHistoricalCatchUp,
                                importedDeviceId = analysisSourceId,
                                maxHROverride = profileStore.hrMaxOverride
                                    .takeIf { it > 0 }?.toDouble(),
                        // I2 read-through (Phase 1B-4): resolve the single owning device per day from the
                        // registry. A single-WHOOP install resolves to [deviceId] for every day, so the
                        // reads stay byte-identical; multi-source installs score each day from one source.
                        ownerSource = RegistryDayOwnerSource(noopApp.deviceRegistry),
                        // Steps-estimate calibration: feed the user's manual override in (null = auto-fit),
                        // and mirror the fitted/manual model back into ProfileStore so the Settings/Steps
                        // screen can show + adjust it. Mirrors the macOS engine writing into ProfileStore.
                        manualStepCoefficient = profileStore.stepsManualOverride,
                        persistStepsCalibration = { cal ->
                            profileStore.stepsCalibrationCoefficient = cal.coefficient
                            profileStore.stepsCalibrationSampleDays = cal.sampleDays
                            profileStore.stepsCalibrationConfidence = cal.confidence
                            profileStore.stepsCalibrationManual = cal.manual
                        },
                        // Manual "Recalibrate baseline" anchor (Settings → Charge advanced). The analytics
                        // layer is Context-free, so read the epoch (whole seconds, written as a Long by the
                        // button) here and thread it down — foldHistory drops every HRV night before it.
                        baselineEpoch = NoopPrefs.of(appContext)
                            .getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble(),
                        recoveryEpoch = NoopPrefs.of(appContext)
                            .getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble(),
                        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log
                        // every other subsystem writes to (ble.externalLog PII-scrubs each line), so a bug
                        // report ships proof of what was computed per day. Mirrors the macOS sink wired to
                        // live.append(log:). (Sleep overhaul §2.5.)
                        diag = { line -> ble.externalLog(line) },
                        // Opt-in experimental sleep staging (V2) — read off SharedPreferences here (the
                        // analytics layer is Context-free) and thread it into the sleep self-heal. (V7 3b)
                        useExperimentalSleepV2 = PuffinExperiment.from(appContext).experimentalSleepV2,
                        // Opt-in motion-aware wake refinement (#364 follow-up) — same Context-free threading.
                        useMotionAwareWake = PuffinExperiment.from(appContext).motionAwareWake,
                        // Sleep & Rest test mode (Test Centre E5): when the SLEEP domain is on, route the
                        // per-day sleep gate trace into the SAME shareable strap log, tagged .sleep so it
                        // lands under the profile in the export. Zero-cost when off: the gate is one
                        // SharedPreferences bool read here and the sink stays null, so analyzeDay runs its
                        // byte-identical untraced path. Mirrors the macOS sleepTraceActive wiring.
                        sleepTraceSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.SLEEP))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.SLEEP) }
                            else null,
                        // Recovery (Charge) test mode (Test Centre Group G): when the RECOVERY domain is on,
                        // route each night's Charge term-breakdown into the .recovery-tagged strap log so a
                        // "Charge looks wrong" report shows which term moved it (and which was nil). Zero-cost
                        // when off: one SharedPreferences bool read and the sink stays null, so the Charge
                        // score path is byte-identical. Mirrors the macOS recoveryTraceActive wiring.
                        recoveryTraceSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.RECOVERY))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.RECOVERY) }
                            else null,
                        // Steps test mode (Test Centre): when the STEPS domain is on, route the per-day 5/MG
                        // raw-counter trace + the WHOOP-4 calibration trace into the .steps-tagged strap log so
                        // a "steps look off" report shows the wrap-aware deltas and the calibration state.
                        // Zero-cost when off: one SharedPreferences bool read and the sink stays null, so the
                        // steps total path is byte-identical. Mirrors the macOS stepsTraceActive wiring.
                        stepsTraceSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.STEPS))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.STEPS) }
                            else null,
                        // CAPTURE-B universal diagnostic (Test Centre, domain .universal): when ANY test
                        // mode is on, stamp each scored day's `dayOwner …` line into the .universal-tagged
                        // strap log so EVERY export self-diagnoses the read-vs-write identity + provenance.
                        // active(UNIVERSAL) returns true whenever any non-universal mode is on, so the
                        // universal line rides whatever domain the user enabled. Zero-cost when all off.
                        universalSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.UNIVERSAL))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.UNIVERSAL) }
                            else null,
                        // Workouts & GPS test mode (#975): when the WORKOUTS domain is on, route each detected-
                        // bout persist/drop decision into the .workouts-tagged strap log so an "auto workout
                        // appeared then vanished" is explainable from an export (previously the auto path
                        // produced NO trace). Zero-cost when off: one SharedPreferences bool read and the sink
                        // stays null, so the detected-bout persist path is byte-identical. Mirrors macOS.
                        workoutsTraceSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.WORKOUTS))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.WORKOUTS) }
                            else null,
                        // HRV & Autonomic test mode (#141): when on, route the nightly per-window RMSSD (by
                        // sleep stage) + the whole-night/deep-only/last-SWS summary to the .hrv-tagged strap
                        // log, so an "HRV reads high vs WHOOP" report shows which stages lift the average.
                        hrvTraceSink =
                            if (com.noop.testcentre.TestCentre.from(appContext)
                                    .active(com.noop.testcentre.TestDomain.HRV))
                                { line -> ble.externalLog(line, com.noop.testcentre.TestDomain.HRV) }
                            else null,
                        // #141: nightly HRV over deep-sleep windows only when the user picked WHOOP-style.
                                deepHrvWindow =
                                    UnitPrefs.hrvWindow(appContext) == HrvWindow.DEEP_SLEEP,
                                sourceConsumed = analysisConsumption::markSourceConsumed,
                                sourcesEvaluatedForOwnership =
                                    analysisConsumption::markSourcesEvaluatedForOwnership,
                            )
                        }
                        // analyzeRecent now hops to Dispatchers.Default; a scope cancellation surfaces as a
                        // CancellationException that runCatching would otherwise swallow, breaking the loop's
                        // own cancellation — rethrow it so onCleared() actually stops the loop. (#125)
                    }.onSuccess {
                        com.noop.AppDiagnosticsRecorder.endOperation(
                            analysisDiagnostic,
                            outcome = "completed",
                            includeResourceSnapshot = true,
                        )
                        if (chargeUpgradePending && analysisPlan.requestedWindowSatisfied) {
                            prefs.edit()
                                .putString(
                                    ChargeFormulaUpgradeGate.COMPLETED_REVISION_KEY,
                                    ChargeFormulaUpgradeGate.CURRENT_REVISION,
                                )
                                .apply()
                        }
                        if (activeZoneUpgradePending && analysisPlan.requestedWindowSatisfied) {
                            prefs.edit()
                                .putString(
                                    ActiveZoneUpgradeGate.COMPLETED_REVISION_KEY,
                                    ActiveZoneUpgradeGate.CURRENT_REVISION,
                                )
                                .apply()
                        }
                        if (explicitRescorePending &&
                            analysisPlan.requestedWindowSatisfied &&
                            prefs.getString(NoopPrefs.KEY_ANALYZE_WATERMARK, null) == ""
                        ) {
                            prefs.edit().remove(NoopPrefs.KEY_ANALYZE_WATERMARK).apply()
                        }
                        // Foreground/periodic reanalysis parity with the background post-sync hook. Reuse the
                        // Today card's suggestion-only scan; the notifier never asks permission or saves.
                        if (!analysisPlan.isHistoricalCatchUp) {
                            AutoWorkoutCandidateNotifier.afterReanalysis(
                                context = appContext,
                                repository = repository,
                                activeDeviceId = analysisSourceId,
                                traceSink =
                                    if (com.noop.testcentre.TestCentre.from(appContext)
                                            .active(com.noop.testcentre.TestDomain.WORKOUTS))
                                        { line ->
                                            ble.externalLog(
                                                line,
                                                com.noop.testcentre.TestDomain.WORKOUTS,
                                            )
                                        }
                                    else null,
                            )
                        }
                    }.onFailure {
                        com.noop.AppDiagnosticsRecorder.endOperation(
                            analysisDiagnostic,
                            outcome =
                                if (it is kotlin.coroutines.cancellation.CancellationException) {
                                    "canceled"
                                } else {
                                    "failed"
                                },
                            fields = mapOf("failure_kind" to it.javaClass.simpleName),
                            includeResourceSnapshot = true,
                        )
                        if (it is kotlin.coroutines.cancellation.CancellationException) throw it
                    }
                }
                // Opt-in writeback: push the freshly computed nights into Health Connect so other
                // apps see them. Idempotent (clientRecordId per metric+day), so re-running every
                // cycle just upserts. Never let an HC hiccup (perm revoked mid-flight, provider
                // update) break the analysis loop.
                if (_hcWriteback.value) {
                    runCatching { HealthConnectWriter.write(appContext, repository, deviceId) }
                    refreshHcWritebackStatus()   // #660: reflect the outcome the writer just persisted
                }
                // 15-min backstop cadence, but wake EARLY on an app-resume kick (#386 self-heal) so a
                // night the overnight tick was killed before scoring catches up the moment the user opens
                // NOOP. The next iteration's dirty-marker gate makes an unnecessary wake a cheap no-op.
                withTimeoutOrNull(ANALYZE_INTERVAL_MS) { analyzeKick.receive() }
            }
        }

        // Apply the persisted "Continuous HRV capture" intent so the BLE client holds the dense realtime
        // stream armed once bonded (the reconciler arms it post-bond). Only effective with background
        // connection on — without it there's nothing keeping the link up to stream over, so a continuous
        // want would be meaningless. Pushed BEFORE autoReconnectOnLaunch so a launch reconnect arms it.
        ble.setKeepStreamForData(continuousHrvEffective())

        // #477: push the persisted Power-saving prefs so the battery-adaptive levers apply from launch.
        applyPowerSaving()

        // Reconnect to the strap we last bonded to, so the user doesn't have to tap Connect after an
        // app update / restart (#67). Self-gates on the keep-connected pref + a saved strap + permission.
        autoReconnectOnLaunch()
    }

    private suspend fun refreshAdaptiveHydrationContext(todayRow: DailyMetric? = _today.value) {
        val config = HydrationReminderPrefs.config(appContext)
        if (!config.adaptiveEnabled) return
        val localDay = java.time.LocalDate.now().toString()
        val currentRow = todayRow?.takeIf { it.day == localDay }
        val reading = runCatching { HydrationStore.reading(repository) }.getOrNull()
        val profile = ProfileStore.from(appContext)
        val goalMl = HydrationGoal.personalizedDailyGoalMl(
            age = profile.age,
            ageConfirmed = profile.ageInputConfirmed,
            sex = profile.sex,
            sexConfirmed = profile.sexInputConfirmed,
            weightKg = profile.weightKg,
            weightConfirmed = profile.weightInputConfirmed,
            effort = currentRow?.strain,
        )
        val changed = HydrationReminderPrefs.updateAdaptiveContext(
            context = appContext,
            effort = currentRow?.strain,
            consumedMl = reading?.valueMl,
            goalMl = reading?.let { goalMl },
        )
        if (changed && config.enabled) HydrationReminderScheduler.reconcile(appContext)
    }

    /** Push the persisted BLE-behaviour prefs to the client. The #477 Power-saving levers: the
     *  offload-cadence stretch uses the battery-% threshold (0 = off when the master is off); the HRV pause
     *  is its own Battery-Saver toggle. The riskier connection-priority idle throttle is deliberately NOT
     *  exposed here — it stays dormant pending on-strap validation (#478). Also pushes the independent
     *  #533 "Faster history sync" experiment (its own toggle, NOT gated on the Power-saving master: it is a
     *  sync-speed lever, not a power-saving one). */
    private fun applyPowerSaving() {
        val on = NoopPrefs.powerSaving(appContext)
        // #533: the SAFE half of #477's connection-priority management shipped fully implemented but
        // DORMANT — nothing ever called this, so refreshConnectionPriority early-returned and EVERY
        // historical offload ran at the stack default. Behind the experimental toggle it escalates to HIGH
        // for the bounded offload burst (faster backlog drain). The RISKY idle→LOW_POWER half stays at 0
        // (still dormant, #478), and live-HR does not escalate (see WhoopBleClient.escalateForLiveHr) —
        // realtimeArmed covers the overnight capture window, which would otherwise hold HIGH for hours.
        ble.setConnectionPriorityManagement(
            enabled = NoopPrefs.fastHistorySync(appContext),
            idleThrottleBatteryPct = 0,
        )
        // #533: the second, orthogonal sync-speed lever — prefer LE 2M around the offload burst. Also
        // independent of the Power-saving master, and its own toggle so a field report can tell the two
        // apart (they have opposite battery profiles). No-op unless on.
        ble.setFastLinkPhy(NoopPrefs.fastLinkPhy(appContext))
        ble.setLowBatteryOffloadThrottle(if (on) NoopPrefs.powerSavingBatteryPct(appContext) else 0)
        // HRV pause is a sub-option: only effective while the master is on (defaults on when it is), and
        // now battery-%-aware like the offload lever — pass the same threshold.
        ble.setPauseCaptureOnPowerSave(
            on && NoopPrefs.pauseHrvOnPowerSave(appContext),
            NoopPrefs.powerSavingBatteryPct(appContext),
        )
    }

    /** Flip "Power saving" (Settings). Persists + applies immediately. */
    fun setPowerSaving(enabled: Boolean) {
        NoopPrefs.setPowerSaving(appContext, enabled)
        applyPowerSaving()
    }

    /** Set the power-saving battery-% threshold (Settings). Persists + applies immediately. */
    fun setPowerSavingBatteryPct(pct: Int) {
        NoopPrefs.setPowerSavingBatteryPct(appContext, pct)
        applyPowerSaving()
    }

    /** Flip "Pause HRV capture in Battery Saver" (Settings). Persists + applies immediately. */
    fun setPauseHrvOnPowerSave(enabled: Boolean) {
        NoopPrefs.setPauseHrvOnPowerSave(appContext, enabled)
        applyPowerSaving()
    }

    /** Flip the experimental "Faster history sync" (#533). Persists + applies immediately, so the next
     *  offload burst uses the new priority without waiting for a reconnect. */
    fun setFastHistorySync(enabled: Boolean) {
        NoopPrefs.setFastHistorySync(appContext, enabled)
        applyPowerSaving()
    }

    /** Flip the experimental LE 2M PHY preference (#533). Persists + pushes it to the client; it applies
     *  at the next offload burst, and switching it off releases an already-2M link back to 1M. */
    fun setFastLinkPhy(enabled: Boolean) {
        NoopPrefs.setFastLinkPhy(appContext, enabled)
        applyPowerSaving()
    }

    /** The effective continuous-HRV want: the user's "Continuous HRV capture" preference AND
     *  "Keep connected in the background" - the latter is what holds the link up for the stream to ride,
     *  so continuous capture is meaningless without it. */
    private fun continuousHrvEffective(): Boolean =
        NoopPrefs.continuousHrv(appContext) && NoopPrefs.backgroundConnection(appContext)

    /**
     * On launch, reconnect DIRECTLY to the strap we last bonded to (no scan), so the connection
     * survives an app update / restart without the user tapping Connect (#67). Gated on "Keep
     * connected in the background" (the user's keep-it-on intent) and a previously-bonded strap; the
     * BLE client itself no-ops if already connected or the runtime permission isn't granted yet.
     */
    private fun autoReconnectOnLaunch() {
        val saved = NoopPrefs.lastDevice(appContext) ?: return
        // Restore the model selection whenever a strap is remembered — deliberately NOT gated on the
        // background-connection pref, so an opted-out 5/MG user's picker and scan family still
        // survive restarts. Only the reconnect itself respects the pref. (#78 fork)
        _selectedModel.value = saved.second
        if (!NoopPrefs.backgroundConnection(appContext)) return
        // APK updates tear down the old foreground service along with the old process. Re-promote it
        // on the first launch after update/restart before reconnecting, so the persistent notification
        // and long-lived connection both come back without the user toggling the setting again.
        WhoopConnectionService.start(appContext)
        ble.reconnectToAddress(saved.first, saved.second)
    }

    /** Snapshot the user's body profile from SharedPreferences as an analytics [UserProfile]. */
    private fun currentProfile(): UserProfile = UserProfile(
        weightKg = profileStore.weightKg,
        heightCm = profileStore.heightCm,
        age = profileStore.age.toDouble(),
        sex = profileStore.sex,
        stepTicksPerStep = profileStore.stepTicksPerStep,
        waistCm = profileStore.waistCm,
        // The demo flavor's on-device history is synthetic and DemoSeeder stamps its actual profile
        // v2 markers. Treat both seeded Fitness Age inputs as confirmed so the first launch analysis
        // cannot purge the fixture while onboarding is still open. Production remains user-confirmed.
        ageInputConfirmed = profileStore.ageInputConfirmed || com.noop.BuildConfig.ENABLE_DEMO,
        sexInputConfirmed = profileStore.sexInputConfirmed || com.noop.BuildConfig.ENABLE_DEMO,
        fitnessAgeProvenanceRequired = profileStore.fitnessAgeProvenanceRequired,
        vo2maxProvenanceRequired = profileStore.vo2maxProvenanceRequired,
        vitalityProvenanceRequired = profileStore.vitalityProvenanceRequired,
    )

    /** Bounded analysis surfaces reuse the exact profile snapshot the background scorer consumes. */
    internal fun analysisProfileSnapshot(): UserProfile = currentProfile()

    // MARK: - HR smoothing (median filter)

    private fun ingestHr(raw: Int) {
        if (raw <= 0) return
        hrWindow.addLast(raw)
        while (hrWindow.size > hrWindowSize) hrWindow.removeFirst()
        val sorted = hrWindow.sorted()
        _bpm.value = sorted[sorted.size / 2]
    }

    // MARK: - Manual workout tracking
    //
    // Lets a user start/stop a workout themselves rather than relying on auto-detection (a top request).
    // Holds the start time + the live HR collected since; on End the window is scored via StrainScorer
    // and saved as a WorkoutRow (source "manual"), which then shows in the Workouts screen. The day's
    // strain already counts this HR (same live stream the store persists), so it's a per-session
    // annotation, not a double-count. Mirrors macOS AppModel.

    /** A manual workout in progress. [samples] admit genuine sequence-identified raw HR packets (the
     *  smoothed BPM is display-only); [liveStrain] is recomputed as the window grows. */
    data class ActiveWorkout(
        val startMs: Long,
        val sport: Sport,
        val gpsEnabled: Boolean,
        /** Pin attribution at Start; switching the active device mid-workout cannot move its row/samples. */
        val deviceId: String = WhoopBleClient.DEFAULT_DEVICE_ID,
        val samples: List<HrSample> = emptyList(),
        val track: List<RouteMath.LatLng> = emptyList(),
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
        val liveStrain: Double = 0.0,
        val avgHr: Int = 0,
        val peakHr: Int = 0,
        /** Frozen once End is tapped. Non-null means sampling/GPS stopped and this exact snapshot is
         *  saving or waiting for Retry; duration must never continue growing behind an error. */
        val endMs: Long? = null,
    )

    private val _activeWorkout = MutableStateFlow<ActiveWorkout?>(null)
    val activeWorkout: StateFlow<ActiveWorkout?> = _activeWorkout.asStateFlow()
    private val _lastWorkout = MutableStateFlow<WorkoutRow?>(null)
    val lastWorkout: StateFlow<WorkoutRow?> = _lastWorkout.asStateFlow()
    private val _workoutSaveInProgress = MutableStateFlow(false)
    val workoutSaveInProgress: StateFlow<Boolean> = _workoutSaveInProgress.asStateFlow()
    private val _workoutSaveError = MutableStateFlow<String?>(null)
    val workoutSaveError: StateFlow<String?> = _workoutSaveError.asStateFlow()
    /** Last full active-workout snapshot boundary. The growing HR list is checkpointed at a bounded cadence,
     *  not re-encoded on every packet; End still performs a forced durable write of the complete window. */
    private var lastActiveWorkoutCheckpointSec: Long? = null

    /** Ref-count + Activity-lifecycle gate for battery-intensive realtime requests. Declared before the
     *  workout-rehydrate init blocks so a restored explicit workout can safely reclaim its lease. */
    private val realtimeLeasePolicy = ForegroundRealtimeLeasePolicy()
    private var activeWorkoutOwnsRealtimeLease = false

    /** One-shot: the Today "workout in progress" indicator card raises this (via [openActiveWorkout]) so the
     *  Live screen presents the in-exercise overlay for an ALREADY-RUNNING workout. The overlay normally only
     *  opens at workout start (StartWorkoutSheet), so this is the single path that re-opens it for a session
     *  already in flight, the Android analogue of iOS NavRouter.presentActiveWorkout. LiveScreen consumes it
     *  on appear via [consumeActiveWorkoutRequest]; a normal Live visit never raises it, so it is inert. */
    private val _presentActiveWorkout = MutableStateFlow(false)
    val presentActiveWorkout: StateFlow<Boolean> = _presentActiveWorkout.asStateFlow()

    /** Raise the one-shot so the Live screen opens the in-exercise overlay on its next appearance. AppRoot
     *  also navigates to the Live destination; together that is one tap from the Today indicator card. */
    fun openActiveWorkout() { _presentActiveWorkout.value = true }

    /** Consume the one-shot (called by LiveScreen on appear). Returns true exactly once per raise, and ONLY
     *  while a workout is actually active, so a stale flag can never open an empty overlay. */
    fun consumeActiveWorkoutRequest(): Boolean {
        if (!_presentActiveWorkout.value) return false
        _presentActiveWorkout.value = false
        return _activeWorkout.value != null
    }

    /** Durable companion snapshot for every manual workout. GPS route points are append-checkpointed by
     *  [GpsSession] while live; this store keeps source/HR state and owns the final route after End until
     *  Room commits, giving both GPS and non-GPS workouts the same retry semantics. */
    private val activeWorkoutStore = ActiveWorkoutStore.from(appContext)

    /** Mirrors the process-level [GpsSession] route into [_activeWorkout] for live display. The route
     *  itself is collected by [WhoopConnectionService], not here, so it survives the screen turning off
     *  (#215) — this observer just republishes it to the UI while the ViewModel is alive. */
    private var gpsJob: Job? = null

    /** Emit one Workouts & GPS test-mode line tagged .workouts iff the mode is on. The cheap
     *  TestCentre.active(WORKOUTS) gate is read here, so nothing is built when the mode is off. The line
     *  is built lazily by the caller (already a short String, no heavy work). Diagnostic only. */
    private fun emitWorkoutsTrace(build: () -> String) {
        if (com.noop.testcentre.TestCentre.from(appContext)
                .active(com.noop.testcentre.TestDomain.WORKOUTS)
        ) {
            ble.externalLog(build(), com.noop.testcentre.TestDomain.WORKOUTS)
        }
    }

    /** Begin a workout for [sport]; start GPS route tracking when [gpsEnabled]. Single buzz confirms. */
    fun startWorkout(sport: Sport = WorkoutSport.default, gpsEnabled: Boolean = false) {
        if (_activeWorkout.value != null) return
        _lastWorkout.value = null
        _workoutSaveError.value = null
        _workoutSaveInProgress.value = false
        val startMs = System.currentTimeMillis()
        _activeWorkout.value = ActiveWorkout(
            startMs = startMs,
            sport = sport,
            gpsEnabled = gpsEnabled,
            deviceId = deviceId,
        )
        workoutHeartRateCursor = WorkoutHeartRateCursor(
            consumedSequence = ble.state.value.heartRateSampleSequence,
        )
        val liveState = ble.state.value
        workoutCautionPolicy = if (
            _zoneCoaching.value &&
            liveState.bonded &&
            liveState.encryptedBond &&
            liveState.worn
        ) {
            WorkoutCautionPolicy(
                config = WorkoutCautionPolicy.Config(hrMax = profileStore.hrMax.toDouble()),
                startTs = startMs / 1_000L,
            )
        } else {
            null
        }
        lastActiveWorkoutCheckpointSec = null
        holdActiveWorkoutRealtimeLease()
        buzz(1)
        // Workouts & GPS test mode (Test Centre): one session-start line tagged .workouts. Zero-cost when off.
        emitWorkoutsTrace {
            com.noop.analytics.WorkoutsTrace.sessionLine(
                event = "start", sportKey = WorkoutEditing.traceSportKey(sport.name), hrSamples = 0,
            )
        }
        if (gpsEnabled) {
            // Hand the route to the process-level session and make sure the foreground service is up to
            // collect it — even if the user hasn't opted into background connection, the route must keep
            // tracking with the screen off (#215). Then mirror the shared route back into the UI state.
            GpsSession.start(startMs, sport.name)
            WhoopConnectionService.start(appContext)
            observeGpsSession()
        }
        // Snapshot EVERY manual workout. GPS points remain in GpsSession's O(1) append journal while live;
        // this companion snapshot preserves source identity + raw HR and later owns the frozen final route.
        persistActiveWorkout(
            _activeWorkout.value,
            checkpointSec = startMs / 1_000L,
            force = true,
            durable = true,
        )
    }

    /** Map the in-memory session to its recovery record. A live GPS route stays in GpsSession; an ended
     *  one carries its exact final polyline here so a database failure/relaunch can retry without loss. */
    private fun activeWorkoutSnapshot(w: ActiveWorkout): ActiveWorkoutPersistence.Snapshot =
        ActiveWorkoutPersistence.Snapshot(
            startMs = w.startMs,
            sportName = w.sport.name,
            deviceId = w.deviceId,
            samples = w.samples,
            avgHr = w.avgHr,
            peakHr = w.peakHr,
            liveStrain = w.liveStrain,
            endMs = w.endMs,
            gpsEnabled = w.gpsEnabled,
            distanceM = w.distanceM,
            paceSecPerKm = w.paceSecPerKm,
            routePolyline = if (w.endMs != null && w.track.size >= 2) RouteMath.encode(w.track) else null,
        )

    private fun persistActiveWorkout(
        w: ActiveWorkout?,
        checkpointSec: Long = System.currentTimeMillis() / 1_000L,
        force: Boolean = false,
        durable: Boolean = false,
    ) {
        if (w == null) return
        if (!ActiveWorkoutCheckpointPolicy.shouldCheckpoint(
                lastCheckpointSec = lastActiveWorkoutCheckpointSec,
                sampleSec = checkpointSec,
                force = force,
            )
        ) return
        runCatching {
            val snapshot = activeWorkoutSnapshot(w)
            if (durable) activeWorkoutStore.saveDurably(snapshot) else {
                activeWorkoutStore.save(snapshot)
                true
            }
        }.onSuccess { saved -> if (saved) lastActiveWorkoutCheckpointSec = checkpointSec }
    }

    /** Mirror constant-size GPS totals into [_activeWorkout] while the ViewModel is alive. The full route
     *  remains in GpsSession's O(1) accumulator and is copied exactly once at End. */
    private fun observeGpsSession() {
        gpsJob?.cancel()
        gpsJob = viewModelScope.launch {
            GpsSession.state.collect { s ->
                val w = _activeWorkout.value ?: return@collect
                if (!w.gpsEnabled || w.endMs != null) return@collect
                // The exact route stays in GpsSession's private append accumulator (copying it here for every
                // fix was O(n²)). The live card only needs constant-size distance/pace; End snapshots once.
                _activeWorkout.value = w.copy(distanceM = s.distanceM, paceSecPerKm = s.paceSecPerKm)
            }
        }
    }

    /** Rebuild either a recording workout or an exact ended-but-unsaved retry snapshot after process death. */
    private fun rehydrateActiveWorkout() {
        if (_activeWorkout.value != null) return
        val snap = activeWorkoutStore.load()
        val gps = GpsSession.state.value

        if (snap != null) {
            val sport = WorkoutSport.all.firstOrNull { it.name == snap.sportName } ?: WorkoutSport.default
            val frozenTrack = snap.routePolyline?.let { encoded ->
                runCatching { RouteMath.decode(encoded) }.getOrNull()
            }.orEmpty()
            val matchingLiveGps = snap.gpsEnabled && gps.active &&
                gps.startMs == snap.startMs && gps.sportName == snap.sportName
            val track = when {
                frozenTrack.isNotEmpty() -> frozenTrack
                matchingLiveGps -> GpsSession.snapshotTrack()
                else -> emptyList()
            }
            val distance = when {
                frozenTrack.isNotEmpty() -> snap.distanceM
                matchingLiveGps -> gps.distanceM
                else -> snap.distanceM
            }
            val w = ActiveWorkout(
                startMs = snap.startMs,
                sport = sport,
                gpsEnabled = snap.gpsEnabled,
                deviceId = snap.deviceId,
                samples = snap.samples,
                track = track,
                distanceM = distance,
                paceSecPerKm = if (matchingLiveGps) gps.paceSecPerKm else snap.paceSecPerKm,
                liveStrain = snap.liveStrain,
                avgHr = snap.avgHr,
                peakHr = snap.peakHr,
                endMs = snap.endMs,
            )
            _activeWorkout.value = w
            workoutHeartRateCursor = WorkoutHeartRateCursor(
                consumedSequence = ble.state.value.heartRateSampleSequence,
                lastTimestampSec = snap.samples.maxOfOrNull { it.ts },
            )
            val liveState = ble.state.value
            workoutCautionPolicy = if (
                w.endMs == null &&
                _zoneCoaching.value &&
                liveState.bonded &&
                liveState.encryptedBond &&
                liveState.worn
            ) {
                WorkoutCautionPolicy(
                    config = WorkoutCautionPolicy.Config(hrMax = profileStore.hrMax.toDouble()),
                    startTs = snap.startMs / 1_000L,
                )
            } else {
                null
            }
            lastActiveWorkoutCheckpointSec = snap.samples.maxOfOrNull { it.ts } ?: (snap.startMs / 1_000L)

            if (w.endMs != null) {
                // A prior commit failed or the process died during it. The final route is already in this
                // snapshot, so stop any stale live GPS checkpoint and present Retry without resuming capture.
                if (gps.active) {
                    GpsSession.stop()
                    reconcileServiceAfterGpsWorkout()
                }
                _workoutSaveError.value = "This finished workout still needs to be saved."
            } else {
                holdActiveWorkoutRealtimeLease()
                if (w.gpsEnabled) {
                    if (!matchingLiveGps) GpsSession.start(w.startMs, w.sport.name)
                    WhoopConnectionService.start(appContext)
                    observeGpsSession()
                }
            }
            return
        }

        // Compatibility fallback for an older in-progress GPS checkpoint that predates the companion
        // active-workout snapshot. Preserve its route rather than hiding it after the upgrade.
        if (gps.active) {
            val sport = WorkoutSport.all.firstOrNull { it.name == gps.sportName } ?: WorkoutSport.default
            _activeWorkout.value = ActiveWorkout(
                startMs = gps.startMs,
                sport = sport,
                gpsEnabled = true,
                deviceId = deviceId,
                track = GpsSession.snapshotTrack(),
                distanceM = gps.distanceM,
                paceSecPerKm = gps.paceSecPerKm,
            )
            val liveState = ble.state.value
            workoutCautionPolicy = if (
                _zoneCoaching.value &&
                liveState.bonded &&
                liveState.encryptedBond &&
                liveState.worn
            ) {
                WorkoutCautionPolicy(
                    config = WorkoutCautionPolicy.Config(hrMax = profileStore.hrMax.toDouble()),
                    startTs = gps.startMs / 1_000L,
                )
            } else {
                null
            }
            persistActiveWorkout(
                _activeWorkout.value,
                checkpointSec = gps.startMs / 1_000L,
                force = true,
                durable = true,
            )
            WhoopConnectionService.start(appContext)
            holdActiveWorkoutRealtimeLease()
            observeGpsSession()
        }
    }

    /** A manually-started workout owns one logical high-rate lease until End, even if its overlay is
     *  dismissed. The foreground policy still physically disarms it whenever the Activity is paused. */
    private fun holdActiveWorkoutRealtimeLease() {
        if (activeWorkoutOwnsRealtimeLease) return
        activeWorkoutOwnsRealtimeLease = true
        requestRealtimeHr()
    }

    private fun releaseActiveWorkoutRealtimeLease() {
        if (!activeWorkoutOwnsRealtimeLease) return
        activeWorkoutOwnsRealtimeLease = false
        releaseRealtimeHr()
    }

    /** A GPS-started service returned START_STICKY. Re-enter it once after GPS ends so a background-BLE
     *  preference leaves the service running but NOT_STICKY; otherwise stop the GPS-only service entirely. */
    private fun reconcileServiceAfterGpsWorkout() {
        if (NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.start(appContext)
        } else {
            WhoopConnectionService.stop(appContext)
        }
    }

    /**
     * Freeze and save the active workout as a small transaction. End first commits an exact recovery
     * snapshot (bounded end, raw HR window, final GPS route), then stops capture, then writes Room. UI and
     * snapshot remain present on failure so Retry is idempotent; only a successful Room+HR commit clears.
     */
    fun endWorkout() {
        if (_workoutSaveInProgress.value) return
        var w = _activeWorkout.value ?: return

        if (w.endMs == null) {
            val finalTrack = if (w.gpsEnabled) GpsSession.snapshotTrack() else w.track
            val finalDistance = if (w.gpsEnabled) RouteMath.totalMeters(finalTrack) else w.distanceM
            val frozenEndMs = System.currentTimeMillis()
            val ended = w.copy(
                endMs = frozenEndMs,
                track = finalTrack,
                distanceM = finalDistance,
                paceSecPerKm = if (w.gpsEnabled)
                    RouteMath.paceSecPerKm(finalDistance, (frozenEndMs - w.startMs) / 1_000.0)
                else w.paceSecPerKm,
            )

            if (ended.samples.size < 2 && finalTrack.size < 2) {
                // Nothing truthful to save. This is the same deliberate empty-session discard as before.
                if (w.gpsEnabled) GpsSession.stop()
                gpsJob?.cancel(); gpsJob = null
                releaseActiveWorkoutRealtimeLease()
                activeWorkoutStore.clear()
                _activeWorkout.value = null
                workoutCautionPolicy = null
                lastActiveWorkoutCheckpointSec = null
                _workoutSaveError.value = null
                // Workouts & GPS test mode: record WHY a session vanished (too short / no track), tagged .workouts.
                emitWorkoutsTrace {
                    com.noop.analytics.WorkoutsTrace.sessionLine(
                        event = "discarded", sportKey = WorkoutEditing.traceSportKey(w.sport.name),
                        hrSamples = w.samples.size, gpsPoints = if (w.gpsEnabled) finalTrack.size else null,
                    )
                }
                _lastWorkout.value = null
                if (w.gpsEnabled) reconcileServiceAfterGpsWorkout()
                return
            }

            // The one synchronous barrier in this lifecycle: do not stop GPS/sampling until the exact
            // final route and end time are known to be on disk. A failure leaves the original workout live.
            if (!activeWorkoutStore.saveDurably(activeWorkoutSnapshot(ended))) {
                _workoutSaveError.value = "Couldn't secure this workout for saving. It is still recording; try End again."
                return
            }
            w = ended
            _activeWorkout.value = ended
            workoutCautionPolicy = null
            releaseActiveWorkoutRealtimeLease()
            gpsJob?.cancel(); gpsJob = null
            if (w.gpsEnabled) {
                GpsSession.stop() // safe now: the final route is durably present in ActiveWorkoutStore
                reconcileServiceAfterGpsWorkout()
            }
        }

        val endMs = w.endMs ?: return
        val samples = w.samples
        val track = w.track
        val distanceM = w.distanceM
        val avg = if (samples.isNotEmpty()) samples.sumOf { it.bpm } / samples.size else null
        val peak = if (samples.isNotEmpty()) samples.maxOf { it.bpm } else null
        val strain = if (samples.size >= 2)
            StrainScorer.strain(samples, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) else null
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        val energyKcal = if (samples.size >= 2)
            Calories.estimateBoutCalories(samples, currentProfile(), profileStore.hrMax.toDouble(), null)
                .first.takeIf { it > 0 }
        else null
        val row = WorkoutRow(
            deviceId = w.deviceId, startTs = w.startMs / 1000, endTs = endMs / 1000,
            sport = w.sport.name, source = "manual", durationS = (endMs - w.startMs) / 1000.0,
            energyKcal = energyKcal,
            avgHr = avg, maxHr = peak, strain = strain,
            distanceM = distanceM.takeIf { it > 0 },
            routePolyline = if (track.size >= 2) RouteMath.encode(track) else null,
        )
        _workoutSaveInProgress.value = true
        _workoutSaveError.value = null
        viewModelScope.launch {
            val result = ActiveWorkoutPersistence.saveThenClear(
                save = {
                    repository.upsertWorkouts(listOf(row))
                    // Keep the snapshot until HR rows commit too. Retry is safe: workout upsert is idempotent
                    // and hrSample uses IGNORE-on-conflict for the same device+second.
                    if (samples.isNotEmpty()) repository.insertHr(samples)
                },
                clear = { activeWorkoutStore.clear() },
            )
            _workoutSaveInProgress.value = false
            when (result) {
                ActiveWorkoutPersistence.SaveResult.Saved -> {
                    _activeWorkout.value = null
                    workoutCautionPolicy = null
                    lastActiveWorkoutCheckpointSec = null
                    _workoutSaveError.value = null
                    _lastWorkout.value = row
                    emitWorkoutsTrace {
                        com.noop.analytics.WorkoutsTrace.sessionLine(
                            event = "end", sportKey = WorkoutEditing.traceSportKey(w.sport.name),
                            hrSamples = samples.size,
                            durationSec = ((endMs - w.startMs) / 1000L).toInt(),
                            gpsPoints = if (w.gpsEnabled) track.size else null,
                        )
                    }
                    buzz(2)
                    if (_hcWriteback.value) {
                        runCatching { HealthConnectWriter.writeExercise(appContext, row, w.sport.exerciseType) }
                        writebackHealthConnectNow()
                    }
                }
                is ActiveWorkoutPersistence.SaveResult.Failed -> {
                    _workoutSaveError.value =
                        "Couldn't save this workout. It is still kept on this device. Retry when ready. (${result.detail})"
                }
            }
        }
    }

    /** Explicitly abandon a recording or retained failed-save workout. UI must confirm this action. */
    fun discardActiveWorkout() {
        if (_workoutSaveInProgress.value) return
        val w = _activeWorkout.value ?: return
        if (w.gpsEnabled) {
            GpsSession.stop()
            gpsJob?.cancel(); gpsJob = null
            reconcileServiceAfterGpsWorkout()
        }
        releaseActiveWorkoutRealtimeLease()
        activeWorkoutStore.clear()
        _activeWorkout.value = null
        workoutCautionPolicy = null
        lastActiveWorkoutCheckpointSec = null
        _lastWorkout.value = null
        _workoutSaveError.value = null
    }

    /** Append one genuine RAW HR packet and recompute running stats. Smoothed display state, timers and
     *  unrelated LiveState emissions cannot enter this path. */
    private fun captureWorkoutSample(sequence: Long, rawBpm: Int, receivedAtSec: Long) {
        // `_activeWorkout` (declared further down) can still be null HERE: the HR collector in the first
        // init block can fire ingestHr -> captureWorkoutSample INLINE during construction (a StateFlow
        // replays its current value to a new collector), before this field's initializer has run — the
        // JVM field-init footgun. The safe-call tolerates that one-shot race; once constructed it is
        // never null. (Fixes the NPE in @maddognik's ADB: captureWorkoutSample -> getValue on null.)
        @Suppress("UNNECESSARY_SAFE_CALL")
        val w = _activeWorkout?.value ?: return
        if (w.endMs != null) return
        val fresh = workoutHeartRateCursor.consume(
            sequence = sequence,
            bpm = rawBpm,
            receivedAtSec = receivedAtSec,
            deviceId = w.deviceId,
        ) ?: return
        val s = w.samples + fresh
        val strain = StrainScorer.strain(s, maxHR = profileStore.hrMax.toDouble(), sex = profileStore.sex) ?: 0.0
        val updated = w.copy(
            samples = s, avgHr = s.sumOf { it.bpm } / s.size, peakHr = s.maxOf { it.bpm }, liveStrain = strain,
        )
        _activeWorkout.value = updated
        evaluateWorkoutCaution(nowSec = fresh.ts, bpm = fresh.bpm)
        persistActiveWorkout(updated, checkpointSec = fresh.ts)
    }

    private fun evaluateWorkoutCaution(nowSec: Long, bpm: Int) {
        val state = ble.state.value
        if (
            !_zoneCoaching.value ||
            !state.bonded ||
            !state.encryptedBond ||
            !state.worn
        ) {
            workoutCautionPolicy = null
            return
        }
        val policy = workoutCautionPolicy ?: WorkoutCautionPolicy(
            config = WorkoutCautionPolicy.Config(hrMax = profileStore.hrMax.toDouble()),
            startTs = nowSec,
        ).also { workoutCautionPolicy = it }
        val cue = policy.update(nowSec, bpm).cue ?: return
        val canBuzz = state.bonded && state.encryptedBond && state.worn
        val wristHapticsEnabled =
            NotifPrefs.getBool(appContext, NotifPrefs.MASTER, false)
        when (cue) {
            WorkoutCautionPolicy.Cue.EASE_OFF ->
                if (wristHapticsEnabled && canBuzz) ble.buzz(3)
            WorkoutCautionPolicy.Cue.PAUSE_AND_ASSESS -> {
                if (wristHapticsEnabled && canBuzz) ble.buzz(5)
                WorkoutCautionNotifier.onPauseAndAssess(appContext)
            }
            WorkoutCautionPolicy.Cue.RECOVERED -> {
                if (wristHapticsEnabled && canBuzz && _zoneCoachRecovery.value) ble.buzz(1)
            }
        }
    }

    // MARK: - Workouts screen (load + manual edit · relabel · dismiss · delete) (#107)
    //
    // The screen observes [workouts]; every mutation re-loads it so the list reflects the new state
    // immediately. Loads ALL sources — strap (imported + manual), Apple Health / Health Connect, and
    // the on-device DETECTED bouts under "<deviceId>-noop" - then filters out dismissed detected bouts
    // so a duplicate the auto-detector created is visible but removable. Mirrors macOS
    // Repository.workoutRows.

    private val _workouts = MutableStateFlow<List<WorkoutRow>>(emptyList())
    /** All workouts for the Workouts screen (newest first), dismissed detected bouts removed. */
    val workouts: StateFlow<List<WorkoutRow>> = _workouts.asStateFlow()

    /** Persist a bed/wake-time edit for one sleep session in place, then
     *  re-score the affected day immediately so Charge / Rest / recovery and the persisted
     *  sleep_performance honor the corrected window without waiting for the 15-min loop — matching Swift
     *  SleepView, which calls analyzeRecent() right after editSleepTimes. Returns false when the row was
     *  concurrently removed or the write failed, allowing the optimistic screen to reload authoritative
     *  history instead of fabricating a replacement. */
    suspend fun updateSleepSessionTimes(
        session: com.noop.data.SleepSession,
        newStartTs: Long,
        newEndTs: Long,
    ): Boolean {
        val saved = runCatching {
            repository.updateSleepSessionTimes(session, newStartTs, newEndTs)
        }.onFailure {
            if (it is CancellationException) throw it
        }.getOrDefault(false)
        rescoreAfterEdit()
        return saved
    }

    /** Delete one sleep session, then re-score the affected day immediately so the dashboard aggregates
     *  recompute as if the misread night were never recorded — matching Swift SleepView's analyzeRecent()
     *  after deleteSleepSession. Swallows persist failures — the Sleep screen already removed it
     *  optimistically, so the day recomputes without the misread night either way. (#281) */
    suspend fun deleteSleepSession(session: com.noop.data.SleepSession) {
        runCatching { repository.deleteSleepSession(session) }
        rescoreAfterEdit()
    }

    /** Undo the most recent sleep delete (#65): restore the row into its ORIGINAL namespace, lift the
     *  tombstone, then re-score so the day recomputes WITH the night again, matching Swift SleepView's
     *  analyzeRecent() after undoDeleteSleepSession. Swallows persist failures. */
    suspend fun undoDeleteSleepSession(session: com.noop.data.SleepSession) {
        runCatching { repository.undoDeleteSleepSession(session) }
        rescoreAfterEdit()
    }

    /** Re-open one deliberately deleted sleep window (#515): remove its durable tombstone first, then
     *  immediately run the normal detector/scorer over the stored raw data. Unlike optimistic edits, this
     *  returns false when the marker could not be removed — rescoring while it is still present would keep
     *  suppressing the night and make a successful-looking button a no-op. */
    suspend fun recomputeDeletedSleep(marker: com.noop.data.DismissedSleep): Boolean {
        val cleared = runCatching {
            repository.allowSleepReDetection(marker.deviceId, marker.startTs)
        }.isSuccess
        if (!cleared) return false
        rescoreAfterEdit()
        return true
    }

    /** Hide an unwanted deleted-sleep row from the persistent recompute card while preserving its
     *  detector tombstone. This is deliberately separate from [recomputeDeletedSleep], which removes the
     *  tombstone and can therefore allow that mistaken sleep to return (#515). */
    suspend fun hideDeletedSleepWindow(marker: com.noop.data.DismissedSleep): Boolean =
        runCatching {
            repository.hideDeletedSleepWindow(marker.deviceId, marker.startTs)
        }.getOrDefault(false)

    /** Manually add a missed nap as its OWN session (#508) — staged from raw, written under the computed
     *  source with userEdited=true so the recompute guard keeps it and it's never folded into main sleep —
     *  then re-score the affected day immediately so the day's aggregates pick up the new session, matching
     *  Swift SleepView's analyzeRecent() after addManualNap. Swallows persist failures; the Sleep screen
     *  recomputes from the persisted rows on its next reload. */
    suspend fun addManualNap(startTs: Long, endTs: Long) {
        runCatching { repository.addManualNap(deviceId, startTs, endTs) }
        rescoreAfterEdit()
    }

    // --- On-device short-nap detection (PR #569 reimpl under NoopApp). Candidates are detected on the
    // offload hook (WhoopBleClient.maybeDetectNaps) and queued in NapStore; this is the review surface. ---

    /** Whether on-device nap detection is enabled (opt-in, default OFF). */
    val napDetectionEnabled: StateFlow<Boolean> get() = _napDetectionEnabled
    private val _napDetectionEnabled = MutableStateFlow(com.noop.analytics.NapPrefs.enabled(appContext))

    fun setNapDetectionEnabled(enabled: Boolean) {
        _napDetectionEnabled.value = enabled
        com.noop.analytics.NapPrefs.setEnabled(appContext, enabled)
    }

    /** The detected naps awaiting review (newest first). Read on demand by the Automations review card. */
    fun pendingNaps(): List<com.noop.analytics.NapCandidate> =
        com.noop.data.NapStore.pending(appContext)

    /** Accept a detected nap: persist it as a manual nap session (the SAME #508 overlap-guarded path) and
     *  drop it from the review queue. Returns the still-pending list for the UI to re-render. */
    suspend fun acceptDetectedNap(candidate: com.noop.analytics.NapCandidate): List<com.noop.analytics.NapCandidate> {
        addManualNap(candidate.start, candidate.end)
        return com.noop.data.NapStore.remove(appContext, com.noop.data.NapStore.idFor(candidate))
    }

    /** Dismiss a detected nap: drop it AND remember the window so a re-detect can't re-queue it. */
    fun dismissDetectedNap(candidate: com.noop.analytics.NapCandidate): List<com.noop.analytics.NapCandidate> =
        com.noop.data.NapStore.dismiss(appContext, com.noop.data.NapStore.idFor(candidate))

    /**
     * Re-score recent days right after an edit that changes them (a sleep edit / delete / add-nap, or a
     * manually-added workout — #598), so daily recovery + the
     * persisted sleep_performance recompute and [recentDays] (daysMergedFlow) republishes to Today the
     * same instant the Sleep tab updates — closing the up-to-15-min staleness where Charge / Rest on Today
     * disagreed with the Sleep tab after an edit (audit #2/#3/#4). The args are kept byte-identical to the
     * launch + 15-min analyze loop above (so a manual re-score and the loop produce the same scores);
     * mirrors Swift SleepView, which calls intelligence.analyzeRecent() after each edit. Best-effort —
     * a failure here just leaves the loop to catch up; never throws into the edit caller. CancellationException
     * is rethrown so a ViewModel teardown mid-edit isn't swallowed (matches the loop's #125 handling).
     */
    private suspend fun rescoreAfterEdit() {
        runCatching {
            IntelligenceEngine.analyzeRecent(
                repo = repository,
                profileProvider = ::currentProfile,
                importedDeviceId = deviceId,
                maxHROverride = profileStore.hrMaxOverride
                    .takeIf { it > 0 }?.toDouble(),
                ownerSource = RegistryDayOwnerSource(noopApp.deviceRegistry),
                manualStepCoefficient = profileStore.stepsManualOverride,
                persistStepsCalibration = { cal ->
                    profileStore.stepsCalibrationCoefficient = cal.coefficient
                    profileStore.stepsCalibrationSampleDays = cal.sampleDays
                    profileStore.stepsCalibrationConfidence = cal.confidence
                    profileStore.stepsCalibrationManual = cal.manual
                },
                baselineEpoch = NoopPrefs.of(appContext)
                    .getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble(),
                recoveryEpoch = NoopPrefs.of(appContext)
                    .getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble(),
                // #195/#141: keep the HRV window consistent with the 15-min loop — without this a sleep edit
                // would re-score + persist every night's HRV over the WHOLE night, silently overwriting the
                // deep-window value (the "deep sleep window changes nothing" bug).
                deepHrvWindow = UnitPrefs.hrvWindow(appContext) == HrvWindow.DEEP_SLEEP,
                // Opt-in experimental sleep staging (V2) — same flag the 15-min loop reads, so a manual
                // re-score after an edit stages with the same engine the user chose. (V7 Pillar 3b)
                useExperimentalSleepV2 = PuffinExperiment.from(appContext).experimentalSleepV2,
                // Opt-in motion-aware wake refinement (#364 follow-up) — same flag the 15-min loop reads.
                useMotionAwareWake = PuffinExperiment.from(appContext).motionAwareWake,
            )
        }.onFailure { if (it is kotlin.coroutines.cancellation.CancellationException) throw it }
    }

    /** Re-read every source + the dismissed markers and republish [workouts]. */
    fun loadWorkouts() {
        viewModelScope.launch {
            val now = System.currentTimeMillis() / 1000
            // #28: read across the strap-id + "my-whoop" union (like HR/sleep), so a re-added/newly-paired
            // strap whose workouts live under "my-whoop" isn't shown an empty Workouts screen.
            val whoop = repository.workoutsUnion(deviceId, 0L, now)
            val apple = repository.workouts("apple-health", 0L, now) +
                repository.workouts("health-connect", 0L, now)
            val detected = repository.detectedWorkoutsUnion(deviceId, 0L, now)
            // Imported lifting sessions (Hevy / Liftosaur) carry a volume-load note but no HR — they're
            // a strength-volume estimate, not cardio. Kept OUT of the strap HR-fill below so we never
            // fabricate a heart rate the lift never measured.
            val lifting = repository.workouts(LiftingImporter.SOURCE_ID, 0L, now)
            // #29: imported activity FILES (FIT / GPX / TCX) live under their own "activity-file" source, so
            // without reading it a successful file import never appears in the Workouts list (Data Sources
            // counts it, the load didn't). They're cardio (often GPS + HR), so they go through the strap
            // HR-fill below like the imported Apple sessions — a GPX with no HR borrows the strap's, while a
            // FIT that already carries HR is untouched (fill only fills nulls).
            val activityFiles = repository.workouts(ActivityFileImporter.SOURCE_ID, 0L, now)
            val markers = repository.dismissedDetected(deviceId)
            // Fill imported sessions' missing HR from strap samples (#77), same as before; detected /
            // manual rows already carry their own HR so they pass through unchanged. #961: also backfill a
            // strap-native row's Effort (strain) from the strap trace when it's null, so a live/manual
            // session that ended with sparse HR can't show a blank Effort while the day total counted it.
            val filled = repository.fillWorkoutHrFromStrap(
                (whoop + apple + detected + activityFiles),
                strainMaxHR = profileStore.hrMax.toDouble(),
                strainSex = profileStore.sex,
            )
            // #687: collapse the SAME activity tracked live under the strap AND imported from Health
            // Connect / Apple Health into one richer entry — they sit under different sources so without
            // this they show as two sessions. Dedup runs on the dismissed-filtered set, before the sort.
            val filteredRows = WorkoutEditing.filterDismissed(filled + lifting, markers)
            // Workouts & GPS test mode: when on, run the dedup twin which returns the BYTE-IDENTICAL kept list
            // plus a trace line per collapsed cross-source pair, tagged .workouts. Zero-cost when off (the gate
            // is one SharedPreferences bool read), and the kept list equals dedupCrossSource exactly, so the
            // workout list the screen shows is unchanged. Mirrors the macOS Repository.workoutRows wiring.
            val deduped = if (com.noop.testcentre.TestCentre.from(appContext)
                    .active(com.noop.testcentre.TestDomain.WORKOUTS)
            ) {
                val (kept, trace) = WorkoutEditing.dedupCrossSourceTrace(filteredRows)
                for (line in trace) ble.externalLog(line, com.noop.testcentre.TestDomain.WORKOUTS)
                kept
            } else {
                WorkoutEditing.dedupCrossSource(filteredRows)
            }
            val sorted = deduped.sortedByDescending { it.startTs }
            _workouts.value = sorted
            // Post-workout summary (#517) — opt-in, default OFF. The newest session (by start) drives a
            // one-shot Effort + duration + avg-HR notification when it's strictly newer than the last one
            // summarised, so a re-sync of the same backlog never re-fires. Honest timing: a strap-only
            // workout only surfaces on the next history offload, so the copy says "after your strap synced".
            sorted.firstOrNull()?.let { maybeNotifyWorkout(it) }
        }
    }

    /** Build the opt-in post-workout summary copy from [row] (Effort on the user's scale, duration, avg HR)
     *  and hand it to the notifier, which applies the strictly-newer gate. avgHr is omitted when absent —
     *  never invented. No-op when the toggle is off (gated inside the notifier). */
    private fun maybeNotifyWorkout(row: WorkoutRow) {
        // Effort is the workout's stored 0–100 strain, shown on the user's chosen scale (0–100 or 0–21).
        // A session with no scored strain still gets a summary (duration + HR), but without an Effort line.
        val scale = UnitPrefs.effortScale(appContext)
        val durMin = ((row.durationS ?: (row.endTs - row.startTs).toDouble()) / 60.0).roundToInt()
        val (title, body) = if (row.strain != null) {
            ScheduledReportPolicy.workoutCopy(
                sportLabel = WorkoutEditing.displaySport(row.sport),
                effortDisplay = UnitFormatter.effortDisplay(row.strain, scale),
                effortMaxLabel = UnitFormatter.effortScaleMax(scale),
                durationLabel = ScheduledReportPolicy.durationLabel(durMin),
                avgHr = row.avgHr,
            )
        } else {
            // No strain: a leaner summary that still tells the user the session landed.
            val pieces = buildList {
                add(ScheduledReportPolicy.durationLabel(durMin))
                row.avgHr?.let { add("avg $it bpm") }
            }
            "Workout logged: ${WorkoutEditing.displaySport(row.sport)}" to
                (pieces.joinToString(" · ") + ". Summarised after your strap synced.")
        }
        ScheduledReportNotifier.onWorkout(appContext, row.startTs, title, body)
    }

    private var postWorkoutReportPreferenceJob: Job? = null

    /**
     * Change the post-workout report preference as one transaction. Enabling first snapshots the
     * source-complete database frontier, then persists ON; this prevents an old workout from racing a
     * screen-local/empty list. A later off-tap cancels an in-flight enable and removes a standing alert.
     */
    fun setPostWorkoutReportEnabled(enabled: Boolean, onComplete: (Boolean) -> Unit = {}) {
        postWorkoutReportPreferenceJob?.cancel()
        postWorkoutReportPreferenceJob = null
        if (!enabled) {
            NoopPrefs.setPostWorkoutReportEnabled(appContext, false)
            ScheduledReportNotifier.cancelWorkout(appContext)
            onComplete(false)
            return
        }
        NoopPrefs.setPostWorkoutReportEnabled(appContext, false)
        postWorkoutReportPreferenceJob = viewModelScope.launch {
            val newest = runCatching { repository.latestWorkoutStartAllSources() }
                .getOrElse {
                    onComplete(false)
                    return@launch
                }
            ScheduledReportNotifier.seedWorkoutFrontier(appContext, newest)
            if (!isActive) return@launch
            NoopPrefs.setPostWorkoutReportEnabled(appContext, true)
            onComplete(true)
        }
    }

    // MARK: - Workout detail reads (#410) — suspend helpers, additive

    /** Downsampled HR (mean bpm per bucket) over ONE workout's [from, to] window for the detail
     *  HR-curve. A short session wants a finer bucket than the Today 24h chart (300 s would flatten a
     *  30-min run to ~6 points), so the bucket scales with duration: ~120 buckets across the window,
     *  floored at 15 s and capped at 300 s. Mirrors macOS Repository.workoutHrBuckets. */
    suspend fun workoutHrBuckets(from: Long, to: Long): List<com.noop.data.HrBucket> {
        if (to <= from) return emptyList()
        val span = to - from
        val bucket = (span / 120).coerceIn(15L, 300L)
        return runCatching { repository.hrBuckets(deviceId, from, to, bucket) }.getOrDefault(emptyList())
    }

    /** Per-zone MINUTES for a workout window, binning the strap's raw HR samples into the age-derived
     *  (Tanaka) %HRmax zones — the same display zone model the Workouts screen uses for imported zone
     *  percentages, but from the strap's own samples so a session WITHOUT imported zones still gets a
     *  real time-in-zone split. null when the window carries no HR. age <= 0 falls back to 30 y.
     *  Mirrors macOS Repository.workoutZoneMinutes. */
    suspend fun workoutZoneMinutes(from: Long, to: Long): List<Double>? {
        if (to <= from) return null
        val samples = runCatching { repository.hrSamples(deviceId, from, to) }.getOrDefault(emptyList())
        if (samples.isEmpty()) return null
        val age = profileStore.age.toDouble().takeIf { it > 0 } ?: 30.0
        val zoneSet = com.noop.analytics.HrZones.zones(age = age)
        val tiz = com.noop.analytics.HrZones.timeInZone(samples, zoneSet)
        val minutes = tiz.seconds.map { it / 60.0 }
        return if (minutes.any { it > 0.0 }) minutes else null
    }

    /** HRR for one workout (#516), derived from a narrow workout-end + post-workout HR read. The pure
     *  engine owns the intensity and coverage gates, so a disconnect after exercise returns null rather
     *  than an interpolated value. Mirrors macOS Repository.workoutHeartRateRecovery. */
    suspend fun workoutHeartRateRecovery(from: Long, to: Long): com.noop.analytics.HeartRateRecovery.Result? {
        if (to <= from) return null
        val readFrom = maxOf(from, to - com.noop.analytics.HeartRateRecovery.eligibilityLookbackSeconds)
        val readTo = to + 5 * 60 + com.noop.analytics.HeartRateRecovery.measurementToleranceSeconds
        val samples = try {
            repository.hrSamplesUnion(activeStrapId, readFrom, readTo, limit = 2_000)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            emptyList()
        }
        return com.noop.analytics.HeartRateRecovery.calculate(
            samples = samples,
            workoutStart = from,
            workoutEnd = to,
            maxHr = profileStore.hrMax.toDouble(),
        )
    }

    /** Steps over a manual-workout window `[from, to]` from the strap's own `step_motion_counter@57`
     *  (#398): the shared wrap-aware `StepsCounter` delta-sum, then the per-user `stepTicksPerStep`
     *  calibration the daily total applies (#139, floor 0.5). null when no strap counter covers the window
     *  — a WHOOP 4.0 (no @57 counter) or an MG/5.0 that hasn't offloaded the window yet. Mirrors Swift
     *  `Repository.strapStepTicks` + the WorkoutDetailView scaling; the phone-pedometer fallback iOS adds is
     *  not available on Android (no cheap windowed step source), so a 4.0 window simply shows no steps. */
    suspend fun workoutSteps(from: Long, to: Long): Int? {
        if (to <= from) return null
        val samples = runCatching { repository.stepSamples(deviceId, from, to) }.getOrDefault(emptyList())
        val ticks = com.noop.analytics.StepsCounter.stepsInWindow(samples) ?: return null
        val scaled = (ticks.toDouble() / maxOf(profileStore.stepTicksPerStep, 0.5)).roundToInt()
        return if (scaled > 0) scaled else null
    }

    /** Save a retroactive / edited manual workout, then reload. [replacing] is the original on edit. */
    fun saveManualWorkout(
        row: WorkoutRow,
        replacing: WorkoutRow? = null,
        onResult: (Boolean) -> Unit = {},
    ) {
        viewModelScope.launch {
            val saved = runCatching { repository.saveManualWorkout(row, replacing) }.isSuccess
            if (!saved) {
                onResult(false)
                return@launch
            }
            if (replacing != null && WorkoutEditing.classify(replacing.source) == WorkoutSource.DETECTED) {
                AutoWorkoutPrefs.dismiss(appContext, replacing)
                AutoWorkoutPrefs.clearReview(appContext, replacing.startTs)
            }
            // #598: rescore the just-added workout from the strap's HR for its window NOW, so its average /
            // peak HR, strain and calories appear immediately instead of waiting for the next analyze tick.
            // No-ops when there's no strap HR for the window; never overrides a value the user typed.
            rescoreAfterEdit()
            loadWorkouts()
            onResult(true)
        }
    }

    /** Re-label a detected bout to [sport] (becomes a durable manual session), then reload. */
    fun relabelDetected(row: WorkoutRow, sport: String) {
        viewModelScope.launch {
            runCatching { repository.relabelDetected(row, sport) }
                .onSuccess { AutoWorkoutPrefs.clearReview(getApplication(), row.startTs) }
            loadWorkouts()
        }
    }

    /** Dismiss a detected bout ("not a workout") durably, then reload. */
    fun dismissDetected(row: WorkoutRow) {
        viewModelScope.launch {
            runCatching { repository.dismissDetected(row) }
                .onSuccess {
                    AutoWorkoutPrefs.dismiss(getApplication(), row)
                    AutoWorkoutPrefs.clearReview(getApplication(), row.startTs)
                }
            loadWorkouts()
        }
    }

    /** Delete one workout (manual delete, or durable dismiss for a detected bout), then reload. */
    fun deleteWorkout(row: WorkoutRow) {
        viewModelScope.launch {
            runCatching { repository.deleteWorkout(row) }
                .onSuccess {
                    if (WorkoutEditing.classify(row.source) == WorkoutSource.DETECTED) {
                        AutoWorkoutPrefs.dismiss(getApplication(), row)
                        AutoWorkoutPrefs.clearReview(getApplication(), row.startTs)
                    }
                }
            loadWorkouts()
        }
    }

    /**
     * #64: merge the selected MANUAL / DETECTED sessions into one manual session, then reload. [sport] is
     * passed only when every selected row is a bare detected bout and the user picked a label. No-op when
     * the selection can't merge (fewer than two, or any imported row) — imported history is never touched.
     */
    fun mergeWorkouts(rows: List<WorkoutRow>, sport: String? = null) {
        if (!WorkoutMerge.canMerge(rows)) return
        val merged = WorkoutMerge.merge(rows, sport = sport, strapDeviceId = deviceId) ?: return
        viewModelScope.launch {
            runCatching { repository.mergeWorkouts(rows, merged) }
                .onSuccess {
                    rows.filter { WorkoutEditing.classify(it.source) == WorkoutSource.DETECTED }
                        .forEach {
                            AutoWorkoutPrefs.dismiss(appContext, it)
                            AutoWorkoutPrefs.clearReview(appContext, it.startTs)
                        }
                }
            // #598: rescore the merged row's strain from the strap's HR over its window now, so its Effort
            // appears immediately instead of waiting for the next analyze tick.
            rescoreAfterEdit()
            loadWorkouts()
        }
    }

    /** #64: bulk-delete the selected sessions (per-class routing), then reload. Imported rows are never
     *  selectable, so a stray one is skipped by the repository. */
    fun bulkDeleteWorkouts(rows: List<WorkoutRow>) {
        viewModelScope.launch {
            runCatching { repository.bulkDeleteWorkouts(rows) }
                .onSuccess {
                    rows.filter { WorkoutEditing.classify(it.source) == WorkoutSource.DETECTED }
                        .forEach {
                            AutoWorkoutPrefs.dismiss(appContext, it)
                            AutoWorkoutPrefs.clearReview(appContext, it.startTs)
                        }
                }
            loadWorkouts()
        }
    }

    /**
     * Drop the smoothing window and blank the hero number so a resume / re-attach shows "-" until a
     * genuinely fresh sample arrives, instead of republishing the stale pre-gap median. Called on
     * explicit foreground Live/workout/reading/session arm (requestRealtimeHr 0->1), NOT on keep-alive re-arm, so steady-state
     * smoothing is untouched. Mirrors AppModel.resetSmoothing and the existing disconnect() clear.
     * Fixes #46 (HR jumped to a stale ~100 on reopen, then settled as fresh low samples refilled).
     */
    private fun resetSmoothing() {
        hrWindow.clear()
        _bpm.value = null
    }

    // MARK: - Strap controls (thin pass-throughs to the BLE client)

    fun connect(promoteService: Boolean = true) {
        // An explicit user-driven Connect must start the reconnect schedule fresh — never inherit a
        // backoff delay accumulated by a prior involuntary-reconnect loop (#48, iOS connect() parity).
        ble.resetReconnectBackoff()
        // A fresh user Connect also clears any lingering pairing-mode guidance + its refusal streak (#78),
        // so a hint from a previous attempt doesn't carry into the retry the user just kicked off. (Auto
        // reconnects deliberately don't, so the streak can accumulate to the threshold across drops.)
        ble.clearPairingHintForUserConnect()
        ble.connect(_selectedModel.value)
        // Keep the link alive when the app is closed, unless the user has opted out. Started from the
        // foreground (this is a user tap), so Android 12+'s background-start rule is satisfied.
        // Onboarding auto-connects before the user has finished setup and passes promoteService=false
        // so the persistent notification doesn't appear mid-flow; it promotes once on completion.
        if (promoteService && NoopPrefs.backgroundConnection(appContext)) {
            WhoopConnectionService.start(appContext)
        }
    }

    /** Promote the background service now if a strap is live and the user hasn't opted out — used by
     *  onboarding to defer the foreground notification until the flow completes. */
    fun promoteBackgroundConnectionIfActive() {
        if (!NoopPrefs.backgroundConnection(appContext)) return
        if (ble.state.value.connected || ble.state.value.bonded) {
            WhoopConnectionService.start(appContext)
        }
    }

    fun disconnect() {
        // User asked to disconnect: drop the foreground promotion first, then the link itself.
        WhoopConnectionService.stop(appContext)
        ble.disconnect()
        hrWindow.clear()
        _bpm.value = null
    }

    /** Restart the connected strap (user-initiated, confirmation-gated in DevicesScreen). Non-destructive —
     *  the strap keeps its data and re-advertises after boot; NOOP auto-reconnects. See WhoopBleClient.rebootStrap. */
    fun rebootStrap() = ble.rebootStrap()

    /** Send one WHOOP 4.0 reboot-probe candidate (Test Centre → Connection, 4.0 only). Confirmation-gated
     *  in DevicesScreen; finds the real 4.0 reboot frame when the production one is ignored (#235). */
    fun rebootProbe(variant: com.noop.protocol.RebootProbeVariant) = ble.rebootProbe(variant)

    /** #592 opcode probe: read-only GET_EXTENDED_BATTERY_INFO(98) with a full raw-response dump to the
     *  strap log. Confirmation-gated in DevicesScreen (Test Centre → Connection); settles the disputed
     *  battery-info opcode (98 vs an APK decompile's 87) from a normal strap-log export. */
    fun probeExtendedBatteryInfo() = ble.probeExtendedBatteryInfo()

    /** #592 probe result text (null until a reply lands; " waiting" sentinel while in flight). */
    val extendedBatteryProbe = ble.extendedBatteryProbe

    fun clearExtendedBatteryProbe() = ble.clearExtendedBatteryProbe()

    /** #690: read-only body-location/status probe (0x54). User-initiated, Test-Centre-gated in
     *  DevicesScreen; decodes revision/location/confidence/status to a diagnostic report + strap log.
     *  Never changes wear detection, sleep gating, or scoring. */
    fun probeBodyLocationAndStatus() = ble.probeBodyLocationAndStatus()

    /** #690 probe result text (null until a reply lands; waiting sentinel while in flight). */
    val bodyLocationProbe = ble.bodyLocationProbe

    fun clearBodyLocationProbe() = ble.clearBodyLocationProbe()

    /**
     * Flip the "keep connected in the background" preference (driven by Settings). Turning it on
     * while a strap is live promotes to the foreground immediately; turning it off drops the
     * foreground service (the connection stays up until the app is actually closed).
     */
    fun setBackgroundConnection(enabled: Boolean) {
        NoopPrefs.setBackgroundConnection(appContext, enabled)
        if (enabled) {
            if (ble.state.value.connected || ble.state.value.bonded) {
                WhoopConnectionService.start(appContext)
            }
        } else {
            WhoopConnectionService.stop(appContext)
        }
        // Continuous HRV capture is gated on background connection (it has nothing to stream over without
        // it), so a change here re-reconciles the keep-stream want: turning background off disarms the
        // continuous stream when no Live screen wants it; turning it back on re-arms it if the pref is on.
        ble.setKeepStreamForData(continuousHrvEffective())
    }

    /**
     * Flip "Continuous HRV capture" (driven by Settings → Strap). Persists the preference and pushes the
     * effective want to the BLE client so it takes effect immediately: turning it on while bonded +
     * backgrounded arms the dense realtime stream now; turning it off disarms it unless a Live screen
     * still wants it (the reconciler only sends the toggle on the false↔true edge). Gated on background
     * connection — it does nothing while that's off (there'd be no background link to stream over).
     */
    fun setContinuousHrv(enabled: Boolean) {
        NoopPrefs.setContinuousHrv(appContext, enabled)
        ble.setKeepStreamForData(continuousHrvEffective())
    }

    /**
     * Flip "Overnight only" for Continuous HRV capture (#927, driven by Settings → Strap). Persists the
     * preference and re-pushes the UNCHANGED keep-stream want, purely so the BLE reconciler re-derives
     * the window gate immediately: flipping it on outside the window disarms the stream now, flipping it
     * off re-arms it. The BLE client re-reads this preference at every arm site, so no stale value can
     * keep the stream armed outside the window between reconciles.
     */
    fun setContinuousHrvOvernight(enabled: Boolean) {
        NoopPrefs.setContinuousHrvOvernight(appContext, enabled)
        ble.setKeepStreamForData(continuousHrvEffective())
    }

    /**
     * Flip "Debug logging" (driven by Settings → Strap). Persists the preference and pushes it to the
     * live BLE client so it takes effect immediately. Default OFF: the strap log stays in the in-app
     * ring buffer (and the "Share strap log" export) but is not mirrored to logcat unless the user opts
     * in — so a normal user never writes the connection log to the system log. With it on, developers
     * can watch the connection live over `adb logcat -s WhoopBleClient`.
     */
    fun setDebugLogging(enabled: Boolean) {
        NoopPrefs.setDebugLogging(appContext, enabled)
        ble.debugLogcat = enabled
    }

    // --- Broadcast heart rate (NOOP acts as a standard BLE HR peripheral; gym kit reads the strap HR) ---
    //
    // OPT-IN, OFF BY DEFAULT, OFFLINE. When on, [HrBroadcaster] advertises the standard Heart Rate Service
    // (0x180D) and notifies 0x2A37 with each live strap HR, so a treadmill / Zwift / Peloton can read the
    // WHOOP HR NOOP receives. LOCAL Bluetooth only — nothing leaves the device. The broadcaster is a pure
    // CONSUMER of [ble.state].heartRate (fed in the state-collect loop in init); it never writes back into
    // the WHOOP path, so the strap connection and scoring can't regress.
    private val broadcaster = HrBroadcaster(appContext, log = { ble.externalLog(it) })

    private val _hrBroadcast = MutableStateFlow(NoopPrefs.hrBroadcast(appContext))
    /** Whether the "Broadcast heart rate" toggle is on. Default OFF. */
    val hrBroadcast: StateFlow<Boolean> = _hrBroadcast.asStateFlow()
    /** True while NOOP is actually advertising as an HR peripheral (radio on + permission granted). */
    val hrBroadcastAdvertising: StateFlow<Boolean> = broadcaster.advertising
    /** How many centrals (gym kit / apps) are subscribed to the broadcast right now. */
    val hrBroadcastSubscribers: StateFlow<Int> = broadcaster.subscriberCount
    /** A human-readable reason the broadcast can't run (Bluetooth off / no permission), or null. */
    val hrBroadcastStatus: StateFlow<String?> = broadcaster.statusNote

    init {
        // Re-broadcast the live strap HR whenever it changes, but only while the toggle is on. Kept as its
        // own collector so it's a clean pure-consumer of LiveState; [HrBroadcaster.update] itself no-ops
        // when broadcasting isn't wanted, so this is harmless when the toggle is off.
        viewModelScope.launch {
            ble.state.collect { state -> broadcaster.update(state.heartRate) }
        }
        // Resume broadcasting on launch if the user had it on (and the OS permission survives). If the
        // permission was revoked, [HrBroadcaster.start] degrades to a status note rather than crashing.
        if (_hrBroadcast.value) broadcaster.start()
    }

    /**
     * Flip "Broadcast heart rate" (driven by Data Sources). Persists the preference and starts/stops the
     * HR peripheral immediately. The Compose layer requests BLUETOOTH_ADVERTISE + BLUETOOTH_CONNECT before
     * calling this with `enabled = true` (Android 12+); if those aren't held, [HrBroadcaster.start]
     * surfaces a status note instead of broadcasting. Default OFF.
     */
    fun setHrBroadcast(enabled: Boolean) {
        _hrBroadcast.value = enabled
        NoopPrefs.setHrBroadcast(appContext, enabled)
        if (enabled) broadcaster.start() else broadcaster.stop()
    }

    // --- Health Connect periodic auto-sync (Samsung Health → Health Connect → NOOP) ---
    private val _hcAutoSync = MutableStateFlow(NoopPrefs.hcAutoSync(appContext))
    val hcAutoSync: StateFlow<Boolean> = _hcAutoSync.asStateFlow()
    private val _hcSyncHours = MutableStateFlow(NoopPrefs.hcSyncHours(appContext))
    val hcSyncHours: StateFlow<Int> = _hcSyncHours.asStateFlow()
    private val _hcLastSync = MutableStateFlow(NoopPrefs.hcLastSync(appContext))
    val hcLastSync: StateFlow<Long> = _hcLastSync.asStateFlow()
    private val _hcWriteback = MutableStateFlow(NoopPrefs.hcWriteback(appContext))
    val hcWriteback: StateFlow<Boolean> = _hcWriteback.asStateFlow()

    // Last writeback outcome (#660). Read from prefs (the writer persists it — including on the
    // background BLE path, which never touches this VM), so Data Sources shows a failing share
    // instead of a healthy-looking toggle. [refreshHcWritebackStatus] re-reads after each attempt.
    private val _hcWritebackStatus = MutableStateFlow(readHcWritebackStatus())
    val hcWritebackStatus: StateFlow<HcWritebackStatus> = _hcWritebackStatus.asStateFlow()
    private fun readHcWritebackStatus() = HcWritebackStatus(
        code = NoopPrefs.hcWritebackStatus(appContext),
        atMs = NoopPrefs.hcWritebackAt(appContext),
        written = NoopPrefs.hcWritebackWritten(appContext),
    )
    /** Re-read the persisted writeback outcome (a background BLE-path write updates prefs, not this VM). */
    fun refreshHcWritebackStatus() { _hcWritebackStatus.value = readHcWritebackStatus() }

    init {
        runCatching {
            WindDownScheduler.reconcilePersisted(appContext, windDownStore)
        }.onFailure {
            WindDownScheduler.cancel(appContext)
        }
        _windDownEnabled.value = windDownStore.enabled

        // Correct the local Health Connect-derived BMI projection even when auto-sync or provider
        // permissions are off. Then catch up provider data if auto-sync is enabled and overdue.
        reconcileHealthConnectBmiProjection()
        syncHealthConnectIfStale()

        // Rebuild either a recording manual workout or an ended save-retry snapshot. Placed in THIS init —
        // not the first one above — because it reads _activeWorkout, which is declared below that first init
        // block and would still be null there (JVM field-init order).
        rehydrateActiveWorkout()
    }

    /** Flip auto-sync. Enabling kicks an immediate import, retains foreground catch-up everywhere,
     *  and reconciles the eligible-platform best-effort background worker. */
    fun setHcAutoSync(enabled: Boolean) {
        _hcAutoSync.value = enabled
        NoopPrefs.setHcAutoSync(appContext, enabled)
        runCatching { HealthConnectSyncScheduler.reconcile(appContext) }
        if (enabled) syncHealthConnectIfStale(force = true)
    }

    /** Change the sync interval (hours) for foreground catch-up and any eligible periodic worker. */
    fun setHcSyncHours(hours: Int) {
        _hcSyncHours.value = hours
        NoopPrefs.setHcSyncHours(appContext, hours)
        runCatching { HealthConnectSyncScheduler.reconcile(appContext) }
    }

    /** Flip Health Connect writeback (computed metrics → HC). Persists; the UI requests the write
     *  permissions and kicks the first write via [writebackHealthConnectNow]. While on, every 15-min
     *  recompute re-writes (idempotent — clientRecordId upserts). Default OFF. */
    fun setHcWriteback(enabled: Boolean) {
        _hcWriteback.value = enabled
        NoopPrefs.setHcWriteback(appContext, enabled)
    }

    /** One immediate writeback (permissions assumed granted — the UI gates on that). */
    fun writebackHealthConnectNow() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { HealthConnectWriter.write(appContext, repository, deviceId) }
            }
            refreshHcWritebackStatus()   // #660: surface the just-recorded outcome in Data Sources
        }
    }

    /**
     * Foreground catch-up import: when auto-sync is on and the last sync is older than the chosen
     * interval (or [force]), pull from Health Connect now. Opening the app remains the dependable sync
     * point because background work is permission-gated and OS-scheduled. No-ops silently if Health
     * Connect is unavailable or its read permissions aren't granted (the UI requests them on enable).
     */
    fun syncHealthConnectIfStale(force: Boolean = false) {
        if (!_hcAutoSync.value) return
        val intervalMs = _hcSyncHours.value.toLong() * 60 * 60 * 1000
        val last = _hcLastSync.value
        val now = System.currentTimeMillis()
        if (!force && last != 0L && now - last < intervalMs) return
        viewModelScope.launch {
            val ran = withContext(Dispatchers.IO) {
                if (HealthConnectImporter.sdkStatus(appContext) != HealthConnectClient.SDK_AVAILABLE) {
                    return@withContext false
                }
                val granted = try {
                    HealthConnectImporter.client(appContext).permissionController.getGrantedPermissions()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    HealthConnectReconciler.reconcileLocalBmiProjection(
                        repository = repository,
                        currentHeightCm = { profileStore.bodyCompositionImportHeightCm },
                    )
                    return@withContext false
                }
                // Empty/partial permissions still run the local BMI dependency correction. The engine
                // accesses only record types represented by granted permissions.
                // A token advances only after its bounded Health Connect-owned projection is rebuilt.
                // Provider failures keep the old token, so the next foreground/worker run replays it.
                val outcome = try {
                    HealthConnectReconciler.reconcile(
                        context = appContext,
                        repository = repository,
                        grantedPermissions = granted,
                        currentHeightCm = { profileStore.bodyCompositionImportHeightCm },
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    null
                }
                outcome is HealthConnectReconcileResult.Success
            }
            if (ran) {
                val t = System.currentTimeMillis()
                NoopPrefs.setHcLastSync(appContext, t)
                _hcLastSync.value = t
            }
        }
    }

    private fun reconcileHealthConnectBmiProjection() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                HealthConnectReconciler.reconcileLocalBmiProjection(
                    repository = repository,
                    currentHeightCm = { profileStore.bodyCompositionImportHeightCm },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // A later profile revision, foreground sync, or worker run retries the local correction.
            }
        }
    }

    /** A screen that shows live HR appeared. Arms the realtime stream on the 0→1 transition, and
     *  blanks the stale smoothing window so a resume shows "-" until a fresh sample lands (#46).
     *  Guarded on 0→1 so a second concurrent HR screen doesn't re-clear an already-live window. */
    fun requestRealtimeHr() {
        val transition = realtimeLeasePolicy.requestLease()
        recordRealtimeLease("request", transition)
        if (transition == ForegroundRealtimeLeasePolicy.Transition.ARM) {
            resetSmoothing()
            ble.startRealtime()
        }
    }

    /** A live-HR screen went away. Stops the realtime stream only when the last one leaves. */
    fun releaseRealtimeHr() {
        val transition = realtimeLeasePolicy.releaseLease()
        recordRealtimeLease("release", transition)
        if (transition == ForegroundRealtimeLeasePolicy.Transition.DISARM) {
            ble.stopRealtime()
        }
    }

    /** Gate high-rate UI/session leases on Activity foreground. This does not disconnect BLE, stop
     *  history sync, or change Continuous HRV capture. A still-held explicit lease re-arms once when the
     *  Activity resumes; stale smoothing is cleared before that resumed stream is shown. */
    fun setRealtimeForeground(foreground: Boolean) {
        val transition = realtimeLeasePolicy.setForeground(foreground)
        recordRealtimeLease(if (foreground) "foreground" else "background", transition)
        when (transition) {
            ForegroundRealtimeLeasePolicy.Transition.ARM -> {
                resetSmoothing()
                ble.startRealtime()
            }
            ForegroundRealtimeLeasePolicy.Transition.DISARM -> ble.stopRealtime()
            ForegroundRealtimeLeasePolicy.Transition.NONE -> Unit
        }
    }

    private fun recordRealtimeLease(
        action: String,
        transition: ForegroundRealtimeLeasePolicy.Transition,
    ) {
        com.noop.AppDiagnosticsRecorder.record(
            "realtime_hr.lease",
            fields = mapOf(
                "action" to action,
                "transition" to transition.name.lowercase(),
                "lease_count_bucket" to when (realtimeLeasePolicy.leaseCount) {
                    0 -> "zero"
                    1 -> "one"
                    else -> "multiple"
                },
                "foreground" to realtimeLeasePolicy.isForeground.toString(),
                "transport_armed" to realtimeLeasePolicy.transportArmed.toString(),
            ),
        )
    }

    /** Refresh the battery reading. Reads the standard 0x2A19 characteristic (works on 5/MG, where the
     *  proprietary command is dropped) and also fires the legacy command on WHOOP 4. */
    fun getBattery() = ble.refreshBattery()

    /**
     * User-initiated "Sync now": kick a historical offload on demand (#93). A thin pass-through to the
     * BLE client's gated [WhoopBleClient.syncNow], which forwards to the same connected+bonded+
     * not-already-backfilling guard the auto-kick and 900s periodic timer use — so it's a safe no-op
     * when the strap isn't ready or a session is already running. Progress is unknowable from the
     * protocol, so the UI shows an indeterminate indicator + live.syncChunksThisSession, never a percent. */
    fun syncNow() = ble.syncNow()

    /** Force an immediate Fitness Age recompute from stored history , the not-ready card's refresh button.
     *  Light (no raw-HR rescoring), so it returns fast and works even when the strap is offline. Applies the
     *  SAME gate as the recompute pass (IntelligenceEngine.fitnessAgeRows). Calls back on the main thread
     *  with whether a value landed, so the card can re-read + confirm. */
    fun refreshFitnessAgeNow(onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            val wrote = runCatching {
                IntelligenceEngine.recomputeFitnessAgeOnly(
                    repo = repository,
                    profile = currentProfile(),
                    profileProvider = ::currentProfile,
                    importedDeviceId = deviceId,
                )
            }.onFailure {
                if (it is CancellationException) throw it
            }.getOrDefault(false)
            noteAgeMetricsChanged()
            onResult(wrote)
        }
    }

    private fun scheduleAgeMetricRecompute() {
        ageMetricReconciliationRunner.schedule()
    }

    /** Catch a naturally advanced age when the app resumes across a birthday. Profile edits still arrive
     *  through [ProfileStore.ageMetricProfileChanges], so this comparison adds no polling or duplicate work. */
    private fun refreshAgeMetricsIfProfileChanged() {
        val currentTarget = AgeMetricReconciliationTarget(
            profileState = profileStore.ageMetricStateToken,
            deviceId = deviceId,
        )
        if (currentTarget == lastAgeMetricReconciliationTarget) return
        scheduleAgeMetricRecompute()
    }

    private fun invalidateTodayAgeMetricCaches() {
        todayCardsLoadedSig = null
        todayCardsLoadedProfileSig = null
        todayCardsLoadedAgeMetricVersion = null
        todayFitnessAgeCache = null
        todayVitalityCache = null
    }

    private fun noteAgeMetricsChanged() {
        invalidateTodayAgeMetricCaches()
        repository.noteAgeMetricsChanged()
    }

    private fun noteAllMetricsChanged() {
        invalidateTodayAgeMetricCaches()
        repository.noteMetricsChanged()
    }

    // --- Smart alarm (persisted; arms the strap's firmware alarm). Port of macOS BehaviorStore +
    // AppModel.applySmartAlarm. The previous Android UI was a non-persisted mock-up (issue #51).
    // NOTE: the _smartAlarm* state fields are declared ABOVE the init block (next to _illnessWatchEnabled)
    // so the init bond-collector can't read them before they're initialized (#84). ---

    fun setSmartAlarmEnabled(enabled: Boolean) {
        _smartAlarmEnabled.value = enabled
        NoopPrefs.setSmartAlarmEnabled(appContext, enabled)
        reconcileStrapAlarm()
    }

    fun setSmartAlarmMinutes(minutes: Int) {
        _smartAlarmMinutes.value = minutes.coerceIn(0, 24 * 60 - 1)
        NoopPrefs.setSmartAlarmMinutes(appContext, _smartAlarmMinutes.value)
        reconcileStrapAlarm()
    }

    /** Set which weekdays the strap alarm fires on (Calendar.DAY_OF_WEEK 1=Sun…7=Sat; empty = every
     *  day). Re-arms so the change takes effect immediately. Mirrors macOS (#539). */
    fun setSmartAlarmWeekdays(days: Set<Int>) {
        val clean = days.filter { it in 1..7 }.toSet()
        _smartAlarmWeekdays.value = clean
        NoopPrefs.setSmartAlarmWeekdays(appContext, clean)
        reconcileStrapAlarm()
    }

    /** Set a per-weekday wake-time override (#554 reimpl). [minutes] = null clears the override for [dow]
     *  (that day falls back to the default time). Persists + re-arms immediately so the next occurrence
     *  uses the new time. */
    fun setSmartAlarmDayOverride(dow: Int, minutes: Int?) {
        if (dow !in 1..7) return
        val next = _smartAlarmDayOverrides.value.toMutableMap()
        if (minutes == null) next.remove(dow) else next[dow] = minutes.coerceIn(0, 24 * 60 - 1)
        _smartAlarmDayOverrides.value = next
        NoopPrefs.setSmartAlarmDayOverrides(appContext, next)
        reconcileStrapAlarm()
    }

    // --- PHONE smart alarm (#207). The setters persist + (re)arm the GUARANTEED OS alarm via
    // [SmartAlarmScheduler]: scheduling the hard deadline FIRST, before any smart logic exists, so the
    // fallback is in place the instant the alarm is enabled. Whether the strap is connected is
    // irrelevant — that's the whole point. The exact-alarm permission is requested by the UI before
    // these are called on a fresh enable; if it's somehow missing, arm() returns null and the UI shows
    // the permission prompt. ---

    /** Enable/disable the phone smart alarm. Enabling arms the guaranteed hard-deadline alarm now;
     *  disabling cancels it. Returns false if exact alarms aren't permitted (the UI then routes the
     *  user to grant the permission and re-tries). */
    fun setPhoneAlarmEnabled(enabled: Boolean): Boolean {
        if (enabled && !SmartAlarmScheduler.canScheduleExact(appContext)) return false
        phoneAlarmStore.enabled = enabled
        _phoneAlarmEnabled.value = enabled
        if (enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
        else SmartAlarmScheduler.cancel(appContext, phoneAlarmStore)
        return true
    }

    /** Change the earliest wake time (minutes since midnight). Re-arms while enabled so the new
     *  window takes effect immediately. */
    fun setPhoneAlarmTargetMinutes(minutes: Int) {
        phoneAlarmStore.targetMinutes = minutes
        _phoneAlarmTargetMinutes.value = phoneAlarmStore.targetMinutes
        if (phoneAlarmStore.enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
        // #536: re-arm the strap at the new earliest time when "Buzz WHOOP 4" is on. Routed through the
        // single reconciler so it can't clobber a smart-alarm the user still has on (#5).
        reconcileStrapAlarm()
    }

    /** Toggle the "Buzz WHOOP 4/5" companion (#536). Routes through the single strap-alarm reconciler so
     *  enabling/disabling it never clobbers a smart wake-alarm sharing the one firmware slot (#5): on the
     *  reconcile re-evaluates BOTH flags and arms the earliest, off it re-evaluates and keeps the slot for
     *  the smart alarm if that's still on. */
    fun setBuzzWhoop4Enabled(enabled: Boolean) {
        _buzzWhoop4Enabled.value = enabled
        NoopPrefs.setBuzzWhoop4WithAlarm(appContext, enabled)
        reconcileStrapAlarm()
    }

    /** Change the window length (minutes after the target the hard deadline sits). Re-arms while
     *  enabled. */
    fun setPhoneAlarmWindowMinutes(minutes: Int) {
        phoneAlarmStore.windowMinutes = minutes
        _phoneAlarmWindowMinutes.value = phoneAlarmStore.windowMinutes
        if (phoneAlarmStore.enabled) SmartAlarmScheduler.arm(appContext, phoneAlarmStore)
    }

    /** Whether the OS will honour an exact alarm right now (API 31+ gates it behind a permission). */
    fun canScheduleExactAlarms(): Boolean = SmartAlarmScheduler.canScheduleExact(appContext)

    /** Enable/disable the evening wind-down nudge. Enabling is committed only when Android can
     *  actually deliver this notification; a revoked app/channel permission leaves the control off. */
    fun setWindDownEnabled(enabled: Boolean): Boolean {
        if (!enabled) {
            windDownStore.enabled = false
            _windDownEnabled.value = false
            WindDownScheduler.cancel(appContext)
            return true
        }
        if (!WindDownScheduler.notificationsAvailable(appContext)) {
            windDownStore.enabled = false
            _windDownEnabled.value = false
            WindDownScheduler.cancel(appContext)
            return false
        }
        val result = WindDownScheduler.commitEnableAfterAcceptance(
            store = windDownStore,
            schedule = { WindDownScheduler.schedule(appContext, windDownStore) },
            cancel = { WindDownScheduler.cancel(appContext) },
        )
        return when (result) {
            is WindDownScheduler.ScheduleResult.Scheduled -> {
                _windDownEnabled.value = true
                true
            }
            is WindDownScheduler.ScheduleResult.Failed -> {
                _windDownEnabled.value = false
                false
            }
        }
    }

    private fun rescheduleWindDownIfEnabled() {
        if (!windDownStore.enabled) return
        runCatching {
            WindDownScheduler.reconcilePersisted(appContext, windDownStore)
        }.onFailure {
            WindDownScheduler.cancel(appContext)
        }
        _windDownEnabled.value = windDownStore.enabled
    }

    fun windDownNotificationsAvailable(): Boolean =
        WindDownScheduler.notificationsAvailable(appContext)

    fun windDownNotificationSettingsIntent(): Intent =
        WindDownScheduler.notificationSettingsIntent(appContext)

    fun setWindDownSleepNeedMinutes(minutes: Int) {
        val prior = windDownStore.sleepNeedMinutes
        val wasExplicit = windDownStore.hasExplicitSleepNeed
        windDownStore.sleepNeedMinutes = minutes
        _windDownSleepNeedMinutes.value = windDownStore.sleepNeedMinutes
        rescheduleWindDownIfEnabled()
        if (!wasExplicit || windDownStore.sleepNeedMinutes != prior) {
            onAdaptiveDayInputsChanged()
        }
    }

    fun setWindDownGoalMode(mode: com.noop.analytics.SleepGoalMode) {
        windDownStore.goalMode = mode
        _windDownGoalMode.value = windDownStore.goalMode
    }

    fun setWindDownLeadMinutes(minutes: Int) {
        windDownStore.leadMinutes = minutes
        _windDownLeadMinutes.value = windDownStore.leadMinutes
        rescheduleWindDownIfEnabled()
    }

    fun setWindDownWakeMinutes(minutes: Int) {
        windDownStore.wakeMinutes = minutes
        _windDownWakeMinutes.value = windDownStore.wakeMinutes
        rescheduleWindDownIfEnabled()
    }

    fun setWindDownWakeOverride(weekday: Int, minutes: Int?) {
        windDownStore.setWakeOverride(weekday, minutes)
        _windDownWakeOverrides.value = windDownStore.perDayWakeOverrides
        rescheduleWindDownIfEnabled()
    }

    /** Refresh the persisted planner addition without creating a reschedule loop when unchanged. */
    fun setWindDownRecoveryMinutes(minutes: Int) {
        val next = minutes.coerceIn(0, WindDownStore.RECOVERY_MAX)
        if (next == windDownStore.recoveryMinutes) return
        windDownStore.recoveryMinutes = next
        _windDownRecoveryMinutes.value = windDownStore.recoveryMinutes
        rescheduleWindDownIfEnabled()
    }

    // --- Illness watch (opt-out; the evaluation itself is the pure IllnessWatch.evaluate).
    // State lives next to _healthAlert above (declaration-order constraint); setter here with
    // the other settings mutators. ---
    fun setIllnessWatchEnabled(enabled: Boolean) {
        _illnessWatchEnabled.value = enabled
        NoopPrefs.setIllnessWatch(appContext, enabled)
        // Recompute now — the recentDays collector only fires on data changes.
        viewModelScope.launch { refreshHealthSignalState() }
    }

    fun setContextualVitalReviewEnabled(enabled: Boolean) {
        _contextualVitalReviewEnabled.value = enabled
        NoopPrefs.setContextualVitalReview(appContext, enabled)
        if (enabled) {
            viewModelScope.launch {
                evaluateContextualVitalInterventions(currentIllnessDayKey())
            }
        }
    }

    fun setContextualVo2ReviewEnabled(enabled: Boolean) {
        _contextualVo2ReviewEnabled.value = enabled
        NoopPrefs.setContextualVo2Review(appContext, enabled)
        if (enabled) {
            viewModelScope.launch {
                evaluateContextualVitalInterventions(currentIllnessDayKey())
            }
        }
    }

    fun setAdaptiveDayGuidanceEnabled(enabled: Boolean): Boolean {
        if (!AdaptiveDayNotifier.setGuidanceConsent(appContext, enabled)) {
            _adaptiveDayGuidanceEnabled.value =
                AdaptiveDayConsentGate.guidance(appContext)
            return false
        }
        AdaptiveDayEvaluationGate.invalidate()
        _adaptiveDayGuidanceEnabled.value = enabled
        if (!enabled) {
            plannedWorkoutCalendarEvaluationJob?.cancel()
            AdaptiveDayTimeZoneStore.discardPending(appContext)
            PlannedWorkoutCalendarStore.clear()
            AdaptivePlannedWorkoutScheduler.cancel(appContext)
            reconcilePlannedWorkoutCalendarObserver()
            return true
        }
        onPlannedWorkoutCalendarChanged()
        return true
    }

    fun onPlannedWorkoutCalendarChanged() {
        reconcilePlannedWorkoutCalendarObserver()
        AdaptiveDayEvaluationGate.invalidate()
        PlannedWorkoutCalendarStore.invalidate()
        AdaptivePlannedWorkoutScheduler.cancel(appContext)
        AdaptiveDayNotifier.reconcilePlannedWorkoutArtifacts(
            appContext,
            currentFingerprint = null,
        )
        plannedWorkoutCalendarEvaluationJob?.cancel()
        plannedWorkoutCalendarEvaluationJob = viewModelScope.launch {
            PlannedWorkoutCalendarStore.refresh(
                context = appContext,
                force = true,
            )
            evaluateAdaptiveDayGuidance()
        }
    }

    fun onAdaptiveDayInputsChanged() {
        AdaptiveDayEvaluationGate.invalidate()
        adaptiveDayInputEvaluationJob?.cancel()
        adaptiveDayInputEvaluationJob = viewModelScope.launch {
            evaluateAdaptiveDayGuidance()
        }
    }

    private fun reconcilePlannedWorkoutCalendarObserver() {
        val shouldObserve =
            AdaptiveDayConsentGate.guidance(appContext) &&
                AdaptiveDayConsentGate.plannedWorkoutCalendar(appContext) &&
                ContextCompat.checkSelfPermission(
                    appContext,
                    Manifest.permission.READ_CALENDAR,
                ) == PackageManager.PERMISSION_GRANTED
        when {
            shouldObserve && !plannedWorkoutCalendarObserverRegistered -> {
                runCatching {
                    appContext.contentResolver.registerContentObserver(
                        CalendarContract.Events.CONTENT_URI,
                        true,
                        plannedWorkoutCalendarObserver,
                    )
                }.onSuccess {
                    plannedWorkoutCalendarObserverRegistered = true
                }
            }
            !shouldObserve && plannedWorkoutCalendarObserverRegistered -> {
                unregisterPlannedWorkoutCalendarObserver()
            }
        }
    }

    private fun unregisterPlannedWorkoutCalendarObserver() {
        if (!plannedWorkoutCalendarObserverRegistered) return
        runCatching {
            appContext.contentResolver.unregisterContentObserver(
                plannedWorkoutCalendarObserver,
            )
        }.onSuccess {
            plannedWorkoutCalendarObserverRegistered = false
        }
    }

    /**
     * Rank current sleep, personal timing, and a persisted timezone transition. Missing or stale data
     * fails closed in the pure engine; the notifier independently owns permission, quiet hours, and
     * restart-safe delivery cooldowns.
     */
    private suspend fun evaluateAdaptiveDayGuidance(
        days: List<DailyMetric> = recentDays.value,
        now: ZonedDateTime = ZonedDateTime.now(),
    ) {
        AdaptiveDayEvaluator.evaluateAndNotify(
            context = appContext,
            repository = repository,
            deviceId = deviceId,
            days = days,
            now = now,
            sleepTargetMinutes = windDownStore.sleepNeedMinutes,
            sleepTargetIsExplicit = windDownStore.hasExplicitSleepNeed,
        )
    }

    /**
     * Source-preserving Android parity for Apple's contextual vital reviews. This never feeds the
     * illness score, produces an all-clear, or pages contacts. Every candidate is independently fresh,
     * conflict-aware, opt-in, and passed through a persisted delivery cooldown.
     */
    private suspend fun evaluateContextualVitalInterventions(todayKey: String) {
        val today = runCatching { java.time.LocalDate.parse(todayKey) }.getOrNull() ?: return
        val importedSources = repository.importedSourceIds(deviceId)
        val computedSources = repository.computedSourceIds(deviceId)

        if (_contextualVitalReviewEnabled.value) {
            val from = today.minusDays(7).toString()
            val dailySources = (
                importedSources + computedSources +
                    WhoopRepository.APPLE_HEALTH_SOURCE +
                    WhoopRepository.HEALTH_CONNECT_SOURCE
                ).distinct()
            val oxygen = dailySources.flatMap { source ->
                val priority = when (source) {
                    WhoopRepository.APPLE_HEALTH_SOURCE -> 0
                    WhoopRepository.HEALTH_CONNECT_SOURCE -> 1
                    else -> if (source.endsWith("-noop")) 3 else 2
                }
                repository.daysInRange(source, from, todayKey).mapNotNull { row ->
                    row.spo2Pct?.let {
                        ContextualVitalPolicy.OxygenPoint(row.day, it, priority)
                    }
                }
            }
            ContextualVitalPolicy.oxygenCandidate(oxygen, todayKey)?.let {
                ContextualVitalNotifier.onCandidate(appContext, it)
            }

            val bodyPoints = listOf(
                WhoopRepository.APPLE_HEALTH_SOURCE to 0,
                WhoopRepository.HEALTH_CONNECT_SOURCE to 1,
            ).flatMap { (source, priority) ->
                repository.metricSeries(source, "body_temp", from, todayKey).map { row ->
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        day = row.day,
                        valueC = row.value,
                        source = source,
                        sourcePriority = priority,
                    )
                }
            }
            ContextualVitalPolicy.bodyTemperatureCandidate(bodyPoints, todayKey)?.let {
                ContextualVitalNotifier.onCandidate(appContext, it)
            }
        }

        if (!_contextualVo2ReviewEnabled.value) return
        val from = today.minusDays(400).toString()
        val measuredByDay = LinkedHashMap<String, Double>()
        for (source in importedSources) {
            for (row in repository.metricSeries(source, "vo2max", from, todayKey)) {
                measuredByDay[row.day] = row.value
            }
        }
        // Health Connect wins a wearable collision; an explicit Apple Health VO2 type wins both.
        for (source in listOf(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            WhoopRepository.APPLE_HEALTH_SOURCE,
        )) {
            for (row in repository.metricSeries(source, "vo2max", from, todayKey)) {
                measuredByDay[row.day] = row.value
            }
            for (row in repository.appleDaily(source, from, todayKey)) {
                row.vo2max?.let { measuredByDay[row.day] = it }
            }
        }
        val measured = measuredByDay.map { (day, value) ->
            ContextualVitalPolicy.Vo2Point(day, value)
        }
        val estimated = repository.metricSeriesComputedUnion(
            deviceId,
            "vo2max_est",
            from,
            todayKey,
        ).map { ContextualVitalPolicy.Vo2Point(it.day, it.value) }
        ContextualVitalPolicy.vo2Candidate(measured, estimated, todayKey)?.let {
            ContextualVitalNotifier.onCandidate(appContext, it)
        }
    }

    /** Re-publish the explanatory medication context after the private list changes. This cannot alter
     *  the anomaly score or level; it only refreshes copy on the banner and Health detail card. */
    fun medicationContextChanged() {
        viewModelScope.launch { refreshHealthSignalState() }
    }

    /** Flip cycle awareness (v5 skin-temp suite). Persists and recomputes the v5 signals immediately so
     *  the Health hub's Cycle card flips between its opt-in card and the live result without a data change. */
    fun setCycleTrackingEnabled(enabled: Boolean) {
        if (enabled && !cycleOptInApplies(ProfileStore.from(appContext).sex)) return
        _cycleTrackingEnabled.value = enabled
        NoopPrefs.setCycleTracking(appContext, enabled)
        viewModelScope.launch {
            refreshCycleTracking()
        }
    }

    /** Store a user-confirmed cycle day 1, then immediately republish history + the anchored estimate. */
    suspend fun logPeriodStart(day: String): Boolean {
        val saved = repository.logPeriodStart(day)
        if (saved) refreshCycleTracking()
        return saved
    }

    /** Physically delete one user-confirmed cycle day 1 and immediately recompute the estimate. */
    suspend fun deletePeriodStart(day: String): Boolean {
        val deleted = repository.deletePeriodStart(day)
        if (deleted) refreshCycleTracking()
        return deleted
    }

    /** Physically delete all local period-start history; sensor history and other metrics are untouched. */
    suspend fun deleteAllPeriodStarts(): Boolean {
        val deleted = repository.deleteAllPeriodStarts()
        if (deleted) refreshCycleTracking()
        return deleted
    }

    suspend fun saveCycleDailyLog(
        day: String,
        flow: CycleTrackingStore.Flow?,
        symptoms: Set<CycleTrackingStore.Symptom>,
    ): Boolean {
        val saved = repository.saveCycleDailyLog(day, flow, symptoms)
        if (saved) refreshCycleTracking()
        return saved
    }

    suspend fun deleteCycleDailyLog(day: String): Boolean {
        val deleted = repository.deleteCycleDailyLog(day)
        if (deleted) refreshCycleTracking()
        return deleted
    }

    suspend fun deleteAllCycleDailyLogs(): Boolean {
        val deleted = repository.deleteAllCycleDailyLogs()
        if (deleted) refreshCycleTracking()
        return deleted
    }

    /** Explicitly reevaluate cycle state after a local log mutation or foreground return. `recentDays` may
     *  remain unchanged across midnight when the band was not worn, but cycle day must still advance. */
    private suspend fun refreshCycleTracking() = refreshHealthSignalState()

    /**
     * Publish the illness banner and v5 Health snapshot from one serialized assessment. Foreground,
     * repository-flow, medication, and cycle-log refreshes can overlap; resolving the latest inputs inside
     * the mutex prevents an older suspended refresh from leaving the two surfaces on different assessments.
     * Room failures retain the last cycle history instead of escaping a lifecycle coroutine.
     */
    private suspend fun refreshHealthSignalState() {
        healthSignalRefreshMutex.withLock {
            val days = recentDays.value
            val todayKey = currentIllnessDayKey()
            val context = try {
                illnessJournalContext(days, todayKey)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                illnessContextWithoutJournal(days, todayKey)
            }
            val assessment = IllnessWatch.assess(days, todayKey, context)
            val starts = try {
                repository.periodStarts()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                _periodStarts.value
            }
            val dailyLogs = try {
                repository.cycleDailyLogs()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                _cycleDailyLogs.value
            }
            val previousAlert = _healthAlert.value
            val currentAlert = if (_illnessWatchEnabled.value) {
                IllnessWatch.banner(assessment.result)
            } else {
                null
            }
            val currentSignals = V5HealthSignals.evaluate(
                days = days,
                cycleOptedIn = _cycleTrackingEnabled.value,
                loggedPeriodStarts = starts,
                journalContext = context,
                todayKey = todayKey,
                illnessAssessment = assessment,
            )
            _periodStarts.value = starts
            _cycleDailyLogs.value = dailyLogs
            _healthAlert.value = currentAlert
            _v5Signals.value = currentSignals
            if (previousAlert == null) {
                currentAlert?.let { IllnessAlertNotifier.onEvaluated(appContext, it) }
            }
        }
    }

    /** Current civil day wins over the pre-04:00 logical day for signal freshness and journal context. */
    private fun currentIllnessDayKey(): String =
        maxOf(logicalDayKeyNow(), java.time.LocalDate.now().toString())

    /**
     * Exact current/prior-two-day journal context. These factors explain a shift but never suppress it;
     * an explicit unwell entry remains visible even with no usable wearable rows.
     */
    private suspend fun illnessJournalContext(
        days: List<DailyMetric>,
        todayKey: String,
    ): IllnessSignalEngine.Context {
        val today = runCatching { java.time.LocalDate.parse(todayKey) }.getOrNull()
            ?: return illnessContextWithoutJournal(days, todayKey)
        val from = today.minusDays(IllnessSignalPipeline.MAXIMUM_SIGNAL_AGE_DAYS.toLong()).toString()
        val entries = (
            repository.journal(JOURNAL_DEVICE_ID, from, todayKey) +
                repository.journal(deviceId, from, todayKey)
            ).distinctBy { Triple(it.deviceId, it.day, it.question) }
        val recentDays = (0L..IllnessSignalPipeline.MAXIMUM_SIGNAL_AGE_DAYS.toLong())
            .mapTo(HashSet()) { today.minusDays(it).toString() }
        var alcohol = false
        var stress = false
        var sauna = false
        var hardOrLateWorkout = false
        var travel = false
        var alreadyUnwell = false
        for (entry in entries) {
            if (!entry.answeredYes || entry.day !in recentDays) continue
            val question = entry.question.lowercase()
            if ("alcohol" in question || "drink" in question) alcohol = true
            if ("stress" in question) stress = true
            if ("sauna" in question) sauna = true
            if ("workout" in question || "train" in question || "exercise" in question) {
                hardOrLateWorkout = true
            }
            if ("travel" in question || "jet lag" in question) travel = true
            if (
                "sick" in question || "ill" in question || "unwell" in question ||
                "symptom" in question || "fever" in question
            ) {
                alreadyUnwell = true
            }
        }
        val fallback = illnessContextWithoutJournal(days, todayKey)
        return IllnessSignalEngine.Context(
            alcohol = alcohol,
            stress = stress,
            sauna = sauna,
            hardOrLateWorkout = hardOrLateWorkout || fallback.hardOrLateWorkout,
            travelPhaseJump = travel,
            alreadyUnwell = alreadyUnwell,
            recentMedicationChange = MedicationStore.hasRecentChange(appContext),
        )
    }

    private fun illnessContextWithoutJournal(
        days: List<DailyMetric>,
        todayKey: String,
    ): IllnessSignalEngine.Context {
        val today = runCatching { java.time.LocalDate.parse(todayKey) }.getOrNull()
        val recentDays = today?.let { anchor ->
            (0L..IllnessSignalPipeline.MAXIMUM_SIGNAL_AGE_DAYS.toLong())
                .mapTo(HashSet()) { anchor.minusDays(it).toString() }
        } ?: emptySet()
        val hardOrLate = days.asSequence()
            .filter { it.day in recentDays }
            .any { (it.exerciseCount ?: 0) >= 2 }
        return IllnessSignalEngine.Context(
            hardOrLateWorkout = hardOrLate,
            recentMedicationChange = MedicationStore.hasRecentChange(appContext),
        )
    }

    /** Build today's fused multi-device record for [FusedRecordScreen] (v5 Local Multi-Device Fusion).
     *  Reads each source's banked row for the logical day and runs the pure FusionResolver per metric;
     *  no core-waterfall change. Suspend so the screen calls it from a LaunchedEffect. */
    suspend fun fusedRecordForToday(): FusedRecord =
        // SPINE / #814: the strap + computed reads follow the registry's ACTIVE strap id (the same id the
        // live read path resolves to), not a hardcoded "my-whoop", so a non-WHOOP active band fuses its OWN
        // data. A single-WHOOP install resolves to "my-whoop", so this is byte-identical there.
        FusionDayAdapter.buildFor(repository, logicalDayKeyNow(), activeStrapId = deviceId)

    /** Toggle strap low/full battery notifications (#368). The notifier reads NoopPrefs on each
     *  live-state update, so persisting is all that's needed — no stream to re-arm. */
    fun setBatteryAlertsEnabled(enabled: Boolean) {
        _batteryAlertsEnabled.value = enabled
        NoopPrefs.setBatteryAlerts(appContext, enabled)
    }

    /** Toggle the predictive ~24h-runtime warning on its own; same persist-only mechanics as above. */
    fun setPredictiveBatteryAlertsEnabled(enabled: Boolean) {
        _predictiveBatteryAlertsEnabled.value = enabled
        NoopPrefs.setPredictiveBatteryAlerts(appContext, enabled)
    }

    /** Re-evaluate the strap's single firmware-alarm slot from BOTH features that want it (#5).
     *
     *  The "Strap wake-alarm" (_smartAlarmEnabled) and the "Buzz WHOOP 4/5" companion (_buzzWhoop4Enabled)
     *  both target the ONE firmware slot. Previously each armed/disarmed it independently, so turning one
     *  off disarmed a slot the other still wanted, and whichever ran last won the time. This is now the
     *  SOLE caller of ble.armStrapAlarm / ble.disableStrapAlarm: it computes each feature's requested wake
     *  epoch (null when that feature is off or has no valid firing day) and arms the slot to the EARLIEST
     *  of the two, or disarms when neither wants it.
     *
     *  Needs the strap connected (if it isn't, send() logs "ignored, not connected" and the reconcile
     *  takes effect next time you connect + change a setting; the bond-edge re-arm also calls this). */
    private fun reconcileStrapAlarm() {
        // Smart wake-alarm's requested time (honours weekdays + per-day overrides), or null when off /
        // no valid firing day.
        val smartEpoch = if (_smartAlarmEnabled.value) {
            nextSmartAlarmEpochSec(
                _smartAlarmMinutes.value,
                _smartAlarmWeekdays.value,
                dayOverrides = _smartAlarmDayOverrides.value,
            )
        } else null
        // Buzz-WHOOP-4 companion's requested time: the phone alarm's EARLIEST wake time, next occurrence.
        val buzzEpoch = if (_buzzWhoop4Enabled.value) {
            nextDailyEpochSec(phoneAlarmStore.targetMinutes)
        } else null

        val epochSec = earliestStrapAlarmEpochSec(smartEpoch, buzzEpoch)
        if (epochSec == null) {
            // Neither feature wants the slot (both off, or the smart set is corrupted), so disarm. Mirrors
            // macOS's disarm-rather-than-arm-a-misleading-time stance.
            ble.disableStrapAlarm()
            return
        }
        ble.armStrapAlarm(epochSec)
    }

    /** Fire a haptic buzz on the strap (requires a bonded connection). Scheduled cues only; for a
     *  user-facing "buzz the strap now" action use [buzzStrapOnce] instead (#921). */
    fun buzz(loops: Int = 2) = ble.buzz(loops)

    /** One-shot user buzz (#921): the confirmed pattern + RUN_ALARM sequence, written acknowledged
     *  (RUN_ALARM only where the family gate allows it). Drives the Live-screen Buzz button. */
    fun buzzStrapOnce() = ble.buzzStrapOnce()

    /** Tell the strap to stop an in-progress haptic pattern (#769). Best-effort; no-op when not connected
     *  or on a 5/MG (cmd 122 isn't confirmed on its 0x13 path). Used by the Breathe session teardown. */
    fun stopHaptics() = ble.stopHaptics()

    // --- Double-tap action (parity since 4.2.8). Persisted via NoopPrefs; dispatched from the init
    // LiveState collector on a fresh DOUBLE_TAP event. Port of macOS BehaviorStore.doubleTapAction +
    // AppModel.handleDoubleTap / runMacAction (Apple-applicable subset only). ---

    /** Set the double-tap action (driven by the Automations screen) and persist it. */
    fun setDoubleTapAction(action: DoubleTapAction) {
        _doubleTapAction.value = action
        NoopPrefs.of(appContext).edit().putString(DOUBLE_TAP_ACTION_KEY, action.name).apply()
    }

    /** Run the configured double-tap action NOW (the Automations "Test action" button). Mirrors the iOS
     *  AutomationsView "Test action" calling model.runMacAction directly. */
    fun testDoubleTapAction() = runDoubleTapAction(_doubleTapAction.value)

    /**
     * Dispatch the double-tap action when the strap reports a FRESH double-tap. The BLE client already
     * surfaces the gesture as [LiveState.lastEvent] = "DOUBLE_TAP(14)" (WhoopBleClient onInbound) - it
     * does NOT change the decode; this just consumes the event it already publishes. Debounced on the
     * event identity: [lastEvent] keeps its last value across many LiveState emissions, so without the
     * [lastDispatchedEvent] guard a single tap would fire on every subsequent emission. Mirrors the iOS
     * AppModel.handleDoubleTap (which debounces on a 1.2s window over the same onDoubleTap closure).
     */
    private suspend fun dispatchDoubleTap(state: LiveState) {
        val sequence = state.gestureSequence
        if (sequence == lastDispatchedGestureSequence) return
        lastDispatchedGestureSequence = sequence
        val ev = state.lastEvent
        if (ev == null || !ev.startsWith("DOUBLE_TAP")) return

        when (val result = TapAutomationStore.consumeForGesture(appContext, sequence)) {
            is TapAutomationStore.GestureResult.Consumed -> {
                val line = runCatching {
                    TapAutomationRuntime.perform(appContext, result.action, repository, ble)
                }.getOrElse { "Double-tap automation failed: ${it.javaClass.simpleName}" }
                ble.externalLog(line)
                return
            }
            TapAutomationStore.GestureResult.AlreadyConsumed -> return
            TapAutomationStore.GestureResult.None -> Unit
        }

        when (val safety = SafetySosGestureRuntime.consume(appContext, sequence)) {
            SafetySosGestureRuntime.Result.Ignored -> Unit
            SafetySosGestureRuntime.Result.ReservedDuplicate -> return
            is SafetySosGestureRuntime.Result.Progress -> {
                ble.externalLog(
                    "SOS gesture: repeated double-tap ${safety.count}/${safety.required}",
                )
                return
            }
            SafetySosGestureRuntime.Result.Triggered -> {
                ble.externalLog("SOS gesture complete; opening a manual contact page")
                ble.buzz(3)
                val outcome = SafetySosDispatcher.trigger(appContext)
                ble.externalLog(
                    when (outcome) {
                        SafetySosDispatcher.Outcome.Opened ->
                            "SOS page request accepted; delivery is pending"
                        SafetySosDispatcher.Outcome.AlreadyActive ->
                            "SOS page already active; latest-location sharing resumed"
                        is SafetySosDispatcher.Outcome.Unavailable ->
                            "SOS page was not sent: ${outcome.reason}"
                    },
                )
                return
            }
        }

        val action = _doubleTapAction.value
        if (action == DoubleTapAction.NONE) return
        ble.externalLog("Double-tap -> ${action.label}")
        runDoubleTapAction(action)
    }

    /** Execute one double-tap action using the primitives that already exist on Android. In-app side
     *  effects (buzz / log / sleep mark) stay on-device; there is no lockScreen / Shortcuts action on
     *  Android (those Apple-only cases were dropped from [DoubleTapAction]). */
    private fun runDoubleTapAction(action: DoubleTapAction) {
        when (action) {
            DoubleTapAction.NONE -> {}
            DoubleTapAction.BUZZ_BACK -> ble.buzz(1)
            DoubleTapAction.MARK_MOMENT -> markMoment()
            DoubleTapAction.SLEEP_MARK -> markSleep()
            DoubleTapAction.HAPTIC_CLOCK -> ble.buzzTimeNow(is24h = localeUses24HourClock())
        }
    }

    /** Record a "moment" (a double-tap marker) with a confirming buzz. Android has no separate moments
     *  store yet, so — matching the iOS markMoment's user-visible effect (a buzz + a greppable log line)
     *  — this writes a timestamped line into the shareable strap log and buzzes once. Additive: no new
     *  persistence, no change to any existing path. */
    private fun markMoment() {
        val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date())
        ble.externalLog("Moment marked @ $clock")
        ble.buzz(1)
    }

    /** Record a "sleep mark" via the existing [SleepMark] analytics + the shareable strap log, with a
     *  confirming buzz — the same logging-only path the Sleep screen's mark card uses (#461). A double-tap
     *  can't pick bedtime vs wake, so it defaults to bedtime ([SleepMark.nowDefault]). */
    private fun markSleep() {
        val mark = SleepMark.nowDefault()
        ble.externalLog(mark.logLine())
        ble.buzz(1)
        viewModelScope.launch {
            // Use the SAME "my-whoop" series source the Sleep screen's mark card writes (SleepScreen.kt)
            // and reads back from, so a double-tap mark lands in the same place a tapped one does.
            runCatching { repository.upsertMetricSeries(listOf(mark.metricPoint("my-whoop"))) }
        }
    }

    /** Whether the device's locale formats time on a 24-hour clock — drives the Haptic Clock's hour
     *  encoding so a double-tap buzzes the time the way the user reads it. Mirrors macOS
     *  AppModel.localeUses24HourClock. */
    private fun localeUses24HourClock(): Boolean {
        val pattern = (java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT) as? java.text.SimpleDateFormat)
            ?.toPattern() ?: "h:mm a"
        return !pattern.contains('a', ignoreCase = true)
    }

    // --- Sustained workout-exertion guidance settings. ---

    fun setZoneCoaching(enabled: Boolean) {
        _zoneCoaching.value = enabled
        if (!enabled) workoutCautionPolicy = null
        NoopPrefs.setZoneCoaching(appContext, enabled)
    }

    fun setZoneCoachRecovery(enabled: Boolean) {
        _zoneCoachRecovery.value = enabled
        NoopPrefs.setZoneCoachRecovery(appContext, enabled)
    }

    override fun onCleared() {
        // The process-owned BLE client outlives this Activity-scoped ViewModel. Drop this VM's durable
        // workout lease before a replacement VM rehydrates the same session, preventing a stale screen
        // want or double acquisition across Activity teardown.
        releaseActiveWorkoutRealtimeLease()
        plannedWorkoutCalendarEvaluationJob?.cancel()
        adaptiveDayInputEvaluationJob?.cancel()
        unregisterPlannedWorkoutCalendarObserver()
        super.onCleared()
        // #78 hole-4: drop the app-foreground salvage-probe hook with this ViewModel (the next Activity's
        // ViewModel re-registers its own), so a cleared VM can never leak resume callbacks.
        noopApp.unregisterActivityLifecycleCallbacks(salvageProbeLifecycleCallbacks)
        // The BLE client is process-owned (NoopApplication) and may be held up by
        // WhoopConnectionService, so we never shut it down here. Only drop the connection when the
        // user hasn't opted into background streaming — otherwise closing the UI would defeat the
        // foreground service. (We deliberately do NOT call ble.shutdown(): the client outlives the
        // ViewModel and is reused by the next Activity.)
        if (!NoopPrefs.backgroundConnection(appContext)) {
            ble.disconnect()
        }
        // Release the HR-broadcast radio when this ViewModel goes away — the broadcast is a foreground
        // convenience (read your strap HR on nearby gym kit), not a background service. A relaunch
        // re-resumes it from the persisted toggle.
        broadcaster.stop()
    }

    private companion object {
        /** Grace before the first scoring pass, letting the first BLE offload land. */
        const val FIRST_OFFLOAD_GRACE_MS = 6_000L
        /** On-device scoring cadence — 15 min, matching the strap offload cadence. */
        const val ANALYZE_INTERVAL_MS = 15 * 60 * 1_000L
        /** Daily re-arm cadence for the single-instant strap firmware alarm (secondary buzz cue). */
        const val STRAP_ALARM_REARM_INTERVAL_MS = 24 * 60 * 60 * 1_000L
        /** SharedPreferences key for the persisted double-tap action (stored as the enum NAME). */
        const val DOUBLE_TAP_ACTION_KEY = "noop.doubleTapAction"
        /** Last profile state fully reconciled into Fitness Age and Vitality rows. */
        const val AGE_METRIC_RECONCILED_PROFILE_STATE_KEY =
            "noop.ageMetrics.reconciledProfileState.v2"
        /** Active source paired with [AGE_METRIC_RECONCILED_PROFILE_STATE_KEY]. */
        const val AGE_METRIC_RECONCILED_DEVICE_ID_KEY =
            "noop.ageMetrics.reconciledDeviceId.v3"
    }
}

/** Immutable scope captured by one Fitness Age/Vitality reconciliation job. */
internal data class AgeMetricReconciliationTarget(
    val profileState: String,
    val deviceId: String,
)

/**
 * What a strap double-tap does on Android (parity promised since 4.2.8). Mirrors the Apple-applicable
 * subset of iOS `MacActionKind` (Strand/System/MacActions.swift): the macOS-only `lockScreen` and the
 * Shortcuts-only `runShortcut` cases are deliberately DROPPED — Android has neither. Persisted by raw
 * value (the enum NAME) in NoopPrefs; default [NONE] keeps it manual-first. The dispatch lives in
 * [AppViewModel] (the Android analogue of iOS AppModel.runMacAction).
 */
enum class DoubleTapAction {
    NONE,         // do nothing (default — manual-first)
    BUZZ_BACK,    // a single confirming buzz
    MARK_MOMENT,  // log a timestamped "moment" to the strap log
    SLEEP_MARK,   // log a sleep mark (#461)
    HAPTIC_CLOCK; // buzz the current time out on the strap (#460)

    /** The picker label, mirroring the iOS `MacActionKind.label` wording for the same cases. */
    val label: String
        get() = when (this) {
            NONE -> "Nothing"
            BUZZ_BACK -> "Buzz back (confirm)"
            MARK_MOMENT -> "Mark a moment"
            SLEEP_MARK -> "Log a sleep mark"
            HAPTIC_CLOCK -> "Buzz the time"
        }

    companion object {
        /** Decode a persisted name back to an action; tolerant of an unknown/blank value (→ [NONE]). */
        fun fromRaw(raw: String?): DoubleTapAction =
            entries.firstOrNull { it.name == raw } ?: NONE
    }
}

/**
 * Next strap-alarm fire time as absolute UTC seconds, honouring the weekday selection (#539). Pure +
 * side-effect-free so it can be unit-tested against a fixed clock. Mirrors macOS
 * `AppModel.nextSmartAlarmDate`.
 *
 *  - [minuteOfDay]: target wake time, minutes since local midnight.
 *  - [weekdays]: Calendar.DAY_OF_WEEK numbers (1=Sun…7=Sat) the alarm may fire on. Empty = every day.
 *    Numbers outside 1…7 are ignored.
 *  - [nowMs]/[calendarFactory]: injected for tests; default to the real clock + local calendar.
 *
 * Scans today through +7 days for the next strictly-future occurrence on an enabled weekday. Returns
 * null only when no valid weekday falls in that range (i.e. the set held nothing in 1…7).
 */
internal fun nextSmartAlarmEpochSec(
    minuteOfDay: Int,
    weekdays: Set<Int>,
    nowMs: Long = System.currentTimeMillis(),
    calendarFactory: () -> java.util.Calendar = { java.util.Calendar.getInstance() },
    dayOverrides: Map<Int, Int> = emptyMap(),
): Long? {
    val valid = weekdays.filter { it in 1..7 }.toSet()
    // An EMPTY input means "every day" (backward compatible). A non-empty selection that filters to
    // nothing (only out-of-range numbers) has no valid day to fire on, so it's null, not a daily alarm.
    if (weekdays.isNotEmpty() && valid.isEmpty()) return null
    // Per-weekday OVERRIDES (#554): only valid (day 1…7, minute in-range) entries count; a day without an
    // override uses the default [minuteOfDay]. When the map is empty this is byte-for-byte the old path.
    val cleanOverrides = dayOverrides.filterKeys { it in 1..7 }.filterValues { it in 0 until 24 * 60 }
    for (offset in 0..7) {
        // Resolve this calendar day's weekday first, so the per-day override time is applied BEFORE the
        // strictly-future check (a later override time can make today's occurrence still pending).
        val probe = calendarFactory().apply {
            timeInMillis = nowMs
            add(java.util.Calendar.DAY_OF_YEAR, offset)
        }
        val dow = probe.get(java.util.Calendar.DAY_OF_WEEK)
        // Skip days the alarm doesn't fire on (empty weekdays = every day).
        if (weekdays.isNotEmpty() && !valid.contains(dow)) continue
        val wakeMin = cleanOverrides[dow] ?: minuteOfDay
        val cal = calendarFactory().apply {
            timeInMillis = nowMs
            add(java.util.Calendar.DAY_OF_YEAR, offset)
            set(java.util.Calendar.HOUR_OF_DAY, wakeMin / 60)
            set(java.util.Calendar.MINUTE, wakeMin % 60)
            set(java.util.Calendar.SECOND, 0)
            set(java.util.Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= nowMs) continue
        return cal.timeInMillis / 1000
    }
    return null
}

/**
 * Next strictly-future occurrence of a daily wake time (today, or tomorrow if already passed), as an
 * epoch-second. Used for the "Buzz WHOOP 4/5" companion, which fires every day at the phone alarm's
 * earliest wake time (no weekday selection). Pure + clock-injectable so it can be unit-tested.
 */
internal fun nextDailyEpochSec(
    minuteOfDay: Int,
    nowMs: Long = System.currentTimeMillis(),
    calendarFactory: () -> java.util.Calendar = { java.util.Calendar.getInstance() },
): Long {
    val cal = calendarFactory().apply {
        timeInMillis = nowMs
        set(java.util.Calendar.HOUR_OF_DAY, minuteOfDay / 60)
        set(java.util.Calendar.MINUTE, minuteOfDay % 60)
        set(java.util.Calendar.SECOND, 0)
        set(java.util.Calendar.MILLISECOND, 0)
        if (timeInMillis <= nowMs) add(java.util.Calendar.DAY_OF_YEAR, 1)
    }
    return cal.timeInMillis / 1000
}

/**
 * The strap has ONE firmware-alarm slot but two features can want it (#5): the smart wake-alarm and the
 * "Buzz WHOOP 4/5" companion. Given each feature's requested wake epoch (null = that feature is off or
 * has no valid firing day), return the EARLIEST that is non-null, or null when neither wants the slot.
 * Pure so the clobber scenario (both on, turn one off → slot stays armed to the other's time) is unit-
 * testable without the BLE stack.
 */
internal fun earliestStrapAlarmEpochSec(smartEpoch: Long?, buzzEpoch: Long?): Long? =
    when {
        smartEpoch == null -> buzzEpoch
        buzzEpoch == null -> smartEpoch
        else -> minOf(smartEpoch, buzzEpoch)
    }

/**
 * Elapsed-workout clock from a whole-second count: M:SS up to an hour, H:MM:SS once an hour has passed (so a
 * 90-minute session reads "1:30:00", not "90:00"). Negative inputs clamp to zero ("0:00"). Pure so the
 * Today "workout in progress" indicator and the Live card share ONE format, and the iOS-parity H:MM:SS
 * roll-over is unit-testable without composing any UI. Mirrors iOS ActiveWorkoutIndicatorModel.elapsed.
 */
internal fun elapsedClock(elapsedS: Long): String {
    val total = elapsedS.coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) {
        java.lang.String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s)
    } else {
        java.lang.String.format(java.util.Locale.US, "%d:%02d", m, s)
    }
}
