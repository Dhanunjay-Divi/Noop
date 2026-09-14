package com.noop.notif

import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import com.noop.ui.PendingNotificationRouteRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyReviewReminderPolicyTest {
    private val zone = ZoneId.of("America/New_York")

    @Test
    fun nextRun_usesTodayWhenFutureAndTomorrowWhenPast() {
        val morning = ZonedDateTime.of(2026, 8, 31, 7, 30, 0, 0, zone)
        assertEquals(
            ZonedDateTime.of(2026, 8, 31, 8, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(morning, 8 * 60),
        )

        val evening = ZonedDateTime.of(2026, 8, 31, 20, 0, 0, 0, zone)
        assertEquals(
            ZonedDateTime.of(2026, 9, 1, 19, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(evening, 19 * 60),
        )
    }

    @Test
    fun nextRun_keepsTodayDuringFinalSecondBeforeReminder() {
        val justBefore = ZonedDateTime.of(2026, 8, 31, 7, 59, 59, 500_000_000, zone)

        assertEquals(
            ZonedDateTime.of(2026, 8, 31, 8, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(justBefore, 8 * 60),
        )
    }

    @Test
    fun nextRun_movesQuietEveningToNextMorningWithoutChangingLogicalDay() {
        val now = ZonedDateTime.of(2026, 8, 31, 20, 0, 0, 0, zone)
        val nominal = DailyReviewReminderPolicy.nextNominalRun(now, 23 * 60)
        val delivery = DailyReviewReminderPolicy.nextRun(
            now = now,
            minuteOfDay = 23 * 60,
            quietHoursEnabled = true,
            quietStartMinutes = 22 * 60,
            quietEndMinutes = 7 * 60,
        )

        assertEquals(
            ZonedDateTime.of(2026, 8, 31, 23, 0, 0, 0, zone),
            nominal,
        )
        assertEquals(
            ZonedDateTime.of(2026, 9, 1, 7, 0, 0, 0, zone),
            delivery,
        )
        assertTrue(
            DailyReviewReminderPolicy.logicalDayMatchesDelivery(
                nominal.toLocalDate(),
                delivery,
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.logicalDayMatchesDelivery(
                nominal.toLocalDate().minusDays(1),
                delivery,
            ),
        )
        assertTrue(
            DailyReviewReminderPolicy.requiresCarryoverMarker(
                nominal.toLocalDate(),
                delivery,
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.requiresCarryoverMarker(
                delivery.toLocalDate(),
                delivery,
            ),
        )
    }

    @Test
    fun quietHoursEditReschedulesYesterdayCarryoverWithoutChangingItsJournalDay() {
        val logicalDay = LocalDate.of(2026, 9, 13)
        val now = ZonedDateTime.of(2026, 9, 14, 1, 0, 0, 0, zone)

        assertEquals(
            ZonedDateTime.of(2026, 9, 14, 6, 0, 0, 0, zone),
            DailyReviewReminderPolicy.carryoverRun(
                logicalDay = logicalDay,
                now = now,
                minuteOfDay = 23 * 60,
                quietHoursEnabled = true,
                quietStartMinutes = 22 * 60,
                quietEndMinutes = 6 * 60,
            ),
        )
        assertEquals(
            now.plusSeconds(1),
            DailyReviewReminderPolicy.carryoverRun(
                logicalDay = logicalDay,
                now = now,
                minuteOfDay = 23 * 60,
                quietHoursEnabled = false,
                quietStartMinutes = 22 * 60,
                quietEndMinutes = 7 * 60,
            ),
        )
        assertEquals(
            null,
            DailyReviewReminderPolicy.carryoverRun(
                logicalDay = logicalDay.minusDays(1),
                now = now,
                minuteOfDay = 23 * 60,
                quietHoursEnabled = true,
                quietStartMinutes = 22 * 60,
                quietEndMinutes = 7 * 60,
            ),
        )
    }

    @Test
    fun deliveryGate_rejectsEarlyExecution() {
        val scheduled = ZonedDateTime.of(2026, 8, 31, 19, 0, 0, 0, zone)
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.minusSeconds(1),
            ),
        )
    }

    @Test
    fun deliveryGate_rejectsWrongDayAndExcessiveDelay() {
        val scheduled = ZonedDateTime.of(2026, 8, 31, 19, 0, 0, 0, zone)
        assertTrue(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusMinutes(DailyReviewReminderPolicy.DELIVERY_GRACE_MINUTES),
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusMinutes(DailyReviewReminderPolicy.DELIVERY_GRACE_MINUTES + 1),
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusDays(1),
            ),
        )
    }

    @Test
    fun completedJournal_suppressesOnlyEveningPrompt() {
        assertFalse(
            DailyReviewReminderPolicy.shouldPost(
                DailyReviewKind.EVENING,
                scheduleIsFresh = true,
                journalCompleted = true,
            ),
        )
        assertTrue(
            DailyReviewReminderPolicy.shouldPost(
                DailyReviewKind.MORNING,
                scheduleIsFresh = true,
                journalCompleted = true,
            ),
        )
    }

    @Test
    fun fixedMorningReminderRoutesToSleepWithoutInventingMeasuredSleepEvidence() {
        val source = locateReminderSource().readText()
        val notifier = source.substring(source.indexOf("object DailyReviewReminderNotifier"))

        assertTrue(notifier.contains("DailyReviewKind.MORNING -> NoopNotificationRoute.SLEEP"))
        assertTrue(notifier.contains("NotificationRouteBridge.launchIntent("))
        assertTrue(notifier.contains("journalDay = logicalDay.takeIf"))
        assertTrue(notifier.contains("journalDay = logicalDay.toString()"))
        assertTrue(
            notifier.contains(
                "\"${'$'}{kind.name.lowercase()}:${'$'}logicalDay\"",
            ),
        )
        assertFalse(notifier.contains("ContextualActionCenter.presentRecovery("))
        assertFalse(notifier.contains("\"current-sleep\""))

        assertTrue(source.contains("logicalDay = nominal.toLocalDate()"))
        assertTrue(source.contains("logicalDay,"))
        assertTrue(source.contains("WhoopRepository.from(applicationContext)"))
        assertTrue(source.contains(".journal(JOURNAL_DEVICE_ID, scheduledDay, scheduledDay)"))
    }

    @Test
    fun workerRejectsStaleDeliveryBeforeQuietHoursCanRescheduleIt() {
        val source = locateReminderSource().readText()
        val worker = source.substring(
            source.indexOf("class DailyReviewReminderWorker"),
            source.indexOf("/** Recomputes local wall-clock work"),
        )

        val freshness = worker.indexOf("val fresh =")
        val staleExit = worker.indexOf("if (!fresh)")
        val quietHours = worker.indexOf("DailyReviewReminderPolicy.isInQuietHours(")

        assertTrue(freshness >= 0)
        assertTrue(staleExit > freshness)
        assertTrue(quietHours > staleExit)
    }

    @Test
    fun operationalEntryPointsRejectBeforeReadingOrRepairingReminderState() {
        val source = locateReminderSource().readText()
        val worker = source.substring(
            source.indexOf("class DailyReviewReminderWorker"),
            source.indexOf("/** Recomputes local wall-clock work"),
        )
        val receiver = source.substring(
            source.indexOf("class DailyReviewTimeChangeReceiver"),
            source.indexOf("internal object DailyReviewReminderNotifier"),
        )

        val workerGate = worker.indexOf(
            "ManagedRuntimeGate.isAuthorized(applicationContext)",
        )
        val workerInput = worker.indexOf("inputData.getString(KIND_KEY)")
        val receiverGate = receiver.indexOf(
            "ManagedRuntimeGate.isAuthorized(context.applicationContext)",
        )
        val receiverRepair = receiver.indexOf("DailyReviewReminders.restore(context)")

        assertTrue(workerGate >= 0)
        assertTrue(workerInput > workerGate)
        assertTrue(receiverGate >= 0)
        assertTrue(receiverRepair > receiverGate)
        assertTrue(source.contains("\"daily_review.operational_gate\""))
    }

    @Test
    fun journalRouteKeepsTheLogicalDayAfterQuietHoursCrossMidnight() {
        val request = PendingNotificationRouteRequest(
            route = NoopNotificationRoute.JOURNAL,
            journalDay = LocalDate.of(2026, 9, 13),
        )

        assertEquals(
            1L,
            NotificationRouteBridge.journalDayOffset(
                request,
                today = LocalDate.of(2026, 9, 14),
            ),
        )
        assertEquals(
            null,
            NotificationRouteBridge.journalDayOffset(
                request.copy(route = NoopNotificationRoute.SLEEP),
                today = LocalDate.of(2026, 9, 14),
            ),
        )
        assertEquals(
            1L,
            NotificationRouteBridge.journalDayOffset(
                "2026-09-13",
                today = LocalDate.of(2026, 9, 14),
            ),
        )
        assertEquals(
            null,
            NotificationRouteBridge.journalDayOffset(
                "2026-02-31",
                today = LocalDate.of(2026, 9, 14),
            ),
        )
    }

    @Test
    fun processStartupKeepsExistingDailyReviewWork() {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val application = listOf(
            File(root, "src/main/java/com/noop/NoopApplication.kt"),
            File(root, "app/src/main/java/com/noop/NoopApplication.kt"),
            File(root, "android/app/src/main/java/com/noop/NoopApplication.kt"),
        ).firstOrNull(File::isFile)?.readText()
        val reminder = locateReminderSource().readText()

        assertTrue(checkNotNull(application).contains("DailyReviewReminders.restore("))
        assertTrue(reminder.contains("reconcile(context, ExistingWorkPolicy.KEEP)"))
        assertTrue(reminder.contains("fun reconcile(context: Context)"))
        assertTrue(reminder.contains("reconcile(context, ExistingWorkPolicy.REPLACE)"))
        assertTrue(reminder.contains("preserveQuietHoursCarryover"))
        assertTrue(reminder.contains("quietHoursCarryover = true"))
        assertTrue(reminder.contains("quietHoursCarryover = DailyReviewReminderPolicy"))
        assertTrue(reminder.contains(".requiresCarryoverMarker("))
        assertTrue(reminder.contains("recordCarryover(context, kind, logicalDay)"))
        assertTrue(
            reminder.contains(
                "if (intent?.action == Intent.ACTION_DATE_CHANGED)",
            ),
        )
    }

    @Test
    fun restoredDailyReviewChoicesReplaceScheduledWorkImmediately() {
        val source = locateBackupSettingsSource().readText()
        val reconcile = source.substring(
            source.indexOf("fun reconcileAfterRestore(context: Context)"),
            source.indexOf("internal enum class RestoreSchedulerRetryOutcome"),
        )

        assertTrue(reconcile.contains("DailyReviewReminders.reconcile(appContext)"))
        assertTrue(reconcile.contains("\"component\" to \"daily_review\""))
        assertTrue(reconcile.contains("reconcileSchedulerForConfirmedRestore("))
        assertTrue(reconcile.contains("DAILY_REVIEW_RETRY_NEEDED"))
        assertTrue(source.contains("fun reconcileDailyReviewAfterDatabaseReady("))
    }

    private fun locateReminderSource(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop/notif/DailyReviewReminders.kt"),
            File(root, "app/src/main/java/com/noop/notif/DailyReviewReminders.kt"),
            File(root, "android/app/src/main/java/com/noop/notif/DailyReviewReminders.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate DailyReviewReminders.kt from $root")
    }

    private fun locateBackupSettingsSource(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop/data/BackupSettings.kt"),
            File(root, "app/src/main/java/com/noop/data/BackupSettings.kt"),
            File(root, "android/app/src/main/java/com/noop/data/BackupSettings.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate BackupSettings.kt from $root")
    }
}
