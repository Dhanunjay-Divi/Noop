package com.noop.notif

import com.noop.R
import com.noop.analytics.AdaptiveDayGuidance
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ScoreConfidence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveDayNotifierTest {
    private val nowMillis = 1_700_000_000_000L

    private fun candidate(
        kind: AdaptiveDayDeliveryKind = AdaptiveDayDeliveryKind.SLEEP_RECOVERY,
        observedAtMillis: Long = nowMillis,
        fingerprint: String = "sleep-a",
    ) = AdaptiveDayDeliveryCandidate(
        kind = kind,
        observedAtMillis = observedAtMillis,
        maximumAgeMillis = 36L * 60L * 60L * 1_000L,
        fingerprint = fingerprint,
    )

    @Test fun deliveryGateRejectsDuplicateCooldownGlobalCooldownQuietHoursAndStaleEvidence() {
        val delivered = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(),
            AdaptiveDayDeliveryState(),
            nowMillis,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertTrue(delivered.shouldDeliver)

        val duplicate = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(),
            delivered.nextState,
            nowMillis + 31L * 60L * 1_000L,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.DUPLICATE, duplicate.reason)

        val topicCooldown = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(fingerprint = "sleep-b"),
            delivered.nextState,
            nowMillis + 31L * 60L * 1_000L,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, topicCooldown.reason)

        val globalCooldown = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(AdaptiveDayDeliveryKind.TRAVEL, fingerprint = "travel-a"),
            delivered.nextState,
            nowMillis + 10L * 60L * 1_000L,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.GLOBAL_COOLDOWN, globalCooldown.reason)

        val quiet = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(),
            AdaptiveDayDeliveryState(),
            nowMillis,
            23 * 60,
            true,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.QUIET_HOURS, quiet.reason)

        val stale = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(observedAtMillis = nowMillis - 37L * 60L * 60L * 1_000L),
            AdaptiveDayDeliveryState(),
            nowMillis,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.STALE, stale.reason)
    }

    @Test fun timeZoneTransitionIgnoresDstAndRetainsQualifiedTravelAcrossRestart() {
        val initial = AdaptiveDayTimeZonePolicy.observe(
            AdaptiveDayTimeZoneState(),
            offsetSec = 0,
            nowSec = 1_000,
        )
        val dst = AdaptiveDayTimeZonePolicy.observe(initial, 60 * 60, 2_000)
        assertNull(dst.pending)

        val travel = AdaptiveDayTimeZonePolicy.observe(dst, 3 * 60 * 60, 3_000)
        assertEquals(60 * 60, travel.pending?.previousOffsetSec)
        assertEquals(3 * 60 * 60, travel.pending?.currentOffsetSec)

        val afterRestart = AdaptiveDayTimeZonePolicy.observe(
            AdaptiveDayTimeZoneState(
                currentOffsetSec = travel.currentOffsetSec,
                pending = travel.pending,
            ),
            offsetSec = 3 * 60 * 60,
            nowSec = 4_000,
        )
        assertEquals(travel.pending, afterRestart.pending)
    }

    @Test fun travelSuppressesWeakerAdaptiveFollowUpsForTheDay() {
        val travel = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(
                kind = AdaptiveDayDeliveryKind.TRAVEL,
                fingerprint = "travel-a",
            ),
            AdaptiveDayDeliveryState(),
            nowMillis,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertTrue(travel.shouldDeliver)

        val later = nowMillis + 31L * 60L * 1_000L
        val routine = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(
                kind = AdaptiveDayDeliveryKind.ROUTINE_RECOVERY,
                observedAtMillis = later,
                fingerprint = "routine-a",
            ),
            travel.nextState,
            later,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, routine.reason)

        val sleep = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(
                kind = AdaptiveDayDeliveryKind.SLEEP_RECOVERY,
                observedAtMillis = later,
                fingerprint = "sleep-a",
            ),
            travel.nextState,
            later,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, sleep.reason)

        val planned = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(
                kind = AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
                observedAtMillis = later,
                fingerprint = "planned-a",
            ),
            travel.nextState,
            later,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, planned.reason)
    }

    @Test fun plannedWorkoutSuppressesWeakerRoutineAndSleepPrompts() {
        val planned = AdaptiveDayDeliveryPolicy.evaluate(
            candidate(
                kind = AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
                fingerprint = "planned-a",
            ),
            AdaptiveDayDeliveryState(),
            nowMillis,
            12 * 60,
            false,
            22 * 60,
            7 * 60,
        )
        assertTrue(planned.shouldDeliver)

        val later = nowMillis + 31L * 60L * 1_000L
        listOf(
            AdaptiveDayDeliveryKind.ROUTINE_RECOVERY,
            AdaptiveDayDeliveryKind.SLEEP_RECOVERY,
        ).forEach { kind ->
            val result = AdaptiveDayDeliveryPolicy.evaluate(
                candidate(
                    kind = kind,
                    observedAtMillis = later,
                    fingerprint = "${kind.name}-a",
                ),
                planned.nextState,
                later,
                12 * 60,
                false,
                22 * 60,
                7 * 60,
            )
            assertEquals(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, result.reason)
        }
    }

    @Test fun recommendationMappingKeepsTheEvidenceIdentityAndTopic() {
        val recommendation = AdaptiveDayGuidance.Recommendation(
            kind = AdaptiveDayGuidance.Kind.ROUTINE_RECOVERY,
            observedAtSec = 1_700_000_000L,
            maximumAgeSeconds = 18 * 60 * 60,
            confidence = AdaptiveDayGuidance.Confidence.STRONG,
            fingerprint = "routine-window",
            evidence = listOf("personal-sleep-timing"),
        )

        val mapped = AdaptiveDayNotifier.candidate(recommendation)

        assertEquals(AdaptiveDayDeliveryKind.ROUTINE_RECOVERY, mapped.kind)
        assertEquals("routine-window", mapped.fingerprint)
        assertEquals(1_700_000_000_000L, mapped.observedAtMillis)
        assertFalse(mapped.maximumAgeMillis <= 0)
    }

    @Test fun plannedWorkoutEvidenceMatchesTheSupportingSignals() {
        assertEquals(
            listOf(
                R.string.daily_plan_workout_adjustment_title,
                R.string.daily_plan_workout_adjustment_sleep_label,
            ),
            AdaptiveDayNotifier.plannedWorkoutEvidenceResources(
                DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT,
            ),
        )
        assertEquals(
            listOf(
                R.string.daily_plan_workout_adjustment_title,
                R.string.daily_plan_evidence_readiness,
            ),
            AdaptiveDayNotifier.plannedWorkoutEvidenceResources(
                DailyActionPlanner.WorkoutAdjustmentReason.RECOVERY_SHIFT,
            ),
        )
        assertEquals(
            listOf(
                R.string.daily_plan_workout_adjustment_title,
                R.string.daily_plan_workout_adjustment_sleep_label,
                R.string.daily_plan_evidence_readiness,
            ),
            AdaptiveDayNotifier.plannedWorkoutEvidenceResources(
                DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_AND_RECOVERY,
            ),
        )
    }
}
