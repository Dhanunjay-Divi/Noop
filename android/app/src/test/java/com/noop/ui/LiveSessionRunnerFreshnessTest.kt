package com.noop.ui

import com.noop.analytics.LiveSessionEngine
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression coverage for the BLE-state -> 1 Hz Live Session freshness seam. */
@OptIn(ExperimentalCoroutinesApi::class)
class LiveSessionRunnerFreshnessTest {

    private val baseEpochSec = 1_700_000_000L

    private fun TestScope.runner(
        readHeartRate: () -> LiveSessionRunner.HeartRateSample,
        realtimeTransitions: MutableList<Boolean> = mutableListOf(),
    ) = LiveSessionRunner(
        config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
        deviceId = "my-whoop",
        scope = this,
        readHeartRate = readHeartRate,
        buzz = {},
        persist = {},
        realtimeHr = { realtimeTransitions += it },
        nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
    )

    @Test
    fun silentTransport_doesNotConsumeCachedPreSessionHeartRate() = runTest {
        val cached = LiveSessionRunner.HeartRateSample(bpm = 140, sequence = 7L)
        val runner = runner(readHeartRate = { cached })

        runner.start()
        runCurrent()

        val output = runner.snapshot.value.output
        assertEquals(LiveSessionEngine.Status.STALE, output?.status)
        assertFalse(output?.sampleArrived ?: true)

        runner.end()
        runCurrent()
    }

    @Test
    fun stoppedTransport_repeatedCachedHeartRateGoesStaleAndStopsAccruing() = runTest {
        var sample = LiveSessionRunner.HeartRateSample(bpm = null, sequence = 0L)
        val runner = runner(readHeartRate = { sample })
        runner.start()
        runCurrent()

        sample = LiveSessionRunner.HeartRateSample(bpm = 140, sequence = 1L)
        advanceTimeBy(1_000L)
        runCurrent()
        val accruedAfterFreshPacket = runner.snapshot.value.output?.inBandSeconds ?: 0.0

        // Transport stopped: the public live state still holds 140, but its packet sequence no longer moves.
        advanceTimeBy(10_000L)
        runCurrent()

        val output = runner.snapshot.value.output
        assertEquals(LiveSessionEngine.Status.STALE, output?.status)
        assertFalse(output?.sampleArrived ?: true)
        assertTrue((output?.inBandSeconds ?: 0.0) <= accruedAfterFreshPacket + 8.0)

        runner.end()
        runCurrent()
    }

    @Test
    fun backgroundPause_onlyRecoversAfterANewPacketSequence() = runTest {
        var sample = LiveSessionRunner.HeartRateSample(bpm = null, sequence = 0L)
        val runner = runner(readHeartRate = { sample })
        runner.start()
        runCurrent()

        sample = LiveSessionRunner.HeartRateSample(bpm = 140, sequence = 1L)
        advanceTimeBy(1_000L)
        runCurrent()
        advanceTimeBy(10_000L)
        runCurrent()
        assertEquals(LiveSessionEngine.Status.STALE, runner.snapshot.value.output?.status)

        // Foreground/re-arm without a packet is still stale; only a genuine new BLE event resumes coaching.
        advanceTimeBy(1_000L)
        runCurrent()
        assertEquals(LiveSessionEngine.Status.STALE, runner.snapshot.value.output?.status)

        sample = LiveSessionRunner.HeartRateSample(bpm = 140, sequence = 2L)
        advanceTimeBy(1_000L)
        runCurrent()
        val resumed = runner.snapshot.value.output
        assertTrue(resumed?.status != LiveSessionEngine.Status.STALE)
        assertTrue(resumed?.sampleArrived == true)

        runner.end()
        runCurrent()
    }

    @Test
    fun backgroundTransportThatNeverReturnsAutoEndsAndReleasesLease() = runTest {
        val transitions = mutableListOf<Boolean>()
        val runner = runner(
            readHeartRate = { LiveSessionRunner.HeartRateSample(bpm = 140, sequence = 7L) },
            realtimeTransitions = transitions,
        )
        runner.start()
        runCurrent()

        advanceTimeBy(LiveSessionRunner.AUTO_END_AFTER_STALE_SEC * 1_000L)
        runCurrent()

        assertTrue(runner.snapshot.value.ended)
        assertTrue(runner.snapshot.value.endedAutomatically)
        assertEquals(listOf(true, false), transitions)
    }

    @Test
    fun sustainedVeryHighTraceUsesDistinctCueAndPhoneCompanionOnce() = runTest {
        var sequence = 0L
        val buzzes = mutableListOf<Int>()
        var phonePrompts = 0
        val runner = LiveSessionRunner(
            config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
            deviceId = "my-whoop",
            scope = this,
            readHeartRate = {
                LiveSessionRunner.HeartRateSample(bpm = 185, sequence = sequence)
            },
            buzz = { buzzes += it },
            persist = {},
            realtimeHr = {},
            workoutGuidanceEnabled = { true },
            workoutGuidanceSignalTrusted = { true },
            workoutGuidanceHapticsEnabled = { true },
            pauseAndAssess = { phonePrompts += 1 },
            nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
        )
        runner.start()
        runCurrent()

        repeat(70) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }

        assertEquals(1, phonePrompts)
        assertTrue(5 in buzzes)
        runner.end()
        runCurrent()
    }

    @Test
    fun disabledWorkoutGuidanceNeverAddsStrongCueOrPhonePrompt() = runTest {
        var sequence = 0L
        val buzzes = mutableListOf<Int>()
        var phonePrompts = 0
        val runner = LiveSessionRunner(
            config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
            deviceId = "my-whoop",
            scope = this,
            readHeartRate = {
                LiveSessionRunner.HeartRateSample(bpm = 185, sequence = sequence)
            },
            buzz = { buzzes += it },
            persist = {},
            realtimeHr = {},
            workoutGuidanceEnabled = { false },
            pauseAndAssess = { phonePrompts += 1 },
            nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
        )
        runner.start()
        runCurrent()

        repeat(70) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }

        assertEquals(0, phonePrompts)
        assertFalse(5 in buzzes)
        runner.end()
        runCurrent()
    }

    @Test
    fun mutedWristGuidanceKeepsPhoneCompanionWithoutStrongBandCue() = runTest {
        var sequence = 0L
        val buzzes = mutableListOf<Int>()
        var phonePrompts = 0
        val runner = LiveSessionRunner(
            config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
            deviceId = "my-whoop",
            scope = this,
            readHeartRate = {
                LiveSessionRunner.HeartRateSample(bpm = 185, sequence = sequence)
            },
            buzz = { buzzes += it },
            persist = {},
            realtimeHr = {},
            workoutGuidanceEnabled = { true },
            workoutGuidanceSignalTrusted = { true },
            workoutGuidanceHapticsEnabled = { false },
            pauseAndAssess = { phonePrompts += 1 },
            nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
        )
        runner.start()
        runCurrent()

        repeat(70) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }

        assertEquals(1, phonePrompts)
        assertFalse(5 in buzzes)
        runner.end()
        runCurrent()
    }

    @Test
    fun offWristTimeCannotAccrueTowardWorkoutGuidance() = runTest {
        var sequence = 0L
        var trusted = false
        val buzzes = mutableListOf<Int>()
        var phonePrompts = 0
        val runner = LiveSessionRunner(
            config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
            deviceId = "my-whoop",
            scope = this,
            readHeartRate = {
                LiveSessionRunner.HeartRateSample(bpm = 185, sequence = sequence)
            },
            buzz = { buzzes += it },
            persist = {},
            realtimeHr = {},
            workoutGuidanceEnabled = { true },
            workoutGuidanceSignalTrusted = { trusted },
            workoutGuidanceHapticsEnabled = { true },
            pauseAndAssess = { phonePrompts += 1 },
            nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
        )
        runner.start()
        runCurrent()

        repeat(120) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }
        trusted = true
        repeat(50) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }

        assertEquals(0, phonePrompts)
        assertFalse(5 in buzzes)

        repeat(20) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }
        assertEquals(1, phonePrompts)
        assertTrue(5 in buzzes)
        runner.end()
        runCurrent()
    }

    @Test
    fun disablingThenReenablingStartsAWholeNewWarningWindow() = runTest {
        var sequence = 0L
        var enabled = true
        val buzzes = mutableListOf<Int>()
        var phonePrompts = 0
        val runner = LiveSessionRunner(
            config = LiveSessionEngine.Config(restingHR = 60.0, hrMax = 190.0, charge = 50.0),
            deviceId = "my-whoop",
            scope = this,
            readHeartRate = {
                LiveSessionRunner.HeartRateSample(bpm = 185, sequence = sequence)
            },
            buzz = { buzzes += it },
            persist = {},
            realtimeHr = {},
            workoutGuidanceEnabled = { enabled },
            workoutGuidanceSignalTrusted = { true },
            workoutGuidanceHapticsEnabled = { true },
            pauseAndAssess = { phonePrompts += 1 },
            nowEpochSec = { baseEpochSec + testScheduler.currentTime / 1_000L },
        )
        runner.start()
        runCurrent()

        repeat(55) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }
        enabled = false
        sequence += 1
        advanceTimeBy(1_000L)
        runCurrent()
        enabled = true
        repeat(55) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }

        assertEquals(0, phonePrompts)
        assertFalse(5 in buzzes)

        repeat(15) {
            sequence += 1
            advanceTimeBy(1_000L)
            runCurrent()
        }
        assertEquals(1, phonePrompts)
        assertTrue(5 in buzzes)
        runner.end()
        runCurrent()
    }
}
