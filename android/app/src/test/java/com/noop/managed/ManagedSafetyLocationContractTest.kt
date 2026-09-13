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
        assertTrue(service.contains("releaseManagedSafetyLocation("))
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
        assertTrue(screen.contains("foregroundLocationReady"))
        assertTrue(screen.contains("ManagedSafetyLocationAuthorization.canStartIncident("))
        assertTrue(screen.contains("enabled = !state.busy && locationIncidentReady"))
        assertTrue(screen.contains("managed_safety_location_background_body"))
        assertFalse(service.contains("\"latitude\" to"))
        assertFalse(service.contains("\"longitude\" to"))
    }

    @Test
    fun locationSharingIncidentIsAuthorizedAgainAtTheServiceBoundary() {
        val cloud = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        val screen = source(
            "src/main/java/com/noop/ui/ManagedSafetySection.kt",
            "app/src/main/java/com/noop/ui/ManagedSafetySection.kt",
            "android/app/src/main/java/com/noop/ui/ManagedSafetySection.kt",
        )
        val safetyCenter = source(
            "src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
        )
        assumeTrue(cloud != null && screen != null && safetyCenter != null)

        val createIncident = cloud!!
            .substringAfter("suspend fun createSafetyIncident(")
            .substringBefore("suspend fun updateSafetyLocation(")
        assertTrue(
            createIncident.contains(
                "ManagedSafetyLocationAuthorization.isAuthorized(appContext, shareLocation)",
            ),
        )
        assertTrue(
            createIncident.indexOf("ManagedSafetyLocationAuthorization.isAuthorized") <
                createIncident.indexOf("preferences.safetyIncidentRequest("),
        )
        assertTrue(
            screen!!.contains(
                "ManagedSafetyLocationAuthorization.canStartIncident(",
            ),
        )
        assertTrue(screen.contains("if (!locationIncidentReady)"))
        assertTrue(
            safetyCenter!!.contains(
                "foregroundLocationReady = hasForegroundLocation",
            ),
        )
        assertTrue(
            safetyCenter.contains(
                "backgroundLocationReady = hasBackgroundLocation",
            ),
        )
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
        assertTrue(text.contains("managedPushRegistrationMutex.withLock"))

        val registration = text
            .substringAfter("suspend fun registerManagedPushToken(token: String): Boolean")
            .substringBefore("suspend fun registerCurrentManagedPushToken()")
        val disconnect = text
            .substringAfter("suspend fun disconnect()")
            .substringBefore("suspend fun sendDeletionCode(")
        assertTrue(registration.contains("managedPushRegistrationMutex.withLock"))
        assertTrue(registration.contains("\"reason\" to \"managed_state_changed\""))
        assertTrue(disconnect.contains("managedPushRegistrationMutex.withLock"))
        assertTrue(disconnect.contains("syncMutex.withLock"))
        assertTrue(disconnect.contains("managedDocumentProfileBindingJob?.cancelAndJoin()"))
        assertTrue(disconnect.contains("\"managed_sync.disconnect_serialization\""))
        assertTrue(
            disconnect.indexOf("managedDisconnecting = true") <
                disconnect.indexOf("syncMutex.withLock"),
        )
        assertTrue(
            disconnect.indexOf("managedDocumentProfileBindingJob?.cancelAndJoin()") <
                disconnect.indexOf("managedPushRegistrationMutex.withLock"),
        )
        assertTrue(
            disconnect.indexOf("releaseManagedDocumentProfile()") <
                disconnect.indexOf("runtime().auth.signOut()"),
        )
        assertTrue(text.contains(
            "if (accountScopeHash != null && managedDisconnecting) return",
        ))
        assertTrue(text.contains(
            "if (accountScopeHash != null && managedDisconnecting) return@launch",
        ))
    }

    @Test
    fun managedSafetyLocationPersistenceIsOpaqueBoundedAndCleared() {
        val session = source(
            "src/main/java/com/noop/managed/ManagedSafetyLiveLocationSession.kt",
            "app/src/main/java/com/noop/managed/ManagedSafetyLiveLocationSession.kt",
            "android/app/src/main/java/com/noop/managed/ManagedSafetyLiveLocationSession.kt",
        )
        val cloud = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        assumeTrue(session != null && cloud != null)
        val text = session!!

        assertTrue(text.contains("private const val INCIDENT_ID = \"incident_id\""))
        assertTrue(text.contains("private const val EXPIRES_AT_UNIX = \"expires_at_unix\""))
        assertTrue(
            text.contains(
                "internal const val MAXIMUM_SESSION_SECONDS = 12L * 60L * 60L",
            ),
        )
        assertEquals(1, Regex("""\.putString\(INCIDENT_ID,""").findAll(text).count())
        assertEquals(1, Regex("""\.putLong\(EXPIRES_AT_UNIX,""").findAll(text).count())

        val storedState = text
            .substringAfter("data class State(")
            .substringBefore(") {")
        val start = text
            .substringAfter("fun start(")
            .substringBefore("@Synchronized\n    fun stop(")
        for (sensitiveField in listOf("latitude", "longitude", "accuracy")) {
            assertFalse(storedState.contains(sensitiveField, ignoreCase = true))
            assertFalse(start.contains(sensitiveField, ignoreCase = true))
        }

        val initialize = text
            .substringAfter("fun initialize(context: Context)")
            .substringBefore("@Synchronized\n    fun start(")
        assertTrue(initialize.contains("if (!mutableState.value.isActiveAt(nowUnix))"))
        assertTrue(initialize.contains("preferences.edit().clear().apply()"))

        val stop = text
            .substringAfter("fun stop(context: Context, expectedIncidentId: UUID? = null)")
            .substringBefore("internal fun activeOwnerIncident(")
        assertTrue(stop.contains("mutableState.value = State()"))
        assertTrue(stop.contains("preferences(context).edit().clear().apply()"))

        val cloudText = cloud!!
        assertTrue(
            cloudText.contains(
                "if (state.value.phase != ManagedCloudPhase.ENROLLED || incident == null)",
            ),
        )
        assertTrue(cloudText.contains("stopManagedSafetyLocationSession(\"inactive\")"))
        assertTrue(
            cloudText.contains(
                "stopManagedSafetyLocationSession(\"invalid_expiry\")",
            ),
        )
        assertTrue(
            cloudText.contains(
                "stopManagedSafetyLocationSession(\"server_terminal\")",
            ),
        )
        assertTrue(
            cloudText.contains(
                "stopManagedSafetyLocationSession(\"presentation_cleared\")",
            ),
        )
    }

    @Test
    fun inviteRedemptionExplainsThatTheRedeemerMustAccept() {
        val cloud = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        val strings = source(
            "src/main/res/values/safety.xml",
            "app/src/main/res/values/safety.xml",
            "android/app/src/main/res/values/safety.xml",
        )
        assumeTrue(cloud != null && strings != null)
        val corrected =
            "Safety request added from the invitation. Accept it in Contact requests to finish setup."
        val reversed =
            "Safety request sent from the invitation. The other person must accept it."

        assertTrue(cloud!!.contains("managed_safety_status_invite_redeemed"))
        assertTrue(strings!!.contains(corrected))
        assertFalse(strings.contains(reversed))
    }
}
