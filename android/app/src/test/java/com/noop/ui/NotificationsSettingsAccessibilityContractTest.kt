package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class NotificationsSettingsAccessibilityContractTest {
    private fun source(): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/NotificationsSettingsScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/NotificationsSettingsScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/NotificationsSettingsScreen.kt"),
        ).firstOrNull(File::isFile)?.readText()
    }

    @Test
    fun largeTextStacksTrailingControlsAfterTheSupportedCompactScale() {
        assertFalse(notificationSettingsUsesStackedControls(1.0f))
        assertFalse(notificationSettingsUsesStackedControls(1.30f))
        assertTrue(notificationSettingsUsesStackedControls(1.31f))
        assertTrue(notificationSettingsUsesStackedControls(2.0f))
    }

    @Test
    fun customNotificationActionsKeepTheAndroidMinimumTarget() {
        assertEquals(48f, NotificationSettingsMinimumTouchTarget.value, 0f)
    }

    @Test
    fun notificationRowsGrowAndCustomActionsSeparateHitBoundsFromPaintedBounds() {
        val source = source()
        assumeTrue("NotificationsSettingsScreen.kt unavailable", source != null)
        val text = source!!

        assertFalse("Notification rows must grow with text", text.contains(".height(48.dp)"))
        assertEquals(
            "Calls, app, and form rows must all use the responsive font-scale policy",
            3,
            Regex(
                """notificationSettingsUsesStackedControls\(LocalDensity\.current\.fontScale\)""",
            ).findAll(text).count(),
        )
        assertTrue(
            "Every responsive row branch must retain a 48dp minimum",
            Regex("""heightIn\(min = NotificationSettingsMinimumTouchTarget\)""")
                .findAll(text)
                .count() >= 5,
        )
        assertEquals(
            "Notification Access, pattern, test, pill, and time actions need minimum widths",
            5,
            Regex("""minWidth = NotificationSettingsMinimumTouchTarget""")
                .findAll(text)
                .count(),
        )
        assertEquals(
            "Notification Access, pattern, test, pill, and time actions need minimum heights",
            5,
            Regex("""minHeight = NotificationSettingsMinimumTouchTarget""")
                .findAll(text)
                .count(),
        )
        assertTrue(
            "The compact test-buzz visual should remain independent of its hit target",
            text.contains(".size(28.dp)"),
        )
        assertTrue(
            "Time-picker dialog actions must use Material touch-target buttons",
            text.contains("TextButton(onClick = { showPicker = false })"),
        )
    }
}
