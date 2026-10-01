package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionableWellnessPolicyTest {
    @Test
    fun breathingSessionCompletesOnlyAtBoundedMinute() {
        assertEquals(
            0,
            ActionableWellnessPolicy.elapsedSeconds(
                startedAtElapsedRealtimeMs = 1_000L,
                nowElapsedRealtimeMs = 999L,
            ),
        )
        assertEquals(
            59,
            ActionableWellnessPolicy.elapsedSeconds(
                startedAtElapsedRealtimeMs = 1_000L,
                nowElapsedRealtimeMs = 60_999L,
            ),
        )
        assertFalse(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession = false,
                elapsedSeconds = 60,
            ),
        )
        assertFalse(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession = true,
                elapsedSeconds = 59,
            ),
        )
        assertTrue(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession = true,
                elapsedSeconds = 60,
            ),
        )
        assertFalse(
            ActionableWellnessPolicy.shouldStopBreathingForBondTransition(
                wasBonded = false,
                isBonded = false,
                isRunning = true,
            ),
        )
        assertTrue(
            ActionableWellnessPolicy.shouldStopBreathingForBondTransition(
                wasBonded = true,
                isBonded = false,
                isRunning = true,
            ),
        )
    }

    @Test
    fun movementBreakCountdownAndProgressAreBounded() {
        assertEquals(
            119,
            ActionableWellnessPolicy.movementRemainingSecondsAfterTick(120),
        )
        assertEquals(
            0,
            ActionableWellnessPolicy.movementRemainingSecondsAfterTick(0),
        )
        assertEquals(
            120,
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtElapsedRealtimeMs = 1_000L,
                nowElapsedRealtimeMs = 1_999L,
            ),
        )
        assertEquals(
            119,
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtElapsedRealtimeMs = 1_000L,
                nowElapsedRealtimeMs = 2_000L,
            ),
        )
        assertEquals(
            0,
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtElapsedRealtimeMs = 1_000L,
                nowElapsedRealtimeMs = 121_000L,
            ),
        )
        assertEquals(
            0f,
            ActionableWellnessPolicy.movementProgress(120),
            0.0001f,
        )
        assertEquals(
            0.5f,
            ActionableWellnessPolicy.movementProgress(60),
            0.0001f,
        )
        assertEquals(
            1f,
            ActionableWellnessPolicy.movementProgress(0),
            0.0001f,
        )
        assertEquals(
            1f,
            ActionableWellnessPolicy.movementProgress(-20),
            0.0001f,
        )
    }

    @Test
    fun wellnessPresentationsRoundTripOnlyTrustedValues() {
        listOf(
            NotificationRoutePresentation.START_BREATHING,
            NotificationRoutePresentation.LOG_HYDRATION,
            NotificationRoutePresentation.MOVEMENT_BREAK,
        ).forEach { presentation ->
            assertEquals(
                presentation,
                NotificationRoutePresentation.fromRaw(
                    presentation.storedValue,
                ),
            )
        }
        assertEquals(
            null,
            NotificationRoutePresentation.fromRaw("https://example.com"),
        )
    }
}
