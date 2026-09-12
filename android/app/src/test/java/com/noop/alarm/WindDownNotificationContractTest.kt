package com.noop.alarm

import com.noop.testing.FakeSharedPreferences
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WindDownNotificationContractTest {
    @Test
    fun viewModelAndScreenRetainExistingOptInWhenDeliveryIsTemporarilyUnavailable() {
        val viewModel = source("src/main/java/com/noop/ui/AppViewModel.kt")
        val screen = source("src/main/java/com/noop/ui/SmartAlarmScreen.kt")
        val initialization = viewModel.substring(
            viewModel.indexOf("private val windDownStore"),
            viewModel.indexOf("/** Whether the evening wind-down nudge is scheduled. */"),
        )
        val resumeObserver = screen.substring(
            screen.indexOf("DisposableEffect(lifecycleOwner, enabled)"),
            screen.indexOf("NoopCard(", screen.indexOf("DisposableEffect(lifecycleOwner, enabled)")),
        )

        assertTrue(initialization.contains("MutableStateFlow(windDownStore.enabled)"))
        assertFalse(initialization.contains("windDownStore.enabled = false"))
        assertTrue(resumeObserver.contains("notificationsBlocked = true"))
        assertFalse(resumeObserver.contains("setWindDownEnabled(false)"))
    }


    @Test
    fun defaultIsOff() {
        val store = WindDownStore(FakeSharedPreferences())

        assertFalse(store.enabled)
    }

    @Test
    fun plannerWakeAndWeekdayOverridesAreOwnedByWindDownStore() {
        val prefs = FakeSharedPreferences()
        val store = WindDownStore(prefs)

        store.migrateWakeMinutesIfNeeded(6 * 60 + 30)
        store.setWakeOverride(7, 9 * 60)
        store.setWakeOverride(1, 2_000)

        assertEquals(6 * 60 + 30, store.wakeMinutes)
        assertEquals(9 * 60, store.wakeMinutesForWeekday(7))
        assertEquals(24 * 60 - 1, store.wakeMinutesForWeekday(1))
        assertEquals(6 * 60 + 30, store.wakeMinutesForWeekday(2))

        store.wakeMinutes = 8 * 60
        store.migrateWakeMinutesIfNeeded(5 * 60)
        assertEquals("migration must never overwrite planner input", 8 * 60, store.wakeMinutes)

        val restored = WindDownStore(prefs)
        assertEquals(mapOf(1 to 24 * 60 - 1, 7 to 9 * 60), restored.perDayWakeOverrides)
    }

    @Test
    fun permissionRevocationCancelsStaleAlarmAndRetainsOptIn() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        var cancelled = 0
        var scheduleCalls = 0

        val result = WindDownScheduler.reconcilePersisted(
            store = store,
            availability = WindDownScheduler.DeliveryAvailability.NOTIFICATIONS_OFF,
            schedule = {
                scheduleCalls += 1
                error("revoked permission must not schedule")
            },
            cancel = { cancelled += 1 },
        )

        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_NOTIFICATIONS_OFF,
            result,
        )
        assertTrue(store.enabled)
        assertEquals(1, cancelled)
        assertEquals(0, scheduleCalls)
    }

    @Test
    fun channelRevocationCancelsStaleAlarmAndRetainsOptIn() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        var cancelled = 0

        val result = WindDownScheduler.reconcilePersisted(
            store = store,
            availability = WindDownScheduler.DeliveryAvailability.CHANNEL_OFF,
            schedule = { error("blocked channel must not schedule") },
            cancel = { cancelled += 1 },
        )

        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_CHANNEL_OFF,
            result,
        )
        assertTrue(store.enabled)
        assertEquals(1, cancelled)
    }

    @Test
    fun everyForegroundResumeRetainsOptInAndRetriesScheduling() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var availability = WindDownScheduler.DeliveryAvailability.AVAILABLE
        var throwDuringCheck = false
        var scheduleSucceeds = true
        var scheduleCalls = 0
        var cancelled = 0
        val published = mutableListOf<Boolean>()
        val reconciler = WindDownForegroundReconciler(
            store = store,
            availability = {
                if (throwDuringCheck) error("delivery check failed")
                availability
            },
            schedule = {
                scheduleCalls += 1
                if (scheduleSucceeds) {
                    WindDownScheduler.ScheduleResult.Scheduled(plan, attempts = 1)
                } else {
                    WindDownScheduler.ScheduleResult.Failed(
                        WindDownScheduler.ScheduleFailure.ALARM_MANAGER_REJECTED,
                        attempts = 2,
                    )
                }
            },
            cancel = { cancelled += 1 },
            publishEnabled = published::add,
        )

        assertEquals(
            WindDownScheduler.ReconcileResult.SCHEDULED,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(1, scheduleCalls)
        assertEquals(0, cancelled)

        availability = WindDownScheduler.DeliveryAvailability.NOTIFICATIONS_OFF
        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_NOTIFICATIONS_OFF,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(1, cancelled)

        availability = WindDownScheduler.DeliveryAvailability.CHANNEL_OFF
        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_CHANNEL_OFF,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(2, cancelled)

        throwDuringCheck = true
        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_DELIVERY_CHECK_FAILURE,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(3, cancelled)

        throwDuringCheck = false
        availability = WindDownScheduler.DeliveryAvailability.AVAILABLE
        scheduleSucceeds = false
        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_SCHEDULE_FAILURE,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(2, scheduleCalls)
        assertEquals(4, cancelled)

        scheduleSucceeds = true
        assertEquals(
            WindDownScheduler.ReconcileResult.SCHEDULED,
            reconciler.onAppResumed(),
        )
        assertTrue(store.enabled)
        assertEquals(3, scheduleCalls)
        assertEquals(4, cancelled)
        assertEquals(listOf(true, true, true, true, true, true), published)
    }

    @Test
    fun schedulingFailureRetriesTwiceAndRetainsOptIn() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var attempts = 0
        var cancelled = 0

        val result = WindDownScheduler.reconcilePersisted(
            store = store,
            availability = WindDownScheduler.DeliveryAvailability.AVAILABLE,
            schedule = {
                WindDownScheduler.registerWithRetry(
                    plan = plan,
                    retryPolicy = WindDownScheduler.RetryPolicy(maximumAttempts = 2),
                    register = {
                        attempts += 1
                        false
                    },
                )
            },
            cancel = { cancelled += 1 },
        )

        assertEquals(
            WindDownScheduler.ReconcileResult.RETRY_SCHEDULE_FAILURE,
            result,
        )
        assertEquals(2, attempts)
        assertEquals(1, cancelled)
        assertTrue(store.enabled)
    }

    @Test
    fun enablePersistsOnlyAfterAlarmManagerAcceptance() {
        val store = WindDownStore(FakeSharedPreferences())
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var cancellations = 0

        val rejected = WindDownScheduler.commitEnableAfterAcceptance(
            store = store,
            schedule = {
                WindDownScheduler.ScheduleResult.Failed(
                    WindDownScheduler.ScheduleFailure.ALARM_MANAGER_REJECTED,
                    attempts = 2,
                )
            },
            cancel = { cancellations += 1 },
        )

        assertTrue(rejected is WindDownScheduler.ScheduleResult.Failed)
        assertFalse(store.enabled)
        assertEquals(1, cancellations)

        val accepted = WindDownScheduler.commitEnableAfterAcceptance(
            store = store,
            schedule = {
                WindDownScheduler.ScheduleResult.Scheduled(
                    plan = plan,
                    attempts = 1,
                )
            },
            cancel = { cancellations += 1 },
        )

        assertTrue(accepted is WindDownScheduler.ScheduleResult.Scheduled)
        assertTrue(store.enabled)
        assertEquals(1, cancellations)
    }

    @Test
    fun acceptedAlarmIsCancelledWhenDurableEnableCommitFails() {
        val store = WindDownStore(
            FakeSharedPreferences(commitResults = listOf(false, true)),
        )
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var cancellations = 0

        val result = WindDownScheduler.commitEnableAfterAcceptance(
            store = store,
            schedule = {
                WindDownScheduler.ScheduleResult.Scheduled(
                    plan = plan,
                    attempts = 1,
                )
            },
            cancel = { cancellations += 1 },
        )

        assertEquals(
            WindDownScheduler.ScheduleFailure.PERSISTENCE_REJECTED,
            (result as WindDownScheduler.ScheduleResult.Failed).reason,
        )
        assertEquals(1, result.attempts)
        assertEquals(1, cancellations)
        assertFalse(store.enabled)
    }

    @Test
    fun bootRestoreKeepsEnabledOnlyAfterAlarmAcceptance() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var attempts = 0
        var cancelled = 0

        val result = WindDownScheduler.reconcilePersisted(
            store = store,
            availability = WindDownScheduler.DeliveryAvailability.AVAILABLE,
            schedule = {
                WindDownScheduler.registerWithRetry(
                    plan = plan,
                    retryPolicy = WindDownScheduler.RetryPolicy(maximumAttempts = 2),
                    register = {
                        attempts += 1
                        true
                    },
                )
            },
            cancel = { cancelled += 1 },
        )

        assertEquals(WindDownScheduler.ReconcileResult.SCHEDULED, result)
        assertEquals(1, attempts)
        assertEquals(0, cancelled)
        assertTrue(store.enabled)
    }

    @Test
    fun bootRestoreExceptionCancelsStaleAlarmAndRetainsOptIn() {
        val store = WindDownStore(FakeSharedPreferences()).apply { enabled = true }
        var cancelCalls = 0

        val result = SmartAlarmBootReceiver.reconcileWindDownForRestore(
            reconcile = { error("restore failed") },
            cancelStale = { cancelCalls += 1 },
        )

        assertEquals(null, result)
        assertEquals(1, cancelCalls)
        assertTrue(store.enabled)
    }

    @Test
    fun thrownAlarmRegistrationIsStructuredAndBounded() {
        val plan = WindDownScheduler.DatedPlan(
            windDownAtMillis = 1_000L,
            bedtimeAtMillis = 2_000L,
            wakeAtMillis = 3_000L,
            wakeWeekday = 7,
        )
        var attempts = 0

        val result = WindDownScheduler.registerWithRetry(
            plan = plan,
            retryPolicy = WindDownScheduler.RetryPolicy(maximumAttempts = 2),
            register = {
                attempts += 1
                error("AlarmManager rejected")
            },
        )

        assertEquals(
            WindDownScheduler.ScheduleResult.Failed(
                WindDownScheduler.ScheduleFailure.ALARM_MANAGER_REJECTED,
                attempts = 2,
            ),
            result,
        )
        assertEquals(2, attempts)
    }

    private fun source(relative: String): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, relative),
            File(root, "app/$relative"),
            File(root, "android/app/$relative"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("Missing source file $relative from ${root.absolutePath}")
    }
}
