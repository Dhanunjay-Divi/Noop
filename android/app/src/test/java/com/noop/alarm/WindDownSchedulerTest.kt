package com.noop.alarm

import androidx.core.app.NotificationCompat
import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

class WindDownSchedulerTest {

    private fun millis(
        zone: TimeZone,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
    ): Long = Calendar.getInstance(zone).apply {
        clear()
        set(year, month - 1, day, hour, minute, 0)
    }.timeInMillis

    @Test
    fun schedulesTodayWhenLocalTimeIsStillAhead() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 8, 22, 20, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 8, 22, 22, 0), next)
    }

    @Test
    fun schedulesTomorrowWhenLocalTimeHasPassed() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 8, 22, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 8, 23, 22, 0), next)
    }

    @Test
    fun preservesWallClockAcrossSpringDstInsteadOfAddingTwentyFourHours() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 3, 7, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 3, 8, 22, 0), next)
        assertEquals(23L * 60L * 60L * 1_000L, next - millis(zone, 2026, 3, 7, 22, 0))
    }

    @Test
    fun preservesWallClockAcrossFallDstInsteadOfAddingTwentyFourHours() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 10, 31, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 11, 1, 22, 0), next)
        assertEquals(25L * 60L * 60L * 1_000L, next - millis(zone, 2026, 10, 31, 22, 0))
    }

    @Test
    fun exactCurrentMinuteRollsForward() {
        val zone = TimeZone.getTimeZone("UTC")
        val now = millis(zone, 2026, 8, 22, 22, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertTrue(next > now)
        assertEquals(millis(zone, 2026, 8, 23, 22, 0), next)
    }

    @Test
    fun notificationVisibilityIsPrivate() {
        assertEquals(
            NotificationCompat.VISIBILITY_PRIVATE,
            WindDownScheduler.NOTIFICATION_VISIBILITY,
        )
    }

    @Test
    fun freshComputedSessionEndingAsleepSuppressesWindDown() {
        val now = 1_800_000_000L
        val session = session(
            start = now - 90 * 60,
            end = now - 2 * 60,
            lastStage = "deep",
        )

        assertTrue(WindDownSleepStatePolicy.shouldSuppress(listOf(session), now))
    }

    @Test
    fun awakeStaleEditedAndSummaryOnlySessionsFailOpen() {
        val now = 1_800_000_000L
        val awake = session(now - 90 * 60, now - 2 * 60, "wake")
        val stale = session(now - 3 * 60 * 60, now - 31 * 60, "rem")
        val edited = session(now - 90 * 60, now - 2 * 60, "light").copy(userEdited = true)
        val summaryOnly = session(now - 90 * 60, now - 2 * 60, "light").copy(
            stagesJSON = """{"light":80,"deep":10}""",
        )

        assertFalse(
            WindDownSleepStatePolicy.shouldSuppress(
                listOf(awake, stale, edited, summaryOnly),
                now,
            ),
        )
    }

    @Test
    fun malformedOrFutureEvidenceFailsOpen() {
        val now = 1_800_000_000L
        val malformed = session(now - 90 * 60, now - 2 * 60, "light").copy(
            stagesJSON = """[{"start":$now,"end":${now - 60},"stage":"light"}]""",
        )
        val future = session(now + 60, now + 5 * 60, "light")

        assertFalse(WindDownSleepStatePolicy.shouldSuppress(listOf(malformed, future), now))
    }

    private fun session(start: Long, end: Long, lastStage: String): SleepSession {
        val middle = start + (end - start) / 2
        return SleepSession(
            deviceId = "test-noop",
            startTs = start,
            endTs = end,
            stagesJSON =
                """[{"start":$start,"end":$middle,"stage":"light"},""" +
                    """{"start":$middle,"end":$end,"stage":"$lastStage"}]""",
        )
    }
}
