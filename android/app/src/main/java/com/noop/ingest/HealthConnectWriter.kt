package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Percentage
import com.noop.analytics.DetailedSleepStagePublication
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.NoopPrefs
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import kotlinx.coroutines.sync.Mutex
import kotlin.reflect.KClass

/** PII-safe category of a Health Connect writeback failure — a coarse reason, never a raw message. */
enum class WritebackFailure { PERMISSION_DENIED, REMOTE_ERROR }

/**
 * Outcome of a writeback attempt (#660): how many records landed, plus any per-concern failure
 * categories. Lets callers/UI distinguish "wrote 0 because nothing to share" from "wrote 0 because
 * the write FAILED" - the silent-zero the previous `Int` return couldn't express.
 */
data class WritebackResult(val written: Int, val failures: List<WritebackFailure>) {
    val ok: Boolean get() = failures.isEmpty()

    /** PII-safe status code persisted for the UI — a permission failure outranks a generic one, since it
     *  needs a distinct "re-grant" action. Pure/testable; must equal the `NoopPrefs.HC_WB_*` constants. */
    val statusCode: String get() = when {
        WritebackFailure.PERMISSION_DENIED in failures -> "PERMISSION_DENIED"
        failures.isNotEmpty() -> "REMOTE_ERROR"
        else -> "OK"
    }

    companion object {
        /** HC unavailable / nothing attempted — benign, not a failure. */
        val UNAVAILABLE = WritebackResult(0, emptyList())
    }
}

/** Map a thrown write error to a PII-safe category; rethrow coroutine cancellation (never a "failure"). */
private fun Throwable.writebackCategory(): WritebackFailure {
    if (this is kotlin.coroutines.cancellation.CancellationException) throw this
    return if (this is SecurityException) WritebackFailure.PERMISSION_DENIED else WritebackFailure.REMOTE_ERROR
}

/** One process-wide critical section for the complete Health Connect write/migration transaction. */
internal object HealthConnectWriteGate {
    private val mutex = Mutex()

    suspend fun <T> serialize(block: suspend () -> T): T {
        mutex.lock()
        try {
            return block()
        } finally {
            mutex.unlock()
        }
    }
}

/** Delete merged-away sleep records without swallowing provider failure or coroutine cancellation. */
internal suspend fun deleteAbsorbedSleepRecords(
    clientRecordIds: List<String>,
    batchSize: Int = 500,
    delete: suspend (List<String>) -> Unit,
) {
    val uniqueIds = clientRecordIds.distinct()
    require(batchSize > 0)
    uniqueIds.chunked(batchSize).forEach { delete(it) }
}

/**
 * Replacement ordering contract for Health Connect sleep records. Desired records land first; only a
 * fully successful insert permits stale IDs to be removed. This prevents a provider/binder failure from
 * turning a policy migration into an empty sleep history.
 */
internal suspend fun insertSleepRecordsThenDeleteOrphans(
    existingClientRecordIds: Collection<String>,
    desiredClientRecordIds: Collection<String>,
    absorbedClientRecordIds: Collection<String>,
    deleteBatchSize: Int = 500,
    insertDesired: suspend () -> Int,
    deleteByClientRecordId: suspend (List<String>) -> Unit,
): Int {
    val written = insertDesired()
    val desired = desiredClientRecordIds.toHashSet()
    val stale = LinkedHashSet<String>()
    stale.addAll(existingClientRecordIds)
    stale.addAll(absorbedClientRecordIds)
    stale.removeAll(desired)
    deleteAbsorbedSleepRecords(stale.toList(), deleteBatchSize, deleteByClientRecordId)
    return written
}

/**
 * OPT-IN writeback: pushes NOOP's on-device computed nightly metrics (resting HR, HRV RMSSD, sleep
 * SpO2, respiratory rate) INTO Health Connect, so other apps can see what the strap measured.
 * Inverse of [HealthConnectImporter]; default OFF (NoopPrefs.hcWriteback), toggled in Data Sources.
 *
 * Two deliberate scope limits:
 *  - **Computed days only** (`repo.days(computedDeviceId)`) — never imported ones. Echoing imported
 *    WHOOP-export or Health-Connect-sourced rows back into HC would duplicate another app's data
 *    (or loop our own import). What NOOP computed from the strap is genuinely ours to contribute.
 *  - **Idempotent by clientRecordId** (`noop-<metric>-<day>`): Health Connect does NOT auto-dedupe
 *    on re-insert the way HealthKit does — without a client id every 15-min recompute would stack
 *    duplicates. With it, HC upserts: same id + higher [Metadata.clientRecordVersion] replaces, so
 *    we stamp the version with the write time and the latest computation always wins.
 */
object HealthConnectWriter {

    /** How far back to write. Recomputation only ever touches recent nights; 60 days is generous. */
    private const val WINDOW_DAYS = 60L
    /** Bump when an existing sleep record must be replaced for a publication-policy change. */
    private const val SLEEP_PUBLICATION_SCHEMA_VERSION = 1L
    private const val SLEEP_READ_PAGE_SIZE = 500
    private const val SLEEP_DELETE_BATCH_SIZE = 500

    private val WRITE_RECORDS: List<KClass<out Record>> = listOf(
        RestingHeartRateRecord::class,
        HeartRateVariabilityRmssdRecord::class,
        OxygenSaturationRecord::class,
        RespiratoryRateRecord::class,
        HeartRateRecord::class,
        SleepSessionRecord::class,
    )

    /** The write-permission strings the UI must request before calling [write]. */
    val PERMISSIONS: Set<String> =
        WRITE_RECORDS.map { HealthPermission.getWritePermission(it) }.toSet()

    /**
     * Write the last [WINDOW_DAYS] of computed metrics. Returns a [WritebackResult] — the record
     * count PLUS any per-concern failure categories, so a revoked permission no longer looks like a
     * benign "wrote 0" (#660). Persists the outcome via [recordStatus] for the Data Sources UI.
     * Assumes [PERMISSIONS] are granted (HC throws SecurityException otherwise — caught + categorized).
     *
     * [deviceId] must be the registry's ACTIVE strap id (SPINE / #814): a wizard-paired strap banks
     * rows under `whoop-<address>`, so a hardcoded legacy "my-whoop" id reads empty tables and
     * exports nothing.
     */
    suspend fun write(context: Context, repo: WhoopRepository, deviceId: String): WritebackResult =
        HealthConnectWriteGate.serialize {
            writeSerialized(context, repo, deviceId)
        }

    /**
     * The complete operation lives under [HealthConnectWriteGate], including the one-time sleep policy
     * marker read/write. Concurrent callers can therefore never both observe an unset marker or race a
     * full-history delete against another insertion.
     */
    private suspend fun writeSerialized(
        context: Context,
        repo: WhoopRepository,
        deviceId: String,
    ): WritebackResult {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return WritebackResult.UNAVAILABLE

        // Guard the pre-insert work (client acquisition + the day read) the same way the concern inserts
        // below are guarded, so a provider race or DB error can't throw PAST recordStatus and leave the
        // UI showing a stale "OK" while sharing is actually broken (#660). Cancellation still propagates.
        val (client, days) = runCatching {
            val c = HealthConnectClient.getOrCreate(context)
            val cutoff = LocalDate.now().minusDays(WINDOW_DAYS).toString()
            c to repo.days(repo.computedDeviceId(deviceId)).filter { it.day >= cutoff }
        }.getOrElse { t ->
            val result = WritebackResult(0, listOf(t.writebackCategory()))
            recordStatus(context, result)
            return result
        }

        val zone = ZoneId.systemDefault()
        // Stamp every record in this batch with one version so a later recompute (higher stamp)
        // replaces the whole day consistently.
        val version = System.currentTimeMillis() / 1000

        val records = ArrayList<Record>()
        for (d in days) {
            // Noon local on the metric's day: an unambiguous, stable instant for a daily summary
            // (midnight would straddle the previous night across DST shifts).
            val date = runCatching { LocalDate.parse(d.day) }.getOrNull() ?: continue
            val time = date.atTime(LocalTime.NOON).atZone(zone)
            val instant: Instant = time.toInstant()
            val offset = time.offset

            d.restingHr?.let {
                records.add(RestingHeartRateRecord(
                    time = instant, zoneOffset = offset, beatsPerMinute = it.toLong(),
                    metadata = meta("rhr", d.day, version),
                ))
            }
            d.avgHrv?.let {
                records.add(HeartRateVariabilityRmssdRecord(
                    time = instant, zoneOffset = offset, heartRateVariabilityMillis = it,
                    metadata = meta("hrv", d.day, version),
                ))
            }
            d.spo2Pct?.let {
                records.add(OxygenSaturationRecord(
                    time = instant, zoneOffset = offset, percentage = Percentage(it),
                    metadata = meta("spo2", d.day, version),
                ))
            }
            d.respRateBpm?.let {
                records.add(RespiratoryRateRecord(
                    time = instant, zoneOffset = offset, rate = it,
                    metadata = meta("resp", d.day, version),
                ))
            }
        }

        // NOTE: steps + active-calories are deliberately NOT written back (was #528). NOOP's strap
        // step/kcal figures are estimates, and the phone pedometer / a watch already feed Health
        // Connect the authoritative values — writing ours too would double-count in the OS's daily
        // totals. iOS (#249) excludes them for the same reason; this keeps the two platforms aligned.
        // The unique strap signals (vitals, HR, sleep, workouts) are still written below.

        // Each export concern inserts independently so a failure in one — e.g. a revoked per-type WRITE
        // permission — can't suppress the others. Failures are CATEGORIZED (PII-safe, never raw messages)
        // and folded into the result instead of collapsing to a silent 0, so the UI can surface them (#660).
        var total = 0
        val failures = mutableListOf<WritebackFailure>()
        if (records.isNotEmpty()) {
            runCatching { client.insertRecords(records); records.size }
                .fold({ total += it }, { failures += it.writebackCategory() })
        }
        runCatching { writeHeartRate(client, context, repo, deviceId, version) }
            .fold({ total += it }, { failures += it.writebackCategory() })
        val migrateSleepStageHistory =
            !NoopPrefs.hcSleepStagePublicationMigrated(context, deviceId)
        runCatching {
            writeSleep(
                client = client,
                repo = repo,
                deviceId = deviceId,
                writeVersionSec = version,
                fullHistory = migrateSleepStageHistory,
                packageName = context.packageName,
            )
        }.fold(
            {
                total += it
                if (migrateSleepStageHistory) {
                    NoopPrefs.setHcSleepStagePublicationMigrated(context, deviceId)
                }
            },
            { failures += it.writebackCategory() },
        )
        val result = WritebackResult(total, failures.distinct())
        recordStatus(context, result)
        return result
    }

    /** Persist the last writeback outcome (PII-safe category + count + time) for the Data Sources UI (#660). */
    private fun recordStatus(context: Context, result: WritebackResult) {
        NoopPrefs.setHcWritebackStatus(context, result.statusCode, result.written, System.currentTimeMillis())
    }

    private fun meta(metric: String, day: String, version: Long) = Metadata(
        clientRecordId = "noop-$metric-$day",
        clientRecordVersion = version,
    )

    /** Health Connect caps records per insert call; insert in batches to stay well under it. */
    private suspend fun insertChunked(client: HealthConnectClient, records: List<Record>, batch: Int = 1000): Int {
        var n = 0
        records.chunked(batch).forEach { client.insertRecords(it); n += it.size }
        return n
    }

    /**
     * #528 — export NOOP's heart-rate samples (raw [deviceId], not computed) above the persisted
     * frontier. Inside workout/sleep windows the series is kept at full resolution; elsewhere it is
     * decimated to ~1 sample / 30 s so a continuous day doesn't flood Health Connect. The frontier
     * (a single epoch-second cursor in [NoopPrefs]) advances past every sample seen, so each 15-min
     * writeback only emits NEW samples and decimated-away points are never reconsidered.
     */
    private suspend fun writeHeartRate(client: HealthConnectClient, context: Context, repo: WhoopRepository, deviceId: String, version: Long): Int {
        val now = System.currentTimeMillis() / 1000
        val floor = now - WINDOW_DAYS * 86_400
        val frontier = maxOf(NoopPrefs.hcHrFrontier(context), floor)

        val samples = repo.hrSamples(deviceId, from = frontier + 1, to = now, limit = 200_000)
            .map { HealthExportPlan.HrPoint(it.ts, it.bpm) }
        if (samples.isEmpty()) return 0

        // Workout + sleep windows where the full-resolution series matters; everything else decimates.
        val windows = buildList {
            repo.workouts(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
            repo.sleepSessions(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
        }

        val plan = HealthExportPlan.heartRate(samples, windows, frontier)
        if (plan.chunks.isEmpty()) {
            if (plan.newFrontierSec > frontier) NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
            return 0
        }

        val zone = ZoneId.systemDefault()
        val records = plan.chunks.map { c ->
            val startTs = c.startSec
            val endTs = if (c.endSec > c.startSec) c.endSec else c.startSec + 1 // HC needs end > start
            val start = Instant.ofEpochSecond(startTs)
            val end = Instant.ofEpochSecond(endTs)
            HeartRateRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                samples = c.points.map {
                    HeartRateRecord.Sample(time = Instant.ofEpochSecond(it.tsSec), beatsPerMinute = it.bpm.toLong())
                },
                metadata = Metadata(clientRecordId = c.clientId, clientRecordVersion = version),
            )
        }
        val n = insertChunked(client, records)
        NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
        return n
    }

    /**
     * #528 — export finalized sleep sessions from the MERGED view (imported wins,
     * on-device-computed gap-fills) so a strap-only user's locally-computed nights (stored under the
     * "-noop" computed id) are included. Local detailed stages publish only for the exact source,
     * wake day, and canonical main-sleep group carrying sustained R-R evidence. Imported classifiers
     * remain stage-free here because Health Connect would attribute inserted records to NOOP.
     * #364 — fragments are grouped into BRIDGED NIGHTS (the same #561 bridge the daily totals score
     * with), so a night split by a brief mid-night wake exports as ONE record. Its gap is AWAKE only
     * when both adjacent fragments may publish detail. The clientRecordId keys off the group's
     * earliest fragment's immutable detected startTs, and the absorbed fragments' old per-fragment
     * records are DELETED (HC upserts by id but never removes an id we stop writing).
     */
    private suspend fun writeSleep(
        client: HealthConnectClient,
        repo: WhoopRepository,
        deviceId: String,
        writeVersionSec: Long,
        fullHistory: Boolean,
        packageName: String,
    ): Int {
        val now = System.currentTimeMillis() / 1000
        // Existing records outside the rolling window may contain stage detail written before the
        // R-R gate. Rewrite all history once, then return to the bounded recurring write.
        val floor = if (fullHistory) 0L else now - WINDOW_DAYS * 86_400
        // Resolve one complete Room snapshot before touching Health Connect. A local read failure leaves
        // both external records and the one-time migration marker unchanged.
        val snapshot = repo.sleepWritebackSnapshot(deviceId, from = floor, to = now)
        val sessions = snapshot.sessions
        val fallbackOffsetSec = WhoopRepository.historicalOffsetSeconds(now)
        val habitualMidsleepSec = snapshot.habitualMidsleepSec
        val publishableLocalSessions = WhoopRepository.projectPublishableDetailedStages(
            sessions = sessions,
            habitualMidsleepSec = habitualMidsleepSec,
        ).authorizedSessionKeys
        val inputs = sessions.map { session ->
            HealthExportPlan.SleepInput(
                keyStartTs = session.startTs,
                startTs = session.effectiveStartTs,
                endTs = session.endTs,
                stagesJSON = session.stagesJSON,
                // Health Connect attributes inserted records to NOOP. Imported classifiers remain
                // visible in-app, but their stage labels are not republished as NOOP-authored data.
                publishDetailedStages =
                    DetailedSleepStagePublication.key(session) in publishableLocalSessions,
                timezoneOffsetSec = WhoopRepository.historicalOffsetSeconds(session.endTs),
            )
        }
        val plans = HealthExportPlan.sleepSessions(inputs, now, fallbackOffsetSec)

        val zone = ZoneId.systemDefault()
        val records = plans.map { p ->
            val start = Instant.ofEpochSecond(p.startSec)
            val end = Instant.ofEpochSecond(p.endSec)
            SleepSessionRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                title = null, notes = null,
                stages = p.stages.map { s ->
                    SleepSessionRecord.Stage(
                        startTime = Instant.ofEpochSecond(s.startSec),
                        endTime = Instant.ofEpochSecond(s.endSec),
                        stage = when (s.kind) {
                            HealthExportPlan.StageKind.AWAKE -> SleepSessionRecord.STAGE_TYPE_AWAKE
                            HealthExportPlan.StageKind.SLEEPING -> SleepSessionRecord.STAGE_TYPE_SLEEPING
                            HealthExportPlan.StageKind.LIGHT -> SleepSessionRecord.STAGE_TYPE_LIGHT
                            HealthExportPlan.StageKind.DEEP -> SleepSessionRecord.STAGE_TYPE_DEEP
                            HealthExportPlan.StageKind.REM -> SleepSessionRecord.STAGE_TYPE_REM
                        },
                    )
                },
                // Health Connect replaces the same clientRecordId only when the version rises.
                // Multiplying the write timestamp keeps this above the legacy `endSec` version and
                // leaves room for an explicit publication-schema revision.
                metadata = Metadata(
                    clientRecordId = p.clientId,
                    clientRecordVersion =
                        writeVersionSec * 100 + SLEEP_PUBLICATION_SCHEMA_VERSION,
                ),
            )
        }
        val existingClientRecordIds = if (fullHistory) {
            readExistingNoopSleepClientRecordIds(client, packageName, now)
        } else {
            emptySet()
        }
        val absorbed = plans.flatMap { it.absorbedClientIds }
        return insertSleepRecordsThenDeleteOrphans(
            existingClientRecordIds = existingClientRecordIds,
            desiredClientRecordIds = plans.map { it.clientId },
            absorbedClientRecordIds = absorbed,
            deleteBatchSize = SLEEP_DELETE_BATCH_SIZE,
            insertDesired = {
                if (records.isEmpty()) 0 else insertChunked(client, records)
            },
            deleteByClientRecordId = { clientRecordIds ->
                client.deleteRecords(
                    SleepSessionRecord::class,
                    recordIdsList = emptyList(),
                    clientRecordIdsList = clientRecordIds,
                )
            },
        )
    }

    /** Page only this package's records and retain the stable IDs owned by NOOP's sleep exporter. */
    private suspend fun readExistingNoopSleepClientRecordIds(
        client: HealthConnectClient,
        packageName: String,
        nowSec: Long,
    ): Set<String> {
        val ids = linkedSetOf<String>()
        var pageToken: String? = null
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    recordType = SleepSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(
                        Instant.EPOCH,
                        Instant.ofEpochSecond(nowSec + 1),
                    ),
                    dataOriginFilter = setOf(DataOrigin(packageName)),
                    ascendingOrder = true,
                    pageSize = SLEEP_READ_PAGE_SIZE,
                    pageToken = pageToken,
                ),
            )
            for (record in response.records) {
                if (record.metadata.dataOrigin.packageName != packageName) continue
                val clientId = record.metadata.clientRecordId ?: continue
                if (clientId.startsWith("noop-sleep-")) ids += clientId
            }
            pageToken = response.pageToken
        } while (pageToken != null)
        return ids
    }

    // --- Workout (ExerciseSession) writeback (GPS workouts, v1.71) ---

    /** Write-permission strings for exercise sessions + distance; union into the writeback request. */
    val EXERCISE_PERMISSIONS: Set<String> = setOf(
        HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        HealthPermission.getWritePermission(DistanceRecord::class),
    )

    /** Pure: build the records for one workout (testable without a client). */
    fun buildExerciseRecords(row: WorkoutRow, exerciseType: Int): List<Record> {
        val start = Instant.ofEpochSecond(row.startTs)
        val end = Instant.ofEpochSecond(row.endTs)
        val offset = ZoneId.systemDefault().rules.getOffset(start)
        val out = ArrayList<Record>()
        out.add(
            ExerciseSessionRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                exerciseType = exerciseType, title = row.sport,
                metadata = Metadata(clientRecordId = "noop-workout-${row.startTs}", clientRecordVersion = row.endTs),
            ),
        )
        row.distanceM?.let {
            out.add(
                DistanceRecord(
                    startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                    distance = Length.meters(it),
                    metadata = Metadata(clientRecordId = "noop-workout-dist-${row.startTs}", clientRecordVersion = row.endTs),
                ),
            )
        }
        return out
    }

    /** Insert one workout's records into Health Connect. Opt-in caller. Returns a [WritebackResult] so a
     *  failed exercise share is visible instead of silently swallowed, and records the outcome (#660). */
    suspend fun writeExercise(context: Context, row: WorkoutRow, exerciseType: Int): WritebackResult {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return WritebackResult.UNAVAILABLE
        val recs = buildExerciseRecords(row, exerciseType)
        val result = runCatching { HealthConnectClient.getOrCreate(context).insertRecords(recs); recs.size }
            .fold({ WritebackResult(it, emptyList()) }, { WritebackResult(0, listOf(it.writebackCategory())) })
        recordStatus(context, result)
        return result
    }
}
