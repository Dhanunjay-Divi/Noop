package com.noop.notif

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivateNotificationContractTest {
    @Test
    fun privateNotificationsUseTheSharedGenericPublicVersion() {
        val sourceRoot = locateSourceRoot()
        val helper = File(sourceRoot, "notif/PrivateNotification.kt").readText()

        assertTrue(helper.contains("setVisibility(NotificationCompat.VISIBILITY_PRIVATE)"))
        assertTrue(helper.contains("setPublicVersion("))
        assertTrue(helper.contains("setContentTitle(context.getString(R.string.app_name))"))
        assertTrue(
            helper.contains(
                "setContentText(context.getString(R.string.notification_public_update))",
            ),
        )
        assertTrue(helper.contains("setVisibility(NotificationCompat.VISIBILITY_PUBLIC)"))
        assertFalse(helper.contains(".setContentIntent("))
        assertFalse(helper.contains(".addAction("))
        assertFalse(helper.contains(".setStyle("))

        val expectedUsers = setOf(
            "notif/AdaptiveDayNotifier.kt",
            "notif/AutoWorkoutCandidateNotifier.kt",
            "notif/CoachCheckInReminder.kt",
            "notif/ContextualVitalNotifier.kt",
            "notif/DailyReviewReminders.kt",
            "notif/HydrationReminders.kt",
            "notif/IllnessAlertNotifier.kt",
            "notif/ManagedSafetyNotifier.kt",
            "notif/ManagedSocialPokeNotifier.kt",
            "notif/ScheduledReportNotifier.kt",
            "notif/StaleSyncReminder.kt",
            "notif/StrainTargetNotifier.kt",
            "notif/StressBreathingNotifier.kt",
            "notif/WorkoutCautionNotifier.kt",
            "alarm/WindDownScheduler.kt",
            "safety/SafetyCheckInReminder.kt",
            "safety/SafetyContactSetupReminder.kt",
            "safety/SafetySosGesture.kt",
            "ble/WhoopConnectionService.kt",
        )
        val actualUsers = listOf("alarm", "ble", "notif", "safety")
            .flatMap { directory ->
                File(sourceRoot, directory).listFiles().orEmpty().filter { it.extension == "kt" }
            }
            .filter { it.name != "PrivateNotification.kt" }
            .filter { it.readText().contains(".protectPrivateContent(") }
            .map { it.relativeTo(sourceRoot).invariantSeparatorsPath }
            .toSet()

        assertEquals(expectedUsers, actualUsers)
    }

    @Test
    fun scopedNotificationSourcesCannotBypassThePublicVersionHelper() {
        val sourceRoot = locateSourceRoot()
        val bypasses = listOf("alarm", "ble", "notif", "safety")
            .flatMap { directory ->
                File(sourceRoot, directory).listFiles().orEmpty().filter { it.extension == "kt" }
            }
            .filter { it.name != "PrivateNotification.kt" }
            .filter {
                it.readText().contains(
                    "setVisibility(NotificationCompat.VISIBILITY_PRIVATE)",
                )
            }
            .map { it.relativeTo(sourceRoot).invariantSeparatorsPath }

        assertTrue("Direct private visibility bypasses: $bypasses", bypasses.isEmpty())
    }

    @Test
    fun publicLockScreenCopyIsNeutralAndLocalized() {
        val resourceRoot = locateResourceRoot()
        val localizedDirectories = setOf(
            "values",
            "values-de",
            "values-es",
            "values-fr",
            "values-it",
            "values-pt-rPT",
            "values-ru",
            "values-zh",
            "values-zh-rTW",
        )
        val resourceFiles = localizedDirectories.associateWith { directory ->
            File(resourceRoot, "$directory/notification_privacy.xml")
        }

        assertTrue(resourceFiles.values.all(File::isFile))
        assertTrue(
            resourceFiles.values.all {
                it.readText().contains("name=\"notification_public_update\"")
            },
        )
        assertTrue(
            checkNotNull(resourceFiles["values"])
                .readText()
                .contains("Open NOOP to view this update"),
        )
    }

    private fun locateSourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory)
            ?: error("Could not locate Android NOOP source root from $root")
    }

    private fun locateResourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/res"),
            File(root, "app/src/main/res"),
            File(root, "android/app/src/main/res"),
        ).firstOrNull(File::isDirectory)
            ?: error("Could not locate Android resource root from $root")
    }
}
