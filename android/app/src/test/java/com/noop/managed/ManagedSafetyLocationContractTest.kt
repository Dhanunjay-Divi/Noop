package com.noop.managed

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class ManagedSafetyLocationContractTest {
    private fun source(vararg candidates: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return candidates
            .map { File(root, it) }
            .firstOrNull(File::isFile)
            ?.readText()
    }

    @Test
    fun managedSafetyUsesBoundedBackgroundLatestLocationSession() {
        val service = source(
            "src/main/java/com/noop/ble/WhoopConnectionService.kt",
            "app/src/main/java/com/noop/ble/WhoopConnectionService.kt",
            "android/app/src/main/java/com/noop/ble/WhoopConnectionService.kt",
        )
        val cloud = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        val application = source(
            "src/main/java/com/noop/NoopApplication.kt",
            "app/src/main/java/com/noop/NoopApplication.kt",
            "android/app/src/main/java/com/noop/NoopApplication.kt",
        )
        val screen = source(
            "src/main/java/com/noop/ui/ManagedSafetySection.kt",
            "app/src/main/java/com/noop/ui/ManagedSafetySection.kt",
            "android/app/src/main/java/com/noop/ui/ManagedSafetySection.kt",
        )
        assumeTrue(service != null && cloud != null && application != null && screen != null)

        assertTrue(service!!.contains("ManagedSafetyLiveLocationSession.state"))
        assertTrue(service.contains("updateSafetyLocationForStream("))
        assertEquals(
            1,
            Regex("""SafetyIncidentLocationTracker\(this\)""")
                .findAll(service)
                .count(),
        )
        assertTrue(service.contains("SharingStarted.WhileSubscribed"))
        assertTrue(service.contains("locationActive = locationForegroundActive()"))
        assertTrue(service.contains("Safety location sharing active"))
        assertTrue(cloud!!.contains("reconcileManagedSafetyLocationSession()"))
        assertTrue(cloud.contains("stopManagedSafetyLocationSession(\"disconnect\")"))
        assertTrue(cloud.contains("\"managed_safety.location_session\""))
        assertTrue(application!!.contains("ManagedSafetyLiveLocationSession.initialize"))
        assertTrue(screen!!.contains("backgroundLocationReady"))
        assertTrue(screen.contains("managed_safety_location_background_body"))
        assertFalse(service.contains("\"latitude\" to"))
        assertFalse(service.contains("\"longitude\" to"))
    }

    @Test
    fun managedSafetyLifecycleFailsClosedAndClearsCascadedState() {
        val cloud = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        assumeTrue(cloud != null)
        val text = cloud!!
        val deletion = text
            .substringAfter("suspend fun deleteSocialProfile()")
            .substringBefore("suspend fun sendSocialPoke(")

        assertTrue(deletion.contains("preferences.clearSocialState()"))
        assertTrue(deletion.contains("preferences.clearSafetyState()"))
        assertTrue(deletion.contains("clearSafetyPresentation()"))
        assertTrue(text.contains(
            "ManagedPushRevocationPolicy.canFinalizeDisconnect(",
        ))
        assertTrue(text.contains("scheduleManagedSafetyBootstrap()"))
    }
}
