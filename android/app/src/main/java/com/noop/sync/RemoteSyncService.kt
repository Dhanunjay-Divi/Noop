package com.noop.sync

import android.content.Context
import com.noop.BuildConfig
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.ingest.WearableExportImporter
import com.noop.ingest.XiaomiBandImporter
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.Instant

/** UI/worker-facing orchestration. One process performs at most one remote upload at a time. */
object RemoteSyncService {
    private val mutex = Mutex()

    fun initialize(context: Context) {
        RemoteSyncPrefs.initialize(context)
    }

    /** Dedicated installation-scoped producer for the privacy-minimized Friends projection. */
    fun socialDailyDeviceId(activeDeviceId: String): String =
        RemoteNamespaceCatalog.scopedRemoteId(
            RemoteSyncPrefs.installationId(),
            "$activeDeviceId-noop-friends-${RemoteNoopAlgorithmRevision.ID_SUFFIX}-friends-v1",
        )

    fun saveConfiguration(
        context: Context,
        endpoint: String,
        newApiKey: String,
        automatic: Boolean,
    ): String {
        initialize(context)
        val normalized = RemoteSyncPrefs.saveConfiguration(endpoint, newApiKey, automatic)
        RemoteSyncScheduler.reschedule(context)
        return normalized
    }

    fun setAutomatic(context: Context, enabled: Boolean) {
        initialize(context)
        RemoteSyncPrefs.setAutomatic(enabled)
        RemoteSyncScheduler.reschedule(context)
    }

    suspend fun disconnect(context: Context) = withContext(Dispatchers.IO) {
        mutex.withLock {
            initialize(context)
            try {
                RemoteSyncPrefs.clearConfiguration()
            } finally {
                RemoteSyncScheduler.reschedule(context)
            }
        }
    }

    suspend fun testConnection(
        context: Context,
        endpointInput: String,
        apiKeyInput: String,
    ): RemoteStatus {
        initialize(context)
        val endpoint = RemoteEndpointPolicy.normalize(endpointInput)
        val key = apiKeyInput.trim().ifEmpty { RemoteSyncPrefs.apiKey().orEmpty() }
        if (key.isBlank()) throw RemoteSyncConfigurationException("Enter the server API key.")
        return RemoteSyncClient(
            RemoteSyncConfiguration(endpoint, key, timeoutSeconds = 20),
        ).authenticatedStatus()
    }

    suspend fun sync(
        context: Context,
        activeDeviceId: String,
        fullReplay: Boolean = false,
    ): RemoteSyncRunResult = withContext(Dispatchers.IO) {
        mutex.withLock {
            initialize(context)
            val nowMs = System.currentTimeMillis()
            RemoteSyncPrefs.setLastAttemptMs(nowMs)
            RemoteSyncPrefs.setLastStatus("Syncing…")

            try {
                val database = WhoopDatabase.get(context.applicationContext)
                val store = RoomRemoteSyncDataStore(database)
                val namespaces = RemoteNamespaceCatalog.forActiveDevice(
                    activeDeviceId = activeDeviceId,
                    pairedDeviceIds = store.pairedDevices().map { it.id },
                    appVersion = BuildConfig.VERSION_NAME,
                    installationId = RemoteSyncPrefs.installationId(),
                    firmwareVersion = NoopPrefs.lastFirmware(context),
                )
                val syncNow = Instant.now()
                var replayWindow = RemoteSyncPrefs.replayWindow()
                var replay = RemoteSyncPrefs.replayInProgress() && replayWindow != null
                val replayStateIsIncomplete =
                    RemoteSyncPrefs.replayInProgress() && replayWindow == null
                val initializeReplay =
                    !replay &&
                        (fullReplay ||
                            RemoteSyncPrefs.needsFullReplay() ||
                            replayStateIsIncomplete)
                if (initializeReplay) {
                    val fixedWindow = RemoteDerivedWindow.endingAt(syncNow, historyDays = 3_650)
                    // No network work starts until every durable outbox/cursor reset succeeds. If the
                    // process dies before beginReplay, needsFullReplay remains true and this
                    // idempotent initialization is retried on the next launch.
                    store.reset(
                        namespaces.asSequence()
                            .filter(RemoteNamespace::includeRaw)
                            .map(RemoteNamespace::localDeviceId)
                            .toCollection(linkedSetOf()),
                    )
                    namespaces
                        .asSequence()
                        .filter(RemoteNamespace::includeDerived)
                        .forEach { RemoteSyncPrefs.clearDerivedCursor(it.remoteDeviceId) }
                    RemoteSyncPrefs.beginReplay(fixedWindow)
                    RemoteSyncPrefs.setNeedsFullReplay(false)
                    replayWindow = fixedWindow
                    replay = true
                } else if (replay && RemoteSyncPrefs.needsFullReplay()) {
                    // Covers termination after beginReplay committed but before the request bit was
                    // cleared. The valid fixed window wins; do not reset already-drained namespaces.
                    RemoteSyncPrefs.setNeedsFullReplay(false)
                }

                val client = RemoteSyncClient(RemoteSyncPrefs.configuration())
                val coordinator = RemoteSyncCoordinator(
                    store,
                    client,
                    RemoteSyncPrefs,
                    RemoteSyncPrefs,
                )
                var totalRows = 0
                var totalBatches = 0
                var hasMoreRaw = false
                var hasMoreDerived = false
                var lastAck: RemoteSyncAck? = null

                for (namespace in namespaces) {
                    val isRawStrap = namespace.includeRaw
                    val result = coordinator.sync(
                        namespace = namespace,
                        now = syncNow,
                        derivedHistoryDays = if (replay) 3_650 else 400,
                        derivedWindow = replayWindow.takeIf { replay },
                        retainDerivedCompletion = replay,
                        maxBatches = if (isRawStrap) {
                            if (replay) 50 else 8
                        } else {
                            if (replay) 50 else 2
                        },
                    )
                    totalRows += result.uploadedRawRows
                    totalBatches += result.uploadedBatches
                    hasMoreRaw = hasMoreRaw || result.hasMoreRawRows
                    hasMoreDerived = hasMoreDerived || result.hasMoreDerivedRows
                    lastAck = result.lastAck ?: lastAck
                }

                if (replay && !hasMoreRaw && !hasMoreDerived) {
                    // Completion cursors stay in place until every raw outbox and every derived
                    // namespace is done. Clear them and the replay marker in one preference commit.
                    RemoteSyncPrefs.finishReplay(
                        namespaces
                            .asSequence()
                            .filter(RemoteNamespace::includeDerived)
                            .map(RemoteNamespace::remoteDeviceId)
                            .toList(),
                    )
                }

                val status = when {
                    hasMoreRaw || hasMoreDerived ->
                        "Uploaded $totalRows raw rows; more raw/derived history is queued."
                    totalBatches == 0 -> "Up to date - no pending changes."
                    else -> "Up to date - uploaded $totalRows pending raw rows and refreshed derived history."
                }
                RemoteSyncPrefs.recordSuccess(System.currentTimeMillis(), totalRows, status)
                RemoteSyncRunResult(
                    uploadedRawRows = totalRows,
                    uploadedBatches = totalBatches,
                    hasMoreRawRows = hasMoreRaw,
                    hasMoreDerivedRows = hasMoreDerived,
                    lastAck = lastAck,
                )
            } catch (error: Throwable) {
                RemoteSyncPrefs.setLastStatus("Sync failed: ${safeError(error)}")
                throw error
            }
        }
    }

    private fun safeError(error: Throwable): String = when (error) {
        is RemoteSyncException -> error.message ?: "The sync request failed."
        else -> "An unexpected sync failure occurred."
    }
}

/** Every first-party namespace with user-owned data that the v1 API understands. */
object RemoteNamespaceCatalog {
    fun forActiveDevice(
        activeDeviceId: String,
        pairedDeviceIds: List<String> = listOf(activeDeviceId),
        appVersion: String,
        installationId: String,
        firmwareVersion: String?,
    ): List<RemoteNamespace> {
        val canonical = WhoopRepository.WHOOP_SOURCE
        val specs = ArrayList<RemoteNamespace>()
        fun add(
            logicalRemoteId: String,
            localId: String,
            role: String,
            raw: Boolean = false,
            derived: Boolean = true,
            pairedId: String = activeDeviceId,
        ) {
            val revisionScopedLogicalId = if (role == "noop_computed") {
                "$logicalRemoteId-${RemoteNoopAlgorithmRevision.ID_SUFFIX}"
            } else {
                logicalRemoteId
            }
            val remoteId = scopedRemoteId(installationId, revisionScopedLogicalId)
            if (specs.any { it.remoteDeviceId == remoteId }) return
            specs += RemoteNamespace(
                remoteDeviceId = remoteId,
                logicalSourceId = logicalRemoteId,
                localDeviceId = localId,
                role = role,
                pairedDeviceId = pairedId,
                appVersion = appVersion,
                installationId = installationId,
                firmwareVersion = firmwareVersion.takeIf { raw && pairedId == activeDeviceId },
                includeRaw = raw,
                includeDerived = derived,
            )
        }

        // Include every paired device's decoded outbox, not just the currently active strap. The
        // active one leads; archived/secondary devices retain independent remote namespaces.
        val strapIds = linkedSetOf(activeDeviceId).apply {
            addAll(pairedDeviceIds)
            add(canonical) // legacy rows may predate a later multi-device registry id
        }
        for (strapId in strapIds) {
            add(
                logicalRemoteId = "$strapId-strap",
                localId = strapId,
                role = "strap_measured",
                raw = true,
                derived = false,
                pairedId = strapId,
            )
            add(
                logicalRemoteId = "$strapId-noop",
                localId = "$strapId-noop",
                role = "noop_computed",
                pairedId = strapId,
            )
        }

        // Local schema history uses "my-whoop" for both legacy measured rows and a user-imported
        // WHOOP export. The raw loop above and this derived-only REMOTE id keep them separated.
        add(
            logicalRemoteId = "whoop-official-reference",
            localId = canonical,
            role = "official_reference",
        )
        add("noop-journal", "noop-journal", "noop_journal")
        add(
            WhoopRepository.APPLE_HEALTH_SOURCE,
            WhoopRepository.APPLE_HEALTH_SOURCE,
            "apple_health_import",
        )
        add(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            "health_connect_import",
        )
        add(
            WhoopRepository.ACTIVITY_FILE_SOURCE,
            WhoopRepository.ACTIVITY_FILE_SOURCE,
            "activity_file_import",
        )
        // v1 deliberately accepts only modeled daily/sleep/workout rows from wearable imports.
        // Generic metricSeries, Oura raw API pages, labs, nutrition, hydration and mood stay local.
        val wearableImportSources = listOf(XiaomiBandImporter.DEFAULT_DEVICE_ID) +
            WearableExportImporter.Brand.entries.map(WearableExportImporter.Brand::sourceId)
        wearableImportSources.forEach { sourceId ->
            add(sourceId, sourceId, "wearable_import")
        }
        return specs
    }

    /**
     * Stable producer identity for the server. The readable form covers normal UUID/device ids; a
     * hashed fallback keeps unusual legacy ids inside the API's 128-character identifier grammar.
     */
    internal fun scopedRemoteId(installationId: String, logicalRemoteId: String): String {
        val direct = "android:$installationId:$logicalRemoteId"
        if (direct.length <= 128 && direct.matches(Regex("""[A-Za-z0-9][A-Za-z0-9._:-]*"""))) {
            return direct
        }

        fun safe(value: String): String = buildString(value.length) {
            value.forEach { character ->
                append(
                    if (character in 'A'..'Z' ||
                        character in 'a'..'z' ||
                        character in '0'..'9' ||
                        character == '.' ||
                        character == '_' ||
                        character == ':' ||
                        character == '-'
                    ) {
                        character
                    } else {
                        '_'
                    },
                )
            }
        }

        val safeInstallation = safe(installationId).ifBlank {
            RemoteIdentifiers.fnv1a64(installationId)
        }.take(64)
        val safeLogical = safe(logicalRemoteId).ifBlank { "source" }
        val digest = RemoteIdentifiers.fnv1a64(logicalRemoteId)
        val prefix = "android:$safeInstallation:"
        val readableLength = (128 - prefix.length - digest.length - 1).coerceAtLeast(0)
        return "$prefix${safeLogical.take(readableLength)}:$digest"
    }
}
