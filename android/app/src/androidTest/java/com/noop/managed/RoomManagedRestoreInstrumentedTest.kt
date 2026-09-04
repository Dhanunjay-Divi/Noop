package com.noop.managed

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.HrSample
import com.noop.data.ManagedSyncSourceEntity
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Base64
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RoomManagedRestoreInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var restore: RoomManagedRestoreApplier

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        restore = RoomManagedRestoreApplier(
            database = database,
            clock = { 1_800_000_000_000 },
        )
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun restoresAllFiveChunkClasses() = runBlocking {
        val essential = restore.applyChunk(
            chunk(
                "essential_timeseries",
                listOf(
                    stream(
                        "heart_rate",
                        HEART_RATE_COLUMNS,
                        row(i(TS), i(68), nil(), s("sensor")),
                    ),
                ),
            ),
        )
        val auxiliary = restore.applyChunk(
            chunk(
                "raw_auxiliary",
                listOf(stream("skin_temperature_adc", ADC_COLUMNS, row(i(TS), i(3_200)))),
            ),
        )
        val ppg = restore.applyChunk(
            chunk(
                "raw_ppg",
                listOf(
                    stream(
                        "spo2_optical_adc",
                        listOf("event_at_ms", "red_adc", "infrared_adc"),
                        row(i(TS), i(500), i(450)),
                    ),
                ),
            ),
        )
        val motion = restore.applyChunk(
            chunk(
                "raw_motion",
                listOf(
                    stream(
                        "gravity",
                        listOf("event_at_ms", "x_g", "y_g", "z_g"),
                        row(i(TS), n(0.0), n(0.0), n(1.0)),
                    ),
                ),
            ),
        )
        val derived = restore.applyChunk(
            chunk(
                "derived_summaries",
                listOf(
                    stream(
                        "metric_series",
                        METRIC_SERIES_COLUMNS,
                        row(
                            i(TS),
                            s("2026-09-03"),
                            s("recovery"),
                            n(72.5),
                            s("source"),
                            i(TS),
                            b(false),
                        ),
                    ),
                ),
            ),
        )

        assertEquals(1, count("hrSample", essential.localSourceId))
        assertEquals(1, count("skinTempSample", auxiliary.localSourceId))
        assertEquals(1, count("spo2Sample", ppg.localSourceId))
        assertEquals(1, count("gravitySample", motion.localSourceId))
        assertEquals(1, count("metricSeries", derived.localSourceId))
    }

    @Test
    fun ownCloudEchoCannotOverwriteFresherLocalStrapData() = runBlocking {
        val sourceId = UUID.randomUUID()
        val localSource = "strap"
        database.whoopDao().insertHr(listOf(HrSample(localSource, TS / 1_000, 77)))
        database.managedSyncDao().upsertSource(
            ManagedSyncSourceEntity(
                sourceId = sourceId.toString(),
                localSourceId = localSource,
                sourceKind = "live_ble",
                platform = "android",
                logicalSourceHash = "a".repeat(64),
                createdAtMs = TS,
                updatedAtMs = TS,
            ),
        )

        val result = restore.applyChunk(
            chunk(
                "essential_timeseries",
                listOf(
                    stream(
                        "heart_rate",
                        HEART_RATE_COLUMNS,
                        row(i(TS), i(99), nil(), s("sensor")),
                    ),
                ),
                sourceId,
            ),
        )

        assertEquals(localSource, result.localSourceId)
        assertEquals(0, result.appliedRows)
        assertEquals(77, long(
            "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = ?",
            localSource,
            TS / 1_000,
        ))
    }

    @Test
    fun hydrationRestoresCloudBaseAndOverlaysLateLocalRows() = runBlocking {
        val sourceId = UUID.randomUUID()
        val localSource = "strap"
        database.managedSyncDao().upsertSource(
            ManagedSyncSourceEntity(
                sourceId = sourceId.toString(),
                localSourceId = localSource,
                sourceKind = "live_ble",
                platform = "android",
                logicalSourceHash = "a".repeat(64),
                createdAtMs = TS,
                updatedAtMs = TS,
            ),
        )
        database.openHelper.writableDatabase.execSQL(
            """
                INSERT INTO hrSample (deviceId, ts, bpm, synced)
                VALUES (?, ?, 72, 0)
            """.trimIndent(),
            arrayOf<Any?>(localSource, TS / 1_000 + 1),
        )
        database.openHelper.writableDatabase.execSQL(
            """
                INSERT INTO bodyMeasurement (
                    deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                    userId, unit, source
                ) VALUES (?, ?, ?, 80, 24, 181, -1, 'kg', 'manual')
            """.trimIndent(),
            arrayOf<Any?>(localSource, TS / 1_000, TS / 1_000),
        )
        val dirtyBefore = long("SELECT COUNT(*) FROM managedDirtyWindow")

        val result = restore.hydrateChunk(
            chunk("essential_timeseries", essentialSnapshot(68), sourceId),
            localSource,
        )

        assertEquals(localSource, result.localSourceId)
        assertEquals(
            listOf(68L, 72L),
            longs(
                "SELECT bpm FROM hrSample WHERE deviceId = ? ORDER BY ts",
                localSource,
            ),
        )
        assertEquals(80L, long(
            "SELECT CAST(weightKg AS INTEGER) FROM bodyMeasurement " +
                "WHERE deviceId = ? AND measuredAt = ?",
            localSource,
            TS / 1_000,
        ))
        assertEquals(dirtyBefore, long("SELECT COUNT(*) FROM managedDirtyWindow"))
        assertEquals(0L, long("SELECT COUNT(*) FROM managedPruneGuard"))
    }

    @Test
    fun laterRevisionUpdatesNaturalKeyAndFullEmptySnapshotDeletesIt() = runBlocking {
        val sourceId = UUID.randomUUID()
        val first = restore.applyChunk(
            chunk("essential_timeseries", essentialSnapshot(68), sourceId),
        )
        restore.applyChunk(
            chunk("essential_timeseries", essentialSnapshot(69), sourceId),
        )
        assertEquals(69, long(
            "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = ?",
            first.localSourceId,
            TS / 1_000,
        ))

        restore.applyChunk(
            chunk("essential_timeseries", essentialSnapshot(null), sourceId),
        )
        assertEquals(0, count("hrSample", first.localSourceId))
    }

    @Test
    fun malformedRowRollsBackEarlierRowsAndSourceRegistration() {
        val sourceId = UUID.randomUUID()
        val invalidChunk = chunk(
            "essential_timeseries",
            listOf(
                stream(
                    "heart_rate",
                    HEART_RATE_COLUMNS,
                    row(i(TS), i(68), nil(), s("sensor")),
                ),
                stream(
                    "rr_intervals",
                    RR_COLUMNS,
                    row(i(TS), i(10), i(0), nil(), nil(), b(false)),
                ),
            ),
            sourceId,
        )

        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            runBlocking { restore.applyChunk(invalidChunk) }
        }
        assertEquals(0, total("hrSample"))
        assertEquals(0, long(
            "SELECT COUNT(*) FROM managedSyncSource WHERE sourceId = ?",
            sourceId.toString(),
        ))
    }

    @Test
    fun packedWaveformLengthMustMatchDeclaredSampleCount() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val invalidChunk = chunk(
            "raw_ppg",
            listOf(
                stream(
                    "ppg_waveform",
                    listOf(
                        "event_at_ms",
                        "sample_rate_hz",
                        "sample_count",
                        "samples_base64",
                    ),
                    row(
                        i(TS),
                        n(24.0),
                        i(3),
                        s(Base64.getEncoder().encodeToString(bytes)),
                    ),
                ),
            ),
        )

        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            runBlocking { restore.applyChunk(invalidChunk) }
        }
        assertEquals(0, total("ppgWaveformSample"))
    }

    private fun essentialSnapshot(bpm: Long?): List<ManagedChunkStreamPayload> = listOf(
        stream(
            "heart_rate",
            HEART_RATE_COLUMNS,
            bpm?.let { row(i(TS), i(it), nil(), s("sensor")) },
        ),
        stream("rr_intervals", RR_COLUMNS),
        stream("battery", listOf("event_at_ms", "percent", "millivolts", "charging")),
        stream(
            "derived_heart_rate",
            listOf("event_at_ms", "bpm", "confidence", "algorithm_revision"),
        ),
        stream("device_events", listOf("event_at_ms", "kind", "payload_json")),
        stream("step_counter", listOf("event_at_ms", "counter", "activity_class")),
        stream(
            "body_measurement",
            listOf("event_at_ms", "weight_kg", "bmi", "height_cm", "user_id", "source"),
        ),
    )

    private fun chunk(
        dataClass: String,
        streams: List<ManagedChunkStreamPayload>,
        sourceId: UUID = UUID.randomUUID(),
    ): ManagedChunkPayload {
        val prepared = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                dataClass,
                WINDOW_START,
                WINDOW_END,
                streams,
            ),
        )
        return ManagedChunkPayload(
            chunkId = prepared.chunkId,
            sourceId = sourceId,
            dataClass = dataClass,
            schemaVersion = 1,
            eventStartMs = WINDOW_START,
            eventEndMs = WINDOW_END,
            streams = prepared.streams,
        )
    }

    private fun stream(
        key: String,
        columns: List<String>,
        vararg rows: List<ManagedJsonValue>?,
    ) = ManagedChunkStreamPayload(key, columns, rows.filterNotNull())

    private fun row(vararg values: ManagedJsonValue) = values.toList()
    private fun i(value: Long) = ManagedJsonValue.IntegerValue(value)
    private fun n(value: Double) = ManagedJsonValue.NumberValue(value)
    private fun s(value: String) = ManagedJsonValue.StringValue(value)
    private fun b(value: Boolean) = ManagedJsonValue.BooleanValue(value)
    private fun nil() = ManagedJsonValue.NullValue

    private fun count(table: String, source: String): Long =
        long("SELECT COUNT(*) FROM $table WHERE deviceId = ?", source)

    private fun total(table: String): Long = long("SELECT COUNT(*) FROM $table")

    private fun long(sql: String, vararg arguments: Any): Long =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(sql, arguments),
        ).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getLong(0)
        }

    private fun longs(sql: String, vararg arguments: Any): List<Long> =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(sql, arguments),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getLong(0))
            }
        }

    companion object {
        private const val TS = 1_788_436_800_000L
        private const val WINDOW_START = TS
        private const val WINDOW_END = TS + 3_599_999L
        private val HEART_RATE_COLUMNS =
            listOf("event_at_ms", "bpm", "quality", "provenance")
        private val ADC_COLUMNS = listOf("event_at_ms", "adc")
        private val RR_COLUMNS = listOf(
            "event_at_ms",
            "rr_ms",
            "seq",
            "ord",
            "source_channel",
            "timestamp_suspect",
        )
        private val METRIC_SERIES_COLUMNS = listOf(
            "event_at_ms",
            "day",
            "metric_key",
            "value",
            "source_id",
            "updated_at_ms",
            "deleted",
        )
    }
}
