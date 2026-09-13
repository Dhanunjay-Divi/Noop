package com.noop.notif

import com.noop.R
import com.noop.analytics.AdaptiveDayGuidance
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ScoreConfidence
import com.noop.testing.FakeSharedPreferences
import java.io.File
import java.time.ZoneOffset
import java.time.ZonedDateTime
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
                routineHistoryStartSec = travel.routineHistoryStartSec,
            ),
            offsetSec = 3 * 60 * 60,
            nowSec = 4_000,
        )
        assertEquals(travel.pending, afterRestart.pending)
        assertEquals(3_000L, afterRestart.routineHistoryStartSec)
    }

    @Test fun operationalAccessResumeRebasesTimezoneWithoutReplayingBlockedTravel() {
        val pending = AdaptiveDayGuidance.TimeZoneChange(
            previousOffsetSec = 0,
            currentOffsetSec = 3 * 60 * 60,
            observedAtSec = 2_000,
        )
        val resumed = AdaptiveDayTimeZonePolicy.resumeAfterOperationalBlock(
            state = AdaptiveDayTimeZoneState(
                currentOffsetSec = 0,
                pending = pending,
            ),
            offsetSec = 5 * 60 * 60 + 30 * 60,
            nowSec = 2_500,
        )

        assertEquals(5 * 60 * 60 + 30 * 60, resumed.currentOffsetSec)
        assertNull(resumed.pending)
        assertEquals(2_500L, resumed.routineHistoryStartSec)
    }

    @Test fun operationalAccessResumePersistsRebaseAndConsumesItsMarkerOnce() {
        val prefs = FakeSharedPreferences()
        assertNull(AdaptiveDayTimeZoneStore.observe(prefs, offsetSec = 0, nowSec = 1_000))
        val blockedTravel = AdaptiveDayTimeZoneStore.observe(
            prefs,
            offsetSec = 3 * 60 * 60,
            nowSec = 2_000,
        )
        assertEquals(0, blockedTravel?.previousOffsetSec)
        assertTrue(AdaptiveDayTimeZoneStore.markOperationalAccessBlocked(prefs))

        val resumedOffset = 5 * 60 * 60 + 30 * 60
        assertEquals(
            AdaptiveDayOperationalResumeResult.REBASED,
            AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
                prefs,
                resumedOffset,
                nowSec = 2_500,
            ),
        )
        assertNull(
            AdaptiveDayTimeZoneStore.observe(
                prefs,
                offsetSec = resumedOffset,
                nowSec = 3_000,
            ),
        )
        assertEquals(
            AdaptiveDayOperationalResumeResult.NOT_REQUIRED,
            AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
                prefs,
                resumedOffset,
                nowSec = 3_000,
            ),
        )
        assertEquals(2_500L, AdaptiveDayTimeZoneStore.load(prefs).routineHistoryStartSec)

        val laterTravel = AdaptiveDayTimeZoneStore.observe(
            prefs,
            offsetSec = 8 * 60 * 60 + 30 * 60,
            nowSec = 4_000,
        )
        assertEquals(resumedOffset, laterTravel?.previousOffsetSec)
    }

    @Test fun operationalAccessResumeKeepsItsMarkerWhenRebasePersistenceFails() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false, true),
        )
        assertTrue(AdaptiveDayTimeZoneStore.markOperationalAccessBlocked(prefs))
        assertEquals(
            AdaptiveDayOperationalResumeResult.FAILED,
            AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
                prefs,
                offsetSec = 3_600,
                nowSec = 2_000,
            ),
        )
        assertEquals(
            AdaptiveDayOperationalResumeResult.REBASED,
            AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
                prefs,
                offsetSec = 3_600,
                nowSec = 2_100,
            ),
        )
        assertEquals(
            AdaptiveDayOperationalResumeResult.NOT_REQUIRED,
            AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
                prefs,
                offsetSec = 3_600,
                nowSec = 2_200,
            ),
        )
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

    @Test fun plannedWorkoutBoundaryAndActionLifetimeTrackTheWorkoutStart() {
        val startSec = nowMillis / 1_000L + 3L * 60L * 60L

        assertEquals(
            60L * 60L * 1_000L,
            AdaptivePlannedWorkoutSchedulePolicy.boundaryDelayMillis(
                startSec = startSec,
                nowMillis = nowMillis,
            ),
        )
        assertNull(
            AdaptivePlannedWorkoutSchedulePolicy.boundaryDelayMillis(
                startSec = nowMillis / 1_000L + 90L * 60L,
                nowMillis = nowMillis,
            ),
        )
        assertEquals(
            20L * 60L * 1_000L,
            AdaptivePlannedWorkoutSchedulePolicy.retryDelayMillis(
                startSec = nowMillis / 1_000L + 60L * 60L,
                retryAtMillis = nowMillis + 20L * 60L * 1_000L,
                nowMillis = nowMillis,
            ),
        )
        assertNull(
            AdaptivePlannedWorkoutSchedulePolicy.retryDelayMillis(
                startSec = nowMillis / 1_000L + 20L * 60L,
                retryAtMillis = nowMillis + 20L * 60L * 1_000L,
                nowMillis = nowMillis,
            ),
        )
        assertEquals(
            15L * 60L * 1_000L,
            AdaptiveDayNotifier.plannedWorkoutMaximumAgeMillis(
                startSec = nowMillis / 1_000L + 15L * 60L,
                observedAtMillis = nowMillis,
            ),
        )
    }

    @Test fun plannedWorkoutRetriesAfterTransientCooldownAndQuietHours() {
        val boundary = ZonedDateTime.of(2026, 8, 23, 6, 0, 0, 0, ZoneOffset.UTC)
        val start = boundary.plusHours(2)
        val planned = AdaptiveDayDeliveryCandidate(
            kind = AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
            observedAtMillis = boundary.toInstant().toEpochMilli(),
            maximumAgeMillis = 2L * 60L * 60L * 1_000L,
            fingerprint = "planned-a",
        )
        val state = AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = boundary.minusMinutes(10).toInstant().toEpochMilli(),
        )

        assertEquals(
            boundary.plusHours(1).toInstant().toEpochMilli(),
            AdaptiveDayDeliveryPolicy.nextEligibleAtMillis(
                candidate = planned,
                state = state,
                notBefore = boundary,
                quietHoursEnabled = true,
                quietStartMinutes = 22 * 60,
                quietEndMinutes = 7 * 60,
            ),
        )
        assertNull(
            AdaptiveDayDeliveryPolicy.nextEligibleAtMillis(
                candidate = planned,
                state = AdaptiveDayDeliveryState(
                    lastGlobalDeliveryMillis = boundary.toInstant().toEpochMilli(),
                    deliveries = mapOf(
                        AdaptiveDayDeliveryKind.PLANNED_WORKOUT to AdaptiveDayDelivery(
                            boundary.toInstant().toEpochMilli(),
                            "planned-a",
                        ),
                    ),
                ),
                notBefore = boundary,
                quietHoursEnabled = false,
                quietStartMinutes = 22 * 60,
                quietEndMinutes = 7 * 60,
            ),
        )
        assertEquals(start.toInstant().toEpochMilli(), planned.observedAtMillis + planned.maximumAgeMillis)
    }

    @Test fun adaptiveNotificationExpiresAtItsEvidenceBoundaryFromActualPostTime() {
        assertEquals(
            4_000L,
            AdaptiveDayNotifier.remainingLifetimeMillis(
                observedAtMillis = 1_000L,
                maximumAgeMillis = 10_000L,
                postAtMillis = 7_000L,
            ),
        )
        assertNull(
            AdaptiveDayNotifier.remainingLifetimeMillis(
                observedAtMillis = 1_000L,
                maximumAgeMillis = 10_000L,
                postAtMillis = 11_000L,
            ),
        )

        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val remaining = text.indexOf("val notificationTimeoutMillis = remainingLifetimeMillis(")
        val builder = text.indexOf("val notificationBuilder = NotificationCompat.Builder")
        val timeout = text.indexOf(
            "notificationBuilder.setTimeoutAfter(notificationTimeoutMillis)",
            builder,
        )
        val build = text.indexOf("val notification = notificationBuilder.build()", timeout)

        assertTrue(remaining >= 0)
        assertTrue(
            text.substring(remaining, builder)
                .contains("postAtMillis = System.currentTimeMillis()"),
        )
        assertTrue(builder >= 0)
        assertTrue(timeout > builder)
        assertTrue(build > timeout)
        assertFalse(text.substring(builder, timeout).contains("candidate.maximumAgeMillis"))
        assertFalse(
            text.substring(remaining, builder)
                .contains("candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT"),
        )
    }

    @Test fun movingWorkoutWithinThirtyMinutesChangesItsFingerprint() {
        val first = DailyActionPlanner.WorkoutAdjustment(
            startSec = nowMillis / 1_000L + 60L * 60L,
            durationMinutes = 60,
            reason = DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT,
            measuredSleepMinutes = 372,
            referenceSleepMinutes = 450,
            sleepDeficitMinutes = 78,
            sleepReference = DailyActionPlanner.SleepReference.PERSONAL_USUAL,
            confidence = ScoreConfidence.SOLID,
        )

        assertFalse(
            AdaptiveDayNotifier.plannedWorkoutFingerprint("2026-08-22", first) ==
                AdaptiveDayNotifier.plannedWorkoutFingerprint(
                    "2026-08-22",
                    first.copy(startSec = first.startSec + 5L * 60L),
                ),
        )
    }

    @Test fun changingWorkoutEvidenceKeepsTheSameFingerprint() {
        val first = DailyActionPlanner.WorkoutAdjustment(
            startSec = nowMillis / 1_000L + 60L * 60L,
            durationMinutes = 60,
            reason = DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT,
            measuredSleepMinutes = 372,
            referenceSleepMinutes = 450,
            sleepDeficitMinutes = 78,
            sleepReference = DailyActionPlanner.SleepReference.PERSONAL_USUAL,
            confidence = ScoreConfidence.SOLID,
        )

        assertEquals(
            AdaptiveDayNotifier.plannedWorkoutFingerprint("2026-08-22", first),
            AdaptiveDayNotifier.plannedWorkoutFingerprint(
                "2026-08-22",
                first.copy(
                    reason = DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_AND_RECOVERY,
                ),
            ),
        )
    }

    @Test fun plannedWorkoutFingerprintExposesOnlyItsBoundedStartTimestamp() {
        assertEquals(
            1_700_000_123L,
            AdaptiveDayNotifier.plannedWorkoutStartSec(
                "planned-workout|2026-08-22|1700000123",
            ),
        )
        assertEquals(
            1_700_000_123L,
            AdaptiveDayNotifier.plannedWorkoutStartSec(
                "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT",
            ),
        )
        assertNull(
            AdaptiveDayNotifier.plannedWorkoutStartSec(
                "planned-workout|2026-08-22|not-a-date|SLEEP_DEFICIT",
            ),
        )
        assertNull(
            AdaptiveDayNotifier.plannedWorkoutStartSec(
                "other|2026-08-22|1700000123|SLEEP_DEFICIT",
            ),
        )
    }

    @Test fun legacyWorkoutIdentityMigratesWithoutDroppingCooldownHistory() {
        val legacy = "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT"
        val current = "planned-workout|2026-08-22|1700000123"
        val state = AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                    AdaptiveDayDelivery(2_000L, legacy),
            ),
        )

        val migrated = AdaptiveDayNotifier.reconciledPlannedWorkoutState(
            state,
            currentFingerprint = current,
        )

        assertEquals(2_000L, migrated.lastGlobalDeliveryMillis)
        assertEquals(
            AdaptiveDayDelivery(2_000L, current),
            migrated.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT],
        )
        assertTrue(AdaptiveDayNotifier.plannedWorkoutFingerprintsMatch(legacy, current))
        assertFalse(
            AdaptiveDayNotifier.plannedWorkoutFingerprintsMatch(
                legacy,
                "planned-workout|2026-08-23|1700000123",
            ),
        )
        assertFalse(
            AdaptiveDayNotifier.plannedWorkoutFingerprintsMatch(
                "malformed-a",
                "malformed-b",
            ),
        )
    }

    @Test fun plannedWorkoutReconciliationMigratesActionBeforeRemovingStaleIds() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull { it.exists() }?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val method = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts"),
            text.indexOf("private fun cancelAdaptiveDayNotification"),
        )
        val migration = method.indexOf("ContextualActionCenter.migrateRecoveryAction")
        val reconciliation = method.indexOf(
            "ContextualActionCenter.reconcileRecoveryActions",
            migration,
        )

        assertTrue(migration >= 0)
        assertTrue(reconciliation > migration)
        assertTrue(method.contains("toFingerprint = currentFingerprint"))
        assertTrue(method.contains("plannedWorkoutFingerprintsMatch(it, currentFingerprint)"))
        assertTrue(method.contains("keepingFingerprint = currentFingerprint"))
    }

    @Test fun timeZoneBroadcastRetractsWorkoutArtifactsBeforeTravelDelivery() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull { it.exists() }?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val method = text.substring(
            text.indexOf("fun onTimeZoneChanged("),
            text.indexOf("fun prepareAndCanNotify("),
        )
        val terms = method.indexOf(
            "ManagedRuntimeGate.isAuthorized(context.applicationContext)",
        )
        val observe = method.indexOf("AdaptiveDayTimeZoneStore.observe(")
        val invalidate = method.indexOf("AdaptiveDayEvaluationGate.invalidate()")
        val cancel = method.indexOf(
            "AdaptivePlannedWorkoutScheduler.cancelBoundary(context)",
            invalidate,
        )
        val reconcile = method.indexOf("reconcilePlannedWorkoutArtifacts(", cancel)
        val post = method.indexOf("onRecommendation(context, it)")

        assertTrue(terms >= 0)
        assertTrue(observe > terms)
        assertTrue(invalidate > observe)
        assertTrue(cancel > invalidate)
        assertTrue(reconcile > cancel)
        assertTrue(method.contains("currentFingerprint = null"))
        assertTrue(post > reconcile)
    }

    @Test fun stalePlannedWorkoutDeliveryIsRemovedAndGlobalCooldownRecomputed() {
        val state = AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                AdaptiveDayDeliveryKind.SLEEP_RECOVERY to
                    AdaptiveDayDelivery(1_000L, "sleep-a"),
                AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                    AdaptiveDayDelivery(2_000L, "planned-a"),
            ),
        )

        val reconciled = AdaptiveDayNotifier.reconciledPlannedWorkoutState(
            state,
            currentFingerprint = null,
        )

        assertFalse(
            reconciled.deliveries.containsKey(AdaptiveDayDeliveryKind.PLANNED_WORKOUT),
        )
        assertEquals(1_000L, reconciled.lastGlobalDeliveryMillis)
        assertEquals(
            state,
            AdaptiveDayNotifier.reconciledPlannedWorkoutState(
                state,
                currentFingerprint = "planned-a",
            ),
        )
    }

    @Test fun acceptedDeliveryUsesTheDurableReceiptTimestamp() {
        val accepted = AdaptiveDayNotifier.acceptedDeliveryState(
            state = AdaptiveDayDeliveryState(
                lastGlobalDeliveryMillis = 3_000L,
                deliveries = mapOf(
                    AdaptiveDayDeliveryKind.TRAVEL to
                        AdaptiveDayDelivery(3_000L, "travel-a"),
                ),
            ),
            candidate = candidate(
                kind = AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
                fingerprint = "planned-workout|2026-09-10|1789074000",
            ),
            acceptedAtMillis = 2_000L,
        )

        assertEquals(3_000L, accepted.lastGlobalDeliveryMillis)
        assertEquals(
            AdaptiveDayDelivery(
                2_000L,
                "planned-workout|2026-09-10|1789074000",
            ),
            accepted.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT],
        )
    }

    @Test fun sharedPromptLedgerRestoresThePreviousOwnerWhenPlannedWorkoutIsRetracted() {
        val state = ContextualPromptDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                ContextualPromptDeliveryOwner.VITAL_REVIEW to 1_000L,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT to 2_000L,
            ),
        )

        assertEquals(
            ContextualPromptDeliveryState(
                lastGlobalDeliveryMillis = 1_000L,
                deliveries = mapOf(ContextualPromptDeliveryOwner.VITAL_REVIEW to 1_000L),
            ),
            ContextualPromptDeliveryLedger.reconciledState(
                state,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                expectedAtMillis = 2_000L,
            ),
        )
        assertEquals(
            state,
            ContextualPromptDeliveryLedger.reconciledState(
                state,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                expectedAtMillis = 1_500L,
            ),
        )
    }

    @Test fun sharedPromptLedgerPersistsAndRemovesTheExactWorkoutIdentityAtomically() {
        val fingerprint = "planned-workout|2026-09-10|1789074000"
        val recorded = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = fingerprint,
        )
        assertEquals(
            ContextualPromptDeliveryReceipt(2_000L, fingerprint),
            ContextualPromptDeliveryLedger.deliveryReceipt(
                recorded,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            ),
        )

        val prefs = FakeSharedPreferences()
        ContextualPromptDeliveryLedger.saveState(prefs, recorded)
        assertEquals(recorded, ContextualPromptDeliveryLedger.loadState(prefs))

        val reconciled = ContextualPromptDeliveryLedger.reconciledState(
            recorded,
            ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 2_000L,
        )
        assertFalse(reconciled.deliveries.containsKey(ContextualPromptDeliveryOwner.PLANNED_WORKOUT))
        assertFalse(reconciled.identities.containsKey(ContextualPromptDeliveryOwner.PLANNED_WORKOUT))
    }

    @Test fun sharedPromptLedgerCanReconcileALegacyUnownedPlannedWorkoutTimestamp() {
        assertEquals(
            ContextualPromptDeliveryState(),
            ContextualPromptDeliveryLedger.reconciledState(
                ContextualPromptDeliveryState(lastGlobalDeliveryMillis = 2_000L),
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                expectedAtMillis = 2_000L,
            ),
        )
    }

    @Test fun sharedPromptLedgerCanForceRemoveARecordedPlannedWorkoutOwner() {
        val state = ContextualPromptDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                ContextualPromptDeliveryOwner.VITAL_REVIEW to 1_000L,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT to 2_000L,
            ),
        )

        assertEquals(
            ContextualPromptDeliveryState(
                lastGlobalDeliveryMillis = 1_000L,
                deliveries = mapOf(ContextualPromptDeliveryOwner.VITAL_REVIEW to 1_000L),
            ),
            ContextualPromptDeliveryLedger.reconciledOwnerState(
                state,
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            ),
        )
    }

    @Test fun orphanedPlannedWorkoutOwnerReportsWhetherItOwnsItsNotificationSlot() {
        val orphanedLatest = ContextualPromptDeliveryLedger.ownerReconciliation(
            ContextualPromptDeliveryState(
                lastGlobalDeliveryMillis = 2_000L,
                deliveries = mapOf(
                    ContextualPromptDeliveryOwner.VITAL_REVIEW to 1_000L,
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT to 2_000L,
                ),
            ),
            ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        )
        assertTrue(orphanedLatest.ownerRemoved)
        assertTrue(orphanedLatest.ownedNotificationSlot)
        assertEquals(1_000L, orphanedLatest.nextState.lastGlobalDeliveryMillis)

        val supersededInSameSlot = ContextualPromptDeliveryLedger.ownerReconciliation(
            ContextualPromptDeliveryState(
                lastGlobalDeliveryMillis = 3_000L,
                deliveries = mapOf(
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT to 2_000L,
                    ContextualPromptDeliveryOwner.ADAPTIVE_DAY to 3_000L,
                ),
            ),
            ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        )
        assertTrue(supersededInSameSlot.ownerRemoved)
        assertFalse(supersededInSameSlot.ownedNotificationSlot)
        assertEquals(3_000L, supersededInSameSlot.nextState.lastGlobalDeliveryMillis)
        assertEquals(
            mapOf(ContextualPromptDeliveryOwner.ADAPTIVE_DAY to 3_000L),
            supersededInSameSlot.nextState.deliveries,
        )

        val newerDifferentSlot = ContextualPromptDeliveryLedger.ownerReconciliation(
            ContextualPromptDeliveryState(
                lastGlobalDeliveryMillis = 3_000L,
                deliveries = mapOf(
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT to 2_000L,
                    ContextualPromptDeliveryOwner.VITAL_REVIEW to 3_000L,
                ),
            ),
            ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        )
        assertTrue(newerDifferentSlot.ownerRemoved)
        assertTrue(newerDifferentSlot.ownedNotificationSlot)
        assertEquals(3_000L, newerDifferentSlot.nextState.lastGlobalDeliveryMillis)
        assertEquals(
            mapOf(ContextualPromptDeliveryOwner.VITAL_REVIEW to 3_000L),
            newerDifferentSlot.nextState.deliveries,
        )
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

    @Test fun routedPendingIntentIsCreatedOnlyInsideApprovedPostCallback() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val postGate = text.indexOf("ContextualPromptDeliveryLedger.postIfAllowed")
        val pendingIntent = text.indexOf(
            "NotificationPlatformIdentity.activityPendingIntent",
            postGate,
        )
        val notificationPost = text.indexOf("NotificationLifecycleLedger.posted", postGate)

        assertTrue(postGate >= 0)
        assertTrue(pendingIntent > postGate)
        assertTrue(notificationPost > pendingIntent)
    }

    @Test fun plannedWorkoutDeliveryRechecksCalendarConsentAtThePostBoundary() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val postCandidate = text.indexOf("private fun postCandidate(")
        val postGate = text.indexOf("ContextualPromptDeliveryLedger.postIfAllowed", postCandidate)
        val pendingIntent = text.indexOf(
            "NotificationPlatformIdentity.activityPendingIntent",
            postGate,
        )
        val action = text.indexOf("ContextualActionCenter.presentRecovery", pendingIntent)
        val helper = text.indexOf("private fun plannedWorkoutDeliveryCurrent")

        assertTrue(postCandidate >= 0)
        assertTrue(postGate > postCandidate)
        assertTrue(pendingIntent > postGate)
        assertTrue(action > pendingIntent)
        assertTrue(
            text.substring(postCandidate, postGate)
                .contains("plannedWorkoutDeliveryCurrent(context, candidate)"),
        )
        assertTrue(
            text.substring(postGate, pendingIntent)
                .contains("plannedWorkoutDeliveryCurrent(context, candidate)"),
        )
        assertTrue(
            text.substring(pendingIntent, action)
                .contains("plannedWorkoutDeliveryCurrent(context, candidate)"),
        )
        assertTrue(helper > action)
        assertTrue(
            text.substring(helper)
                .contains("Manifest.permission.READ_CALENDAR"),
        )
        assertTrue(
            text.substring(helper)
                .contains("AdaptiveDayConsentGate.plannedWorkoutCalendar(context)"),
        )
        assertTrue(
            text.substring(helper)
                .contains("AdaptiveDayConsentGate.guidance(context)"),
        )
        assertTrue(
            text.substring(helper)
                .contains("AdaptiveDayEvaluationGate.isCurrent(evaluationToken)"),
        )
        assertTrue(
            text.substring(helper)
                .contains("PlannedWorkoutCalendarStore.isCurrentRevision(calendarRevision)"),
        )
    }

    @Test fun consentLossAfterPostingReleasesThePlannedWorkoutPromptOwner() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val postCandidate = text.indexOf("private fun postCandidate(")
        val deliveryNow = text.indexOf(
            "val deliveryNow = ZonedDateTime.now()",
            postCandidate,
        )
        val deliveryAt = text.indexOf(
            "val deliveryAtMillis = deliveryNow.toInstant().toEpochMilli()",
            deliveryNow,
        )
        val postGate = text.indexOf("ContextualPromptDeliveryLedger.postIfAllowed", deliveryAt)
        val postedResult = text.indexOf(
            "if (postResult.status != ContextualPromptPostStatus.ACCEPTED)",
            postGate,
        )
        val acceptedReceipt = text.indexOf("val acceptedReceipt = postResult.receipt", postedResult)
        val postSuccessConsent = text.indexOf(
            "!plannedWorkoutDeliveryCurrent(context, candidate)",
            acceptedReceipt,
        )
        val reconcile = text.indexOf(
            "ContextualPromptDeliveryLedger.reconcileIfOwned(",
            postSuccessConsent,
        )
        val expectedTimestamp = text.indexOf(
            "expectedAtMillis = acceptedReceipt.atMillis",
            reconcile,
        )
        val cancellation = text.indexOf(
            "NotificationLifecycleLedger.cancelled(",
            expectedTimestamp,
        )

        assertTrue(deliveryNow > postCandidate)
        assertTrue(deliveryAt > deliveryNow)
        assertTrue(postGate > deliveryAt)
        assertTrue(postedResult > postGate)
        assertTrue(acceptedReceipt > postedResult)
        assertTrue(postSuccessConsent > acceptedReceipt)
        assertTrue(reconcile > postSuccessConsent)
        assertTrue(expectedTimestamp > reconcile)
        assertTrue(cancellation > expectedTimestamp)
    }

    @Test fun deliveryPolicyUsesTheActualPostBoundaryClock() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val postCandidate = text.indexOf("private fun postCandidate(")
        val deliveryNow = text.indexOf("val deliveryNow = ZonedDateTime.now()", postCandidate)
        val policy = text.indexOf("AdaptiveDayDeliveryPolicy.evaluate(", deliveryNow)
        val postGate = text.indexOf("ContextualPromptDeliveryLedger.postIfAllowed", policy)
        val postSource = text.substring(postCandidate, postGate)

        assertTrue(deliveryNow > postCandidate)
        assertTrue(policy > deliveryNow)
        assertTrue(postGate > policy)
        assertTrue(postSource.contains("localMinuteOfDay = deliveryNow.hour"))
        assertTrue(postSource.contains("notBefore = deliveryNow"))
        assertFalse(postSource.contains("deliveryAtMillis = now.toInstant()"))
    }

    @Test fun scheduledWorkoutSuppressesWeakerAdaptiveGuidance() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val evaluator = text.indexOf("object AdaptiveDayEvaluator")
        val notifier = text.indexOf("object AdaptiveDayNotifier", evaluator)
        val evaluatorSource = text.substring(evaluator, notifier)
        val scheduled = evaluatorSource.indexOf(
            "val scheduled = AdaptivePlannedWorkoutScheduler.schedule",
        )
        val priorityReturn = evaluatorSource.indexOf(
            "if (scheduled) return@commitIfCurrent true",
            scheduled,
        )
        val weakerRecommendation = evaluatorSource.indexOf(
            "recommendation?.let",
            priorityReturn,
        )

        assertTrue(scheduled >= 0)
        assertTrue(priorityReturn > scheduled)
        assertTrue(weakerRecommendation > priorityReturn)
    }

    @Test fun plannedWorkoutWorkerResolvesThePersistedActiveDeviceBeforeEvaluation() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val worker = text.indexOf("class AdaptivePlannedWorkoutWorker")
        val registry = text.indexOf("deviceRegistry?.activeDeviceId()", worker)
        val evaluate = text.indexOf("AdaptiveDayEvaluator.evaluateAndNotify", worker)

        assertTrue(worker >= 0)
        assertTrue(registry > worker)
        assertTrue(evaluate > registry)
    }

    @Test fun plannedWorkoutWorkerRequiresCurrentTermsBeforeDiagnosticsOrDataAccess() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val worker = text.indexOf("class AdaptivePlannedWorkoutWorker")
        val terms = text.indexOf("ManagedRuntimeGate.isAuthorized(applicationContext)", worker)
        val diagnostic = text.indexOf("AppDiagnosticsRecorder.beginOperation", worker)
        val repository = text.indexOf("WhoopRepository.from(applicationContext)", worker)

        assertTrue(worker >= 0)
        assertTrue(terms > worker)
        assertTrue(diagnostic > terms)
        assertTrue(repository > diagnostic)
    }

    @Test fun calendarFailureRetryIsBoundedAndStopsAtWorkoutStart() {
        assertTrue(
            AdaptivePlannedWorkoutSchedulePolicy.shouldRetryCalendarFailure(
                expectedStartSec = 2_000,
                nowSec = 1_000,
                runAttemptCount = 0,
            ),
        )
        assertFalse(
            AdaptivePlannedWorkoutSchedulePolicy.shouldRetryCalendarFailure(
                expectedStartSec = 1_000,
                nowSec = 1_000,
                runAttemptCount = 0,
            ),
        )
        assertFalse(
            AdaptivePlannedWorkoutSchedulePolicy.shouldRetryCalendarFailure(
                expectedStartSec = 2_000,
                nowSec = 1_000,
                runAttemptCount =
                    AdaptivePlannedWorkoutSchedulePolicy.MAX_CALENDAR_RETRY_ATTEMPTS,
            ),
        )
    }

    @Test fun adaptiveEvaluatorRequiresCurrentTermsBeforeStateOrDataAccess() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val evaluator = text.indexOf("object AdaptiveDayEvaluator")
        val notifier = text.indexOf("object AdaptiveDayNotifier", evaluator)
        val evaluatorSource = text.substring(evaluator, notifier)
        val terms = evaluatorSource.indexOf("ManagedRuntimeGate.isAuthorized(appContext)")
        val generation = evaluatorSource.indexOf("AdaptiveDayEvaluationGate.begin()")
        val timeZone = evaluatorSource.indexOf("AdaptiveDayTimeZoneStore.observe(")
        val repository = evaluatorSource.indexOf("repository.daysMerged(")
        val calendar = evaluatorSource.indexOf("PlannedWorkoutCalendarStore.refresh(")

        assertTrue(terms >= 0)
        assertTrue(generation > terms)
        assertTrue(timeZone > generation)
        assertTrue(repository > timeZone)
        assertTrue(calendar > repository)
    }

    @Test fun failedCalendarRefreshPreservesWorkoutAndStillDeliversIndependentGuidance() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val evaluator = text.indexOf("object AdaptiveDayEvaluator")
        val notifier = text.indexOf("object AdaptiveDayNotifier", evaluator)
        val evaluatorSource = text.substring(evaluator, notifier)
        val refresh = evaluatorSource.indexOf("val calendarRefresh")
        val failure = evaluatorSource.indexOf(
            "PlannedWorkoutCalendarRefreshOutcome.Failed",
            refresh,
        )
        val delivery = evaluatorSource.indexOf(
            "AdaptiveDayNotifier.onRecommendation(",
            failure,
        )
        val retry = evaluatorSource.indexOf(
            "throw AdaptiveDayCalendarRefreshRetry()",
            delivery,
        )
        val abort = evaluatorSource.indexOf("return recommendation", retry)
        val plan = evaluatorSource.indexOf("val plan = DailyActionPlanner.plan", abort)
        val reconcileMissing = evaluatorSource.indexOf(
            "reconcileMissingPlannedWorkoutArtifacts",
            plan,
        )

        assertTrue(refresh >= 0)
        assertTrue(failure > refresh)
        assertTrue(delivery > failure)
        assertTrue(retry > delivery)
        assertTrue(abort > retry)
        assertTrue(plan > abort)
        assertTrue(reconcileMissing > plan)
    }

    @Test fun plannedWorkoutSchedulerWatchesCalendarChangesWhileAppIsInactive() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val watcher = text.indexOf("fun scheduleCalendarChangeWatcher(")
        val uriTrigger = text.indexOf(
            "addContentUriTrigger(CalendarContract.Events.CONTENT_URI, true)",
            watcher,
        )
        val uniqueWork = text.indexOf("CALENDAR_WATCH_WORK_NAME", uriTrigger)
        val evaluatorStart = text.indexOf("object AdaptiveDayEvaluator")
        val evaluator = text.indexOf(
            "AdaptivePlannedWorkoutScheduler.scheduleCalendarChangeWatcher(",
            evaluatorStart,
        )
        val refresh = text.indexOf(
            "val calendarRefresh = PlannedWorkoutCalendarStore.refresh(",
            evaluatorStart,
        )
        val plan = text.indexOf(
            "val plan = DailyActionPlanner.plan(",
            evaluatorStart,
        )
        val noAdjustment = text.indexOf(
            "AdaptivePlannedWorkoutScheduler.cancelBoundary(appContext)",
            plan,
        )
        val worker = text.indexOf("class AdaptivePlannedWorkoutWorker")
        val contentTrigger = text.indexOf(
            "CALENDAR_CHANGE_TRIGGER_KEY",
            worker,
        )
        val invalidate = text.indexOf(
            "PlannedWorkoutCalendarStore.invalidate()",
            contentTrigger,
        )

        assertTrue(watcher >= 0)
        assertTrue(uriTrigger > watcher)
        assertTrue(uniqueWork > uriTrigger)
        assertTrue(evaluator > uniqueWork)
        assertTrue(refresh > evaluator)
        assertTrue(plan > refresh)
        assertTrue(noAdjustment > plan)
        assertTrue(contentTrigger > worker)
        assertTrue(invalidate > contentTrigger)
        assertTrue(
            text.substring(plan, noAdjustment + 80)
                .contains("AdaptivePlannedWorkoutScheduler.cancelBoundary(appContext)"),
        )
    }

    @Test fun termsLockedStartupRebasesTimezoneBeforeOperationalWorkResumes() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/NoopApplication.kt"),
            File(root, "app/src/main/java/com/noop/NoopApplication.kt"),
            File(root, "android/app/src/main/java/com/noop/NoopApplication.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate NoopApplication.kt from $root" }
        val onCreate = text.substring(
            text.indexOf("override fun onCreate()"),
            text.indexOf("fun startOperationalRuntime()"),
        )
        val start = text.substring(
            text.indexOf("fun startOperationalRuntime()"),
            text.indexOf("private fun hasAcceptedCurrentTerms()"),
        )

        assertTrue(onCreate.contains("AdaptiveDayTimeZoneStore.markOperationalAccessBlocked(this)"))
        val rebase = start.indexOf("AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(")
        val failedClosed = start.indexOf("AdaptiveDayOperationalResumeResult.FAILED", rebase)
        val runtimeClaim = start.indexOf("operationalRuntime.compareAndSet(false, true)", failedClosed)
        val runtimeEvent = start.indexOf("AppDiagnosticsRecorder.record(\"runtime.operational_started\")")
        assertTrue(rebase >= 0)
        assertTrue(failedClosed > rebase)
        assertTrue(runtimeClaim > failedClosed)
        assertTrue(runtimeEvent > rebase)
        assertTrue(start.contains("\"rebased_after_operational_block\""))
        assertTrue(start.contains("\"operational_resume_failed_closed\""))
    }

    @Test fun termsAcceptancePersistsTheBlockedMarkerBeforeClickwrapAndRuntimeStartup() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/ui/MainActivity.kt"),
            File(root, "app/src/main/java/com/noop/ui/MainActivity.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/MainActivity.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate MainActivity.kt from $root" }
        val terms = text.substring(
            text.indexOf("TermsGateScreen(onAccept = {"),
            text.indexOf("var onboarded by remember"),
        )
        val marker = terms.indexOf("AdaptiveDayTimeZoneStore.markOperationalAccessBlocked")
        val clickwrap = terms.indexOf("NoopPrefs.KEY_ACCEPTED_TERMS_VERSION")
        val startup = terms.indexOf("application.startOperationalRuntime()")
        val exposeAccepted = terms.indexOf("acceptedTerms = Terms.CURRENT_VERSION")

        assertTrue(marker >= 0)
        assertTrue(clickwrap > marker)
        assertTrue(startup > clickwrap)
        assertTrue(exposeAccepted > startup)
        assertTrue(terms.contains("if (application.operationalRuntimeStarted)"))
    }

    @Test fun newerAdaptiveEvaluationInvalidatesEveryOlderDeliveryToken() {
        val first = AdaptiveDayEvaluationGate.begin()
        assertTrue(AdaptiveDayEvaluationGate.isCurrent(first))

        val second = AdaptiveDayEvaluationGate.begin()
        assertFalse(AdaptiveDayEvaluationGate.isCurrent(first))
        assertTrue(AdaptiveDayEvaluationGate.isCurrent(second))

        AdaptiveDayEvaluationGate.invalidate()
        assertFalse(AdaptiveDayEvaluationGate.isCurrent(second))
    }

    @Test fun adaptiveEvaluationReconcilesRemovedWorkoutAndDeliveryStateCanDeleteKeys() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val evaluator = text.indexOf("object AdaptiveDayEvaluator")
        val notifier = text.indexOf("object AdaptiveDayNotifier", evaluator)
        val evaluatorSource = text.substring(evaluator, notifier)
        val saveState = text.indexOf("private fun saveState")

        assertTrue(evaluatorSource.contains("reconcileMissingPlannedWorkoutArtifacts"))
        assertTrue(evaluatorSource.contains("nowSec = nowSec"))
        assertTrue(evaluatorSource.contains("if (leadSeconds <= 0L)"))
        assertTrue(saveState >= 0)
        assertTrue(text.substring(saveState).contains(".clear()"))
    }

    @Test fun naturalWorkoutExpiryPreservesCooldownLedgersAndTransientSuppressionRetries() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val evaluator = text.indexOf("object AdaptiveDayEvaluator")
        val notifier = text.indexOf("object AdaptiveDayNotifier", evaluator)
        val evaluatorSource = text.substring(evaluator, notifier)
        val postCandidate = text.indexOf("private fun postCandidate(")
        val deliveryCurrent = text.indexOf("private fun plannedWorkoutDeliveryCurrent", postCandidate)
        val postSource = text.substring(postCandidate, deliveryCurrent)
        val expire = text.indexOf("internal fun expirePlannedWorkoutArtifacts(")
        val reconcileMissing = text.indexOf(
            "internal fun reconcileMissingPlannedWorkoutArtifacts(",
            expire,
        )
        val reconcile = text.indexOf(
            "internal fun reconcilePlannedWorkoutArtifacts(",
            reconcileMissing,
        )
        val expireSource = text.substring(expire, reconcileMissing)
        val missingSource = text.substring(reconcileMissing, reconcile)

        assertTrue(evaluatorSource.contains("expirePlannedWorkoutArtifacts("))
        assertTrue(postSource.contains("AdaptiveDayDeliveryPolicy.nextEligibleAtMillis("))
        assertTrue(postSource.contains("ContextualPromptDeliveryLedger.nextAllowedAtMillis("))
        assertTrue(postSource.contains("schedulePlannedWorkoutRetry("))
        assertTrue(expire >= 0)
        assertFalse(expireSource.contains("ContextualPromptDeliveryLedger.reconcile"))
        assertFalse(expireSource.contains("saveState("))
        assertTrue(expireSource.contains("plannedWorkoutFingerprintsMatch("))
        assertTrue(expireSource.contains("cancelNotificationSlotIfOwned("))
        assertTrue(missingSource.contains("plannedWorkoutStartSec(prior.fingerprint)"))
        assertTrue(missingSource.contains("expirePlannedWorkoutArtifacts"))
        assertTrue(missingSource.contains("reconcilePlannedWorkoutArtifacts"))
    }

    @Test fun missingWorkoutReconcilesOnlyTheOwnedNotificationSlot() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val reconcile = text.indexOf("internal fun reconcilePlannedWorkoutArtifacts(")
        val cancel = text.indexOf("private fun cancelAdaptiveDayNotification(", reconcile)
        val reconcileSource = text.substring(reconcile, cancel)

        assertTrue(reconcileSource.contains("reconcileOwnerWithOutcome("))
        assertTrue(reconcileSource.contains("onNotificationSlotOwnerRemoved = {"))
        assertTrue(reconcileSource.contains("currentFingerprint = null"))
        assertTrue(reconcileSource.contains("cancelNotificationSlotIfUnowned("))
        assertTrue(reconcileSource.contains("hasPendingCancellation("))
        val unownedCancellation = reconcileSource.indexOf("cancelNotificationSlotIfUnowned(")
        val privateCleanup = reconcileSource.indexOf(
            "val cleared = plannedWorkoutStateAfterReconciliation(",
            startIndex = unownedCancellation,
        )
        assertTrue(privateCleanup > unownedCancellation)
    }

    @Test fun failedSharedOrNotificationCleanupRetainsPrivateWorkoutRetryEvidence() {
        val state = AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                    AdaptiveDayDelivery(
                        atMillis = 2_000L,
                        fingerprint = "planned-workout|2026-09-11|1789160400",
                    ),
            ),
        )

        assertNull(
            AdaptiveDayNotifier.plannedWorkoutStateAfterReconciliation(
                state = state,
                currentFingerprint = null,
                sharedStateCommitted = false,
                notificationHandled = true,
            ),
        )
        assertNull(
            AdaptiveDayNotifier.plannedWorkoutStateAfterReconciliation(
                state = state,
                currentFingerprint = null,
                sharedStateCommitted = true,
                notificationHandled = false,
            ),
        )
        assertEquals(
            AdaptiveDayDeliveryState(),
            AdaptiveDayNotifier.plannedWorkoutStateAfterReconciliation(
                state = state,
                currentFingerprint = null,
                sharedStateCommitted = true,
                notificationHandled = true,
            ),
        )

        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val reconcile = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
            text.indexOf("internal fun restoredPlannedWorkoutState("),
        )
        val notificationHandled = reconcile.indexOf("val notificationHandled = when")
        val gatedState = reconcile.indexOf(
            "plannedWorkoutStateAfterReconciliation(",
            notificationHandled,
        )
        val privateSave = reconcile.indexOf("saveState(app, cleared)", gatedState)

        assertTrue(notificationHandled >= 0)
        assertTrue(gatedState > notificationHandled)
        assertTrue(privateSave > gatedState)
    }

    @Test fun forceCleanupUsesPrivacyFirstSlotCancellationAndReturnsBeforeNormalReconciliation() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val reconcile = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
            text.indexOf("internal fun restoredPlannedWorkoutState("),
        )
        val forceBranch = reconcile.indexOf("if (forceCancelSharedNotification)")
        val forceCancellation = reconcile.indexOf("completeGuidanceCleanup(app)", forceBranch)
        val normalOwnerReconciliation = reconcile.indexOf(
            "ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(",
            forceBranch,
        )
        val forceReturn = reconcile.indexOf("return", forceCancellation)

        assertTrue(forceBranch >= 0)
        assertTrue(forceCancellation > forceBranch)
        assertTrue(forceReturn > forceCancellation)
        assertTrue(normalOwnerReconciliation > forceReturn)
        assertTrue(reconcile.contains("completePlannedWorkoutCleanup(app)"))
    }

    @Test fun disabledEntryPointsRetryTheCorrectCleanupScope() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }

        assertTrue(
            Regex(
                """if \(!AdaptiveDayConsentGate\.guidance\(appContext\)\)[\s\S]*?""" +
                    """forceCancelSharedNotification = true""",
            ).containsMatchIn(text),
        )
        assertTrue(
            Regex(
                """forceCancelSharedNotification = !adaptiveDayEnabled[\s\S]*?""" +
                    """requirePlannedWorkoutCalendarDisabled =[\s\S]*?""" +
                    """adaptiveDayEnabled && !calendarEnabled""",
            ).containsMatchIn(text),
        )
        assertTrue(
            Regex(
                """if \(!AdaptiveDayConsentGate\.guidance\(context\)\)[\s\S]*?""" +
                    """forceCancelSharedNotification = true""",
            ).containsMatchIn(text),
        )
    }

    @Test fun synchronizedCleanupRechecksConsentBeforeCancelling() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val annotation = text.lastIndexOf(
            "@Synchronized",
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
        )
        val reconcile = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
            text.indexOf("internal fun restoredPlannedWorkoutState("),
        )
        val adaptiveGuard = reconcile.indexOf("AdaptiveDayConsentGate.guidance(app)")
        val calendarGuard = reconcile.indexOf(
            "AdaptiveDayConsentGate.plannedWorkoutCalendar(app)",
        )
        val forceCancellation = reconcile.indexOf("completeGuidanceCleanup(app)")

        assertTrue(annotation >= 0)
        assertTrue(adaptiveGuard >= 0)
        assertTrue(calendarGuard > adaptiveGuard)
        assertTrue(forceCancellation > calendarGuard)
        assertTrue(reconcile.contains("\"outcome\" to \"force_superseded\""))
        assertTrue(reconcile.contains("\"outcome\" to \"calendar_cleanup_superseded\""))
    }

    @Test fun processStartupRetriesDurableConsentCleanupBeforeTermsAndRuntimeGates() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/NoopApplication.kt"),
            File(root, "app/src/main/java/com/noop/NoopApplication.kt"),
            File(root, "android/app/src/main/java/com/noop/NoopApplication.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate NoopApplication.kt from $root" }
        val onCreate = text.substring(
            text.indexOf("override fun onCreate()"),
            text.indexOf("fun startOperationalRuntime()"),
        )
        val recovery = onCreate.indexOf(
            "AdaptiveDayNotifier.recoverPendingConsentCleanup(this)",
        )
        val termsGate = onCreate.indexOf("if (hasAcceptedCurrentTerms())")
        val retry = onCreate.indexOf("if (!consentCleanupComplete)")

        assertTrue(recovery >= 0)
        assertTrue(retry > recovery)
        assertTrue(termsGate > retry)
    }

    @Test fun cleanupNeverTreatsAnInMemoryEmptyPrivateStateAsDurable() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false, true),
            applyFailedCommitsToMemory = true,
        )
        val initial = AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = 2_000L,
            deliveries = mapOf(
                AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                    AdaptiveDayDelivery(
                        atMillis = 2_000L,
                        fingerprint = "planned-workout|2026-09-11|1789160400",
                    ),
            ),
        )
        assertTrue(AdaptiveDayNotifier.saveState(prefs, initial))

        assertFalse(AdaptiveDayNotifier.saveState(prefs, AdaptiveDayDeliveryState()))
        assertEquals(
            AdaptiveDayDeliveryState(),
            AdaptiveDayNotifier.loadState(prefs),
        )
        assertTrue(AdaptiveDayNotifier.saveState(prefs, AdaptiveDayDeliveryState()))

        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val guidanceCleanup = text.substring(
            text.indexOf("private fun completeGuidanceCleanup("),
            text.indexOf("private fun completePlannedWorkoutCleanup("),
        )
        val calendarCleanup = text.substring(
            text.indexOf("private fun completePlannedWorkoutCleanup("),
            text.indexOf("fun onRecommendation("),
        )
        assertTrue(
            guidanceCleanup.contains(
                "canClearPrivateState && saveState(app, AdaptiveDayDeliveryState())",
            ),
        )
        assertFalse(guidanceCleanup.contains("state == AdaptiveDayDeliveryState()"))
        assertTrue(calendarCleanup.contains("cancelNotificationSlotThroughCutoff("))
        assertTrue(calendarCleanup.contains("canClearPrivateState && saveState(app, cleared)"))
        assertFalse(calendarCleanup.contains("cleared == state"))
    }

    @Test fun consentWritesShareTheNotifierMonitorWithPostingAndCleanup() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val notifier = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val appViewModel = listOf(
            File(root, "src/main/java/com/noop/ui/AppViewModel.kt"),
            File(root, "app/src/main/java/com/noop/ui/AppViewModel.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/AppViewModel.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val automations = listOf(
            File(root, "src/main/java/com/noop/ui/AutomationsScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/AutomationsScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/AutomationsScreen.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val preferences = listOf(
            File(root, "src/main/java/com/noop/ui/MainActivity.kt"),
            File(root, "app/src/main/java/com/noop/ui/MainActivity.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/MainActivity.kt"),
        ).firstOrNull(File::isFile)?.readText()

        val notifierText = checkNotNull(notifier)
        val guidanceSetter = notifierText.indexOf("fun setGuidanceConsent(")
        val calendarSetter = notifierText.indexOf("fun setPlannedWorkoutCalendarConsent(")
        assertTrue(notifierText.lastIndexOf("@Synchronized", guidanceSetter) >= 0)
        assertTrue(notifierText.lastIndexOf("@Synchronized", calendarSetter) >= 0)
        assertTrue(checkNotNull(appViewModel).contains("AdaptiveDayNotifier.setGuidanceConsent("))
        assertFalse(appViewModel.contains("NoopPrefs.setAdaptiveDayGuidance("))
        assertTrue(
            checkNotNull(automations).contains(
                "fun commitPlannedWorkoutCalendarConsent(enabled: Boolean): Boolean",
            ),
        )
        assertFalse(automations.contains("NoopPrefs.setPlannedWorkoutCalendar("))
        assertTrue(automations.contains("if (!commitPlannedWorkoutCalendarConsent(false)) return"))
        assertTrue(
            appViewModel.contains(
                "if (!AdaptiveDayNotifier.setGuidanceConsent(appContext, enabled))",
            ),
        )
        val preferenceText = checkNotNull(preferences)
        assertFalse(preferenceText.contains("fun setAdaptiveDayGuidance("))
        assertFalse(preferenceText.contains("fun setPlannedWorkoutCalendar("))
        val guidancePreference = preferenceText.substring(
            preferenceText.indexOf("fun commitAdaptiveDayGuidance("),
            preferenceText.indexOf("fun adaptiveDayCleanupPending("),
        )
        val calendarPreference = preferenceText.substring(
            preferenceText.indexOf("fun commitPlannedWorkoutCalendar("),
            preferenceText.indexOf("fun plannedWorkoutCleanupPending("),
        )
        assertTrue(guidancePreference.contains(".commit()"))
        assertFalse(guidancePreference.contains(".apply()"))
        assertTrue(guidancePreference.contains("cleanupPending"))
        assertTrue(calendarPreference.contains(".commit()"))
        assertFalse(calendarPreference.contains(".apply()"))
        assertTrue(calendarPreference.contains("cleanupPending"))
    }

    @Test fun currentWorkoutRestoresPrivateCooldownFromOrphanedSharedOwner() {
        val fingerprint = "planned-workout|2026-09-10|1789074000"
        val restored = checkNotNull(AdaptiveDayNotifier.restoredPlannedWorkoutState(
            state = AdaptiveDayDeliveryState(
                lastGlobalDeliveryMillis = 1_000L,
                deliveries = mapOf(
                    AdaptiveDayDeliveryKind.SLEEP_RECOVERY to
                    AdaptiveDayDelivery(1_000L, "sleep-a"),
                ),
            ),
            currentFingerprint = fingerprint,
            receipt = ContextualPromptDeliveryReceipt(2_000L, fingerprint),
        ))

        assertEquals(2_000L, restored.lastGlobalDeliveryMillis)
        assertEquals(
            AdaptiveDayDelivery(
                2_000L,
                fingerprint,
            ),
            restored.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT],
        )
        assertEquals(
            AdaptiveDayDelivery(1_000L, "sleep-a"),
            restored.deliveries[AdaptiveDayDeliveryKind.SLEEP_RECOVERY],
        )

        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val reconcile = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
            text.indexOf("internal fun restoredPlannedWorkoutState("),
        )
        val ownerRead = reconcile.indexOf("ContextualPromptDeliveryLedger.deliveryReceipt(")
        val restore = reconcile.indexOf("restoredPlannedWorkoutState(", ownerRead)
        val returnIndex = reconcile.indexOf("return", restore)
        assertTrue(ownerRead >= 0)
        assertTrue(restore > ownerRead)
        assertTrue(returnIndex > restore)
    }

    @Test fun newerSharedWorkoutReplacesStalePrivateWorkoutWithoutKeepingItsTimestamp() {
        val current = "planned-workout|2026-09-11|1789160400"
        val restored = checkNotNull(
            AdaptiveDayNotifier.restoredPlannedWorkoutState(
                state = AdaptiveDayDeliveryState(
                    lastGlobalDeliveryMillis = 5_000L,
                    deliveries = mapOf(
                        AdaptiveDayDeliveryKind.SLEEP_RECOVERY to
                            AdaptiveDayDelivery(1_000L, "sleep-a"),
                        AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                            AdaptiveDayDelivery(
                                5_000L,
                                "planned-workout|2026-09-10|1789074000",
                            ),
                    ),
                ),
                currentFingerprint = current,
                receipt = ContextualPromptDeliveryReceipt(2_000L, current),
            ),
        )

        assertEquals(2_000L, restored.lastGlobalDeliveryMillis)
        assertEquals(
            AdaptiveDayDelivery(2_000L, current),
            restored.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT],
        )
    }

    @Test fun movedOrIdentitylessWorkoutOwnerIsNotRestoredAsTheCurrentPlan() {
        val current = "planned-workout|2026-09-10|1789074000"
        val moved = "planned-workout|2026-09-10|1789077600"

        assertNull(
            AdaptiveDayNotifier.restoredPlannedWorkoutState(
                state = AdaptiveDayDeliveryState(),
                currentFingerprint = current,
                receipt = ContextualPromptDeliveryReceipt(2_000L, moved),
            ),
        )
        assertNull(
            AdaptiveDayNotifier.restoredPlannedWorkoutState(
                state = AdaptiveDayDeliveryState(),
                currentFingerprint = current,
                receipt = ContextualPromptDeliveryReceipt(2_000L, identity = null),
            ),
        )

        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/AdaptiveDayNotifier.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) { "Could not locate AdaptiveDayNotifier.kt from $root" }
        val reconcile = text.substring(
            text.indexOf("internal fun reconcilePlannedWorkoutArtifacts("),
            text.indexOf("internal fun restoredPlannedWorkoutState("),
        )
        val receiptRead = reconcile.indexOf("ContextualPromptDeliveryLedger.deliveryReceipt(")
        val staleOwnerRemoval = reconcile.indexOf(
            "ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(",
            receiptRead,
        )
        assertTrue(receiptRead >= 0)
        assertTrue(staleOwnerRemoval > receiptRead)
        assertTrue(reconcile.contains("onNotificationSlotOwnerRemoved = {"))
    }

    @Test fun orphanCleanupPersistsOwnershipRemovalBeforeCancellingInsideTheLock() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val source = listOf(
            File(root, "src/main/java/com/noop/notif/ContextualPromptDeliveryLedger.kt"),
            File(root, "app/src/main/java/com/noop/notif/ContextualPromptDeliveryLedger.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/notif/ContextualPromptDeliveryLedger.kt",
            ),
        ).firstOrNull(File::isFile)?.readText()
        val text = checkNotNull(source) {
            "Could not locate ContextualPromptDeliveryLedger.kt from $root"
        }
        val method = text.indexOf("fun reconcileOwnerWithOutcome(")
        val methodEnd = text.indexOf("fun nextAllowedAtMillis(", method)
        val methodSource = text.substring(method, methodEnd)
        val cancel = methodSource.indexOf("onNotificationSlotOwnerRemoved()")
        val save = methodSource.indexOf("saveState(prefs, prepared)")

        assertTrue(methodSource.contains("synchronized(lock)"))
        assertTrue(save >= 0)
        assertTrue(cancel >= 0)
        assertTrue(cancel > save)
        assertTrue(methodSource.contains("pendingCancellationSlots"))
    }
}
