package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutCautionDeliveryPolicyTest {
    @Test fun firstCueDeliversAndRestartedStateDeduplicatesUntilCooldown() {
        val now = 1_700_000_000_000L
        assertTrue(
            WorkoutCautionDeliveryPolicy.shouldDeliver(WorkoutCautionDeliveryState(), now),
        )

        val restarted = WorkoutCautionDeliveryState(lastDeliveryMillis = now)
        assertFalse(
            WorkoutCautionDeliveryPolicy.shouldDeliver(
                restarted,
                now + WorkoutCautionDeliveryPolicy.COOLDOWN_MILLIS - 1,
            ),
        )
        assertTrue(
            WorkoutCautionDeliveryPolicy.shouldDeliver(
                restarted,
                now + WorkoutCautionDeliveryPolicy.COOLDOWN_MILLIS,
            ),
        )
    }
}
