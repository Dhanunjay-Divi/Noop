package com.noop.safety

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetySosGestureTest {
    @Test
    fun fourRapidEventsTriggerOnlyOnFourth() {
        val policy = SafetySosGestureAccumulator()
        assertEquals(
            SafetySosGestureAccumulator.Result.Progress(1),
            policy.record(1_000, 4),
        )
        assertEquals(
            SafetySosGestureAccumulator.Result.Progress(2),
            policy.record(3_000, 4),
        )
        assertEquals(
            SafetySosGestureAccumulator.Result.Progress(3),
            policy.record(5_000, 4),
        )
        assertEquals(
            SafetySosGestureAccumulator.Result.Triggered,
            policy.record(7_000, 4),
        )
    }

    @Test
    fun longGapStartsANewSequence() {
        val policy = SafetySosGestureAccumulator()
        policy.record(1_000, 3)
        policy.record(2_000, 3)
        assertEquals(
            SafetySosGestureAccumulator.Result.Progress(1),
            policy.record(6_000, 3),
        )
    }

    @Test
    fun triggerResetsSequence() {
        val policy = SafetySosGestureAccumulator()
        policy.record(1_000, 3)
        policy.record(2_000, 3)
        assertEquals(
            SafetySosGestureAccumulator.Result.Triggered,
            policy.record(3_000, 3),
        )
        assertEquals(
            SafetySosGestureAccumulator.Result.Progress(1),
            policy.record(4_000, 3),
        )
    }

    @Test
    fun requiredEventCountIsClampedToThreeOrFour() {
        val low = SafetySosGestureAccumulator()
        low.record(1_000, 1)
        low.record(2_000, 1)
        assertEquals(
            SafetySosGestureAccumulator.Result.Triggered,
            low.record(3_000, 1),
        )

        val high = SafetySosGestureAccumulator()
        high.record(1_000, 8)
        high.record(2_000, 8)
        high.record(3_000, 8)
        assertEquals(
            SafetySosGestureAccumulator.Result.Triggered,
            high.record(4_000, 8),
        )
    }

    @Test
    fun bandSosLocationRequiresPreferenceAndBackgroundPermission() {
        assertFalse(
            SafetySosDispatcher.shouldShareLocation(
                preferenceEnabled = false,
                backgroundLocationAvailable = false,
            ),
        )
        assertFalse(
            SafetySosDispatcher.shouldShareLocation(
                preferenceEnabled = false,
                backgroundLocationAvailable = true,
            ),
        )
        assertFalse(
            SafetySosDispatcher.shouldShareLocation(
                preferenceEnabled = true,
                backgroundLocationAvailable = false,
            ),
        )
        assertTrue(
            SafetySosDispatcher.shouldShareLocation(
                preferenceEnabled = true,
                backgroundLocationAvailable = true,
            ),
        )
    }

    @Test
    fun liveLocationStateStopsAtItsBoundedExpiry() {
        val state = SafetyLiveLocationSession.State(
            dispatchId = "dispatch",
            sequence = 2L,
            expiresAtUnix = 10_000L,
        )
        assertTrue(state.isActiveAt(9_999L))
        assertFalse(state.isActiveAt(10_000L))
        assertFalse(SafetyLiveLocationSession.State().isActiveAt(1L))
    }

    @Test
    fun isoIncidentExpiryParsingIsStrict() {
        assertEquals(1_787_395_200L, parseIsoInstantUnix("2026-08-22T10:40:00Z"))
        assertEquals(null, parseIsoInstantUnix("not-a-time"))
    }
}
