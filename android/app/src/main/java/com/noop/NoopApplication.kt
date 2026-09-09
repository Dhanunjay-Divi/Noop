package com.noop

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import com.noop.ble.SourceCoordinator
import com.noop.ble.WhoopBleClient
import com.noop.analytics.RegistryDayOwnerSource
import com.noop.ble.WhoopModel
import com.noop.data.DeviceRegistry
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.sync.RemoteSyncService
import com.noop.sync.RemoteSyncScheduler
import com.noop.ui.BackupSync
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.DebugExportScheduler
import com.noop.ui.NoopPrefs
import com.noop.ui.AppearanceMode
import com.noop.ui.AppearancePrefs
import com.noop.widget.WidgetSnapshotStore
import com.noop.widget.shouldRefreshSystemWidgetsForNightMode
import com.noop.location.GpsSession
import com.noop.ingest.HealthConnectSyncScheduler
import com.noop.managed.ManagedCloudScheduler
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedRuntimeGate
import com.noop.managed.ManagedSafetyLiveLocationSession
import com.noop.notif.DailyReviewReminders
import com.noop.notif.HydrationReminderScheduler
import com.noop.ownership.OwnershipService
import com.noop.safety.SafetyContactSetupReminderScheduler
import com.noop.safety.SafetyIncidentStatusMonitor
import com.noop.safety.SafetyLiveLocationSession
import com.noop.social.FriendsSyncScheduler
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Application entry point.
 *
 * NOOP is local-first: it connects to the strap over BLE and persists everything in Room. Network
 * features are explicit opt-ins only (AI Coach and the user's own self-hosted sync destination).
 *
 * The data layer ([WhoopRepository]) and the BLE client ([WhoopBleClient]) are owned **here**, at the
 * process level, rather than by the Activity-scoped AppViewModel. That is what lets a connection keep
 * streaming when the app is backgrounded or closed: [com.noop.ble.WhoopConnectionService] holds the
 * process up with a foreground notification, and both it and the UI share this one BLE client. The
 * macOS app gets the same outcome for free — its `AppModel` is an app-level `@StateObject` kept alive
 * by the menu-bar extra.
 */
class NoopApplication : Application(), androidx.work.Configuration.Provider {

    private var lastWidgetNightMode: Boolean? = null
    private val startupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableActiveDeviceId = MutableStateFlow(WhoopBleClient.DEFAULT_DEVICE_ID)
    private val activeDeviceLock = Any()
    private var activeDeviceRevision = 0L
    private val operationalRuntime = AtomicBoolean(false)

    /** True after the consent-gated Room/BLE/cloud/worker runtime has started for this process. */
    val operationalRuntimeStarted: Boolean get() = operationalRuntime.get()

    /**
     * WorkManager is initialized lazily on the first consent-gated scheduler call.
     *
     * The manifest removes only WorkManager's AndroidX Startup initializer, leaving the other Startup
     * components intact. This keeps a fresh Review Sample/Terms process from opening WorkManager's
     * database before [startOperationalRuntime] while preserving normal returning-user and worker
     * execution through WorkManager's documented [androidx.work.Configuration.Provider] path.
     */
    override val workManagerConfiguration: androidx.work.Configuration
        get() = androidx.work.Configuration.Builder().build()

    /** Process-wide active-device projection. It starts at the legacy single-band id, then the Room
     *  registry resolves it off the main thread. Consumers that outlive startup observe the correction
     *  without making the first Compose frame wait for database open/migration. */
    val activeDeviceIdFlow: StateFlow<String> = mutableActiveDeviceId.asStateFlow()

    /** Synchronous best-known id for workers and lazy process services. */
    val activeDeviceId: String get() = mutableActiveDeviceId.value

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        // UI resource lookup is intentionally available before onCreate: data-driven presentation
        // helpers (release notes, metric catalogs) can resolve a resource without becoming
        // @Composable or retaining an Activity. The Application is process-scoped, so this does not
        // leak a screen/context; configuration changes replace its Resources in place.
        instance = this
    }

    override fun onCreate() {
        super.onCreate()
        // Start before Room, BLE, WorkManager, or Firebase can initialize. If startup later hangs or
        // crashes, the unmatched operation/lifecycle edge is already durable for the next report.
        AppDiagnosticsRecorder.start(this)
        // Install immediately after the bounded recorder so a failure in the initialization below keeps
        // its stack trace as well as the unmatched launch breadcrumb.
        CrashCapture.install(this)
        lastWidgetNightMode = resources.configuration.isNightMode()
        if (hasAcceptedCurrentTerms()) {
            startOperationalRuntime()
        }
    }

    /**
     * Start the production runtime exactly once, after current Terms have been accepted.
     *
     * A fresh Review Sample process never calls this method, so that path cannot open Room, construct BLE,
     * reconcile cloud identity, restore Safety location, or schedule notifications/workers. Returning
     * consented users call it from [onCreate]; a first-run acceptance calls it from the UI before the
     * operational ViewModel is constructed.
     */
    fun startOperationalRuntime() {
        if (!operationalRuntime.compareAndSet(false, true)) return
        AppDiagnosticsRecorder.record("runtime.operational_started")
        resolveActiveDeviceId()
        // Canonicalize the stress-check-in choices against this build's evidence capability before
        // BLE/background readers observe them. The live path still fails closed per event.
        BiofeedbackPrefs.migrateAutomaticStressNudgePreferences(this)
        lastWidgetNightMode = resources.configuration.isNightMode()
        // Restore any process-killed, actively-recording GPS workout before the foreground service or
        // ViewModel reads GpsSession. The checkpoint is local-only and expires after 24 hours.
        GpsSession.initialize(this)
        com.noop.ui.NoopPrefs.migrateContinuousHrvOvernightDefault(this)
        // Canonicalize the retired auto-save/Boolean preferences before any UI or background notifier
        // reads them. Ask remains approval-first and rollback cannot resurrect unattended writes.
        NoopPrefs.migrateAutoWorkoutMode(this)
        // Preference initialization only; no network work occurs here. Self-hosted upload remains
        // opt-in and is scheduled later from the activity after the user saves a destination.
        RemoteSyncService.initialize(this)
        deferProcessMaintenance()
    }

    private fun hasAcceptedCurrentTerms(): Boolean =
        ManagedRuntimeGate.isAuthorized(this)

    override fun onTrimMemory(level: Int) {
        AppDiagnosticsRecorder.record(
            "system.trim_memory",
            fields = mapOf("level" to level.toString()),
            includeResourceSnapshot = true,
        )
        super.onTrimMemory(level)
    }

    override fun onLowMemory() {
        AppDiagnosticsRecorder.record(
            "system.low_memory",
            includeResourceSnapshot = true,
        )
        super.onLowMemory()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val currentNightMode = newConfig.isNightMode()
        if (!operationalRuntimeStarted) {
            lastWidgetNightMode = currentNightMode
            return
        }
        if (
            shouldRefreshSystemWidgetsForNightMode(
                previousDark = lastWidgetNightMode,
                currentDark = currentNightMode,
                followsSystem = AppearancePrefs.persistedMode(this) == AppearanceMode.SYSTEM,
            )
        ) {
            WidgetSnapshotStore.requestRefresh(this)
        }
        lastWidgetNightMode = currentNightMode
    }

    /** Process-wide Room-backed store. One instance shared by the UI and the background service. */
    val repository: WhoopRepository by lazy {
        WhoopRepository(WhoopDatabase.get(this))
    }

    /** Process-wide device registry over the same Room DB — the single source of the active device id. */
    val deviceRegistry: DeviceRegistry by lazy { DeviceRegistry(WhoopDatabase.get(this)) }

    /** Optional managed backup owner. It stays dormant when this build has no NOOP+ configuration. */
    val managedCloud: ManagedCloudService by lazy { ManagedCloudService.get(this) }

    /** First-party band ownership authority. It is independent of NOOP+ and remains fail-closed
     *  until an approved supplier possession provider is installed. */
    val ownership: OwnershipService by lazy { OwnershipService.get(this) }

    /**
     * Publish a registry selection immediately after a user-driven device switch. The Room transaction
     * remains the source of truth; this projection removes the old process-lifetime stale value and lets
     * every subscribed read surface switch without waiting for a restart.
     */
    fun noteActiveDeviceId(id: String) {
        synchronized(activeDeviceLock) {
            activeDeviceRevision += 1L
            publishActiveDeviceId(id)
        }
    }

    private fun publishActiveDeviceId(id: String) {
        val resolved = id.trim().ifEmpty { WhoopBleClient.DEFAULT_DEVICE_ID }
        if (mutableActiveDeviceId.value == resolved) return
        mutableActiveDeviceId.value = resolved
        if (bleDelegate.isInitialized()) {
            ble.setActiveDeviceId(resolved)
        }
    }

    /**
     * Resolve the persisted registry selection without blocking Application/MainActivity startup.
     * A multi-device install can briefly render the canonical history projection, then atomically
     * switches to its active source when this indexed Room read completes. If a background service
     * initialized BLE first, re-point it and start the coordinator so generic-source ownership is
     * reconciled too.
     */
    private fun resolveActiveDeviceId() {
        val expectedRevision = synchronized(activeDeviceLock) { activeDeviceRevision }
        startupScope.launch {
            val resolved = runCatching { deviceRegistry.activeDeviceId() }
                .onFailure {
                    AppDiagnosticsRecorder.record(
                        "device_registry.resolve",
                        fields = mapOf(
                            "outcome" to "fallback",
                            "failure_kind" to it.javaClass.simpleName,
                        ),
                    )
                }
                .getOrNull()
                ?.takeIf(String::isNotBlank)
                ?: WhoopBleClient.DEFAULT_DEVICE_ID
            // Publish while holding the same lock as user-driven changes. This also catches a user
            // explicitly switching back to the default id while Room opens, where comparing only the
            // current string cannot distinguish the new selection from the initial fallback.
            val published = synchronized(activeDeviceLock) {
                if (activeDeviceRevision != expectedRevision) {
                    false
                } else {
                    activeDeviceRevision += 1L
                    publishActiveDeviceId(resolved)
                    true
                }
            }
            if (!published) return@launch
            if (resolved != WhoopBleClient.DEFAULT_DEVICE_ID || bleDelegate.isInitialized()) {
                sourceCoordinator.start()
            }
        }
    }

    /**
     * WorkManager opens its own database. Keep schedule repair out of Application's main-thread launch
     * path while preserving process-level self-healing for starts that do not create an Activity.
     */
    private fun deferProcessMaintenance() {
        startupScope.launch {
            // The private three-day Safety setup reminder remains inert until onboarding requests it.
            runCatching { SafetyContactSetupReminderScheduler.reconcile(this@NoopApplication) }
            // Friends remains credential-gated and network constrained. Remote preferences were initialized
            // synchronously above, before this task can inspect them.
            runCatching { FriendsSyncScheduler.reconcile(this@NoopApplication) }
            // NOOP+ remains configuration-, identity-, consent-, and network-gated. Bootstrap restores
            // local auth state only; WorkManager performs any due transfer outside app startup.
            runCatching { managedCloud.bootstrap() }
            runCatching { ManagedCloudScheduler.reconcile(this@NoopApplication) }
            runCatching { ManagedCloudScheduler.enqueueCatchUpIfDue(this@NoopApplication) }
            // Account state reconciliation is local unless this build explicitly enables the
            // ownership authority. It never starts BLE, uploads health data, or grants NOOP+.
            runCatching { ownership.bootstrap() }

            // Activity-independent schedule repair. Keeping all of it behind startOperationalRuntime
            // prevents a fresh Review Sample process from touching production workers or storage.
            runCatching { DebugExportScheduler.reschedule(this@NoopApplication) }
            runCatching { BackupSync.reschedule(this@NoopApplication) }
            runCatching { BackupSync.catchUpIfDue(this@NoopApplication) }
            runCatching { RemoteSyncScheduler.reschedule(this@NoopApplication) }
            runCatching { RemoteSyncScheduler.enqueueCatchUpIfDue(this@NoopApplication) }
            runCatching { HealthConnectSyncScheduler.reconcile(this@NoopApplication) }
            runCatching { DailyReviewReminders.reconcile(this@NoopApplication) }
            runCatching { HydrationReminderScheduler.reconcile(this@NoopApplication) }
            runCatching {
                SafetyLiveLocationSession.initialize(this@NoopApplication)
                ManagedSafetyLiveLocationSession.initialize(this@NoopApplication)
                SafetyIncidentStatusMonitor.reconcile(this@NoopApplication)
            }
        }
    }

    /** Process-wide BLE client. Owns the GATT connection and outlives any single Activity/ViewModel. */
    private val bleDelegate = lazy {
        WhoopBleClient(
            applicationContext,
            repository = repository,
            deviceId = activeDeviceId,
            dayOwnerSource = RegistryDayOwnerSource(deviceRegistry),
        ).apply {
            // Apply the persisted "Debug logging" preference at the composition root so the low-level
            // client never has to read the UI/prefs layer. Default OFF — see WhoopBleClient.debugLogcat.
            debugLogcat = NoopPrefs.debugLogging(applicationContext)
        }
    }
    // Serialize first construction with active-id publication. Otherwise a switch could observe the
    // delegate as "initializing", skip re-pointing it, and race its constructor reading the old fallback.
    val ble: WhoopBleClient get() = synchronized(activeDeviceLock) { bleDelegate.value }

    /** Do not construct the BLE stack merely because a background social delivery arrived. */
    fun requestManagedSocialPokeHaptic(): Boolean = synchronized(activeDeviceLock) {
        if (!bleDelegate.isInitialized()) {
            false
        } else {
            bleDelegate.value.requestManagedSocialPokeHaptic()
        }
    }

    /**
     * Multi-source coordinator (Phase 1B): runs exactly one device's live BLE at a time, driven by the
     * registry's active device id. DORMANT whenever the active device is the WHOOP (the default and every
     * single-WHOOP install), so the existing WHOOP flow is untouched. Only when a non-WHOOP generic HR
     * strap becomes active does it pause WHOOP and run the isolated [com.noop.ble.StandardHrSource].
     *
     * Wired to the EXISTING [ble] entry points via closures — it never touches [WhoopBleClient]
     * internals. Strap live HR is pushed into the same [ble] state flow the UI observes via
     * [WhoopBleClient.publishExternalLiveHr]. [SourceCoordinator.start] reconciles once against the
     * current active id at launch (a no-op for a single-WHOOP install); the Devices screen (next task)
     * calls [SourceCoordinator.onActiveDeviceChanged] after a setActive.
     *
     * Multi-WHOOP identity adoption: AppViewModel's init collects [WhoopBleClient.connectedPeripheralAddress]
     * (distinctUntilChanged) into [SourceCoordinator.connectedPeripheralChanged] — the Kotlin analogue of
     * macOS wiring `BLEManager.connectedPeripheralUUID` into the coordinator's adoption sink. Kept beside
     * the other `ble`-flow collectors there (this Application owns no CoroutineScope of its own).
     */
    private val sourceCoordinatorDelegate = lazy {
        SourceCoordinator(
            context = applicationContext,
            registry = deviceRegistry,
            repository = repository,
            liveSink = { hr, rr -> ble.publishExternalLiveHr(hr, rr) },
            // #74: reconnect on the PERSISTED family, not the WhoopModel.WHOOP4 default - otherwise a
            // 5/MG WHOOP->WHOOP switch rescans the wrong service and misses the 5/MG direct-bond fast
            // path (status=133 on an OS-bonded strap). Mirrors macOS AppModel.scan() reading the persisted
            // "selectedWhoopModel". Same-strap switches now adopt in place (no reconnect) via the
            // coordinator, so this only fires for a genuinely different WHOOP.
            startWhoop = { ble.connect(persistedWhoopModel()) },
            stopWhoop = { ble.disconnect() },
            // Multi-WHOOP (MW-2/MW-3): pin the connection to the active WHOOP's persisted address and
            // re-attribute live samples to it on a WHOOP→WHOOP switch. Both inert on the single-WHOOP
            // path — the coordinator only invokes them for a non-legacy WHOOP / a non-null peripheralId.
            setWhoopPreferredAddress = { addr -> ble.preferredAddress = addr },
            setWhoopActiveDeviceId = { id -> ble.setActiveDeviceId(id) },
            // Generic-HR connect lifecycle → the SAME in-app strap log the user exports, so a
            // "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc path.
            straplog = { ble.externalLog(it) },
            // A generic strap's standard battery (0x180F) → the same live battery field the WHOOP uses.
            batterySink = { pct -> ble.publishExternalBattery(pct) },
        )
    }
    val sourceCoordinator: SourceCoordinator get() = sourceCoordinatorDelegate.value

    /** The WHOOP family last seen advertising, persisted by [WhoopBleClient.persistSelectedModel] under
     *  "noop.selectedWhoopModel" in the shared noop_prefs store. Defaults to [WhoopModel.WHOOP4] when
     *  unset or unparseable (the historical connect() default), so a fresh install is unchanged. Used to
     *  reconnect on the right service after a WHOOP->WHOOP switch (#74). */
    private fun persistedWhoopModel(): WhoopModel =
        NoopPrefs.of(this).getString("noop.selectedWhoopModel", null)
            ?.let { runCatching { WhoopModel.valueOf(it) }.getOrNull() }
            ?: WhoopModel.WHOOP4

    companion object {
        @Volatile private var instance: NoopApplication? = null

        /** Resolve app-owned UI copy from composable and non-composable presentation helpers alike. */
        fun localizedString(@StringRes id: Int, vararg formatArgs: Any): String {
            val app = checkNotNull(instance) { "NoopApplication is not attached" }
            return if (formatArgs.isEmpty()) app.getString(id) else app.getString(id, *formatArgs)
        }

        /** Quantity-aware twin of [localizedString]: resolves a `<plurals>` for [count] under the active
         *  locale's own plural rules. Same Application-resources path, so it stays locale-aware off the
         *  composition. */
        fun localizedPlural(@PluralsRes id: Int, count: Int, vararg formatArgs: Any): String {
            val app = checkNotNull(instance) { "NoopApplication is not attached" }
            return app.resources.getQuantityString(id, count, *formatArgs)
        }
    }
}

private fun Configuration.isNightMode(): Boolean =
    (uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
