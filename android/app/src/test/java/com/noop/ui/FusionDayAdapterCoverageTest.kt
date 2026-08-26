package com.noop.ui

import com.noop.analytics.FusionSource
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.time.ZoneId

/**
 * #799 / SPINE regression: the fused record only lets a source win the day it ACTUALLY covers, and the
 * strap reads follow the registry's ACTIVE strap id (not a hardcoded "my-whoop"). The reported symptom was
 * "fused 8h57m every day": one imported sleep row appeared to win every day. [FusionDayAdapter.buildFor]
 * must read each source's OWN row keyed to the exact requested day, so an import for day A never supplies a
 * value for day B; and an active band stored under its own id must fuse ITS data, not the WHOOP id's.
 *
 * Mirrors the iOS regression test logic. Driven through a Proxy-stub [WhoopDao] (no Room): only daily
 * rows and exact-source sleep-session evidence are available from the fixture.
 */
class FusionDayAdapterCoverageTest {

    /** Build a repository exposing only the adapter's daily rows and exact sleep-session evidence. */
    private fun repo(
        rowsByDevice: Map<String, List<DailyMetric>>,
        sessionsByDevice: Map<String, List<SleepSession>> = emptyMap(),
    ): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                // A trailing Continuation (suspend ABI) is ignored. Returning the list synchronously is
                // the supported way to stub a suspend function through a Java Proxy.
                "days" -> rowsByDevice[args?.get(0) as String].orEmpty()
                "sleepSessions" -> {
                    val callArgs = requireNotNull(args)
                    val deviceId = callArgs[0] as String
                    val from = callArgs[1] as Long
                    val to = callArgs[2] as Long
                    sessionsByDevice[deviceId].orEmpty()
                        .filter { it.startTs in from..to }
                }
                // Anything else proves the adapter reached past its contract.
                else -> throw UnsupportedOperationException("FusionDayAdapter must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun sleepRow(deviceId: String, day: String, asleepMin: Double) =
        DailyMetric(deviceId = deviceId, day = day, totalSleepMin = asleepMin)

    private fun stagedSleepRow(deviceId: String, day: String) = DailyMetric(
        deviceId = deviceId,
        day = day,
        totalSleepMin = 420.0,
        deepMin = 80.0,
        remMin = 100.0,
        lightMin = 240.0,
    )

    private fun stagedSession(deviceId: String, day: String, supported: Boolean = true): SleepSession {
        val end = LocalDate.parse(day).atTime(8, 0).atZone(ZoneId.systemDefault()).toEpochSecond()
        return SleepSession(
            deviceId = deviceId,
            startTs = end - 8 * 3_600L,
            endTs = end,
            stagesJSON = """{"awake":30,"light":210,"deep":80,"rem":100}""",
            rrEligibleWindowCount = if (supported) 96 else null,
            rrValidWindowCount = if (supported) 24 else null,
        )
    }

    private val dayA = "2026-06-10"
    private val dayB = "2026-06-11"

    @Test
    fun importedSleepRowDoesNotWinADayItDoesNotCover() = runBlocking {
        // The import covers ONLY dayA with 8h57m (537 min). Building the record for dayB must NOT carry
        // that value forward (the "fused 8h57m every day" bug).
        val repo = repo(
            mapOf("my-whoop" to listOf(sleepRow("my-whoop", dayA, 537.0))),
        )

        val recA = FusionDayAdapter.buildFor(repo, dayA)
        val recB = FusionDayAdapter.buildFor(repo, dayB)

        // dayA has the imported asleep value; dayB has NO source for it.
        val sleepA = recA.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(537.0, sleepA?.point?.value)
        val sleepB = recB.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertNull("an import for dayA must not supply sleep for dayB", sleepB)
        // dayB has no contributing source at all -> empty record, never a carried-forward number.
        assertEquals(0, recB.contributingSourceCount)
        assertTrue(recB.rows.isEmpty())
    }

    @Test
    fun strapReadsFollowTheActiveStrapIdNotHardcodedMyWhoop() = runBlocking {
        // The active band stores its day under its OWN id. A hardcoded "my-whoop" read would miss it; the
        // active-id read fuses it. (SPINE / #814.)
        val activeId = "polar-h10"
        val repo = repo(
            mapOf(activeId to listOf(sleepRow(activeId, dayA, 480.0))),
        )

        // Default (hardcoded my-whoop) sees nothing for this band.
        val hardcoded = FusionDayAdapter.buildFor(repo, dayA)
        assertEquals(0, hardcoded.contributingSourceCount)

        // Active-id read fuses the band's own row, and attributes it to the WHOOP_IMPORT strap slot.
        val active = FusionDayAdapter.buildFor(repo, dayA, activeStrapId = activeId)
        val sleep = active.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(480.0, sleep?.point?.value)
        assertEquals(FusionSource.WHOOP_IMPORT, sleep?.point?.winningSource)
    }

    @Test
    fun computedSiblingAlsoFollowsTheActiveStrapId() = runBlocking {
        // The on-device computed sibling is "<activeStrapId>-noop", not "my-whoop-noop".
        val activeId = "garmin-hrm"
        val repo = repo(
            mapOf("$activeId-noop" to listOf(sleepRow("$activeId-noop", dayA, 421.0))),
        )
        val rec = FusionDayAdapter.buildFor(repo, dayA, activeStrapId = activeId)
        val sleep = rec.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(421.0, sleep?.point?.value)
        assertEquals(FusionSource.NOOP_COMPUTED, sleep?.point?.winningSource)
    }

    @Test
    fun unsupportedComputedStagesAreWithheldWithoutHidingSleepTotal() = runBlocking {
        val source = "my-whoop-noop"
        val rec = FusionDayAdapter.buildFor(
            repo(mapOf(source to listOf(stagedSleepRow(source, dayA)))),
            dayA,
        )

        assertEquals(420.0, rec.rows.first { it.point.metric == "sleep_total_min" }.point.value, 0.0)
        assertNull(rec.rows.firstOrNull { it.point.metric == "sleep_deep_min" })
        assertNull(rec.rows.firstOrNull { it.point.metric == "sleep_rem_min" })
    }

    @Test
    fun exactComputedSourceEvidencePublishesStages() = runBlocking {
        val source = "my-whoop-noop"
        val rec = FusionDayAdapter.buildFor(
            repo(
                rowsByDevice = mapOf(source to listOf(stagedSleepRow(source, dayA))),
                sessionsByDevice = mapOf(source to listOf(stagedSession(source, dayA))),
            ),
            dayA,
        )

        assertEquals(80.0, rec.rows.first { it.point.metric == "sleep_deep_min" }.point.value, 0.0)
        assertEquals(100.0, rec.rows.first { it.point.metric == "sleep_rem_min" }.point.value, 0.0)
    }

    @Test
    fun anotherComputedSourceEvidenceCannotAuthorizeTheActiveSource() = runBlocking {
        val activeId = "polar-h10"
        val activeComputed = "$activeId-noop"
        val canonicalComputed = "my-whoop-noop"
        val rec = FusionDayAdapter.buildFor(
            repo(
                rowsByDevice = mapOf(
                    activeComputed to listOf(stagedSleepRow(activeComputed, dayA)),
                ),
                sessionsByDevice = mapOf(
                    canonicalComputed to listOf(stagedSession(canonicalComputed, dayA)),
                ),
            ),
            dayA,
            activeStrapId = activeId,
        )

        assertNull(rec.rows.firstOrNull { it.point.metric == "sleep_deep_min" })
        assertNull(rec.rows.firstOrNull { it.point.metric == "sleep_rem_min" })
    }

    @Test
    fun independentlyStagedImportRemainsPublishable() = runBlocking {
        val source = "my-whoop"
        val rec = FusionDayAdapter.buildFor(
            repo(mapOf(source to listOf(stagedSleepRow(source, dayA)))),
            dayA,
        )

        assertEquals(80.0, rec.rows.first { it.point.metric == "sleep_deep_min" }.point.value, 0.0)
        assertEquals(FusionSource.WHOOP_IMPORT,
            rec.rows.first { it.point.metric == "sleep_deep_min" }.point.winningSource)
    }
}
