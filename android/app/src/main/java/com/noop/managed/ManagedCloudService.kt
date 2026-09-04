package com.noop.managed

import android.app.Activity
import android.content.Context
import android.icu.text.ListFormatter
import android.net.Uri
import android.util.Log
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
import com.noop.R
import com.noop.data.BackupSettingsBridge
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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

    private val appContext = context.applicationContext
    private val configuration = ManagedCloudConfiguration.load()
    private val preferences by lazy { ManagedCloudPreferences(appContext) }
    private val database by lazy { WhoopDatabase.get(appContext) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val syncMutex = Mutex()
    private val firebaseLock = Any()
    private val stateLock = Any()

    @Volatile
    private var firebaseRuntime: FirebaseRuntime? = null

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
                replaceState {
                    it.copy(
                        status = preferences.status,
                        lastSuccessMs = preferences.lastSuccessMs,
                        deletionNotBefore = preferences.erasureNotBefore,
                    )
                }
            }
        }
    }

    /** Initializes persisted Firebase auth only for a configured build; it performs no upload. */
    fun bootstrap() {
        if (configuration == null) {
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
        try {
            val phone = normalizedPhone(rawPhoneNumber)
            val verificationId = requestPhoneVerification(activity, phone)
            if (verificationId != null) {
                preferences.verificationId = verificationId
                setPhase(ManagedCloudPhase.CODE_SENT)
                setStatus(text(R.string.managed_cloud_status_code_sent))
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    suspend fun verifyCode(rawCode: String) {
        if (!beginBusy()) return
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
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    suspend fun enroll() {
        if (!beginBusy()) return
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
            setStatus(text(R.string.managed_cloud_status_enabled))
            ManagedCloudScheduler.reconcile(appContext)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (runCatching { runtime().auth.currentUser != null }.getOrDefault(false)) {
                setPhase(ManagedCloudPhase.CONSENT_REQUIRED)
            }
            setStatus(userMessage(error))
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
            }
        } catch (error: CancellationException) {
            writer?.abort()
                ?: ManagedHistorySafArchiveWriter.removePartial(appContext, destination)
            setStatus(text(R.string.managed_cloud_status_export_canceled))
            throw error
        } catch (error: Throwable) {
            writer?.abort()
                ?: ManagedHistorySafArchiveWriter.removePartial(appContext, destination)
            setStatus(userMessage(error))
        } finally {
            endBusy()
        }
    }

    internal suspend fun syncForWorker(): ManagedCloudSyncSummary =
        performSync(SyncMode.AUTOMATIC)

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

    fun disconnect() {
        runCatching { runtime().auth.signOut() }
            .onFailure {
                setStatus(userMessage(it))
                return
            }
        preferences.disconnect()
        setPhase(ManagedCloudPhase.SIGNED_OUT)
        setStatus(text(R.string.managed_cloud_status_disconnected))
        ManagedCloudScheduler.reconcile(appContext)
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
        return preferences.automatic &&
            preferences.erasureJobId == null &&
            preferences.isEnrolled(scopeHash, config.storage.policyVersion)
    }

    internal fun lastAttemptMs(): Long =
        runCatching { preferences.lastAttemptMs }.getOrDefault(0L)

    private suspend fun performSync(mode: SyncMode): ManagedCloudSyncSummary =
        syncMutex.withLock {
            withContext(Dispatchers.IO) {
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
                            Log.i(
                                TAG,
                                "Managed sync token rejected; retrying once with forced refresh",
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
                summary
            }
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
        val localPruneBeforeMs = if (
            preferences.optimizePhoneStorage &&
            mode != SyncMode.EXPORT_PREPARATION
        ) {
            ManagedLocalRetentionPolicy.cutoff(System.currentTimeMillis())
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
                localPruneBeforeMs = localPruneBeforeMs,
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
    }

    private fun completeLocalErasureState() {
        runCatching { runtime().auth.signOut() }
        preferences.clearEnrollment()
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.SIGNED_OUT,
                deletionNotBefore = null,
                overview = null,
                installations = emptyList(),
            )
        }
        setStatus(text(R.string.managed_cloud_status_deletion_completed))
        ManagedCloudScheduler.reconcile(appContext)
    }

    private fun completeLocalDeletionHandoff() {
        runCatching { runtime().auth.signOut() }
        preferences.clearEnrollment()
        replaceState {
            it.copy(
                phase = ManagedCloudPhase.SIGNED_OUT,
                deletionNotBefore = null,
                overview = null,
                installations = emptyList(),
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
        setStatus(text(R.string.managed_cloud_status_deletion_canceled))
        ManagedCloudScheduler.reconcile(appContext)
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
            requireNotNull(configuration) { "Managed storage is not configured." }.storage,
        )

    private fun currentUser(): FirebaseUser =
        runtime().auth.currentUser ?: throw ManagedCloudException.NotSignedIn

    private fun accountScopeHash(): String = accountScopeHash(currentUser())

    private fun accountScopeHash(user: FirebaseUser): String =
        ManagedDigest.sha256(
            "noop-managed-account-v1\u0000${user.uid}".toByteArray(StandardCharsets.UTF_8),
        )

    private fun runtime(): FirebaseRuntime {
        firebaseRuntime?.let { return it }
        return synchronized(firebaseLock) {
            firebaseRuntime?.let { return@synchronized it }
            val config = configuration ?: throw ManagedCloudException.Unavailable
            val firebase = runCatching { FirebaseApp.getInstance(FIREBASE_APP_NAME) }
                .getOrNull()
                ?: FirebaseApp.initializeApp(
                    appContext,
                    FirebaseOptions.Builder()
                        .setProjectId(config.projectId)
                        .setApiKey(config.apiKey)
                        .setApplicationId(config.googleAppId)
                        .setGcmSenderId(config.gcmSenderId)
                        .build(),
                    FIREBASE_APP_NAME,
                )
                ?: throw ManagedCloudException.Unavailable
            if (firebase.options.projectId != config.projectId ||
                firebase.options.applicationId != config.googleAppId
            ) {
                throw ManagedCloudException.FirebaseProjectConflict
            }
            ManagedAppCheckProvider.install(firebase)
            FirebaseRuntime(
                auth = FirebaseAuth.getInstance(firebase),
                appCheck = FirebaseAppCheck.getInstance(firebase),
            ).also { firebaseRuntime = it }
        }
    }

    private suspend fun requestPhoneVerification(
        activity: Activity,
        phone: String,
        deletion: Boolean = false,
    ): String? = suspendCancellableCoroutine { continuation ->
        val auth = runtime().auth
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
    )

    companion object {
        private const val TAG = "ManagedCloudService"
        private const val FIREBASE_APP_NAME = "noop-managed"
        private const val CLOUD_RESTORE_PREFIX = "noop-plus-"
        private const val MAXIMUM_EXPORT_PREPARATION_PASSES = 256
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
