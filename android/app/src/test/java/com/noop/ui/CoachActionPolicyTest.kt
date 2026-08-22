package com.noop.ui

import com.noop.notif.CoachCheckInReminder
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoachActionPolicyTest {
    @Test
    fun voiceDraftOnlyMatchesKnownReviewRows() {
        val matches = CoachJournalDraftPolicy.matches(
            "I used the sauna, took magnesium, and had a glass of wine.",
        )
        assertEquals(
            setOf(
                "Did you drink any alcohol?",
                "Did you use a sauna?",
                "Did you take magnesium?",
            ),
            matches.toSet(),
        )
        assertTrue(CoachJournalDraftPolicy.matches("ordinary day").isEmpty())
        assertTrue(matches.all { it in CoachJournalDraftPolicy.questions })
    }

    @Test
    fun nextCheckInUsesLocalWallClockAcrossDst() {
        val zone = ZoneId.of("America/New_York")
        val beforeSpring = ZonedDateTime.of(2026, 3, 7, 20, 0, 0, 0, zone)
        val spring = CoachCheckInReminder.nextRun(beforeSpring, 18 * 60)
        assertEquals(18, spring.hour)
        assertEquals(8, spring.dayOfMonth)
        assertEquals("-04:00", spring.offset.toString())

        val beforeFall = ZonedDateTime.of(2026, 10, 31, 20, 0, 0, 0, zone)
        val fall = CoachCheckInReminder.nextRun(beforeFall, 18 * 60)
        assertEquals(18, fall.hour)
        assertEquals(1, fall.dayOfMonth)
        assertEquals("-05:00", fall.offset.toString())
    }
}
