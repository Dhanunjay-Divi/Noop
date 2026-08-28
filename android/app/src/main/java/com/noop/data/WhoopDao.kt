package com.noop.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * Data-access for the local store. Mirrors the GRDB reads/writes in WhoopStore
 * (StreamStore.swift, Reads.swift, MetricsCache.swift).
 *
 * Stream inserts use OnConflictStrategy.IGNORE == Swift `ON CONFLICT(...) DO NOTHING`
 * (idempotent by natural key — re-inserting an existing row is a no-op).
 *
 * Server-derived dailyMetric/metricSeries caches use @Upsert. sleepSession uses a conditional
 * transaction because a blanket Room upsert would erase user edits and locally banked evidence.
 *
 * Range reads are ORDER BY ts ASC (R-R and events add a secondary key matching Reads.swift),
 * and bound by [from, to] inclusive with a row limit.
 */
@Dao
interface WhoopDao : DeviceRegistryDao {

    // MARK: - Device

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertDevice(device: DeviceRow)

    @Query("SELECT * FROM device WHERE id = :id")
    suspend fun device(id: String): DeviceRow?

    // NOTE: the device-registry reads/writes (pairedDevice/dayOwnership, v8) live on the narrow
    // [DeviceRegistryDao] super-interface so [DeviceRegistry] can be unit-tested with a small fake DAO
    // (no Robolectric — see DeviceRegistryTest). Room flattens the inherited @Query/@Insert methods
    // into this @Dao at compile time, so they generate exactly as if declared here.

    // MARK: - Stream inserts (idempotent by natural key)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertHr(rows: List<HrSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertRr(rows: List<RrInterval>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertEvents(rows: List<EventRow>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertBattery(rows: List<BatterySample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSpo2(rows: List<Spo2Sample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSkinTemp(rows: List<SkinTempSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSteps(rows: List<StepSample>): List<Long>

    /** The strap's OWN band sleep_state per record (#175). Idempotent by (deviceId, ts). */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSleepState(rows: List<SleepStateSampleEntity>): List<Long>

    /** Upsert one Live Session (v22). Natural key (deviceId, startTs) — start (endTs null) then end. */
    @Upsert
    suspend fun upsertLiveSession(row: LiveSessionRow)

    /** Most-recent Live Sessions first, for the look-back summary + streak. */
    @Query("SELECT * FROM liveSession WHERE deviceId = :deviceId ORDER BY startTs DESC LIMIT :limit")
    suspend fun recentLiveSessions(deviceId: String, limit: Int): List<LiveSessionRow>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertResp(rows: List<RespSample>): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertGravity(rows: List<GravitySample>): List<Long>

    /** PPG-derived HR from the v26 optical waveform. Idempotent by (deviceId, ts). (#156) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertPpgHr(rows: List<PpgHrSample>): List<Long>

    /** RAW v26 optical PPG waveform (packed i16 BLOB). Idempotent by (deviceId, ts). (#156 follow-up) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertPpgWaveform(rows: List<PpgWaveformSampleEntity>): List<Long>

    /** RAW 5/MG IMU offload buffers (packed i16 BLOB). Idempotent by (deviceId, ts). (#423) */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertRawImu(rows: List<RawImuSampleEntity>): List<Long>

    // MARK: - Optional self-hosted sync outbox

    /**
     * Oldest raw rows not yet acknowledged by the user's self-hosted server. A separate limit per
     * stream keeps dense HR from starving sparse battery/events while bounding one request. These
     * queries intentionally exclude PPG-derived HR and the raw optical/IMU blobs: the v1 API carries
     * decoded scalar streams, and measured HR remains distinguishable from an estimate.
     */
    @Query(
        "SELECT * FROM hrSample WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteHr(deviceId: String, limit: Int): List<HrSample>

    @Query(
        "SELECT * FROM rrInterval WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC, rrMs ASC, seq ASC LIMIT :limit"
    )
    suspend fun pendingRemoteRr(deviceId: String, limit: Int): List<RrInterval>

    @Query(
        "SELECT * FROM event WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC, kind ASC LIMIT :limit"
    )
    suspend fun pendingRemoteEvents(deviceId: String, limit: Int): List<EventRow>

    @Query(
        "SELECT * FROM battery WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteBattery(deviceId: String, limit: Int): List<BatterySample>

    @Query(
        "SELECT * FROM spo2Sample WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteSpo2(deviceId: String, limit: Int): List<Spo2Sample>

    @Query(
        "SELECT * FROM skinTempSample WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteSkinTemp(deviceId: String, limit: Int): List<SkinTempSample>

    @Query(
        "SELECT * FROM respSample WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteResp(deviceId: String, limit: Int): List<RespSample>

    @Query(
        "SELECT * FROM stepSample WHERE deviceId = :deviceId AND synced = 0 " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun pendingRemoteSteps(deviceId: String, limit: Int): List<StepSample>

    /** Exact natural-key acknowledgements. Call only inside the store's transaction after a 2xx. */
    @Query("UPDATE hrSample SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteHr(deviceId: String, ts: Long): Int

    @Query(
        "UPDATE rrInterval SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts " +
            "AND rrMs = :rrMs AND seq = :seq"
    )
    suspend fun acknowledgeRemoteRr(deviceId: String, ts: Long, rrMs: Int, seq: Int): Int

    @Query(
        "UPDATE event SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts AND kind = :kind"
    )
    suspend fun acknowledgeRemoteEvent(deviceId: String, ts: Long, kind: String): Int

    @Query("UPDATE battery SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteBattery(deviceId: String, ts: Long): Int

    @Query("UPDATE spo2Sample SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteSpo2(deviceId: String, ts: Long): Int

    @Query("UPDATE skinTempSample SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteSkinTemp(deviceId: String, ts: Long): Int

    @Query("UPDATE respSample SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteResp(deviceId: String, ts: Long): Int

    @Query("UPDATE stepSample SET synced = 1 WHERE deviceId = :deviceId AND ts = :ts")
    suspend fun acknowledgeRemoteStep(deviceId: String, ts: Long): Int

    /**
     * A destination change/full replay makes every decoded scalar row pending again. These are kept
     * as table-specific statements so Room validates every table/column at compile time; the store
     * invokes them in one transaction.
     */
    @Query("UPDATE hrSample SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteHr(deviceId: String): Int

    @Query("UPDATE rrInterval SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteRr(deviceId: String): Int

    @Query("UPDATE event SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteEvents(deviceId: String): Int

    @Query("UPDATE battery SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteBattery(deviceId: String): Int

    @Query("UPDATE spo2Sample SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteSpo2(deviceId: String): Int

    @Query("UPDATE skinTempSample SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteSkinTemp(deviceId: String): Int

    @Query("UPDATE respSample SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteResp(deviceId: String): Int

    @Query("UPDATE stepSample SET synced = 0 WHERE deviceId = :deviceId")
    suspend fun resetRemoteSteps(deviceId: String): Int

    /** Bound the raw-IMU table to the newest [keep] rows for [deviceId] (rolling retention, #423). */
    @Query(
        "DELETE FROM rawImuSample WHERE deviceId = :deviceId AND ts < " +
            "(SELECT MIN(ts) FROM (SELECT ts FROM rawImuSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT :keep))"
    )
    suspend fun pruneRawImu(deviceId: String, keep: Int)

    /** RAW 5/MG IMU buffers in [from, to] (ascending), packed i16 BLOB. (#423) */
    @Query(
        "SELECT * FROM rawImuSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun rawImuSamples(deviceId: String, from: Long, to: Long, limit: Int): List<RawImuSampleEntity>

    // MARK: - Server-derived caches (latest value wins)

    @Upsert
    suspend fun upsertDailyMetrics(rows: List<DailyMetric>)

    @Query(
        "DELETE FROM dailyMetric WHERE deviceId = :deviceId " +
            "AND day >= :fromDay AND day <= :toDay"
    )
    suspend fun deleteDailyMetricRange(deviceId: String, fromDay: String, toDay: String): Int

    /**
     * Sleep-session insert/update with field ownership preserved on conflict.
     *
     * An existing user edit owns its effective bounds, stage payload, and exact R-R evidence. Fresh
     * analysis may still refresh vitals. Per-epoch motion/state are written by targeted APIs and never
     * replaced on conflict, though an incoming value may fill a previously absent auxiliary. An
     * unedited row accepts all incoming analysis fields, including null evidence, so stale detail fails
     * closed. The dedicated [applySleepEdit] path mutates an already-edited row.
     */
    @Transaction
    suspend fun upsertSleepSessions(rows: List<SleepSession>) {
        if (rows.isEmpty()) return
        val inserted = insertSleepSessionsIgnoringConflicts(rows)
        for (index in rows.indices) {
            if (inserted.getOrNull(index) != -1L) continue
            val row = rows[index]
            updateSleepSessionOnConflict(
                deviceId = row.deviceId,
                startTs = row.startTs,
                endTs = row.endTs,
                efficiency = row.efficiency,
                restingHr = row.restingHr,
                avgHrv = row.avgHrv,
                stagesJSON = row.stagesJSON,
                incomingUserEdited = row.userEdited,
                startTsAdjusted = row.startTsAdjusted,
                incomingMotionJSON = row.motionJSON,
                incomingSleepStateJSON = row.sleepStateJSON,
                rrEligibleWindowCount = row.rrEligibleWindowCount,
                rrValidWindowCount = row.rrValidWindowCount,
            )
        }
    }

    @Query(
        "UPDATE sleepSession SET " +
            "endTs = CASE WHEN userEdited = 1 THEN endTs ELSE :endTs END, " +
            "efficiency = :efficiency, restingHr = :restingHr, avgHrv = :avgHrv, " +
            "stagesJSON = CASE WHEN userEdited = 1 THEN stagesJSON ELSE :stagesJSON END, " +
            "userEdited = CASE WHEN userEdited = 1 THEN 1 ELSE :incomingUserEdited END, " +
            "startTsAdjusted = CASE WHEN userEdited = 1 THEN startTsAdjusted ELSE :startTsAdjusted END, " +
            "motionJSON = COALESCE(motionJSON, :incomingMotionJSON), " +
            "sleepStateJSON = COALESCE(sleepStateJSON, :incomingSleepStateJSON), " +
            "rrEligibleWindowCount = CASE WHEN userEdited = 1 " +
                "THEN rrEligibleWindowCount ELSE :rrEligibleWindowCount END, " +
            "rrValidWindowCount = CASE WHEN userEdited = 1 " +
                "THEN rrValidWindowCount ELSE :rrValidWindowCount END " +
            "WHERE deviceId = :deviceId AND startTs = :startTs"
    )
    suspend fun updateSleepSessionOnConflict(
        deviceId: String,
        startTs: Long,
        endTs: Long,
        efficiency: Double?,
        restingHr: Int?,
        avgHrv: Double?,
        stagesJSON: String?,
        incomingUserEdited: Boolean,
        startTsAdjusted: Long?,
        incomingMotionJSON: String?,
        incomingSleepStateJSON: String?,
        rrEligibleWindowCount: Int?,
        rrValidWindowCount: Int?,
    ): Int

    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs = :startTs LIMIT 1"
    )
    suspend fun sleepSessionByKey(deviceId: String, startTs: Long): SleepSession?

    @Query(
        "DELETE FROM sleepSession WHERE deviceId = :deviceId " +
            "AND startTs >= :fromTs AND startTs <= :toTs AND userEdited = 0 " +
            "AND motionJSON IS NULL AND sleepStateJSON IS NULL"
    )
    suspend fun deleteImportedSleepSessionRange(
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): Int

    /** Reconciliation insert that cannot overwrite a hand-edited Health Connect night. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSleepSessionsIgnoringConflicts(rows: List<SleepSession>): List<Long>

    /** Remove one sleep session by its immutable full primary key (deviceId, startTs). Bed/wake edits
     *  use [applySleepEdit] in place; this delete is reserved for an explicit user deletion or repair.
     *  Returns the number of rows changed so callers never report a row as deleted when it was not. */
    @Query("DELETE FROM sleepSession WHERE deviceId = :deviceId AND startTs = :startTs")
    suspend fun deleteSleepSession(deviceId: String, startTs: Long): Int

    /** Manually ADD a sleep session the detector missed — typically a daytime NAP (#508). Port of iOS
     *  MetricsCache.insertManualSleepSession. `onConflict = IGNORE` makes it purely ADDITIVE: it can
     *  never clobber an existing detected/edited session that shares the exact onset second (it returns
     *  -1 then). The caller builds the row with userEdited = true (so the recompute overlap guard in
     *  [com.noop.analytics.IntelligenceEngine] preserves it) and startTsAdjusted = null (a manual nap's
     *  onset IS the chosen onset). Returns the inserted rowid, or -1 on a conflicting onset. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertSleepSession(row: SleepSession): Long

    /**
     * Apply a user-selected window and its matching stage/evidence payload without replacing auxiliary
     * motion/state. Nullable evidence deliberately clears stale counts when no exact restaging exists.
     */
    @Query(
        "UPDATE sleepSession SET endTs = :endTs, stagesJSON = :stagesJSON, userEdited = 1, " +
            "startTsAdjusted = :startTsAdjusted, " +
            "rrEligibleWindowCount = :rrEligibleWindowCount, " +
            "rrValidWindowCount = :rrValidWindowCount " +
            "WHERE deviceId = :deviceId AND startTs = :detectedStartTs"
    )
    suspend fun applySleepEdit(
        deviceId: String,
        detectedStartTs: Long,
        startTsAdjusted: Long,
        endTs: Long,
        stagesJSON: String?,
        rrEligibleWindowCount: Int?,
        rrValidWindowCount: Int?,
    ): Int

    /**
     * Replace ONLY the stage breakdown of an already user-edited night, leaving the corrected
     * bed/wake bounds (startTsAdjusted/endTs) and the userEdited flag untouched. Port of iOS
     * MetricsCache.updateSleepStages (PR #449). The post-sync self-heal
     * ([com.noop.analytics.SleepStageHealer]) calls this when a strap sync finally delivers the raw
     * streams for a night that was edited BEFORE they arrived: at edit time the stages were
     * fabricated by SleepWindowReclip (a trailing "wake" block) because the raw wasn't present yet,
     * and userEdited then froze that breakdown against every later sync. This swaps in the real
     * re-derived stages without disturbing the user's bound correction. A stage-only mutation has no
     * attributable R-R analysis, so it clears both exact-session evidence counts.
     *
     * Scoped to `userEdited = 1` rows (Room stores Boolean true as INTEGER 1) so it can NEVER rewrite
     * an un-edited (freely re-derivable) night — the regular recompute upsert owns those. Keyed by the
     * IMMUTABLE detected primary key (deviceId, startTs); the caller passes the detected startTs, never
     * effectiveStartTs. Returns rows changed (0 when no such edited session exists).
     */
    @Query(
        "UPDATE sleepSession SET stagesJSON = :stagesJSON, " +
            "rrEligibleWindowCount = NULL, rrValidWindowCount = NULL " +
            "WHERE deviceId = :deviceId AND startTs = :detectedStartTs AND userEdited = 1"
    )
    suspend fun updateSleepStages(deviceId: String, detectedStartTs: Long, stagesJSON: String): Int

    /**
     * Atomically replace an edited session's stages and the exact-session R-R counts produced by the
     * same successful raw analysis. Keeping these in one UPDATE prevents a crash from publishing stages
     * against stale evidence or evidence against stale bounds.
     */
    @Query(
        "UPDATE sleepSession SET stagesJSON = :stagesJSON, " +
            "rrEligibleWindowCount = :rrEligibleWindowCount, " +
            "rrValidWindowCount = :rrValidWindowCount " +
            "WHERE deviceId = :deviceId AND startTs = :detectedStartTs AND userEdited = 1"
    )
    suspend fun updateAnalyzedSleepStages(
        deviceId: String,
        detectedStartTs: Long,
        stagesJSON: String,
        rrEligibleWindowCount: Int,
        rrValidWindowCount: Int,
    ): Int

    /**
     * v18 (H8): write the per-epoch motion magnitudes (compact JSON array) for one session, banked beside
     * `stagesJSON` on the same row. Keyed by the IMMUTABLE detected key (deviceId, startTs). `null` clears
     * the column (no series). Port of iOS WhoopStore.persistSessionMotion (the repository encodes the array).
     * Returns rows changed (0 when no such session). Targeted UPDATE so the @Upsert recompute/import path —
     * which never names this column — preserves it. */
    @Query(
        "UPDATE sleepSession SET motionJSON = :json WHERE deviceId = :deviceId AND startTs = :sessionStart"
    )
    suspend fun updateSessionMotion(deviceId: String, sessionStart: Long, json: String?): Int

    /** v18 (H8): read the per-epoch motion JSON for one session, or null when unset / no such session.
     *  The repository decodes it to `List<Double>?` (absent stays absent). */
    @Query("SELECT motionJSON FROM sleepSession WHERE deviceId = :deviceId AND startTs = :sessionStart")
    suspend fun sessionMotionJson(deviceId: String, sessionStart: Long): String?

    /**
     * v18 (H2 persist half): write the decoded v18 band sleep_state per epoch (compact JSON int array) for
     * one session. Keyed by (deviceId, startTs). `null` clears the column. Port of iOS
     * WhoopStore.persistSessionSleepState. Returns rows changed. Targeted UPDATE so the @Upsert path
     * preserves it. */
    @Query(
        "UPDATE sleepSession SET sleepStateJSON = :json WHERE deviceId = :deviceId AND startTs = :sessionStart"
    )
    suspend fun updateSessionSleepState(deviceId: String, sessionStart: Long, json: String?): Int

    /** v18 (H2): read the decoded v18 band sleep_state JSON for one session, or null when unset.
     *  The repository decodes it to `List<Int>?`. */
    @Query("SELECT sleepStateJSON FROM sleepSession WHERE deviceId = :deviceId AND startTs = :sessionStart")
    suspend fun sessionSleepStateJson(deviceId: String, sessionStart: Long): String?

    @Upsert
    suspend fun upsertMetricSeries(rows: List<MetricSeriesRow>)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertMetricSeriesIgnoringConflicts(rows: List<MetricSeriesRow>): List<Long>

    @Query(
        "DELETE FROM metricSeries WHERE deviceId = :deviceId " +
            "AND day >= :fromDay AND day <= :toDay AND `key` IN (:managedKeys)"
    )
    suspend fun deleteManagedMetricSeriesRange(
        deviceId: String,
        fromDay: String,
        toDay: String,
        managedKeys: List<String>,
    ): Int

    /**
     * Atomically replace importer-owned metric keys in one inclusive day range. A later, narrower
     * export can therefore remove a value instead of leaving the previous import's row behind.
     */
    @Transaction
    suspend fun replaceMetricSeriesRange(
        deviceId: String,
        fromDay: String,
        toDay: String,
        managedKeys: List<String>,
        rows: List<MetricSeriesRow>,
    ) {
        if (managedKeys.isEmpty()) return
        deleteManagedMetricSeriesRange(deviceId, fromDay, toDay, managedKeys)
        if (rows.isNotEmpty()) upsertMetricSeries(rows)
    }

    @Upsert
    suspend fun upsertJournal(rows: List<JournalEntry>)

    @Upsert
    suspend fun upsertWorkouts(rows: List<WorkoutRow>)

    @Query(
        "DELETE FROM workout WHERE deviceId = :deviceId " +
            "AND source = :source AND startTs >= :fromTs AND startTs <= :toTs"
    )
    suspend fun deleteWorkoutRange(
        deviceId: String,
        source: String,
        fromTs: Long,
        toTs: Long,
    ): Int

    @Query(
        "DELETE FROM workout WHERE deviceId = :deviceId AND startTs = :startTs " +
            "AND sport = :sport AND source = :source"
    )
    suspend fun deleteWorkoutKeyForSource(
        deviceId: String,
        startTs: Long,
        sport: String,
        source: String,
    ): Int

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertWorkoutsIgnoringConflicts(rows: List<WorkoutRow>): List<Long>

    /**
     * Commit one complete CSV projection in a single Room transaction. Official rows retain their
     * authoritative upsert/range-replacement semantics. Sleep-only and local daily rows fill null
     * fields and absent rows; local sleep, metric-series, and workout rows remain insert-only.
     */
    @Transaction
    suspend fun applyWhoopCsvImport(batch: WhoopCsvImportBatch) {
        batch.officialDailyMetricRange?.let { range ->
            if (range.fromDay <= range.toDay) {
                deleteDailyMetricRange(range.deviceId, range.fromDay, range.toDay)
            }
        }
        if (batch.officialDailyMetrics.isNotEmpty()) {
            upsertDailyMetrics(batch.officialDailyMetrics)
        }
        for ((deviceId, incoming) in batch.fillOnlyDailyMetrics.groupBy { it.deviceId }) {
            val existing = dailyMetricsRange(
                deviceId,
                incoming.minOf { it.day },
                incoming.maxOf { it.day },
            )
            val merged = mergeFillOnlyDailyMetrics(existing, incoming)
            if (merged.isNotEmpty()) upsertDailyMetrics(merged)
        }
        batch.officialSleepSessionRange?.let { range ->
            if (range.fromTs <= range.toTs) {
                deleteImportedSleepSessionRange(range.deviceId, range.fromTs, range.toTs)
            }
        }
        if (batch.officialSleepSessions.isNotEmpty()) {
            val merged = batch.officialSleepSessions.map { incoming ->
                mergeOfficialSleepSession(
                    sleepSessionByKey(incoming.deviceId, incoming.startTs),
                    incoming,
                )
            }
            upsertSleepSessions(merged)
        }
        if (batch.fillOnlySleepSessions.isNotEmpty()) {
            insertSleepSessionsIgnoringConflicts(batch.fillOnlySleepSessions)
        }

        for (replacement in batch.officialMetricSeriesReplacements) {
            if (replacement.fromDay > replacement.toDay || replacement.managedKeys.isEmpty()) continue
            deleteManagedMetricSeriesRange(
                replacement.deviceId,
                replacement.fromDay,
                replacement.toDay,
                replacement.managedKeys,
            )
            if (replacement.rows.isNotEmpty()) upsertMetricSeries(replacement.rows)
        }
        if (batch.fillOnlyMetricSeries.isNotEmpty()) {
            insertMetricSeriesIgnoringConflicts(batch.fillOnlyMetricSeries)
        }

        batch.journalReplacement?.let { replacement ->
            if (replacement.fromDay <= replacement.toDay) {
                deleteJournalRange(
                    replacement.deviceId,
                    replacement.fromDay,
                    replacement.toDay,
                )
                if (replacement.rows.isNotEmpty()) upsertJournal(replacement.rows)
            }
        }

        // Keep workouts last so a persistence failure still rolls back all earlier projection writes.
        // The source is part of importer ownership even though it is not part of WorkoutRow's PK:
        // replacing a CSV range must never delete a manual/native row sharing the same device and span.
        val officialWorkoutSource = batch.officialWorkoutSource.trim()
            .ifEmpty { WHOOP_CSV_IMPORTED_WORKOUT_SOURCE }
        batch.officialWorkoutRange?.let { range ->
            if (range.fromTs <= range.toTs) {
                deleteWorkoutRange(
                    range.deviceId,
                    officialWorkoutSource,
                    range.fromTs,
                    range.toTs,
                )
            }
        }
        if (batch.officialWorkouts.isNotEmpty()) {
            val normalized = batch.officialWorkouts.map {
                it.copy(source = officialWorkoutSource)
            }
            // `source` is not part of the workout primary key. Remove only the importer's prior
            // version, then insert with IGNORE so a manual/native row at the same natural key wins.
            for (row in normalized) {
                deleteWorkoutKeyForSource(
                    row.deviceId,
                    row.startTs,
                    row.sport,
                    officialWorkoutSource,
                )
            }
            insertWorkoutsIgnoringConflicts(normalized)
        }
        if (batch.fillOnlyWorkouts.isNotEmpty()) {
            insertWorkoutsIgnoringConflicts(batch.fillOnlyWorkouts)
        }
    }

    @Upsert
    suspend fun upsertAppleDaily(rows: List<AppleDaily>)

    // MARK: - Health Connect incremental reconciliation

    @Query("SELECT * FROM healthConnectSyncState WHERE recordType IN (:recordTypes)")
    suspend fun healthConnectSyncStates(recordTypes: List<String>): List<HealthConnectSyncStateRow>

    @Upsert
    suspend fun upsertHealthConnectSyncStates(rows: List<HealthConnectSyncStateRow>)

    @Query(
        "DELETE FROM appleDaily WHERE deviceId = :source AND day >= :fromDay AND day <= :toDay"
    )
    suspend fun deleteAppleDailyProjection(source: String, fromDay: String, toDay: String)

    @Query(
        "DELETE FROM metricSeries WHERE deviceId = :source AND day >= :fromDay AND day <= :toDay " +
            "AND `key` IN (:keys)"
    )
    suspend fun deleteMetricSeriesProjection(
        source: String,
        fromDay: String,
        toDay: String,
        keys: List<String>,
    )

    @Query(
        "DELETE FROM sleepSession WHERE deviceId = :source AND userEdited = 0 " +
            "AND startTs <= :toTs AND endTs >= :fromTs"
    )
    suspend fun deleteUneditedSleepProjection(source: String, fromTs: Long, toTs: Long)

    @Query(
        "DELETE FROM workout WHERE deviceId = :source AND source = :workoutSource " +
            "AND startTs <= :toTs AND endTs >= :fromTs"
    )
    suspend fun deleteWorkoutProjection(
        source: String,
        workoutSource: String,
        fromTs: Long,
        toTs: Long,
    )

    /**
     * Atomically replace only the Health Connect-owned part of the bounded projection. Values for
     * record types whose permission is absent are merged back from the old rows. Other source ids are
     * never named by any delete. An edited Health Connect sleep row survives via delete(userEdited=0)
     * plus INSERT IGNORE.
     */
    @Transaction
    suspend fun replaceHealthConnectProjection(
        source: String,
        workoutSource: String,
        fromDay: String,
        toDay: String,
        fromTs: Long,
        toTs: Long,
        scope: HealthConnectProjectionScope,
        appleRows: List<AppleDaily>,
        dailyRows: List<DailyMetric>,
        metricRows: List<MetricSeriesRow>,
        sleepRows: List<SleepSession>,
        workoutRows: List<WorkoutRow>,
    ) {
        val oldApple = appleDaily(source, fromDay, toDay)
        val oldDaily = dailyMetricsRange(source, fromDay, toDay)
        val oldWorkouts = workouts(source, fromTs, toTs, Int.MAX_VALUE)
            .filter { it.source == workoutSource }
        val mergedApple = HealthConnectProjectionMerge.appleDaily(source, oldApple, appleRows, scope)
        val mergedDaily = HealthConnectProjectionMerge.dailyMetrics(source, oldDaily, dailyRows, scope)
        val mergedWorkouts = HealthConnectProjectionMerge.workouts(oldWorkouts, workoutRows, scope)

        deleteAppleDailyProjection(source, fromDay, toDay)
        deleteDailyMetricsInRange(source, fromDay, toDay)
        if (scope.seriesKeys.isNotEmpty()) {
            deleteMetricSeriesProjection(source, fromDay, toDay, scope.seriesKeys.toList())
        }
        if (scope.sleep) deleteUneditedSleepProjection(source, fromTs, toTs)
        if (scope.exercise) deleteWorkoutProjection(source, workoutSource, fromTs, toTs)

        if (mergedApple.isNotEmpty()) upsertAppleDaily(mergedApple)
        if (mergedDaily.isNotEmpty()) upsertDailyMetrics(mergedDaily)
        if (metricRows.isNotEmpty()) upsertMetricSeries(metricRows)
        if (sleepRows.isNotEmpty()) insertSleepSessionsIgnoringConflicts(sleepRows)
        if (mergedWorkouts.isNotEmpty()) upsertWorkouts(mergedWorkouts)
    }

    /**
     * Manual Health Connect import is additive: it updates rows returned by this read without treating
     * an absent record/permission as a deletion. Sparse Room upserts would otherwise replace an entire
     * aggregate row and null signals imported on an earlier pass.
     */
    @Transaction
    suspend fun mergeHealthConnectProjectionAdditive(
        source: String,
        workoutSource: String,
        appleRows: List<AppleDaily>,
        dailyRows: List<DailyMetric>,
        metricRows: List<MetricSeriesRow>,
        sleepRows: List<SleepSession>,
        workoutRows: List<WorkoutRow>,
    ) {
        val oldApple = if (appleRows.isEmpty()) emptyList() else {
            appleDaily(source, appleRows.minOf { it.day }, appleRows.maxOf { it.day })
        }
        val oldDaily = if (dailyRows.isEmpty()) emptyList() else {
            dailyMetricsRange(source, dailyRows.minOf { it.day }, dailyRows.maxOf { it.day })
        }
        val oldWorkouts = if (workoutRows.isEmpty()) emptyList() else {
            workouts(
                source,
                workoutRows.minOf { it.startTs },
                workoutRows.maxOf { it.startTs },
                Int.MAX_VALUE,
            ).filter { it.source == workoutSource }
        }

        val mergedApple = HealthConnectProjectionMerge.appleDailyAdditive(oldApple, appleRows)
        val mergedDaily = HealthConnectProjectionMerge.dailyMetricsAdditive(oldDaily, dailyRows)
        val mergedWorkouts = HealthConnectProjectionMerge.workoutsAdditive(oldWorkouts, workoutRows)
        if (mergedApple.isNotEmpty()) upsertAppleDaily(mergedApple)
        if (mergedDaily.isNotEmpty()) upsertDailyMetrics(mergedDaily)
        if (metricRows.isNotEmpty()) upsertMetricSeries(metricRows)
        if (sleepRows.isNotEmpty()) insertSleepSessionsIgnoringConflicts(sleepRows)
        if (mergedWorkouts.isNotEmpty()) upsertWorkouts(mergedWorkouts)
    }

    // MARK: - Range reads (ORDER BY ts ASC, inclusive [from, to], limited)

    /** COALESCE union (#172/#219 parity with Swift's hrSamples): the measured `hrSample` is
     *  authoritative; the v26 PPG-derived `ppgHrSample` fills ONLY seconds the strap never reported a
     *  bpm for (anti-join), so a PPG-only WHOOP 5 night still clears the scoring gate and is scorable —
     *  exactly as `hrBuckets` already coalesces for charts. PPG rows carry synced = 0. */
    @Query(
        "SELECT deviceId, ts, bpm, synced FROM (" +
            "SELECT deviceId, ts, bpm, synced FROM hrSample " +
            "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.deviceId AS deviceId, p.ts AS ts, p.bpm AS bpm, 0 AS synced FROM ppgHrSample p " +
            "WHERE p.deviceId = :deviceId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)" +
            ") ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun hrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<HrSample>

    /** RAW measured HR only — the `hrSample` table with NO v26 PPG-derived union (cf. [hrSamples]).
     *  Backs the raw-sensor diagnostic export, which emits measured HR and PPG-derived HR as two
     *  distinct streams so they're never conflated. Range read, ts asc, row-limited. */
    @Query(
        "SELECT * FROM hrSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun rawHrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<HrSample>

    /** Downsampled HR for charting: mean bpm per [bucketSeconds]-wide bucket over [from, to],
     *  keyed by the bucket start (floor(ts/bucket)*bucket). Aggregated in SQL so a 24h window
     *  returns ~(to-from)/bucketSeconds rows, not every ~1 Hz sample. Mirrors macOS hrBuckets.
     *
     *  COALESCE union (#156): the real sensor `hrSample` is authoritative; the v26 PPG-derived
     *  `ppgHrSample` only contributes seconds the strap NEVER reported a bpm for (WHERE NOT EXISTS),
     *  so derived HR fills gaps without ever overriding or double-counting a true HR sample. The two
     *  selects are UNION ALL'd into one bpm stream, then bucket-averaged exactly as before. Matches
     *  the Swift hrBuckets COALESCE union. */
    @Query(
        "SELECT (ts / :bucketSeconds) * :bucketSeconds AS bucket, AVG(bpm) AS avgBpm FROM (" +
            "SELECT ts, bpm FROM hrSample " +
            "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm FROM ppgHrSample p " +
            "WHERE p.deviceId = :deviceId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)" +
            ") GROUP BY ts / :bucketSeconds ORDER BY bucket ASC"
    )
    suspend fun hrBuckets(deviceId: String, from: Long, to: Long, bucketSeconds: Long): List<HrBucket>

    /** Raw v26 PPG-derived HR samples in [from, to] (ascending). (#156) */
    @Query(
        "SELECT * FROM ppgHrSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun ppgHrSamples(deviceId: String, from: Long, to: Long, limit: Int): List<PpgHrSample>

    /** RAW v26 optical PPG waveform rows in [from, to] (ascending), packed i16 BLOB. (#156 follow-up) */
    @Query(
        "SELECT * FROM ppgWaveformSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun ppgWaveformSamples(deviceId: String, from: Long, to: Long, limit: Int):
        List<PpgWaveformSampleEntity>

    /**
     * Aggregate HR over a workout window for up to two source ids, with [primaryId] winning when the
     * same second was re-banked under both ids (#836/#1039). Each id first coalesces measured HR with
     * its PPG-derived fallback; grouping by timestamp then prevents a naive cross-id UNION from inflating
     * count/average. Passing the same id twice is the single-source control.
     */
    @Query(
        "SELECT COUNT(*) AS n, AVG(bpm) AS avg, MAX(bpm) AS max FROM (" +
            "SELECT ts, MIN(pri), bpm FROM (" +
            "SELECT ts, bpm, 0 AS pri FROM hrSample " +
            "WHERE deviceId = :primaryId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm, 0 AS pri FROM ppgHrSample p " +
            "WHERE p.deviceId = :primaryId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts) " +
            "UNION ALL " +
            "SELECT ts, bpm, 1 AS pri FROM hrSample " +
            "WHERE deviceId = :secondaryId AND ts >= :from AND ts <= :to " +
            "UNION ALL " +
            "SELECT p.ts AS ts, p.bpm AS bpm, 1 AS pri FROM ppgHrSample p " +
            "WHERE p.deviceId = :secondaryId AND p.ts >= :from AND p.ts <= :to " +
            "AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts) " +
            ") GROUP BY ts" +
            ")"
    )
    suspend fun hrWindowStats(
        primaryId: String,
        secondaryId: String,
        from: Long,
        to: Long,
    ): HrWindowStats

    @Query(
        // ord preserves same-second emission order; legacy NULLs fall through to deterministic value order.
        // Oura's SpO2 IBI stream (durable channel 2) duplicates its green beat train, so it remains stored
        // for diagnostics but is excluded from scoring. NULL keeps all WHOOP and pre-migration rows.
        "SELECT * FROM rrInterval WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "AND (tsSuspect IS NULL OR tsSuspect <> 1) " +
            "AND (srcChannel IS NULL OR srcChannel <> 2) " +
            "ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :limit"
    )
    suspend fun rrIntervals(deviceId: String, from: Long, to: Long, limit: Int): List<RrInterval>

    @Query(
        "SELECT * FROM event WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC, kind ASC LIMIT :limit"
    )
    suspend fun events(deviceId: String, from: Long, to: Long, limit: Int): List<EventRow>

    @Query(
        "SELECT * FROM battery WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun batterySamples(deviceId: String, from: Long, to: Long, limit: Int): List<BatterySample>

    @Query(
        "SELECT * FROM spo2Sample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun spo2Samples(deviceId: String, from: Long, to: Long, limit: Int): List<Spo2Sample>

    @Query(
        "SELECT * FROM skinTempSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun skinTempSamples(deviceId: String, from: Long, to: Long, limit: Int): List<SkinTempSample>

    @Query(
        "SELECT * FROM stepSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun stepSamples(deviceId: String, from: Long, to: Long, limit: Int): List<StepSample>

    /** The strap's OWN banked band sleep_state (#175) in [from, to], ascending. Feeds the Deep Timeline
     *  band-state track and the per-session grid the H7 re-onset confirm guard reads. */
    @Query(
        "SELECT * FROM sleepStateSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun sleepStateSamples(deviceId: String, from: Long, to: Long, limit: Int): List<SleepStateSampleEntity>

    @Query(
        "SELECT * FROM respSample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun respSamples(deviceId: String, from: Long, to: Long, limit: Int): List<RespSample>

    @Query(
        "SELECT * FROM gravitySample WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to " +
            "ORDER BY ts ASC LIMIT :limit"
    )
    suspend fun gravitySamples(deviceId: String, from: Long, to: Long, limit: Int): List<GravitySample>

    // MARK: - Daily metrics / sleep reads (mirror MetricsCache.swift)

    /**
     * Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
     * Port of MetricsCache.swift dailyMetrics(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun dailyMetricsRange(deviceId: String, from: String, to: String): List<DailyMetric>

    /**
     * Delete a source's cached daily rows whose day-key is in [from, to] (inclusive, yyyy-MM-dd
     * lexicographic = chronological). The #277 local-day re-bucketing migration uses this to drop the
     * computed ("-noop") UTC-keyed rows across the recompute window before re-upserting the LOCAL-keyed
     * rows, so a UTC/local duplicate day can't linger. Source-scoped, so imported "my-whoop" rows are
     * never touched. Mirrors WhoopStore MetricsCache.deleteDailyMetrics.
     */
    @Query("DELETE FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun deleteDailyMetricsInRange(deviceId: String, from: String, to: String)

    /** All cached daily metrics for a device, oldest first. Convenience for analytics windows. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    suspend fun days(deviceId: String): List<DailyMetric>

    /** Bounded daily-metric read for event-driven policies that need source fidelity without loading
     *  years of history on every fresh observation. ISO day keys preserve chronological ordering. */
    @Query(
        "SELECT * FROM dailyMetric WHERE deviceId = :deviceId " +
            "AND day >= :from AND day <= :to ORDER BY day ASC"
    )
    suspend fun daysInRange(deviceId: String, from: String, to: String): List<DailyMetric>

    /** Scalar COUNT twin of [days], for count badges that were materializing every row for `.size`. */
    @Query("SELECT COUNT(*) FROM dailyMetric WHERE deviceId = :deviceId")
    suspend fun daysCount(deviceId: String): Int

    /** Reactive stream of all daily metrics for a device, oldest first. */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day ASC")
    fun daysFlow(deviceId: String): Flow<List<DailyMetric>>

    /**
     * Every distinct source id with at least one cached daily row. The Health Connect backfill's
     * covered-days gate filters these to the strap-native ids
     * (HealthConnectImporter.isStrapNativeSourceId), so its #112 skip-set also covers an actively
     * paired strap's "whoop-<mac>" / "whoop-<mac>-noop" rows - not just the canonical
     * "my-whoop" / "my-whoop-noop" pair.
     */
    @Query("SELECT DISTINCT deviceId FROM dailyMetric")
    suspend fun dailyMetricDeviceIds(): List<String>

    /**
     * #112 follow-up heal: delete un-edited "my-whoop" sleep sessions that carry NO signal beyond a
     * window (no efficiency / restingHr / avgHrv / motionJSON / sleepStateJSON — exactly the shape the
     * Health Connect backfill writes) when a computed ("-noop") session overlaps the same window.
     * These are the shadow rows an HC import wrote while the covered-days gate missed active-strap
     * ids; once purged, the richer computed night wins the merge again. Rows a WHOOP CSV / wearable
     * export wrote carry efficiency (or HR/HRV), and userEdited rows are never touched, so real data
     * survives. Idempotent: a re-run matches nothing.
     */
    @Query(
        "DELETE FROM sleepSession WHERE deviceId = 'my-whoop' AND userEdited = 0 " +
            "AND efficiency IS NULL AND restingHr IS NULL AND avgHrv IS NULL " +
            "AND motionJSON IS NULL AND sleepStateJSON IS NULL " +
            "AND EXISTS (SELECT 1 FROM sleepSession c WHERE c.deviceId LIKE '%-noop' " +
            "AND c.startTs < sleepSession.endTs AND c.endTs > sleepSession.startTs)"
    )
    suspend fun purgeHcShadowedSleepSessions(): Int

    /**
     * #112 follow-up heal (daily half): delete "my-whoop" daily rows shaped like the Health Connect
     * backfill (no efficiency / stage minutes / disturbances / recovery / strain / steps — HC only
     * writes totals + vitals) on a day a computed ("-noop") source also covers. A sparse row like
     * this shadows the computed day in the imported-wins merge (#112), blanking Today / regressing
     * Sleep stages. CSV-imported days carry stage minutes + efficiency and are never matched.
     */
    @Query(
        "DELETE FROM dailyMetric WHERE deviceId = 'my-whoop' " +
            "AND efficiency IS NULL AND deepMin IS NULL AND remMin IS NULL AND lightMin IS NULL " +
            "AND disturbances IS NULL AND recovery IS NULL AND strain IS NULL " +
            "AND steps IS NULL AND activeKcalEst IS NULL " +
            "AND day IN (SELECT day FROM dailyMetric d WHERE d.deviceId LIKE '%-noop')"
    )
    suspend fun purgeHcShadowedDailyMetrics(): Int

    /**
     * #797: the most-recent [limit] daily metrics for a device, returned oldest-first. Backs the bounded
     * dashboard merge: the SQL takes the newest rows (ORDER BY day DESC LIMIT), and the repository flips
     * them to ascending so every downstream consumer sees the SAME oldest-first order as [daysFlow]. A
     * generous bound (the repository's RECENT_DAYS_CAP) keeps every current surface intact (Trends' deepest
     * view, Fitness Age / Vitality 7-day windows) while a years-deep import no longer re-merges the WHOLE
     * history on every DB change.
     */
    @Query("SELECT * FROM dailyMetric WHERE deviceId = :deviceId ORDER BY day DESC LIMIT :limit")
    fun recentDaysFlow(deviceId: String, limit: Int): Flow<List<DailyMetric>>

    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun sleepSessions(deviceId: String, from: Long, to: Long, limit: Int): List<SleepSession>

    /**
     * Complete, uncapped sleep read for a set of source namespaces. This is intentionally separate from
     * bounded presentation/export reads: a destructive external-store replacement must either observe
     * every local row in its range or fail, never mistake a query cap for the end of history.
     */
    @Query(
        "SELECT * FROM sleepSession WHERE deviceId IN (:deviceIds) " +
            "AND startTs >= :from AND startTs <= :to ORDER BY deviceId ASC, startTs ASC"
    )
    suspend fun sleepSessionsForSources(
        deviceIds: List<String>,
        from: Long,
        to: Long,
    ): List<SleepSession>

    /** Complete source timeline used to assign edited fragments after bridge-before-wake-day grouping. */
    @Query("SELECT * FROM sleepSession WHERE deviceId = :deviceId ORDER BY startTs ASC")
    fun sleepSessionsFlow(deviceId: String): Flow<List<SleepSession>>

    /** Keyset-paged twin used by optional self-hosted export so local deletes cannot shift an OFFSET. */
    @Query(
        "SELECT * FROM sleepSession WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "AND (:afterStartTs IS NULL OR startTs > :afterStartTs) " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun remoteSleepSessions(
        deviceId: String,
        from: Long,
        to: Long,
        afterStartTs: Long?,
        limit: Int,
    ): List<SleepSession>

    /** Hand-edited sessions for a device (userEdited = 1), oldest first. Backs the H5 edit-merge (#509):
     *  the repository maps each to its LOCAL wake-day so [WhoopRepository.mergeDaily] lets the computed
     *  sleep fields win on those days over a re-imported night. */
    @Query("SELECT * FROM sleepSession WHERE deviceId = :deviceId AND userEdited = 1 ORDER BY startTs ASC")
    suspend fun editedSleepSessions(deviceId: String): List<SleepSession>

    /** Reactive variant of [editedSleepSessions] for the merged daily Flow. */
    @Query("SELECT * FROM sleepSession WHERE deviceId = :deviceId AND userEdited = 1 ORDER BY startTs ASC")
    fun editedSleepSessionsFlow(deviceId: String): Flow<List<SleepSession>>

    // MARK: - Generic metric series (Swift metricSeries, v9)

    @Query(
        "SELECT * FROM metricSeries WHERE deviceId = :deviceId AND key = :key AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun metricSeries(
        deviceId: String,
        key: String,
        from: String,
        to: String,
    ): List<MetricSeriesRow>

    /** Every scalar recorded on one exact local day, retaining source partition. */
    @Query("SELECT * FROM metricSeries WHERE day = :day ORDER BY deviceId ASC, key ASC")
    suspend fun metricSeriesForDay(day: String): List<MetricSeriesRow>

    /** Distinct metric keys present for a device, sorted ascending (Swift metricKeys, v9). */
    @Query("SELECT DISTINCT key FROM metricSeries WHERE deviceId = :deviceId ORDER BY key ASC")
    suspend fun metricKeys(deviceId: String): List<String>

    /** Row count for one (deviceId, key) series — the scalar COUNT twin of [metricSeries], for count
     *  badges (Data Sources) that were materializing the full history just to call `.size`. */
    @Query("SELECT COUNT(*) FROM metricSeries WHERE deviceId = :deviceId AND key = :key")
    suspend fun metricSeriesKeyCount(deviceId: String, key: String): Int

    /** The NEWEST row of a (deviceId, key) series, or null — the ORDER BY day DESC LIMIT 1 twin of
     *  [metricSeries] for latest-value tiles (day is yyyy-MM-dd, so lexicographic MAX(day) = newest).
     *  Rides the same idx_metricSeries_device_key_day index, so the read stops at one row instead of
     *  materializing the whole series for a `.lastOrNull()`. */
    @Query("SELECT * FROM metricSeries WHERE deviceId = :deviceId AND key = :key ORDER BY day DESC LIMIT 1")
    suspend fun latestMetricSeriesRow(deviceId: String, key: String): MetricSeriesRow?

    /** Delete one projected day for a key (used when a Lab Book reading's last numeric value
     *  for a (markerKey, day) cell is removed). Swift LabMarkerStore.reprojectCells delete branch. */
    @Query("DELETE FROM metricSeries WHERE deviceId = :deviceId AND day = :day AND key = :key")
    suspend fun deleteMetricSeriesPoint(deviceId: String, day: String, key: String)

    /** Physically delete one complete source/key series. Used for explicit deletion of sensitive,
     *  user-owned local series such as period-start history; unrelated keys and sources are untouched. */
    @Query("DELETE FROM metricSeries WHERE deviceId = :deviceId AND key = :key")
    suspend fun deleteMetricSeries(deviceId: String, key: String): Int

    // MARK: - Editable nutrition log (Swift nutritionEntry v39)

    @Upsert
    suspend fun upsertNutritionEntriesRaw(rows: List<NutritionEntryRow>)

    @Query(
        "SELECT * FROM nutritionEntry WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC, occurredAt ASC, createdAt ASC, id ASC"
    )
    suspend fun nutritionEntries(
        deviceId: String,
        from: String,
        to: String,
    ): List<NutritionEntryRow>

    @Query("SELECT * FROM nutritionEntry WHERE id = :id")
    suspend fun nutritionEntry(id: String): NutritionEntryRow?

    @Query(
        "SELECT * FROM nutritionEntry WHERE deviceId = :deviceId AND origin = :origin " +
            "AND day <= :throughDay ORDER BY occurredAt DESC, updatedAt DESC, id DESC LIMIT :limit"
    )
    suspend fun recentManualNutritionEntriesRaw(
        deviceId: String,
        origin: String,
        throughDay: String,
        limit: Int,
    ): List<NutritionEntryRow>

    @Query("DELETE FROM nutritionEntry WHERE id = :id")
    suspend fun deleteNutritionEntryRaw(id: String)

    @Transaction
    suspend fun nutritionTotals(deviceId: String, day: String): NutritionDailyTotals =
        NutritionLogContract.resolvedTotals(
            entries = nutritionEntries(deviceId, day, day),
            day = day,
            deviceId = deviceId,
        )

    @Transaction
    suspend fun recentManualNutritionEntries(
        deviceId: String,
        throughDay: String,
        limit: Int,
    ): List<NutritionEntryRow> {
        val queryLimit = (limit * 12).coerceIn(24, 240)
        val rows = recentManualNutritionEntriesRaw(
            deviceId = deviceId,
            origin = NutritionLogContract.MANUAL_ORIGIN,
            throughDay = throughDay,
            limit = queryLimit,
        )
        return NutritionLogContract.recentManualEntries(
            entries = rows,
            limit = limit,
            deviceId = deviceId,
        )
    }

    @Transaction
    suspend fun upsertNutritionEntries(rows: List<NutritionEntryRow>) {
        if (rows.isEmpty()) return
        val clean = rows.map(NutritionLogContract::validated)
        val touched = LinkedHashSet<Pair<String, String>>()
        for (row in clean) {
            nutritionEntry(row.id)?.let { touched += it.deviceId to it.day }
        }
        upsertNutritionEntriesRaw(clean)
        for (row in clean) touched += row.deviceId to row.day
        for ((deviceId, day) in touched) reprojectNutritionDay(deviceId, day)
    }

    @Transaction
    suspend fun deleteNutritionEntry(id: String): Boolean {
        val row = nutritionEntry(id) ?: return false
        deleteNutritionEntryRaw(id)
        reprojectNutritionDay(row.deviceId, row.day)
        return true
    }

    @Transaction
    suspend fun reprojectNutritionDay(deviceId: String, day: String) {
        val totals = nutritionTotals(deviceId, day)
        val values = listOf(
            NutritionLogContract.CALORIES_KEY to totals.caloriesKcal,
            NutritionLogContract.PROTEIN_KEY to totals.proteinG,
            NutritionLogContract.CARBS_KEY to totals.carbsG,
            NutritionLogContract.FAT_KEY to totals.fatG,
        )
        for ((key, value) in values) {
            if (value != null) {
                upsertMetricSeries(listOf(MetricSeriesRow(deviceId, day, key, value)))
            } else {
                deleteMetricSeriesPoint(deviceId, day, key)
            }
        }
    }

    // MARK: - Saved food/meal library and barcode cache (Swift v43)

    @Upsert
    suspend fun upsertNutritionCatalogItemsRaw(rows: List<NutritionCatalogItemRow>)

    @Query(
        "SELECT * FROM nutritionCatalogItem WHERE (:savedOnly = 0 OR isSaved = 1) " +
            "ORDER BY isSaved DESC, COALESCE(lastUsedAt, 0) DESC, updatedAt DESC, " +
            "name COLLATE NOCASE ASC, id ASC LIMIT :limit",
    )
    suspend fun nutritionCatalogItemsRaw(
        savedOnly: Boolean,
        limit: Int,
    ): List<NutritionCatalogItemRow>

    @Query("SELECT * FROM nutritionCatalogItem WHERE id = :id")
    suspend fun nutritionCatalogItem(id: String): NutritionCatalogItemRow?

    @Query("SELECT * FROM nutritionCatalogItem WHERE barcode = :barcode LIMIT 1")
    suspend fun nutritionCatalogItemByBarcode(barcode: String): NutritionCatalogItemRow?

    @Query(
        "UPDATE nutritionCatalogItem SET lastUsedAt = :timestamp, " +
            "updatedAt = MAX(updatedAt, :timestamp) WHERE id = :id",
    )
    suspend fun markNutritionCatalogItemUsedRaw(id: String, timestamp: Long): Int

    @Query("DELETE FROM nutritionCatalogItem WHERE id = :id")
    suspend fun deleteNutritionCatalogItemRaw(id: String): Int

    suspend fun upsertNutritionCatalogItems(rows: List<NutritionCatalogItemRow>) {
        if (rows.isEmpty()) return
        upsertNutritionCatalogItemsRaw(rows.map(NutritionCatalogContract::validated))
    }

    suspend fun nutritionCatalogItems(
        savedOnly: Boolean = true,
        limit: Int = 250,
    ): List<NutritionCatalogItemRow> =
        nutritionCatalogItemsRaw(savedOnly, limit.coerceIn(1, 500_000))

    suspend fun nutritionCatalogItemForBarcode(rawBarcode: String): NutritionCatalogItemRow? {
        val barcode = requireNotNull(NutritionCatalogContract.normalizedBarcode(rawBarcode)) {
            "invalid barcode"
        }
        return nutritionCatalogItemByBarcode(barcode)
    }

    suspend fun markNutritionCatalogItemUsed(id: String, timestamp: Long): Boolean {
        require(timestamp > 0L) { "invalid nutrition catalog timestamp" }
        return markNutritionCatalogItemUsedRaw(id, timestamp) > 0
    }

    suspend fun deleteNutritionCatalogItem(id: String): Boolean =
        deleteNutritionCatalogItemRaw(id) > 0

    // MARK: - Strength training (Swift v40)

    @Upsert
    suspend fun upsertStrengthExercisesRaw(rows: List<StrengthExerciseRow>)

    @Query(
        "SELECT * FROM strengthExercise WHERE (:includeArchived = 1 OR archivedAt IS NULL) " +
            "ORDER BY isCustom ASC, name COLLATE NOCASE ASC, id ASC",
    )
    suspend fun strengthExercises(includeArchived: Boolean = false): List<StrengthExerciseRow>

    @Query("SELECT * FROM strengthExercise WHERE id = :id")
    suspend fun strengthExercise(id: String): StrengthExerciseRow?

    @Query("SELECT COUNT(*) FROM strengthExercise WHERE id = :id")
    suspend fun strengthExerciseCount(id: String): Int

    @Upsert
    suspend fun upsertStrengthRoutineRaw(row: StrengthRoutineRow)

    @Upsert
    suspend fun upsertStrengthRoutineExercisesRaw(rows: List<StrengthRoutineExerciseRow>)

    @Query("DELETE FROM strengthRoutineExercise WHERE routineId = :routineId")
    suspend fun deleteStrengthRoutineExercises(routineId: String)

    @Query(
        "SELECT * FROM strengthRoutine WHERE (:includeArchived = 1 OR archivedAt IS NULL) " +
            "ORDER BY updatedAt DESC, name COLLATE NOCASE ASC, id ASC",
    )
    suspend fun strengthRoutineRows(includeArchived: Boolean = false): List<StrengthRoutineRow>

    @Query("SELECT * FROM strengthRoutine WHERE id = :id")
    suspend fun strengthRoutineRow(id: String): StrengthRoutineRow?

    @Query(
        "SELECT * FROM strengthRoutineExercise WHERE routineId = :routineId " +
            "ORDER BY position ASC, id ASC",
    )
    suspend fun strengthRoutineExercises(routineId: String): List<StrengthRoutineExerciseRow>

    @Query("SELECT COUNT(*) FROM strengthRoutine WHERE id = :id")
    suspend fun strengthRoutineCount(id: String): Int

    @Transaction
    suspend fun saveStrengthRoutine(
        routine: StrengthRoutineRow,
        exercises: List<StrengthRoutineExerciseRow>,
    ): StrengthRoutineSnapshot {
        val cleanRoutine = StrengthTrainingContract.validated(routine)
        val cleanExercises = exercises.map(StrengthTrainingContract::validated)
        require(cleanExercises.all { it.routineId == cleanRoutine.id }) {
            "strength routine exercise belongs to another routine"
        }
        for (exerciseId in cleanExercises.map { it.exerciseId }.distinct()) {
            require(strengthExerciseCount(exerciseId) == 1) { "unknown strength exercise" }
        }
        upsertStrengthRoutineRaw(cleanRoutine)
        deleteStrengthRoutineExercises(cleanRoutine.id)
        if (cleanExercises.isNotEmpty()) {
            upsertStrengthRoutineExercisesRaw(cleanExercises.sortedWith(compareBy({ it.position }, { it.id })))
        }
        return StrengthRoutineSnapshot(cleanRoutine, cleanExercises)
    }

    @Transaction
    suspend fun strengthRoutines(includeArchived: Boolean = false): List<StrengthRoutineSnapshot> =
        strengthRoutineRows(includeArchived).map { routine ->
            StrengthRoutineSnapshot(routine, strengthRoutineExercises(routine.id))
        }

    @Upsert
    suspend fun upsertStrengthSessionRaw(row: StrengthSessionRow)

    @Upsert
    suspend fun upsertStrengthSetsRaw(rows: List<StrengthSetRow>)

    @Query("DELETE FROM strengthSet WHERE sessionId = :sessionId")
    suspend fun deleteStrengthSets(sessionId: String)

    @Query(
        "SELECT * FROM strengthSession WHERE startedAt >= :from AND startedAt <= :to " +
            "AND (:includeInProgress = 1 OR endedAt IS NOT NULL) ORDER BY startedAt DESC, id ASC",
    )
    suspend fun strengthSessionRows(
        from: Long,
        to: Long,
        includeInProgress: Boolean = true,
    ): List<StrengthSessionRow>

    @Query("SELECT * FROM strengthSession WHERE id = :id")
    suspend fun strengthSessionRow(id: String): StrengthSessionRow?

    @Query(
        "SELECT * FROM strengthSet WHERE sessionId = :sessionId " +
            "ORDER BY exercisePosition ASC, setPosition ASC, id ASC",
    )
    suspend fun strengthSets(sessionId: String): List<StrengthSetRow>

    @Query("SELECT COUNT(*) FROM strengthSession WHERE id = :id")
    suspend fun strengthSessionCount(id: String): Int

    @Query("DELETE FROM strengthSession WHERE id = :id")
    suspend fun deleteStrengthSessionRaw(id: String)

    @Transaction
    suspend fun saveStrengthSession(
        session: StrengthSessionRow,
        sets: List<StrengthSetRow>,
    ): StrengthSessionSnapshot {
        val cleanSession = StrengthTrainingContract.validated(session)
        val cleanSets = sets.map(StrengthTrainingContract::validated)
        require(cleanSets.all { it.sessionId == cleanSession.id }) {
            "strength set belongs to another session"
        }
        cleanSession.routineId?.let {
            require(strengthRoutineCount(it) == 1) { "unknown strength routine" }
        }
        for (exerciseId in cleanSets.map { it.exerciseId }.distinct()) {
            require(strengthExerciseCount(exerciseId) == 1) { "unknown strength exercise" }
        }
        upsertStrengthSessionRaw(cleanSession)
        deleteStrengthSets(cleanSession.id)
        if (cleanSets.isNotEmpty()) {
            upsertStrengthSetsRaw(
                cleanSets.sortedWith(
                    compareBy({ it.exercisePosition }, { it.setPosition }, { it.id }),
                ),
            )
        }
        return StrengthSessionSnapshot(cleanSession, cleanSets)
    }

    @Transaction
    suspend fun strengthSessions(
        from: Long = 0,
        to: Long = Long.MAX_VALUE,
        includeInProgress: Boolean = true,
    ): List<StrengthSessionSnapshot> =
        strengthSessionRows(from, to, includeInProgress).map { session ->
            StrengthSessionSnapshot(session, strengthSets(session.id))
        }

    @Transaction
    suspend fun deleteStrengthSession(id: String): Boolean {
        if (strengthSessionCount(id) != 1) return false
        deleteStrengthSets(id)
        deleteStrengthSessionRaw(id)
        return true
    }

    @Query(
        "SELECT COUNT(DISTINCT s.id) AS sessionCount, COUNT(st.id) AS completedSetCount, " +
            "COALESCE(SUM(st.reps), 0) AS totalReps, " +
            "COALESCE(SUM(CASE WHEN st.loadKg IS NOT NULL AND st.reps IS NOT NULL " +
            "THEN st.loadKg * st.reps ELSE 0 END), 0) AS loadedVolumeKg, " +
            "COALESCE(SUM(CASE WHEN st.loadKg IS NOT NULL AND st.reps IS NOT NULL " +
            "THEN 1 ELSE 0 END), 0) AS loadedVolumeSetCount " +
            "FROM strengthSession s LEFT JOIN strengthSet st " +
            "ON st.sessionId = s.id AND st.completedAt IS NOT NULL " +
            "WHERE s.startedAt >= :from AND s.startedAt <= :to AND s.endedAt IS NOT NULL",
    )
    suspend fun strengthSummary(from: Long, to: Long): StrengthSummary

    @Query(
        "SELECT :exerciseId AS exerciseId, COUNT(*) AS completedSetCount, " +
            "MAX(loadKg) AS maxLoadKg, MAX(reps) AS maxReps, " +
            "MAX(CASE WHEN loadKg IS NOT NULL AND reps IS NOT NULL " +
            "THEN loadKg * reps END) AS bestSetVolumeKg " +
            "FROM strengthSet WHERE exerciseId = :exerciseId AND completedAt IS NOT NULL",
    )
    suspend fun strengthExerciseProgress(exerciseId: String): StrengthExerciseProgress

    // MARK: - Lab Book markers (Swift labMarker, v17 / LabMarkerStore.swift)
    //
    // The book is `labMarker` (one row per dated reading the user entered themselves); the daily
    // `metricSeries` projection under source [LAB_BOOK_SOURCE_ID] is HOW the book talks to the rest
    // of the app. [upsertLabMarkers] / [deleteLabMarker] keep the two in lockstep in a single
    // transaction, byte-identical to the Swift LabMarkerStore.

    /** Raw upsert of marker rows by the natural key (UNIQUE index idx_labMarker_natural): a
     *  re-import of the same (deviceId, markerKey, takenAt, source) REPLACEs in place rather than
     *  duplicating, mirroring the Swift `ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE`.
     *  Prefer [upsertLabMarkers] (which also re-projects); this primitive backs it. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertLabMarkersRaw(rows: List<LabMarkerRow>)

    /** All readings in a category, oldest first (by takenAt). */
    @Query("SELECT * FROM labMarker WHERE deviceId = :deviceId AND category = :category ORDER BY takenAt ASC")
    suspend fun labMarkersByCategory(deviceId: String, category: String): List<LabMarkerRow>

    /** Full reading history for one marker, oldest first (by takenAt). */
    @Query("SELECT * FROM labMarker WHERE deviceId = :deviceId AND markerKey = :markerKey ORDER BY takenAt ASC")
    suspend fun labMarkersByKey(deviceId: String, markerKey: String): List<LabMarkerRow>

    /** Distinct marker keys present for a device, sorted ascending. */
    @Query("SELECT DISTINCT markerKey FROM labMarker WHERE deviceId = :deviceId ORDER BY markerKey ASC")
    suspend fun markerKeysPresent(deviceId: String): List<String>

    /** One reading by id, or null. Backs the delete-then-reproject flow. */
    @Query("SELECT * FROM labMarker WHERE id = :id")
    suspend fun labMarkerById(id: String): LabMarkerRow?

    /** Latest NUMERIC value for a (markerKey, day) cell (greatest takenAt with value not null),
     *  or null if the cell has no numeric reading. The latest-per-day projection rule. */
    @Query(
        "SELECT value FROM labMarker " +
            "WHERE deviceId = :deviceId AND markerKey = :markerKey AND day = :day AND value IS NOT NULL " +
            "ORDER BY takenAt DESC LIMIT 1"
    )
    suspend fun latestNumericForCell(deviceId: String, markerKey: String, day: String): Double?

    @Query("DELETE FROM labMarker WHERE id = :id")
    suspend fun deleteLabMarkerRaw(id: String)

    /**
     * Upsert marker rows, then re-project each affected (markerKey, day) cell into `metricSeries`
     * under [LAB_BOOK_SOURCE_ID]. Idempotent by natural key; LATEST-numeric-per-day wins in the
     * projection (qualitative valueText-only readings never project a REAL cell). Atomic — the
     * marker write and the projection can't diverge. Byte-identical to Swift
     * WhoopStore.upsertLabMarkers.
     */
    @Transaction
    suspend fun upsertLabMarkers(rows: List<LabMarkerRow>) {
        if (rows.isEmpty()) return
        insertLabMarkersRaw(rows)
        // Distinct touched cells, in a deterministic order.
        val cells = rows.map { Triple(it.deviceId, it.markerKey, it.day) }.toSet()
        for ((deviceId, markerKey, day) in cells) {
            reprojectCell(deviceId, markerKey, day)
        }
    }

    /**
     * Delete one reading by id; if it was the last numeric reading for its (markerKey, day) cell the
     * projected day is removed, otherwise the projection is recomputed from the remainder. Returns
     * true if a row was deleted. Byte-identical to Swift WhoopStore.deleteLabMarker.
     */
    @Transaction
    suspend fun deleteLabMarker(id: String): Boolean {
        val row = labMarkerById(id) ?: return false
        deleteLabMarkerRaw(id)
        reprojectCell(row.deviceId, row.markerKey, row.day)
        return true
    }

    /** Recompute the `metricSeries` projection (under [LAB_BOOK_SOURCE_ID]) for one cell from the
     *  CURRENT labMarker rows: latest-numeric-per-day wins; no numeric reading → drop the day. */
    @Transaction
    suspend fun reprojectCell(deviceId: String, markerKey: String, day: String) {
        val latest = latestNumericForCell(deviceId, markerKey, day)
        if (latest != null) {
            upsertMetricSeries(listOf(MetricSeriesRow(LAB_BOOK_SOURCE_ID, day, markerKey, latest)))
        } else {
            deleteMetricSeriesPoint(LAB_BOOK_SOURCE_ID, day, markerKey)
        }
    }

    companion object {
        /** The constant device-id the daily marker projection is written under, so Compare/Explore/
         *  Coach see markers as a single-source series (Swift WhoopStore.labBookSourceId). */
        const val LAB_BOOK_SOURCE_ID = "lab-book"
    }

    // MARK: - One-time #34 refile: separate legacy Health Connect data from the Apple Health bucket.
    // Only an Apple Health EXPORT writes metricSeries, so metricSeries-count==0 means the apple-health
    // daily rows are Health-Connect-origin and safe to move. HC workouts are tagged source so they move
    // unconditionally. Safe on first run: no `to` rows exist yet (no PK conflict), and post-#34 nothing
    // ever writes HC data to apple-health again, so it's idempotent (re-runs match 0 rows).
    @Query("SELECT COUNT(*) FROM metricSeries WHERE deviceId = :deviceId")
    suspend fun metricSeriesCount(deviceId: String): Int

    @Query("UPDATE appleDaily SET deviceId = :to WHERE deviceId = :from")
    suspend fun reassignAppleDaily(from: String, to: String)

    @Query("UPDATE workout SET deviceId = :to WHERE deviceId = :from AND source = :source")
    suspend fun reassignWorkoutsBySource(from: String, to: String, source: String)

    // MARK: - Journal / workouts / Apple-Health reads (mirror JournalWorkoutAppleCache.swift, v8)

    /**
     * Journal entries for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest day first
     * then by question. Port of JournalWorkoutAppleCache.swift journalEntries(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC, question ASC"
    )
    suspend fun journal(deviceId: String, from: String, to: String): List<JournalEntry>

    /** Natural-key paged twin for the bounded self-hosted sync request. */
    @Query(
        "SELECT * FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "AND (:afterDay IS NULL OR day > :afterDay OR " +
            "(day = :afterDay AND question > COALESCE(:afterQuestion, ''))) " +
            "ORDER BY day ASC, question ASC LIMIT :limit"
    )
    suspend fun remoteJournal(
        deviceId: String,
        from: String,
        to: String,
        afterDay: String?,
        afterQuestion: String?,
        limit: Int,
    ): List<JournalEntry>

    /**
     * Delete one journal answer by natural key (the native logging card's "clear"). Source-scoped
     * by deviceId, so clearing a native ("noop-journal") answer never removes an identical imported
     * row. Port of JournalWorkoutAppleCache.swift deleteJournal(deviceId:day:question:).
     */
    @Query("DELETE FROM journal WHERE deviceId = :deviceId AND day = :day AND question = :question")
    suspend fun deleteJournalEntry(deviceId: String, day: String, question: String)

    /**
     * Delete a device's journal within a day range (#136). The WHOOP importer clears exactly the span
     * it re-writes before upserting, so the wake-day keying fix doesn't leave pre-fix onset-keyed rows
     * behind as duplicates. Bounded to [from, to] — journal outside the imported range is never touched.
     * Source-scoped by deviceId, so the native ("noop-journal") log is never touched.
     */
    @Query("DELETE FROM journal WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun deleteJournalRange(deviceId: String, from: String, to: String)

    /**
     * Atomically replace a device's journal within a day range (#136): clear [from, to] then upsert
     * [rows] in ONE transaction, so a crash mid-import can't leave the range deleted-but-not-repopulated.
     */
    @Transaction
    suspend fun replaceJournalRange(deviceId: String, from: String, to: String, rows: List<JournalEntry>) {
        deleteJournalRange(deviceId, from, to)
        upsertJournal(rows)
    }

    /**
     * Workouts whose startTs falls in [from, to] (unix seconds), oldest first, row-limited.
     * Port of JournalWorkoutAppleCache.swift workouts(deviceId:from:to:limit:).
     */
    @Query(
        "SELECT * FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun workouts(deviceId: String, from: Long, to: Long, limit: Int): List<WorkoutRow>

    /** Newest workout across every source namespace. Notification frontiers must include imported,
     *  detected, old-strap and current-strap rows even when the Workouts screen has never loaded. */
    @Query("SELECT MAX(startTs) FROM workout")
    suspend fun latestWorkoutStartAllSources(): Long?

    /** Every workout from every device/source that overlaps [from, to]. Auto-suggestion exclusion must
     *  be source-complete: imported files, current/old straps, computed siblings and future sources all
     *  suppress a duplicate prompt without maintaining a hard-coded id list. */
    @Query(
        "SELECT * FROM workout WHERE endTs >= :from AND startTs <= :to " +
            "ORDER BY startTs ASC LIMIT :limit"
    )
    suspend fun workoutsOverlappingAllSources(from: Long, to: Long, limit: Int): List<WorkoutRow>

    /** Natural-key paged twin for the bounded self-hosted sync request. */
    @Query(
        "SELECT * FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to " +
            "AND (:afterStartTs IS NULL OR startTs > :afterStartTs OR " +
            "(startTs = :afterStartTs AND sport > COALESCE(:afterSport, ''))) " +
            "ORDER BY startTs ASC, sport ASC LIMIT :limit"
    )
    suspend fun remoteWorkouts(
        deviceId: String,
        from: Long,
        to: Long,
        afterStartTs: Long?,
        afterSport: String?,
        limit: Int,
    ): List<WorkoutRow>

    /** Scalar COUNT twin of [workouts] (no row limit — a count badge wants the exact total), for
     *  badges that were materializing the row list for `.size`. */
    @Query("SELECT COUNT(*) FROM workout WHERE deviceId = :deviceId AND startTs >= :from AND startTs <= :to")
    suspend fun workoutsCount(deviceId: String, from: Long, to: Long): Int

    @Query(
        "SELECT COALESCE(SUM(steps), 0) FROM workout " +
            "WHERE deviceId = :deviceId AND steps IS NOT NULL AND startTs >= :from AND startTs < :to"
    )
    suspend fun sumWorkoutSteps(deviceId: String, from: Long, to: Long): Int

    /**
     * Apple-Health daily aggregates for days in [from, to] (lexicographic compare), oldest first.
     * Port of JournalWorkoutAppleCache.swift appleDaily(deviceId:from:to:).
     */
    @Query(
        "SELECT * FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to " +
            "ORDER BY day ASC"
    )
    suspend fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>

    /** Scalar COUNT twin of [appleDaily], for badges that were materializing the rows for `.size`. */
    @Query("SELECT COUNT(*) FROM appleDaily WHERE deviceId = :deviceId AND day >= :from AND day <= :to")
    suspend fun appleDailyCount(deviceId: String, from: String, to: String): Int

    /** Delete a computed source's workouts of a given [sport] whose startTs is in [from, to]
     *  (makes detected-workout re-derivation idempotent). (#78) */
    @Query("DELETE FROM workout WHERE deviceId = :deviceId AND sport = :sport AND startTs >= :from AND startTs <= :to")
    suspend fun deleteWorkoutsBySport(deviceId: String, sport: String, from: Long, to: Long)

    /** Delete ONE workout by its full natural key (deviceId, startTs, sport). Used by the Workouts
     *  screen to remove a single manual / re-labelled session. (#107) */
    @Query("DELETE FROM workout WHERE deviceId = :deviceId AND startTs = :startTs AND sport = :sport")
    suspend fun deleteWorkoutByKey(deviceId: String, startTs: Long, sport: String)

    // MARK: - Dismissed detected bouts (durable #107 marker; survives engine re-detection)

    /** Record a dismissed detected bout. IGNORE so re-dismissing the same bout is a no-op. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertDismissed(rows: List<DismissedWorkout>)

    /** All dismissed markers for a [deviceId] (the computed "<id>-noop" source the detector writes). */
    @Query("SELECT * FROM dismissedWorkout WHERE deviceId = :deviceId")
    suspend fun dismissedWorkouts(deviceId: String): List<DismissedWorkout>

    /** Every durable workout-dismissal marker, for source-complete safety/activity context reads. */
    @Query("SELECT * FROM dismissedWorkout")
    suspend fun dismissedWorkoutsAllSources(): List<DismissedWorkout>

    /** Record a deleted sleep night (#33). IGNORE so re-deleting the same night is a no-op. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertDismissedSleep(rows: List<DismissedSleep>)

    /** All deleted-sleep markers for a [deviceId]. The engine reads the UNION of the imported id and its
     *  computed "<id>-noop" id (see WhoopRepository.dismissedSleeps, #65 3A), since a tombstone is written
     *  under whichever namespace owned the deleted row. */
    @Query("SELECT * FROM dismissedSleep WHERE deviceId = :deviceId")
    suspend fun dismissedSleeps(deviceId: String): List<DismissedSleep>

    /** Hide one tombstone from the Sleep screen's recompute list while leaving the row in place so the
     *  detector continues to suppress the sleep the user deliberately deleted (#515). */
    @Query(
        "UPDATE dismissedSleep SET managementVisible = 0 " +
            "WHERE deviceId = :deviceId AND startTs = :startTs",
    )
    suspend fun hideDismissedSleepFromManagement(deviceId: String, startTs: Long): Int

    /** Lift ONE deleted-sleep tombstone (#65 undo / "allow re-detection"): removes the marker so the
     *  night is re-detected from raw on the next analyze pass. Keyed by (deviceId, startTs): the same
     *  natural key the insert uses, so it removes exactly the tombstone [deleteSleepSession] wrote. */
    @Query("DELETE FROM dismissedSleep WHERE deviceId = :deviceId AND startTs = :startTs")
    suspend fun deleteDismissedSleep(deviceId: String, startTs: Long)

    // MARK: - Frontier / stats (Reads.swift)

    /** Max HR sample ts for a device, or null if none — the biometric data frontier.
     *  COALESCEs measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156) so a PPG-only
     *  offload (a v26 WHOOP 5 night with no measured HR) still advances the frontier, matching the
     *  Swift reader (Reads.swift latestHrSampleTs). Both persist on the same per-second ts grid. */
    @Query(
        "SELECT MAX(ts) FROM (" +
            "SELECT ts FROM hrSample WHERE deviceId = :deviceId " +
            "UNION ALL " +
            "SELECT ts FROM ppgHrSample WHERE deviceId = :deviceId)",
    )
    suspend fun latestHrSampleTs(deviceId: String): Long?

    @Query("SELECT COUNT(*) FROM hrSample") suspend fun countHr(): Int
    /** #836/#1196: whole-history token across every raw stream consumed by daily scoring. History can
     * deliver HR before R-R or motion; every later score-bearing chunk must invalidate the watermark. */
    @Query(
        "SELECT " +
            "(SELECT COUNT(*) FROM hrSample) + " +
            "(SELECT COUNT(*) FROM ppgHrSample) + " +
            "(SELECT COUNT(*) FROM rrInterval) + " +
            "(SELECT COUNT(*) FROM gravitySample) + " +
            "(SELECT COUNT(*) FROM respSample) + " +
            "(SELECT COUNT(*) FROM skinTempSample) + " +
            "(SELECT COUNT(*) FROM spo2Sample) + " +
            "(SELECT COUNT(*) FROM stepSample) + " +
            "(SELECT COUNT(*) FROM sleepStateSample) + " +
            "(SELECT COUNT(*) FROM event)",
    )
    suspend fun countAnalysisFingerprintRows(): Int

    @Query(
        "SELECT COALESCE(MAX(ts), 0) FROM (" +
            "SELECT ts FROM hrSample " +
            "UNION ALL " +
            "SELECT ts FROM ppgHrSample " +
            "UNION ALL " +
            "SELECT ts FROM rrInterval " +
            "UNION ALL " +
            "SELECT ts FROM gravitySample " +
            "UNION ALL " +
            "SELECT ts FROM respSample " +
            "UNION ALL " +
            "SELECT ts FROM skinTempSample " +
            "UNION ALL " +
            "SELECT ts FROM spo2Sample " +
            "UNION ALL " +
            "SELECT ts FROM stepSample " +
            "UNION ALL " +
            "SELECT ts FROM sleepStateSample " +
            "UNION ALL " +
            "SELECT ts FROM event)",
    )
    suspend fun maxAnalysisFingerprintTs(): Long

    // Raw measured-HR aggregate retained for diagnostics and database summaries.
    @Query("SELECT COALESCE(MAX(ts), 0) FROM hrSample") suspend fun maxHrTs(): Long
    @Query("SELECT COUNT(*) FROM rrInterval") suspend fun countRr(): Int
    @Query("SELECT COUNT(*) FROM event") suspend fun countEvents(): Int
    @Query("SELECT COUNT(*) FROM battery") suspend fun countBattery(): Int
    @Query("SELECT COUNT(*) FROM spo2Sample") suspend fun countSpo2(): Int
    @Query("SELECT COUNT(*) FROM skinTempSample") suspend fun countSkinTemp(): Int
    @Query("SELECT COUNT(*) FROM stepSample") suspend fun countSteps(): Int
    @Query("SELECT COUNT(*) FROM respSample") suspend fun countResp(): Int
    @Query("SELECT COUNT(*) FROM gravitySample") suspend fun countGravity(): Int

    // MARK: - Live convenience reads

    /** Latest HR sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM hrSample WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestHr(deviceId: String): HrSample?

    /** Latest battery sample for a device (most recent ts), or null. */
    @Query("SELECT * FROM battery WHERE deviceId = :deviceId ORDER BY ts DESC LIMIT 1")
    suspend fun latestBattery(deviceId: String): BatterySample?

    // MARK: - Durable Coach history and user-managed memory

    @Upsert
    suspend fun upsertCoachMessage(row: CoachMessageRow)

    @Query(
        "DELETE FROM coachMessage WHERE id NOT IN (" +
            "SELECT id FROM coachMessage ORDER BY createdAt DESC, id DESC LIMIT :limit)"
    )
    suspend fun pruneCoachMessages(limit: Int)

    @Query(
        "SELECT * FROM (SELECT * FROM coachMessage ORDER BY createdAt DESC, id DESC LIMIT :limit) " +
            "ORDER BY createdAt ASC, id ASC"
    )
    suspend fun coachMessages(limit: Int): List<CoachMessageRow>

    @Query("DELETE FROM coachMessage")
    suspend fun clearCoachMessages(): Int

    @Transaction
    suspend fun appendCoachMessage(row: CoachMessageRow, limit: Int) {
        upsertCoachMessage(row)
        pruneCoachMessages(limit)
    }

    @Upsert
    suspend fun upsertCoachMemory(row: CoachMemoryRow)

    @Query(
        "SELECT * FROM coachMemory WHERE (:includeDisabled = 1 OR enabled = 1) " +
            "ORDER BY updatedAt DESC, id DESC"
    )
    suspend fun coachMemories(includeDisabled: Boolean): List<CoachMemoryRow>

    @Query("SELECT COUNT(*) FROM coachMemory")
    suspend fun coachMemoryCount(): Int

    @Query("SELECT COUNT(*) FROM coachMemory WHERE id = :id")
    suspend fun coachMemoryCount(id: String): Int

    @Query("DELETE FROM coachMemory WHERE id = :id")
    suspend fun deleteCoachMemory(id: String): Int

    // MARK: - #547 one-time heal: purge rows polluted by a bad-strap-clock timestamp
    //
    // pikapik's WHOOP 4.0 (#547) emitted records whose `unix` decoded to garbage (far-past / a 2027 spike
    // / a future date), which entered the DB verbatim before the ingest gate existed. These deletes purge
    // the already-stored pollution ONCE on upgrade across EVERY device id (the bad rows can sit under
    // "my-whoop" raw streams AND the "-noop" computed daily/sleep rows), so a normal analyzeRecent rescore
    // recomputes the real days cleanly. Bounds are passed in from [MIN_PLAUSIBLE_UNIX]/[FUTURE_MARGIN]; the
    // future-day string is the local "today" key so a future-DATED computed day is removed. Each returns
    // the row count deleted (for the heal log). Re-running is harmless (idempotent — nothing left to match).

    /** Raw stream rows whose unix-second `ts` is implausible (before [minTs] or after [maxTs]). One per
     *  raw table (all keyed by `ts`); summed by the repository. */
    @Query("DELETE FROM hrSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneHrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM ppgHrSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun prunePpgHrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM rrInterval WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneRrByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM skinTempSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneSkinTempByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM stepSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneStepByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM respSample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneRespByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM gravitySample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneGravityByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM spo2Sample WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneSpo2ByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM event WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneEventByTs(minTs: Long, maxTs: Long): Int

    @Query("DELETE FROM battery WHERE ts < :minTs OR ts > :maxTs")
    suspend fun pruneBatteryByTs(minTs: Long, maxTs: Long): Int

    /** Daily-metric rows whose `day` key is FUTURE (lexicographically after [today], valid for "yyyy-MM-dd",
     *  any source) or implausibly old (before [minDay]) AND computed (`-noop`). The far-past floor is
     *  `-noop`-scoped so a WHOOP CSV import (bare "my-whoop") carrying REAL multi-year history is never
     *  purged (v8.2.1). String compare is correct for ISO dates. */
    @Query("DELETE FROM dailyMetric WHERE day > :today OR (day < :minDay AND deviceId LIKE '%-noop')")
    suspend fun pruneDailyMetricByDay(today: String, minDay: String): Int

    /** Sleep-session rows whose onset `startTs` is future (after [maxTs], any source) or implausibly old
     *  (before [minTs]) AND computed (`-noop`), so an imported multi-year sleep history survives (v8.2.1). */
    @Query("DELETE FROM sleepSession WHERE startTs > :maxTs OR (startTs < :minTs AND deviceId LIKE '%-noop')")
    suspend fun pruneSleepSessionByTs(minTs: Long, maxTs: Long): Int
}
