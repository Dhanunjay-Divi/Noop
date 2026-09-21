package com.noop.notif

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSafetyPresentationContractTest {
    @Test fun safetyPresentationIsVersionedOptInPrivateAndDoesNotBypassTheOs() {
        val source = source("notif/ManagedSafetyNotifier.kt")
        assertTrue(source.contains("noop_managed_safety_standard_v2"))
        assertTrue(source.contains("noop_managed_safety_urgent_v2"))
        assertTrue(source.contains("managedSafetyUrgentSound"))
        assertTrue(source.contains("NotificationManager.IMPORTANCE_HIGH"))
        assertTrue(source.contains("enableVibration(true)"))
        assertTrue(source.contains("enableLights(true)"))
        assertTrue(source.contains("AudioAttributes.USAGE_ALARM"))
        assertTrue(source.contains("setBypassDnd(false)"))
        assertTrue(source.contains(".protectPrivateContent(context, channelId)"))
        assertTrue(source.contains("legacyWasDisabled"))
        assertTrue(source.contains("resolveChannelReadiness"))
        assertTrue(source.contains("ChannelReadiness.STANDARD_FALLBACK"))
        assertTrue(source.contains("registrationChannelImportance"))
        assertTrue(source.contains("\"managed_safety.channel_readiness\""))
        assertFalse(source.contains("setFullScreenIntent"))
        assertFalse(source.contains("setBypassDnd(true)"))
        assertFalse(source.contains("deleteNotificationChannel"))
    }

    @Test fun presentationPreferencesAreOffByDefaultAndDiagnosticsContainNoValues() {
        val source = source("notif/NotificationPresentationPreferences.kt")
        assertTrue(source.contains("getBoolean(KEY_MANAGED_SAFETY_URGENT_SOUND, false)"))
        assertTrue(source.contains("getBoolean(KEY_LIVE_HEART_RATE, false)"))
        assertTrue(source.contains("\"cadence\" to \"bounded_15s\""))
        assertFalse(source.contains("\"heart_rate\""))
        assertFalse(source.contains("\"bpm\""))
        assertFalse(source.contains("incidentId"))
    }

    @Test fun disabledPreferredSafetyChannelDoesNotFallBack() {
        assertEquals(
            ManagedSafetyNotifier.ChannelReadiness.BLOCKED,
            ManagedSafetyNotifier.resolveChannelReadiness(
                preferredIsUrgent = true,
                preferredImportance = 0,
                standardImportance = 4,
            ),
        )
        assertEquals(
            ManagedSafetyNotifier.ChannelReadiness.BLOCKED,
            ManagedSafetyNotifier.resolveChannelReadiness(
                preferredIsUrgent = false,
                preferredImportance = 0,
                standardImportance = 4,
            ),
        )
    }

    @Test fun missingUrgentChannelMayUseAnEnabledStandardFallback() {
        assertEquals(
            ManagedSafetyNotifier.ChannelReadiness.STANDARD_FALLBACK,
            ManagedSafetyNotifier.resolveChannelReadiness(
                preferredIsUrgent = true,
                preferredImportance = null,
                standardImportance = 4,
            ),
        )
        assertEquals(
            ManagedSafetyNotifier.ChannelReadiness.BLOCKED,
            ManagedSafetyNotifier.resolveChannelReadiness(
                preferredIsUrgent = true,
                preferredImportance = null,
                standardImportance = 0,
            ),
        )
    }

    private fun source(relative: String): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val sourceRoot = listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory) ?: error("Could not locate source root from $root")
        return File(sourceRoot, relative).readText()
    }
}
