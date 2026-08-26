package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WhoopCsvImportStoreInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var dao: WhoopDao
    private lateinit var repository: WhoopRepository

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        dao = database.whoopDao()
        repository = WhoopRepository(database)
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun officialRowsReplaceAndLocalDailyFieldsFillWhileOtherRowsRemainInsertOnly() = runBlocking {
        val official = "wearable-import"
        val local = "$official-noop"
        val firstStart = 1_767_300_000L
        val secondStart = firstStart + 86_400L
        dao.upsertDailyMetrics(listOf(DailyMetric(official, "2026-01-02", recovery = 10.0)))
        dao.upsertDailyMetrics(listOf(DailyMetric(local, "2026-01-02", recovery = 20.0)))
        dao.upsertSleepSessions(
            listOf(SleepSession(local, firstStart, firstStart + 20_000, efficiency = 0.5))
        )
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(local, "2026-01-02", "recovery", 30.0),
                MetricSeriesRow(local, "2026-01-02", "sleep_performance", 40.0),
                MetricSeriesRow(official, "2026-01-02", "recovery", 50.0),
            )
        )
        dao.upsertWorkouts(
            listOf(workout(local, firstStart, firstStart + 1_800, energy = 100.0))
        )

        repository.importWhoopCsv(
            WhoopCsvImportBatch(
                officialDailyMetrics =
                    listOf(DailyMetric(official, "2026-01-02", recovery = 91.0)),
                fillOnlyDailyMetrics = listOf(
                    DailyMetric(
                        local,
                        "2026-01-02",
                        totalSleepMin = 480.0,
                        recovery = 92.0,
                    ),
                    DailyMetric(
                        local,
                        "2026-01-02",
                        efficiency = 0.88,
                        restingHr = 54,
                        recovery = 99.0,
                    ),
                    DailyMetric(local, "2026-01-03", recovery = 93.0),
                ),
                fillOnlySleepSessions = listOf(
                    SleepSession(local, firstStart, firstStart + 30_000, efficiency = 0.9),
                    SleepSession(local, secondStart, secondStart + 30_000, efficiency = 0.8),
                ),
                officialMetricSeriesReplacements = listOf(
                    WhoopCsvMetricSeriesReplacement(
                        deviceId = official,
                        fromDay = "2026-01-02",
                        toDay = "2026-01-02",
                        managedKeys = listOf("recovery", "hrv"),
                        rows = listOf(
                            MetricSeriesRow(official, "2026-01-02", "recovery", 94.0)
                        ),
                    )
                ),
                fillOnlyMetricSeries = listOf(
                    MetricSeriesRow(local, "2026-01-02", "recovery", 95.0),
                    MetricSeriesRow(local, "2026-01-02", "sleep_performance", 96.0),
                    MetricSeriesRow(local, "2026-01-03", "recovery", 97.0),
                ),
                fillOnlyWorkouts = listOf(
                    workout(local, firstStart, firstStart + 3_600, energy = 200.0),
                    workout(local, secondStart, secondStart + 3_600, energy = 300.0),
                ),
            )
        )

        assertEquals(
            listOf(91.0),
            dao.dailyMetricsRange(official, "2026-01-02", "2026-01-03").map { it.recovery },
        )
        val localDays = dao.dailyMetricsRange(local, "2026-01-02", "2026-01-03")
        assertEquals(listOf(20.0, 93.0), localDays.map { it.recovery })
        assertEquals(480.0, localDays.first().totalSleepMin)
        assertEquals(0.88, localDays.first().efficiency)
        assertEquals(54, localDays.first().restingHr)
        val sleeps = dao.sleepSessions(local, firstStart, secondStart, 10)
        assertEquals(listOf(0.5, 0.8), sleeps.map { it.efficiency })
        assertEquals(firstStart + 20_000, sleeps.first().endTs)
        assertEquals(
            listOf(94.0),
            dao.metricSeries(official, "recovery", "2026-01-02", "2026-01-03")
                .map { it.value },
        )
        assertEquals(
            listOf(30.0, 97.0),
            dao.metricSeries(local, "recovery", "2026-01-02", "2026-01-03")
                .map { it.value },
        )
        assertEquals(
            listOf(40.0),
            dao.metricSeries(local, "sleep_performance", "2026-01-02", "2026-01-03")
                .map { it.value },
        )
        val workouts = dao.workouts(local, firstStart, secondStart, 10)
        assertEquals(listOf(100.0, 300.0), workouts.map { it.energyKcal })
        assertEquals(firstStart + 1_800, workouts.first().endTs)
    }

    @Test
    fun officialSleepReimportPreservesCompleteEditedRow() = runBlocking {
        val deviceId = "wearable-import"
        val start = 1_767_300_000L
        val edited = SleepSession(
            deviceId = deviceId,
            startTs = start,
            endTs = start + 28_800,
            efficiency = 0.72,
            restingHr = 61,
            avgHrv = 39.0,
            stagesJSON = """[{"stage":"edited"}]""",
            userEdited = true,
            startTsAdjusted = start + 900,
            motionJSON = "[0.1,0.2]",
            sleepStateJSON = "[1,2]",
        )
        dao.upsertSleepSessions(listOf(edited))

        repository.importWhoopCsv(
            WhoopCsvImportBatch(
                officialSleepSessions = listOf(
                    SleepSession(
                        deviceId = deviceId,
                        startTs = start,
                        endTs = start + 32_400,
                        efficiency = 0.91,
                        restingHr = 52,
                        avgHrv = 62.0,
                        stagesJSON = """[{"stage":"provider"}]""",
                    )
                ),
            )
        )

        val persisted = dao.sleepSessionByKey(deviceId, start)!!
        assertEquals(edited, persisted)
    }

    @Test
    fun sleepOnlyDailyImportFillsMissingFieldsWithoutReplacingExistingValues() = runBlocking {
        val deviceId = "wearable-import"
        val day = "2026-01-02"
        dao.upsertDailyMetrics(
            listOf(
                DailyMetric(
                    deviceId = deviceId,
                    day = day,
                    totalSleepMin = 430.0,
                    efficiency = 0.82,
                    restingHr = 52,
                    avgHrv = 61.0,
                    recovery = 88.0,
                    strain = 47.0,
                ),
                DailyMetric(deviceId, "2026-01-03", recovery = 77.0),
            )
        )

        repository.importWhoopCsv(
            WhoopCsvImportBatch(
                fillOnlyDailyMetrics = listOf(
                    DailyMetric(
                        deviceId = deviceId,
                        day = day,
                        totalSleepMin = 480.0,
                        efficiency = 0.94,
                        deepMin = 105.0,
                        remMin = 92.0,
                        restingHr = 99,
                        avgHrv = 1.0,
                        recovery = 5.0,
                        strain = 3.0,
                    )
                ),
            )
        )

        val rows = dao.dailyMetricsRange(deviceId, day, "2026-01-03")
        val persisted = rows.first { it.day == day }
        assertEquals(430.0, persisted.totalSleepMin!!, 0.0)
        assertEquals(0.82, persisted.efficiency!!, 0.0)
        assertEquals(105.0, persisted.deepMin!!, 0.0)
        assertEquals(92.0, persisted.remMin!!, 0.0)
        assertEquals(52, persisted.restingHr)
        assertEquals(61.0, persisted.avgHrv!!, 0.0)
        assertEquals(88.0, persisted.recovery!!, 0.0)
        assertEquals(47.0, persisted.strain!!, 0.0)
        assertEquals(77.0, rows.first { it.day == "2026-01-03" }.recovery!!, 0.0)
    }

    @Test
    fun officialWorkoutReplacementIsSourceScopedAndNormalizesIncomingRows() = runBlocking {
        val deviceId = "wearable-import"
        val firstStart = 1_767_300_000L
        val secondStart = firstStart + 3_600L
        val manualStart = firstStart + 1_800L
        val collisionStart = secondStart + 1_800L
        dao.upsertWorkouts(
            listOf(
                workout(
                    deviceId,
                    firstStart,
                    firstStart + 1_200,
                    energy = 100.0,
                    sport = "Stale imported run",
                    source = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
                ),
                workout(
                    deviceId,
                    secondStart,
                    secondStart + 1_200,
                    energy = 200.0,
                    sport = "Stale imported ride",
                    source = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
                ),
                workout(
                    deviceId,
                    manualStart,
                    manualStart + 900,
                    energy = 50.0,
                    sport = "Manual mobility",
                    source = "manual",
                ),
                workout(
                    deviceId,
                    collisionStart,
                    collisionStart + 900,
                    energy = 75.0,
                    sport = "Collision workout",
                    source = "manual",
                ),
            )
        )

        repository.importWhoopCsv(
            WhoopCsvImportBatch(
                officialWorkouts = listOf(
                    workout(
                        deviceId,
                        firstStart,
                        firstStart + 1_500,
                        energy = 300.0,
                        sport = "Fresh imported run",
                        source = "provider-label-that-must-not-persist",
                    ),
                    workout(
                        deviceId,
                        collisionStart,
                        collisionStart + 1_500,
                        energy = 999.0,
                        sport = "Collision workout",
                        source = "provider-label-that-must-not-persist",
                    ),
                ),
                officialWorkoutRange = WhoopCsvTimestampRange(
                    deviceId,
                    firstStart,
                    collisionStart,
                ),
            )
        )

        val rows = dao.workouts(deviceId, firstStart, collisionStart, 10)
        assertEquals(
            setOf("Fresh imported run", "Manual mobility", "Collision workout"),
            rows.map { it.sport }.toSet(),
        )
        val bySport = rows.associateBy { it.sport }
        assertEquals(
            WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
            bySport.getValue("Fresh imported run").source,
        )
        assertEquals("manual", bySport.getValue("Manual mobility").source)
        assertEquals(300.0, bySport.getValue("Fresh imported run").energyKcal!!, 0.0)
        assertEquals(50.0, bySport.getValue("Manual mobility").energyKcal!!, 0.0)
        assertEquals("manual", bySport.getValue("Collision workout").source)
        assertEquals(75.0, bySport.getValue("Collision workout").energyKcal!!, 0.0)
    }

    @Test
    fun officialRangesRemoveMissingRowsButPreserveLocalSleepEvidenceAndEdits() = runBlocking {
        val deviceId = "wearable-import"
        val firstStart = 1_767_300_000L
        val secondStart = firstStart + 86_400L
        val thirdStart = secondStart + 86_400L
        val fourthStart = thirdStart + 86_400L

        dao.upsertDailyMetrics(
            listOf(
                DailyMetric(deviceId, "2026-01-02", recovery = 20.0),
                DailyMetric(deviceId, "2026-01-03", recovery = 30.0),
                DailyMetric(deviceId, "2026-01-04", recovery = 40.0),
            )
        )
        dao.upsertSleepSessions(
            listOf(
                SleepSession(deviceId, firstStart, firstStart + 20_000, efficiency = 0.7),
                SleepSession(deviceId, secondStart, secondStart + 20_000, efficiency = 0.7),
                SleepSession(deviceId, thirdStart, thirdStart + 20_000, efficiency = 0.7),
                SleepSession(
                    deviceId,
                    fourthStart,
                    fourthStart + 20_000,
                    efficiency = 0.7,
                    stagesJSON = """[{"edited":true}]""",
                    userEdited = true,
                ),
            )
        )
        dao.updateSessionMotion(deviceId, secondStart, "[0.1,0.2]")
        dao.upsertWorkouts(
            listOf(
                workout(
                    deviceId,
                    firstStart,
                    firstStart + 1_800,
                    energy = 100.0,
                    source = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
                ),
                workout(
                    deviceId,
                    secondStart,
                    secondStart + 1_800,
                    energy = 200.0,
                    source = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
                ),
            )
        )

        repository.importWhoopCsv(
            WhoopCsvImportBatch(
                officialDailyMetrics =
                    listOf(DailyMetric(deviceId, "2026-01-02", recovery = 91.0)),
                officialDailyMetricRange = WhoopCsvDayRange(
                    deviceId, "2026-01-02", "2026-01-04"),
                officialSleepSessions = listOf(
                    SleepSession(deviceId, firstStart, firstStart + 30_000, efficiency = 0.9)
                ),
                officialSleepSessionRange = WhoopCsvTimestampRange(
                    deviceId, firstStart, fourthStart),
                officialWorkouts = listOf(
                    workout(deviceId, firstStart, firstStart + 3_600, energy = 300.0)
                ),
                officialWorkoutRange = WhoopCsvTimestampRange(
                    deviceId, firstStart, secondStart),
            )
        )

        val days = dao.dailyMetricsRange(deviceId, "2026-01-02", "2026-01-04")
        assertEquals(listOf("2026-01-02"), days.map { it.day })
        assertEquals(listOf(91.0), days.map { it.recovery })

        val sleeps = dao.sleepSessions(deviceId, firstStart, fourthStart, 10)
        assertEquals(listOf(firstStart, secondStart, fourthStart), sleeps.map { it.startTs })
        assertEquals(0.9, sleeps.first().efficiency!!, 0.0)
        assertEquals("""[{"edited":true}]""", sleeps.last().stagesJSON)
        assertEquals("[0.1,0.2]", dao.sessionMotionJson(deviceId, secondStart))

        val workouts = dao.workouts(deviceId, firstStart, secondStart, 10)
        assertEquals(listOf(firstStart), workouts.map { it.startTs })
        assertEquals(listOf(300.0), workouts.map { it.energyKcal })
    }

    @Test
    fun lateWorkoutFailureRollsBackEarlierRowsAndRangeDeletion() = runBlocking {
        val deviceId = "wearable-import"
        dao.upsertMetricSeries(
            listOf(MetricSeriesRow(deviceId, "2026-01-02", "recovery", 55.0))
        )
        database.openHelper.writableDatabase.execSQL(
            """
            CREATE TRIGGER abort_csv_import_workout
            BEFORE INSERT ON workout
            WHEN NEW.sport = 'Abort transaction'
            BEGIN
                SELECT RAISE(ABORT, 'forced late import failure');
            END
            """.trimIndent()
        )

        var failed = false
        try {
            repository.importWhoopCsv(
                WhoopCsvImportBatch(
                    officialDailyMetrics =
                        listOf(DailyMetric(deviceId, "2026-01-02", recovery = 90.0)),
                    officialMetricSeriesReplacements = listOf(
                        WhoopCsvMetricSeriesReplacement(
                            deviceId = deviceId,
                            fromDay = "2026-01-02",
                            toDay = "2026-01-02",
                            managedKeys = listOf("recovery"),
                            rows = emptyList(),
                        )
                    ),
                    officialWorkouts = listOf(
                        workout(
                            deviceId,
                            1_767_300_000,
                            1_767_303_600,
                            energy = null,
                            sport = "Abort transaction",
                        )
                    ),
                )
            )
        } catch (_: Exception) {
            failed = true
        }

        assertTrue("the trigger must abort the import", failed)
        assertTrue(
            dao.dailyMetricsRange(deviceId, "2026-01-02", "2026-01-02").isEmpty()
        )
        assertEquals(
            listOf(55.0),
            dao.metricSeries(deviceId, "recovery", "2026-01-02", "2026-01-02")
                .map { it.value },
        )
    }

    @Test
    fun lateCsvFailureRollsBackPortableRowsDeviceAndCsvProjection() = runBlocking {
        val deviceId = "wearable-archive"
        val nutritionId = "archive-meal"
        val timestamp = 1_777_000_000L
        val portable = PortableUserData(
            exportedAt = timestamp + 100,
            nutritionEntries = listOf(
                NutritionEntryRow(
                    id = nutritionId,
                    origin = NutritionLogContract.MANUAL_ORIGIN,
                    day = "2026-04-25",
                    occurredAt = timestamp,
                    mealType = "lunch",
                    label = "Rollback meal",
                    proteinG = 30.0,
                    createdAt = timestamp,
                    updatedAt = timestamp,
                ),
            ),
            strengthExercises = emptyList(),
            strengthRoutines = emptyList(),
            strengthRoutineExercises = emptyList(),
            strengthSessions = emptyList(),
            strengthSets = emptyList(),
        )
        database.openHelper.writableDatabase.execSQL(
            """
            CREATE TRIGGER abort_archive_import_workout
            BEFORE INSERT ON workout
            WHEN NEW.sport = 'Abort archive transaction'
            BEGIN
                SELECT RAISE(ABORT, 'forced late archive failure');
            END
            """.trimIndent()
        )

        var failed = false
        try {
            repository.importWhoopArchive(
                portableUserData = portable,
                devices = listOf(WhoopCsvDeviceRegistration(deviceId, "Noop Band")),
                csvBatch = WhoopCsvImportBatch(
                    officialDailyMetrics = listOf(
                        DailyMetric(deviceId, "2026-04-25", recovery = 90.0),
                    ),
                    officialWorkouts = listOf(
                        workout(
                            deviceId = deviceId,
                            start = timestamp,
                            end = timestamp + 3_600,
                            energy = null,
                            sport = "Abort archive transaction",
                        ),
                    ),
                ),
            )
        } catch (_: Exception) {
            failed = true
        }

        assertTrue("the trigger must abort the combined archive import", failed)
        assertNull(dao.nutritionEntry(nutritionId))
        assertNull(dao.device(deviceId))
        assertTrue(
            dao.dailyMetricsRange(deviceId, "2026-04-25", "2026-04-25").isEmpty(),
        )
        assertTrue(
            dao.workouts(deviceId, timestamp, timestamp + 3_600, 10).isEmpty(),
        )
    }

    private fun workout(
        deviceId: String,
        start: Long,
        end: Long,
        energy: Double?,
        sport: String = "Run",
        source: String = "analytics",
    ) = WorkoutRow(
        deviceId = deviceId,
        startTs = start,
        endTs = end,
        sport = sport,
        source = source,
        durationS = (end - start).toDouble(),
        energyKcal = energy,
    )
}
