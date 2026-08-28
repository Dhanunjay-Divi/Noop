package com.noop.ui

import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.CoarseWorkoutClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoWorkoutSuggestionPolicyTest {
    @Test
    fun modeMigration_preservesLegacyChoiceAndDefaultsFreshInstallToAsk() {
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode(null, null))
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode(null, true))
        assertEquals(AutoWorkoutMode.OFF, NoopPrefs.resolveAutoWorkoutMode(null, false))
        assertEquals(AutoWorkoutMode.OFF, NoopPrefs.resolveAutoWorkoutMode("off", true))
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode("autoSave", true))
        assertEquals(AutoWorkoutMode.ASK, NoopPrefs.resolveAutoWorkoutMode("bad", true))
    }

    @Test
    fun startupMigration_canonicalizesRetiredAutoSave_andDisablesLegacyWriteGate() {
        listOf(
            Triple(null, null, AutoWorkoutMode.ASK),
            Triple(null, true, AutoWorkoutMode.ASK),
            Triple(null, false, AutoWorkoutMode.OFF),
            Triple("autoSave", true, AutoWorkoutMode.ASK),
            Triple("ask", true, AutoWorkoutMode.ASK),
            Triple("off", true, AutoWorkoutMode.OFF),
        ).forEach { (stored, legacy, expectedMode) ->
            val canonical = NoopPrefs.canonicalAutoWorkoutPreferences(stored, legacy)
            assertEquals(expectedMode, canonical.mode)
            assertEquals(false, canonical.legacyEnabled)
        }
    }

    @Test
    fun autoSave_neverPersistsUncalibratedCandidates() {
        val short = AutoWorkoutDetector.DetectedWorkout(1_000, 1_840, 130, 160, 14)
        val longButUncalibrated = AutoWorkoutDetector.DetectedWorkout(
            1_000, 1_900, 130, 160, 15,
            eventConfidence = 0.99,
            confidenceStatus = AutoWorkoutDetector.ConfidenceStatus.UNCALIBRATED,
        )
        assertEquals(false, AutoWorkoutAutomationPolicy.shouldAutoSave(short))
        assertEquals(false, AutoWorkoutAutomationPolicy.shouldAutoSave(longButUncalibrated))
    }

    @Test
    fun backgroundProcessing_rejectsOldAndHeartRateOnlyCandidates() {
        val now = 1_700_010_000L
        val borderline = AutoWorkoutDetector.DetectedWorkout(
            now - 25 * 60, now - 10 * 60, 102, 112, 15,
        )
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(borderline, now))

        val strongHeartRateOnly = AutoWorkoutDetector.DetectedWorkout(
            now - 35 * 60, now - 10 * 60, 125, 150, 25,
        )
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(strongHeartRateOnly, now))

        val mislabeledStillWindow = AutoWorkoutDetector.DetectedWorkout(
            startSec = now - 35 * 60,
            endSec = now - 10 * 60,
            avgBpm = 125,
            peakBpm = 150,
            durationMin = 25,
            suggestedClass = CoarseWorkoutClass.CYCLE,
            suggestionConfidence = 0.9,
            evidenceProvenance = AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_ONLY,
        )
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(mislabeledStillWindow, now))

        val stale = AutoWorkoutDetector.DetectedWorkout(
            startSec = now - 4 * 3_600,
            endSec = now - 3 * 3_600,
            avgBpm = 145,
            peakBpm = 175,
            durationMin = 60,
            evidenceProvenance = AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_AND_MOTION,
        )
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(stale, now))
    }

    @Test
    fun motionCorroboration_allowsARecentTenMinuteCandidate() {
        val now = 1_700_010_000L
        val corroborated = AutoWorkoutDetector.DetectedWorkout(
            startSec = now - 20 * 60,
            endSec = now - 10 * 60,
            avgBpm = 100,
            peakBpm = 115,
            durationMin = 10,
            evidenceProvenance = AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_AND_MOTION,
        )
        assertTrue(AutoWorkoutBackgroundPolicy.shouldProcess(corroborated, now))
        assertEquals(
            AutoWorkoutDetector.minSustainedMin,
            AutoWorkoutBackgroundPolicy.minimumCorroboratedMinutes.toDouble(),
            0.0,
        )
    }

    @Test
    fun backgroundProcessing_honorsRecencyAndDurationBoundaries() {
        val now = 1_700_010_000L
        fun candidate(endOffset: Long, duration: Int): AutoWorkoutDetector.DetectedWorkout {
            val end = now + endOffset
            return AutoWorkoutDetector.DetectedWorkout(
                startSec = end - duration * 60,
                endSec = end,
                avgBpm = 110,
                peakBpm = 135,
                durationMin = duration,
                evidenceProvenance = AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_AND_MOTION,
            )
        }

        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(-600, 9), now))
        assertTrue(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(-600, 10), now))
        assertTrue(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(-600, 13), now))
        assertTrue(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(-7_200, 10), now))
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(-7_201, 10), now))
        assertTrue(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(300, 10), now))
        assertFalse(AutoWorkoutBackgroundPolicy.shouldProcess(candidate(301, 10), now))
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
        assertEquals(
            "Basketball",
            acceptedAutoDetectSport(CoarseWorkoutClass.OTHER, requestedSport = "Basketball"),
        )
        assertEquals(
            "Running",
            acceptedAutoDetectSport(CoarseWorkoutClass.RUN, requestedSport = "not-a-catalog-sport"),
        )
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
