package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure gate + copy of the #517 scheduled report notifications (the CallAlertPolicy/IllnessAlertPolicy
 * idiom). The Android notifier just wires these to a channel + the persisted dedupe markers, so all the
 * decision logic is verified here without android.*. The PRIVACY contract: notification copy is a generic
 * invitation to open NOOP and never includes a score, sport, duration, or heart-rate value. Both reports
 * still fire at most once per logical event, never twice.
 */
class ScheduledReportPolicyTest {

    // MARK: - shouldNotifyMorning (once-per-day gate)

    @Test fun morningFiresWhenEnabledScorePresentAndNotYetToday() {
        assertTrue(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = true, lastNotifiedDay = "2026-06-20", reportDay = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenDisabled() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = false, chargeOrRestPresent = true, lastNotifiedDay = null, reportDay = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenAlreadyFiredToday() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = true, lastNotifiedDay = "2026-06-21", reportDay = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenNoScore() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = false, lastNotifiedDay = null, reportDay = "2026-06-21",
            ),
        )
    }

    /** #567: after midnight a late-nighter's row still resolves to LAST night (reportDay stays that
     *  night's day) even though the calendar day has rolled. Keyed on reportDay (not the calendar day),
     *  the recap must NOT re-fire — it was already posted for that night. Guards the fix against a
     *  regression back to `LocalDate.now()`. */
    @Test fun morningDoesNotRefireAtMidnightWhenReportDayIsStillLastNight() {
        // Fired this morning for the 06-20 night; now it's just past midnight (calendar day 06-21) but the
        // resolved row is still the 06-20 night → reportDay = "2026-06-20", already notified → suppressed.
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = true, lastNotifiedDay = "2026-06-20", reportDay = "2026-06-20",
            ),
        )
    }

    // MARK: - shouldNotifyWorkout (strictly-newer gate)

    @Test fun workoutFiresForANewerSession() {
        assertTrue(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 2000L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedForSameSession() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 1000L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedForReSyncOfOlderBacklog() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 500L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedWhenDisabledOrNull() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = false, newestWorkoutTs = 2000L, lastWorkoutTs = 1000L))
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = null, lastWorkoutTs = 1000L))
    }

    @Test fun workoutFiresForTheVeryFirstSession() {
        // lastWorkoutTs == 0 means "none yet"; any real timestamp is newer.
        assertTrue(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 1L, lastWorkoutTs = 0L))
    }

    // MARK: - morningCopy (privacy-safe lock-screen reminder)

    @Test fun morningCopyNeverShowsScores() {
        val (title, body) = ScheduledReportPolicy.morningCopy(chargePct = 72, restPct = 88)!!
        val copy = "$title $body"
        assertEquals("Your morning recap is ready", title)
        assertTrue(body.contains("Recovery"))
        assertTrue(body.contains("Sleep Score"))
        assertFalse(copy.contains("72"))
        assertFalse(copy.contains("88"))
        assertFalse(copy.contains("Charge"))
    }

    @Test fun morningCopyStaysGenericWhenOnlyOneScoreExists() {
        val copy = ScheduledReportPolicy.morningCopy(chargePct = 60, restPct = null)!!
        assertEquals(
            ScheduledReportPolicy.morningCopy(chargePct = null, restPct = 91),
            copy,
        )
        assertFalse("${copy.first} ${copy.second}".contains("60"))
        assertFalse("${copy.first} ${copy.second}".contains("91"))
    }

    @Test fun morningCopyNullWhenNeitherPresent() {
        assertNull(ScheduledReportPolicy.morningCopy(chargePct = null, restPct = null))
    }

    // MARK: - workoutCopy

    @Test fun workoutCopyNeverShowsSportEffortDurationOrHr() {
        val (title, body) = ScheduledReportPolicy.workoutCopy(
            sportLabel = "Running", effortDisplay = "14.2", effortMaxLabel = "21",
            durationLabel = "42 min", avgHr = 148,
        )
        val copy = "$title $body"
        assertEquals("Your workout summary is ready", title)
        assertTrue(body.contains("Effort"))
        listOf("Running", "14.2", "21", "42", "148", "bpm").forEach {
            assertFalse(copy.contains(it))
        }
    }

    @Test fun workoutCopyIsStableAcrossDetailedInputs() {
        val a = ScheduledReportPolicy.workoutCopy(
            sportLabel = "Cycling", effortDisplay = "60", effortMaxLabel = "100",
            durationLabel = "1 h", avgHr = null,
        )
        val b = ScheduledReportPolicy.workoutCopy(
            sportLabel = "Running", effortDisplay = "14.2", effortMaxLabel = "21",
            durationLabel = "42 min", avgHr = 148,
        )
        assertEquals(a, b)
    }

    // MARK: - durationLabel

    @Test fun durationLabelFormats() {
        assertEquals("under a minute", ScheduledReportPolicy.durationLabel(0))
        assertEquals("under a minute", ScheduledReportPolicy.durationLabel(-5))
        assertEquals("42 min", ScheduledReportPolicy.durationLabel(42))
        assertEquals("1 h", ScheduledReportPolicy.durationLabel(60))
        assertEquals("1 h 8 min", ScheduledReportPolicy.durationLabel(68))
        assertEquals("2 h", ScheduledReportPolicy.durationLabel(120))
    }
}
