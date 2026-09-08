package com.noop.managed

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.noop.NoopApplication
import com.noop.notif.ManagedSafetyNotifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class ManagedSafetyMessagingService : FirebaseMessagingService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        val app = applicationContext as? NoopApplication ?: return
        if (!app.operationalRuntimeStarted) return
        scope.launch {
            app.managedCloud.registerManagedPushToken(token)
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val incidentId = ManagedSafetyPushPayload.incidentId(message.data)
        if (incidentId == null) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.push_received",
                fields = mapOf(
                    "outcome" to "rejected",
                    "failure_kind" to "invalid_payload",
                ),
            )
            return
        }
        val app = applicationContext as? NoopApplication
        if (app == null || !app.operationalRuntimeStarted) {
            val notification = ManagedSafetyNotifier.post(applicationContext, incidentId)
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.push_received",
                fields = mapOf(
                    "outcome" to "deferred",
                    "failure_kind" to "runtime_unavailable",
                    "notification" to notification,
                ),
            )
            return
        }
        scope.launch {
            val updated = app.managedCloud.handleManagedSafetyPush(incidentId)
            val notification = ManagedSafetyNotifier.post(applicationContext, incidentId)
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.push_received",
                fields = mapOf(
                    "outcome" to if (updated) "completed" else "failed",
                    "notification" to notification,
                ),
            )
        }
    }

    companion object {
        const val EXTRA_INCIDENT_ID = "com.noop.extra.MANAGED_SAFETY_INCIDENT"
    }
}
