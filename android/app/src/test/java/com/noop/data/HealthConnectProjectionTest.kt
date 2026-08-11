package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HealthConnectProjectionTest {
    private val source = WhoopRepository.HEALTH_CONNECT_SOURCE

    @Test
    fun partialPermissionRefreshesOwnedColumnAndPreservesOthers() {
        val old = AppleDaily(source, "2026-08-10", steps = 100, activeKcal = 450.0, weightKg = 80.0)
        val fresh = AppleDaily(source, old.day, steps = 125)

        val merged = HealthConnectProjectionMerge.appleDaily(
            source,
            existing = listOf(old),
            incoming = listOf(fresh),
            scope = HealthConnectProjectionScope(steps = true),
        ).single()

        assertEquals(125, merged.steps)
        assertEquals(450.0, merged.activeKcal!!, 0.0)
        assertEquals(80.0, merged.weightKg!!, 0.0)
    }

    @Test
    fun deletedOwnedValueClearsWithoutClearingUngrantedValue() {
        val old = DailyMetric(
            source,
            "2026-08-10",
            restingHr = 52,
            avgHrv = 61.0,
            spo2Pct = 97.0,
        )
        val merged = HealthConnectProjectionMerge.dailyMetrics(
            source,
            existing = listOf(old),
            incoming = emptyList(),
            scope = HealthConnectProjectionScope(hrv = true),
        ).single()

        assertNull(merged.avgHrv)
        assertEquals(52, merged.restingHr)
        assertEquals(97.0, merged.spo2Pct!!, 0.0)
    }

    @Test
    fun exerciseReplacementPreservesUnavailableEnrichment() {
        val old = WorkoutRow(
            source, 100, 200, "Run", source,
            energyKcal = 300.0, avgHr = 150, maxHr = 175, distanceM = 5_000.0,
        )
        val fresh = WorkoutRow(source, 100, 220, "Run", source, durationS = 120.0)
        val merged = HealthConnectProjectionMerge.workouts(
            existing = listOf(old),
            incoming = listOf(fresh),
            // Total calories without Active Calories must not claim/clear workout energy.
            scope = HealthConnectProjectionScope(exercise = true, totalCalories = true),
        ).single()

        assertEquals(300.0, merged.energyKcal!!, 0.0)
        assertEquals(150, merged.avgHr)
        assertEquals(175, merged.maxHr)
        assertEquals(5_000.0, merged.distanceM!!, 0.0)
        assertEquals(220, merged.endTs)
    }

    @Test
    fun additiveManualImportNeverNullsSparseAggregateColumns() {
        val oldApple = AppleDaily(source, "2026-08-10", steps = 100, activeKcal = 400.0, weightKg = 80.0)
        val freshApple = AppleDaily(source, oldApple.day, steps = 125)
        val mergedApple = HealthConnectProjectionMerge.appleDailyAdditive(
            listOf(oldApple),
            listOf(freshApple),
        ).single()
        assertEquals(125, mergedApple.steps)
        assertEquals(400.0, mergedApple.activeKcal!!, 0.0)
        assertEquals(80.0, mergedApple.weightKg!!, 0.0)

        val oldDaily = DailyMetric(source, oldApple.day, restingHr = 52, avgHrv = 61.0, spo2Pct = 97.0)
        val freshDaily = DailyMetric(source, oldApple.day, restingHr = 50)
        val mergedDaily = HealthConnectProjectionMerge.dailyMetricsAdditive(
            listOf(oldDaily),
            listOf(freshDaily),
        ).single()
        assertEquals(50, mergedDaily.restingHr)
        assertEquals(61.0, mergedDaily.avgHrv!!, 0.0)
        assertEquals(97.0, mergedDaily.spo2Pct!!, 0.0)
    }

    @Test
    fun additiveManualWorkoutPreservesMissingEnrichment() {
        val old = WorkoutRow(
            source, 100, 200, "Run", source,
            durationS = 100.0,
            energyKcal = 300.0,
            avgHr = 150,
            maxHr = 175,
            distanceM = 5_000.0,
            notes = "Morning run",
        )
        val fresh = WorkoutRow(source, 100, 220, "Run", source, durationS = 120.0)
        val merged = HealthConnectProjectionMerge.workoutsAdditive(
            existing = listOf(old),
            incoming = listOf(fresh),
        ).single()

        assertEquals(120.0, merged.durationS!!, 0.0)
        assertEquals(300.0, merged.energyKcal!!, 0.0)
        assertEquals(150, merged.avgHr)
        assertEquals(175, merged.maxHr)
        assertEquals(5_000.0, merged.distanceM!!, 0.0)
        assertEquals("Morning run", merged.notes)
        assertEquals(220, merged.endTs)
    }
}
