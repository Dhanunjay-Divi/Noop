package com.noop.sync

import com.noop.data.DailyMetric
import com.noop.data.EventRow
import com.noop.data.HrSample
import com.noop.data.JournalEntry
import com.noop.data.PairedDeviceRow
import com.noop.data.SleepSession
import com.noop.data.WorkoutRow
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID

class RemoteSyncCoordinatorTest {
    private val namespace = RemoteNamespace(
        remoteDeviceId = "android:install-1:my-whoop-strap",
        logicalSourceId = "my-whoop-strap",
        localDeviceId = "my-whoop",
        role = "strap_measured",
        pairedDeviceId = "my-whoop",
        appVersion = "1.0",
        installationId = "install-1",
        includeRaw = true,
        includeDerived = false,
    )

    @Test
    fun rawRowsAreAcknowledgedOnlyAfterMatchingSuccess() = runTest {
        val store = FakeStore(
            pendingRows = PendingRemoteStreams(
                hr = listOf(HrSample("my-whoop", 1_700_000_000, 62)),
            ),
        )
        val identities = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(
            store,
            object : RemoteSyncUploading {
                override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck {
                    throw RemoteSyncException.Network("offline", IOException())
                }
            },
            identities,
            identities,
        )

        assertThrows(RemoteSyncException.Network::class.java) {
            kotlinx.coroutines.runBlocking {
                coordinator.sync(namespace, maxBatches = 1)
            }
        }
        assertTrue(store.acknowledged.isEmpty())
        assertFalse(store.pendingRows.isEmpty)
        assertEquals(1, identities.saved.size)
    }

    @Test
    fun retryIdentityIsStableAndSuccessClearsThenAcknowledges() = runTest {
        val store = FakeStore(
            pendingRows = PendingRemoteStreams(
                hr = listOf(HrSample("my-whoop", 1_700_000_000, 62)),
            ),
        )
        val identities = FakeIdentities()
        val seen = mutableListOf<RemoteEnvelope>()
        val coordinator = RemoteSyncCoordinator(
            store,
            object : RemoteSyncUploading {
                override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck {
                    seen += envelope
                    return RemoteSyncAck(envelope.batchId, "accepted", false, emptyMap())
                }
            },
            identities,
            identities,
        )

        val result = coordinator.sync(namespace, maxBatches = 1)
        assertEquals(1, result.uploadedRawRows)
        assertEquals(1, store.acknowledged.single().hr.size)
        assertTrue(store.pendingRows.isEmpty)
        assertTrue(identities.saved.isEmpty())
        assertEquals("android:install-1:my-whoop-strap", seen.single().draft.source.deviceId)
        assertEquals("strap_measured", seen.single().draft.source.metadata["namespace"])
        assertEquals("my-whoop-strap", seen.single().draft.source.metadata["logical_source_id"])
        assertEquals("my-whoop", seen.single().draft.source.metadata["paired_device_id"])
        assertEquals("strap_measured", seen.single().draft.source.metadata["score_provenance"])
        assertEquals("strap_measured", seen.single().draft.streams.hr.single().metadata["provenance"])
    }

    @Test
    fun nonAcceptedAckNeverClearsDurableRows() = runTest {
        val store = FakeStore(
            pendingRows = PendingRemoteStreams(
                hr = listOf(HrSample("my-whoop", 1_700_000_000, 62)),
            ),
        )
        val state = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(
            store,
            object : RemoteSyncUploading {
                override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck =
                    RemoteSyncAck(envelope.batchId, "queued", false, emptyMap())
            },
            state,
            state,
        )

        assertThrows(RemoteSyncException.InvalidResponse::class.java) {
            kotlinx.coroutines.runBlocking { coordinator.sync(namespace, maxBatches = 1) }
        }
        assertFalse(store.pendingRows.isEmpty)
        assertTrue(store.acknowledged.isEmpty())
        assertEquals(1, state.saved.size)
    }

    @Test
    fun derivedMappingUsesFractionEfficiencyAndIntegerStageSeconds() = runTest {
        val coordinator = RemoteSyncCoordinator(
            FakeStore(),
            NoopUploader,
            FakeIdentities(),
            FakeIdentities(),
        )
        val derivedNamespace = namespace.copy(
            remoteDeviceId = "android:install-1:whoop-official-reference",
            logicalSourceId = "whoop-official-reference",
            role = "official_reference",
            includeRaw = false,
            includeDerived = true,
        )
        val draft = coordinator.buildDraft(
            derivedNamespace,
            paired = null,
            pending = PendingRemoteStreams(),
            derived = RemoteDerivedRows(
                daily = listOf(
                    DailyMetric(
                        deviceId = "my-whoop",
                        day = "2026-07-24",
                        efficiency = 92.0, // legacy percent row normalizes on wire
                        strain = 80.0,
                        skinTempDevC = 34.8,
                    ),
                ),
                sleep = listOf(
                    SleepSession(
                        deviceId = "my-whoop",
                        startTs = 1_700_000_000,
                        endTs = 1_700_003_600,
                        efficiency = 0.9,
                        stagesJSON = """[{"start":1700000000,"end":1700001800,"stage":"deep"},{"start":1700001800,"end":1700003600,"stage":"rem"}]""",
                    ),
                ),
            ),
        )

        assertEquals(0.92, draft.dailyMetrics.getValue("2026-07-24").getValue("efficiency"), 1e-9)
        assertEquals(80.0, draft.dailyMetrics.getValue("2026-07-24").getValue("effort"), 1e-9)
        assertEquals(16.8, draft.dailyMetrics.getValue("2026-07-24").getValue("whoop_strain"), 1e-9)
        assertEquals(34.8, draft.dailyMetrics.getValue("2026-07-24").getValue("skin_temp_c"), 1e-9)
        assertFalse(draft.dailyMetrics.getValue("2026-07-24").containsKey("strain"))
        assertFalse(draft.dailyMetrics.getValue("2026-07-24").containsKey("skin_temp_dev_c"))
        assertEquals(0.9, draft.sleepSessions.single().efficiency!!, 1e-9)
        assertEquals(mapOf("deep" to 1_800, "rem" to 1_800), draft.sleepSessions.single().stages)
        assertEquals(
            "user_imported_whoop_export",
            draft.source.metadata["score_provenance"],
        )
    }

    @Test
    fun officialReferenceFiltersLegacyShadowsAndUsesExplicitWireUnits() {
        val state = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(FakeStore(), NoopUploader, state, state)
        val official = namespace.copy(
            remoteDeviceId = "android:install-1:whoop-official-reference",
            logicalSourceId = "whoop-official-reference",
            role = "official_reference",
            includeRaw = false,
            includeDerived = true,
        )
        val draft = coordinator.buildDraft(
            official,
            paired = null,
            pending = PendingRemoteStreams(),
            derived = RemoteDerivedRows(
                daily = listOf(
                    DailyMetric(
                        deviceId = "my-whoop",
                        day = "2026-07-23",
                        totalSleepMin = 420.0,
                        restingHr = 52,
                    ), // sparse Health Connect shadow: not safely attributable to WHOOP
                    DailyMetric(
                        deviceId = "my-whoop",
                        day = "2026-07-24",
                        recovery = 74.0,
                        strain = 50.0,
                        skinTempDevC = 35.2,
                    ),
                ),
                sleep = listOf(
                    SleepSession("my-whoop", 100, 200, stagesJSON = """[{"stage":"deep","min":1}]"""),
                    SleepSession("my-whoop", 300, 400, efficiency = 0.88),
                ),
                workouts = listOf(
                    WorkoutRow("my-whoop", 500, 600, "Run", "health-connect", strain = 40.0),
                    WorkoutRow("my-whoop", 700, 800, "Ride", "my-whoop", strain = 50.0),
                ),
                journal = listOf(
                    JournalEntry("my-whoop", "2026-07-24", "Alcohol?", false),
                ),
            ),
        )

        assertEquals(setOf("2026-07-24"), draft.dailyMetrics.keys)
        val daily = draft.dailyMetrics.getValue("2026-07-24")
        assertEquals(50.0, daily.getValue("effort"), 1e-9)
        assertEquals(10.5, daily.getValue("whoop_strain"), 1e-9)
        assertEquals(35.2, daily.getValue("skin_temp_c"), 1e-9)
        assertFalse(daily.containsKey("strain"))
        assertFalse(daily.containsKey("skin_temp_dev_c"))
        assertEquals(listOf(300L), draft.sleepSessions.map(RemoteSleepSession::startTs))
        assertEquals(listOf("Ride"), draft.workouts.map(RemoteWorkout::sport))
        assertEquals(50.0, draft.workouts.single().metrics.getValue("effort"), 1e-9)
        assertEquals(10.5, draft.workouts.single().metrics.getValue("whoop_strain"), 1e-9)
        assertEquals(1, draft.journal.size)
        assertEquals(
            "whoop_export_signal_shape_v1",
            draft.source.metadata["reference_filter"],
        )
    }

    @Test
    fun noopMetricsKeepEffortAndTemperatureDeviationSemantics() {
        val state = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(FakeStore(), NoopUploader, state, state)
        val draft = coordinator.buildDraft(
            namespace.copy(
                remoteDeviceId = "android:install-1:my-whoop-noop-cer-v1",
                logicalSourceId = "my-whoop-noop",
                localDeviceId = "my-whoop-noop",
                role = "noop_computed",
                includeRaw = false,
                includeDerived = true,
            ),
            paired = null,
            pending = PendingRemoteStreams(),
            derived = RemoteDerivedRows(
                daily = listOf(
                    DailyMetric(
                        deviceId = "my-whoop-noop",
                        day = "2026-07-24",
                        strain = 67.0,
                        skinTempDevC = 1.2,
                    ),
                ),
                workouts = listOf(
                    WorkoutRow(
                        deviceId = "my-whoop-noop",
                        startTs = 1_800_000_000,
                        endTs = 1_800_000_600,
                        sport = "S".repeat(300),
                        source = "local-source-" + "x".repeat(180),
                    ),
                ),
                journal = listOf(
                    JournalEntry(
                        deviceId = "noop-journal",
                        day = "2026-07-24",
                        question = "Q".repeat(300),
                        answeredYes = true,
                        notes = "n".repeat(3_000),
                    ),
                ),
            ),
        )

        val metrics = draft.dailyMetrics.getValue("2026-07-24")
        assertEquals(67.0, metrics.getValue("effort"), 1e-9)
        assertEquals(1.2, metrics.getValue("skin_temp_dev_c"), 1e-9)
        assertFalse(metrics.containsKey("strain"))
        assertFalse(metrics.containsKey("whoop_strain"))
        assertFalse(metrics.containsKey("skin_temp_c"))
        assertEquals(
            "noop-charge-v1+noop-effort-v1+noop-rest-v1",
            draft.source.metadata["algorithm_revision"],
        )
        assertEquals("my-whoop-noop", draft.source.metadata["logical_source_id"])
        assertEquals(300, draft.workouts.single().sport.length)
        assertEquals(193, draft.workouts.single().source!!.length)
        assertEquals(300, draft.journal.single().question.length)
        assertEquals(3_000, draft.journal.single().notes!!.length)
    }

    @Test
    fun malformedDurationsAreSkippedAndEventMetadataStaysWithinServerBound() {
        val state = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(FakeStore(), NoopUploader, state, state)
        val draft = coordinator.buildDraft(
            namespace.copy(
                remoteDeviceId = "android:install:my-whoop-noop-cer-v1",
                logicalSourceId = "my-whoop-noop",
                localDeviceId = "my-whoop-noop",
                role = "noop_computed",
                includeRaw = true,
                includeDerived = true,
            ),
            paired = null,
            pending = PendingRemoteStreams(
                events = listOf(
                    EventRow(
                        "my-whoop",
                        1_800_000_000,
                        "",
                        "\u0001".repeat(10_000),
                    ),
                ),
            ),
            derived = RemoteDerivedRows(
                sleep = listOf(
                    SleepSession("my-whoop-noop", 100, 200, efficiency = 0.9),
                    SleepSession(
                        "my-whoop-noop",
                        300L,
                        300L + 3L * 86_400L,
                        efficiency = 0.9,
                    ),
                ),
                workouts = listOf(
                    WorkoutRow("my-whoop-noop", 500, 600, "Run", "local"),
                    WorkoutRow(
                        "my-whoop-noop",
                        700L,
                        700L + 3L * 86_400L,
                        "Ride",
                        "local",
                    ),
                ),
            ),
        )

        assertEquals(listOf(100L), draft.sleepSessions.map(RemoteSleepSession::startTs))
        assertEquals(listOf("Run"), draft.workouts.map(RemoteWorkout::sport))
        val event = draft.streams.events.single()
        assertEquals("unknown", event.kind)
        assertEquals("true", event.metadata["original_kind_blank"])
        assertEquals("true", event.metadata["payload_truncated"])
        assertTrue(
            JSONObject(event.metadata).toString().toByteArray(StandardCharsets.UTF_8).size <= 16_384,
        )
    }

    @Test
    fun derivedHistoryResumesWithNaturalKeysAfterEarlierRowsAreDeleted() = runTest {
        val base = 1_800_000_000L
        val store = FakeStore(
            derivedRows = RemoteDerivedRows(
                sleep = (0..5_000).map { index ->
                    SleepSession(
                        deviceId = "my-whoop-noop",
                        startTs = base + index,
                        endTs = base + index + 60,
                        efficiency = 0.9,
                    )
                },
            ),
        )
        val state = FakeIdentities()
        val uploads = mutableListOf<RemoteEnvelope>()
        val coordinator = RemoteSyncCoordinator(
            store,
            object : RemoteSyncUploading {
                override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck {
                    uploads += envelope
                    return RemoteSyncAck(envelope.batchId, "accepted", false, emptyMap())
                }
            },
            state,
            state,
        )
        val derivedNamespace = namespace.copy(
            remoteDeviceId = "android:install-1:my-whoop-noop-cer-v1",
            logicalSourceId = "my-whoop-noop",
            localDeviceId = "my-whoop-noop",
            role = "noop_computed",
            includeRaw = false,
            includeDerived = true,
        )

        val first = coordinator.sync(derivedNamespace, maxBatches = 1)
        assertTrue(first.hasMoreDerivedRows)
        assertEquals(
            base + 4_999,
            state.derivedCursor("android:install-1:my-whoop-noop-cer-v1").sleepStartTs,
        )

        // Deleting a row before the watermark would shift a persisted OFFSET and skip the final row.
        store.derivedRows = store.derivedRows.copy(sleep = store.derivedRows.sleep.drop(1))
        val second = coordinator.sync(derivedNamespace, maxBatches = 2)

        assertFalse(second.hasMoreDerivedRows)
        assertEquals(base + 5_000, uploads.last().draft.sleepSessions.single().startTs)
        assertEquals(
            RemoteDerivedCursor(),
            state.derivedCursor("android:install-1:my-whoop-noop-cer-v1"),
        )
    }

    @Test
    fun fixedReplayWindowAndCompletedNamespacesSurviveCoordinatorRestart() = runTest {
        val base = 1_800_000_000L
        val window = RemoteDerivedWindow.endingAt(
            now = Instant.ofEpochSecond(base),
            historyDays = 3_650,
            zoneId = ZoneOffset.UTC,
        )
        val completedNamespace = namespace.copy(
            remoteDeviceId = "android:install-1:oura-import",
            logicalSourceId = "oura-import",
            localDeviceId = "oura-import",
            role = "wearable_import",
            includeRaw = false,
            includeDerived = true,
        )
        val drainingNamespace = namespace.copy(
            remoteDeviceId = "android:install-1:fitbit-import",
            logicalSourceId = "fitbit-import",
            localDeviceId = "fitbit-import",
            role = "wearable_import",
            includeRaw = false,
            includeDerived = true,
        )
        val completedStore = FakeStore(
            derivedRows = RemoteDerivedRows(
                sleep = listOf(
                    SleepSession("oura-import", base - 100, base - 40, efficiency = 0.9),
                ),
            ),
        )
        val drainingStore = FakeStore(
            derivedRows = RemoteDerivedRows(
                sleep = (0..5_000).map { index ->
                    SleepSession(
                        deviceId = "fitbit-import",
                        startTs = base - 10_000 + index,
                        endTs = base - 9_940 + index,
                        efficiency = 0.9,
                    )
                },
            ),
        )
        val state = FakeIdentities()
        val firstUploads = mutableListOf<RemoteEnvelope>()
        val firstCoordinator = RemoteSyncCoordinator(
            completedStore,
            recordingUploader(firstUploads),
            state,
            state,
        )

        val completedResult = firstCoordinator.sync(
            namespace = completedNamespace,
            now = Instant.ofEpochSecond(base),
            derivedWindow = window,
            retainDerivedCompletion = true,
            maxBatches = 1,
        )
        assertFalse(completedResult.hasMoreDerivedRows)
        assertTrue(state.derivedCursor(completedNamespace.remoteDeviceId).isComplete)

        val drainingFirst = RemoteSyncCoordinator(
            drainingStore,
            recordingUploader(firstUploads),
            state,
            state,
        ).sync(
            namespace = drainingNamespace,
            now = Instant.ofEpochSecond(base),
            derivedWindow = window,
            retainDerivedCompletion = true,
            maxBatches = 1,
        )
        assertTrue(drainingFirst.hasMoreDerivedRows)
        assertFalse(state.derivedCursor(drainingNamespace.remoteDeviceId).isComplete)

        // Simulate a later process/worker with a moving "now". The completed namespace must stay
        // skipped, while the unfinished namespace resumes against the exact original replay bounds.
        val restartedUploads = mutableListOf<RemoteEnvelope>()
        val completedDerivedReads = completedStore.derivedQueries.size
        val restartedCompleted = RemoteSyncCoordinator(
            completedStore,
            recordingUploader(restartedUploads),
            state,
            state,
        ).sync(
            namespace = completedNamespace,
            now = Instant.ofEpochSecond(base + 86_400),
            derivedWindow = window,
            retainDerivedCompletion = true,
            maxBatches = 2,
        )
        assertFalse(restartedCompleted.hasMoreDerivedRows)
        assertTrue(restartedUploads.isEmpty())
        assertEquals(completedDerivedReads, completedStore.derivedQueries.size)

        val restartedDraining = RemoteSyncCoordinator(
            drainingStore,
            recordingUploader(restartedUploads),
            state,
            state,
        ).sync(
            namespace = drainingNamespace,
            now = Instant.ofEpochSecond(base + 86_400),
            derivedWindow = window,
            retainDerivedCompletion = true,
            maxBatches = 2,
        )
        assertFalse(restartedDraining.hasMoreDerivedRows)
        assertTrue(state.derivedCursor(drainingNamespace.remoteDeviceId).isComplete)
        assertEquals(
            setOf(window),
            drainingStore.derivedQueries.map(DerivedQuery::window).toSet(),
        )
        assertEquals(base - 5_000, restartedUploads.single().draft.sleepSessions.single().startTs)
    }

    @Test
    fun normalRefreshClearsAReplayCompletionMarkerAndUsesRolling400Days() = runTest {
        val now = Instant.parse("2026-07-24T12:00:00Z")
        val derivedNamespace = namespace.copy(
            remoteDeviceId = "android:install-1:oura-import",
            logicalSourceId = "oura-import",
            localDeviceId = "oura-import",
            role = "wearable_import",
            includeRaw = false,
            includeDerived = true,
        )
        val state = FakeIdentities().apply {
            setDerivedCursor(
                derivedNamespace.remoteDeviceId,
                RemoteDerivedCursor(started = true, isComplete = true),
            )
        }
        val store = FakeStore(
            derivedRows = RemoteDerivedRows(
                sleep = listOf(
                    SleepSession(
                        "oura-import",
                        now.epochSecond - 60,
                        now.epochSecond,
                        efficiency = 0.9,
                    ),
                ),
            ),
        )
        val uploads = mutableListOf<RemoteEnvelope>()

        val result = RemoteSyncCoordinator(
            store,
            recordingUploader(uploads),
            state,
            state,
        ).sync(
            namespace = derivedNamespace,
            now = now,
            maxBatches = 1,
        )

        assertFalse(result.hasMoreDerivedRows)
        assertEquals(1, uploads.size)
        assertEquals(
            RemoteDerivedWindow.endingAt(now, 400),
            store.derivedQueries.single().window,
        )
        assertEquals(RemoteDerivedCursor(), state.derivedCursor(derivedNamespace.remoteDeviceId))
    }

    @Test
    fun namespaceCatalogSeparatesRawOfficialAndNoopScores() {
        val rows = RemoteNamespaceCatalog.forActiveDevice(
            activeDeviceId = "my-whoop",
            pairedDeviceIds = listOf("my-whoop"),
            appVersion = "1",
            installationId = "install",
            firmwareVersion = null,
        )
        val byRole = rows.groupBy(RemoteNamespace::role)
        val strap = byRole.getValue("strap_measured").single()
        assertEquals("android:install:my-whoop-strap", strap.remoteDeviceId)
        assertEquals("my-whoop-strap", strap.logicalSourceId)
        assertEquals(
            "android:install:whoop-official-reference",
            byRole.getValue("official_reference").single().remoteDeviceId,
        )
        assertTrue(
            byRole.getValue("noop_computed")
                .any { it.remoteDeviceId == "android:install:my-whoop-noop-cer-v1" },
        )
        assertTrue(byRole.getValue("strap_measured").all { it.includeRaw && !it.includeDerived })
        assertTrue(
            listOf(
                "official_reference",
                "noop_computed",
                "noop_journal",
                "apple_health_import",
                "health_connect_import",
                "activity_file_import",
                "wearable_import",
            ).all { role -> byRole.getValue(role).all { !it.includeRaw && it.includeDerived } },
        )
        assertEquals(
            setOf("xiaomi-band", "oura-import", "fitbit-import", "garmin-import"),
            byRole.getValue("wearable_import").map(RemoteNamespace::localDeviceId).toSet(),
        )
        val excludedV1Sources = setOf(
            "lab-book",
            "lab-csv",
            "nutrition-csv",
            "hydration",
            "noop-mood",
            "lifting",
            "oura-api-raw",
        )
        assertTrue(rows.none { it.localDeviceId in excludedV1Sources })
        assertTrue(rows.all { it.remoteDeviceId.length <= 128 })
        val otherInstallationIds = RemoteNamespaceCatalog.forActiveDevice(
                activeDeviceId = "my-whoop",
                pairedDeviceIds = listOf("my-whoop"),
                appVersion = "1",
                installationId = "other-install",
                firmwareVersion = null,
            ).map(RemoteNamespace::remoteDeviceId).toSet()
        assertTrue(
            (otherInstallationIds intersect rows.map(RemoteNamespace::remoteDeviceId).toSet())
                .isEmpty(),
        )
        val fallbackId = RemoteNamespaceCatalog.scopedRemoteId(
            installationId = "install id 🔐".repeat(12),
            logicalRemoteId = "legacy source / ".repeat(20),
        )
        assertTrue(fallbackId.length <= 128)
        assertTrue(fallbackId.matches(Regex("""[A-Za-z0-9][A-Za-z0-9._:-]*""")))
    }

    @Test
    fun wearableNamespacesUseServerAcceptedProvenanceAndUnknownRolesFailClosed() {
        val state = FakeIdentities()
        val coordinator = RemoteSyncCoordinator(FakeStore(), NoopUploader, state, state)
        val wearable = namespace.copy(
            remoteDeviceId = "android:install-1:oura-import",
            logicalSourceId = "oura-import",
            localDeviceId = "oura-import",
            role = "wearable_import",
            includeRaw = false,
            includeDerived = true,
        )

        val draft = coordinator.buildDraft(
            wearable,
            paired = null,
            pending = PendingRemoteStreams(),
            derived = RemoteDerivedRows(),
        )
        assertEquals("wearable_import", draft.source.metadata["namespace"])
        assertEquals("user_imported_wearable", draft.source.metadata["score_provenance"])

        assertThrows(RemoteSyncConfigurationException::class.java) {
            coordinator.buildDraft(
                wearable.copy(role = "future_unreviewed_role"),
                paired = null,
                pending = PendingRemoteStreams(),
                derived = RemoteDerivedRows(),
            )
        }
    }

    private object NoopUploader : RemoteSyncUploading {
        override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck =
            RemoteSyncAck(envelope.batchId, "accepted", false, emptyMap())
    }

    private fun recordingUploader(envelopes: MutableList<RemoteEnvelope>): RemoteSyncUploading =
        object : RemoteSyncUploading {
            override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck {
                envelopes += envelope
                return RemoteSyncAck(envelope.batchId, "accepted", false, emptyMap())
            }
        }

    private class FakeIdentities : RemoteBatchIdentityStore, RemoteDerivedCursorStore {
        val saved = linkedMapOf<String, RemoteBatchIdentity>()
        val derivedCursors = linkedMapOf<String, RemoteDerivedCursor>()
        override fun resolve(fingerprint: String, now: Instant): RemoteBatchIdentity =
            saved.getOrPut(fingerprint) {
                RemoteBatchIdentity(UUID.randomUUID().toString(), now.toString())
            }

        override fun acknowledge(fingerprint: String) {
            saved.remove(fingerprint)
        }

        override fun derivedCursor(remoteDeviceId: String): RemoteDerivedCursor =
            derivedCursors[remoteDeviceId] ?: RemoteDerivedCursor()

        override fun setDerivedCursor(remoteDeviceId: String, cursor: RemoteDerivedCursor) {
            derivedCursors[remoteDeviceId] = cursor
        }

        override fun clearDerivedCursor(remoteDeviceId: String) {
            derivedCursors.remove(remoteDeviceId)
        }
    }

    private class FakeStore(
        var pendingRows: PendingRemoteStreams = PendingRemoteStreams(),
        var derivedRows: RemoteDerivedRows = RemoteDerivedRows(),
    ) : RemoteSyncDataStore {
        val acknowledged = mutableListOf<PendingRemoteStreams>()
        val derivedQueries = mutableListOf<DerivedQuery>()

        override suspend fun pending(deviceId: String, limitPerStream: Int): PendingRemoteStreams =
            pendingRows

        override suspend fun acknowledge(deviceId: String, rows: PendingRemoteStreams) {
            acknowledged += rows
            pendingRows = PendingRemoteStreams()
        }

        override suspend fun reset(deviceIds: Set<String>) = Unit
        override suspend fun hasPending(deviceId: String): Boolean = !pendingRows.isEmpty
        override suspend fun derived(
            deviceId: String,
            fromTs: Long,
            toTs: Long,
            fromDay: String,
            toDay: String,
            cursor: RemoteDerivedCursor,
            limit: Int,
            includeDaily: Boolean,
        ): RemoteDerivedRows {
            derivedQueries += DerivedQuery(
                RemoteDerivedWindow(fromTs, toTs, fromDay, toDay),
                cursor,
            )
            return RemoteDerivedRows(
                daily = if (includeDaily) derivedRows.daily else emptyList(),
                platformDaily = if (includeDaily) derivedRows.platformDaily else emptyList(),
                sleep = derivedRows.sleep.filter { row ->
                    cursor.sleepStartTs?.let { row.startTs > it } ?: true
                }.take(limit),
                workouts = derivedRows.workouts.filter { row ->
                    cursor.workoutStartTs?.let { afterStartTs ->
                        row.startTs > afterStartTs ||
                            (row.startTs == afterStartTs &&
                                row.sport > cursor.workoutSport.orEmpty())
                    } ?: true
                }.take(limit),
                journal = derivedRows.journal.filter { row ->
                    cursor.journalDay?.let { afterDay ->
                        row.day > afterDay ||
                            (row.day == afterDay &&
                                row.question > cursor.journalQuestion.orEmpty())
                    } ?: true
                }.take(limit),
            )
        }

        override suspend fun pairedDevice(deviceId: String): PairedDeviceRow? = null
        override suspend fun pairedDevices(): List<PairedDeviceRow> = emptyList()
    }

    private data class DerivedQuery(
        val window: RemoteDerivedWindow,
        val cursor: RemoteDerivedCursor,
    )
}
