package com.noop.ui

import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.CoarseWorkoutClass
import org.junit.Assert.assertEquals
import org.junit.Test

class AutoWorkoutSuggestionPolicyTest {
    @Test
    fun modeMigration_preservesLegacyChoiceAndDefaultsFreshInstallToAsk() {
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode(null, null))
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode(null, true))
        assertEquals(AutoWorkoutMode.OFF, NoopPrefs.resolveAutoWorkoutMode(null, false))
        assertEquals(AutoWorkoutMode.OFF, NoopPrefs.resolveAutoWorkoutMode("off", true))
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode("bad", true))
    }

    @Test
    fun autoSave_usesStricterDurationGate() {
        val short = AutoWorkoutDetector.DetectedWorkout(1_000, 1_840, 130, 160, 14)
        val confident = AutoWorkoutDetector.DetectedWorkout(1_000, 1_900, 130, 160, 15)
        assertEquals(false, AutoWorkoutAutomationPolicy.shouldAutoSave(short))
        assertEquals(true, AutoWorkoutAutomationPolicy.shouldAutoSave(confident))
    }

    @Test
    fun acceptedOrAutoSavedRow_isHonestlyDetectedNotManual() {
        val candidate = AutoWorkoutDetector.DetectedWorkout(1_700_000_000, 1_700_001_200, 140, 170, 20)
        val row = buildDetectedAutoWorkoutRow("strap-2-noop", candidate)
        requireNotNull(row)
        assertEquals("strap-2-noop", row.deviceId)
        assertEquals("strap-2-noop", row.source)
        assertEquals(WorkoutSource.DETECTED, WorkoutEditing.classify(row.source))
    }

    @Test
    fun acceptedHintMapsToEditableCatalogueSport_andUnknownStaysGeneric() {
        assertEquals("Running", acceptedAutoDetectSport(CoarseWorkoutClass.RUN))
        assertEquals("Walking", acceptedAutoDetectSport(CoarseWorkoutClass.WALK))
        assertEquals("Strength Training", acceptedAutoDetectSport(CoarseWorkoutClass.STRENGTH))
        assertEquals("Cycling", acceptedAutoDetectSport(CoarseWorkoutClass.CYCLE))
        assertEquals("Skiing", acceptedAutoDetectSport(CoarseWorkoutClass.SKI))
        assertEquals("Workout", acceptedAutoDetectSport(CoarseWorkoutClass.OTHER))
        assertEquals("Workout", acceptedAutoDetectSport(null))
    }

    @Test
    fun successfulSaveClearsCandidate_butFailureKeepsItForRetry() {
        assertEquals(
            AutoWorkoutSuggestionPolicy.SaveDisposition.CLEAR_CANDIDATE,
            AutoWorkoutSuggestionPolicy.afterSave(saved = true),
        )
        assertEquals(
            AutoWorkoutSuggestionPolicy.SaveDisposition.KEEP_FOR_RETRY,
            AutoWorkoutSuggestionPolicy.afterSave(saved = false),
        )
    }
}
