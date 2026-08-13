package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden behaviour vectors shared with StressOnsetDetectorTests.swift: four distinct trusted windows,
 * credibility-before-learning, replay/spacing safety, exact-mean warm-up, and fail-closed motion/session
 * gates. See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
class StressOnsetDetectorTest {

    private val on = StressOnsetDetector.Config(enabled = true, autoNudge = true)

    private fun flat(rrMs: Int, n: Int): List<Int> = List(n) { rrMs }

    /** Alternating ±[jitter] around [rrMs] → RMSSD ≈ 2*jitter. */
    private fun jittered(rrMs: Int, jitter: Int, n: Int): List<Int> =
        (0 until n).map { rrMs + if (it % 2 == 0) jitter else -jitter }

    /** Four physiologically-equivalent but fingerprint-distinct resting windows, one minute apart. */
    private fun warmedBaseline(startSec: Long = 10_000L): StressOnsetDetector.Decision {
        var state = StressOnsetDetector.State.INITIAL
        lateinit var decision: StressOnsetDetector.Decision
        repeat(StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS) { index ->
            decision = StressOnsetDetector.evaluate(
                rrBuffer = jittered(900 + index, 60, 60),
                currentHR = 70.0,
                recentMotionG = 0.0,
                sessionActive = false,
                state = state,
                config = on,
                nowSec = startSec + index * 60L,
                tzOffsetSec = 0L,
            )
            assertFalse(decision.shouldNudge)
            assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
            assertEquals(index + 1, decision.nextState.trustedWindowCount)
            state = decision.nextState
        }
        return decision
    }

    @Test fun fires_once_on_fresh_dip_then_not_again() {
        var decision = warmedBaseline()
        assertNotNull(decision.baselineRMSSD)

        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(910, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 10_240L, tzOffsetSec = 0L,
        )
        assertTrue(decision.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.ONSET, decision.reason)

        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(911, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 10_300L, tzOffsetSec = 0L,
        )
        assertFalse(decision.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.NOT_AN_EDGE, decision.reason)
    }

    @Test fun requires_four_distinct_trusted_windows_before_auto_fire() {
        assertTrue(StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS >= 4)
        var decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = StressOnsetDetector.State.INITIAL, config = on,
            nowSec = 0L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
        assertEquals(1, decision.nextState.trustedWindowCount)

        val firstBaseline = decision.nextState.baselineRMSSD
        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 60L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.DUPLICATE_WINDOW, decision.reason)
        assertEquals(1, decision.nextState.trustedWindowCount)
        assertEquals(firstBaseline, decision.nextState.baselineRMSSD, 0.0)

        for (index in 1 until StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS) {
            decision = StressOnsetDetector.evaluate(
                rrBuffer = jittered(900 + index, 60, 60), currentHR = 70.0,
                recentMotionG = 0.0, sessionActive = false, state = decision.nextState,
                config = on, nowSec = 60L + index * 60L, tzOffsetSec = 0L,
            )
            assertFalse(decision.shouldNudge)
            assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
        }
        assertEquals(
            StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS,
            decision.nextState.trustedWindowCount,
        )

        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(910, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 360L, tzOffsetSec = 0L,
        )
        assertTrue(decision.shouldNudge)
    }

    @Test fun legacy_state_defaults_to_safe_warmup() {
        val legacy = StressOnsetDetector.State(baselineRMSSD = 72.0, wasBelow = false, lastFireAt = 0L)
        assertEquals(0, legacy.trustedWindowCount)
        assertEquals(0L, legacy.lastTrustedWindowFingerprint)
        assertEquals(0L, legacy.lastTrustedWindowAt)

        val decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = legacy, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertFalse(decision.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
        assertEquals(decision.fastRMSSD!!, decision.nextState.baselineRMSSD, 0.000_001)
    }

    @Test fun outlier_first_warmup_uses_mean_then_normal_window_cannot_fire() {
        val warmupWindows = listOf(
            jittered(1_100, 100, 60),
            jittered(901, 30, 60),
            jittered(902, 30, 60),
            jittered(903, 30, 60),
        )
        var state = StressOnsetDetector.State.INITIAL
        val observed = ArrayList<Double>()

        warmupWindows.forEachIndexed { index, window ->
            val decision = StressOnsetDetector.evaluate(
                rrBuffer = window, currentHR = 70.0, recentMotionG = 0.0,
                sessionActive = false, state = state, config = on,
                nowSec = index * 60L, tzOffsetSec = 0L,
            )
            observed += decision.fastRMSSD!!
            assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
            assertEquals(observed.average(), decision.nextState.baselineRMSSD, 0.000_001)
            state = decision.nextState
        }

        val baselineAfterWarmup = state.baselineRMSSD
        val nextNormal = StressOnsetDetector.evaluate(
            rrBuffer = jittered(904, 30, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = state, config = on, nowSec = 240L, tzOffsetSec = 0L,
        )
        val nextFast = nextNormal.fastRMSSD!!
        val expectedEma = baselineAfterWarmup * StressOnsetDetector.BASELINE_EMA_ALPHA +
            nextFast * (1.0 - StressOnsetDetector.BASELINE_EMA_ALPHA)
        assertFalse(nextNormal.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.NO_DIP, nextNormal.reason)
        assertEquals(expectedEma, nextNormal.nextState.baselineRMSSD, 0.000_001)
        assertTrue(nextFast >= nextNormal.nextState.baselineRMSSD * StressOnsetDetector.DROP_RATIO)
    }

    @Test fun rapid_overlapping_windows_do_not_counterfeit_warmup() {
        var decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = StressOnsetDetector.State.INITIAL, config = on,
            nowSec = 10_000L, tzOffsetSec = 0L,
        )
        assertEquals(1, decision.nextState.trustedWindowCount)

        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(901, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 10_010L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.DUPLICATE_WINDOW, decision.reason)
        assertEquals(1, decision.nextState.trustedWindowCount)

        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(902, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 10_060L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.WARMING_UP, decision.reason)
        assertEquals(2, decision.nextState.trustedWindowCount)
    }

    @Test fun missing_motion_suppresses_and_cannot_train_baseline() {
        val initial = StressOnsetDetector.State.INITIAL
        val noMotion = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 60, 60), currentHR = 70.0, recentMotionG = null,
            sessionActive = false, state = initial, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.MOTION_UNAVAILABLE, noMotion.reason)
        assertEquals(initial, noMotion.nextState)

        val warmed = warmedBaseline(startSec = 0L)
        val dip = StressOnsetDetector.evaluate(
            rrBuffer = jittered(910, 5, 60), currentHR = 70.0, recentMotionG = null,
            sessionActive = false, state = warmed.nextState, config = on,
            nowSec = 240L, tzOffsetSec = 0L,
        )
        assertFalse(dip.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.MOTION_UNAVAILABLE, dip.reason)
        assertEquals(warmed.nextState, dip.nextState)
    }

    @Test fun movement_or_exercise_cannot_train_baseline() {
        val initial = StressOnsetDetector.State.INITIAL
        val moving = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 60, 60), currentHR = 70.0, recentMotionG = 0.5,
            sessionActive = false, state = initial, config = on, nowSec = 60L, tzOffsetSec = 0L,
        )
        val exercising = StressOnsetDetector.evaluate(
            rrBuffer = jittered(901, 60, 60), currentHR = 140.0, recentMotionG = 0.0,
            sessionActive = false, state = initial, config = on, nowSec = 120L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.EXERCISE_GATED, moving.reason)
        assertEquals(StressOnsetDetector.Reason.EXERCISE_GATED, exercising.reason)
        assertEquals(initial, moving.nextState)
        assertEquals(initial, exercising.nextState)
    }

    @Test fun replay_safe_cannot_refire() {
        val low = jittered(910, 5, 60)
        var decision = warmedBaseline(startSec = 0L)
        decision = StressOnsetDetector.evaluate(
            rrBuffer = low, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = decision.nextState, config = on, nowSec = 240L, tzOffsetSec = 0L,
        )
        assertTrue(decision.shouldNudge)

        val replay = StressOnsetDetector.evaluate(
            rrBuffer = low, currentHR = 70.0, recentMotionG = 0.0, sessionActive = false,
            state = decision.nextState, config = on, nowSec = 241L, tzOffsetSec = 0L,
        )
        assertFalse(replay.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.DUPLICATE_WINDOW, replay.reason)
    }

    @Test fun rate_limit_blocks_second_fire_within_window() {
        var decision = warmedBaseline(startSec = 0L)
        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(910, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 240L, tzOffsetSec = 0L,
        )
        assertTrue(decision.shouldNudge)
        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(920, 60, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 300L, tzOffsetSec = 0L,
        )
        decision = StressOnsetDetector.evaluate(
            rrBuffer = jittered(911, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = decision.nextState, config = on,
            nowSec = 540L, tzOffsetSec = 0L,
        )
        assertFalse(decision.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.SUPPRESSED, decision.reason)
    }

    @Test fun disabled_and_active_session_leave_state_untouched() {
        val off = StressOnsetDetector.Config(enabled = false, autoNudge = true)
        val disabled = StressOnsetDetector.evaluate(
            rrBuffer = jittered(900, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = StressOnsetDetector.State.INITIAL, config = off,
            nowSec = 0L, tzOffsetSec = 0L,
        )
        assertEquals(StressOnsetDetector.Reason.DISABLED, disabled.reason)
        assertEquals(StressOnsetDetector.State.INITIAL, disabled.nextState)

        val warmed = warmedBaseline(startSec = 0L)
        val active = StressOnsetDetector.evaluate(
            rrBuffer = jittered(910, 5, 60), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = true, state = warmed.nextState, config = on,
            nowSec = 240L, tzOffsetSec = 0L,
        )
        assertFalse(active.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.SUPPRESSED, active.reason)
        assertEquals(warmed.nextState, active.nextState)
    }

    @Test fun insufficient_data_never_invents_signal() {
        val decision = StressOnsetDetector.evaluate(
            rrBuffer = flat(900, 5), currentHR = 70.0, recentMotionG = 0.0,
            sessionActive = false, state = StressOnsetDetector.State.INITIAL, config = on,
            nowSec = 0L, tzOffsetSec = 0L,
        )
        assertFalse(decision.shouldNudge)
        assertEquals(StressOnsetDetector.Reason.INSUFFICIENT_DATA, decision.reason)
    }

    @Test fun motion_evidence_requires_dense_current_rows() {
        fun gravity(ts: Long, x: Double = 0.0) = GravitySample("strap", ts, x, 0.0, 1.0)
        val now = 10_000L
        val still = (now - 10L..now).map { gravity(it) }
        assertEquals(0.0, StressMotionEvidence.recentIntensityG(still, now)!!, 0.0)

        val moving = (now - 10L..now).mapIndexed { index, ts ->
            gravity(ts, if (index % 2 == 0) 0.0 else 0.5)
        }
        assertTrue(StressMotionEvidence.recentIntensityG(moving, now)!! > StressOnsetDetector.MOTION_GATE_G)

        val stale = (now - 200L..now - 190L).map { gravity(it) }
        assertNull(StressMotionEvidence.recentIntensityG(stale, now))
        assertNull(StressMotionEvidence.recentIntensityG(listOf(gravity(now)), now))
        assertNull(StressMotionEvidence.recentIntensityG(still, now - 1L))
    }
}
