package com.noop.data

import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.runBlocking

class DetailedSleepStageRepositoryTest {
    @Test
    fun fullHistoryUpperBoundDoesNotWrapLexically() {
        assertEquals("9999-12-31", WhoopRepository.bufferDayAfter("9999-12-31"))
        assertEquals("9999-99-99", WhoopRepository.bufferDayAfter("9999-99-99"))
        assertEquals("2026-08-21", WhoopRepository.bufferDayAfter("2026-08-20"))
    }

    @Test
    fun exactSessionFilterFailsClosed() {
        val zone = ZoneId.systemDefault()
        fun session(day: String, valid: Int?): SleepSession {
            val end = LocalDate.parse(day).atTime(8, 0).atZone(zone).toEpochSecond()
            return SleepSession(
                deviceId = "my-whoop-noop",
                startTs = end - 8 * 3_600L,
                endTs = end,
                stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
                rrEligibleWindowCount = valid?.let { 96 },
                rrValidWindowCount = valid,
            )
        }
        val days = WhoopRepository.publishableDetailedStageDays(
            listOf(
                session("2026-08-20", valid = 24),
                session("2026-08-21", valid = 0),
                session("2026-08-22", valid = null),
            ),
        )

        assertEquals(setOf("2026-08-20"), days)
    }

    @Test
    fun projectionDerivesEveryPublishedAliasFromSelectedSessionJsonAndExcludesNap() {
        val nightStart = Instant.parse("2026-08-20T00:00:00Z").epochSecond
        val night = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = nightStart,
            endTs = nightStart + 8 * 3_600L,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
            rrEligibleWindowCount = 96,
            rrValidWindowCount = 24,
        )
        val nap = SleepSession(
            deviceId = night.deviceId,
            startTs = nightStart + 14 * 3_600L,
            endTs = nightStart + 15 * 3_600L,
            stagesJSON = """{"awake":0,"light":0,"deep":60,"rem":0}""",
            rrEligibleWindowCount = 12,
            rrValidWindowCount = 12,
        )

        val projection = WhoopRepository.projectPublishableDetailedStages(
            sessions = listOf(night, nap),
            offsetAtEpochSec = { 0L },
        )
        val minutes = projection.minutesBySourceDay.getValue(
            night.deviceId to "2026-08-20",
        )

        assertEquals(80.0, WhoopRepository.detailedSleepStageValue("sleep_deep_min", minutes)!!, 0.0)
        assertEquals(100.0, WhoopRepository.detailedSleepStageValue("rem_min", minutes)!!, 0.0)
        assertEquals(230.0, WhoopRepository.detailedSleepStageValue("core_min", minutes)!!, 0.0)
        assertEquals(30.0, WhoopRepository.detailedSleepStageValue("awake_min", minutes)!!, 0.0)
        assertEquals(180.0, WhoopRepository.detailedSleepStageValue("restorative_min", minutes)!!, 0.0)
        assertEquals(180.0 / 410.0 * 100.0,
            WhoopRepository.detailedSleepStageValue("restorative_pct", minutes)!!, 1e-9)
        assertEquals(
            setOf(com.noop.analytics.DetailedSleepStagePublication.key(night)),
            projection.authorizedSessionKeys,
        )
    }

    @Test
    fun projectionWithholdsWholeBridgedNightWhenOneFragmentCannotDecode() {
        val start = Instant.parse("2026-08-20T00:00:00Z").epochSecond
        val staged = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = start,
            endTs = start + 4 * 3_600L,
            stagesJSON = """{"awake":10,"light":150,"deep":40,"rem":40}""",
            rrEligibleWindowCount = 48,
            rrValidWindowCount = 12,
        )
        val malformed = SleepSession(
            deviceId = staged.deviceId,
            startTs = start + 4 * 3_600L + 600L,
            endTs = start + 8 * 3_600L + 600L,
            stagesJSON = """{"not_a_stage":240}""",
            rrEligibleWindowCount = 48,
            rrValidWindowCount = 12,
        )

        val projection = WhoopRepository.projectPublishableDetailedStages(
            sessions = listOf(staged, malformed),
            offsetAtEpochSec = { 0L },
        )

        assertEquals(emptyMap<Pair<String, String>, com.noop.analytics.SleepStageTotals.Minutes>(),
            projection.minutesBySourceDay)
        assertEquals(emptySet<com.noop.analytics.DetailedSleepStagePublication.SessionKey>(),
            projection.authorizedSessionKeys)
    }

    @Test
    fun projectionUsesOffsetAtSessionWakeInsteadOfOffsetAtQueryTime() {
        val end = Instant.parse("2026-01-01T23:30:00Z").epochSecond
        val session = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = end - 8 * 3_600L,
            endTs = end,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
            rrEligibleWindowCount = 96,
            rrValidWindowCount = 24,
        )

        val days = WhoopRepository.publishableDetailedStageDays(
            sessions = listOf(session),
            offsetAtEpochSec = { epoch -> if (epoch == end) 3_600L else -18_000L },
        )

        assertEquals(setOf("2026-01-02"), days)
    }

    @Test
    fun habitualMidsleepUsesEachHistoricalOffset() {
        val baseMidpoint = Instant.parse("2026-01-01T08:00:00Z").epochSecond
        val sessions = (0 until 14).map { index ->
            val midpoint = baseMidpoint + index * 86_400L
            SleepSession(
                deviceId = "my-whoop-noop",
                startTs = midpoint - 4 * 3_600L,
                endTs = midpoint + 4 * 3_600L,
            )
        }

        val habitual = WhoopRepository.historicalHabitualMidsleepSec(
            sessions,
            offsetAtEpochSec = { -5 * 3_600L },
        )

        assertEquals(3 * 3_600L, habitual)
    }

    @Test
    fun habitualMidsleepStaysAtSameLocalClockAcrossDstOffsets() {
        val winterStart = Instant.parse("2026-01-01T08:00:00Z").epochSecond
        val summerStart = Instant.parse("2026-07-01T07:00:00Z").epochSecond
        val winterMidpoints = (0 until 7).map { winterStart + it * 86_400L }
        val summerMidpoints = (0 until 7).map { summerStart + it * 86_400L }
        val sessions = (winterMidpoints + summerMidpoints).map { midpoint ->
            SleepSession(
                deviceId = "my-whoop-noop",
                startTs = midpoint - 4 * 3_600L,
                endTs = midpoint + 4 * 3_600L,
            )
        }

        val habitual = WhoopRepository.historicalHabitualMidsleepSec(
            sessions,
            offsetAtEpochSec = { epoch ->
                if (epoch < summerStart) -5 * 3_600L else -4 * 3_600L
            },
        )

        assertEquals(3 * 3_600L, habitual)
    }

    @Test
    fun customerSeriesAndResolverIgnoreStalePersistedStageValues() = runBlocking {
        val source = "my-whoop-noop"
        val day = "2026-08-20"
        val end = LocalDate.parse(day).atTime(8, 0).atZone(ZoneId.systemDefault()).toEpochSecond()
        val session = SleepSession(
            deviceId = source,
            startTs = end - 8 * 3_600L,
            endTs = end,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
            rrEligibleWindowCount = 96,
            rrValidWindowCount = 24,
        )
        var staleSeriesReads = 0
        var staleDailyReads = 0
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "sleepSessions" -> {
                    val requestedSource = args!![0] as String
                    if (requestedSource == source) listOf(session) else emptyList<SleepSession>()
                }
                "metricSeries" -> {
                    staleSeriesReads += 1
                    listOf(MetricSeriesRow(source, day, "sleep_deep_min", 999.0))
                }
                "dailyMetricsRange" -> {
                    staleDailyReads += 1
                    listOf(DailyMetric(source, day, deepMin = 888.0))
                }
                else -> throw UnsupportedOperationException(
                    "detailed-stage projection must not call ${method.name}",
                )
            }
        } as WhoopDao
        val repository = WhoopRepository(dao)

        val direct = repository.metricSeries(source, "sleep_deep_min", day, day)
        val resolved = repository.resolvedSeries(
            key = "sleep_deep_min",
            preferredSource = source,
            from = day,
            to = day,
        )

        assertEquals(listOf(80.0), direct.map { it.value })
        assertEquals(listOf(day to 80.0), resolved.values)
        assertEquals(0, staleSeriesReads)
        assertEquals(0, staleDailyReads)
    }
}
