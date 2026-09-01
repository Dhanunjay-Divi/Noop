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
        assertTrue(source.contains("R.string.automation_morning_recap_help"))
        assertTrue(source.contains("R.string.automation_post_workout_summary_help"))
        assertTrue(source.contains("Lifecycle.Event.ON_RESUME"))
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
}
