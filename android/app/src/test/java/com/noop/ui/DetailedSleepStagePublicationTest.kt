package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailedSleepStagePublicationTest {
    private val zone = ZoneId.systemDefault()

    private fun day(value: String, deep: Double = 70.0, rem: Double = 90.0) = DailyMetric(
        deviceId = "my-whoop",
        day = value,
        totalSleepMin = 420.0,
        deepMin = deep,
        remMin = rem,
        lightMin = 260.0,
        efficiency = 0.9,
    )

    private fun session(source: String, day: String, supported: Boolean = false): SleepSession {
        val end = LocalDate.parse(day).atTime(8, 0).atZone(zone).toEpochSecond()
        return SleepSession(
            deviceId = source,
            startTs = end - 8 * 3_600,
            endTs = end,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
            rrEligibleWindowCount = if (supported) 96 else null,
            rrValidWindowCount = if (supported) 24 else null,
        )
    }

    @Test
    fun localStagesRequireEvidenceWhileImportedStagesKeepTheirProvenance() {
        val days = listOf(
            day("2026-08-20"),
            day("2026-08-21"),
            day("2026-08-22"),
        )
        val localSupported = session("my-whoop-noop", "2026-08-20", supported = true)
        val imported = session("fitbit-import", "2026-08-21")
        val localUnsupported = session("my-whoop-noop", "2026-08-22")

        val publishable = detailedStagePublicationDays(
            days = days,
            sessions = listOf(localSupported, imported, localUnsupported),
        )

        assertEquals(setOf("2026-08-20", "2026-08-21"), publishable)
        assertTrue(selectNight(listOf(listOf(imported)), days, 0)!!.independentlyStagedImport)
        assertFalse(selectNight(listOf(listOf(localUnsupported)), days, 0)!!.independentlyStagedImport)
    }

    @Test
    fun importedNapCannotAuthorizeUnsupportedLocalMainNight() {
        val dayKey = "2026-08-20"
        val end = LocalDate.parse(dayKey).atTime(8, 0).atZone(zone).toEpochSecond()
        val localMain = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = end - 8 * 3_600,
            endTs = end,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
        )
        val napStart = LocalDate.parse(dayKey).atTime(14, 0).atZone(zone).toEpochSecond()
        val importedNap = SleepSession(
            deviceId = "oura-import",
            startTs = napStart,
            endTs = napStart + 3_600,
            stagesJSON = """{"awake":5,"light":35,"deep":10,"rem":10}""",
        )
        val sessions = listOf(localMain, importedNap)

        assertEquals(
            emptySet<String>(),
            detailedStagePublicationDays(
                days = listOf(day(dayKey)),
                sessions = sessions,
            ),
        )
        val selected = selectNight(listOf(sessions), listOf(day(dayKey)), 0)!!
        assertFalse(selected.independentlyStagedImport)
        assertFalse(
            canPublishDetailedStages(selected),
        )
    }

    @Test
    fun stageDerivedHistoryIsFilteredAndNeverBecomesAStaleLatestValue() {
        val days = listOf(
            day("2026-08-20", deep = 60.0, rem = 80.0),
            day("2026-08-21", deep = 80.0, rem = 100.0),
            day("2026-08-22", deep = 120.0, rem = 120.0),
        )

        val filtered = buildSleepModel(
            days = days,
            session = null,
            selectedDay = "2026-08-22",
            detailedStageDays = setOf("2026-08-20", "2026-08-21"),
        )!!

        assertEquals(70.0, filtered.typicalDeepMin!!, 1e-9)
        assertEquals(90.0, filtered.typicalRemMin!!, 1e-9)
        assertEquals(2, filtered.restorative.series.size)
        assertNull(filtered.restorative.latest)
        assertEquals(
            listOf("2026-08-20", "2026-08-21"),
            buildSleepMetricPoints(
                days,
                key = "restorative",
                detailedStageDays = setOf("2026-08-20", "2026-08-21"),
            ).map { it.first },
        )

        val supportedLatest = buildSleepModel(
            days = days,
            session = null,
            selectedDay = "2026-08-22",
            detailedStageDays = days.mapTo(linkedSetOf()) { it.day },
        )!!
        assertTrue(supportedLatest.restorative.latest != null)
    }
}
