package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins WhoopCsvImporter.parseCycleSeries: physiological_cycles.csv -> the complete long-format
 * metricSeries projection imported on Apple, attributed to the local WAKE day.
 */
class WhoopCycleSeriesTest {

    @Test
    fun mapsTheFourSleepFigureColumns() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Sleep performance %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+02:00,85,88,480,60
        """.trimIndent().toByteArray()
        val rows = WhoopCsvImporter.parseCycleSeries(CsvTable.fromData(csv), "my-whoop")
        assertEquals(4, rows.size)
        // Onset-to-onset cycle (start 06-01 evening, end 06-02 evening, no wake column) → wake day 06-02.
        assertTrue(rows.all { it.deviceId == "my-whoop" && it.day == "2026-06-02" })
        assertEquals(85.0, rows.first { it.key == "sleep_performance" }.value, 1e-9)
        assertEquals(88.0, rows.first { it.key == "sleep_consistency" }.value, 1e-9)
        assertEquals(480.0, rows.first { it.key == "sleep_need_min" }.value, 1e-9)
        assertEquals(60.0, rows.first { it.key == "sleep_debt_min" }.value, 1e-9)
    }

    @Test
    fun mapsCompleteAppleCycleProjectionWithCanonicalUnits() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (F),Blood oxygen %,Day Strain,Energy burned (cal),Average HR (bpm),Max HR (bpm),Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Deep (SWS) duration (min),REM duration (min),Light sleep duration (min),Awake duration (min),Sleep efficiency %,Sleep performance %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+02:00,78,51,72,95,97,10.5,2200,62,151,14.2,420,450,90,100,230,30,92,88,85,480,60
        """.trimIndent().toByteArray()

        val rows = WhoopCsvImporter.parseCycleSeries(CsvTable.fromData(csv), "my-whoop")
        val values = rows.associate { it.key to it.value }

        assertEquals(24, rows.size)
        assertEquals(78.0, values.getValue("recovery"), 1e-9)
        assertEquals(50.0, values.getValue("strain"), 1e-9)
        assertEquals(51.0, values.getValue("rhr"), 1e-9)
        assertEquals(72.0, values.getValue("hrv"), 1e-9)
        assertEquals(97.0, values.getValue("spo2"), 1e-9)
        assertEquals(35.0, values.getValue("skin_temp"), 1e-9)
        assertEquals(14.2, values.getValue("resp_rate"), 1e-9)
        assertEquals(2200.0, values.getValue("energy_kcal"), 1e-9)
        assertEquals(62.0, values.getValue("avg_hr"), 1e-9)
        assertEquals(151.0, values.getValue("max_hr"), 1e-9)
        assertEquals(420.0, values.getValue("sleep_total_min"), 1e-9)
        assertEquals(450.0, values.getValue("in_bed_min"), 1e-9)
        assertEquals(90.0, values.getValue("sleep_deep_min"), 1e-9)
        assertEquals(100.0, values.getValue("sleep_rem_min"), 1e-9)
        assertEquals(230.0, values.getValue("sleep_light_min"), 1e-9)
        assertEquals(30.0, values.getValue("awake_min"), 1e-9)
        assertEquals(0.92, values.getValue("sleep_efficiency"), 1e-9)
        assertEquals(88.0, values.getValue("sleep_performance"), 1e-9)
        assertEquals(85.0, values.getValue("sleep_consistency"), 1e-9)
        assertEquals(480.0, values.getValue("sleep_need_min"), 1e-9)
        assertEquals(60.0, values.getValue("sleep_debt_min"), 1e-9)
        assertEquals(190.0, values.getValue("restorative_min"), 1e-9)
        assertEquals(190.0 / 420.0 * 100.0, values.getValue("restorative_pct"), 1e-9)
        assertEquals(420.0 / 480.0 * 100.0, values.getValue("hours_vs_needed_pct"), 1e-9)
        assertTrue(rows.all { it.day == "2026-06-02" && it.value.isFinite() })
    }

    @Test
    fun blankCellsProduceNoRowAndTimestamplessRowsAreSkipped() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Sleep performance %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+02:00,,88,,
            ,,UTC+02:00,85,88,480,60
        """.trimIndent().toByteArray()
        val rows = WhoopCsvImporter.parseCycleSeries(CsvTable.fromData(csv), "my-whoop")
        assertEquals(1, rows.size)
        assertEquals("sleep_consistency", rows.single().key)
        assertEquals(88.0, rows.single().value, 1e-9)
    }

    @Test
    fun onePercentEfficiencyIsStoredAsOneHundredthNotAWholeFraction() {
        val csv = """
            Cycle start time,Cycle end time,Cycle timezone,Sleep efficiency %
            2026-06-01 22:30:00,2026-06-02 21:00:00,UTC+00:00,1
        """.trimIndent().toByteArray()

        val row = WhoopCsvImporter.parseCycleSeries(
            CsvTable.fromData(csv),
            "my-whoop",
        ).single()

        assertEquals("sleep_efficiency", row.key)
        assertEquals(0.01, row.value, 1e-12)
    }
}
