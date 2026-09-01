package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutCautionPolicyTest {
    private fun policy() = WorkoutCautionPolicy(
        WorkoutCautionPolicy.Config(hrMax = 190.0),
        startTs = 0,
    )

    @Test fun oneSpikeIsRejectedAndCannotCue() {
        val policy = policy()
        policy.update(0, 120)
        val spike = policy.update(1, 190)

        assertFalse(spike.sampleArrived)
        assertNull(spike.cue)
        assertEquals(120.0, spike.smoothedBpm ?: 0.0, 0.01)
    }

    @Test fun repeatedJumpCorroboratesButStillNeedsSustainedDwell() {
        val policy = policy()
        policy.update(0, 120)
        assertFalse(policy.update(1, 186).sampleArrived)
        assertTrue(policy.update(2, 185).sampleArrived)

        val outputs = (3..200).map { policy.update(it.toLong(), 185) }
        assertEquals(1, outputs.count { it.cue == WorkoutCautionPolicy.Cue.PAUSE_AND_ASSESS })
        assertFalse(outputs.any { it.cue == WorkoutCautionPolicy.Cue.EASE_OFF })
    }

    @Test fun sustainedHighExertionEasesOffOnce() {
        val policy = policy()
        val outputs = (0..80).map { policy.update(it.toLong(), 175) }

        assertEquals(1, outputs.count { it.cue == WorkoutCautionPolicy.Cue.EASE_OFF })
        assertFalse(outputs.any { it.cue == WorkoutCautionPolicy.Cue.PAUSE_AND_ASSESS })
    }

    @Test fun readingsAboveEstimatedMaxRemainEligibleButImpossibleValuesDoNot() {
        val policy = WorkoutCautionPolicy(
            WorkoutCautionPolicy.Config(hrMax = 170.0),
            startTs = 0,
        )

        assertTrue(policy.update(0, 180).sampleArrived)
        assertFalse(policy.update(1, 241).sampleArrived)
    }

    @Test fun gapResetsDwellAndRecoveryFiresOnlyAfterARealCue() {
        val policy = policy()
        (0..30).forEach { policy.update(it.toLong(), 175) }
        policy.update(50, 175)
        val beforeDwell = (51 until 95).map { policy.update(it.toLong(), 175) }
        assertFalse(beforeDwell.any { it.cue != null })

        assertEquals(WorkoutCautionPolicy.Cue.EASE_OFF, policy.update(95, 175).cue)
        val recovery = (96..115).map { policy.update(it.toLong(), 150) }
        assertEquals(1, recovery.count { it.cue == WorkoutCautionPolicy.Cue.RECOVERED })
    }
}
