package com.noop.ui

import com.noop.testing.FakeSharedPreferences
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AdaptiveDayConsentGateTest {
    @Before
    fun resetBeforeTest() {
        AdaptiveDayConsentGate.resetForTests()
    }

    @After
    fun resetAfterTest() {
        AdaptiveDayConsentGate.resetForTests()
    }

    @Test
    fun failedGuidanceEnableNeverEscapesTheLastCommittedValue() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(false, false),
            applyFailedCommitsToMemory = true,
        )
        assertFalse(AdaptiveDayConsentGate.guidance(prefs))

        assertFalse(AdaptiveDayConsentGate.commitGuidance(prefs, enabled = true))

        assertFalse(AdaptiveDayConsentGate.guidance(prefs))
        assertFalse(prefs.getBoolean(NoopPrefs.KEY_ADAPTIVE_DAY_GUIDANCE, false))
        assertFalse(NoopPrefs.adaptiveDayCleanupPending(prefs))
    }

    @Test
    fun failedCalendarDisableNeverEscapesTheLastCommittedValue() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(false, false),
            applyFailedCommitsToMemory = true,
        ).apply {
            edit()
                .putBoolean(NoopPrefs.KEY_PLANNED_WORKOUT_CALENDAR, true)
                .apply()
        }
        assertTrue(AdaptiveDayConsentGate.plannedWorkoutCalendar(prefs))

        assertFalse(
            AdaptiveDayConsentGate.commitPlannedWorkoutCalendar(
                prefs,
                enabled = false,
            ),
        )

        assertTrue(AdaptiveDayConsentGate.plannedWorkoutCalendar(prefs))
        assertTrue(prefs.getBoolean(NoopPrefs.KEY_PLANNED_WORKOUT_CALENDAR, false))
        assertFalse(NoopPrefs.plannedWorkoutCleanupPending(prefs))
    }

    @Test
    fun successfulDisablePersistsCleanupAcrossProcessRestart() {
        val prefs = FakeSharedPreferences().apply {
            edit()
                .putBoolean(NoopPrefs.KEY_ADAPTIVE_DAY_GUIDANCE, true)
                .putBoolean(NoopPrefs.KEY_PLANNED_WORKOUT_CALENDAR, true)
                .apply()
        }

        assertTrue(AdaptiveDayConsentGate.guidance(prefs))
        assertTrue(AdaptiveDayConsentGate.commitGuidance(prefs, enabled = false))
        assertFalse(AdaptiveDayConsentGate.guidance(prefs))
        assertTrue(NoopPrefs.adaptiveDayCleanupPending(prefs))

        AdaptiveDayConsentGate.resetForTests()

        assertFalse(AdaptiveDayConsentGate.guidance(prefs))
        assertTrue(NoopPrefs.adaptiveDayCleanupPending(prefs))
    }
}
