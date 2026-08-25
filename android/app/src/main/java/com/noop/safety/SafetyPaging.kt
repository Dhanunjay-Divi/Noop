package com.noop.safety

import android.content.Context
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.noop.R
import com.noop.ble.WhoopConnectionService
import com.noop.data.SecurePrefs
import com.noop.sync.RemoteEndpointPolicy
import com.noop.sync.RemoteSyncPrefs
import java.io.IOException
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

enum class SafetyPagingSetupState { NEEDS_SERVER, NEEDS_ENROLLMENT, READY }

enum class SafetyContactStatus { PENDING, ACCEPTED, DECLINED, EXPIRED }

enum class SafetyDeliveryStatus {
    PENDING,
    SUBMITTING,
    LEASED,
    RETRY_WAIT,
    QUEUED,
    SENT,
    DELIVERED,
    FAILED,
    CANCELLED,
    UNKNOWN,
}

enum class SafetyIncidentStatus {
    OPEN,
    ACKNOWLEDGED,
    RESOLVED,
    CANCELLED,
    EXPIRED,
    PENDING,
    SUBMITTED,
    PARTIAL_FAILURE,
    FAILED,
}

enum class SafetyResponseDecision { RESPONDING, CANNOT_RESPOND }

enum class SafetyPageTrigger(val wireValue: String) {
    MANUAL_SOS("manual_sos"),
    BAND_SOS("band_sos"),
    VALIDATED_FALL("validated_fall"),
}

internal fun pendingSafetyPageBody(
    persistedBody: String?,
    hadPendingKey: Boolean,
    requestedBody: JSONObject,
): JSONObject {
    if (hadPendingKey) {
        persistedBody
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?.let { return it }
        return JSONObject()
            .put("trigger", SafetyPageTrigger.MANUAL_SOS.wireValue)
            .put("share_duration_hours", 8)
    }
    return requestedBody
}

internal fun shouldReplaceTerminalSafetyPageReplay(
    status: SafetyIncidentStatus,
    idempotentReplay: Boolean,
): Boolean = idempotentReplay &&
    status !in setOf(
        SafetyIncidentStatus.OPEN,
        SafetyIncidentStatus.ACKNOWLEDGED,
        SafetyIncidentStatus.PENDING,
    )

data class SafetyPagingContact(
    val contactId: String,
    val displayName: String,
    val phoneE164: String,
    val status: SafetyContactStatus,
    val invitationDeliveryStatus: SafetyDeliveryStatus,
    val invitationError: String?,
)

data class SafetyPagingDelivery(
    val deliveryId: String,
    val contactDisplayName: String,
    val channel: String,
    val escalationRound: Int,
    val status: SafetyDeliveryStatus,
    val error: String?,
    val attemptCount: Int,
    val maxAttempts: Int,
)

data class SafetyPagingResponse(
    val contactId: String,
    val contactDisplayName: String,
    val decision: SafetyResponseDecision,
    val source: String,
)

data class SafetyPagingLocation(
    val sequence: Long,
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracyMeters: Double?,
    val capturedAt: String,
    val receivedAt: String,
    val idempotentReplay: Boolean?,
)

data class SafetyContactSummary(
    val targeted: Int,
    val reached: Int,
    val pending: Int,
    val failed: Int,
    val lastReachedAt: String?,
    val allContactsFailed: Boolean,
)

internal fun shouldShowAllContactsFailed(
    status: SafetyIncidentStatus,
    summary: SafetyContactSummary?,
): Boolean = status == SafetyIncidentStatus.FAILED || summary?.allContactsFailed == true

data class SafetyPagingDispatch(
    val dispatchId: String,
    val idempotencyKey: String?,
    val trigger: SafetyPageTrigger,
    val status: SafetyIncidentStatus,
    val expiresAt: String?,
    val shareDurationHours: Int?,
    val escalationRounds: Int?,
    val escalationIntervalSeconds: Int?,
    val idempotentReplay: Boolean,
    val acknowledgedContactDisplayName: String?,
    val resolutionNote: String?,
    val deliveries: List<SafetyPagingDelivery>,
    val responses: List<SafetyPagingResponse>,
    val latestLocation: SafetyPagingLocation?,
    val contactSummary: SafetyContactSummary?,
)

internal data class SafetyPagingSnapshot(
    val contacts: List<SafetyPagingContact>,
    val acceptedCount: Int,
    val maximumContacts: Int,
    val pagingConfigured: Boolean,
    val pagingEnabled: Boolean?,
)

sealed class SafetyPagingException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class Network(cause: Throwable) :
        SafetyPagingException("Could not reach the safety paging server.", cause)
    class Server(val statusCode: Int, message: String) :
        SafetyPagingException(message)
    class InvalidResponse :
        SafetyPagingException("The safety paging server returned an invalid response.")
}

class SafetyPagingController(context: Context) {
    private val appContext = context.applicationContext

    var setupState by mutableStateOf(SafetyPagingPrefs.setupState(appContext))
        private set
    var contacts by mutableStateOf<List<SafetyPagingContact>>(emptyList())
        private set
    var acceptedCount by mutableStateOf(SafetyPagingPrefs.acceptedCount(appContext))
        private set
    var maximumContacts by mutableStateOf(5)
        private set
    var pagingConfigured by mutableStateOf(false)
        private set
    var pagingEnabled by mutableStateOf<Boolean?>(null)
        private set
    var isBusy by mutableStateOf(false)
        private set
    var statusMessage by mutableStateOf("")
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var lastDispatch by mutableStateOf<SafetyPagingDispatch?>(null)
        private set
    var recentIncidents by mutableStateOf<List<SafetyPagingDispatch>>(emptyList())
        private set

    val remainingAcceptedContacts: Int
        get() = (MINIMUM_ACCEPTED - acceptedCount).coerceAtLeast(0)

    val canPage: Boolean
        get() = setupState == SafetyPagingSetupState.READY &&
            acceptedCount >= MINIMUM_ACCEPTED && pagingConfigured && pagingEnabled != false &&
            activeIncident == null && !isBusy

    val activeIncident: SafetyPagingDispatch?
        get() = recentIncidents.firstOrNull {
            it.status in ACTIVE_INCIDENT_STATES
        } ?: lastDispatch?.takeIf { it.status in ACTIVE_INCIDENT_STATES }

    fun dismissError() {
        errorMessage = null
    }

    fun markSetupPresented() {
        SafetyPagingPrefs.setReminderRequired(appContext, true)
        SafetyContactSetupReminderScheduler.reconcile(appContext)
    }

    suspend fun bootstrap(displayNameInput: String) {
        val displayName = displayNameInput.trim()
        if (displayName.length !in 1..64) {
            errorMessage = "Enter your name so contacts know who invited them."
            return
        }
        val endpoint = RemoteSyncPrefs.endpoint().takeIf(String::isNotBlank)
        val adminToken = RemoteSyncPrefs.apiKey()
        if (endpoint == null || adminToken == null) {
            setupState = SafetyPagingSetupState.NEEDS_SERVER
            errorMessage =
                "Safety Network is unavailable. Check the service connection in Backup & Sync."
            return
        }
        withBusy {
            val pending = SafetyPagingPrefs.pendingEnrollment(
                appContext,
                endpoint = RemoteEndpointPolicy.normalize(endpoint),
                displayName = displayName,
            )
            val body = JSONObject()
                .put("display_name", pending.displayName)
                .put("installation_id", RemoteSyncPrefs.installationId())
                .put("enrollment_id", pending.enrollmentId)
                .put("safety_token", pending.token)
            val response = SafetyPagingClient(pending.endpoint, adminToken)
                .requestJson("POST", "v1/safety/bootstrap", body)
            val profile = response.optJSONObject("profile")
                ?: throw SafetyPagingException.InvalidResponse()
            val profileId = profile.optString("profile_id")
            if (profileId.isBlank()) throw SafetyPagingException.InvalidResponse()
            SafetyPagingPrefs.completeEnrollment(
                appContext,
                endpoint = pending.endpoint,
                profileId = profileId,
                displayName = profile.optString("display_name", pending.displayName),
            )
            pagingEnabled = profile.optionalBoolean("paging_enabled")
            setupState = SafetyPagingSetupState.READY
            statusMessage = ""
            reload()
        }
    }

    suspend fun refresh() {
        if (setupState != SafetyPagingSetupState.READY) {
            setupState = SafetyPagingPrefs.setupState(appContext)
            return
        }
        withBusy { reload() }
    }

    suspend fun addContact(displayNameInput: String, phoneInput: String): Boolean {
        val displayName = displayNameInput.trim()
        if (displayName.length !in 1..64) {
            errorMessage = "Enter a contact name."
            return false
        }
        val phone = normalizedE164(phoneInput)
        if (phone == null) {
            errorMessage =
                "Enter the full phone number with country code, for example +14155550123."
            return false
        }
        if (contacts.size >= maximumContacts) {
            errorMessage = "You can add up to five emergency contacts."
            return false
        }
        var added = false
        withBusy {
            val client = memberClient()
            val response = client.requestJson(
                "POST",
                "v1/safety/contacts",
                JSONObject()
                    .put("display_name", displayName)
                    .put("phone_e164", phone),
            )
            val contact = response.optJSONObject("contact")
                ?.let(::decodeContact)
                ?: throw SafetyPagingException.InvalidResponse()
            statusMessage = if (contact.invitationDeliveryStatus == SafetyDeliveryStatus.FAILED) {
                "Contact saved, but the invitation could not be delivered."
            } else {
                "Invitation sent. This contact must accept before paging is enabled."
            }
            if (contact.invitationDeliveryStatus == SafetyDeliveryStatus.FAILED) {
                errorMessage = contact.invitationError
                    ?: "The server could not send this invitation."
            }
            reload()
            added = true
        }
        return added
    }

    suspend fun resend(contact: SafetyPagingContact) {
        withBusy {
            val response = memberClient().requestJson(
                "POST",
                "v1/safety/contacts/${contact.contactId}/resend",
                JSONObject(),
            )
            val updated = response.optJSONObject("contact")
                ?.let(::decodeContact)
                ?: throw SafetyPagingException.InvalidResponse()
            statusMessage = if (updated.invitationDeliveryStatus == SafetyDeliveryStatus.FAILED) {
                "Invitation delivery failed."
            } else {
                "Invitation sent again."
            }
            if (updated.invitationDeliveryStatus == SafetyDeliveryStatus.FAILED) {
                errorMessage = updated.invitationError
                    ?: "The server could not send this invitation."
            }
            reload()
        }
    }

    suspend fun remove(contact: SafetyPagingContact) {
        withBusy {
            memberClient().requestNoContent(
                "DELETE",
                "v1/safety/contacts/${contact.contactId}",
            )
            statusMessage = "${contact.displayName} was removed."
            reload()
        }
    }

    suspend fun pageAcceptedContacts(
        trigger: SafetyPageTrigger = SafetyPageTrigger.MANUAL_SOS,
        shareDurationHours: Int = SafetyPagingPrefs.shareDurationHours(appContext),
        evidence: JSONObject? = null,
    ): Boolean {
        if (!canPage) {
            errorMessage = when {
                !pagingConfigured -> "SMS and voice paging are not configured on this server."
                pagingEnabled == false -> "Safety paging is disabled for this profile."
                else -> "At least two accepted emergency contacts are required."
            }
            return false
        }
        var submitted = false
        withBusy {
            val pendingKey = SafetyPagingPrefs.pendingPageKey(appContext)
            var key = pendingKey
                ?: UUID.randomUUID().toString()
            val requestedBody = JSONObject()
                .put("trigger", trigger.wireValue)
                .put(
                    "share_duration_hours",
                    if (shareDurationHours == 12) 12 else 8,
                )
            if (evidence != null) requestedBody.put("evidence", evidence)
            var body = pendingSafetyPageBody(
                persistedBody = SafetyPagingPrefs.pendingPageBody(appContext),
                hadPendingKey = pendingKey != null,
                requestedBody = requestedBody,
            )
            check(
                SafetyPagingPrefs.setPendingPage(
                    appContext,
                    key = key,
                    body = body.toString(),
                ),
            ) { "Safety page retry state could not be saved." }
            try {
                val client = memberClient()
                var replacedTerminalReplay = false
                while (true) {
                    val response = client.requestJson(
                        method = "POST",
                        path = "v1/safety/incidents",
                        body = body,
                        idempotencyKey = key,
                    )
                    val dispatch = decodeDispatch(response)
                    check(SafetyPagingPrefs.clearPendingPage(appContext)) {
                        "Safety page retry state could not be cleared."
                    }
                    if (
                        shouldReplaceTerminalSafetyPageReplay(
                            dispatch.status,
                            dispatch.idempotentReplay,
                        ) &&
                        !replacedTerminalReplay
                    ) {
                        replacedTerminalReplay = true
                        key = UUID.randomUUID().toString()
                        body = requestedBody
                        check(
                            SafetyPagingPrefs.setPendingPage(
                                appContext,
                                key = key,
                                body = body.toString(),
                            ),
                        ) { "Safety page retry state could not be saved." }
                        continue
                    }
                    lastDispatch = dispatch
                    merge(dispatch)
                    if (dispatch.status in ACTIVE_INCIDENT_STATES) {
                        SafetyLiveLocationSession.start(
                            appContext,
                            dispatch.dispatchId,
                            expiresAtUnix = dispatch.expiresAt?.let(::parseIsoInstantUnix),
                            startingSequence = dispatch.latestLocation?.sequence ?: 0L,
                        )
                        SafetyIncidentStatusMonitor.start(
                            appContext,
                            dispatch.dispatchId,
                            dispatch.expiresAt?.let(::parseIsoInstantUnix),
                        )
                        WhoopConnectionService.start(appContext)
                    }
                    statusMessage = appContext.getString(R.string.safety_page_detail_submitted)
                    submitted = dispatch.status != SafetyIncidentStatus.FAILED
                    break
                }
            } catch (error: Exception) {
                val serverStatus = (error as? SafetyPagingException.Server)?.statusCode
                if (!shouldRetainPageIdempotencyKey(serverStatus)) {
                    SafetyPagingPrefs.clearPendingPage(appContext)
                }
                throw error
            }
        }
        return submitted
    }

    suspend fun refreshLatestIncident() {
        if (setupState != SafetyPagingSetupState.READY) return
        runCatching {
            val client = memberClient()
            val current = activeIncident ?: lastDispatch
            if (current != null) {
                val refreshed = client.incident(current.dispatchId)
                reconcilePendingPage(refreshed)
                lastDispatch = refreshed
                merge(refreshed)
                reconcileObservedIncident(refreshed)
            } else {
                recentIncidents = client.incidents()
                recentIncidents.forEach(::reconcilePendingPage)
                lastDispatch = recentIncidents.firstOrNull()
                lastDispatch?.let {
                    reconcileObservedIncident(it)
                }
            }
            Unit
        }
    }

    suspend fun resolve(incident: SafetyPagingDispatch) {
        transition(incident, "resolve")
    }

    suspend fun cancel(incident: SafetyPagingDispatch) {
        transition(incident, "cancel")
    }

    private suspend fun transition(
        incident: SafetyPagingDispatch,
        action: String,
    ) {
        withBusy {
            val updated = memberClient().transition(incident.dispatchId, action)
            lastDispatch = updated
            merge(updated)
            SafetyLiveLocationSession.stop(
                appContext,
                expectedDispatchId = incident.dispatchId,
            )
            SafetyIncidentStatusMonitor.stop(
                appContext,
                expectedDispatchId = incident.dispatchId,
            )
            statusMessage = if (action == "resolve") {
                "Safety page marked resolved."
            } else {
                "Safety page cancelled."
            }
        }
    }

    private suspend fun reload() {
        val client = memberClient()
        val snapshot = client.contacts()
        contacts = snapshot.contacts
        acceptedCount = snapshot.acceptedCount
        maximumContacts = snapshot.maximumContacts
        pagingConfigured = snapshot.pagingConfigured
        pagingEnabled = snapshot.pagingEnabled
        SafetyPagingPrefs.setAcceptedCount(appContext, snapshot.acceptedCount)
        SafetyPagingPrefs.setReminderRequired(
            appContext,
            snapshot.acceptedCount < MINIMUM_ACCEPTED,
        )
        SafetyContactSetupReminderScheduler.reconcile(appContext)
        statusMessage = readinessStatusMessage(snapshot)
        recentIncidents = client.incidents()
        recentIncidents.forEach(::reconcilePendingPage)
        lastDispatch = recentIncidents.firstOrNull()
        lastDispatch?.let {
            reconcileObservedIncident(it)
        }
    }

    private fun reconcileObservedIncident(incident: SafetyPagingDispatch) {
        val notificationReconciled =
            SafetyIncidentStatusMonitor.observe(appContext, incident)
        if (incident.status !in ACTIVE_INCIDENT_STATES) {
            SafetyLiveLocationSession.stop(
                appContext,
                expectedDispatchId = incident.dispatchId,
            )
            if (notificationReconciled) {
                SafetyIncidentStatusMonitor.stop(
                    appContext,
                    expectedDispatchId = incident.dispatchId,
                )
            } else {
                SafetyIncidentStatusMonitor.reconcile(appContext)
            }
        }
    }

    private fun reconcilePendingPage(incident: SafetyPagingDispatch) {
        val pendingKey = SafetyPagingPrefs.pendingPageKey(appContext) ?: return
        if (incident.idempotencyKey == pendingKey) {
            SafetyPagingPrefs.clearPendingPage(appContext)
        }
    }

    private fun merge(incident: SafetyPagingDispatch) {
        recentIncidents = (
            listOf(incident) +
                recentIncidents.filterNot { it.dispatchId == incident.dispatchId }
            ).take(10)
    }

    private fun memberClient(): SafetyPagingClient {
        val endpoint = SafetyPagingPrefs.endpoint(appContext)
        val token = SafetyPagingPrefs.token(appContext)
        if (endpoint.isBlank() || token == null) {
            throw SafetyPagingException.Server(
                401,
                "Finish Safety setup before managing emergency contacts.",
            )
        }
        return SafetyPagingClient(endpoint, token)
    }

    private suspend fun withBusy(operation: suspend () -> Unit) {
        if (isBusy) return
        isBusy = true
        errorMessage = null
        try {
            operation()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            errorMessage = error.message ?: "Safety could not complete this request."
        } finally {
            isBusy = false
        }
    }

    companion object {
        const val MINIMUM_ACCEPTED = 2
        private val ACTIVE_INCIDENT_STATES = setOf(
            SafetyIncidentStatus.OPEN,
            SafetyIncidentStatus.ACKNOWLEDGED,
            SafetyIncidentStatus.PENDING,
        )

        fun normalizedE164(raw: String): String? {
            var compact = raw.filter { it == '+' || it in '0'..'9' }
            if (compact.startsWith("00")) compact = "+${compact.drop(2)}"
            if (!compact.startsWith('+')) return null
            val digits = compact.drop(1)
            return compact.takeIf {
                digits.length in 8..15 &&
                    digits.firstOrNull() != '0' &&
                    digits.all { it in '0'..'9' }
            }
        }

        private val strictE164 = Regex("""^\+[1-9][0-9]{7,14}$""")

        fun isStrictE164(raw: String): Boolean = strictE164.matches(raw)

        internal fun isReadySnapshot(snapshot: SafetyPagingSnapshot): Boolean =
            snapshot.acceptedCount >= MINIMUM_ACCEPTED &&
                snapshot.pagingConfigured &&
                snapshot.pagingEnabled != false

        internal fun readinessStatusMessage(snapshot: SafetyPagingSnapshot): String =
            if (isReadySnapshot(snapshot)) "Safety paging is ready." else ""

        internal fun shouldRetainPageIdempotencyKey(serverStatus: Int?): Boolean =
            serverStatus == null || serverStatus !in 400..499
    }
}

private class SafetyPagingClient(
    endpointInput: String,
    private val bearerToken: String,
) {
    private val endpoint = RemoteEndpointPolicy.normalize(endpointInput)
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .build()

    suspend fun contacts(): SafetyPagingSnapshot {
        val json = requestJson("GET", "v1/safety/contacts")
        return decodeSafetyPagingSnapshot(json)
    }

    suspend fun incidents(limit: Int = 10): List<SafetyPagingDispatch> {
        val json = requestJson(
            "GET",
            "v1/safety/incidents?limit=${limit.coerceIn(1, 100)}",
        )
        val rows = json.optJSONArray("incidents") ?: JSONArray()
        return buildList {
            for (index in 0 until rows.length()) {
                rows.optJSONObject(index)?.let { add(decodeDispatch(it)) }
            }
        }
    }

    suspend fun incident(dispatchId: String): SafetyPagingDispatch =
        decodeDispatch(
            requestJson(
                "GET",
                "v1/safety/incidents/$dispatchId",
            ),
        )

    suspend fun transition(
        dispatchId: String,
        action: String,
    ): SafetyPagingDispatch = decodeDispatch(
        requestJson(
            "POST",
            "v1/safety/incidents/$dispatchId/$action",
            JSONObject(),
        ),
    )

    suspend fun updateLocation(
        dispatchId: String,
        sequence: Long,
        location: SafetyLocation,
    ): SafetyPagingLocation {
        val body = JSONObject()
            .put("sequence", sequence)
            .put("latitude", location.latitude)
            .put("longitude", location.longitude)
            .put("captured_at", Instant.ofEpochSecond(location.capturedAtUnix).toString())
        location.horizontalAccuracyMeters?.let {
            body.put("horizontal_accuracy_meters", it)
        }
        val response = requestJson(
            "PUT",
            "v1/safety/incidents/$dispatchId/location",
            body,
        )
        return response.optJSONObject("location")
            ?.let(::decodeLocation)
            ?: throw SafetyPagingException.InvalidResponse()
    }

    suspend fun requestNoContent(method: String, path: String) {
        execute(method, path, null, null)
    }

    suspend fun requestJson(
        method: String,
        path: String,
        body: JSONObject? = null,
        idempotencyKey: String? = null,
    ): JSONObject {
        val raw = execute(method, path, body, idempotencyKey)
        return runCatching { JSONObject(raw) }
            .getOrElse { throw SafetyPagingException.InvalidResponse() }
    }

    private suspend fun execute(
        method: String,
        path: String,
        body: JSONObject?,
        idempotencyKey: String?,
    ): String = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url("${endpoint.trimEnd('/')}/${path.trimStart('/')}")
            .header("Accept", "application/json")
            .header("Authorization", "Bearer $bearerToken")
            .header("User-Agent", "Noop-Android/safety-paging-v1")
        if (idempotencyKey != null) {
            builder.header("Idempotency-Key", idempotencyKey)
        }
        val requestBody = body?.toString()?.toRequestBody(JSON)
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post(requestBody ?: "{}".toRequestBody(JSON))
            "PUT" -> builder.put(requestBody ?: "{}".toRequestBody(JSON))
            "DELETE" -> builder.delete()
            else -> error("Unsupported safety request method")
        }
        val response = try {
            http.newCall(builder.build()).execute()
        } catch (error: IOException) {
            throw SafetyPagingException.Network(error)
        }
        response.use {
            val raw = runCatching { it.body?.string().orEmpty() }.getOrDefault("")
            if (!it.isSuccessful) {
                val detail = runCatching {
                    JSONObject(raw).optString("detail")
                }.getOrDefault("").take(300)
                throw SafetyPagingException.Server(
                    it.code,
                    detail.ifBlank {
                        "Safety paging request failed (HTTP ${it.code})."
                    },
                )
            }
            raw
        }
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}

private fun decodeContact(json: JSONObject): SafetyPagingContact =
    SafetyPagingContact(
        contactId = json.optString("contact_id"),
        displayName = json.optString("display_name"),
        phoneE164 = json.optString("phone_e164"),
        status = enumValueOrDefault(
            json.optString("status"),
            SafetyContactStatus.PENDING,
        ),
        invitationDeliveryStatus = enumValueOrDefault(
            json.optString("invitation_delivery_status"),
            SafetyDeliveryStatus.PENDING,
        ),
        invitationError = json.nullableString("invitation_error"),
    )

internal fun decodeSafetyPagingSnapshot(json: JSONObject): SafetyPagingSnapshot {
    val rows = json.optJSONArray("contacts") ?: JSONArray()
    val contacts = buildList {
        for (index in 0 until rows.length()) {
            rows.optJSONObject(index)?.let { add(decodeContact(it)) }
        }
    }
    return SafetyPagingSnapshot(
        contacts = contacts,
        acceptedCount = json.optInt("accepted_count", 0).coerceAtLeast(0),
        maximumContacts = json.optInt("maximum_contacts", 5).coerceAtLeast(0),
        pagingConfigured = json.optBoolean("paging_configured", false),
        pagingEnabled = json.optionalBoolean("paging_enabled"),
    )
}

internal fun decodeDispatch(json: JSONObject): SafetyPagingDispatch {
    val rows = json.optJSONArray("deliveries") ?: JSONArray()
    val deliveries = buildList {
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            add(
                SafetyPagingDelivery(
                    deliveryId = row.optString("delivery_id"),
                    contactDisplayName = row.optString("contact_display_name"),
                    channel = row.optString("channel"),
                    escalationRound = row.optInt("escalation_round", 0),
                    status = enumValueOrDefault(
                        row.optString("status"),
                        SafetyDeliveryStatus.PENDING,
                    ),
                    error = row.nullableString("error"),
                    attemptCount = row.optInt("attempt_count", 0),
                    maxAttempts = row.optInt("max_attempts", 0),
                ),
            )
        }
    }
    val responseRows = json.optJSONArray("responses") ?: JSONArray()
    val responses = buildList {
        for (index in 0 until responseRows.length()) {
            val row = responseRows.optJSONObject(index) ?: continue
            add(
                SafetyPagingResponse(
                    contactId = row.optString("contact_id"),
                    contactDisplayName = row.optString("contact_display_name"),
                    decision = enumValueOrDefault(
                        row.optString("decision"),
                        SafetyResponseDecision.CANNOT_RESPOND,
                    ),
                    source = row.optString("source"),
                ),
            )
        }
    }
    return SafetyPagingDispatch(
        dispatchId = json.optString("dispatch_id"),
        idempotencyKey = json.nullableString("idempotency_key"),
        trigger = SafetyPageTrigger.entries.firstOrNull {
            it.wireValue == json.optString("trigger")
        } ?: SafetyPageTrigger.MANUAL_SOS,
        status = enumValueOrDefault(
            json.optString("status"),
            SafetyIncidentStatus.FAILED,
        ),
        expiresAt = json.nullableString("expires_at"),
        shareDurationHours = json.strictInt("share_duration_hours"),
        escalationRounds = json.strictInt("escalation_rounds"),
        escalationIntervalSeconds = json.strictInt("escalation_interval_seconds"),
        idempotentReplay = json.optBoolean("idempotent_replay", false),
        acknowledgedContactDisplayName =
            json.nullableString("acknowledged_contact_display_name"),
        resolutionNote = json.nullableString("resolution_note"),
        deliveries = deliveries,
        responses = responses,
        latestLocation = json.optJSONObject("latest_location")?.let(::decodeLocation),
        contactSummary = json.optJSONObject("contact_summary")?.let(::decodeContactSummary),
    )
}

internal fun parseIsoInstantUnix(raw: String): Long? =
    runCatching { Instant.parse(raw).epochSecond }.getOrNull()

private fun decodeLocation(json: JSONObject): SafetyPagingLocation =
    SafetyPagingLocation(
        sequence = json.optLong("sequence"),
        latitude = json.optDouble("latitude"),
        longitude = json.optDouble("longitude"),
        horizontalAccuracyMeters = json
            .takeIf { it.has("horizontal_accuracy_meters") && !it.isNull("horizontal_accuracy_meters") }
            ?.optDouble("horizontal_accuracy_meters"),
        capturedAt = json.optString("captured_at"),
        receivedAt = json.optString("received_at"),
        idempotentReplay = json
            .takeIf { it.has("idempotent_replay") }
            ?.optBoolean("idempotent_replay"),
    )

private fun decodeContactSummary(json: JSONObject): SafetyContactSummary? {
    val targeted = json.strictInt("targeted") ?: return null
    val reached = json.strictInt("reached") ?: return null
    val pending = json.strictInt("pending") ?: return null
    val failed = json.strictInt("failed") ?: return null
    val allContactsFailed = json.opt("all_contacts_failed") as? Boolean ?: return null
    val lastReachedAt = when (val raw = json.opt("last_reached_at")) {
        null, JSONObject.NULL -> null
        is String -> raw.takeIf(String::isNotBlank)
        else -> return null
    }
    if (
        targeted <= 0 ||
        reached !in 0..targeted ||
        pending !in 0..targeted ||
        failed !in 0..targeted ||
        reached + pending + failed != targeted ||
        allContactsFailed != (failed == targeted)
    ) {
        return null
    }
    return SafetyContactSummary(
        targeted = targeted,
        reached = reached,
        pending = pending,
        failed = failed,
        lastReachedAt = lastReachedAt,
        allContactsFailed = allContactsFailed,
    )
}

private fun JSONObject.strictInt(key: String): Int? =
    when (val raw = opt(key)) {
        is Int -> raw
        is Long -> raw.takeIf {
            it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()
        }?.toInt()
        else -> null
    }

internal suspend fun fetchSafetyIncident(
    context: Context,
    dispatchId: String,
): SafetyPagingDispatch {
    val endpoint = SafetyPagingPrefs.endpoint(context)
    val token = SafetyPagingPrefs.token(context)
        ?: throw SafetyPagingException.Server(
            401,
            "Finish Safety setup before checking a page.",
        )
    if (endpoint.isBlank()) {
        throw SafetyPagingException.Server(
            401,
            "Finish Safety setup before checking a page.",
        )
    }
    return SafetyPagingClient(endpoint, token).incident(dispatchId)
}

internal suspend fun updateSafetyIncidentLocation(
    context: Context,
    dispatchId: String,
    sequence: Long,
    location: SafetyLocation,
): SafetyPagingLocation {
    val endpoint = SafetyPagingPrefs.endpoint(context)
    val token = SafetyPagingPrefs.token(context)
        ?: throw SafetyPagingException.Server(
            401,
            "Finish Safety setup before sharing location.",
        )
    if (endpoint.isBlank()) {
        throw SafetyPagingException.Server(
            401,
            "Finish Safety setup before sharing location.",
        )
    }
    return SafetyPagingClient(endpoint, token).updateLocation(
        dispatchId = dispatchId,
        sequence = sequence,
        location = location,
    )
}

private inline fun <reified T : Enum<T>> enumValueOrDefault(
    raw: String,
    fallback: T,
): T = enumValues<T>().firstOrNull {
    it.name.equals(raw.replace('-', '_'), ignoreCase = true)
} ?: fallback

private fun JSONObject.nullableString(key: String): String? =
    optString(key).takeIf { it.isNotBlank() && it != "null" }

private fun JSONObject.optionalBoolean(key: String): Boolean? =
    takeIf { has(key) && !isNull(key) }?.optBoolean(key)

internal object SafetyPagingPrefs {
    private const val STATE_FILE = "noop_safety_paging"
    private const val SECRET_FILE = "noop_safety_paging_secure"
    private const val ENDPOINT = "endpoint"
    private const val PROFILE_ID = "profile_id"
    private const val DISPLAY_NAME = "display_name"
    private const val ACCEPTED_COUNT = "accepted_count"
    private const val REMINDER_REQUIRED = "reminder_required"
    private const val PENDING_ENDPOINT = "pending_endpoint"
    private const val PENDING_ENROLLMENT_ID = "pending_enrollment_id"
    private const val PENDING_DISPLAY_NAME = "pending_display_name"
    private const val PENDING_PAGE_KEY = "pending_page_key"
    private const val PENDING_PAGE_BODY = "pending_page_body"
    private const val SHARE_DURATION_HOURS = "share_duration_hours"
    private const val TOKEN = "safety_token"

    data class PendingEnrollment(
        val endpoint: String,
        val enrollmentId: String,
        val displayName: String,
        val token: String,
    )

    private fun state(context: Context) =
        context.applicationContext.getSharedPreferences(STATE_FILE, Context.MODE_PRIVATE)

    private fun secrets(context: Context) = SecurePrefs.of(context, SECRET_FILE)

    fun endpoint(context: Context): String =
        state(context).getString(ENDPOINT, null).orEmpty()

    fun token(context: Context): String? =
        secrets(context).getString(TOKEN, null)?.takeIf(String::isNotBlank)

    fun acceptedCount(context: Context): Int =
        state(context).getInt(ACCEPTED_COUNT, 0).coerceAtLeast(0)

    fun reminderRequired(context: Context): Boolean =
        state(context).getBoolean(REMINDER_REQUIRED, false)

    fun setupState(context: Context): SafetyPagingSetupState = when {
        state(context).getString(PROFILE_ID, null).isNullOrBlank().not() &&
            endpoint(context).isNotBlank() && token(context) != null ->
            SafetyPagingSetupState.READY
        RemoteSyncPrefs.isConfigured() -> SafetyPagingSetupState.NEEDS_ENROLLMENT
        else -> SafetyPagingSetupState.NEEDS_SERVER
    }

    fun pendingEnrollment(
        context: Context,
        endpoint: String,
        displayName: String,
    ): PendingEnrollment {
        val prefs = state(context)
        val existingEndpoint = prefs.getString(PENDING_ENDPOINT, null)
        val existingEnrollment = prefs.getString(PENDING_ENROLLMENT_ID, null)
        val existingName = prefs.getString(PENDING_DISPLAY_NAME, null)
        val existingToken = token(context)
        if (
            existingEndpoint == endpoint &&
            !existingEnrollment.isNullOrBlank() &&
            !existingName.isNullOrBlank() &&
            existingToken != null
        ) {
            return PendingEnrollment(
                endpoint,
                existingEnrollment,
                existingName,
                existingToken,
            )
        }
        val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
        val suffix = Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        val safetyToken = "noop_safety_$suffix"
        check(secrets(context).edit().putString(TOKEN, safetyToken).commit()) {
            "The private safety credential could not be saved securely."
        }
        val enrollmentId = UUID.randomUUID().toString()
        check(
            prefs.edit()
                .putString(PENDING_ENDPOINT, endpoint)
                .putString(PENDING_ENROLLMENT_ID, enrollmentId)
                .putString(PENDING_DISPLAY_NAME, displayName)
                .commit(),
        ) { "Safety enrollment could not be saved." }
        return PendingEnrollment(endpoint, enrollmentId, displayName, safetyToken)
    }

    fun completeEnrollment(
        context: Context,
        endpoint: String,
        profileId: String,
        displayName: String,
    ) {
        check(
            state(context).edit()
                .putString(ENDPOINT, endpoint)
                .putString(PROFILE_ID, profileId)
                .putString(DISPLAY_NAME, displayName)
                .remove(PENDING_ENDPOINT)
                .remove(PENDING_ENROLLMENT_ID)
                .remove(PENDING_DISPLAY_NAME)
                .commit(),
        ) { "Safety profile state could not be saved." }
    }

    fun setAcceptedCount(context: Context, value: Int) {
        state(context).edit().putInt(ACCEPTED_COUNT, value.coerceAtLeast(0)).apply()
    }

    fun setReminderRequired(context: Context, required: Boolean) {
        state(context).edit().putBoolean(REMINDER_REQUIRED, required).apply()
    }

    fun pendingPageKey(context: Context): String? =
        state(context).getString(PENDING_PAGE_KEY, null)

    fun pendingPageBody(context: Context): String? =
        state(context).getString(PENDING_PAGE_BODY, null)

    fun setPendingPage(context: Context, key: String, body: String): Boolean =
        state(context).edit()
            .putString(PENDING_PAGE_KEY, key)
            .putString(PENDING_PAGE_BODY, body)
            .commit()

    fun clearPendingPage(context: Context): Boolean =
        state(context).edit()
            .remove(PENDING_PAGE_KEY)
            .remove(PENDING_PAGE_BODY)
            .commit()

    fun shareDurationHours(context: Context): Int =
        if (state(context).getInt(SHARE_DURATION_HOURS, 8) == 12) 12 else 8

    fun setShareDurationHours(context: Context, hours: Int) {
        state(context).edit()
            .putInt(SHARE_DURATION_HOURS, if (hours == 12) 12 else 8)
            .apply()
    }
}
