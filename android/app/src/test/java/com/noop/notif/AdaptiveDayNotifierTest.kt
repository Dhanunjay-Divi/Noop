package com.noop.notif

import com.noop.R
import com.noop.analytics.AdaptiveDayGuidance
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ScoreConfidence
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

    @Test fun plannedWorkoutNotificationExpiresAtTheWorkoutStartFromActualPostTime() {
        assertEquals(
            4_000L,
            AdaptiveDayNotifier.plannedWorkoutRemainingLifetimeMillis(
                observedAtMillis = 1_000L,
                maximumAgeMillis = 10_000L,
                postAtMillis = 7_000L,
            ),
        )
        assertNull(
            AdaptiveDayNotifier.plannedWorkoutRemainingLifetimeMillis(
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
        val remaining = text.indexOf("val plannedWorkoutTimeoutMillis =")
        val builder = text.indexOf("val notificationBuilder = NotificationCompat.Builder")
        val timeout = text.indexOf(
            "notificationBuilder.setTimeoutAfter(plannedWorkoutTimeoutMillis)",
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

    @Test fun plannedWorkoutFingerprintExposesOnlyItsBoundedStartTimestamp() {
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
                .contains("NoopPrefs.plannedWorkoutCalendar(context)"),
        )
        assertTrue(
            text.substring(helper)
                .contains("NoopPrefs.adaptiveDayGuidance(context)"),
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
        val deliveryAt = text.indexOf(
            "val deliveryAtMillis = now.toInstant().toEpochMilli()",
            postCandidate,
        )
        val postGate = text.indexOf("ContextualPromptDeliveryLedger.postIfAllowed", deliveryAt)
        val postedResult = text.indexOf(
            "if (postResult != ContextualPromptPostResult.POSTED)",
            postGate,
        )
        val postSuccessConsent = text.indexOf(
            "!plannedWorkoutDeliveryCurrent(context, candidate)",
            postedResult,
        )
        val reconcile = text.indexOf(
            "ContextualPromptDeliveryLedger.reconcileIfOwned(",
            postSuccessConsent,
        )
        val expectedTimestamp = text.indexOf(
            "expectedAtMillis = deliveryAtMillis",
            reconcile,
        )
        val cancellation = text.indexOf(
            "NotificationLifecycleLedger.cancelled(",
            expectedTimestamp,
        )

        assertTrue(deliveryAt > postCandidate)
        assertTrue(postGate > deliveryAt)
        assertTrue(postedResult > postGate)
        assertTrue(postSuccessConsent > postedResult)
        assertTrue(reconcile > postSuccessConsent)
        assertTrue(expectedTimestamp > reconcile)
        assertTrue(cancellation > expectedTimestamp)
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
        assertTrue(expireSource.contains("prior.fingerprint != fingerprint"))
        assertTrue(missingSource.contains("plannedWorkoutStartSec(prior.fingerprint)"))
        assertTrue(missingSource.contains("expirePlannedWorkoutArtifacts"))
        assertTrue(missingSource.contains("reconcilePlannedWorkoutArtifacts"))
    }
}
