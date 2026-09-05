package com.noop.managed

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.ManagedSyncSourceEntity
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RoomManagedSyncStateStoreInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var state: RoomManagedSyncStateStore

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        WhoopDatabase.installManagedDirtyWindowTriggers(
            database.openHelper.writableDatabase,
        )
        state = RoomManagedSyncStateStore(database, SCOPE) { 10_000L }
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun dirtyTriggerAdvancesOnlyOnceAfterClaim() = runBlocking {
        registerSource()
        exec(
            "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, 100, 68, 0)",
            SOURCE,
        )
        exec("UPDATE hrSample SET synced = 1 WHERE deviceId = ?", SOURCE)
        val generation = state.claimWindowGeneration(
            SOURCE_ID,
            SOURCE,
            "essential_timeseries",
            ManagedSyncWindow(0, WINDOW_MS),
        )
        assertEquals(1L, generation)

        exec("UPDATE hrSample SET bpm = 69 WHERE deviceId = ?", SOURCE)
        exec("UPDATE hrSample SET bpm = 70 WHERE deviceId = ?", SOURCE)

        assertEquals(2L, long(
            "SELECT generation FROM managedDirtyWindow " +
                "WHERE localSourceId = ? AND dataClass = 'essential_timeseries'",
            SOURCE,
        ))
        assertEquals(1L, long(
            "SELECT claimedGeneration FROM managedDirtyWindow " +
                "WHERE localSourceId = ? AND dataClass = 'essential_timeseries'",
            SOURCE,
        ))
    }

    @Test
    fun onlyValidatedUnchangedWindowPrunesAndBodyMeasurementStays() = runBlocking {
        registerSource()
        exec(
            "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, 100, 68, 0)",
            SOURCE,
        )
        exec(
            """
                INSERT INTO bodyMeasurement (
                    deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                    userId, unit, source
                ) VALUES (?, 100, 100, 72, 22, 181, -1, 'kg', 'manual')
            """.trimIndent(),
            SOURCE,
        )
        val generation = state.claimWindowGeneration(
            SOURCE_ID,
            SOURCE,
            "essential_timeseries",
            ManagedSyncWindow(0, WINDOW_MS),
        )
        val chunkId = UUID.fromString("22222222-2222-5222-8222-222222222222")
        state.saveWindowUpload(
            ManagedWindowUpload(
                windowEndMs = WINDOW_MS - 1,
                chunkId = chunkId,
                rowCount = 2,
                phase = ManagedWindowUploadPhase.AWAITING_VALIDATION,
                snapshotGeneration = generation,
            ),
            SOURCE_ID,
            "essential_timeseries",
            0,
        )

        assertEquals(
            0,
            state.pruneAvailableWindows(
                SOURCE_ID,
                SOURCE,
                "essential_timeseries",
                WINDOW_MS + 1,
                4,
            ).prunedWindows,
        )
        assertTrue(state.acknowledgeAvailableChunk(
            SOURCE_ID,
            "essential_timeseries",
            0,
            WINDOW_MS - 1,
            chunkId,
        ))
        val pruned = state.pruneAvailableWindows(
            SOURCE_ID,
            SOURCE,
            "essential_timeseries",
            WINDOW_MS + 1,
            4,
        )

        assertEquals(1, pruned.prunedWindows)
        assertEquals(1, pruned.deletedRows)
        assertEquals(0L, long("SELECT COUNT(*) FROM hrSample WHERE deviceId = ?", SOURCE))
        assertEquals(
            1L,
            long("SELECT COUNT(*) FROM bodyMeasurement WHERE deviceId = ?", SOURCE),
        )
        assertEquals(0L, long("SELECT COUNT(*) FROM managedDirtyWindow"))
        assertNotNull(
            database.managedSyncDao()
                .windowUpload(SCOPE, SOURCE_ID.toString(), "essential_timeseries", 0)
                ?.localPrunedAtMs,
        )
    }

    @Test
    fun validatedRawWindowsPruneMappedRowsAndKeepDailySummary() = runBlocking {
        registerSource()
        listOf(
            "INSERT INTO skinTempSample (deviceId, ts, raw, synced) VALUES (?, 100, 1, 0)",
            "INSERT INTO respSample (deviceId, ts, raw, synced) VALUES (?, 100, 2, 0)",
            "INSERT INTO sleepStateSample (deviceId, ts, state, synced) VALUES (?, 100, 1, 0)",
            "INSERT INTO spo2Sample (deviceId, ts, red, ir, synced) VALUES (?, 100, 3, 4, 0)",
            "INSERT INTO ppgWaveformSample (deviceId, ts, samples, synced) VALUES (?, 100, X'0001', 0)",
            "INSERT INTO gravitySample (deviceId, ts, x, y, z, synced) VALUES (?, 100, 0, 0, 1, 0)",
            "INSERT INTO rawImuSample (deviceId, ts, samples) VALUES (?, 100, X'0001')",
        ).forEach { exec(it, SOURCE) }
        exec(
            "INSERT INTO dailyMetric (deviceId, day) VALUES (?, '1970-01-01')",
            SOURCE,
        )

        data class RawClass(val name: String, val rows: Int, val chunkId: UUID)
        val classes = listOf(
            RawClass(
                "raw_auxiliary",
                3,
                UUID.fromString("22222222-2222-5222-8222-222222222221"),
            ),
            RawClass(
                "raw_ppg",
                2,
                UUID.fromString("22222222-2222-5222-8222-222222222222"),
            ),
            RawClass(
                "raw_motion",
                2,
                UUID.fromString("22222222-2222-5222-8222-222222222223"),
            ),
        )
        classes.forEach { item ->
            val generation = state.claimWindowGeneration(
                SOURCE_ID,
                SOURCE,
                item.name,
                ManagedSyncWindow(0, RAW_WINDOW_MS),
            )
            state.saveWindowUpload(
                ManagedWindowUpload(
                    windowEndMs = RAW_WINDOW_MS - 1,
                    chunkId = item.chunkId,
                    rowCount = item.rows,
                    phase = ManagedWindowUploadPhase.AWAITING_VALIDATION,
                    snapshotGeneration = generation,
                ),
                SOURCE_ID,
                item.name,
                0,
            )
            assertTrue(
                state.acknowledgeAvailableChunk(
                    SOURCE_ID,
                    item.name,
                    0,
                    RAW_WINDOW_MS - 1,
                    item.chunkId,
                ),
            )
            val result = state.pruneAvailableWindows(
                SOURCE_ID,
                SOURCE,
                item.name,
                RAW_WINDOW_MS + 1,
                4,
            )
            assertEquals(item.name, 1, result.prunedWindows)
            assertEquals(item.name, item.rows, result.deletedRows)
        }

        listOf(
            "skinTempSample",
            "respSample",
            "sleepStateSample",
            "spo2Sample",
            "ppgWaveformSample",
            "gravitySample",
            "rawImuSample",
        ).forEach { table ->
            assertEquals(
                table,
                0L,
                long("SELECT COUNT(*) FROM $table WHERE deviceId = ?", SOURCE),
            )
        }
        assertEquals(
            1L,
            long("SELECT COUNT(*) FROM dailyMetric WHERE deviceId = ?", SOURCE),
        )
    }

    @Test
    fun snapshotRestoreCheckpointRoundTripsAndFinishCannotRegressCursor() = runBlocking {
        val checkpoint = ManagedSnapshotRestoreCheckpoint(
            requestId = UUID.fromString("11111111-1111-5111-8111-111111111111"),
            dataClasses = listOf("essential_timeseries", "raw_ppg"),
            restoreJobId = UUID.fromString("22222222-2222-5222-8222-222222222222"),
            snapshotAt = "2026-09-01T00:00:00Z",
            changeSequence = 42,
            selectedObjects = 3,
            selectedBytes = 1_024,
            dataClassIndex = 1,
            cursor = ManagedChunkCursor(
                "2026-08-31T23:00:00Z",
                UUID.fromString("33333333-3333-5333-8333-333333333333"),
            ),
            documentCursor = ManagedDocumentCursor(
                "2026-09-01T00:30:00Z",
                ManagedDocumentKind.JOURNAL,
                UUID.fromString("44444444-4444-5444-8444-444444444444"),
            ),
            documentsComplete = false,
            deliveredObjects = 2,
            deliveredBytes = 768,
        )
        state.saveSnapshotRestoreCheckpoint(checkpoint)
        assertEquals(checkpoint, state.snapshotRestoreCheckpoint())

        state.finishSnapshotRestore(42)
        assertEquals(42L, state.changeSequence())
        assertNull(state.snapshotRestoreCheckpoint())

        state.saveSnapshotRestoreCheckpoint(checkpoint)
        state.finishSnapshotRestore(7)
        assertEquals(42L, state.changeSequence())
        assertNull(state.snapshotRestoreCheckpoint())
    }

    private suspend fun registerSource() {
        database.managedSyncDao().upsertSource(
            ManagedSyncSourceEntity(
                sourceId = SOURCE_ID.toString(),
                localSourceId = SOURCE,
                sourceKind = "live_ble",
                platform = "android",
                logicalSourceHash = "a".repeat(64),
                createdAtMs = 1,
                updatedAtMs = 1,
            ),
        )
    }

    private fun exec(sql: String, vararg arguments: Any) {
        database.openHelper.writableDatabase.execSQL(sql, arguments)
    }

    private fun long(sql: String, vararg arguments: Any): Long =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(sql, arguments),
        ).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getLong(0)
        }

    companion object {
        private const val SOURCE = "strap"
        private const val WINDOW_MS = 6 * 60 * 60 * 1_000L
        private const val RAW_WINDOW_MS = 60 * 60 * 1_000L
        private val SOURCE_ID =
            UUID.fromString("11111111-1111-5111-8111-111111111111")
        private val SCOPE = "b".repeat(64)
    }
}
