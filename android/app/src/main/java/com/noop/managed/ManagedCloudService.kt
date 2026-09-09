package com.noop.managed

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.icu.text.ListFormatter
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthException
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.PhoneAuthCredential
import com.google.firebase.auth.PhoneAuthOptions
import com.google.firebase.auth.PhoneAuthProvider
import com.google.firebase.auth.PhoneAuthProvider.ForceResendingToken
import com.google.firebase.messaging.FirebaseMessaging
import com.noop.NoopApplication
import com.noop.R
import com.noop.ble.WhoopConnectionService
import com.noop.data.BackupSettingsBridge
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.notif.ManagedSafetyNotifier
import com.noop.notif.ManagedSocialPokeNotifier
import com.noop.safety.SafetyLocation
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

enum class ManagedCloudPhase {
    UNAVAILABLE,
    SIGNED_OUT,
    CODE_SENT,
    CONSENT_REQUIRED,
    ENROLLED,
    DELETION_SCHEDULED,
}

data class ManagedCloudState(
    val phase: ManagedCloudPhase,
    val busy: Boolean = false,
    val status: String = "",
    val lastSuccessMs: Long = 0L,
    val deletionNotBefore: String? = null,
    val overview: ManagedStorageOverview? = null,
    val installations: List<ManagedInstallation> = emptyList(),
    val socialProfile: ManagedSocialProfile? = null,
    val socialFriends: List<ManagedSocialFriend> = emptyList(),
    val socialBlockedProfiles: List<ManagedSocialBlockedProfile> = emptyList(),
    val socialRequests: List<ManagedSocialRequest> = emptyList(),
    val socialFeed: List<ManagedSocialFeedDay> = emptyList(),
    val socialLookup: ManagedSocialLookupProfile? = null,
    val socialInvite: ManagedSocialInvite? = null,
    val socialStatus: String = "",
    val hasPendingSocialInvite: Boolean = false,
    val pendingSocialNoopId: String? = null,
    val safetyContacts: ManagedSafetyContacts? = null,
    val safetyRequests: List<ManagedSafetyRequest> = emptyList(),
    val safetyIncidents: List<ManagedSafetyIncident> = emptyList(),
    val safetyInvite: ManagedSafetyInvite? = null,
    val safetyStatus: String = "",
    val hasPendingSafetyInvite: Boolean = false,
)

data class ManagedCloudSyncSummary(
    val uploadedChunks: Int,
    val uploadedBytes: Long,
    val uploadedDocuments: Int,
    val appliedChanges: Int,
    val hasMore: Boolean,
    val prunedWindows: Int,
    val prunedRows: Int,
)

/**
 * Process owner for optional NOOP+ identity and managed storage.
 *
 * Firebase and all network clients remain dormant when the build has no managed configuration.
 * Every foreground and WorkManager caller shares [syncMutex], so a reconnect, manual tap, and
 * periodic wake cannot upload the same local window concurrently.
 */
class ManagedCloudService private constructor(context: Context) {
    private enum class SyncMode { MANUAL, AUTOMATIC, EXPORT_PREPARATION }
    internal enum class SafetyLocationUploadOutcome { ACCEPTED, RETRY, STOP }

    private val appContext = context.applicationContext
    private val configuration = ManagedCloudConfiguration.load()
    private val preferences by lazy { ManagedCloudPreferences(appContext) }
    private val database by lazy { WhoopDatabase.get(appContext) }
    private val application by lazy { appContext as NoopApplication }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val syncMutex = Mutex()
    private val socialMutex = Mutex()
    private val safetyMutex = Mutex()
    private val safetyLocationUpdateMutex = Mutex()
    private val firebaseLock = Any()
    private val stateLock = Any()

    @Volatile
    private var firebaseRuntime: FirebaseRuntime? = null
    @Volatile
    private var socialRunning = false
    @Volatile
    private var safetyRunning = false
    @Volatile
    private var safetyBootstrapRunning = false
    @Volatile
    private var managedDisconnecting = false
    private var safetyBootstrapJob: Job? = null

    private val mutableState = MutableStateFlow(
        ManagedCloudState(
            phase = if (configuration == null) {
                ManagedCloudPhase.UNAVAILABLE
            } else {
                ManagedCloudPhase.SIGNED_OUT
            },
        ),
    )
    val state: StateFlow<ManagedCloudState> = mutableState.asStateFlow()

    val isAvailable: Boolean get() = configuration != null
    val automatic: Boolean
        get() = runCatching { preferences.automatic }.getOrDefault(false)
    val maskedPhoneNumber: String
        get() = maskedPhone(runCatching { runtime().auth.currentUser?.phoneNumber }.getOrNull())

    init {
        if (configuration != null) {
            runCatching {
                ManagedSafetyLiveLocationSession.initialize(appContext)
                replaceState {
                    it.copy(
                        status = preferences.status,
                        lastSuccessMs = preferences.lastSuccessMs,
                        deletionNotBefore = preferences.erasureNotBefore,
                        hasPendingSocialInvite =
                            preferences.pendingSocialInviteCapability != null,
                        pendingSocialNoopId = preferences.pendingSocialNoopId,
                        hasPendingSafetyInvite =
                            preferences.pendingSafetyInviteCapability != null,
                    )
                }
            }
        }
    }

    /** Initializes persisted Firebase auth only for a configured build; it performs no upload. */
    fun bootstrap() {
        if (configuration == null) {
            stopManagedSafetyLocationSession("unavailable")
            replaceState { it.copy(phase = ManagedCloudPhase.UNAVAILABLE, busy = false) }
            return
        }
        runCatching {
            runtime()
            if (managedDeletionDeadlinePassed(preferences.erasureNotBefore)) {
                completeLocalDeletionHandoff()
                return
            }
            reconcileAuthenticatedState()
        }.onFailure { error ->
            replaceState {
                it.copy(
                    phase = ManagedCloudPhase.UNAVAILABLE,
                    busy = false,
                    status = userMessage(error),
                )
            }
        }
    }

    fun setAutomatic(enabled: Boolean) {
        val accepted = enabled && state.value.phase == ManagedCloudPhase.ENROLLED
        preferences.automatic = accepted
        ManagedCloudScheduler.reconcile(appContext)
        replaceState { it.copy() }
    }

    val optimizePhoneStorage: Boolean
        get() = preferences.optimizePhoneStorage

    fun setOptimizePhoneStorage(enabled: Boolean) {
        preferences.optimizePhoneStorage =
            enabled && state.value.phase == ManagedCloudPhase.ENROLLED
        replaceState { it.copy() }
    }

    suspend fun sendCode(activity: Activity, rawPhoneNumber: String) {
        if (!beginBusy()) return
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_auth.send_code",
        )
        try {
            val phone = normalizedPhone(rawPhoneNumber)
            val verificationId = requestPhoneVerification(activity, phone)
            if (verificationId != null) {
                preferences.verificationId = verificationId
                setPhase(ManagedCloudPhase.CODE_SENT)
                setStatus(text(R.string.managed_cloud_status_code_sent))
            }
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = diagnosticOperationOutcome(error),
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
        } finally {
            endBusy()
        }
    }

    suspend fun verifyCode(rawCode: String) {
        if (!beginBusy()) return
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_auth.verify_code",
        )
        try {
            val verificationId = preferences.verificationId
                ?: throw ManagedCloudException.CodeRequired
            val credential = PhoneAuthProvider.getCredential(
                verificationId,
                normalizedCode(rawCode),
            )
            runtime().auth.signInWithCredential(credential).awaitManaged()
            preferences.verificationId = null
            reconcileAuthenticatedState()
            if (state.value.phase == ManagedCloudPhase.CONSENT_REQUIRED) {
                setStatus(text(R.string.managed_cloud_status_phone_verified))
            } else {
                setStatus(text(R.string.managed_cloud_status_signed_in))
            }
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = diagnosticOperationOutcome(error),
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
        } finally {
            endBusy()
        }
    }

    suspend fun enroll() {
        if (!beginBusy()) return
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_enrollment",
        )
        try {
            val config = requireNotNull(configuration)
            val authorization = authorization(forceRefresh = true)
            client().enroll(
                authorization = authorization,
                requestId = preferences.enrollmentRequestId(),
                dataClasses = ManagedSyncCoordinator.DATA_CLASSES,
            )
            preferences.completeEnrollment(
                accountScopeHash = accountScopeHash(),
                policyVersion = config.storage.policyVersion,
            )
            setPhase(ManagedCloudPhase.ENROLLED)
            scheduleManagedSafetyBootstrap()
            setStatus(text(R.string.managed_cloud_status_enabled))
            ManagedCloudScheduler.reconcile(appContext)
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            if (runCatching { runtime().auth.currentUser != null }.getOrDefault(false)) {
                setPhase(ManagedCloudPhase.CONSENT_REQUIRED)
            }
            setStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = diagnosticOperationOutcome(error),
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            return
        } finally {
            endBusy()
        }
        syncNow()
    }

    suspend fun syncNow() {
        if (!beginBusy()) return
        try {
            val summary = performSync(SyncMode.MANUAL)
            if (summary.hasMore) {
                ManagedCloudScheduler.enqueueContinuation(appContext)
            }
            try {
                refreshSocialData(deliverPokes = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                setSocialStatus(userMessage(error))
                com.noop.AppDiagnosticsRecorder.record(
                    "managed_social.catch_up",
                    fields = mapOf(
                        "outcome" to "failed",
                        "failure_kind" to diagnosticSyncFailureKind(error),
                    ),
                )
            }
            try {
                refreshSafetyData()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                setSafetyStatus(userMessage(error))
                com.noop.AppDiagnosticsRecorder.record(
                    "managed_safety.catch_up",
                    fields = mapOf(
                        "outcome" to "failed",
                        "failure_kind" to diagnosticSyncFailureKind(error),
                    ),
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    suspend fun exportCompleteCloudHistory(destination: Uri) {
        if (!beginBusy()) return
        var writer: ManagedHistorySafArchiveWriter? = null
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation("managed_export")
        try {
            withContext(Dispatchers.IO) {
                for (pass in 1..MAXIMUM_EXPORT_PREPARATION_PASSES) {
                    coroutineContext.ensureActive()
                    setStatus(
                        text(
                            R.string.managed_cloud_status_export_preparing_pass,
                            pass,
                        ),
                    )
                    val summary = performSync(SyncMode.EXPORT_PREPARATION)
                    if (!summary.hasMore) break
                    if (pass == MAXIMUM_EXPORT_PREPARATION_PASSES) {
                        throw ManagedCloudException.ExportPreparationIncomplete
                    }
                }

                val archiveWriter = ManagedHistorySafArchiveWriter(
                    appContext,
                    destination,
                )
                writer = archiveWriter
                val manifest = ManagedHistoryExporter(client()).export(
                    authorization = ::authorization,
                    progress = ::setExportStatus,
                    consume = archiveWriter::add,
                )
                archiveWriter.finish(manifest)
                writer = null
                setStatus(text(R.string.managed_cloud_status_export_saved))
                com.noop.AppDiagnosticsRecorder.endOperation(
                    diagnostic,
                    outcome = "completed",
                    fields = mapOf(
                        "objects" to manifest.exportedObjects.toString(),
                        "chunk_bytes" to manifest.exportedChunkBytes.toString(),
                    ),
                    includeResourceSnapshot = true,
                )
            }
        } catch (error: CancellationException) {
            writer?.abort()
                ?: ManagedHistorySafArchiveWriter.removePartial(appContext, destination)
            setStatus(text(R.string.managed_cloud_status_export_canceled))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                includeResourceSnapshot = true,
            )
            throw error
        } catch (error: Throwable) {
            writer?.abort()
                ?: ManagedHistorySafArchiveWriter.removePartial(appContext, destination)
            setStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
                includeResourceSnapshot = true,
            )
        } finally {
            endBusy()
        }
    }

    internal suspend fun syncForWorker(): ManagedCloudSyncSummary =
        performSync(SyncMode.AUTOMATIC)

    internal suspend fun socialCatchUpForWorker(
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean {
        if (state.value.phase != ManagedCloudPhase.ENROLLED ||
            !preferences.socialEnabled ||
            !ManagedSocialRuntime.isCatchUpDue(
                preferences.socialLastAttemptMs,
                nowMs,
            )
        ) {
            return false
        }
        preferences.socialLastAttemptMs = nowMs
        return try {
            refreshSocialData(deliverPokes = true)
            true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_social.catch_up",
                fields = mapOf(
                    "outcome" to "failed",
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            throw error
        }
    }

    internal suspend fun safetyCatchUpForWorker(
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean {
        if (state.value.phase != ManagedCloudPhase.ENROLLED ||
            !preferences.safetyEnabled
        ) {
            return false
        }
        val previousAttempt = preferences.beginSafetyAttempt(
            nowMs,
            SAFETY_CATCH_UP_INTERVAL_MS,
        ) ?: return false
        return try {
            refreshSafetyData()
            true
        } catch (error: CancellationException) {
            preferences.rollbackSafetyAttempt(nowMs, previousAttempt)
            throw error
        } catch (error: Throwable) {
            preferences.rollbackSafetyAttempt(nowMs, previousAttempt)
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.catch_up",
                fields = mapOf(
                    "outcome" to "failed",
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            throw error
        }
    }

    suspend fun refreshOverview() {
        if (!beginBusy()) return
        try {
            val authorization = authorization(forceRefresh = false)
            val managedClient = client()
            val overview = managedClient.overview(authorization)
            val installations = managedClient.installations(authorization)
            replaceState {
                it.copy(
                    overview = overview,
                    installations = installations,
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    suspend fun revokeInstallation(installationId: String) {
        if (!beginBusy()) return
        try {
            val authorization = authorization(forceRefresh = true)
            val revoked = client().revokeInstallation(
                authorization,
                installationId,
            )
            replaceState {
                it.copy(
                    installations = it.installations.map { installation ->
                        if (installation.installationId == revoked.installationId) {
                            revoked
                        } else {
                            installation
                        }
                    },
                )
            }
            setStatus(text(R.string.managed_cloud_status_device_revoked))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    // MARK: Managed Safety

    fun stageSafetyInviteLink(uri: Uri?): Boolean {
        val capability = uri?.toString()
            ?.let(ManagedSafetyIdentifier::inviteCapability)
            ?: return false
        preferences.pendingSafetyInviteCapability = capability
        replaceState { it.copy(hasPendingSafetyInvite = true) }
        com.noop.AppDiagnosticsRecorder.record(
            "managed_safety.invite_link_staged",
            fields = mapOf(
                "outcome" to "accepted",
                "persistence" to "encrypted_preferences",
            ),
        )
        return true
    }

    fun safetyInviteUri(): Uri? =
        state.value.safetyInvite
            ?.takeIf { it.status == "active" }
            ?.let { ManagedSafetyIdentifier.inviteUrl(it.capability) }
            ?.let(Uri::parse)

    fun clearPendingSafetyInvite() {
        preferences.pendingSafetyInviteCapability = null
        replaceState { it.copy(hasPendingSafetyInvite = false) }
    }

    suspend fun registerManagedPushToken(token: String): Boolean {
        if (
            state.value.phase != ManagedCloudPhase.ENROLLED ||
            managedDisconnecting
        ) {
            return false
        }
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_safety.push_registration",
        )
        if (!managedSafetyNotificationPermissionGranted()) {
            retireManagedPushInstallationForNotificationSettings()
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "rejected",
                fields = mapOf(
                    "failure_kind" to "notification_not_authorized",
                ),
            )
            return false
        }
        return try {
            client().registerPushInstallation(
                authorization = authorization(forceRefresh = false),
                environment = if (com.noop.BuildConfig.DEBUG) {
                    ManagedPushEnvironment.DEVELOPMENT
                } else {
                    ManagedPushEnvironment.PRODUCTION
                },
                token = token,
            )
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
            )
            true
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            false
        }
    }

    suspend fun registerCurrentManagedPushToken(): Boolean {
        if (state.value.phase != ManagedCloudPhase.ENROLLED) return false
        if (!managedSafetyNotificationPermissionGranted()) {
            retireManagedPushInstallationForNotificationSettings()
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.notification_enable",
                fields = mapOf(
                    "outcome" to "rejected",
                    "failure_kind" to "notification_not_authorized",
                ),
            )
            return false
        }
        return try {
            ManagedSafetyNotifier.prepare(appContext)
            val messaging = runtime().messaging
            messaging.isAutoInitEnabled = true
            val token = messaging.token.awaitManaged()
            token.isNotBlank() && registerManagedPushToken(token)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.notification_enable",
                fields = mapOf(
                    "outcome" to "failed",
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            false
        }
    }

    suspend fun refreshSafety() =
        safetyAction("refresh") {
            refreshSafetyData()
        }

    suspend fun createSafetyInvite() =
        safetyAction("invite_create") {
            registerCurrentManagedPushToken()
            val managedClient = client()
            val auth = authorization(forceRefresh = true)
            var capability = preferences.safetyInviteCapability()
            var invite = managedClient.createSafetyInvite(
                authorization = auth,
                capability = capability,
                requestId = preferences.safetyInviteRequestId(),
            )
            if (invite.status != "active") {
                preferences.clearSafetyInviteRequestId()
                preferences.clearSafetyInviteCapability()
                capability = preferences.safetyInviteCapability()
                invite = managedClient.createSafetyInvite(
                    authorization = auth,
                    capability = capability,
                    requestId = preferences.safetyInviteRequestId(),
                )
            }
            if (invite.status != "active") {
                throw ManagedStorageException.InvalidResponse()
            }
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            replaceState {
                it.copy(
                    safetyInvite = invite,
                    safetyStatus = text(R.string.managed_safety_status_invite_ready),
                )
            }
        }

    suspend fun revokeSafetyInvite() =
        safetyAction("invite_revoke") {
            val invite = state.value.safetyInvite ?: return@safetyAction
            client().revokeSafetyInvite(
                authorization = authorization(forceRefresh = true),
                inviteId = invite.inviteId,
            )
            preferences.clearSafetyInviteRequestId()
            preferences.clearSafetyInviteCapability()
            replaceState {
                it.copy(
                    safetyInvite = null,
                    safetyStatus = text(R.string.managed_safety_status_invite_revoked),
                )
            }
        }

    suspend fun redeemPendingSafetyInvite() =
        safetyAction("invite_redeem") {
            val capability = preferences.pendingSafetyInviteCapability
                ?: return@safetyAction
            client().redeemSafetyInvite(
                authorization = authorization(forceRefresh = true),
                capability = capability,
                requestId = ManagedSafetyIdentifier.inviteRedemptionRequestId(
                    accountScopeHash(),
                    capability,
                ),
            )
            preferences.pendingSafetyInviteCapability = null
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            replaceState {
                it.copy(
                    hasPendingSafetyInvite = false,
                    safetyStatus = text(R.string.managed_safety_status_invite_redeemed),
                )
            }
            refreshSafetyData()
        }

    suspend fun createSafetyRequest(noopId: String) =
        safetyAction("request_create") {
            registerCurrentManagedPushToken()
            val canonical = ManagedSocialIdentifier.canonicalNoopId(noopId)
                ?: throw ManagedStorageException.InvalidResponse()
            val request = preferences.safetyContactRequest(
                accountScopeHash = accountScopeHash(),
                noopId = canonical,
            )
            try {
                client().createSafetyRequest(
                    authorization = authorization(forceRefresh = true),
                    noopId = canonical,
                    requestId = request.requestId,
                )
            } catch (error: Throwable) {
                if (ManagedSafetyContactRequestPolicy.shouldRetire(error)) {
                    preferences.clearSafetyContactRequest(request.requestId)
                }
                throw error
            }
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            setSafetyStatus(text(R.string.managed_safety_status_request_sent))
            refreshSafetyData()
            preferences.clearSafetyContactRequest(request.requestId)
        }

    suspend fun decideSafetyRequest(requestId: UUID, accept: Boolean) =
        safetyAction("request_decide") {
            if (accept) registerCurrentManagedPushToken()
            client().decideSafetyRequest(
                authorization = authorization(forceRefresh = true),
                requestId = requestId,
                accept = accept,
            )
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            setSafetyStatus(
                text(
                    if (accept) {
                        R.string.managed_safety_status_contact_accepted
                    } else {
                        R.string.managed_safety_status_contact_declined
                    },
                ),
            )
            refreshSafetyData()
        }

    suspend fun removeSafetyContact(profileId: UUID) =
        safetyAction("contact_remove") {
            client().removeSafetyContact(
                authorization = authorization(forceRefresh = true),
                profileId = profileId,
            )
            setSafetyStatus(text(R.string.managed_safety_status_contact_removed))
            refreshSafetyData()
        }

    suspend fun createSafetyIncident(
        durationHours: Int,
        shareLocation: Boolean,
    ): ManagedSafetyIncident? {
        var created: ManagedSafetyIncident? = null
        safetyAction("incident_create") {
            val request = preferences.safetyIncidentRequest(
                accountScopeHash = accountScopeHash(),
                durationHours = durationHours,
                shareLocation = shareLocation,
            )
            val creation = try {
                client().createSafetyIncident(
                    authorization = authorization(forceRefresh = true),
                    requestId = request.requestId,
                    durationHours = durationHours,
                    shareLocation = shareLocation,
                )
            } catch (error: Throwable) {
                if (shouldRetireSafetyIncidentRequest(error)) {
                    preferences.clearSafetyIncidentRequest(request.requestId)
                }
                throw error
            }
            preferences.clearSafetyIncidentRequest(request.requestId)
            created = creation.incident
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            replaceState {
                it.copy(
                    safetyIncidents = replaceSafetyIncident(
                        creation.incident,
                        it.safetyIncidents,
                    ),
                    safetyStatus = text(R.string.managed_safety_status_page_started),
                )
            }
            reconcileManagedSafetyLocationSession()
            refreshSafetyData()
        }
        return created
    }

    suspend fun updateSafetyLocation(
        incidentId: UUID,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyM: Double,
        capturedAt: Instant,
    ): Boolean =
        replaceManagedSafetyLocation(
            incidentId = incidentId,
            location = SafetyLocation(
                latitude = latitude,
                longitude = longitude,
                horizontalAccuracyMeters = horizontalAccuracyM,
                capturedAtUnix = capturedAt.epochSecond,
            ),
            source = "manual",
            requireActiveSession = false,
        ) == SafetyLocationUploadOutcome.ACCEPTED

    internal suspend fun updateSafetyLocationForStream(
        incidentId: UUID,
        location: SafetyLocation,
    ): SafetyLocationUploadOutcome =
        replaceManagedSafetyLocation(
            incidentId = incidentId,
            location = location,
            source = "stream",
            requireActiveSession = true,
        )

    suspend fun respondToSafetyIncident(incidentId: UUID, responding: Boolean) =
        safetyAction("incident_response") {
            val incident = client().respondToSafetyIncident(
                authorization = authorization(forceRefresh = true),
                incidentId = incidentId,
                responding = responding,
            )
            replaceState {
                it.copy(
                    safetyIncidents = replaceSafetyIncident(
                        incident,
                        it.safetyIncidents,
                    ),
                    safetyStatus = text(
                        if (responding) {
                            R.string.managed_safety_status_responding
                        } else {
                            R.string.managed_safety_status_cannot_respond
                        },
                    ),
                )
            }
        }

    suspend fun endSafetyIncident(incidentId: UUID, resolved: Boolean) =
        safetyAction("incident_end") {
            val incident = client().endSafetyIncident(
                authorization = authorization(forceRefresh = true),
                incidentId = incidentId,
                resolved = resolved,
            )
            preferences.clearSafetyLocationSequence(incidentId)
            replaceState {
                it.copy(
                    safetyIncidents = replaceSafetyIncident(
                        incident,
                        it.safetyIncidents,
                    ),
                    safetyStatus = text(
                        if (resolved) {
                            R.string.managed_safety_status_resolved
                        } else {
                            R.string.managed_safety_status_canceled
                        },
                    ),
                )
            }
            reconcileManagedSafetyLocationSession()
        }

    suspend fun retrySafetyPush(incidentId: UUID) =
        safetyAction("push_retry") {
            client().retrySafetyPush(
                authorization = authorization(forceRefresh = true),
                incidentId = incidentId,
            )
            setSafetyStatus(text(R.string.managed_safety_status_retry_complete))
            refreshSafetyData()
        }

    suspend fun handleManagedSafetyPush(incidentId: UUID?): Boolean {
        if (state.value.phase != ManagedCloudPhase.ENROLLED) return false
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_safety.push_catch_up",
        )
        return try {
            if (incidentId == null) {
                refreshSafetyData()
            } else {
                val incident = client().safetyIncident(
                    authorization = authorization(forceRefresh = true),
                    incidentId = incidentId,
                )
                replaceState {
                    it.copy(
                        safetyIncidents = replaceSafetyIncident(
                            incident,
                            it.safetyIncidents,
                        ),
                    )
                }
                reconcileManagedSafetyLocationSession()
            }
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
            )
            true
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            false
        }
    }

    // MARK: Managed Friends

    fun stageSocialProfileLink(uri: Uri?): Boolean {
        val noopId = ManagedSocialRuntime.profileNoopId(uri) ?: return false
        preferences.pendingSocialNoopId = noopId
        replaceState { it.copy(pendingSocialNoopId = noopId) }
        com.noop.AppDiagnosticsRecorder.record(
            "managed_social.profile_link_staged",
            fields = mapOf(
                "outcome" to "accepted",
                "persistence" to "encrypted_preferences",
            ),
        )
        return true
    }

    fun socialProfileUri(): Uri? =
        state.value.socialProfile?.let { ManagedSocialRuntime.profileUri(it.noopId) }

    fun stageSocialInviteLink(uri: Uri?): Boolean {
        val capability = ManagedSocialRuntime.inviteCapability(uri) ?: return false
        preferences.pendingSocialInviteCapability = capability
        replaceState { it.copy(hasPendingSocialInvite = true) }
        com.noop.AppDiagnosticsRecorder.record(
            "managed_social.invite_link_staged",
            fields = mapOf(
                "outcome" to "accepted",
                "persistence" to "encrypted_preferences",
            ),
        )
        return true
    }

    fun socialInviteUri(): Uri? =
        state.value.socialInvite
            ?.takeIf { it.status == "active" }
            ?.let { ManagedSocialRuntime.inviteUri(it.capability) }

    fun clearPendingSocialProfileLink() {
        preferences.pendingSocialNoopId = null
        replaceState { it.copy(pendingSocialNoopId = null) }
    }

    fun clearPendingSocialInvite() {
        preferences.pendingSocialInviteCapability = null
        replaceState { it.copy(hasPendingSocialInvite = false) }
    }

    fun clearSocialLookup() {
        replaceState { it.copy(socialLookup = null) }
    }

    suspend fun createSocialProfile(displayName: String) =
        socialAction("profile_create") {
            val profile = client().createSocialProfile(
                authorization = authorization(forceRefresh = true),
                displayName = displayName,
                requestId = preferences.socialProfileRequestId(),
            )
            preferences.clearSocialProfileRequestId()
            preferences.socialEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            replaceState {
                it.copy(
                    socialProfile = profile,
                    socialStatus = text(R.string.managed_friends_status_profile_ready),
                )
            }
            refreshSocialData(deliverPokes = true)
        }

    suspend fun refreshSocial() =
        socialAction("refresh") {
            refreshSocialData(deliverPokes = true)
        }

    suspend fun updateSocialProfile(
        displayName: String? = null,
        pokeOptIn: Boolean? = null,
        quietStartMinute: Int? = null,
        quietEndMinute: Int? = null,
    ) = socialAction("profile_update") {
        val profile = client().updateSocialProfile(
            authorization = authorization(forceRefresh = true),
            patch = ManagedSocialProfilePatch(
                displayName = displayName,
                pokeOptIn = pokeOptIn,
                quietStartMinute = quietStartMinute,
                quietEndMinute = quietEndMinute,
                timeZone = ZoneId.systemDefault().id,
            ),
        )
        replaceState {
            it.copy(
                socialProfile = profile,
                socialStatus = if (pokeOptIn == true) {
                    text(R.string.managed_friends_status_pokes_enabled)
                } else {
                    text(R.string.managed_friends_status_settings_saved)
                },
            )
        }
        refreshSocialData(deliverPokes = true)
    }

    suspend fun rotateSocialNoopId() =
        socialAction("noop_id_rotate") {
            val profile = client().rotateSocialNoopId(
                authorization(forceRefresh = true),
            )
            replaceState {
                it.copy(
                    socialProfile = profile,
                    socialLookup = null,
                    socialStatus = text(R.string.managed_friends_status_id_rotated),
                )
            }
            refreshSocialData(deliverPokes = false)
        }

    suspend fun lookupSocialProfile(noopId: String) =
        socialAction("lookup") {
            val profile = client().lookupSocialProfile(
                authorization = authorization(forceRefresh = false),
                noopId = noopId,
            )
            replaceState {
                it.copy(
                    socialLookup = profile,
                    socialStatus = text(
                        if (profile.isSelf) {
                            R.string.managed_friends_status_lookup_self
                        } else {
                            R.string.managed_friends_status_lookup_found
                        },
                    ),
                )
            }
        }

    suspend fun sendSocialRequest(noopId: String) =
        socialAction("request_create") {
            client().createSocialRequest(
                authorization = authorization(forceRefresh = true),
                noopId = noopId,
                requestId = UUID.randomUUID(),
            )
            replaceState {
                it.copy(
                    socialLookup = null,
                    socialStatus = text(R.string.managed_friends_status_request_sent),
                )
            }
            refreshSocialData(deliverPokes = false)
        }

    suspend fun createSocialInvite() =
        socialAction("invite_create") {
            val managedClient = client()
            val auth = authorization(forceRefresh = true)
            var invite = managedClient.createSocialInvite(
                authorization = auth,
                capability = preferences.socialInviteCapability(),
                requestId = preferences.socialInviteRequestId(),
            )
            if (invite.status != "active") {
                preferences.clearSocialInviteRequestId()
                preferences.clearSocialInviteCapability()
                invite = managedClient.createSocialInvite(
                    authorization = auth,
                    capability = preferences.socialInviteCapability(),
                    requestId = preferences.socialInviteRequestId(),
                )
            }
            if (invite.status != "active") {
                throw ManagedStorageException.InvalidResponse()
            }
            replaceState {
                it.copy(
                    socialInvite = invite,
                    socialStatus = text(R.string.managed_friends_status_invite_ready),
                )
            }
        }

    suspend fun revokeSocialInvite() =
        socialAction("invite_revoke") {
            val invite = state.value.socialInvite ?: return@socialAction
            client().revokeSocialInvite(
                authorization = authorization(forceRefresh = true),
                inviteId = invite.inviteId,
            )
            preferences.clearSocialInviteRequestId()
            preferences.clearSocialInviteCapability()
            replaceState {
                it.copy(
                    socialInvite = null,
                    socialStatus = text(R.string.managed_friends_status_invite_revoked),
                )
            }
        }

    suspend fun redeemPendingSocialInvite() =
        socialAction("invite_redeem") {
            val capability = preferences.pendingSocialInviteCapability
                ?: return@socialAction
            val scopeHash = accountScopeHash()
            client().redeemSocialInvite(
                authorization = authorization(forceRefresh = true),
                capability = capability,
                requestId = ManagedSocialRuntime.inviteRedemptionRequestId(
                    scopeHash,
                    capability,
                ),
            )
            preferences.pendingSocialInviteCapability = null
            replaceState {
                it.copy(
                    hasPendingSocialInvite = false,
                    socialStatus = text(R.string.managed_friends_status_invite_redeemed),
                )
            }
            refreshSocialData(deliverPokes = false)
        }

    suspend fun decideSocialRequest(requestId: UUID, accept: Boolean) =
        socialAction("request_decide") {
            client().decideSocialRequest(
                authorization = authorization(forceRefresh = true),
                requestId = requestId,
                accept = accept,
            )
            setSocialStatus(
                text(
                    if (accept) {
                        R.string.managed_friends_status_request_accepted
                    } else {
                        R.string.managed_friends_status_request_declined
                    },
                ),
            )
            refreshSocialData(deliverPokes = false)
        }

    suspend fun updateSocialVisibility(
        friendProfileId: UUID,
        patch: ManagedSocialVisibilityPatch,
    ) = socialAction("privacy_update") {
        client().updateSocialVisibility(
            authorization = authorization(forceRefresh = true),
            friendProfileId = friendProfileId,
            patch = patch,
        )
        setSocialStatus(text(R.string.managed_friends_status_privacy_saved))
        refreshSocialData(deliverPokes = false)
    }

    suspend fun removeSocialFriend(profileId: UUID) =
        socialAction("friend_remove") {
            client().removeSocialFriend(
                authorization = authorization(forceRefresh = true),
                profileId = profileId,
            )
            setSocialStatus(text(R.string.managed_friends_status_friend_removed))
            refreshSocialData(deliverPokes = false)
        }

    suspend fun blockSocialProfile(profileId: UUID) =
        socialAction("profile_block") {
            client().blockSocialProfile(
                authorization = authorization(forceRefresh = true),
                profileId = profileId,
            )
            setSocialStatus(text(R.string.managed_friends_status_profile_blocked))
            refreshSocialData(deliverPokes = false)
        }

    suspend fun unblockSocialProfile(profileId: UUID) =
        socialAction("profile_unblock") {
            client().unblockSocialProfile(
                authorization = authorization(forceRefresh = true),
                profileId = profileId,
            )
            setSocialStatus(text(R.string.managed_friends_status_profile_unblocked))
            refreshSocialData(deliverPokes = false)
        }

    suspend fun deleteSocialProfile() =
        socialAction("profile_delete") {
            client().deleteSocialProfile(
                authorization = authorization(forceRefresh = true),
            )
            preferences.clearSocialState()
            preferences.clearSafetyState()
            clearSocialPresentation()
            clearSafetyPresentation()
            ManagedCloudScheduler.reconcile(appContext)
            setSocialStatus(text(R.string.managed_friends_status_profile_deleted))
        }

    suspend fun sendSocialPoke(profileId: UUID) =
        socialAction("poke_send") {
            client().createSocialPoke(
                authorization = authorization(forceRefresh = true),
                recipientProfileId = profileId,
                requestId = UUID.randomUUID(),
            )
            setSocialStatus(text(R.string.managed_friends_status_poke_queued))
        }

    suspend fun disconnect() {
        managedDisconnecting = true
        safetyBootstrapJob?.cancel()
        safetyBootstrapJob = null
        safetyBootstrapRunning = false
        stopManagedSafetyLocationSession("disconnect")
        try {
            val requiresPushRevocation =
                state.value.phase == ManagedCloudPhase.ENROLLED ||
                    state.value.phase == ManagedCloudPhase.DELETION_SCHEDULED
            var serverRevoked = false
            var providerTokenDeleted = false
            if (requiresPushRevocation) {
                val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
                    "managed_safety.push_revocation",
                )
                try {
                    client().revokePushInstallation(
                        authorization = authorization(forceRefresh = true),
                    )
                    serverRevoked = true
                } catch (error: CancellationException) {
                    com.noop.AppDiagnosticsRecorder.endOperation(
                        diagnostic,
                        outcome = "canceled",
                    )
                    throw error
                } catch (error: Throwable) {
                    com.noop.AppDiagnosticsRecorder.record(
                        "managed_safety.push_revocation",
                        fields = mapOf(
                            "outcome" to "server_failed",
                            "failure_kind" to diagnosticSyncFailureKind(error),
                        ),
                    )
                }
                try {
                    val messaging = runtime().messaging
                    messaging.isAutoInitEnabled = false
                    messaging.deleteToken().awaitManaged()
                    providerTokenDeleted = true
                } catch (error: CancellationException) {
                    com.noop.AppDiagnosticsRecorder.endOperation(
                        diagnostic,
                        outcome = "canceled",
                        fields = mapOf(
                            "server" to if (serverRevoked) "revoked" else "failed",
                        ),
                    )
                    throw error
                } catch (error: Throwable) {
                    com.noop.AppDiagnosticsRecorder.record(
                        "managed_safety.push_revocation",
                        fields = mapOf(
                            "outcome" to "provider_failed",
                            "failure_kind" to diagnosticSyncFailureKind(error),
                        ),
                    )
                }
                com.noop.AppDiagnosticsRecorder.endOperation(
                    diagnostic,
                    outcome = if (serverRevoked || providerTokenDeleted) {
                        "completed"
                    } else {
                        "failed"
                    },
                    fields = mapOf(
                        "server" to if (serverRevoked) "revoked" else "failed",
                        "provider" to if (providerTokenDeleted) "deleted" else "failed",
                    ),
                )
            }
            if (
                !ManagedPushRevocationPolicy.canFinalizeDisconnect(
                    requiresRevocation = requiresPushRevocation,
                    serverRevoked = serverRevoked,
                    providerTokenDeleted = providerTokenDeleted,
                )
            ) {
                setStatus(text(R.string.managed_cloud_error_generic))
                return
            }
            runCatching { runtime().auth.signOut() }
                .onFailure {
                    setStatus(userMessage(it))
                    return
                }
            preferences.disconnect()
            preferences.clearSocialState()
            preferences.clearSafetyState()
            clearSocialPresentation()
            clearSafetyPresentation()
            setPhase(ManagedCloudPhase.SIGNED_OUT)
            setStatus(text(R.string.managed_cloud_status_disconnected))
            ManagedCloudScheduler.reconcile(appContext)
        } finally {
            managedDisconnecting = false
            if (state.value.phase == ManagedCloudPhase.ENROLLED) {
                reconcileManagedSafetyLocationSession()
                scheduleManagedSafetyBootstrap()
                ManagedCloudScheduler.reconcile(appContext)
            }
        }
    }

    suspend fun sendDeletionCode(activity: Activity) {
        if (!beginBusy()) return
        try {
            val phone = currentUser().phoneNumber ?: throw ManagedCloudException.NotSignedIn
            val verificationId = requestPhoneVerification(
                activity = activity,
                phone = phone,
                deletion = true,
            )
            if (verificationId != null) {
                preferences.deletionVerificationId = verificationId
                setStatus(
                    text(
                        R.string.managed_cloud_status_fresh_code_sent,
                        maskedPhone(phone),
                    ),
                )
            } else {
                scheduleAccountDeletion()
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    suspend fun requestAccountDeletion(rawCode: String) {
        if (!beginBusy()) return
        try {
            val verificationId = preferences.deletionVerificationId
                ?: throw ManagedCloudException.CodeRequired
            val user = currentUser()
            val credential = PhoneAuthProvider.getCredential(
                verificationId,
                normalizedCode(rawCode),
            )
            user.reauthenticate(credential).awaitManaged()
            preferences.deletionVerificationId = null
            scheduleAccountDeletion()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    private suspend fun scheduleAccountDeletion() {
        val job = client().requestErasure(
            authorization = authorization(forceRefresh = true),
            requestId = UUID.randomUUID(),
            confirmationSha256 = ACCOUNT_DELETION_CONFIRMATION_SHA256,
        )
        preferences.erasureJobId = job.jobId
        preferences.erasureNotBefore = job.notBefore
        preferences.automatic = false
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.DELETION_SCHEDULED,
                deletionNotBefore = job.notBefore,
            )
        }
        setStatus(text(R.string.managed_cloud_status_deletion_scheduled))
        ManagedCloudScheduler.reconcile(appContext)
    }

    suspend fun refreshDeletionStatus() {
        val jobId = preferences.erasureJobId ?: return
        if (!beginBusy()) return
        try {
            val job = client().erasure(
                authorization = authorization(forceRefresh = false),
                jobId = jobId,
            )
            preferences.erasureNotBefore = job.notBefore
            replaceState { it.copy(deletionNotBefore = job.notBefore) }
            when (job.status) {
                "completed" -> completeLocalErasureState()
                "canceled" -> restoreAfterCanceledErasure()
                else -> {
                    setPhase(ManagedCloudPhase.DELETION_SCHEDULED)
                    setStatus(
                        text(
                            R.string.managed_cloud_status_deletion_state,
                            erasureStatus(job.status),
                        ),
                    )
                }
            }
        } catch (error: ManagedStorageException.NotFound) {
            completeLocalErasureState()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (managedDeletionDeadlinePassed(preferences.erasureNotBefore)) {
                completeLocalDeletionHandoff()
            } else {
                setStatus(userMessage(error))
            }
        } finally {
            endBusy()
        }
    }

    suspend fun cancelAccountDeletion() {
        val jobId = preferences.erasureJobId ?: return
        if (!beginBusy()) return
        try {
            val job = client().cancelErasure(
                authorization = authorization(forceRefresh = true),
                jobId = jobId,
            )
            if (job.status != "canceled") throw ManagedStorageException.InvalidResponse()
            restoreAfterCanceledErasure()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    internal fun shouldSchedule(): Boolean {
        val config = configuration ?: return false
        val user = runCatching { runtime().auth.currentUser }.getOrNull() ?: return false
        val scopeHash = accountScopeHash(user)
        return preferences.erasureJobId == null &&
            preferences.isEnrolled(scopeHash, config.storage.policyVersion) &&
            (
                preferences.automatic ||
                    preferences.socialEnabled ||
                    preferences.safetyEnabled
                )
    }

    internal fun shouldSyncForWorker(): Boolean = preferences.automatic

    internal fun shouldRunSocialForWorker(): Boolean = preferences.socialEnabled

    internal fun shouldRunSafetyForWorker(): Boolean = preferences.safetyEnabled

    internal fun schedulerLastAttemptMs(): Long = buildList {
        if (preferences.automatic) add(preferences.lastAttemptMs)
        if (preferences.socialEnabled) add(preferences.socialLastAttemptMs)
        if (preferences.safetyEnabled) add(preferences.safetyLastAttemptMs)
    }.minOrNull() ?: 0L

    private fun beginSafetyAction(): Boolean = synchronized(stateLock) {
        if (mutableState.value.phase != ManagedCloudPhase.ENROLLED ||
            mutableState.value.busy ||
            safetyRunning
        ) {
            return@synchronized false
        }
        mutableState.value = mutableState.value.copy(busy = true)
        true
    }

    private suspend fun safetyAction(
        operation: String,
        body: suspend () -> Unit,
    ) {
        if (!beginSafetyAction()) return
        try {
            runSafetyOperation(operation, body)
        } finally {
            endBusy()
        }
    }

    private suspend fun runSafetyOperation(
        operation: String,
        body: suspend () -> Unit,
    ) {
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_safety",
            fields = mapOf("operation" to operation),
        )
        try {
            body()
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
                fields = mapOf("operation" to operation),
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("operation" to operation),
            )
            throw error
        } catch (error: Throwable) {
            setSafetyStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "operation" to operation,
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
        }
    }

    private suspend fun refreshSafetyData() = safetyMutex.withLock {
        if (state.value.phase != ManagedCloudPhase.ENROLLED) {
            throw ManagedCloudException.ConsentRequired
        }
        safetyRunning = true
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_safety_refresh",
        )
        try {
            val managedClient = client()
            val auth = authorization(forceRefresh = false)
            val contacts = managedClient.safetyContacts(auth)
            val requests = managedClient.safetyRequests(auth)
                .sortedByDescending(ManagedSafetyRequest::createdAt)
            val incidents = managedClient.safetyIncidents(auth)
                .sortedByDescending(ManagedSafetyIncident::createdAt)
            preferences.safetyEnabled = true
            ManagedCloudScheduler.reconcile(appContext)
            replaceState {
                it.copy(
                    safetyContacts = contacts.copy(
                        contacts = contacts.contacts.sortedBy {
                            contact -> contact.displayName.lowercase()
                        },
                    ),
                    safetyRequests = requests,
                    safetyIncidents = incidents,
                    safetyStatus = it.safetyStatus.ifBlank {
                        text(R.string.managed_safety_status_up_to_date)
                    },
                )
            }
            reconcileManagedSafetyLocationSession()
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
                fields = mapOf(
                    "contacts" to contacts.contacts.size.toString(),
                    "requests" to requests.size.toString(),
                    "incidents" to incidents.size.toString(),
                    "active_incidents" to incidents.count {
                        it.status == "open" || it.status == "acknowledged"
                    }.toString(),
                ),
            )
        } catch (_: ManagedStorageException.NotFound) {
            val pendingInvite = preferences.pendingSafetyInviteCapability
            preferences.clearSafetyState()
            preferences.pendingSafetyInviteCapability = pendingInvite
            ManagedCloudScheduler.reconcile(appContext)
            clearSafetyPresentation()
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
                fields = mapOf(
                    "contacts" to "0",
                    "requests" to "0",
                    "incidents" to "0",
                    "profile" to "absent",
                ),
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
            )
            throw error
        } catch (error: Throwable) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            throw error
        } finally {
            safetyRunning = false
        }
    }

    private suspend fun replaceManagedSafetyLocation(
        incidentId: UUID,
        location: SafetyLocation,
        source: String,
        requireActiveSession: Boolean,
    ): SafetyLocationUploadOutcome = safetyLocationUpdateMutex.withLock {
        val nowUnix = System.currentTimeMillis() / 1_000L
        if (state.value.phase != ManagedCloudPhase.ENROLLED) {
            return@withLock SafetyLocationUploadOutcome.RETRY
        }
        if (!location.isUsable(nowUnix)) {
            return@withLock SafetyLocationUploadOutcome.RETRY
        }
        if (requireActiveSession) {
            ManagedSafetyLiveLocationSession.initialize(appContext)
            val active = ManagedSafetyLiveLocationSession.state.value
            if (
                active.incidentId != incidentId.toString().lowercase() ||
                !active.isActiveAt(nowUnix)
            ) {
                return@withLock SafetyLocationUploadOutcome.STOP
            }
        }
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_safety.location_replace",
            fields = mapOf("source" to source),
        )
        try {
            val stored = client().updateSafetyLocation(
                authorization = authorization(forceRefresh = false),
                incidentId = incidentId,
                sequence = preferences.proposedSafetyLocationSequence(incidentId),
                latitude = location.latitude,
                longitude = location.longitude,
                horizontalAccuracyM =
                    location.horizontalAccuracyMeters ?: 10_000.0,
                capturedAt = Instant.ofEpochSecond(
                    location.capturedAtUnix,
                ).toString(),
            )
            preferences.adoptSafetyLocationSequence(
                incidentId,
                stored.sequence,
            )
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
                fields = mapOf("source" to source),
            )
            SafetyLocationUploadOutcome.ACCEPTED
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf(
                    "source" to source,
                    "failure_kind" to "canceled",
                ),
            )
            throw error
        } catch (error: Throwable) {
            val terminal = isTerminalManagedSafetyLocationError(error)
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = if (terminal) "terminal" else "failed",
                fields = mapOf(
                    "source" to source,
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
            if (terminal) {
                stopManagedSafetyLocationSession("server_terminal")
                SafetyLocationUploadOutcome.STOP
            } else {
                SafetyLocationUploadOutcome.RETRY
            }
        }
    }

    private fun reconcileManagedSafetyLocationSession(
        now: Instant = Instant.now(),
    ) {
        val incident = ManagedSafetyLiveLocationSession.activeOwnerIncident(
            state.value.safetyIncidents,
            now,
        )
        if (state.value.phase != ManagedCloudPhase.ENROLLED || incident == null) {
            stopManagedSafetyLocationSession("inactive")
            return
        }
        val expiresAt = runCatching { Instant.parse(incident.expiresAt) }
            .getOrNull()
            ?: run {
                stopManagedSafetyLocationSession("invalid_expiry")
                return
            }
        incident.location?.let {
            preferences.adoptSafetyLocationSequence(
                incident.incidentId,
                it.sequence,
            )
        }
        val changed = ManagedSafetyLiveLocationSession.start(
            context = appContext,
            incidentId = incident.incidentId,
            expiresAtUnix = expiresAt.epochSecond,
            nowUnix = now.epochSecond,
        )
        if (changed) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.location_session",
                fields = mapOf(
                    "outcome" to "started",
                    "duration_class" to if (incident.durationHours == 12) {
                        "12_hours"
                    } else {
                        "8_hours"
                    },
                ),
            )
        }
        WhoopConnectionService.start(appContext)
    }

    internal fun stopSafetyLocationForRuntime(
        incidentId: UUID,
        reason: String,
    ) {
        stopManagedSafetyLocationSession(reason, incidentId)
    }

    private fun stopManagedSafetyLocationSession(
        reason: String,
        expectedIncidentId: UUID? = null,
    ) {
        if (
            ManagedSafetyLiveLocationSession.stop(
                appContext,
                expectedIncidentId,
            )
        ) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.location_session",
                fields = mapOf(
                    "outcome" to "stopped",
                    "reason" to reason,
                ),
            )
        }
    }

    private fun isTerminalManagedSafetyLocationError(
        error: Throwable,
    ): Boolean =
        error is ManagedStorageException.Authentication ||
            error is ManagedStorageException.Forbidden ||
            error is ManagedStorageException.NotFound ||
            error is ManagedStorageException.PolicyChanged ||
            error is ManagedStorageException.CursorExpired ||
            (
                error is ManagedStorageException.Server &&
                    error.statusCode in setOf(401, 403, 404, 410)
                )

    private fun beginSocialAction(): Boolean = synchronized(stateLock) {
        if (mutableState.value.phase != ManagedCloudPhase.ENROLLED ||
            mutableState.value.busy ||
            socialRunning
        ) {
            return@synchronized false
        }
        mutableState.value = mutableState.value.copy(busy = true)
        true
    }

    private suspend fun socialAction(
        operation: String,
        body: suspend () -> Unit,
    ) {
        if (!beginSocialAction()) return
        try {
            runSocialOperation(operation, body)
        } finally {
            endBusy()
        }
    }

    private suspend fun runSocialOperation(
        operation: String,
        body: suspend () -> Unit,
    ) {
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "managed_social",
            fields = mapOf("operation" to operation),
        )
        try {
            body()
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "completed",
                fields = mapOf("operation" to operation),
            )
        } catch (error: CancellationException) {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "canceled",
                fields = mapOf("operation" to operation),
            )
            throw error
        } catch (error: Throwable) {
            setSocialStatus(userMessage(error))
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf(
                    "operation" to operation,
                    "failure_kind" to diagnosticSyncFailureKind(error),
                ),
            )
        }
    }

    private suspend fun refreshSocialData(deliverPokes: Boolean) =
        socialMutex.withLock {
            if (state.value.phase != ManagedCloudPhase.ENROLLED) {
                throw ManagedCloudException.ConsentRequired
            }
            socialRunning = true
            val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
                "managed_social_refresh",
                fields = mapOf(
                    "delivery" to if (deliverPokes) "enabled" else "disabled",
                ),
            )
            try {
                val managedClient = client()
                val auth = authorization(forceRefresh = false)
                val profile = try {
                    managedClient.socialProfile(auth)
                } catch (_: ManagedStorageException.NotFound) {
                    preferences.socialEnabled = false
                    ManagedCloudScheduler.reconcile(appContext)
                    replaceState {
                        it.copy(
                            socialProfile = null,
                            socialFriends = emptyList(),
                            socialBlockedProfiles = emptyList(),
                            socialRequests = emptyList(),
                            socialFeed = emptyList(),
                            socialLookup = null,
                            socialInvite = null,
                        )
                    }
                    com.noop.AppDiagnosticsRecorder.endOperation(
                        diagnostic,
                        outcome = "completed",
                        fields = mapOf(
                            "profile" to "absent",
                            "friends" to "0",
                            "blocks" to "0",
                            "requests" to "0",
                            "summaries_uploaded" to "0",
                            "pokes_claimed" to "0",
                        ),
                    )
                    return@withLock
                }
                preferences.socialEnabled = true
                val friends = managedClient.socialFriends(auth)
                    .sortedBy { it.displayName.lowercase() }
                val blockedProfiles = managedClient.socialBlockedProfiles(auth)
                    .sortedBy { it.displayName.lowercase() }
                val requests = managedClient.socialRequests(auth)
                    .sortedByDescending(ManagedSocialRequest::createdAt)
                val feedDays = ManagedSocialRuntime.summaryDays().takeLast(7)
                var feed = emptyList<ManagedSocialFeedDay>()
                var feedOutcome = "empty_range"
                if (feedDays.isNotEmpty()) {
                    feed = try {
                        managedClient.socialFeed(
                            authorization = auth,
                            startDay = feedDays.first(),
                            endDay = feedDays.last(),
                        ).also {
                            feedOutcome = "completed"
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        feedOutcome = "failed"
                        com.noop.AppDiagnosticsRecorder.record(
                            "managed_social.feed",
                            fields = mapOf(
                                "outcome" to "failed",
                                "failure_kind" to diagnosticSyncFailureKind(error),
                            ),
                        )
                        emptyList()
                    }
                }
                replaceState {
                    it.copy(
                        socialProfile = profile,
                        socialFriends = friends,
                        socialBlockedProfiles = blockedProfiles,
                        socialRequests = requests,
                        socialFeed = feed,
                    )
                }
                val summariesUploaded = uploadChangedSocialSummaries(
                    friends = friends,
                    managedClient = managedClient,
                    authorization = auth,
                )
                if (summariesUploaded > 0) {
                    val refreshedProfile = managedClient.socialProfile(auth)
                    replaceState {
                        it.copy(socialProfile = refreshedProfile)
                    }
                }
                val pokesClaimed = if (deliverPokes) {
                    deliverSocialPokes(managedClient, auth)
                } else {
                    0
                }
                if (state.value.socialStatus.isBlank()) {
                    setSocialStatus(text(R.string.managed_friends_status_up_to_date))
                }
                com.noop.AppDiagnosticsRecorder.endOperation(
                    diagnostic,
                    outcome = "completed",
                    fields = mapOf(
                        "profile" to "active",
                        "friends" to friends.size.toString(),
                        "blocks" to blockedProfiles.size.toString(),
                        "requests" to requests.size.toString(),
                        "feed_rows" to feed.size.toString(),
                        "feed_outcome" to feedOutcome,
                        "summaries_uploaded" to summariesUploaded.toString(),
                        "pokes_claimed" to pokesClaimed.toString(),
                    ),
                )
            } catch (error: CancellationException) {
                com.noop.AppDiagnosticsRecorder.endOperation(
                    diagnostic,
                    outcome = "canceled",
                )
                throw error
            } catch (error: Throwable) {
                com.noop.AppDiagnosticsRecorder.endOperation(
                    diagnostic,
                    outcome = "failed",
                    fields = mapOf(
                        "failure_kind" to diagnosticSyncFailureKind(error),
                    ),
                )
                throw error
            } finally {
                socialRunning = false
            }
        }

    private suspend fun uploadChangedSocialSummaries(
        friends: List<ManagedSocialFriend>,
        managedClient: ManagedStorageClient,
        authorization: ManagedAuthorization,
    ): Int {
        val days = ManagedSocialRuntime.summaryDays()
        if (days.isEmpty()) return 0
        val firstDay = days.first()
        val lastDay = days.last()
        val summaries = days.associateWithTo(linkedMapOf()) {
            ManagedSocialSummary()
        }
        val allowed = ManagedSocialRuntime.visibilityUnion(friends)
        val repository = application.repository
        for (source in repository.computedSourceIds(application.activeDeviceId)) {
            repository.dailyMetrics(source, firstDay, lastDay).forEach { row ->
                val current = summaries[row.day] ?: return@forEach
                summaries[row.day] = current.copy(
                    charge = current.charge ?: if (allowed.charge) {
                        ManagedSocialRuntime.value(row.recovery, 0.0..100.0)
                    } else {
                        null
                    },
                    effort = current.effort ?: if (allowed.effort) {
                        ManagedSocialRuntime.value(row.strain, 0.0..100.0)
                    } else {
                        null
                    },
                    sleepDuration = current.sleepDuration ?: if (allowed.sleepDuration) {
                        ManagedSocialRuntime.value(row.totalSleepMin, 0.0..1_440.0)
                    } else {
                        null
                    },
                    hrv = current.hrv ?: if (allowed.hrv) {
                        ManagedSocialRuntime.value(row.avgHrv, 0.0..500.0)
                    } else {
                        null
                    },
                    rhr = current.rhr ?: if (allowed.rhr) {
                        ManagedSocialRuntime.value(
                            row.restingHr?.toDouble(),
                            20.0..250.0,
                        )
                    } else {
                        null
                    },
                )
            }
            if (allowed.rest) {
                repository.metricSeries(
                    source,
                    "sleep_performance",
                    firstDay,
                    lastDay,
                ).forEach { point ->
                    val current = summaries[point.day] ?: return@forEach
                    summaries[point.day] = current.copy(
                        rest = current.rest ?: ManagedSocialRuntime.value(
                            point.value,
                            0.0..100.0,
                        ),
                    )
                }
            }
        }

        val scopeHash = accountScopeHash()
        val retainedDays = days.toSet()
        val digests = preferences.socialSummaryDigests(scopeHash)
            .filterKeys(retainedDays::contains)
            .toMutableMap()
        var uploaded = 0
        for (day in days) {
            coroutineContext.ensureActive()
            val summary = summaries.getValue(day)
            val digest = ManagedSocialRuntime.digest(day, summary, allowed)
            if (digests[day] == digest ||
                digests[day] == null && !summary.hasValue
            ) {
                continue
            }
            managedClient.putSocialSummary(
                authorization = authorization,
                day = day,
                summary = summary,
                requestId = ManagedSocialRuntime.summaryRequestId(
                    scopeHash,
                    day,
                    digest,
                ),
            )
            digests[day] = digest
            uploaded += 1
            preferences.storeSocialSummaryDigests(scopeHash, digests)
        }
        preferences.storeSocialSummaryDigests(scopeHash, digests)
        return uploaded
    }

    private suspend fun deliverSocialPokes(
        managedClient: ManagedStorageClient,
        authorization: ManagedAuthorization,
    ): Int {
        val claims = managedClient.claimSocialPokes(
            authorization = authorization,
            limit = 3,
        )
        for (claim in claims) {
            coroutineContext.ensureActive()
            val existing = preferences.socialDeliveryReceipt(claim.pokeId)
            val receipt = existing ?: ManagedSocialDeliveryReceipt(
                pokeId = claim.pokeId,
                notificationOutcome = ManagedSocialPokeNotifier.post(appContext),
                hapticOutcome = if (application.requestManagedSocialPokeHaptic()) {
                    "requested"
                } else {
                    "band_unavailable"
                },
                recordedAtMs = System.currentTimeMillis(),
            ).also(preferences::storeSocialDeliveryReceipt)
            managedClient.acknowledgeSocialPoke(
                authorization = authorization,
                pokeId = claim.pokeId,
                acknowledgement = ManagedSocialPokeAcknowledgement(
                    claimId = claim.claimId,
                    notificationOutcome = receipt.notificationOutcome,
                    hapticOutcome = receipt.hapticOutcome,
                ),
            )
        }
        if (claims.isNotEmpty()) {
            val receipts = claims.mapNotNull {
                preferences.socialDeliveryReceipt(it.pokeId)
            }
            com.noop.AppDiagnosticsRecorder.record(
                "managed_social.poke_delivery",
                fields = mapOf(
                    "claimed" to claims.size.toString(),
                    "notifications_scheduled" to receipts.count {
                        it.notificationOutcome == "scheduled"
                    }.toString(),
                    "haptics_requested" to receipts.count {
                        it.hapticOutcome == "requested"
                    }.toString(),
                ),
            )
        }
        return claims.size
    }

    private suspend fun performSync(mode: SyncMode): ManagedCloudSyncSummary =
        syncMutex.withLock {
            withContext(Dispatchers.IO) {
                val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
                    "managed_sync",
                    fields = mapOf("mode" to mode.name.lowercase()),
                )
                try {
                    val config = configuration ?: throw ManagedCloudException.Unavailable
                    val user = currentUser()
                    val scopeHash = accountScopeHash(user)
                    if (!preferences.isEnrolled(scopeHash, config.storage.policyVersion) ||
                        preferences.erasureJobId != null
                    ) {
                        throw ManagedCloudException.ConsentRequired
                    }
                    preferences.lastAttemptMs = System.currentTimeMillis()
                    setStatus(
                        when (mode) {
                            SyncMode.MANUAL ->
                                text(R.string.managed_cloud_status_syncing)
                            SyncMode.AUTOMATIC ->
                                text(R.string.managed_cloud_status_updating_background)
                            SyncMode.EXPORT_PREPARATION ->
                                text(R.string.managed_cloud_status_finishing_backup)
                        },
                    )
                    val summary = ManagedAuthenticationRetry.run(
                        authorization = { forceRefresh ->
                            if (forceRefresh) {
                                com.noop.AppDiagnosticsRecorder.record(
                                    "managed_sync.auth_refresh",
                                    fields = mapOf(
                                        "reason" to "server_rejected_cached_token",
                                    ),
                                )
                            }
                            authorization(forceRefresh)
                        },
                        operation = { authorization ->
                            performSyncPass(
                                mode = mode,
                                scopeHash = scopeHash,
                                authorization = authorization,
                            )
                        },
                    )
                    val now = System.currentTimeMillis()
                    preferences.lastSuccessMs = now
                    replaceState { it.copy(lastSuccessMs = now) }
                    if (summary.hasMore) {
                        setStatus(text(R.string.managed_cloud_status_continuing))
                    } else if (summary.uploadedChunks == 0 &&
                        summary.uploadedDocuments == 0 &&
                        summary.appliedChanges == 0 &&
                        summary.prunedRows == 0
                    ) {
                        setStatus(text(R.string.managed_cloud_status_up_to_date))
                    } else {
                        val changes = buildList {
                            if (summary.uploadedChunks > 0) {
                                add(
                                    quantity(
                                        R.plurals.managed_cloud_sync_chunks,
                                        summary.uploadedChunks,
                                    ),
                                )
                            }
                            if (summary.uploadedDocuments > 0) {
                                add(
                                    quantity(
                                        R.plurals.managed_cloud_sync_documents,
                                        summary.uploadedDocuments,
                                    ),
                                )
                            }
                            if (summary.appliedChanges > 0) {
                                add(
                                    quantity(
                                        R.plurals.managed_cloud_sync_restored_changes,
                                        summary.appliedChanges,
                                    ),
                                )
                            }
                            if (summary.prunedRows > 0) {
                                add(
                                    quantity(
                                        R.plurals.managed_cloud_sync_freed_rows,
                                        summary.prunedRows,
                                    ),
                                )
                            }
                        }
                        setStatus(
                            text(
                                R.string.managed_cloud_status_updated,
                                localizedList(changes),
                            ),
                        )
                    }
                    com.noop.AppDiagnosticsRecorder.endOperation(
                        diagnostic,
                        outcome = "completed",
                        fields = mapOf(
                            "uploaded_chunks" to summary.uploadedChunks.toString(),
                            "uploaded_documents" to summary.uploadedDocuments.toString(),
                            "applied_changes" to summary.appliedChanges.toString(),
                            "pruned_rows" to summary.prunedRows.toString(),
                            "continuation_pending" to summary.hasMore.toString(),
                        ),
                        includeResourceSnapshot = true,
                    )
                    summary
                } catch (error: Throwable) {
                    com.noop.AppDiagnosticsRecorder.endOperation(
                        diagnostic,
                        outcome = "failed",
                        fields = mapOf(
                            "failure_kind" to diagnosticSyncFailureKind(error),
                        ),
                        includeResourceSnapshot = true,
                    )
                    throw error
                }
            }
        }

    private fun diagnosticSyncFailureKind(error: Throwable): String = when (error) {
        is kotlinx.coroutines.CancellationException -> "canceled"
        is IllegalArgumentException -> "invalid_input"
        is FirebaseAuthException -> when (error.errorCode) {
            "ERROR_MISSING_PHONE_NUMBER",
            "ERROR_INVALID_PHONE_NUMBER",
            "ERROR_MISSING_VERIFICATION_CODE",
            "ERROR_INVALID_VERIFICATION_CODE",
            "ERROR_MISSING_VERIFICATION_ID",
            "ERROR_INVALID_VERIFICATION_ID",
            -> "identity_input"
            "ERROR_TOO_MANY_REQUESTS",
            "ERROR_QUOTA_EXCEEDED",
            -> "rate_limited"
            "ERROR_OPERATION_NOT_ALLOWED" -> "identity_provider_disabled"
            "ERROR_NETWORK_REQUEST_FAILED" -> "network_transport"
            "ERROR_INVALID_API_KEY",
            "ERROR_APP_NOT_AUTHORIZED",
            -> "identity_configuration"
            "ERROR_MISSING_APP_CREDENTIAL",
            "ERROR_INVALID_APP_CREDENTIAL",
            "ERROR_MISSING_APP_TOKEN",
            "ERROR_NOTIFICATION_NOT_FORWARDED",
            "ERROR_APP_NOT_VERIFIED",
            "ERROR_CAPTCHA_CHECK_FAILED",
            "ERROR_APP_VERIFICATION_USER_INTERACTION_FAILURE",
            -> "app_verification"
            "ERROR_SESSION_EXPIRED" -> "verification_expired"
            "ERROR_INVALID_CREDENTIAL" -> "authentication"
            else -> "identity_provider"
        }
        is ManagedCloudException.InvalidPhone,
        is ManagedCloudException.InvalidCode,
        is ManagedCloudException.CodeRequired,
        -> "identity_input"
        is ManagedCloudException.NotSignedIn -> "not_signed_in"
        is ManagedCloudException.ConsentRequired -> "consent_required"
        is ManagedCloudException.Unavailable,
        is ManagedCloudException.FirebaseProjectConflict,
        -> "configuration"
        is ManagedCloudException.ExportPreparationIncomplete -> "continuation_incomplete"
        is ManagedStorageException.Network -> "network_transport"
        is ManagedStorageException.InvalidResponse -> "invalid_response"
        is ManagedStorageException.Authentication -> "authentication"
        is ManagedStorageException.Forbidden -> "forbidden"
        is ManagedStorageException.PolicyChanged -> "policy_changed"
        is ManagedStorageException.CursorExpired -> "cursor_expired"
        is ManagedStorageException.NotFound -> "not_found"
        is ManagedStorageException.QuotaExceeded -> "quota_exceeded"
        is ManagedStorageException.Conflict -> "sync_conflict"
        is ManagedStorageException.Server -> when (error.statusCode) {
            408, 504 -> "server_timeout"
            429 -> "rate_limited"
            else -> "server_unavailable"
        }
        is ManagedStorageException.DigestMismatch -> "integrity_mismatch"
        else -> "unexpected"
    }

    private fun diagnosticOperationOutcome(error: Throwable): String =
        when (diagnosticSyncFailureKind(error)) {
            "identity_input",
            "app_verification",
            "identity_provider_disabled",
            "verification_expired",
            "rate_limited",
            "not_signed_in",
            "consent_required",
            "authentication",
            "policy_changed",
            "quota_exceeded",
            "sync_conflict",
            -> "rejected"
            "canceled" -> "canceled"
            else -> "failed"
        }

    private suspend fun performSyncPass(
        mode: SyncMode,
        scopeHash: String,
        authorization: ManagedAuthorization,
    ): ManagedCloudSyncSummary {
        val documentAdapter = RoomManagedDocumentAdapter(
            database = database,
            accountScopeHash = scopeHash,
            context = appContext,
        )
        documentAdapter.stagePreferences(BackupSettingsBridge.snapshotJson(appContext))
        val coordinator = ManagedSyncCoordinator(
            transport = client(),
            extractor = RoomManagedChunkExtractor(database),
            state = RoomManagedSyncStateStore(
                database,
                scopeHash,
            ),
            restore = RoomManagedRestoreApplier(
                database = database,
                documentRestore = documentAdapter,
            ),
            documents = documentAdapter,
        )
        val sources = sourceDescriptors(authorization.installationId)
        var uploadedChunks = 0
        var uploadedBytes = 0L
        var uploadedDocuments = 0
        var appliedChanges = 0
        var hasMore = false
        var prunedWindows = 0
        var prunedRows = 0
        val localPruneNowMs = if (
            preferences.optimizePhoneStorage &&
            mode != SyncMode.EXPORT_PREPARATION
        ) {
            System.currentTimeMillis()
        } else {
            null
        }
        data class Limits(
            val forward: Int,
            val dirty: Int,
            val changes: Int,
            val snapshotObjects: Int,
            val snapshotBytes: Int,
            val documents: Int,
            val prune: Int,
        )
        val limits = when (mode) {
            SyncMode.MANUAL -> Limits(
                8,
                8,
                4,
                32,
                64 * 1_024 * 1_024,
                32,
                8,
            )
            SyncMode.AUTOMATIC -> Limits(
                2,
                2,
                1,
                16,
                32 * 1_024 * 1_024,
                8,
                2,
            )
            SyncMode.EXPORT_PREPARATION -> Limits(
                100,
                100,
                20,
                200,
                256 * 1_024 * 1_024,
                100,
                0,
            )
        }
        sources.forEachIndexed { index, source ->
            val result = coordinator.sync(
                source = source,
                authorization = authorization,
                dataClasses = ManagedSyncCoordinator.DATA_CLASSES,
                maxForwardWindowsPerClass = limits.forward,
                maxDirtyWindowsPerClass = limits.dirty,
                maxChangePages = if (index == 0) limits.changes else 0,
                changePageSize = 100,
                maxSnapshotRestoreObjects = limits.snapshotObjects,
                maxSnapshotRestoreBytes = limits.snapshotBytes,
                maxDocumentUploads = if (index == 0) limits.documents else 0,
                localPruneNowMs = localPruneNowMs,
                maxPruneWindowsPerClass = limits.prune,
            )
            uploadedChunks = Math.addExact(uploadedChunks, result.uploadedChunks)
            uploadedBytes = Math.addExact(uploadedBytes, result.uploadedBytes.toLong())
            uploadedDocuments = Math.addExact(
                uploadedDocuments,
                result.uploadedDocuments,
            )
            appliedChanges = Math.addExact(appliedChanges, result.appliedChanges)
            hasMore = hasMore || result.hasMoreWork
            prunedWindows = Math.addExact(prunedWindows, result.prunedWindows)
            prunedRows = Math.addExact(prunedRows, result.prunedRows)
        }
        return ManagedCloudSyncSummary(
            uploadedChunks = uploadedChunks,
            uploadedBytes = uploadedBytes,
            uploadedDocuments = uploadedDocuments,
            appliedChanges = appliedChanges,
            hasMore = hasMore,
            prunedWindows = prunedWindows,
            prunedRows = prunedRows,
        )
    }

    private suspend fun sourceDescriptors(installationId: String): List<ManagedSourceDescriptor> {
        val candidates = buildList {
            addAll(database.managedSyncDao().managedLocalSourceIds())
            add(WhoopRepository.WHOOP_SOURCE)
        }
        return candidates
            .asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .filterNot { it.startsWith(CLOUD_RESTORE_PREFIX) }
            .distinct()
            .sortedWith(
                compareBy<String> { it != WhoopRepository.WHOOP_SOURCE }.thenBy { it },
            )
            .map { localId ->
                ManagedSourceDescriptor(
                    localSourceId = localId,
                    sourceKind = sourceKind(localId),
                    installationId = installationId,
                )
            }
            .toList()
    }

    private fun sourceKind(localId: String): String = when {
        localId == WhoopRepository.APPLE_HEALTH_SOURCE -> "apple_health"
        localId == WhoopRepository.HEALTH_CONNECT_SOURCE -> "health_connect"
        localId == WhoopRepository.ACTIVITY_FILE_SOURCE -> "activity_file"
        localId.endsWith("-noop") -> "noop_computed"
        else -> "live_ble"
    }

    private fun reconcileAuthenticatedState() {
        val config = configuration ?: run {
            setPhase(ManagedCloudPhase.UNAVAILABLE)
            return
        }
        val user = runtime().auth.currentUser ?: run {
            clearSocialPresentation()
            clearSafetyPresentation()
            setPhase(ManagedCloudPhase.SIGNED_OUT)
            return
        }
        val enrolled = preferences.isEnrolled(
            accountScopeHash(user),
            config.storage.policyVersion,
        )
        setPhase(
            when {
                enrolled && preferences.erasureJobId != null ->
                    ManagedCloudPhase.DELETION_SCHEDULED
                enrolled -> ManagedCloudPhase.ENROLLED
                else -> ManagedCloudPhase.CONSENT_REQUIRED
            },
        )
        if (!enrolled) {
            clearSocialPresentation()
            clearSafetyPresentation()
        } else if (state.value.phase == ManagedCloudPhase.ENROLLED) {
            scheduleManagedSafetyBootstrap()
        }
    }

    private fun completeLocalErasureState() {
        safetyBootstrapJob?.cancel()
        safetyBootstrapJob = null
        safetyBootstrapRunning = false
        disableManagedMessagingLocally()
        runCatching { runtime().auth.signOut() }
        preferences.clearEnrollment()
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.SIGNED_OUT,
                deletionNotBefore = null,
                overview = null,
                installations = emptyList(),
                socialProfile = null,
                socialFriends = emptyList(),
                socialBlockedProfiles = emptyList(),
                socialRequests = emptyList(),
                socialFeed = emptyList(),
                socialLookup = null,
                socialInvite = null,
                socialStatus = "",
                hasPendingSocialInvite = false,
                pendingSocialNoopId = null,
                safetyContacts = null,
                safetyRequests = emptyList(),
                safetyIncidents = emptyList(),
                safetyInvite = null,
                safetyStatus = "",
                hasPendingSafetyInvite = false,
            )
        }
        setStatus(text(R.string.managed_cloud_status_deletion_completed))
        ManagedCloudScheduler.reconcile(appContext)
    }

    private fun completeLocalDeletionHandoff() {
        safetyBootstrapJob?.cancel()
        safetyBootstrapJob = null
        safetyBootstrapRunning = false
        disableManagedMessagingLocally()
        runCatching { runtime().auth.signOut() }
        preferences.clearEnrollment()
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.SIGNED_OUT,
                deletionNotBefore = null,
                overview = null,
                installations = emptyList(),
                socialProfile = null,
                socialFriends = emptyList(),
                socialBlockedProfiles = emptyList(),
                socialRequests = emptyList(),
                socialFeed = emptyList(),
                socialLookup = null,
                socialInvite = null,
                socialStatus = "",
                hasPendingSocialInvite = false,
                pendingSocialNoopId = null,
                safetyContacts = null,
                safetyRequests = emptyList(),
                safetyIncidents = emptyList(),
                safetyInvite = null,
                safetyStatus = "",
                hasPendingSafetyInvite = false,
            )
        }
        setStatus(text(R.string.managed_cloud_status_deletion_processing))
        ManagedCloudScheduler.reconcile(appContext)
    }

    private fun restoreAfterCanceledErasure() {
        preferences.erasureJobId = null
        preferences.erasureNotBefore = null
        preferences.automatic = true
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.ENROLLED,
                deletionNotBefore = null,
            )
        }
        scheduleManagedSafetyBootstrap()
        setStatus(text(R.string.managed_cloud_status_deletion_canceled))
        ManagedCloudScheduler.reconcile(appContext)
    }

    private fun scheduleManagedSafetyBootstrap() {
        val shouldStart = synchronized(stateLock) {
            if (
                mutableState.value.phase != ManagedCloudPhase.ENROLLED ||
                safetyBootstrapRunning
            ) {
                false
            } else {
                safetyBootstrapRunning = true
                true
            }
        }
        if (!shouldStart) return
        safetyBootstrapJob = scope.launch {
            try {
                if (
                    mutableState.value.phase == ManagedCloudPhase.ENROLLED &&
                    (
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                            ContextCompat.checkSelfPermission(
                                appContext,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) == PackageManager.PERMISSION_GRANTED
                        )
                ) {
                    registerCurrentManagedPushToken()
                }
                if (mutableState.value.phase == ManagedCloudPhase.ENROLLED) {
                    runCatching { refreshSafetyData() }
                }
            } finally {
                safetyBootstrapRunning = false
                safetyBootstrapJob = null
            }
        }
    }

    private fun disableManagedMessagingLocally() {
        val messaging = runCatching { runtime().messaging }.getOrNull() ?: return
        messaging.isAutoInitEnabled = false
        scope.launch {
            runCatching { messaging.deleteToken().awaitManaged() }
                .onFailure {
                    com.noop.AppDiagnosticsRecorder.record(
                        "managed_safety.push_revocation",
                        fields = mapOf(
                            "outcome" to "provider_failed",
                            "failure_kind" to diagnosticSyncFailureKind(it),
                        ),
                    )
                }
        }
    }

    private suspend fun authorization(forceRefresh: Boolean): ManagedAuthorization {
        val runtime = runtime()
        val user = runtime.auth.currentUser ?: throw ManagedCloudException.NotSignedIn
        val scopeHash = accountScopeHash(user)
        val identity = user.getIdToken(forceRefresh).awaitManaged().token
            ?.takeIf(String::isNotBlank)
            ?: throw ManagedStorageException.Authentication()
        val appCheck = runtime.appCheck.getAppCheckToken(forceRefresh).awaitManaged().token
            .takeIf(String::isNotBlank)
            ?: throw ManagedStorageException.Authentication()
        return ManagedAuthorization(
            identityToken = identity,
            appCheckToken = appCheck,
            installationId = ManagedAccountIdentifier.installationId(
                preferences.installationId,
                scopeHash,
            ),
            installationToken = preferences.installationToken(scopeHash),
        )
    }

    private fun client(): ManagedStorageClient =
        ManagedStorageClient(
            configuration =
                requireNotNull(configuration) { "Managed storage is not configured." }.storage,
            requestObserver = { diagnostic ->
                com.noop.AppDiagnosticsRecorder.record(
                    "managed_http.request",
                    fields = buildMap {
                        put("target", diagnostic.target)
                        put("route_group", diagnostic.routeGroup)
                        put("method", diagnostic.method)
                        put(
                            "duration_ms",
                            diagnostic.durationMilliseconds.toString(),
                        )
                        put("outcome", diagnostic.outcome)
                        diagnostic.statusCode?.let {
                            put("status_code", it.toString())
                        }
                    },
                )
            },
        )

    private fun currentUser(): FirebaseUser =
        runtime().auth.currentUser ?: throw ManagedCloudException.NotSignedIn

    private fun accountScopeHash(): String = accountScopeHash(currentUser())

    private fun accountScopeHash(user: FirebaseUser): String =
        ManagedDigest.sha256(
            "noop-managed-account-v1\u0000${user.uid}".toByteArray(StandardCharsets.UTF_8),
        )

    private fun managedSafetyNotificationPermissionGranted(): Boolean =
        ManagedSafetyNotificationPermission.canRegister(appContext)

    private suspend fun retireManagedPushInstallationForNotificationSettings() {
        runCatching { runtime().messaging.isAutoInitEnabled = false }
        val result = runCatching {
            client().revokePushInstallation(
                authorization = authorization(forceRefresh = false),
            )
        }
        val error = result.exceptionOrNull()
        com.noop.AppDiagnosticsRecorder.record(
            "managed_safety.push_revocation",
            fields = mapOf(
                "outcome" to if (
                    error == null || error is ManagedStorageException.NotFound
                ) {
                    "completed"
                } else {
                    "failed"
                },
                "failure_kind" to when (error) {
                    null, is ManagedStorageException.NotFound -> "none"
                    else -> diagnosticSyncFailureKind(error)
                },
                "reason" to "notification_not_authorized",
            ),
        )
    }

    private fun shouldRetireSafetyIncidentRequest(error: Throwable): Boolean =
        ManagedSafetyIncidentRequestPolicy.shouldRetire(error) ||
            error is ManagedCloudException.Unavailable ||
            error is ManagedCloudException.FirebaseProjectConflict

    private fun runtime(): FirebaseRuntime {
        firebaseRuntime?.let { return it }
        return synchronized(firebaseLock) {
            firebaseRuntime?.let { return@synchronized it }
            val config = configuration ?: throw ManagedCloudException.Unavailable
            val options = FirebaseOptions.Builder()
                .setProjectId(config.projectId)
                .setApiKey(config.apiKey)
                .setApplicationId(config.googleAppId)
                .setGcmSenderId(config.gcmSenderId)
                .build()
            val firebase = runCatching { FirebaseApp.getInstance(FIREBASE_APP_NAME) }
                .getOrNull()
                ?: FirebaseApp.initializeApp(
                    appContext,
                    options,
                    FIREBASE_APP_NAME,
                )
                ?: throw ManagedCloudException.Unavailable
            if (firebase.options.projectId != config.projectId ||
                firebase.options.applicationId != config.googleAppId
            ) {
                throw ManagedCloudException.FirebaseProjectConflict
            }
            val messagingFirebase = runCatching { FirebaseApp.getInstance() }
                .getOrNull()
                ?: FirebaseApp.initializeApp(appContext, options)
                ?: throw ManagedCloudException.Unavailable
            if (messagingFirebase.options.projectId != config.projectId ||
                messagingFirebase.options.applicationId != config.googleAppId
            ) {
                throw ManagedCloudException.FirebaseProjectConflict
            }
            ManagedAppCheckProvider.install(firebase)
            val messaging = FirebaseMessaging.getInstance().apply {
                isAutoInitEnabled = false
            }
            FirebaseRuntime(
                auth = FirebaseAuth.getInstance(firebase),
                appCheck = FirebaseAppCheck.getInstance(firebase),
                messaging = messaging,
            ).also { firebaseRuntime = it }
        }
    }

    private suspend fun requestPhoneVerification(
        activity: Activity,
        phone: String,
        deletion: Boolean = false,
    ): String? = suspendCancellableCoroutine { continuation ->
        val auth = runtime().auth
        if (configuration?.disablePhoneAppVerificationForTesting == true) {
            if (phone != configuration.testPhoneNumber) {
                continuation.resumeWithException(ManagedCloudException.InvalidPhone)
                return@suspendCancellableCoroutine
            }
            auth.firebaseAuthSettings.setAppVerificationDisabledForTesting(true)
        }
        val callbacks = object : PhoneAuthProvider.OnVerificationStateChangedCallbacks() {
            override fun onVerificationCompleted(credential: PhoneAuthCredential) {
                scope.launch {
                    try {
                        if (deletion) {
                            currentUser().reauthenticate(credential).awaitManaged()
                        } else {
                            auth.signInWithCredential(credential).awaitManaged()
                            preferences.verificationId = null
                            reconcileAuthenticatedState()
                            setStatus(
                                text(R.string.managed_cloud_status_phone_verified),
                            )
                        }
                        if (continuation.isActive) continuation.resume(null)
                    } catch (error: Throwable) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(error)
                        } else {
                            setStatus(userMessage(error))
                        }
                    }
                }
            }

            override fun onVerificationFailed(error: com.google.firebase.FirebaseException) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }

            override fun onCodeSent(
                verificationId: String,
                token: ForceResendingToken,
            ) {
                if (continuation.isActive) continuation.resume(verificationId)
            }
        }
        val options = PhoneAuthOptions.newBuilder(auth)
            .setPhoneNumber(phone)
            .setTimeout(60L, TimeUnit.SECONDS)
            .setActivity(activity)
            .setCallbacks(callbacks)
            .build()
        PhoneAuthProvider.verifyPhoneNumber(options)
    }

    private fun beginBusy(): Boolean = synchronized(stateLock) {
        if (mutableState.value.busy) return@synchronized false
        mutableState.value = mutableState.value.copy(busy = true)
        true
    }

    private fun endBusy() {
        replaceState { it.copy(busy = false) }
    }

    private fun setPhase(phase: ManagedCloudPhase) {
        replaceState { it.copy(phase = phase) }
    }

    private fun setStatus(value: String) {
        val bounded = value.trim().take(512)
        runCatching { preferences.status = bounded }
        replaceState { it.copy(status = bounded) }
    }

    private fun setSocialStatus(value: String) {
        replaceState { it.copy(socialStatus = value.trim().take(512)) }
    }

    private fun setSafetyStatus(value: String) {
        replaceState { it.copy(safetyStatus = value.trim().take(512)) }
    }

    private fun clearSocialPresentation() {
        replaceState {
            it.copy(
                socialProfile = null,
                socialFriends = emptyList(),
                socialBlockedProfiles = emptyList(),
                socialRequests = emptyList(),
                socialFeed = emptyList(),
                socialLookup = null,
                socialInvite = null,
                socialStatus = "",
                hasPendingSocialInvite =
                    preferences.pendingSocialInviteCapability != null,
                pendingSocialNoopId = preferences.pendingSocialNoopId,
            )
        }
    }

    private fun clearSafetyPresentation() {
        stopManagedSafetyLocationSession("presentation_cleared")
        replaceState {
            it.copy(
                safetyContacts = null,
                safetyRequests = emptyList(),
                safetyIncidents = emptyList(),
                safetyInvite = null,
                safetyStatus = "",
                hasPendingSafetyInvite =
                    preferences.pendingSafetyInviteCapability != null,
            )
        }
    }

    private fun replaceSafetyIncident(
        incident: ManagedSafetyIncident,
        values: List<ManagedSafetyIncident>,
    ): List<ManagedSafetyIncident> =
        (values.filterNot { it.incidentId == incident.incidentId } + incident)
            .sortedByDescending(ManagedSafetyIncident::createdAt)

    private fun text(resource: Int, vararg arguments: Any): String =
        appContext.getString(resource, *arguments)

    private fun quantity(resource: Int, count: Int): String =
        appContext.resources.getQuantityString(resource, count, count)

    private fun localizedList(values: List<String>): String {
        val locale = appContext.resources.configuration.locales[0]
        return ListFormatter.getInstance(locale).format(values)
    }

    private fun maskedPhone(phone: String?): String {
        if (phone.isNullOrBlank() || phone.length < 4) {
            return text(R.string.managed_cloud_your_phone)
        }
        return "****${phone.takeLast(4)}"
    }

    private fun erasureStatus(status: String): String = text(
        when (status) {
            "queued" -> R.string.managed_cloud_erasure_queued
            "cooling_off" -> R.string.managed_cloud_erasure_cooling_off
            "running" -> R.string.managed_cloud_erasure_running
            "verifying" -> R.string.managed_cloud_erasure_verifying
            "completed" -> R.string.managed_cloud_erasure_completed
            "failed" -> R.string.managed_cloud_erasure_failed
            "canceled" -> R.string.managed_cloud_erasure_canceled
            else -> R.string.managed_cloud_erasure_pending
        },
    )

    private fun userMessage(error: Throwable): String = when (error) {
        is IllegalArgumentException ->
            text(R.string.managed_friends_error_invalid_input)
        is ManagedCloudException.InvalidPhone ->
            text(R.string.managed_cloud_error_invalid_phone)
        is ManagedCloudException.InvalidCode ->
            text(R.string.managed_cloud_error_invalid_code)
        is ManagedCloudException.CodeRequired ->
            text(R.string.managed_cloud_error_code_required)
        is ManagedCloudException.NotSignedIn ->
            text(R.string.managed_cloud_error_not_signed_in)
        is ManagedCloudException.ConsentRequired ->
            text(R.string.managed_cloud_error_consent_required)
        is ManagedCloudException.Unavailable ->
            text(R.string.managed_cloud_error_unavailable)
        is ManagedCloudException.FirebaseProjectConflict ->
            text(R.string.managed_cloud_error_project_conflict)
        is ManagedCloudException.ExportPreparationIncomplete ->
            text(R.string.managed_cloud_error_export_incomplete)
        is FirebaseAuthException ->
            error.localizedMessage?.takeIf(String::isNotBlank)
                ?: text(R.string.managed_cloud_error_phone_verification)
        is ManagedStorageException.Network ->
            text(R.string.managed_cloud_error_network)
        is ManagedStorageException.InvalidResponse ->
            text(R.string.managed_cloud_error_invalid_response)
        is ManagedStorageException.Authentication ->
            text(R.string.managed_cloud_error_authentication)
        is ManagedStorageException.Forbidden ->
            text(R.string.managed_cloud_error_forbidden)
        is ManagedStorageException.PolicyChanged ->
            text(R.string.managed_cloud_error_policy_changed)
        is ManagedStorageException.CursorExpired ->
            text(R.string.managed_cloud_error_cursor_expired)
        is ManagedStorageException.NotFound ->
            text(R.string.managed_cloud_error_not_found)
        is ManagedStorageException.QuotaExceeded ->
            text(R.string.managed_cloud_error_quota)
        is ManagedStorageException.Conflict ->
            text(R.string.managed_cloud_error_conflict)
        is ManagedStorageException.Server ->
            text(R.string.managed_cloud_error_server)
        is ManagedStorageException.DigestMismatch ->
            text(R.string.managed_cloud_error_digest)
        else -> text(R.string.managed_cloud_error_generic)
    }

    private fun setExportStatus(progress: ManagedHistoryExportProgress) {
        setStatus(
            when (progress.phase) {
                ManagedHistoryExportPhase.PREPARING ->
                    text(R.string.managed_cloud_status_export_snapshot)
                ManagedHistoryExportPhase.CHUNKS -> {
                    val completed = android.text.format.Formatter.formatShortFileSize(
                        appContext,
                        progress.completedChunkBytes,
                    )
                    val total = android.text.format.Formatter.formatShortFileSize(
                        appContext,
                        progress.totalChunkBytes,
                    )
                    text(
                        R.string.managed_cloud_status_export_chunks,
                        progress.completedObjects,
                        progress.totalObjects,
                        completed,
                        total,
                    )
                }
                ManagedHistoryExportPhase.DOCUMENTS ->
                    text(
                        R.string.managed_cloud_status_export_documents,
                        progress.completedObjects,
                        progress.totalObjects,
                    )
                ManagedHistoryExportPhase.FINALIZING ->
                    text(
                        R.string.managed_cloud_status_export_finalizing,
                        progress.completedObjects,
                    )
            },
        )
    }

    private fun replaceState(transform: (ManagedCloudState) -> ManagedCloudState) {
        synchronized(stateLock) {
            mutableState.value = transform(mutableState.value)
        }
    }

    private data class FirebaseRuntime(
        val auth: FirebaseAuth,
        val appCheck: FirebaseAppCheck,
        val messaging: FirebaseMessaging,
    )

    companion object {
        private const val FIREBASE_APP_NAME = "noop-managed"
        private const val CLOUD_RESTORE_PREFIX = "noop-plus-"
        private const val MAXIMUM_EXPORT_PREPARATION_PASSES = 256
        private const val SAFETY_CATCH_UP_INTERVAL_MS = 2L * 60L * 1_000L
        private val ACCOUNT_DELETION_CONFIRMATION_SHA256 = ManagedDigest.sha256(
            "delete-noop-plus-managed-account-v1".toByteArray(StandardCharsets.UTF_8),
        )

        @Volatile
        private var instance: ManagedCloudService? = null

        fun get(context: Context): ManagedCloudService =
            instance ?: synchronized(this) {
                instance ?: ManagedCloudService(context).also { instance = it }
            }

        private fun normalizedPhone(raw: String): String {
            val phone = raw.filterNot { it.isWhitespace() || it in "()-." }
            if (!phone.matches(Regex("^\\+[1-9][0-9]{7,14}$"))) {
                throw ManagedCloudException.InvalidPhone
            }
            return phone
        }

        private fun normalizedCode(raw: String): String {
            val code = raw.filter(Char::isDigit)
            if (code.length !in 4..8) throw ManagedCloudException.InvalidCode
            return code
        }

    }
}

internal object ManagedSafetyNotificationPermission {
    fun canRegister(context: Context): Boolean = runCatching {
        val appContext = context.applicationContext
        ManagedSafetyNotifier.prepare(appContext)
        val channelImportance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            manager.getNotificationChannel(ManagedSafetyNotifier.CHANNEL_ID)?.importance
        } else {
            null
        }
        canRegister(
            sdkInt = Build.VERSION.SDK_INT,
            permissionGranted = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED,
            appNotificationsEnabled = NotificationManagerCompat
                .from(appContext)
                .areNotificationsEnabled(),
            channelImportance = channelImportance,
        )
    }.getOrDefault(false)

    fun canRegister(
        sdkInt: Int,
        permissionGranted: Boolean,
        appNotificationsEnabled: Boolean,
        channelImportance: Int?,
    ): Boolean {
        if (sdkInt >= Build.VERSION_CODES.TIRAMISU && !permissionGranted) return false
        if (!appNotificationsEnabled) return false
        return sdkInt < Build.VERSION_CODES.O ||
            (
                channelImportance != null &&
                    channelImportance != NotificationManager.IMPORTANCE_NONE
            )
    }
}

internal fun managedDeletionDeadlinePassed(
    value: String?,
    now: Instant = Instant.now(),
): Boolean {
    if (value == null) return false
    val deadline = runCatching { Instant.parse(value) }.getOrNull()
        ?: return false
    return deadline <= now
}

private sealed class ManagedCloudException(message: String) : Exception(message) {
    data object InvalidPhone : ManagedCloudException("Invalid phone number")
    data object InvalidCode : ManagedCloudException("Invalid verification code")
    data object CodeRequired : ManagedCloudException("Verification code required")
    data object NotSignedIn : ManagedCloudException("Not signed in")
    data object ConsentRequired : ManagedCloudException("Consent required")
    data object Unavailable : ManagedCloudException("Managed storage unavailable")
    data object FirebaseProjectConflict : ManagedCloudException("Firebase project conflict")
    data object ExportPreparationIncomplete :
        ManagedCloudException("Managed export preparation incomplete")
}
