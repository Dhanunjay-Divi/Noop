package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class ManualWorkoutRescoreIntegrityTest {
    @Test
    fun workoutReadFailurePropagatesOutOfRealRepositoryPath() = runBlocking {
        val expected = IllegalStateException("workout read failed")
        val repository = repository { method ->
            when (method) {
                "workouts" -> throw expected
                else -> unsupported(method)
            }
        }

        try {
            IntelligenceEngine.rescoreManualWorkouts(
                repository,
                UserProfile(),
                "band-a",
                null,
                2_000_000L,
            )
            fail("expected workout read failure")
        } catch (actual: IllegalStateException) {
            assertSame(expected, actual)
        }
    }

    @Test
    fun hrReadFailurePropagatesOutOfRealRepositoryPath() = runBlocking {
        val expected = IllegalStateException("HR read failed")
        val row = WorkoutRow(
            deviceId = "band-a",
            startTs = 1_999_000L,
            endTs = 1_999_600L,
            sport = "workout",
            source = "manual",
            energyKcal = 0.0,
        )
        val repository = repository { method ->
            when (method) {
                "workouts" -> listOf(row)
                "hrSamples" -> throw expected
                else -> unsupported(method)
            }
        }

        try {
            IntelligenceEngine.rescoreManualWorkouts(
                repository,
                UserProfile(),
                "band-a",
                null,
                2_000_000L,
            )
            fail("expected HR read failure")
        } catch (actual: IllegalStateException) {
            assertSame(expected, actual)
        }
    }

    private fun repository(result: (String) -> Any?): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ -> result(method.name) } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun unsupported(method: String): Nothing =
        throw UnsupportedOperationException("unexpected DAO call $method")
}
