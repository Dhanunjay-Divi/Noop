package com.noop.managed

import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.util.Base64
import java.util.UUID
import kotlin.math.roundToLong

data class ManagedRestoreResult(
    val localSourceId: String,
    val appliedRows: Int,
)

class RoomManagedRestoreApplier(
    private val database: WhoopDatabase,
    private val clock: () -> Long = System::currentTimeMillis,
    private val documentRestore: ManagedDocumentRestoring? = null,
) : ManagedRestoreApplying {
    override suspend fun apply(chunk: ManagedChunkPayload, change: ManagedChange) {
        val canonical = ManagedChunkCodec.verifyCanonical(chunk)
        val metadata = change.chunk
        if (change.resourceKind != "chunk" ||
            change.operation != "available" ||
            change.resourceId != chunk.chunkId ||
            change.dataClass != chunk.dataClass ||
            parseInstant(change.eventStart) != chunk.eventStartMs ||
            parseInstant(change.eventEnd) != chunk.eventEndMs ||
            metadata == null ||
            metadata.chunkId != chunk.chunkId ||
            metadata.sourceId != chunk.sourceId ||
            metadata.schemaVersion != chunk.schemaVersion ||
            metadata.state != "available" ||
            metadata.contentMode != "server_readable" ||
            metadata.expectedUncompressedBytes != canonical.uncompressed.size ||
            change.contentSha256?.matches(SHA256) != true
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        applyChunk(chunk)
    }

    override suspend fun hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor,
    ) {
        val canonical = ManagedChunkCodec.verifyCanonical(chunk)
        if (canonical.chunkId != chunk.chunkId || chunk.sourceId != source.sourceId) {
            invalid()
        }
        hydrateChunk(chunk, source.localSourceId)
    }

    override suspend fun apply(document: ManagedDocument, change: ManagedChange) {
        val restorer = documentRestore ?: throw ManagedStorageException.InvalidResponse()
        val metadata = change.document
        if (change.resourceKind != "document" ||
            change.resourceId != document.documentId ||
            change.contentSha256 != document.contentSha256 ||
            !document.contentSha256.matches(SHA256) ||
            metadata == null ||
            metadata.documentKind != document.documentKind ||
            metadata.documentId != document.documentId ||
            metadata.revision != document.revision ||
            metadata.contentMode != document.contentMode ||
            metadata.clientKeyId != document.clientKeyId ||
            metadata.updatedAt != document.updatedAt ||
            metadata.deletedAt != document.deletedAt ||
            change.operation !in setOf("upsert", "tombstone")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        restorer.apply(document, change)
    }

    suspend fun applyChunk(chunk: ManagedChunkPayload): ManagedRestoreResult {
        validateEnvelope(chunk)
        return withContext(Dispatchers.IO) {
            var result: ManagedRestoreResult? = null
            database.runInTransaction {
                val db = database.openHelper.writableDatabase
                val source = restoreSource(db, chunk.sourceId, chunk.streams)
                if (!source.shouldApply) {
                    result = ManagedRestoreResult(source.localSourceId, 0)
                    return@runInTransaction
                }
                val validated = chunk.streams.sortedBy { it.streamKey }.map { stream ->
                    stream to validatedRows(stream, chunk)
                }
                var changed = 0
                val expectedStreams = STREAMS_BY_CLASS.getValue(chunk.dataClass)
                if (chunk.streams.map { it.streamKey }.toSet() == expectedStreams) {
                    changed += clearSnapshotWindow(db, chunk, source.localSourceId)
                }
                validated.forEach { (stream, rows) ->
                    changed += applyRows(db, stream.streamKey, rows, source.localSourceId)
                }
                result = ManagedRestoreResult(source.localSourceId, changed)
            }
            checkNotNull(result)
        }
    }

    suspend fun hydrateChunk(
        chunk: ManagedChunkPayload,
        localSourceId: String,
    ): ManagedRestoreResult {
        validateEnvelope(chunk)
        val allowed = STREAMS_BY_CLASS[chunk.dataClass] ?: invalid()
        if (chunk.dataClass == "derived_summaries" ||
            chunk.streams.map { it.streamKey }.toSet() != allowed ||
            localSourceId.isBlank()
        ) {
            invalid()
        }
        val validated = chunk.streams.sortedBy { it.streamKey }.map { stream ->
            stream to validatedRows(stream, chunk)
        }
        val prunableStreams = PRUNABLE_STREAMS_BY_CLASS[chunk.dataClass] ?: invalid()
        val tables = PRUNABLE_TABLES_BY_CLASS[chunk.dataClass] ?: invalid()

        return withContext(Dispatchers.IO) {
            var result: ManagedRestoreResult? = null
            database.runInTransaction {
                val db = database.openHelper.writableDatabase
                val canonicalSourceId = chunk.sourceId.toString().lowercase()
                val sourceMatches = db.query(
                    SimpleSQLiteQuery(
                        """
                            SELECT EXISTS(
                                SELECT 1 FROM managedSyncSource
                                WHERE sourceId = ? AND localSourceId = ?
                                  AND sourceKind != 'managed_restore'
                            )
                        """.trimIndent(),
                        arrayOf<Any?>(canonicalSourceId, localSourceId),
                    ),
                ).use { cursor -> cursor.moveToFirst() && cursor.getInt(0) == 1 }
                if (!sourceMatches) invalid()

                val fromSeconds = (chunk.eventStartMs + 999L) / 1_000L
                val throughSeconds = chunk.eventEndMs / 1_000L
                val backups = tables.associateWith { "managedHydrate_$it" }
                db.execSQL("INSERT OR IGNORE INTO managedPruneGuard (guardId) VALUES (1)")
                try {
                    backups.forEach { (table, backup) ->
                        db.execSQL("DROP TABLE IF EXISTS temp.$backup")
                        db.execSQL(
                            """
                                CREATE TEMP TABLE $backup AS
                                SELECT * FROM $table
                                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                            """.trimIndent(),
                            arrayOf<Any?>(localSourceId, fromSeconds, throughSeconds),
                        )
                        db.execSQL(
                            "DELETE FROM $table WHERE deviceId = ? AND ts >= ? AND ts <= ?",
                            arrayOf<Any?>(localSourceId, fromSeconds, throughSeconds),
                        )
                    }

                    var changed = 0
                    validated
                        .filter { (stream, _) -> stream.streamKey in prunableStreams }
                        .forEach { (stream, rows) ->
                            changed += applyRows(
                                db,
                                stream.streamKey,
                                rows,
                                localSourceId,
                                enforceRawImuRetention = false,
                            )
                        }
                    backups.forEach { (table, backup) ->
                        db.execSQL("INSERT OR REPLACE INTO $table SELECT * FROM temp.$backup")
                        changed += changes(db)
                    }
                    result = ManagedRestoreResult(localSourceId, changed)
                } finally {
                    backups.values.forEach { backup ->
                        db.execSQL("DROP TABLE IF EXISTS temp.$backup")
                    }
                    db.execSQL("DELETE FROM managedPruneGuard WHERE guardId = 1")
                }
            }
            checkNotNull(result)
        }
    }

    private fun validateEnvelope(chunk: ManagedChunkPayload) {
        if (chunk.schemaVersion != 1 ||
            chunk.eventStartMs < 0L ||
            chunk.eventEndMs < chunk.eventStartMs ||
            chunk.streams.isEmpty()
        ) {
            invalid()
        }
        val allowed = STREAMS_BY_CLASS[chunk.dataClass] ?: invalid()
        val keys = chunk.streams.map { it.streamKey }
        if (keys.distinct().size != keys.size ||
            !allowed.containsAll(keys) ||
            chunk.streams.any { it.schemaRevision != 1 } ||
            chunk.streams.sumOf { it.rows.size } > MAX_ROWS_PER_CHUNK
        ) {
            invalid()
        }
    }

    private fun validatedRows(
        stream: ManagedChunkStreamPayload,
        chunk: ManagedChunkPayload,
    ): List<RestoreRow> {
        val columns = COLUMNS[stream.streamKey] ?: invalid()
        if (stream.columns != columns) invalid()
        return stream.rows.map { values ->
            if (values.size != columns.size) invalid()
            RestoreRow(columns, values).also { row ->
                val event = row.requiredLong("event_at_ms")
                if (event !in chunk.eventStartMs..chunk.eventEndMs || event % 1_000 != 0L) {
                    invalid()
                }
            }
        }
    }

    private fun restoreSource(
        db: SupportSQLiteDatabase,
        sourceId: UUID,
        streams: List<ManagedChunkStreamPayload>,
    ): RestoreSource {
        val canonicalId = sourceId.toString().lowercase()
        db.query(
            SimpleSQLiteQuery(
                "SELECT localSourceId, sourceKind FROM managedSyncSource WHERE sourceId = ?",
                arrayOf<Any?>(canonicalId),
            ),
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                val local = cursor.getString(0)
                if (cursor.getString(1) != "managed_restore") {
                    return RestoreSource(local, false)
                }
                updateCapabilities(db, local, streams)
                return RestoreSource(local, true)
            }
        }

        val local = "noop-plus-$canonicalId"
        val nowMs = clock()
        val nowSeconds = nowMs / 1_000
        execute(
            db,
            """
                INSERT INTO managedSyncSource (
                    sourceId, localSourceId, sourceKind, platform, logicalSourceHash,
                    createdAtMs, updatedAtMs
                ) VALUES (?, ?, 'managed_restore', 'cloud', ?, ?, ?)
            """.trimIndent(),
            arrayOf<Any?>(
                canonicalId,
                local,
                ManagedDigest.sha256(canonicalId.toByteArray()),
                nowMs,
                nowMs,
            ),
        )
        execute(
            db,
            """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, NULL, 'NOOP+ synced source', ?, ?)
                ON CONFLICT(id) DO UPDATE SET lastSeen = excluded.lastSeen
            """.trimIndent(),
            arrayOf<Any?>(local, nowSeconds, nowSeconds),
        )
        execute(
            db,
            """
                INSERT INTO pairedDevice (
                    id, brand, model, nickname, peripheralId, sourceKind, capabilities,
                    status, addedAt, lastSeenAt
                ) VALUES (?, 'NOOP', 'NOOP+ synced source', NULL, NULL, 'cloudImport', ?,
                          'paired', ?, ?)
                ON CONFLICT(id) DO NOTHING
            """.trimIndent(),
            arrayOf<Any?>(local, capabilities(streams).sorted().joinToString(","), nowSeconds, nowSeconds),
        )
        return RestoreSource(local, true)
    }

    private fun updateCapabilities(
        db: SupportSQLiteDatabase,
        source: String,
        streams: List<ManagedChunkStreamPayload>,
    ) {
        val current = db.query(
            SimpleSQLiteQuery(
                "SELECT sourceKind, capabilities FROM pairedDevice WHERE id = ?",
                arrayOf<Any?>(source),
            ),
        ).use { cursor ->
            if (!cursor.moveToFirst() || cursor.getString(0) != "cloudImport") return
            cursor.getString(1).split(',').filter(String::isNotBlank).toSet()
        }
        execute(
            db,
            """
                UPDATE pairedDevice SET capabilities = ?, lastSeenAt = ?
                WHERE id = ? AND sourceKind = 'cloudImport'
            """.trimIndent(),
            arrayOf<Any?>(
                (current + capabilities(streams)).sorted().joinToString(","),
                clock() / 1_000,
                source,
            ),
        )
    }

    private fun capabilities(streams: List<ManagedChunkStreamPayload>): Set<String> =
        buildSet {
            streams.forEach {
                when (it.streamKey) {
                    "heart_rate", "derived_heart_rate" -> add("hr")
                    "rr_intervals" -> add("hrv")
                    "step_counter" -> add("steps")
                    "sleep_state", "sleep_summary" -> add("sleep")
                    "daily_metrics", "workout_summary", "live_session" -> add("strainLoad")
                }
            }
        }

    /**
     * A chunk carrying every registered stream for its class is an authoritative fixed-window snapshot.
     * Clear that imported source's prior window before inserting the revision so rows absent from a later
     * snapshot are actually removed. Partial legacy chunks retain merge-only behavior.
     */
    private fun clearSnapshotWindow(
        db: SupportSQLiteDatabase,
        chunk: ManagedChunkPayload,
        source: String,
    ): Int {
        val fromSeconds = (chunk.eventStartMs + 999L) / 1_000L
        val throughSeconds = chunk.eventEndMs / 1_000L
        var changed = 0
        fun clearSeconds(table: String, column: String = "ts") {
            execute(
                db,
                "DELETE FROM $table WHERE deviceId = ? AND $column >= ? AND $column <= ?",
                arrayOf<Any?>(source, fromSeconds, throughSeconds),
            )
            changed += changes(db)
        }
        when (chunk.dataClass) {
            "essential_timeseries" -> {
                clearSeconds("hrSample")
                clearSeconds("rrInterval")
                clearSeconds("battery")
                clearSeconds("ppgHrSample")
                clearSeconds("event")
                clearSeconds("stepSample")
                clearSeconds("bodyMeasurement", "measuredAt")
            }
            "raw_auxiliary" -> {
                clearSeconds("skinTempSample")
                clearSeconds("respSample")
                clearSeconds("sleepStateSample")
            }
            "raw_ppg" -> {
                clearSeconds("spo2Sample")
                clearSeconds("ppgWaveformSample")
            }
            "raw_motion" -> {
                clearSeconds("gravitySample")
                clearSeconds("rawImuSample")
            }
            "derived_summaries" -> {
                val fromDay = java.time.Instant.ofEpochMilli(chunk.eventStartMs)
                    .atZone(java.time.ZoneOffset.UTC)
                    .toLocalDate()
                    .toString()
                val throughDay = java.time.Instant.ofEpochMilli(chunk.eventEndMs)
                    .atZone(java.time.ZoneOffset.UTC)
                    .toLocalDate()
                    .toString()
                listOf("dailyMetric", "appleDaily", "metricSeries").forEach { table ->
                    execute(
                        db,
                        "DELETE FROM $table WHERE deviceId = ? AND day >= ? AND day <= ?",
                        arrayOf<Any?>(source, fromDay, throughDay),
                    )
                    changed += changes(db)
                }
                clearSeconds("sleepSession", "startTs")
                clearSeconds("workout", "startTs")
                clearSeconds("liveSession", "startTs")
            }
            else -> invalid()
        }
        return changed
    }

    private fun applyRows(
        db: SupportSQLiteDatabase,
        stream: String,
        rows: List<RestoreRow>,
        source: String,
        enforceRawImuRetention: Boolean = true,
    ): Int = when (stream) {
        "heart_rate" -> applyEach(db, rows) { row ->
            val bpm = row.requiredLong("bpm")
            if (bpm !in 20..260) invalid()
            Sql(
                """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET bpm = excluded.bpm, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), bpm),
            )
        }
        "rr_intervals" -> applyEach(db, rows) { row ->
            val rr = row.requiredLong("rr_ms")
            val sequence = row.requiredLong("seq")
            if (rr !in 200..3_000 || sequence !in 0..100) invalid()
            Sql(
                """
                    INSERT INTO rrInterval (
                        deviceId, ts, rrMs, seq, synced, tsSuspect, ord, srcChannel
                    ) VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs, seq) DO UPDATE SET
                        tsSuspect = excluded.tsSuspect, ord = excluded.ord,
                        srcChannel = excluded.srcChannel, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    row.seconds(),
                    rr,
                    sequence,
                    if (row.requiredBoolean("timestamp_suspect")) 1 else 0,
                    row.optionalLong("ord"),
                    row.optionalLong("source_channel"),
                ),
            )
        }
        "battery" -> applyEach(db, rows) { row ->
            val percent = row.optionalNumber("percent")
            val millivolts = row.optionalLong("millivolts")
            if (percent != null && percent !in 0.0..100.0) invalid()
            if (millivolts != null && millivolts !in 0..10_000) invalid()
            Sql(
                """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging, synced)
                    VALUES (?, ?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        soc = excluded.soc, mv = excluded.mv,
                        charging = excluded.charging, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    row.seconds(),
                    percent,
                    millivolts,
                    row.optionalBoolean("charging")?.let { if (it) 1 else 0 },
                ),
            )
        }
        "derived_heart_rate" -> applyEach(db, rows) { row ->
            val bpm = row.requiredNumber("bpm")
            val confidence = row.requiredNumber("confidence")
            row.requiredString("algorithm_revision", 128)
            if (bpm !in 20.0..260.0 || confidence !in 0.0..1.0) invalid()
            Sql(
                """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf, synced)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        bpm = excluded.bpm, conf = excluded.conf, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), bpm, confidence),
            )
        }
        "device_events" -> applyEach(db, rows) { row ->
            val kind = row.requiredString("kind", 128)
            val payload = row.requiredJson("payload_json")
            Sql(
                """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON, synced)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts, kind) DO UPDATE SET
                        payloadJSON = excluded.payloadJSON, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), kind, payload),
            )
        }
        "step_counter" -> applyEach(db, rows) { row ->
            val counter = row.requiredLong("counter")
            val activity = row.optionalLong("activity_class")
            if (counter !in 0..65_535 || (activity != null && activity !in 0..2)) invalid()
            Sql(
                """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass, synced)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        counter = excluded.counter, activityClass = excluded.activityClass, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), counter, activity),
            )
        }
        "body_measurement" -> applyEach(db, rows) { row ->
            val seconds = row.seconds()
            val weight = row.requiredNumber("weight_kg")
            val bmi = row.optionalNumber("bmi")
            val height = row.optionalNumber("height_cm")
            val user = row.requiredLong("user_id")
            if (weight !in 1.0..1_000.0 ||
                (bmi != null && bmi !in 1.0..200.0) ||
                (height != null && height !in 20.0..300.0) ||
                user !in -1..255
            ) {
                invalid()
            }
            Sql(
                """
                    INSERT INTO bodyMeasurement (
                        deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                        userId, unit, source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'kg', ?)
                    ON CONFLICT(deviceId, measuredAt, userId) DO UPDATE SET
                        weightKg = excluded.weightKg, bmi = excluded.bmi,
                        heightCm = excluded.heightCm, source = excluded.source
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    seconds,
                    seconds,
                    weight,
                    bmi,
                    height,
                    user,
                    row.requiredString("source", 64),
                ),
            )
        }
        "skin_temperature_adc" -> restoreScalar(db, rows, source, "skinTempSample")
        "respiration_adc" -> restoreScalar(db, rows, source, "respSample")
        "sleep_state" -> applyEach(db, rows) { row ->
            val state = row.requiredLong("state_code")
            if (state !in 0..3) invalid()
            Sql(
                """
                    INSERT INTO sleepStateSample (deviceId, ts, state, synced)
                    VALUES (?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET state = excluded.state, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), state),
            )
        }
        "spo2_optical_adc" -> applyEach(db, rows) { row ->
            Sql(
                """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir, synced)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        red = excluded.red, ir = excluded.ir, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    row.seconds(),
                    row.requiredLong("red_adc"),
                    row.requiredLong("infrared_adc"),
                ),
            )
        }
        "ppg_waveform" -> applyEach(db, rows) { row ->
            val rate = row.requiredNumber("sample_rate_hz")
            val count = row.requiredLong("sample_count")
            val samples = row.requiredBase64("samples_base64", 8_192)
            if (rate !in 1.0..1_000.0 || count !in 1..4_096 || samples.size.toLong() != count * 2L) {
                invalid()
            }
            Sql(
                """
                    INSERT INTO ppgWaveformSample (deviceId, ts, samples, synced)
                    VALUES (?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET samples = excluded.samples, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), samples),
            )
        }
        "gravity" -> applyEach(db, rows) { row ->
            val x = row.requiredNumber("x_g")
            val y = row.requiredNumber("y_g")
            val z = row.requiredNumber("z_g")
            if (x !in -64.0..64.0 || y !in -64.0..64.0 || z !in -64.0..64.0) invalid()
            Sql(
                """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z, synced)
                    VALUES (?, ?, ?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        x = excluded.x, y = excluded.y, z = excluded.z, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), x, y, z),
            )
        }
        "raw_imu" -> {
            val changed = applyEach(db, rows) { row ->
                val rate = row.requiredNumber("sample_rate_hz")
                val count = row.requiredLong("sample_count")
                val axisOrder = row.requiredString("axis_order", 32)
                val samples = row.requiredBase64("samples_base64", 120_000)
                if (rate !in 1.0..2_000.0 ||
                    count !in 1..10_000 ||
                    axisOrder != "ax_ay_az_gx_gy_gz" ||
                    samples.size.toLong() != count * 12L
                ) {
                    invalid()
                }
                Sql(
                    """
                        INSERT INTO rawImuSample (deviceId, ts, samples)
                        VALUES (?, ?, ?)
                        ON CONFLICT(deviceId, ts) DO UPDATE SET samples = excluded.samples
                    """.trimIndent(),
                    arrayOf<Any?>(source, row.seconds(), samples),
                )
            }
            if (enforceRawImuRetention) {
                execute(
                    db,
                    """
                        DELETE FROM rawImuSample
                        WHERE deviceId = ? AND ts < COALESCE((
                            SELECT MIN(ts) FROM (
                                SELECT ts FROM rawImuSample
                                WHERE deviceId = ?
                                ORDER BY ts DESC LIMIT ?
                            )
                        ), 0)
                    """.trimIndent(),
                    arrayOf<Any?>(source, source, WhoopRepository.RAW_IMU_RETENTION_ROWS),
                )
            }
            changed
        }
        "daily_metrics" -> restoreDaily(db, rows, source)
        "metric_series" -> restoreMetricSeries(db, rows, source)
        "sleep_summary" -> restoreSleep(db, rows, source)
        "workout_summary" -> restoreWorkouts(db, rows, source)
        "live_session" -> restoreLive(db, rows, source)
        else -> invalid()
    }

    private fun restoreScalar(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
        table: String,
    ): Int {
        if (table != "skinTempSample" && table != "respSample") invalid()
        return applyEach(db, rows) { row ->
            Sql(
                """
                    INSERT INTO $table (deviceId, ts, raw, synced) VALUES (?, ?, ?, 0)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET raw = excluded.raw, synced = 0
                """.trimIndent(),
                arrayOf<Any?>(source, row.seconds(), row.requiredLong("adc")),
            )
        }
    }

    private fun restoreDaily(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
    ): Int = applyEach(db, rows) { row ->
        val day = row.requiredDay("day")
        row.requiredString("source_id", 256)
        row.requiredMilliseconds("updated_at_ms")
        val payload = row.requiredObject("payload_json")
        val kind = payload.requiredString("record_type")
        val deleted = row.requiredBoolean("deleted")
        when (kind) {
            "daily_metric" -> if (deleted) {
                Sql("DELETE FROM dailyMetric WHERE deviceId = ? AND day = ?", arrayOf<Any?>(source, day))
            } else {
                Sql(
                    """
                        INSERT INTO dailyMetric (
                            deviceId, day, totalSleepMin, efficiency, deepMin, remMin,
                            lightMin, disturbances, restingHr, avgHrv, recovery, strain,
                            exerciseCount, spo2Pct, skinTempDevC, respRateBpm, steps,
                            activeKcalEst, spo2Red, spo2Ir, hrvMethod
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day) DO UPDATE SET
                            totalSleepMin = excluded.totalSleepMin,
                            efficiency = excluded.efficiency,
                            deepMin = excluded.deepMin,
                            remMin = excluded.remMin,
                            lightMin = excluded.lightMin,
                            disturbances = excluded.disturbances,
                            restingHr = excluded.restingHr,
                            avgHrv = excluded.avgHrv,
                            recovery = excluded.recovery,
                            strain = excluded.strain,
                            exerciseCount = excluded.exerciseCount,
                            spo2Pct = excluded.spo2Pct,
                            skinTempDevC = excluded.skinTempDevC,
                            respRateBpm = excluded.respRateBpm,
                            steps = excluded.steps,
                            activeKcalEst = excluded.activeKcalEst,
                            spo2Red = excluded.spo2Red,
                            spo2Ir = excluded.spo2Ir,
                            hrvMethod = excluded.hrvMethod
                    """.trimIndent(),
                    arrayOf<Any?>(
                        source,
                        day,
                        payload.optionalNumber("total_sleep_min"),
                        payload.optionalNumber("efficiency"),
                        payload.optionalNumber("deep_min"),
                        payload.optionalNumber("rem_min"),
                        payload.optionalNumber("light_min"),
                        payload.optionalLong("disturbances"),
                        payload.optionalLong("resting_hr"),
                        payload.optionalNumber("avg_hrv"),
                        payload.optionalNumber("recovery"),
                        payload.optionalNumber("strain"),
                        payload.optionalLong("exercise_count"),
                        payload.optionalNumber("spo2_pct"),
                        payload.optionalNumber("skin_temp_dev_c"),
                        payload.optionalNumber("resp_rate_bpm"),
                        payload.optionalLong("steps"),
                        payload.optionalNumber("active_kcal_est"),
                        payload.optionalLong("spo2_red"),
                        payload.optionalLong("spo2_ir"),
                        payload.optionalString("hrv_method"),
                    ),
                )
            }
            "platform_daily" -> if (deleted) {
                Sql("DELETE FROM appleDaily WHERE deviceId = ? AND day = ?", arrayOf<Any?>(source, day))
            } else {
                Sql(
                    """
                        INSERT INTO appleDaily (
                            deviceId, day, steps, activeKcal, basalKcal, vo2max,
                            avgHr, maxHr, walkingHr, weightKg
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day) DO UPDATE SET
                            steps = excluded.steps,
                            activeKcal = excluded.activeKcal,
                            basalKcal = excluded.basalKcal,
                            vo2max = excluded.vo2max,
                            avgHr = excluded.avgHr,
                            maxHr = excluded.maxHr,
                            walkingHr = excluded.walkingHr,
                            weightKg = excluded.weightKg
                    """.trimIndent(),
                    arrayOf<Any?>(
                        source,
                        day,
                        payload.optionalLong("steps"),
                        payload.optionalNumber("active_kcal"),
                        payload.optionalNumber("basal_kcal"),
                        payload.optionalNumber("vo2max"),
                        payload.optionalLong("avg_hr"),
                        payload.optionalLong("max_hr"),
                        payload.optionalLong("walking_hr"),
                        payload.optionalNumber("weight_kg"),
                    ),
                )
            }
            else -> invalid()
        }
    }

    private fun restoreMetricSeries(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
    ): Int = applyEach(db, rows) { row ->
        val day = row.requiredDay("day")
        val key = row.requiredString("metric_key", 64)
        row.requiredString("source_id", 256)
        row.requiredMilliseconds("updated_at_ms")
        if (row.requiredBoolean("deleted")) {
            Sql(
                "DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND `key` = ?",
                arrayOf<Any?>(source, day, key),
            )
        } else {
            var value = row.requiredNumber("value")
            if (key == "sleep_efficiency") {
                if (value !in 0.0..100.0) invalid()
                if (value > 1.0) value /= 100.0
            }
            Sql(
                """
                    INSERT INTO metricSeries (deviceId, day, `key`, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, `key`) DO UPDATE SET value = excluded.value
                """.trimIndent(),
                arrayOf<Any?>(source, day, key, value),
            )
        }
    }

    private fun restoreSleep(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
    ): Int = applyEach(db, rows) { row ->
        val start = row.seconds()
        row.requiredString("record_id", 512)
        row.requiredMilliseconds("updated_at_ms")
        if (row.requiredBoolean("deleted")) {
            Sql(
                "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                arrayOf<Any?>(source, start),
            )
        } else {
            val end = row.requiredMilliseconds("end_at_ms") / 1_000
            if (end <= start) invalid()
            val payload = row.requiredObject("payload_json")
            val edited = payload.optionalBoolean("user_edited") ?: false
            val gravitySparse = payload.optionalBoolean("gravity_sparse")
            Sql(
                """
                    INSERT INTO sleepSession (
                        deviceId, startTs, endTs, efficiency, restingHr, avgHrv,
                        stagesJSON, userEdited, startTsAdjusted, motionJSON,
                        sleepStateJSON, gravitySparse, rrEligibleWindowCount,
                        rrValidWindowCount
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        endTs = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.endTs ELSE excluded.endTs END,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.stagesJSON ELSE excluded.stagesJSON END,
                        startTsAdjusted = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.startTsAdjusted ELSE excluded.startTsAdjusted END,
                        motionJSON = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.motionJSON ELSE excluded.motionJSON END,
                        sleepStateJSON = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.sleepStateJSON ELSE excluded.sleepStateJSON END,
                        gravitySparse = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.gravitySparse ELSE excluded.gravitySparse END,
                        rrEligibleWindowCount = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.rrEligibleWindowCount
                            ELSE excluded.rrEligibleWindowCount END,
                        rrValidWindowCount = CASE
                            WHEN sleepSession.userEdited = 1 AND excluded.userEdited = 0
                            THEN sleepSession.rrValidWindowCount
                            ELSE excluded.rrValidWindowCount END,
                        userEdited = MAX(sleepSession.userEdited, excluded.userEdited)
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    start,
                    end,
                    payload.optionalNumber("efficiency"),
                    payload.optionalLong("resting_hr"),
                    payload.optionalNumber("avg_hrv"),
                    payload.optionalString("stages_json"),
                    if (edited) 1 else 0,
                    payload.optionalLong("start_ts_adjusted"),
                    payload.optionalString("motion_json"),
                    payload.optionalString("sleep_state_json"),
                    gravitySparse?.let { if (it) 1 else 0 },
                    payload.optionalLong("rr_eligible_window_count"),
                    payload.optionalLong("rr_valid_window_count"),
                ),
            )
        }
    }

    private fun restoreWorkouts(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
    ): Int = applyEach(db, rows) { row ->
        val start = row.seconds()
        row.requiredString("record_id", 512)
        row.requiredMilliseconds("updated_at_ms")
        val payload = row.requiredObject("payload_json")
        val sport = payload.requiredString("sport")
        if (row.requiredBoolean("deleted")) {
            Sql(
                "DELETE FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                arrayOf<Any?>(source, start, sport),
            )
        } else {
            val end = row.requiredMilliseconds("end_at_ms") / 1_000
            if (end < start) invalid()
            Sql(
                """
                    INSERT INTO workout (
                        deviceId, startTs, endTs, sport, source, durationS,
                        energyKcal, avgHr, maxHr, strain, distanceM, zonesJSON,
                        notes, routePolyline, steps
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        source = excluded.source,
                        durationS = excluded.durationS,
                        energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        strain = excluded.strain,
                        distanceM = excluded.distanceM,
                        zonesJSON = excluded.zonesJSON,
                        notes = excluded.notes,
                        steps = excluded.steps
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    start,
                    end,
                    sport,
                    payload.requiredString("source"),
                    payload.optionalNumber("duration_s"),
                    payload.optionalNumber("energy_kcal"),
                    payload.optionalLong("avg_hr"),
                    payload.optionalLong("max_hr"),
                    payload.optionalNumber("strain"),
                    payload.optionalNumber("distance_m"),
                    payload.optionalString("zones_json"),
                    payload.optionalString("notes"),
                    payload.optionalLong("steps"),
                ),
            )
        }
    }

    private fun restoreLive(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        source: String,
    ): Int = applyEach(db, rows) { row ->
        val start = row.seconds()
        row.requiredString("record_id", 512)
        row.requiredMilliseconds("updated_at_ms")
        if (row.requiredBoolean("deleted")) {
            Sql(
                "DELETE FROM liveSession WHERE deviceId = ? AND startTs = ?",
                arrayOf<Any?>(source, start),
            )
        } else {
            val payload = row.requiredObject("payload_json")
            Sql(
                """
                    INSERT INTO liveSession (
                        deviceId, startTs, endTs, chargeAtStart, floorBpm,
                        ceilingBpm, inBandSec, belowSec, aboveSec, pushCount,
                        easeCount, hrSource
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        endTs = excluded.endTs,
                        chargeAtStart = excluded.chargeAtStart,
                        floorBpm = excluded.floorBpm,
                        ceilingBpm = excluded.ceilingBpm,
                        inBandSec = excluded.inBandSec,
                        belowSec = excluded.belowSec,
                        aboveSec = excluded.aboveSec,
                        pushCount = excluded.pushCount,
                        easeCount = excluded.easeCount,
                        hrSource = excluded.hrSource
                """.trimIndent(),
                arrayOf<Any?>(
                    source,
                    start,
                    row.optionalMilliseconds("end_at_ms")?.div(1_000),
                    payload.optionalNumber("charge_at_start"),
                    payload.requiredNumber("floor_bpm"),
                    payload.requiredNumber("ceiling_bpm"),
                    payload.requiredNumber("in_band_sec"),
                    payload.requiredNumber("below_sec"),
                    payload.requiredNumber("above_sec"),
                    payload.requiredLong("push_count"),
                    payload.requiredLong("ease_count"),
                    payload.requiredString("hr_source"),
                ),
            )
        }
    }

    private fun applyEach(
        db: SupportSQLiteDatabase,
        rows: List<RestoreRow>,
        sql: (RestoreRow) -> Sql,
    ): Int {
        var changed = 0
        rows.forEach { row ->
            val operation = sql(row)
            execute(db, operation.text, operation.arguments)
            changed += changes(db)
        }
        return changed
    }

    private fun execute(
        db: SupportSQLiteDatabase,
        sql: String,
        arguments: Array<out Any?>,
    ) {
        db.execSQL(sql, arguments)
    }

    private fun changes(db: SupportSQLiteDatabase): Int =
        db.query(SimpleSQLiteQuery("SELECT changes()")).use {
            if (it.moveToFirst()) it.getInt(0) else 0
        }

    private fun parseInstant(value: String?): Long =
        try {
            java.time.Instant.parse(value ?: invalid()).toEpochMilli()
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Exception) {
            invalid()
        }

    private data class RestoreSource(val localSourceId: String, val shouldApply: Boolean)
    private data class Sql(val text: String, val arguments: Array<out Any?>)

    private class RestoreRow(
        private val columns: List<String>,
        private val values: List<ManagedJsonValue>,
    ) {
        private fun value(name: String): ManagedJsonValue {
            val index = columns.indexOf(name)
            if (index < 0 || index >= values.size) invalid()
            return values[index]
        }

        fun requiredLong(name: String): Long = when (val value = value(name)) {
            is ManagedJsonValue.IntegerValue -> value.value
            is ManagedJsonValue.NumberValue -> {
                val number = value.value
                if (!number.isFinite() ||
                    number != number.roundToLong().toDouble() ||
                    number < Long.MIN_VALUE.toDouble() ||
                    number > Long.MAX_VALUE.toDouble()
                ) {
                    invalid()
                }
                number.toLong()
            }
            else -> invalid()
        }

        fun optionalLong(name: String): Long? =
            if (value(name) == ManagedJsonValue.NullValue) null else requiredLong(name)

        fun requiredNumber(name: String): Double = when (val value = value(name)) {
            is ManagedJsonValue.IntegerValue -> value.value.toDouble()
            is ManagedJsonValue.NumberValue -> value.value.takeIf(Double::isFinite) ?: invalid()
            else -> invalid()
        }

        fun optionalNumber(name: String): Double? =
            if (value(name) == ManagedJsonValue.NullValue) null else requiredNumber(name)

        fun requiredString(name: String, maximumBytes: Int = 262_144): String {
            val string = (value(name) as? ManagedJsonValue.StringValue)?.value ?: invalid()
            if (string.isEmpty() || string.toByteArray().size > maximumBytes) invalid()
            return string
        }

        fun optionalString(name: String, maximumBytes: Int = 262_144): String? =
            if (value(name) == ManagedJsonValue.NullValue) {
                null
            } else {
                requiredString(name, maximumBytes)
            }

        fun requiredBoolean(name: String): Boolean =
            (value(name) as? ManagedJsonValue.BooleanValue)?.value ?: invalid()

        fun optionalBoolean(name: String): Boolean? =
            if (value(name) == ManagedJsonValue.NullValue) null else requiredBoolean(name)

        fun requiredMilliseconds(name: String): Long {
            val value = requiredLong(name)
            if (value < 0L || value % 1_000 != 0L) invalid()
            return value
        }

        fun optionalMilliseconds(name: String): Long? =
            if (value(name) == ManagedJsonValue.NullValue) null else requiredMilliseconds(name)

        fun seconds(): Long = requiredMilliseconds("event_at_ms") / 1_000

        fun requiredDay(name: String): String {
            val value = requiredString(name, 10)
            val parsed = try {
                LocalDate.parse(value)
            } catch (_: Exception) {
                invalid()
            }
            if (parsed.toString() != value) invalid()
            return value
        }

        fun requiredBase64(name: String, maximumBytes: Int): ByteArray {
            val encoded = requiredString(name, maximumBytes * 2)
            val decoded = try {
                Base64.getDecoder().decode(encoded)
            } catch (_: Exception) {
                invalid()
            }
            if (decoded.size > maximumBytes) invalid()
            return decoded
        }

        fun requiredJson(name: String): String {
            val encoded = requiredString(name)
            try {
                if (encoded.trimStart().startsWith("[")) JSONArray(encoded) else JSONObject(encoded)
            } catch (_: Exception) {
                invalid()
            }
            return encoded
        }

        fun requiredObject(name: String): RestoreObject =
            try {
                RestoreObject(JSONObject(requiredString(name)))
            } catch (error: ManagedStorageException) {
                throw error
            } catch (_: Exception) {
                invalid()
            }
    }

    private class RestoreObject(private val value: JSONObject) {
        private fun optional(key: String): Any? =
            if (!value.has(key) || value.isNull(key)) null else value.get(key)

        fun requiredString(key: String): String =
            (optional(key) as? String)?.takeIf(String::isNotEmpty) ?: invalid()

        fun optionalString(key: String): String? {
            val value = optional(key) ?: return null
            return value as? String ?: invalid()
        }

        fun requiredLong(key: String): Long =
            number(key, required = true)!!.integralLong()

        fun optionalLong(key: String): Long? =
            number(key, required = false)?.integralLong()

        fun requiredNumber(key: String): Double =
            number(key, required = true)!!

        fun optionalNumber(key: String): Double? =
            number(key, required = false)

        fun optionalBoolean(key: String): Boolean? {
            val value = optional(key) ?: return null
            return value as? Boolean ?: invalid()
        }

        private fun number(key: String, required: Boolean): Double? {
            val value = optional(key)
            if (value == null) {
                if (required) invalid()
                return null
            }
            if (value is Boolean || value !is Number) invalid()
            return value.toDouble().takeIf(Double::isFinite) ?: invalid()
        }

        private fun Double.integralLong(): Long {
            if (this != roundToLong().toDouble() ||
                this < Long.MIN_VALUE.toDouble() ||
                this > Long.MAX_VALUE.toDouble()
            ) {
                invalid()
            }
            return toLong()
        }
    }

    companion object {
        private const val MAX_ROWS_PER_CHUNK = 250_000
        private val SHA256 = Regex("^[0-9a-f]{64}$")

        private val STREAMS_BY_CLASS = mapOf(
            "essential_timeseries" to setOf(
                "heart_rate",
                "rr_intervals",
                "battery",
                "derived_heart_rate",
                "device_events",
                "step_counter",
                "body_measurement",
            ),
            "raw_auxiliary" to setOf(
                "skin_temperature_adc",
                "respiration_adc",
                "sleep_state",
            ),
            "raw_ppg" to setOf("spo2_optical_adc", "ppg_waveform"),
            "raw_motion" to setOf("gravity", "raw_imu"),
            "derived_summaries" to setOf(
                "daily_metrics",
                "metric_series",
                "sleep_summary",
                "workout_summary",
                "live_session",
            ),
        )

        private val PRUNABLE_STREAMS_BY_CLASS = STREAMS_BY_CLASS.mapValues { (dataClass, keys) ->
            if (dataClass == "essential_timeseries") {
                keys - "body_measurement"
            } else {
                keys
            }
        }

        private val PRUNABLE_TABLES_BY_CLASS = mapOf(
            "essential_timeseries" to listOf(
                "hrSample",
                "rrInterval",
                "battery",
                "ppgHrSample",
                "event",
                "stepSample",
            ),
            "raw_auxiliary" to listOf(
                "skinTempSample",
                "respSample",
                "sleepStateSample",
            ),
            "raw_ppg" to listOf("spo2Sample", "ppgWaveformSample"),
            "raw_motion" to listOf("gravitySample", "rawImuSample"),
        )

        private val COLUMNS = mapOf(
            "heart_rate" to listOf("event_at_ms", "bpm", "quality", "provenance"),
            "rr_intervals" to listOf(
                "event_at_ms",
                "rr_ms",
                "seq",
                "ord",
                "source_channel",
                "timestamp_suspect",
            ),
            "battery" to listOf("event_at_ms", "percent", "millivolts", "charging"),
            "derived_heart_rate" to listOf(
                "event_at_ms",
                "bpm",
                "confidence",
                "algorithm_revision",
            ),
            "device_events" to listOf("event_at_ms", "kind", "payload_json"),
            "step_counter" to listOf("event_at_ms", "counter", "activity_class"),
            "body_measurement" to listOf(
                "event_at_ms",
                "weight_kg",
                "bmi",
                "height_cm",
                "user_id",
                "source",
            ),
            "skin_temperature_adc" to listOf("event_at_ms", "adc"),
            "respiration_adc" to listOf("event_at_ms", "adc"),
            "sleep_state" to listOf("event_at_ms", "state_code"),
            "spo2_optical_adc" to listOf("event_at_ms", "red_adc", "infrared_adc"),
            "ppg_waveform" to listOf(
                "event_at_ms",
                "sample_rate_hz",
                "sample_count",
                "samples_base64",
            ),
            "gravity" to listOf("event_at_ms", "x_g", "y_g", "z_g"),
            "raw_imu" to listOf(
                "event_at_ms",
                "sample_rate_hz",
                "sample_count",
                "axis_order",
                "samples_base64",
            ),
            "daily_metrics" to listOf(
                "event_at_ms",
                "day",
                "source_id",
                "payload_json",
                "updated_at_ms",
                "deleted",
            ),
            "metric_series" to listOf(
                "event_at_ms",
                "day",
                "metric_key",
                "value",
                "source_id",
                "updated_at_ms",
                "deleted",
            ),
            "sleep_summary" to listOf(
                "event_at_ms",
                "record_id",
                "end_at_ms",
                "payload_json",
                "updated_at_ms",
                "deleted",
            ),
            "workout_summary" to listOf(
                "event_at_ms",
                "record_id",
                "end_at_ms",
                "payload_json",
                "updated_at_ms",
                "deleted",
            ),
            "live_session" to listOf(
                "event_at_ms",
                "record_id",
                "end_at_ms",
                "payload_json",
                "updated_at_ms",
                "deleted",
            ),
        )

        private fun invalid(): Nothing = throw ManagedStorageException.InvalidResponse()
    }
}
