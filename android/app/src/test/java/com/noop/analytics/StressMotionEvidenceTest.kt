package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StressMotionEvidenceTest {
    @Test
    fun denseMotionWindow_preservesObservationTimeAndSampleCount() {
        val nowSec = 10_000L
        val rows = (nowSec - 10L..nowSec).map {
            GravitySample("band", it, 0.0, 0.0, 1.0)
        }

        val evidence = StressMotionEvidence.derive(rows, nowSec)!!

        assertEquals(0.0, evidence.movementG, 0.0)
        assertEquals(nowSec * 1_000L, evidence.observedAtMillis)
        assertEquals(11, evidence.sampleCount)
    }

    @Test
    fun qualifiedMotion_requiresFreshOverlappingPhysiologyAndTrustedBandState() {
        val now = 10_000_000L
        val motion = TimestampedWristMotionEvidence(
            movementG = 0.01,
            observedAtMillis = now - 1_000L,
            sampleCount = 11,
        )
        fun qualify(
            rrAt: Long? = now - 1_000L,
            hrAt: Long? = now - 1_000L,
            observedMotion: TimestampedWristMotionEvidence? = motion,
            connected: Boolean = true,
            bonded: Boolean = true,
            encrypted: Boolean = true,
            worn: Boolean = true,
        ) = StressEvidencePolicy.qualifiedMotion(
            nowMillis = now,
            rrReceivedAtMillis = rrAt,
            heartRateReceivedAtMillis = hrAt,
            motion = observedMotion,
            connected = connected,
            bonded = bonded,
            encryptedBond = encrypted,
            worn = worn,
        )

        assertEquals(0.01, qualify()!!, 0.0)
        assertNull(qualify(rrAt = now - StressEvidencePolicy.MAXIMUM_PHYSIOLOGY_AGE_MILLIS - 1L))
        assertNull(qualify(hrAt = now + 1L))
        assertNull(
            qualify(
                observedMotion = motion.copy(
                    observedAtMillis =
                        now - StressEvidencePolicy.MAXIMUM_MOTION_RR_SKEW_MILLIS - 1_001L,
                ),
            ),
        )
        assertNull(qualify(connected = false))
        assertNull(qualify(bonded = false))
        assertNull(qualify(encrypted = false))
        assertNull(qualify(worn = false))
        assertNull(qualify(observedMotion = null))
    }

    @Test
    fun rrBufferResetsOnlyAfterARealReceiptGapOrClockReversal() {
        val limit = StressEvidencePolicy.MAXIMUM_RR_BUFFER_GAP_MILLIS

        assertFalse(StressEvidencePolicy.shouldResetRrBuffer(null, 1_000L))
        assertFalse(StressEvidencePolicy.shouldResetRrBuffer(1_000L, 1_000L + limit))
        assertTrue(StressEvidencePolicy.shouldResetRrBuffer(1_000L, 1_001L + limit))
        assertTrue(StressEvidencePolicy.shouldResetRrBuffer(1_000L, 999L))
    }

    @Test
    fun liveEvaluationCadence_isBoundedButForceAndClockRepairCanRun() {
        val now = 10_000L
        assertTrue(StressEvaluationCadence.shouldRequest(null, now))
        assertFalse(
            StressEvaluationCadence.shouldRequest(
                now,
                now + StressEvaluationCadence.MINIMUM_INTERVAL_MILLIS - 1L,
            ),
        )
        assertTrue(
            StressEvaluationCadence.shouldRequest(
                now,
                now + StressEvaluationCadence.MINIMUM_INTERVAL_MILLIS,
            ),
        )
        assertTrue(StressEvaluationCadence.shouldRequest(now, now + 1L, force = true))
        assertTrue(StressEvaluationCadence.shouldRequest(now, now - 1L))
    }
}
