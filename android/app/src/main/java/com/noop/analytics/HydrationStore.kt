package com.noop.analytics

import com.noop.AppDiagnosticsRecorder
import com.noop.data.HydrationEntryContract
import com.noop.data.HydrationEntryIntegrityException
import com.noop.data.HydrationEntryMutationResult
import com.noop.data.HydrationEntryRow
import com.noop.data.WhoopRepository
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import java.util.TimeZone
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * HydrationStore — the logging + read seam for the opt-in Hydration tracker.
 *
 * Kotlin twin of the Swift hydration store calls. Each user-authored drink is durable and editable;
 * Room keeps those rows and the generic metric-series daily projection in one transaction. Confirmed
 * Health Connect records remain in their own source partition and are merged conservatively at read
 * time, so a drink mirrored by two apps is not counted twice.
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

    data class Entry(
        val id: String,
        val day: String,
        val amountML: Int,
        val loggedAt: Long,
    )

    data class ProvenanceStrings(
        val noopOnlyLabel: String,
        val externalOnlyLabel: String,
        val bothLabel: String,
        val bothExplanation: String,
    )

    data class SourceTotal(
        val source: ReadingSource,
        val valueMl: Double,
    )

    data class ProvenancePresentation(
        val sourceLabel: String,
        val explanation: String?,
        val sourceTotals: List<SourceTotal>,
    )

    /** Pure detail presentation that keeps potentially overlapping source totals separate. */
    internal fun Reading.provenance(strings: ProvenanceStrings): ProvenancePresentation =
        when (source) {
            ReadingSource.NOOP -> ProvenancePresentation(
                sourceLabel = strings.noopOnlyLabel,
                explanation = null,
                sourceTotals = emptyList(),
            )
            ReadingSource.HEALTH_CONNECT -> ProvenancePresentation(
                sourceLabel = strings.externalOnlyLabel,
                explanation = null,
                sourceTotals = emptyList(),
            )
            ReadingSource.BOTH -> ProvenancePresentation(
                sourceLabel = strings.bothLabel,
                explanation = strings.bothExplanation,
                sourceTotals = listOf(
                    SourceTotal(ReadingSource.NOOP, noopMl),
                    SourceTotal(ReadingSource.HEALTH_CONNECT, healthConnectMl),
                ),
            )
        }

    /**
     * #989 (Kotlin twin of Repository.hydrationSeq): bumped after every changed entry transaction.
     * Hydration writes never touch the flows Today already collects (`days` only changes on a data
     * refresh), so Today keys its hydration re-read on this sequence too.
     */
    val mutationSeq = kotlinx.coroutines.flow.MutableStateFlow(0)
    private val mutationMutex = Mutex()

    /** The generic metric-series key the day total is banked under (shared id; keep == the Swift key). */
    const val KEY: String = HydrationEntryContract.METRIC_KEY

    /** The source/device id the hydration total is written under — its own local-only source so it is
     *  never confused with strap-imported or computed metrics. Matches the Swift source id. */
    const val SOURCE_ID: String = HydrationEntryContract.SOURCE_ID

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

    /** Exact canonical local-day key accepted by day-scoped reads and mutations. */
    internal fun requireDayKey(day: String): String =
        HydrationEntryContract.requireCanonicalDay(day)

    /**
     * Timestamp one log inside its selected local day. Historical entries retain the current local
     * time-of-day; DST gaps/overlaps are resolved by java.time and a noon fallback keeps exotic zone
     * transitions from escaping the requested day.
     */
    internal fun loggedAtForDay(
        day: String,
        nowSec: Long = System.currentTimeMillis() / 1000L,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): Long {
        val selected = LocalDate.parse(requireDayKey(day))
        val now = Instant.ofEpochSecond(nowSec).atZone(zoneId)
        if (now.toLocalDate() == selected) return nowSec
        val candidate = selected.atTime(now.toLocalTime()).atZone(zoneId)
        if (candidate.toLocalDate() == selected) return candidate.toEpochSecond()
        return selected.atTime(12, 0).atZone(zoneId).toEpochSecond()
    }

    internal suspend fun entriesForDay(
        repo: WhoopRepository,
        day: String,
    ): List<Entry> =
        repo.hydrationEntries(SOURCE_ID, requireDayKey(day)).map { it.asEntry() }

    /**
     * Log [amountMl] of fluid for the local day containing [ts] (defaults to now). Each tap persists a
     * separately addressable entry and updates the [SOURCE_ID]/[KEY] daily projection atomically.
     * A non-positive amount is a no-op. Returns the new day total (ml). Idempotency is intentionally
     * absent because each confirmed quick-add represents another drink.
     */
    suspend fun log(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        return logForDay(repo, amountMl, dayKey(ts))
    }

    /** Add one confirmed amount to an exact displayed day. */
    internal suspend fun logForDay(
        repo: WhoopRepository,
        amountMl: Int,
        day: String,
        nowSec: Long = System.currentTimeMillis() / 1000L,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): Double? {
        val canonicalDay = requireDayKey(day)
        if (amountMl <= 0) return totalForDay(repo, canonicalDay)
        require(amountMl <= HydrationEntryContract.MAX_ENTRY_ML) {
            "invalid hydration amount"
        }
        return mutationMutex.withLock {
            recordedMutation("add") {
                repo.addHydrationEntry(
                    HydrationEntryRow(
                        id = UUID.randomUUID().toString(),
                        deviceId = SOURCE_ID,
                        day = canonicalDay,
                        amountML = amountMl,
                        loggedAt = loggedAtForDay(canonicalDay, nowSec, zoneId),
                    ),
                )
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
     * Compatibility correction seam. A positive total becomes one explicit editable entry; zero clears
     * the local entries. Fractional or over-limit values fail rather than creating false precision.
     */
    suspend fun set(repo: WhoopRepository, totalMl: Double, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        return setForDay(repo, totalMl, dayKey(ts))
    }

    /** Replace NOOP's exact displayed-day total, preserving imported Health Connect intake separately. */
    internal suspend fun setForDay(
        repo: WhoopRepository,
        totalMl: Double,
        day: String,
    ): Double? {
        val canonicalDay = requireDayKey(day)
        val next = clampedTotal(totalMl)
        require(next.isFinite() && next % 1.0 == 0.0) { "invalid hydration total" }
        require(next <= HydrationEntryContract.MAX_DAY_ML) { "invalid hydration total" }
        return mutationMutex.withLock {
            recordedMutation("set") {
                val rows = if (next > 0.0) {
                    listOf(
                        HydrationEntryRow(
                            id = UUID.randomUUID().toString(),
                            deviceId = SOURCE_ID,
                            day = canonicalDay,
                            amountML = next.toInt(),
                            loggedAt = loggedAtForDay(canonicalDay),
                        ),
                    )
                } else {
                    emptyList()
                }
                repo.replaceHydrationEntries(SOURCE_ID, canonicalDay, rows)
            }
        }
    }

    /**
     * Compatibility subtract path. New UI deletes or edits an exact entry ID; this method consumes the
     * newest persisted rows first while preserving every unaffected entry.
     */
    suspend fun remove(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double? {
        return removeForDay(repo, amountMl, dayKey(ts))
    }

    /** Remove one amount from NOOP's exact displayed-day total. */
    internal suspend fun removeForDay(
        repo: WhoopRepository,
        amountMl: Int,
        day: String,
    ): Double? {
        val canonicalDay = requireDayKey(day)
        if (amountMl <= 0) return totalForDay(repo, canonicalDay)
        return mutationMutex.withLock {
            recordedMutation("remove") {
                val current = repo.hydrationEntries(SOURCE_ID, canonicalDay)
                var remaining = amountMl
                val retained = current.toMutableList()
                var index = retained.lastIndex
                while (remaining > 0 && index >= 0) {
                    val entry = retained[index]
                    if (remaining >= entry.amountML) {
                        remaining -= entry.amountML
                        retained.removeAt(index)
                    } else {
                        retained[index] = entry.copy(amountML = entry.amountML - remaining)
                        remaining = 0
                    }
                    index -= 1
                }
                repo.replaceHydrationEntries(SOURCE_ID, canonicalDay, retained)
            }
        }
    }

    internal suspend fun updateEntryForDay(
        repo: WhoopRepository,
        id: String,
        amountMl: Int,
        day: String,
    ): Double? {
        val canonicalDay = requireDayKey(day)
        require(amountMl in 1..HydrationEntryContract.MAX_ENTRY_ML) {
            "invalid hydration amount"
        }
        return mutationMutex.withLock {
            recordedMutation("edit") {
                val existing = repo.hydrationEntries(SOURCE_ID, canonicalDay)
                    .firstOrNull { it.id == id }
                    ?: return@recordedMutation HydrationEntryMutationResult(
                        changed = false,
                        totalML = totalForDay(repo, canonicalDay),
                    )
                repo.updateHydrationEntry(existing.copy(amountML = amountMl))
            }
        }
    }

    internal suspend fun deleteEntryForDay(
        repo: WhoopRepository,
        id: String,
        day: String,
    ): Double? {
        val canonicalDay = requireDayKey(day)
        return mutationMutex.withLock {
            recordedMutation("delete") {
                repo.deleteHydrationEntry(id, SOURCE_ID, canonicalDay)
            }
        }
    }

    internal suspend fun clearEntriesForDay(
        repo: WhoopRepository,
        day: String,
    ): Double? {
        val canonicalDay = requireDayKey(day)
        return mutationMutex.withLock {
            recordedMutation("clear") {
                repo.clearHydrationEntries(SOURCE_ID, canonicalDay)
            }
        }
    }

    internal fun persistenceOutcome(changed: Boolean): String =
        if (changed) "saved" else "unchanged"

    private suspend fun recordedMutation(
        operation: String,
        block: suspend () -> HydrationEntryMutationResult,
    ): Double? {
        return try {
            val result = block()
            if (result.changed) mutationSeq.value += 1
            AppDiagnosticsRecorder.record(
                "hydration.persistence",
                mapOf(
                    "operation" to operation,
                    "outcome" to persistenceOutcome(result.changed),
                ),
            )
            result.totalML
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
            is HydrationEntryIntegrityException -> "integrity"
            is android.database.sqlite.SQLiteException -> "database"
            is java.io.IOException -> "io"
            else -> "unexpected"
        }

    private fun HydrationEntryRow.asEntry(): Entry =
        Entry(id = id, day = day, amountML = amountML, loggedAt = loggedAt)

    /** Source-aware confirmed intake for the local day containing [ts], or null when neither source
     * has a record. NOOP and Health Connect remain visible separately for honest UI/corrections. */
    suspend fun reading(
        repo: WhoopRepository,
        ts: Long = System.currentTimeMillis() / 1000L,
    ): Reading? = readingForDay(repo, dayKey(ts))

    /** Confirmed source-aware intake for one exact local/display day key. */
    internal suspend fun readingForDay(
        repo: WhoopRepository,
        day: String,
    ): Reading? {
        val canonicalDay = requireDayKey(day)
        val noopRow = repo.metricSeries(SOURCE_ID, KEY, canonicalDay, canonicalDay).firstOrNull()
        val healthRow = repo.metricSeries(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            KEY,
            canonicalDay,
            canonicalDay,
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

    /** Best confirmed intake for one exact local/display day, or null when that day is unrecorded. */
    internal suspend fun totalForDay(repo: WhoopRepository, day: String): Double? =
        readingForDay(repo, day)?.valueMl

    /**
     * The last [days] local-day totals up to and including today, OLDEST first, as (dayKey, ml) pairs —
     * one entry per calendar day with null for days that have no confirmed log. Backs the detail screen's 7-day
     * mini bar history. [days] is clamped ≥ 1.
     */
    suspend fun history(
        repo: WhoopRepository,
        days: Int = 7,
        nowSec: Long = System.currentTimeMillis() / 1000L,
    ): List<Pair<String, Double?>> =
        historyThroughDay(repo, days, dayKey(nowSec))

    /** Trailing local-day totals ending on one exact displayed day, oldest first. */
    internal suspend fun historyThroughDay(
        repo: WhoopRepository,
        days: Int = 7,
        throughDay: String,
    ): List<Pair<String, Double?>> {
        val n = days.coerceAtLeast(1)
        val end = LocalDate.parse(requireDayKey(throughDay))
        val fromKey = end.minusDays((n - 1).toLong()).toString()
        val toKey = end.toString()
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
            val key = end.minusDays((n - 1 - i).toLong()).toString()
            key to observedTotal(noopByDay[key], healthByDay[key])
        }
    }
}
