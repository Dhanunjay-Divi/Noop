package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class WhoopWorkoutSeriesTest {
    @Test
    fun aggregatesReportedZoneMinutesWithoutRedistributingBelowZoneOneRemainder() {
        val csv = """
            Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
            2026-06-02 08:00:00,2026-06-02 09:00:00,UTC+02:00,Run,10,20,20,10,0
            2026-06-02 18:00:00,2026-06-02 18:30:00,UTC+02:00,Strength Training,20,20,20,10,10
        """.trimIndent().toByteArray()

        val rows = WhoopCsvImporter.parseWorkoutSeries(CsvTable.fromData(csv), "my-whoop")
        val values = rows.associate { it.key to it.value }

        assertEquals(9, rows.size)
        assertEquals(12.0, values.getValue("hr_zone1_min"), 1e-9)
        assertEquals(18.0, values.getValue("hr_zone2_min"), 1e-9)
        assertEquals(18.0, values.getValue("hr_zone3_min"), 1e-9)
        assertEquals(9.0, values.getValue("hr_zone4_min"), 1e-9)
        assertEquals(3.0, values.getValue("hr_zone5_min"), 1e-9)
        assertEquals(48.0, values.getValue("hr_zones13_min"), 1e-9)
        assertEquals(12.0, values.getValue("hr_zones45_min"), 1e-9)
        // The two workouts total 90 minutes. Only 60 minutes are in zones 1-5; the other
        // 30 minutes stay below zone 1 and are not redistributed to force 100% coverage.
        assertEquals(60.0, values.getValue("hr_zones_all_min"), 1e-9)
        assertEquals(30.0, values.getValue("strength_min"), 1e-9)
        assertFalse("below-zone-1 time is a remainder, not a sixth reported zone", "hr_zone0_min" in values)
        assertEquals(setOf("2026-06-02"), rows.map { it.day }.toSet())
    }

    @Test
    fun rowsWithoutValidZoneEvidenceDoNotCreateZeroFilledZoneSeries() {
        val csv = """
            Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %
            2026-06-02 08:00:00,2026-06-02 09:00:00,UTC+00:00,Run,
            2026-06-02 10:00:00,2026-06-02 09:00:00,UTC+00:00,Strength Training,50
        """.trimIndent().toByteArray()

        assertEquals(
            emptyList<com.noop.data.MetricSeriesRow>(),
            WhoopCsvImporter.parseWorkoutSeries(CsvTable.fromData(csv), "my-whoop"),
        )
    }

    @Test
    fun impossibleZoneTotalsAreRejectedInsteadOfExceedingWorkoutDuration() {
        val csv = """
            Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
            2026-06-02 08:00:00,2026-06-02 09:00:00,UTC+00:00,Run,21,21,21,21,21
        """.trimIndent().toByteArray()

        assertEquals(
            emptyList<com.noop.data.MetricSeriesRow>(),
            WhoopCsvImporter.parseWorkoutSeries(CsvTable.fromData(csv), "my-whoop"),
        )
    }

    @Test
    fun onePointRoundingOverflowIsScaledToWorkoutDuration() {
        val csv = """
            Workout start time,Workout end time,Cycle timezone,Activity name,HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %
            2026-06-02 08:00:00,2026-06-02 09:00:00,UTC+00:00,Run,20,20,20,20,21
        """.trimIndent().toByteArray()

        val values = WhoopCsvImporter
            .parseWorkoutSeries(CsvTable.fromData(csv), "my-whoop")
            .associate { it.key to it.value }

        assertEquals(60.0, values.getValue("hr_zones_all_min"), 1e-9)
        assertEquals(60.0, (1..5).sumOf { values.getValue("hr_zone${it}_min") }, 1e-9)
    }
}
