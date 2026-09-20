package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPresentationSettingsContractTest {
    @Test fun settingsExposeIndependentSafetyAndLiveHeartRateControls() {
        val root = sourceRoot()
        val settings = File(root, "ui/SettingsScreen.kt").readText()
        val notifications = File(root, "ui/NotificationsSettingsScreen.kt").readText()
        val connectionService = File(root, "ble/WhoopConnectionService.kt").readText()

        assertTrue(settings.contains("NotificationPresentationPreferences.liveHeartRate"))
        assertTrue(settings.contains("live_heart_rate_notification_title"))
        assertTrue(settings.contains("live_heart_rate_notification_accessibility"))
        val liveHeartRateRow = settings.substring(
            settings.lastIndexOf("Row(", settings.indexOf("live_heart_rate_notification_title")),
            settings.indexOf("// \"Faster history sync\""),
        )
        assertTrue(liveHeartRateRow.contains("semantics(mergeDescendants = true)"))
        assertTrue(liveHeartRateRow.contains("live_heart_rate_notification_accessibility"))
        assertTrue(
            liveHeartRateRow.contains(
                "WhoopConnectionService.refreshPresentationIfRunning()",
            ),
        )
        assertFalse(liveHeartRateRow.contains("WhoopConnectionService.start("))
        val refreshOnly = connectionService.substring(
            connectionService.indexOf("fun refreshPresentationIfRunning()"),
            connectionService.indexOf("fun start(context: Context)"),
        )
        assertTrue(refreshOnly.contains("activeInstance?.get()"))
        assertTrue(refreshOnly.contains("\"not_running\""))
        assertFalse(refreshOnly.contains("startForegroundService"))
        assertTrue(notifications.contains("ManagedSafetyNotifier.urgentSoundEnabled"))
        assertTrue(notifications.contains("managed_safety_urgent_sound_title"))
        assertTrue(notifications.contains("ManagedSafetyNotifier.notificationSettingsIntent"))
    }

    @Test fun presentationCopyExistsInEverySupportedLocale() {
        val root = resourceRoot()
        val locales = listOf(
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
        val required = listOf(
            "managed_safety_urgent_sound_title",
            "managed_safety_urgent_channel_name",
            "managed_safety_open_notification_settings",
            "live_heart_rate_notification_title",
            "live_heart_rate_notification_detail",
            "live_heart_rate_notification_accessibility",
            "live_heart_rate_notification_value",
        )
        locales.forEach { locale ->
            val text = File(root, "$locale/notification_presentation.xml").readText()
            required.forEach { name ->
                assertTrue("$locale missing $name", text.contains("name=\"$name\""))
            }
        }
    }

    private fun sourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory) ?: error("Could not locate source root from $root")
    }

    private fun resourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/res"),
            File(root, "app/src/main/res"),
            File(root, "android/app/src/main/res"),
        ).firstOrNull(File::isDirectory) ?: error("Could not locate resource root from $root")
    }
}
