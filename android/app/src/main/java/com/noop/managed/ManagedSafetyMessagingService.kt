package com.noop.managed

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.noop.notif.ManagedSafetyNotifier

class ManagedSafetyMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        if (token.isBlank()) return
        val scheduled = ManagedCloudScheduler.enqueuePushRegistration(applicationContext)
        com.noop.AppDiagnosticsRecorder.record(
            "managed_safety.push_token_refresh",
            fields = mapOf(
                "outcome" to if (scheduled) "deferred" else "failed",
                "worker" to if (scheduled) "scheduled" else "unavailable",
            ),
        )
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
        val notification = ManagedSafetyNotifier.post(applicationContext, incidentId)
        val scheduled = ManagedCloudScheduler.enqueueSafetyPush(
            applicationContext,
            incidentId,
        )
        com.noop.AppDiagnosticsRecorder.record(
            "managed_safety.push_received",
            fields = mapOf(
                "outcome" to if (scheduled) "deferred" else "failed",
                "notification" to notification,
                "worker" to if (scheduled) "scheduled" else "unavailable",
            ),
        )
    }

    companion object {
        const val EXTRA_INCIDENT_ID = "com.noop.extra.MANAGED_SAFETY_INCIDENT"
    }
}
