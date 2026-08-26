package com.noop.notif

import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.DailyEffortGuidance
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.ScoreConfidence
import com.noop.ui.NoopPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure gate + copy of the #593 evidence-gated Effort-marker notification (the ScheduledReportPolicy /
 * BatteryAlertPolicy crossing-dedupe idiom). The Android notifier just wires this to a channel + the
 * persisted day marker, so all the decision logic is verified here without android.*. Contract: fire at
 * most once per day, only when strain has genuinely reached a KNOWN target, never on a guessed one.
 */
class StrainTargetPolicyTest {
    private val range = DailyActionPlanner.EffortRange(40, 60)

    private fun guidance(effort: Double?) =
        com.noop.analytics.DailyEffortGuidance.evaluate(effort, range)

    @Test fun firesWhenEnabledStrainReachedTargetAndNotYetToday() {
        assertTrue(
            StrainTargetPolicy.shouldNotify(
                enabled = true, guidance = guidance(40.0),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = "2026-07-17",
            ),
        )
        // Overshooting the target still fires (>= gate), once.
        assertTrue(
            StrainTargetPolicy.shouldNotify(
                enabled = true, guidance = guidance(72.0),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun suppressedWhenDisabled() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = false, guidance = guidance(50.0),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun suppressedBeforeTargetIsReached() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, guidance = guidance(39.9),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun suppressedWhenAlreadyFiredToday() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, guidance = guidance(50.0),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedForHistoricalOrFutureDataDays() {
        listOf("2026-07-17", "2026-07-19").forEach { dataDay ->
            assertFalse(
                "only the current local calendar day's row may notify",
                StrainTargetPolicy.shouldNotify(
                    enabled = true,
                    guidance = guidance(50.0),
                    dataDay = dataDay,
                    currentLocalDay = "2026-07-18",
                    lastNotifiedDay = null,
                ),
            )
        }
    }

    @Test fun suppressedWhenTargetUnknownCalibrating() {
        // Planner withheld the range ⇒ null target ⇒ never fire (never guess a target).
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true,
                guidance = DailyEffortGuidance.evaluate(50.0, null),
                dataDay = "2026-07-18",
                currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun suppressedWhenNoStrainYet() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, guidance = guidance(null),
                dataDay = "2026-07-18", currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun staleReadinessCannotProduceNotifiableGuidance() {
        val staleReadiness = ReadinessEngine.Readiness(
            level = ReadinessEngine.Level.BALANCED,
            headline = "Readiness",
            summary = "Stale fixture",
            signals = emptyList(),
            effortVariety = null,
            asOfDay = "2026-07-17",
            confidence = ScoreConfidence.SOLID,
            baselineDays = 14,
        )
        val plan = DailyActionPlanner.plan(
            today = "2026-07-18",
            readiness = staleReadiness,
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = emptyList(),
        )
        assertEquals(null, plan.target)
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true,
                guidance = DailyEffortGuidance.evaluate(50.0, plan.target),
                dataDay = "2026-07-18",
                currentLocalDay = "2026-07-18",
                lastNotifiedDay = null,
            ),
        )
    }

    @Test fun dailyActionCheckInIsStrictlyDayScopedAndFailClosed() {
        assertEquals(
            DailyActionPlanner.CheckIn.AS_USUAL,
            NoopPrefs.decodeDailyActionCheckIn("2026-08-22", "2026-08-22", "asUsual"),
        )
        assertEquals(
            DailyActionPlanner.CheckIn.UNANSWERED,
            NoopPrefs.decodeDailyActionCheckIn("2026-08-22", "2026-08-21", "asUsual"),
        )
        assertEquals(
            DailyActionPlanner.CheckIn.UNANSWERED,
            NoopPrefs.decodeDailyActionCheckIn("2026-08-22", "2026-08-22", "unexpected"),
        )
    }
}
