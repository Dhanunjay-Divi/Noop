package com.noop.analytics

import com.noop.AppDiagnosticsRecorder
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import java.util.TimeZone
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * HydrationStore — the logging + read seam for the opt-in Hydration tracker.
 *
 * Kotlin twin of the Swift hydration store calls. The day total is banked in the generic metric-series
 * store under the [KEY] series, keyed by the device's LOCAL calendar day — the SAME `metricSeries`
 * table + `WhoopRepository.upsertMetricSeries` path every other generic daily series uses (no schema
 * change). Because that table holds one row per (deviceId, day, key), a tap reads the day's running
 * total and re-upserts total + amount, so the stored value IS "the sum of today's hydration logged for
 * this local day". Confirmed Health Connect records remain in their own source partition and are
 * merged conservatively at read time, so a drink mirrored by two apps is not counted twice.
 *
 * `ts` (a wall-clock unix second) selects which local day a log lands on; the goal itself comes from the
 * pure [HydrationGoal] engine, never from here.
 */
object HydrationStore {

    enum class ReadingSource { NOOP, HEALTH_CONNECT, BOTH }

    data class Reading(
        val valueMl: Double,
        val source: ReadingSource,
        val noopMl: Double,
        val healthConnectMl: Double,
    )

    /**
     * #989 (Kotlin twin of Repository.hydrationSeq): bumped on every mutation ([log] / [set]; [remove]
     * routes through [set]). Hydration writes never touch the flows Today already collects (`days` only
     * changes on a data refresh), so the dashboard card sat stale until an unrelated sync. Today keys its
     * hydration re-read on this too.
     */
    val mutationSeq = kotlinx.coroutines.flow.MutableStateFlow(0)
    private val mutationMutex = Mutex()

    /** The generic metric-series key the day total is banked under (shared id; keep == the Swift key). */
    const val KEY: String = "hydration"

    /** The source/device id the hydration total is written under — its own local-only source so it is
     *  never confused with strap-imported or computed metrics. Matches the Swift source id. */
    const val SOURCE_ID: String = "hydration"

    internal fun confirmedTotal(value: Double?): Double? =
        value?.takeIf { it.isFinite() && it > 0.0 }

    /** Conservative source merge: duplicate manual/relay records are possible, so never add totals. */
    internal fun observedTotal(noopMl: Double?, healthConnectMl: Double?): Double? =
        listOfNotNull(confirmedTotal(noopMl), confirmedTotal(healthConnectMl)).maxOrNull()

    internal fun cardValue(totalMl: Double?, goalMl: Int, missingText: String): String =
        confirmedTotal(totalMl)?.let {
            String.format(java.util.Locale.US, "%.1f / %.1f L", it / 1000.0, goalMl / 1000.0)
        } ?: missingText

    /** Seconds EAST of UTC for the device's current zone — the offset [AnalyticsEngine.dayString] needs
     *  to bucket a timestamp on the LOCAL calendar day (matches the dashboard's local "today" read). */
    private fun localOffsetSec(atMillis: Long = System.currentTimeMillis()): Long =
        (TimeZone.getDefault().getOffset(atMillis) / 1000).toLong()

    /** The LOCAL yyyy-MM-dd day key for a unix-seconds [ts] (defaults to now). */
    fun dayKey(ts: Long = System.currentTimeMillis() / 1000L): String =
        AnalyticsEngine.dayString(ts, localOffsetSec(ts * 1000L))

    /**
     * Log [amountMl] of fluid for the local day containing [ts] (defaults to now). Reads the day's
     * current total and upserts total + amount under [SOURCE_ID]/[KEY], so repeated taps accumulate.
     * A non-positive amount is a no-op. Returns the new day total (ml). Idempotency is by design absent —
     * each tap is an additive log, matching the WHOOP-style quick-add buttons.
     */
    suspend fun log(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        if (amountMl <= 0) return total(repo, ts)
        val day = dayKey(ts)
        return mutationMutex.withLock {
            recordedMutation("add") {
                val next = repo.runMetricMutationTransaction {
                    val current = noopTotal(repo, day)
                    val total = current + amountMl
                    repo.upsertMetricSeries(listOf(MetricSeriesRow(SOURCE_ID, day, KEY, total)))
                    total
                }
                mutationSeq.value += 1
                next
            }
        }
    }

    /**
     * Pure clamp behind [set]: a day total can never be negative. Factored out so the correction math
     * (#798) is unit-testable without a Room/repo stand-in. Returns [totalMl] floored at 0.0.
     */
    fun clampedTotal(totalMl: Double): Double = totalMl.coerceAtLeast(0.0)

    /**
     * Pure result of removing [amountMl] from a [currentTotalMl] (#798): a non-positive amount is a no-op
     * (the current total, still clamped at 0), otherwise the difference floored at 0 so an over-subtraction
     * lands on an empty day rather than a negative total. The testable core of [remove].
     */
    fun afterRemoving(currentTotalMl: Double, amountMl: Int): Double =
        if (amountMl <= 0) clampedTotal(currentTotalMl) else clampedTotal(currentTotalMl - amountMl)

    /**
     * Set the day total directly to [totalMl] for the local day containing [ts], clamped at 0 (a negative
     * target lands on 0, never a negative total). The correction seam behind the detail screen's
     * delete/undo affordances (#798): because the schema banks ONE additive total per (source, day, key)
     * row, an entry isn't separately addressable - removing or editing a log is expressed as adjusting the
     * day total. Returns the new stored total (ml). Mirrors the iOS `setHydration`.
     */
    suspend fun set(repo: WhoopRepository, totalMl: Double, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        val day = dayKey(ts)
        val next = clampedTotal(totalMl)
        return mutationMutex.withLock {
            recordedMutation("set") {
                repo.runMetricMutationTransaction {
                    repo.upsertMetricSeries(listOf(MetricSeriesRow(SOURCE_ID, day, KEY, next)))
                }
                mutationSeq.value += 1
                confirmedTotal(next)
            }
        }
    }

    /**
     * Remove [amountMl] from the local day's running total (the undo / delete-a-log path for the detail
     * screen, #798). Subtracts the amount and clamps at 0 so the total never goes negative; a non-positive
     * amount is a no-op. Returns the new day total (ml). Built on [set] + [afterRemoving] so the correction
     * math is shared + tested. Mirrors the iOS `removeHydration`.
     */
    suspend fun remove(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        if (amountMl <= 0) return total(repo, ts)
        val day = dayKey(ts)
        return mutationMutex.withLock {
            recordedMutation("remove") {
                val next = repo.runMetricMutationTransaction {
                    val adjusted = afterRemoving(noopTotal(repo, day), amountMl)
                    repo.upsertMetricSeries(
                        listOf(MetricSeriesRow(SOURCE_ID, day, KEY, adjusted)),
                    )
                    adjusted
                }
                mutationSeq.value += 1
                confirmedTotal(next)
            }
        }
    }

    private suspend fun <T> recordedMutation(
        operation: String,
        block: suspend () -> T,
    ): T {
        return try {
            block().also {
                AppDiagnosticsRecorder.record(
                    "hydration.persistence",
                    mapOf(
                        "operation" to operation,
                        "outcome" to "saved",
                    ),
                )
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            AppDiagnosticsRecorder.record(
                "hydration.persistence",
                mapOf(
                    "operation" to operation,
                    "outcome" to "failed",
                    "failure_kind" to persistenceFailureKind(error),
                ),
            )
            throw error
        }
    }

    private fun persistenceFailureKind(error: Throwable): String =
        when (error) {
            is android.database.sqlite.SQLiteException -> "database"
            is java.io.IOException -> "io"
            else -> "unexpected"
        }

    private suspend fun noopTotal(repo: WhoopRepository, day: String): Double =
        confirmedTotal(repo.metricSeries(SOURCE_ID, KEY, day, day).firstOrNull()?.value) ?: 0.0

    /** Source-aware confirmed intake for the local day containing [ts], or null when neither source
     * has a record. NOOP and Health Connect remain visible separately for honest UI/corrections. */
    suspend fun reading(
        repo: WhoopRepository,
        ts: Long = System.currentTimeMillis() / 1000L,
    ): Reading? {
        val day = dayKey(ts)
        val noopRow = repo.metricSeries(SOURCE_ID, KEY, day, day).firstOrNull()
        val healthRow = repo.metricSeries(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            KEY,
            day,
            day,
        ).firstOrNull()
        val noop = confirmedTotal(noopRow?.value)
        val health = confirmedTotal(healthRow?.value)
        val observed = observedTotal(noop, health) ?: return null
        val source = when {
            noop != null && health != null -> ReadingSource.BOTH
            noop != null -> ReadingSource.NOOP
            else -> ReadingSource.HEALTH_CONNECT
        }
        return Reading(
            valueMl = observed,
            source = source,
            noopMl = noop ?: 0.0,
            healthConnectMl = health ?: 0.0,
        )
    }

    /** The best confirmed fluid-intake total for the local day containing [ts], or null when unrecorded. */
    suspend fun total(repo: WhoopRepository, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        return reading(repo, ts)?.valueMl
    }

    /**
     * The last [days] local-day totals up to and including today, OLDEST first, as (dayKey, ml) pairs —
     * one entry per calendar day with null for days that have no confirmed log. Backs the detail screen's 7-day
     * mini bar history. [days] is clamped ≥ 1.
     */
    suspend fun history(
        repo: WhoopRepository,
        days: Int = 7,
        nowSec: Long = System.currentTimeMillis() / 1000L,
    ): List<Pair<String, Double?>> {
        val n = days.coerceAtLeast(1)
        val from = nowSec - (n - 1).toLong() * 86_400L
        val fromKey = dayKey(from)
        val toKey = dayKey(nowSec)
        // Keep sources separate and take the per-day max. Adding them would double a drink entered in
        // NOOP and mirrored into Health Connect by another app.
        val noopByDay = repo.metricSeries(SOURCE_ID, KEY, fromKey, toKey)
            .mapNotNull { row -> confirmedTotal(row.value)?.let { row.day to it } }
            .toMap()
        val healthByDay = repo.metricSeries(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            KEY,
            fromKey,
            toKey,
        ).mapNotNull { row -> confirmedTotal(row.value)?.let { row.day to it } }
            .toMap()
        return (0 until n).map { i ->
            val key = dayKey(nowSec - (n - 1 - i).toLong() * 86_400L)
            key to observedTotal(noopByDay[key], healthByDay[key])
        }
    }
}
