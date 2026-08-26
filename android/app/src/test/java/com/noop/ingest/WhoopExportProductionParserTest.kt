package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Opt-in coverage for a private production export. Raw health archives stay outside git.
 *
 * Run with:
 * `NOOP_WEARABLE_EXPORT_ARCHIVE=/absolute/path/export.zip ./gradlew :app:testFullDebugUnitTest
 * --tests com.noop.ingest.WhoopExportProductionParserTest`
 */
class WhoopExportProductionParserTest {
    @Test
    fun productionArchiveIfAvailable() {
        val configured = System.getenv("NOOP_WEARABLE_EXPORT_ARCHIVE")?.trim()
        assumeTrue(
            "Set NOOP_WEARABLE_EXPORT_ARCHIVE to a private wearable-export archive",
            !configured.isNullOrEmpty(),
        )
        val archive = File(configured!!)
        assertTrue("NOOP_WEARABLE_EXPORT_ARCHIVE does not exist", archive.isFile)

        val loaded = WhoopCsvImporter.loadCsvData(archive.readBytes(), archive.name)
        val expectedFiles = setOf(
            "physiological_cycles.csv",
            "sleeps.csv",
            "workouts.csv",
            "journal_entries.csv",
        )
        assertEquals(expectedFiles, loaded.csvData.keys)
        assertFalse("private production archive unexpectedly hit the aggregate cap", loaded.truncated)

        val cyclesTable = CsvTable.fromData(loaded.csvData.getValue("physiological_cycles.csv"))
        val sleepsTable = CsvTable.fromData(loaded.csvData.getValue("sleeps.csv"))
        val workoutsTable = CsvTable.fromData(loaded.csvData.getValue("workouts.csv"))
        val journalTable = CsvTable.fromData(loaded.csvData.getValue("journal_entries.csv"))

        val cycles = WhoopCsvImporter.parseCycles(cyclesTable, "my-whoop")
        val sleeps = WhoopCsvImporter.parseSleeps(sleepsTable, "my-whoop")
        val cycleSeries = WhoopCsvImporter.parseCycleSeries(cyclesTable, "my-whoop")
        val workouts = WhoopCsvImporter.parseWorkouts(workoutsTable, "my-whoop")
        val workoutSeries = WhoopCsvImporter.parseWorkoutSeries(workoutsTable, "my-whoop")
        val wakeDays = WhoopCsvImporter.journalWakeDayMap(cyclesTable)
        val journal = WhoopCsvImporter.parseJournal(journalTable, "my-whoop", wakeDays)

        assertFalse(cycles.isEmpty())
        assertFalse(sleeps.sessions.isEmpty())
        assertFalse(workouts.isEmpty())
        assertTrue(cycles.all { it.efficiency?.let { value -> value in 0.0..1.0 } ?: true })
        assertTrue(
            sleeps.sessions.all {
                it.efficiency?.let { value -> value in 0.0..1.0 } ?: true
            },
        )
        assertTrue(
            cycleSeries
                .filter { it.key == "sleep_efficiency" }
                .all { it.value in 0.0..1.0 },
        )
        assertTrue(cycleSeries.all { it.value.isFinite() })
        assertTrue(
            setOf(
                "recovery",
                "strain",
                "rhr",
                "hrv",
                "spo2",
                "skin_temp",
                "resp_rate",
                "energy_kcal",
                "avg_hr",
                "max_hr",
                "sleep_total_min",
                "in_bed_min",
                "sleep_deep_min",
                "sleep_rem_min",
                "sleep_light_min",
                "awake_min",
                "sleep_efficiency",
                "sleep_performance",
                "sleep_consistency",
                "sleep_need_min",
                "sleep_debt_min",
                "restorative_min",
                "restorative_pct",
                "hours_vs_needed_pct",
            ).all { key -> cycleSeries.any { it.key == key } },
        )
        assertTrue(cycleSeries.filter { it.key == "skin_temp" }.all { it.value < 60.0 })
        assertTrue(
            setOf(
                "hr_zone1_min",
                "hr_zone2_min",
                "hr_zone3_min",
                "hr_zone4_min",
                "hr_zone5_min",
                "hr_zones13_min",
                "hr_zones45_min",
                "hr_zones_all_min",
            ).all { key -> workoutSeries.any { it.key == key } },
        )

        assertEquals(
            "production parser emitted duplicate persisted journal entries",
            journal.distinct().size,
            journal.size,
        )
        val answersByDayQuestion = journal
            .groupBy { it.day to it.question }
            .mapValues { (_, rows) -> rows.map { it.answeredYes }.toSet() }
        assertTrue(
            "production parser retained contradictory answers for one day/question",
            answersByDayQuestion.values.none { it.size > 1 },
        )
    }
}
