package com.noop.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class AutomationsScreenContractTest {
    @Test fun reportsRemainUserControlledInsideAutomations() {
        val source = source().readText()

        assertTrue(source.contains("NoopPrefs.morningReportEnabled(ctx)"))
        assertTrue(source.contains("NoopPrefs.postWorkoutReportEnabled(ctx)"))
        assertTrue(source.contains("setReportPreference(AutomationReportKind.MORNING, it)"))
        assertTrue(source.contains("setReportPreference(AutomationReportKind.WORKOUT, it)"))
        assertTrue(source.contains("ScheduledReportNotifier.cancelMorning(ctx)"))
        assertTrue(source.contains("viewModel.setPostWorkoutReportEnabled(false)"))
        assertTrue(
            source.contains(
                "R.string.appwide_daily_review_morning_recap_help",
            ),
        )
        assertTrue(source.contains("R.string.automation_post_workout_summary_help"))
        assertTrue(source.contains("Lifecycle.Event.ON_RESUME"))
        assertTrue(
            source.contains(
                "morningReviewEnabled = DailyReviewReminders.isMorningEnabled(ctx)",
            ),
        )
        assertTrue(
            source.contains(
                "journalReviewEnabled = DailyReviewReminders.isJournalEnabled(ctx)",
            ),
        )
        assertTrue(
            source.contains(
                "morningRecapEnabled = NoopPrefs.morningReportEnabled(ctx)",
            ),
        )
        assertTrue(
            source.contains(
                "postWorkoutSummaryEnabled = NoopPrefs.postWorkoutReportEnabled(ctx)",
            ),
        )
        assertTrue(source.contains("DailyReviewReminders.setMorningEnabled(ctx, true)"))
        assertTrue(source.contains("DailyReviewReminders.setJournalEnabled(ctx, true)"))
        assertTrue(source.contains("NoopPrefs.setMorningReportEnabled(ctx, false)"))
        assertTrue(source.contains("DailyReviewReminders.setMorningEnabled(ctx, false)"))
        assertTrue(
            source.contains(
                "(morningReviewEnabled || journalReviewEnabled) &&",
            ),
        )
        assertTrue(source.contains("ScheduledReportNotifier.canNotify(context)"))
    }

    @Test fun notificationPermissionStateRefreshesWithoutDiscardingHydrationIntent() {
        val source = source().readText()

        assertTrue(
            source.contains(
                "hydrationRemindersEnabled = HydrationReminderPrefs.config(ctx).enabled",
            ),
        )
        assertTrue(
            source.contains(
                "hydrationRemindersEnabled && !HydrationReminderNotifier.canNotify(ctx)",
            ),
        )
        assertTrue(
            source.contains(
                "R.string.appwide_hydration_notifications_unavailable",
            ),
        )
        assertTrue(
            source.contains(
                "android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS",
            ),
        )
        assertTrue(
            source.contains(
                "stressPhoneNudge = BiofeedbackPrefs.phoneNudge(ctx)",
            ),
        )
        assertTrue(
            source.contains(
                "stressPhoneNudge && !StressBreathingNotifier.prepareAndCanNotify(ctx)",
            ),
        )
    }

    @Test fun activityForegroundRestoresPersistedHydrationScheduling() {
        val source = mainActivitySource().readText()
        val onResume = source
            .substringAfter("override fun onResume()")
            .substringBefore("override fun onPause()")

        assertTrue(onResume.contains("operationalRuntimeStarted"))
        assertTrue(onResume.contains("HydrationReminderScheduler.reconcile(applicationContext)"))
    }

    private fun source(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/AutomationsScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/AutomationsScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/AutomationsScreen.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate AutomationsScreen.kt from $userDir")
    }

    private fun mainActivitySource(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/MainActivity.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/MainActivity.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/MainActivity.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate MainActivity.kt from $userDir")
    }
}
