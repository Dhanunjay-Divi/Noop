package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.io.File
import java.lang.reflect.Proxy
import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntelligenceStepIntegrityTest {
    private data class Fixture(
        val repo: WhoopRepository,
        val daily: MutableMap<Pair<String, String>, DailyMetric>,
        val series: MutableMap<Triple<String, String, String>, MetricSeriesRow>,
        val deleteChunkSizes: MutableList<Int>,
        var failEstimateDelete: Boolean = false,
    )

    private fun fixture(): Fixture {
        val daily = linkedMapOf<Pair<String, String>, DailyMetric>()
        val series = linkedMapOf<Triple<String, String, String>, MetricSeriesRow>()
        val deleteChunkSizes = mutableListOf<Int>()
        lateinit var fixture: Fixture
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "deleteMetricSeriesPoints" -> {
                    if (fixture.failEstimateDelete) error("injected estimate delete failure")
                    val source = args!![0] as String
                    @Suppress("UNCHECKED_CAST")
                    val days = (args[1] as List<String>).toSet()
                    deleteChunkSizes += days.size
                    val key = args[2] as String
                    val doomed = series.keys.filter {
                        it.first == source && it.second in days && it.third == key
                    }
                    doomed.forEach(series::remove)
                    doomed.size
                }
                "clearMatchingDailySteps" -> {
                    val source = args!![0] as String
                    val day = args[1] as String
                    val expected = args[2] as Int
                    val mapKey = source to day
                    val row = daily[mapKey]
                    if (row?.steps == expected) {
                        daily[mapKey] = row.copy(steps = null)
                        1
                    } else {
                        0
                    }
                }
                "clearComputedDailySteps" -> {
                    val source = args!![0] as String
                    @Suppress("UNCHECKED_CAST")
                    val days = (args[1] as List<String>).toSet()
                    val targets = daily.keys.filter {
                        it.first == source &&
                            it.second in days &&
                            daily[it]?.steps != null
                    }
                    targets.forEach { key ->
                        daily[key] = requireNotNull(daily[key]).copy(steps = null)
                    }
                    targets.size
                }
                "deleteMatchingMetricSeriesPoint" -> {
                    if (fixture.failEstimateDelete) error("injected estimate delete failure")
                    val source = args!![0] as String
                    val day = args[1] as String
                    val key = args[2] as String
                    val expected = args[3] as Double
                    val mapKey = Triple(source, day, key)
                    if (series[mapKey]?.value == expected) {
                        series.remove(mapKey)
                        1
                    } else {
                        0
                    }
                }
                "dailyMetricsRange" -> {
                    val source = args!![0] as String
                    val from = args[1] as String
                    val to = args[2] as String
                    daily.values
                        .filter { it.deviceId == source && it.day in from..to }
                        .sortedBy(DailyMetric::day)
                }
                "deleteDailyMetricsInRange" -> {
                    val source = args!![0] as String
                    val from = args[1] as String
                    val to = args[2] as String
                    daily.keys
                        .filter { it.first == source && it.second in from..to }
                        .forEach(daily::remove)
                    Unit
                }
                "upsertDailyMetrics" -> {
                    @Suppress("UNCHECKED_CAST")
                    val rows = args!![0] as List<DailyMetric>
                    rows.forEach { daily[it.deviceId to it.day] = it }
                    Unit
                }
                "replaceMetricSeriesRange" -> Unit
                else -> throw UnsupportedOperationException(
                    "step integrity fixture must not call ${method.name}"
                )
            }
        } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                val dailySnapshot = daily.toMap()
                val seriesSnapshot = series.toMap()
                return try {
                    block()
                } catch (error: Throwable) {
                    daily.clear()
                    daily.putAll(dailySnapshot)
                    series.clear()
                    series.putAll(seriesSnapshot)
                    throw error
                }
            }
        }
        fixture = Fixture(
            repo = WhoopRepository(dao, transactor),
            daily = daily,
            series = series,
            deleteChunkSizes = deleteChunkSizes,
        )
        return fixture
    }

    @Test
    fun authoritativeCounterRepairDeletesOnlySupersededEstimate() = runBlocking {
        val f = fixture()
        val targetSource = "whoop-ABC123-noop"
        val canonicalSource = "my-whoop-noop"
        val day = "2026-09-24"
        val adjacentDay = "2026-09-23"
        val target = DailyMetric(
            deviceId = targetSource,
            day = day,
            totalSleepMin = 420.0,
            recovery = 60.0,
            strain = 8.0,
            steps = 4_000,
        )
        f.daily[targetSource to day] = target
        f.daily[targetSource to adjacentDay] = target.copy(day = adjacentDay, steps = 2_000)
        f.daily["health-connect" to day] = target.copy(deviceId = "health-connect", steps = 5_000)
        f.series[Triple(targetSource, day, "steps_est")] =
            MetricSeriesRow(targetSource, day, "steps_est", 4_000.0)
        f.series[Triple(canonicalSource, day, "steps_est")] =
            MetricSeriesRow(canonicalSource, day, "steps_est", 4_000.0)
        f.series[Triple(targetSource, adjacentDay, "steps_est")] =
            MetricSeriesRow(targetSource, adjacentDay, "steps_est", 2_000.0)

        assertEquals(
            2,
            f.repo.reconcileComputedStepEvidence(
                deviceIds = listOf(targetSource, canonicalSource, targetSource),
                deleteEstimateDays = listOf(day, day),
            ),
        )

        val repaired = f.daily[targetSource to day]
        assertEquals(4_000, repaired?.steps)
        assertEquals(60.0, repaired?.recovery)
        assertEquals(8.0, repaired?.strain)
        assertEquals(2_000, f.daily[targetSource to adjacentDay]?.steps)
        assertEquals(5_000, f.daily["health-connect" to day]?.steps)
        assertNull(f.series[Triple(targetSource, day, "steps_est")])
        assertNull(f.series[Triple(canonicalSource, day, "steps_est")])
        assertEquals(2_000.0, f.series[Triple(targetSource, adjacentDay, "steps_est")]?.value)
        assertEquals(1L, f.repo.metricDataVersion.value)
        assertEquals(0L, f.repo.restDataVersion.value)
    }

    @Test
    fun clearComputedStepDaysRemovesOldFourThousandButPreservesImportedRows() = runBlocking {
        val f = fixture()
        val computedSource = "whoop-ABC123-noop"
        val healthConnect = "health-connect"
        val osImport = "apple-health"
        val day = "2026-09-24"
        val oldComputed = DailyMetric(
            deviceId = computedSource,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.daily[computedSource to day] = oldComputed
        f.daily[healthConnect to day] =
            oldComputed.copy(deviceId = healthConnect, recovery = 75.0, steps = 8_000)
        f.daily[osImport to day] =
            oldComputed.copy(deviceId = osImport, recovery = 80.0, steps = 9_000)
        f.series[Triple(computedSource, day, "steps_est")] =
            MetricSeriesRow(computedSource, day, "steps_est", 4_000.0)
        f.series[Triple(healthConnect, day, "steps_est")] =
            MetricSeriesRow(healthConnect, day, "steps_est", 8_000.0)
        f.series[Triple(osImport, day, "steps_est")] =
            MetricSeriesRow(osImport, day, "steps_est", 9_000.0)

        assertEquals(
            2,
            f.repo.reconcileComputedStepEvidence(
                deviceIds = listOf(computedSource),
                deleteEstimateDays = emptyList(),
                clearComputedStepDays = listOf(day),
            ),
        )

        assertNull(f.daily[computedSource to day]?.steps)
        assertEquals(60.0, f.daily[computedSource to day]?.recovery)
        assertNull(f.series[Triple(computedSource, day, "steps_est")])
        assertEquals(8_000, f.daily[healthConnect to day]?.steps)
        assertEquals(75.0, f.daily[healthConnect to day]?.recovery)
        assertEquals(8_000.0, f.series[Triple(healthConnect, day, "steps_est")]?.value)
        assertEquals(9_000, f.daily[osImport to day]?.steps)
        assertEquals(80.0, f.daily[osImport to day]?.recovery)
        assertEquals(9_000.0, f.series[Triple(osImport, day, "steps_est")]?.value)
        assertEquals(1L, f.repo.metricDataVersion.value)
    }

    @Test
    fun clearComputedStepDaysRejectsImportedSourceIds() = runBlocking {
        val failure = runCatching {
            fixture().repo.reconcileComputedStepEvidence(
                deviceIds = listOf("health-connect"),
                deleteEstimateDays = emptyList(),
                clearComputedStepDays = listOf("2026-09-24"),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
    }

    @Test
    fun estimateRepairFailureLeavesDailyEvidenceUntouched() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.series[Triple(source, day, "steps_est")] =
            MetricSeriesRow(source, day, "steps_est", 4_000.0)
        f.failEstimateDelete = true

        val failure = runCatching {
            f.repo.reconcileComputedStepEvidence(
                deviceIds = listOf(source),
                deleteEstimateDays = listOf(day),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(4_000, f.daily[source to day]?.steps)
        assertEquals(4_000.0, f.series[Triple(source, day, "steps_est")]?.value)
        assertEquals(0L, f.repo.metricDataVersion.value)
        assertEquals(0L, f.repo.restDataVersion.value)
    }

    @Test
    fun stationaryLegacyRepairClearsOnlyExactComputedValue() = runBlocking {
        val f = fixture()
        val matching = "active-band-noop"
        val equalOtherComputed = "other-band-noop"
        val mismatching = "old-band-noop"
        val imported = "health-connect"
        val day = "2026-09-24"
        f.daily[matching to day] = DailyMetric(
            deviceId = matching,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.daily[equalOtherComputed to day] = DailyMetric(
            deviceId = equalOtherComputed,
            day = day,
            recovery = 62.0,
            steps = 4_000,
        )
        f.daily[mismatching to day] = DailyMetric(
            deviceId = mismatching,
            day = day,
            recovery = 61.0,
            steps = 4_500,
        )
        f.daily[imported to day] = DailyMetric(
            deviceId = imported,
            day = day,
            recovery = 90.0,
            steps = 4_000,
        )
        f.series[Triple(matching, day, "steps_est")] =
            MetricSeriesRow(matching, day, "steps_est", 4_000.0)
        f.series[Triple(equalOtherComputed, day, "steps_est")] =
            MetricSeriesRow(equalOtherComputed, day, "steps_est", 4_000.0)
        f.series[Triple(mismatching, day, "steps_est")] =
            MetricSeriesRow(mismatching, day, "steps_est", 4_500.0)
        f.series[Triple(imported, day, "steps_est")] =
            MetricSeriesRow(imported, day, "steps_est", 4_000.0)

        assertEquals(
            2,
            f.repo.reconcileComputedStepEvidence(
                deviceIds = listOf(matching, equalOtherComputed, mismatching),
                deleteEstimateDays = emptyList(),
                clearMatchingComputedStepsBySource =
                    mapOf(matching to mapOf(day to 4_000)),
            ),
        )

        assertNull(f.daily[matching to day]?.steps)
        assertEquals(60.0, f.daily[matching to day]?.recovery)
        assertNull(f.series[Triple(matching, day, "steps_est")])
        assertEquals(4_000, f.daily[equalOtherComputed to day]?.steps)
        assertEquals(62.0, f.daily[equalOtherComputed to day]?.recovery)
        assertEquals(
            4_000.0,
            f.series[Triple(equalOtherComputed, day, "steps_est")]?.value,
        )
        assertEquals(4_500, f.daily[mismatching to day]?.steps)
        assertEquals(4_500.0, f.series[Triple(mismatching, day, "steps_est")]?.value)
        assertEquals(4_000, f.daily[imported to day]?.steps)
        assertEquals(4_000.0, f.series[Triple(imported, day, "steps_est")]?.value)
        assertEquals(1L, f.repo.metricDataVersion.value)
    }

    @Test
    fun computedDayClearRollsBackWhenEstimateDeleteFails() = runBlocking {
        val f = fixture()
        val source = "active-band-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.series[Triple(source, day, "steps_est")] =
            MetricSeriesRow(source, day, "steps_est", 4_000.0)
        f.failEstimateDelete = true

        val failure = runCatching {
            f.repo.reconcileComputedStepEvidence(
                deviceIds = listOf(source),
                deleteEstimateDays = emptyList(),
                clearComputedStepDays = listOf(day),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(4_000, f.daily[source to day]?.steps)
        assertEquals(4_000.0, f.series[Triple(source, day, "steps_est")]?.value)
        assertEquals(0L, f.repo.metricDataVersion.value)
    }

    @Test
    fun ambiguousScoreReplacementPreservesOnlyRequestedPriorSteps() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val firstDay = "2026-09-22"
        val secondDay = "2026-09-23"
        val staleDay = "2026-09-24"
        f.daily[source to firstDay] = DailyMetric(
            deviceId = source,
            day = firstDay,
            recovery = 50.0,
            steps = 4_000,
        )
        f.daily[source to secondDay] = DailyMetric(
            deviceId = source,
            day = secondDay,
            recovery = 51.0,
            steps = 3_000,
        )
        f.daily[source to staleDay] = DailyMetric(
            deviceId = source,
            day = staleDay,
            recovery = 52.0,
            steps = 2_000,
        )

        val receipt = f.repo.reconcileComputedScoreRange(
            deviceId = source,
            fromDay = firstDay,
            toDay = staleDay,
            dailyRows = listOf(
                DailyMetric(deviceId = source, day = firstDay, recovery = 80.0),
            ),
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
            preserveDailyStepDays = setOf(firstDay, secondDay),
        )

        assertEquals(setOf(firstDay, secondDay), receipt)
        assertEquals(80.0, f.daily[source to firstDay]?.recovery)
        assertEquals(4_000, f.daily[source to firstDay]?.steps)
        assertNull(f.daily[source to secondDay]?.recovery)
        assertEquals(3_000, f.daily[source to secondDay]?.steps)
        assertNull(f.daily[source to staleDay])
    }

    @Test
    fun stepOnlyScoreReplacementPreservesPriorDailyFields() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            totalSleepMin = 420.0,
            efficiency = 0.91,
            deepMin = 80.0,
            remMin = 100.0,
            lightMin = 240.0,
            disturbances = 2,
            restingHr = 54,
            avgHrv = 62.0,
            recovery = 71.0,
            strain = 8.0,
            exerciseCount = 1,
            spo2Pct = 97.0,
            skinTempDevC = 0.2,
            respRateBpm = 14.4,
            steps = 4_000,
            activeKcalEst = 560.0,
            spo2Red = 120,
            spo2Ir = 240,
            hrvMethod = "RMSSD",
        )

        val receipt = f.repo.reconcileComputedScoreRange(
            deviceId = source,
            fromDay = day,
            toDay = day,
            dailyRows = listOf(
                DailyMetric(
                    deviceId = source,
                    day = day,
                    strain = 9.5,
                    exerciseCount = 0,
                    steps = 1_715,
                )
            ),
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
            preserveDailyFieldsDays = setOf(day),
        )

        assertEquals(setOf(day), receipt)
        val saved = f.daily[source to day]
        assertEquals(420.0, saved?.totalSleepMin)
        assertEquals(0.91, saved?.efficiency)
        assertEquals(54, saved?.restingHr)
        assertEquals(62.0, saved?.avgHrv)
        assertEquals(71.0, saved?.recovery)
        assertEquals(9.5, saved?.strain)
        assertEquals(1, saved?.exerciseCount)
        assertEquals(97.0, saved?.spo2Pct)
        assertEquals(0.2, saved?.skinTempDevC)
        assertEquals(14.4, saved?.respRateBpm)
        assertEquals(1_715, saved?.steps)
        assertEquals(560.0, saved?.activeKcalEst)
        assertEquals(120, saved?.spo2Red)
        assertEquals(240, saved?.spo2Ir)
        assertEquals("RMSSD", saved?.hrvMethod)
        assertEquals(1L, f.repo.metricDataVersion.value)
        assertEquals(1L, f.repo.restDataVersion.value)
    }

    @Test
    fun scoreReplacementClearsComputedStepsAfterFieldPreservation() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val equalOtherComputed = "other-band-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.daily[equalOtherComputed to day] = DailyMetric(
            deviceId = equalOtherComputed,
            day = day,
            recovery = 62.0,
            steps = 4_000,
        )
        f.series[Triple(source, day, "steps_est")] =
            MetricSeriesRow(source, day, "steps_est", 4_000.0)
        f.series[Triple(equalOtherComputed, day, "steps_est")] =
            MetricSeriesRow(equalOtherComputed, day, "steps_est", 4_000.0)

        val receipt = f.repo.reconcileComputedScoreRange(
            deviceId = source,
            fromDay = day,
            toDay = day,
            dailyRows = listOf(
                DailyMetric(deviceId = source, day = day, recovery = 80.0),
            ),
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
            preserveDailyFieldsDays = setOf(day),
            stepEvidenceDeviceIds = listOf(source, equalOtherComputed),
            clearComputedStepDays = listOf(day),
        )

        assertEquals(setOf(day), receipt)
        assertEquals(80.0, f.daily[source to day]?.recovery)
        assertNull(f.daily[source to day]?.steps)
        assertNull(f.series[Triple(source, day, "steps_est")])
        assertNull(f.daily[equalOtherComputed to day]?.steps)
        assertEquals(62.0, f.daily[equalOtherComputed to day]?.recovery)
        assertNull(f.series[Triple(equalOtherComputed, day, "steps_est")])
    }

    @Test
    fun scoreStepCleanupRejectsImportedPrimaryTargetBeforeMutation() = runBlocking {
        val f = fixture()
        val imported = "health-connect"
        val computed = "whoop-ABC123-noop"
        val day = "2026-09-24"
        f.daily[imported to day] = DailyMetric(
            deviceId = imported,
            day = day,
            recovery = 90.0,
            steps = 8_000,
        )
        f.daily[computed to day] = DailyMetric(
            deviceId = computed,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )

        val failure = runCatching {
            f.repo.reconcileComputedScoreRange(
                deviceId = imported,
                fromDay = day,
                toDay = day,
                dailyRows = listOf(
                    DailyMetric(deviceId = imported, day = day, recovery = 50.0),
                ),
                managedRestKeys = setOf("sleep_performance"),
                restRows = emptyList(),
                stepEvidenceDeviceIds = listOf(computed),
                clearComputedStepDays = listOf(day),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertEquals(90.0, f.daily[imported to day]?.recovery)
        assertEquals(8_000, f.daily[imported to day]?.steps)
        assertEquals(60.0, f.daily[computed to day]?.recovery)
        assertEquals(4_000, f.daily[computed to day]?.steps)
        assertEquals(0L, f.repo.metricDataVersion.value)
        assertEquals(0L, f.repo.restDataVersion.value)
    }

    @Test
    fun skippedCounterDayPreservesCompletePriorRowWithoutFreshScore() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            totalSleepMin = 420.0,
            recovery = 71.0,
            strain = 8.0,
            exerciseCount = 2,
            steps = 4_000,
            activeKcalEst = 510.0,
            spo2Pct = 97.0,
            skinTempDevC = 0.2,
            respRateBpm = 14.1,
        )

        val receipt = f.repo.reconcileComputedScoreRange(
            deviceId = source,
            fromDay = day,
            toDay = day,
            dailyRows = emptyList(),
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
            allowEmptyReplacement = true,
            preserveDailyFieldsDays = setOf(day),
        )

        assertEquals(setOf(day), receipt)
        val saved = f.daily[source to day]
        assertEquals(420.0, saved?.totalSleepMin)
        assertEquals(71.0, saved?.recovery)
        assertEquals(8.0, saved?.strain)
        assertEquals(2, saved?.exerciseCount)
        assertEquals(4_000, saved?.steps)
        assertEquals(510.0, saved?.activeKcalEst)
        assertEquals(97.0, saved?.spo2Pct)
        assertEquals(0.2, saved?.skinTempDevC)
        assertEquals(14.1, saved?.respRateBpm)
    }

    @Test
    fun scoreAndStepRepairRollbackTogetherOnEstimateFailure() = runBlocking {
        val f = fixture()
        val source = "whoop-ABC123-noop"
        val day = "2026-09-24"
        f.daily[source to day] = DailyMetric(
            deviceId = source,
            day = day,
            recovery = 60.0,
            steps = 4_000,
        )
        f.series[Triple(source, day, "steps_est")] =
            MetricSeriesRow(source, day, "steps_est", 4_000.0)
        f.failEstimateDelete = true

        val failure = runCatching {
            f.repo.reconcileComputedScoreRange(
                deviceId = source,
                fromDay = day,
                toDay = day,
                dailyRows = listOf(
                    DailyMetric(deviceId = source, day = day, recovery = 80.0)
                ),
                managedRestKeys = setOf("sleep_performance"),
                restRows = emptyList(),
                stepEvidenceDeviceIds = listOf(source),
                deleteEstimateDays = setOf(day),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(60.0, f.daily[source to day]?.recovery)
        assertEquals(4_000, f.daily[source to day]?.steps)
        assertEquals(4_000.0, f.series[Triple(source, day, "steps_est")]?.value)
        assertEquals(0L, f.repo.metricDataVersion.value)
        assertEquals(0L, f.repo.restDataVersion.value)
    }

    @Test
    fun scoreRepairDeletesEstimateFromHistoricalDayOwnerNamespace() = runBlocking {
        val f = fixture()
        val activeComputed = "active-band-noop"
        val historicalComputed = "old-band-noop"
        val day = "2026-09-24"
        f.daily[activeComputed to day] = DailyMetric(
            deviceId = activeComputed,
            day = day,
            recovery = 60.0,
        )
        f.series[Triple(activeComputed, day, "steps_est")] =
            MetricSeriesRow(activeComputed, day, "steps_est", 4_000.0)
        f.series[Triple(historicalComputed, day, "steps_est")] =
            MetricSeriesRow(historicalComputed, day, "steps_est", 4_000.0)

        f.repo.reconcileComputedScoreRange(
            deviceId = activeComputed,
            fromDay = day,
            toDay = day,
            dailyRows = listOf(
                DailyMetric(deviceId = activeComputed, day = day, recovery = 80.0, steps = 1_715)
            ),
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
            stepEvidenceDeviceIds = listOf(activeComputed, historicalComputed),
            deleteEstimateDays = setOf(day),
        )

        assertNull(f.series[Triple(activeComputed, day, "steps_est")])
        assertNull(f.series[Triple(historicalComputed, day, "steps_est")])
        assertEquals(1_715, f.daily[activeComputed to day]?.steps)
    }

    @Test
    fun stepEvidenceMutationChunksLargeDaySets() = runBlocking {
        val f = fixture()
        val start = LocalDate.parse("2022-01-01")
        val days = (0 until 1_201).map { start.plusDays(it.toLong()).toString() }

        f.repo.reconcileComputedStepEvidence(
            deviceIds = listOf("whoop-ABC123-noop"),
            deleteEstimateDays = days,
        )

        assertEquals(listOf(500, 500, 201), f.deleteChunkSizes)
    }

    @Test
    fun daySliceReusesCoveredUnsaturatedWindow() {
        val result = IntelligenceEngine.daySliceFromWindow(
            samples = listOf(90L, 100L, 150L, 200L, 210L),
            windowFrom = 90,
            windowTo = 210,
            dayFrom = 100,
            dayTo = 200,
            limit = 100,
            timestamp = { it },
        )

        assertEquals(listOf(100L, 150L, 200L), result)
    }

    @Test
    fun daySliceRejectsIncompleteOrLimitSaturatedWindow() {
        assertNull(
            IntelligenceEngine.daySliceFromWindow(
                samples = listOf(100L, 150L),
                windowFrom = 110,
                windowTo = 200,
                dayFrom = 100,
                dayTo = 200,
                limit = 100,
                timestamp = { it },
            )
        )
        assertNull(
            IntelligenceEngine.daySliceFromWindow(
                samples = listOf(100L, 150L),
                windowFrom = 100,
                windowTo = 200,
                dayFrom = 100,
                dayTo = 200,
                limit = 2,
                timestamp = { it },
            )
        )
    }

    @Test
    fun observedUnverifiedCounterDaysArePassedToScoreReplacement() {
        val sourceFile = listOf(
            File("src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
            File("app/src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
            File("android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
        ).firstOrNull(File::isFile)
        requireNotNull(sourceFile) { "IntelligenceEngine.kt source root is unavailable" }
        val source = sourceFile.readText()
        val observedSet = source.indexOf("val stepCounterObservedDays")
        val ownerSet = source.indexOf("val stepCounterOwnerIds")
        val counterRead = source.indexOf("val dayStepAnalysis = StepsCounter.analyze(", observedSet)
        val observedMark = source.indexOf("stepCounterObservedDays.add(day)", counterRead)
        val computedSources = source.indexOf("val computedStepSourceIds", observedMark)
        val reconciliation = source.indexOf("repo.reconcileComputedScoreRange(", computedSources)
        val standaloneRepair =
            source.indexOf("if (!shouldReconcileScoreRange &&", reconciliation)

        assertTrue("observed counter-day tracking must exist", observedSet >= 0)
        assertTrue("counter owner tracking must exist", ownerSet >= 0)
        assertTrue("production counter analysis must follow tracking setup", counterRead > observedSet)
        assertTrue("every observed row day must be marked for cleanup", observedMark > counterRead)
        assertTrue("computed source expansion must follow observed-day marking", computedSources > observedMark)
        assertTrue("score replacement must follow counter-day derivation", reconciliation > computedSources)
        assertTrue("standalone repair guard must follow score replacement", standaloneRepair > reconciliation)
        assertTrue(
            source.substring(counterRead, observedMark).contains(
                "ClassificationPolicy.rejectUnverifiedBandCounter"
            )
        )
        assertTrue(source.contains("val alternateSources = ("))
        assertTrue(source.contains("repo.stepSamples(source, dayMidnight, dayEnd, 1)"))
        assertTrue(
            source.substring(computedSources, reconciliation).contains(
                ".plus(stepCounterOwnerIds.map"
            )
        )
        val combinedTransaction = source.substring(reconciliation, standaloneRepair)
        assertTrue(!combinedTransaction.contains("preserveDailyStepDays ="))
        assertTrue(
            combinedTransaction.contains("preserveDailyFieldsDays = preserveDailyFieldsDays")
        )
        assertTrue(
            combinedTransaction.contains("clearComputedStepDays = stepCounterObservedDays")
        )
    }

    @Test
    fun counterIntegrityRepairRunsBeforeHistoricalProjectionGuard() {
        val sourceFile = listOf(
            File("src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
            File("app/src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
            File("android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
        ).firstOrNull(File::isFile)
        requireNotNull(sourceFile) { "IntelligenceEngine.kt source root is unavailable" }
        val source = sourceFile.readText()
        val repair = source.indexOf("val computedStepSourceIds")
        val historicalGuard = source.indexOf("if (!historicalCatchUp)", repair)

        assertTrue("counter repair must exist", repair >= 0)
        assertTrue(
            "historical catch-up must repair stale step evidence before skipping current projections",
            historicalGuard > repair,
        )
        assertTrue(
            source.substring(repair, historicalGuard).contains(
                "repo.reconcileComputedStepEvidence("
            )
        )
        assertTrue(
            source.substring(repair, historicalGuard).contains(
                "if (!shouldReconcileScoreRange &&"
            )
        )
        assertTrue(
            source.substring(repair, historicalGuard).contains(
                "clearComputedStepDays = stepCounterObservedDays"
            )
        )
    }
}
