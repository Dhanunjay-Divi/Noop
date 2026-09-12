package com.noop.alarm

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.TimeZone

class WindDownSchedulerTest {

    private val utc = TimeZone.getTimeZone("UTC")

    @Test
    fun fridayEveningUsesSaturdayPlannerOverride() {
        val now = Instant.parse("2026-09-11T12:00:00Z").toEpochMilli()

        val plan = WindDownScheduler.nextDatedPlan(
            defaultWakeMinutes = 9 * 60,
            wakeOverrides = mapOf(7 to 7 * 60),
            targetSleepMinutes = 8 * 60,
            leadMinutes = 30,
            nowMs = now,
            timeZone = utc,
        )

        assertNotNull(plan)
        assertEquals(
            Instant.parse("2026-09-11T22:30:00Z").toEpochMilli(),
            plan!!.windDownAtMillis,
        )
        assertEquals(
            Instant.parse("2026-09-11T23:00:00Z").toEpochMilli(),
            plan.bedtimeAtMillis,
        )
        assertEquals(
            Instant.parse("2026-09-12T07:00:00Z").toEpochMilli(),
            plan.wakeAtMillis,
        )
        assertEquals(7, plan.wakeWeekday)
    }

    @Test
    fun springGapMovesWakeForwardByTheGapAndKeepsExactPlanInstants() {
        val plan = WindDownScheduler.datedPlan(
            wakeDate = LocalDate.of(2026, 3, 8),
            wakeMinutes = 2 * 60 + 30,
            targetSleepMinutes = 60,
            leadMinutes = 30,
            zoneId = ZoneId.of("America/New_York"),
        )

        assertEquals(
            Instant.parse("2026-03-08T07:30:00Z").toEpochMilli(),
            plan.wakeAtMillis,
        )
        assertEquals(
            Instant.parse("2026-03-08T06:30:00Z").toEpochMilli(),
            plan.bedtimeAtMillis,
        )
        assertEquals(
            Instant.parse("2026-03-08T06:00:00Z").toEpochMilli(),
            plan.windDownAtMillis,
        )
    }

    @Test
    fun fallOverlapUsesEarlierOffsetLikeApple() {
        val plan = WindDownScheduler.datedPlan(
            wakeDate = LocalDate.of(2026, 11, 1),
            wakeMinutes = 1 * 60 + 30,
            targetSleepMinutes = 60,
            leadMinutes = 30,
            zoneId = ZoneId.of("America/New_York"),
        )

        assertEquals(
            Instant.parse("2026-11-01T05:30:00Z").toEpochMilli(),
            plan.wakeAtMillis,
        )
        assertEquals(
            Instant.parse("2026-11-01T04:30:00Z").toEpochMilli(),
            plan.bedtimeAtMillis,
        )
    }

    @Test
    fun fireTimeDerivationAllowsOnlyFreshPreBedtimeDelivery() {
        val planned = WindDownScheduler.nextDatedPlan(
            defaultWakeMinutes = 7 * 60,
            wakeOverrides = mapOf(7 to 8 * 60),
            targetSleepMinutes = 8 * 60,
            leadMinutes = 30,
            nowMs = Instant.parse("2026-09-11T12:00:00Z").toEpochMilli(),
            timeZone = utc,
        )!!
        val delivered = WindDownScheduler.currentDatedPlan(
            defaultWakeMinutes = 7 * 60,
            wakeOverrides = mapOf(7 to 8 * 60),
            targetSleepMinutes = 8 * 60,
            leadMinutes = 30,
            nowMs = planned.windDownAtMillis + 14 * 60 * 1_000L,
            timeZone = utc,
        )

        assertEquals(planned, delivered)
        assertEquals(
            null,
            WindDownScheduler.currentDatedPlan(
                defaultWakeMinutes = 7 * 60,
                wakeOverrides = mapOf(7 to 8 * 60),
                targetSleepMinutes = 8 * 60,
                leadMinutes = 30,
                nowMs = planned.windDownAtMillis + 16 * 60 * 1_000L,
                timeZone = utc,
            ),
        )
    }

    @Test
    fun fireTimeDerivationFailsClosedAtBedtimeEvenWithLaxInjectedLateness() {
        val planned = WindDownScheduler.nextDatedPlan(
            defaultWakeMinutes = 7 * 60,
            wakeOverrides = emptyMap(),
            targetSleepMinutes = 8 * 60,
            leadMinutes = 10,
            nowMs = Instant.parse("2026-09-11T12:00:00Z").toEpochMilli(),
            timeZone = utc,
        )!!

        assertEquals(
            null,
            WindDownScheduler.currentDatedPlan(
                defaultWakeMinutes = 7 * 60,
                wakeOverrides = emptyMap(),
                targetSleepMinutes = 8 * 60,
                leadMinutes = 10,
                nowMs = planned.bedtimeAtMillis,
                timeZone = utc,
                maximumLatenessMillis = 6 * 60 * 60 * 1_000L,
            ),
        )
    }

    @Test
    fun notificationPlanWrapsAcrossMidnightAndKeepsBothPlannerTimes() {
        assertEquals(
            WindDownScheduler.NotificationPlan(
                windDownMinuteOfDay = 22 * 60 + 30,
                bedtimeMinuteOfDay = 23 * 60,
            ),
            WindDownScheduler.notificationPlan(
                wakeMinutes = 7 * 60,
                targetSleepMinutes = 8 * 60,
                leadMinutes = 30,
            ),
        )
        assertEquals(
            WindDownScheduler.NotificationPlan(
                windDownMinuteOfDay = 30,
                bedtimeMinuteOfDay = 60,
            ),
            WindDownScheduler.notificationPlan(
                wakeMinutes = 9 * 60,
                targetSleepMinutes = 8 * 60,
                leadMinutes = 30,
            ),
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
    fun awakeStaleEditedSparseUnknownAndSummaryOnlySessionsFailOpen() {
        val now = 1_800_000_000L
        val awake = session(now - 90 * 60, now - 2 * 60, "wake")
        val stale = session(now - 3 * 60 * 60, now - 31 * 60, "rem")
        val edited = session(now - 90 * 60, now - 2 * 60, "light")
            .copy(userEdited = true)
        val sparse = session(now - 90 * 60, now - 2 * 60, "light")
            .copy(gravitySparse = true)
        val unknown = session(now - 90 * 60, now - 2 * 60, "light")
            .copy(gravitySparse = null)
        val summaryOnly = session(now - 90 * 60, now - 2 * 60, "light").copy(
            stagesJSON = """{"light":80,"deep":10}""",
        )

        assertFalse(
            WindDownSleepStatePolicy.shouldSuppress(
                listOf(awake, stale, edited, sparse, unknown, summaryOnly),
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
            gravitySparse = false,
        )
    }
}
