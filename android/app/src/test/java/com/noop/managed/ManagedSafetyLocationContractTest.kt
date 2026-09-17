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
        val boot = source(
            "src/main/java/com/noop/ble/BackgroundReconnectPolicy.kt",
            "app/src/main/java/com/noop/ble/BackgroundReconnectPolicy.kt",
            "android/app/src/main/java/com/noop/ble/BackgroundReconnectPolicy.kt",
        )
        assumeTrue(
            service != null &&
                cloud != null &&
                application != null &&
                screen != null &&
                boot != null,
        )

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
        assertTrue(cloud.contains("hasUsableHorizontalAccuracy"))
        assertTrue(screen.contains("managedSafetyLocationDetail(location)"))
        assertTrue(screen.contains("R.string.safety_location_accuracy_format"))
        assertTrue(screen.contains("Instant.parse(location.capturedAt)"))
        assertTrue(screen.contains("FormatStyle.MEDIUM"))
        assertTrue(screen.contains("managedSafetyLocationCanUpload("))
        assertFalse(cloud.contains("horizontalAccuracyMeters ?: 10_000.0"))
        assertTrue(cloud.contains("\"failure_kind\" to \"invalid_location\""))
        val replaceLocation = cloud
            .substringAfter("private suspend fun replaceManagedSafetyLocation(")
            .substringBefore("private fun reconcileManagedSafetyLocationSession(")
        val permissionCheck = replaceLocation.indexOf(
            "ManagedSafetyLocationAuthorization.isAuthorized(",
        )
        val transport = replaceLocation.indexOf(
            "client().updateSafetyLocation(",
        )
        assertTrue(permissionCheck >= 0)
        assertTrue(permissionCheck < transport)
        assertTrue(replaceLocation.contains("\"failure_kind\" to \"location_not_authorized\""))
        assertTrue(replaceLocation.contains("\"authorization_revoked\""))
        assertTrue(replaceLocation.contains("SafetyLocationUploadOutcome.STOP"))
        assertTrue(service.contains("ManagedSafetyLocationAuthorizationWatchdog"))
        assertTrue(service.contains(".INTERVAL_MILLIS"))
        assertTrue(service.contains(".shouldStop("))
        assertTrue(service.contains(
            ".reconcileSafetyLocationAuthorizationForRuntime()",
        ))
        assertTrue(service.contains("ManagedSafetyLocationAuthorization.isAuthorized("))
        val authorization = cloud
            .substringAfter("internal object ManagedSafetyLocationAuthorization")
            .substringBefore("internal fun managedSafetyLocationCanUpload(")
        assertTrue(authorization.contains("context.packageManager.checkPermission("))
        assertTrue(authorization.contains("AppOpsManager.permissionToOp("))
        assertTrue(authorization.contains("appOps.unsafeCheckOpRawNoThrow("))
        assertTrue(authorization.contains("appOps.checkOpNoThrow("))
        assertTrue(authorization.contains("Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q"))
        assertTrue(authorization.contains("AppOpsManager.MODE_ALLOWED"))
        assertTrue(authorization.contains("AppOpsManager.MODE_FOREGROUND"))
        assertTrue(authorization.contains("AppOpsManager.MODE_DEFAULT"))
        assertTrue(authorization.contains("getOrDefault(false)"))
        val authorizationLifecycle = cloud
            .substringAfter("internal fun reconcileSafetyLocationAuthorizationForRuntime(")
            .substringBefore("private fun stopManagedSafetyLocationSession(")
        assertTrue(authorizationLifecycle.contains(
            "ManagedSafetyLocationRuntimePolicy.decide(",
        ))
        assertTrue(authorizationLifecycle.contains(
            "ManagedSafetyLocationRuntimeAction.STOP",
        ))
        assertTrue(authorizationLifecycle.contains(
            "ManagedSafetyLocationRuntimeAction.START",
        ))
        val sessionReconciliation = cloud
            .substringAfter("private fun reconcileManagedSafetyLocationSession(")
            .substringBefore("internal fun stopSafetyLocationForRuntime(")
        val authorizationBeforeStart = sessionReconciliation.indexOf(
            "ManagedSafetyLocationAuthorization.isAuthorized(",
        )
        val sessionStart = sessionReconciliation.indexOf(
            "ManagedSafetyLiveLocationSession.start(",
        )
        assertTrue(authorizationBeforeStart >= 0)
        assertTrue(authorizationBeforeStart < sessionStart)
        assertTrue(boot!!.contains("managedLocationAuthorized"))
        assertTrue(boot.contains("ManagedSafetyLiveLocationSession.stop(context)"))
        assertTrue(boot.contains("\"authorization_revoked\""))
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
        assertTrue(createIncident.contains("initialLocation: SafetyLocation? = null"))
        assertTrue(createIncident.contains("managedSafetyLocationCanUpload("))
        assertTrue(createIncident.contains("location = initialLocation"))
        assertTrue(createIncident.contains(
            "if (shareLocation) initialLocation else null",
        ))
        assertTrue(createIncident.contains(
            "initialLocation = effectiveInitialLocation",
        ))
        assertTrue(createIncident.contains("\"failure_kind\" to \"invalid_location\""))
        assertTrue(
            createIncident.indexOf("ManagedSafetyLocationAuthorization.isAuthorized") <
                createIncident.indexOf("preferences.safetyIncidentRequest("),
        )
        assertTrue(
            createIncident.indexOf("managedSafetyLocationCanUpload(") <
                createIncident.indexOf("preferences.safetyIncidentRequest("),
        )
        assertTrue(createIncident.contains("managed_safety_location_needed"))
        assertFalse(createIncident.contains("managed_safety_location_background_body"))
        val initialCreate = screen!!
            .substringAfter("service.createSafetyIncident(")
            .substringBefore("contactToRemove?.let")
        assertFalse(initialCreate.contains("service.updateSafetyLocation("))
        assertTrue(
            screen.contains(
                "ManagedSafetyLocationAuthorization.canStartIncident(",
            ),
        )
        val updateLocation = screen
            .substringAfter("onUpdateLocation = { incident ->")
            .substringBefore("onOpenMap =")
        val updateGuard = updateLocation.indexOf("managedSafetyLocationCanUpload(")
        val updateLaunch = updateLocation.indexOf("scope.launch")
        val updateCall = updateLocation.indexOf("service.updateSafetyLocation(")
        assertTrue(updateGuard >= 0)
        assertTrue(updateGuard < updateLaunch)
        assertTrue(updateLaunch < updateCall)
        val incidents = screen
            .substringAfter("private fun ManagedSafetyIncidents(")
            .substringBefore("private fun managedSafetyIncidentStatusResource(")
        val buttonGuard = incidents.indexOf(
            "if (incident.shareLocation && currentLocationCanUpload)",
        )
        val buttonCallback = incidents.indexOf("onClick = { onUpdateLocation(incident) }")
        assertTrue(incidents.contains("currentLocationCanUpload"))
        assertTrue(buttonGuard >= 0)
        assertTrue(buttonGuard < buttonCallback)
        assertTrue(screen.contains("if (!locationIncidentReady)"))
        assertTrue(screen.contains(
            "if (shareLocation) fix else null",
        ))
        val clearRequest = createIncident.lastIndexOf(
            "preferences.clearSafetyIncidentRequest(request.requestId)",
        )
        val terminalReplay = createIncident.indexOf("val terminalReplay =")
        val stateReplacement = createIncident.indexOf("replaceState {")
        val refresh = createIncident.indexOf(
            "refreshSafetyData()",
            startIndex = stateReplacement,
        )
        assertTrue(clearRequest >= 0)
        assertTrue(clearRequest < terminalReplay)
        assertTrue(terminalReplay < stateReplacement)
        assertTrue(stateReplacement < refresh)
        assertTrue(createIncident.contains("creation.incident.duplicate"))
        assertTrue(createIncident.contains(
            "creation.incident.status in setOf(\"resolved\", \"canceled\", \"expired\")",
        ))
        assertTrue(createIncident.contains("R.string.managed_safety_status_up_to_date"))
        assertTrue(createIncident.contains("R.string.managed_safety_status_page_started"))
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
    fun incidentIdempotencyRecordDoesNotPersistPreciseLocationMaterial() {
        val preferences = source(
            "src/main/java/com/noop/managed/ManagedCloudPreferences.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudPreferences.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudPreferences.kt",
        )
        assumeTrue(preferences != null)

        val record = preferences!!
            .substringAfter("internal data class ManagedSafetyIncidentRequestRecord(")
            .substringBefore("internal object ManagedSafetyIncidentRequestPolicy")
            .lowercase()
        val encoder = preferences
            .substringAfter("private fun encodeSafetyIncidentRequest(")
            .substringBefore("private fun socialDeliveryReceipts(")
            .lowercase()

        for (sensitiveField in listOf(
            "latitude",
            "longitude",
            "horizontalaccuracy",
            "capturedat",
            "initial_location_digest",
            "initiallocationdigest",
        )) {
            assertFalse(record.contains(sensitiveField))
            assertFalse(encoder.contains(sensitiveField))
        }
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
