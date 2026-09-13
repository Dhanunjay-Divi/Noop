package com.noop.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.noop.AppDiagnosticsRecorder
import com.noop.BuildConfig
import com.noop.NoopApplication
import com.noop.R
import com.noop.ble.WhoopModel
import com.noop.data.WhoopDatabase
import com.noop.feedback.FeedbackArchive
import com.noop.feedback.FeedbackArchiveException
import com.noop.feedback.FeedbackFailureCategory
import com.noop.feedback.FeedbackOutbox
import com.noop.feedback.FeedbackOutboxException
import com.noop.feedback.FeedbackRuntimeStatus
import com.noop.feedback.FeedbackRuntimeStatusBus
import com.noop.feedback.FeedbackScheduler
import com.noop.feedback.FeedbackScreenshotCaptureGuard
import com.noop.feedback.FeedbackScreenshotPreview
import com.noop.feedback.FeedbackState
import com.noop.testcentre.DisplayScreenshot
import com.noop.testcentre.ReportReviewGate
import com.noop.testcentre.TestBundleAssembler
import com.noop.testcentre.TestBundleMeta
import com.noop.testcentre.TestDomain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.math.sqrt

internal object AppDiagnosticReportRequestBridge {
    private val mutableRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val requests = mutableRequests.asSharedFlow()

    fun request() {
        mutableRequests.tryEmit(Unit)
    }
}

internal class PhysicalShakeDetector(
    private val thresholdG: Float = 2.7f,
    private val minimumIntervalMs: Long = 2_000L,
) {
    private var lastTriggerAtMs = Long.MIN_VALUE

    fun sample(x: Float, y: Float, z: Float, nowMs: Long): Boolean {
        val g = sqrt(x * x + y * y + z * z) / android.hardware.SensorManager.GRAVITY_EARTH
        if (
            g < thresholdG ||
            (lastTriggerAtMs != Long.MIN_VALUE && nowMs - lastTriggerAtMs < minimumIntervalMs)
        ) {
            return false
        }
        lastTriggerAtMs = nowMs
        return true
    }
}

internal class AppDiagnosticReportController(
    private val activity: ComponentActivity,
    private val awaitScreenshotSurface: suspend (View) -> Unit =
        ::awaitUnderlyingScreenForScreenshot,
    private val screenshotPixelReader: (View) -> Bitmap? = ::captureVisibleWindow,
) {
    enum class Phase {
        EXPLANATION,
        BUILDING,
        REVIEW,
        QUEUED,
        UPLOADING,
        RETRY_SCHEDULED,
        SENT,
        CANCELED,
        FAILED,
    }

    var isPresented by mutableStateOf(false)
        private set
    var phase by mutableStateOf(Phase.EXPLANATION)
        private set
    var userNote by mutableStateOf("")
        private set
    var includeScreenshot by mutableStateOf(false)
        private set
    var screenshotAvailable by mutableStateOf(false)
        private set
    var screenshotCaptureInProgress by mutableStateOf(false)
        private set
    var screenshotCaptureSurfaceHidden by mutableStateOf(false)
        private set
    var entries by mutableStateOf<List<Pair<String, ByteArray>>>(emptyList())
        private set
    var statusMessage by mutableStateOf<String?>(null)
        private set
    var uploadProgress by mutableStateOf(0)
        private set
    var receipt by mutableStateOf<String?>(null)
        private set
    var deliveryState by mutableStateOf<FeedbackState?>(null)
        private set

    private var lastRequestAtMs: Long? = null
    private var capturedScreenPng: ByteArray? = null
    private var localFeedbackId: String? = null
    private var feedbackObservation: Job? = null
    private var screenshotCaptureJob: Job? = null
    private val screenshotCaptureGuard = FeedbackScreenshotCaptureGuard()
    private var activeScreenshotCaptureToken: Long? = null
    private var deliveryFailure = false
    private var deliveryFailureCategory = FeedbackFailureCategory.NONE
    private var deliveryActionInProgress by mutableStateOf(false)

    init {
        activity.lifecycleScope.launch {
            val latest = withContext(Dispatchers.IO) {
                if ((activity.application as NoopApplication).operationalRuntimeStarted) {
                    FeedbackScheduler.reconcile(activity)
                }
                FeedbackOutbox.from(activity).latestVisible()
            } ?: return@launch
            localFeedbackId = latest.localId
            applyRuntime(
                FeedbackRuntimeStatus(
                    record = latest,
                    progressPercent = FeedbackScheduler.progressFor(latest.state),
                ),
            )
            observeFeedback(latest.localId)
        }
    }

    val preventsDismissal: Boolean
        get() = phase == Phase.BUILDING

    val includesScreenAttachment: Boolean
        get() = entries.any { it.first == DisplayScreenshot.BUNDLE_NAME }

    val screenAttachmentBytes: ByteArray?
        get() = entries.firstOrNull { it.first == DisplayScreenshot.BUNDLE_NAME }?.second

    val isDeliveryFailure: Boolean
        get() = deliveryFailure

    val canRetryDelivery: Boolean
        get() = !deliveryActionInProgress && when (deliveryState) {
            FeedbackState.QUEUED,
            FeedbackState.RETRY_SCHEDULED,
            FeedbackState.FAILED,
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            FeedbackState.CANCEL_FAILED,
            -> deliveryFailureCategory !in setOf(
                FeedbackFailureCategory.ARCHIVE_INVALID,
                FeedbackFailureCategory.OUTBOX_FULL,
            )
            else -> false
        }

    val canCancelDelivery: Boolean
        get() = !deliveryActionInProgress &&
            deliveryState?.terminal == false &&
            deliveryState != FeedbackState.CANCELING &&
            deliveryState != FeedbackState.CANCEL_RETRY_SCHEDULED &&
            deliveryState != FeedbackState.CANCEL_FAILED

    val reviewPreview: String
        get() {
            val full = ReportReviewGate(entries).previewText
            val limit = 16_000
            if (full.length <= limit) return full
            val half = limit / 2
            return full.take(half) +
                "\n\n[${activity.getString(R.string.app_report_preview_shortened)}]\n\n" +
                full.takeLast(half)
        }

    fun requestFromShake() {
        request("shake")
    }

    fun requestManually() {
        request("test_centre")
    }

    fun requestDemo() {
        if (BuildConfig.DEBUG) request("debug_demo")
    }

    private fun request(source: String) {
        val now = SystemClock.elapsedRealtime()
        if (isPresented || lastRequestAtMs?.let { now - it < 2_000L } == true) return
        lastRequestAtMs = now
        AppDiagnosticsRecorder.record(
            "report.shake_detected",
            fields = mapOf("source" to source),
            includeResourceSnapshot = true,
        )

        if (localFeedbackId != null) {
            isPresented = true
            return
        }

        invalidateScreenshotCapture()
        userNote = ""
        entries = emptyList()
        statusMessage = null
        phase = Phase.EXPLANATION
        isPresented = true
    }

    fun updateUserNote(value: String) {
        userNote = value.take(TestBundleAssembler.MAX_USER_NOTE_CHARACTERS)
    }

    fun updateScreenshotInclusion(enabled: Boolean) {
        if (phase != Phase.EXPLANATION) return
        if (!enabled) {
            invalidateScreenshotCapture()
            return
        }
        if (includeScreenshot && (screenshotCaptureInProgress || screenshotAvailable)) return

        val captureToken = screenshotCaptureGuard.updateOptIn(true) ?: return
        screenshotCaptureJob?.cancel()
        activeScreenshotCaptureToken = captureToken
        includeScreenshot = true
        screenshotAvailable = false
        capturedScreenPng = null
        screenshotCaptureInProgress = true
        screenshotCaptureSurfaceHidden = true
        val view = activity.window.decorView
        screenshotCaptureJob = activity.lifecycleScope.launch(Dispatchers.Main.immediate) {
            var pendingBitmap: Bitmap? = null
            try {
                try {
                    awaitScreenshotSurface(view)
                    if (!screenshotCaptureGuard.accepts(captureToken, isPresented)) {
                        return@launch
                    }
                    pendingBitmap = screenshotPixelReader(view)
                } finally {
                    if (activeScreenshotCaptureToken == captureToken) {
                        screenshotCaptureSurfaceHidden = false
                    }
                }

                val bitmap = pendingBitmap
                pendingBitmap = null
                val validated = bitmap?.let { captured ->
                    withContext(Dispatchers.Default) {
                        try {
                            TestBundleAssembler.appReportScreenshotEntry(
                                compressPng(captured),
                            )?.second
                        } finally {
                            captured.recycle()
                        }
                    }
                }
                if (!screenshotCaptureGuard.accepts(captureToken, isPresented)) {
                    return@launch
                }
                capturedScreenPng = validated
                screenshotAvailable = validated != null
                includeScreenshot = validated != null
                AppDiagnosticsRecorder.record(
                    "report.screen_snapshot_captured",
                    fields = mapOf(
                        "available" to (validated != null).toString(),
                    ),
                )
            } finally {
                pendingBitmap?.recycle()
                if (activeScreenshotCaptureToken == captureToken) {
                    activeScreenshotCaptureToken = null
                    screenshotCaptureJob = null
                    screenshotCaptureInProgress = false
                    screenshotCaptureSurfaceHidden = false
                }
            }
        }
    }

    fun build() {
        if (screenshotCaptureInProgress ||
            (phase != Phase.EXPLANATION && (phase != Phase.FAILED || deliveryFailure))
        ) {
            return
        }
        phase = Phase.BUILDING
        deliveryFailure = false
        statusMessage = null
        val note = userNote
        val screenshot = capturedScreenPng.takeIf { includeScreenshot }
        AppDiagnosticsRecorder.record(
            "report.build_requested",
            fields = mapOf(
                "user_context_provided" to note.isNotBlank().toString(),
                "screen_snapshot_included" to (screenshot != null).toString(),
            ),
            includeResourceSnapshot = true,
        )

        activity.lifecycleScope.launch {
            val prepared = runCatching {
                withContext(Dispatchers.IO) {
                    val app = activity.application as NoopApplication
                    val dbPath = activity.getDatabasePath(WhoopDatabase.DB_NAME).path
                    val dbBytes = listOf("", "-wal", "-shm").sumOf { suffix ->
                        File(dbPath + suffix).takeIf(File::isFile)?.length() ?: 0L
                    }
                    val latestHr = app.repository.latestHrSampleTsUnion(app.activeDeviceId)
                    val live = app.ble.state.value
                    val nowUnix = System.currentTimeMillis() / 1_000L
                    val bondState = when {
                        live.encryptedBond -> "encrypted"
                        live.bonded -> "partial"
                        else -> "none"
                    }
                    AppDiagnosticsRecorder.record(
                        "band.collection_snapshot",
                        fields = mapOf(
                            "connection_state" to
                                if (live.connected) "connected" else "disconnected",
                            "bond_state" to bondState,
                            "history_sync_state" to
                                if (live.backfilling) "active" else "idle",
                            "live_frame_freshness" to
                                AppDiagnosticsRecorder.freshnessBucket(
                                    live.heartRateReceivedAtMillis?.let {
                                        nowUnix - (it / 1_000L)
                                    },
                                ),
                            "collection_freshness" to
                                AppDiagnosticsRecorder.freshnessBucket(
                                    latestHr?.let { nowUnix - it },
                                ),
                        ),
                    )
                    val captureBytes = listOf(
                        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE,
                        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE + ".1",
                    ).sumOf { name ->
                        File(activity.filesDir, name).takeIf(File::isFile)?.length() ?: 0L
                    }
                    val storage = TestBundleMeta.Storage(
                        dbBytes = dbBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                        rows = emptyMap(),
                        rawCaptureBytes =
                            captureBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                    )
                    val model = NoopPrefs.of(activity)
                        .getString("noop.selectedWhoopModel", null)
                        ?.let { raw ->
                            runCatching { WhoopModel.valueOf(raw).displayName }.getOrNull()
                        }
                    FeedbackArchive.prepareForReview(
                        TestBundleAssembler.assemble(
                            context = activity,
                            profile = TestDomain.MASTER,
                            // APP_HANG deliberately excludes the strap transcript. Do not even retain
                            // the live log in the report-building call.
                            logText = "",
                            storage = storage,
                            strapModel = model,
                            purpose = TestBundleAssembler.Purpose.APP_HANG,
                            runtimeDiagnostics = AppDiagnosticsRecorder.diagnosticEntries(),
                            userNote = note,
                            appReportScreenshotPng = screenshot,
                        ),
                    )
                }
            }.getOrElse {
                AppDiagnosticsRecorder.record(
                    "report.build_failed",
                    fields = mapOf("failure_kind" to reportFailureKind(it)),
                    includeResourceSnapshot = true,
                )
                null
            }

            if (prepared == null || prepared.entries.isEmpty()) {
                phase = Phase.FAILED
                statusMessage = activity.getString(R.string.app_report_error_prepare)
                AppDiagnosticsRecorder.record(
                    "report.build_failed",
                    fields = mapOf("reason" to "empty_bundle"),
                    includeResourceSnapshot = true,
                )
                return@launch
            }
            entries = prepared.entries
            phase = Phase.REVIEW
            AppDiagnosticsRecorder.record(
                "report.build_completed",
                fields = mapOf(
                    "file_count" to prepared.entries.size.toString(),
                    "unsafe_entries_excluded" to
                        prepared.excludedUnsafeEntryCount.toString(),
                ),
            )
        }
    }

    fun removeScreenAttachment() {
        if (phase != Phase.REVIEW || !includesScreenAttachment) return
        entries = entries.filterNot { it.first == DisplayScreenshot.BUNDLE_NAME }
        invalidateScreenshotCapture()
        statusMessage = activity.getString(R.string.app_report_status_snapshot_removed)
        AppDiagnosticsRecorder.record("report.screen_snapshot_removed")
    }

    fun sendFeedback() {
        if (phase != Phase.REVIEW || entries.isEmpty()) return
        phase = Phase.QUEUED
        deliveryState = FeedbackState.QUEUED
        uploadProgress = 0
        receipt = null
        deliveryFailure = false
        statusMessage = null
        val reportEntries = entries.map { (name, bytes) -> name to bytes.copyOf() }
        val includesNote = reportEntries.any { it.first == "user-note.txt" }
        val includesScreenshot =
            reportEntries.any { it.first == DisplayScreenshot.BUNDLE_NAME }
        AppDiagnosticsRecorder.record(
            "report.send_confirmed",
            fields = mapOf(
                "file_count" to reportEntries.size.toString(),
                "user_context_included" to includesNote.toString(),
                "screen_snapshot_included" to includesScreenshot.toString(),
            ),
        )
        activity.lifecycleScope.launch {
            val staged = runCatching {
                withContext(NonCancellable + Dispatchers.IO) {
                    val record = FeedbackOutbox.from(activity).stage(
                        entries = reportEntries,
                        includesUserNote = includesNote,
                        includesScreenshot = includesScreenshot,
                    )
                    FeedbackScheduler.enqueue(activity, record)
                    record
                }
            }.getOrElse {
                phase = Phase.REVIEW
                deliveryState = null
                statusMessage = activity.getString(R.string.app_report_error_queue)
                AppDiagnosticsRecorder.record(
                    "report.queue_failed",
                    fields = mapOf("failure_kind" to reportFailureKind(it)),
                )
                return@launch
            }
            localFeedbackId = staged.localId
            clearSensitiveDraft()
            applyRuntime(FeedbackRuntimeStatus(staged, 0))
            observeFeedback(staged.localId)
        }
    }

    fun retryFeedback() {
        if (deliveryActionInProgress) return
        val localId = localFeedbackId ?: return
        deliveryActionInProgress = true
        activity.lifecycleScope.launch {
            val result = runCatching {
                withContext(NonCancellable + Dispatchers.IO) {
                    when (deliveryState) {
                        FeedbackState.QUEUED -> {
                            val record = FeedbackOutbox.from(activity).load(localId)
                                ?: return@withContext null
                            FeedbackScheduler.enqueue(activity, record, replace = true)
                            record
                        }
                        else -> FeedbackScheduler.retry(activity, localId)
                    }
                }
            }.getOrNull()
            deliveryActionInProgress = false
            if (result == null) {
                statusMessage = activity.getString(R.string.app_report_error_action)
                AppDiagnosticsRecorder.record(
                    "report.retry_failed",
                    fields = mapOf("failure_kind" to "operation_failed"),
                )
                return@launch
            }
            deliveryFailure = false
            applyRuntime(
                FeedbackRuntimeStatus(
                    result,
                    FeedbackScheduler.progressFor(result.state),
                ),
            )
        }
    }

    fun cancelFeedback() {
        if (deliveryActionInProgress) return
        val localId = localFeedbackId ?: return
        deliveryActionInProgress = true
        activity.lifecycleScope.launch {
            val record = runCatching {
                withContext(NonCancellable + Dispatchers.IO) {
                    FeedbackScheduler.cancel(activity, localId)
                }
            }.getOrNull()
            deliveryActionInProgress = false
            if (record == null) {
                statusMessage = activity.getString(R.string.app_report_error_action)
                AppDiagnosticsRecorder.record(
                    "report.cancel_failed",
                    fields = mapOf("failure_kind" to "operation_failed"),
                )
                return@launch
            }
            applyRuntime(FeedbackRuntimeStatus(record, 0))
        }
    }

    fun close() {
        if (preventsDismissal) return
        isPresented = false
        invalidateScreenshotCapture()
        if (phase == Phase.SENT || phase == Phase.CANCELED) {
            localFeedbackId?.let(FeedbackRuntimeStatusBus::forget)
            feedbackObservation?.cancel()
            feedbackObservation = null
            localFeedbackId = null
            deliveryState = null
            deliveryFailure = false
            deliveryFailureCategory = FeedbackFailureCategory.NONE
            uploadProgress = 0
            receipt = null
            resetDraft()
        } else if (localFeedbackId == null) {
            resetDraft()
        }
    }

    private fun observeFeedback(localId: String) {
        feedbackObservation?.cancel()
        feedbackObservation = activity.lifecycleScope.launch {
            FeedbackRuntimeStatusBus.statuses.collect { statuses ->
                statuses[localId]?.let(::applyRuntime)
            }
        }
    }

    private fun applyRuntime(status: FeedbackRuntimeStatus) {
        if (localFeedbackId != null && localFeedbackId != status.record.localId) return
        deliveryState = status.record.state
        uploadProgress = status.progressPercent.coerceIn(0, 100)
        receipt = status.receipt
        phase = when (status.record.state) {
            FeedbackState.QUEUED,
            FeedbackState.CANCELING,
            -> Phase.QUEUED
            FeedbackState.UPLOADING -> Phase.UPLOADING
            FeedbackState.RETRY_SCHEDULED,
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            -> Phase.RETRY_SCHEDULED
            FeedbackState.SENT -> Phase.SENT
            FeedbackState.CANCELED -> Phase.CANCELED
            FeedbackState.FAILED,
            FeedbackState.CANCEL_FAILED,
            -> Phase.FAILED
        }
        deliveryFailure =
            status.record.state == FeedbackState.FAILED ||
                status.record.state == FeedbackState.CANCEL_FAILED
        deliveryFailureCategory = status.record.failureCategory
        statusMessage = deliveryStatusMessage(status.record)
    }

    private fun deliveryStatusMessage(record: com.noop.feedback.FeedbackRecord): String =
        when (record.state) {
        FeedbackState.QUEUED -> activity.getString(R.string.app_report_status_queued)
        FeedbackState.UPLOADING -> activity.getString(R.string.app_report_status_uploading)
        FeedbackState.RETRY_SCHEDULED ->
            activity.getString(R.string.app_report_status_retry_scheduled)
        FeedbackState.CANCELING ->
            activity.getString(R.string.app_report_status_canceling)
        FeedbackState.CANCEL_RETRY_SCHEDULED ->
            activity.getString(R.string.app_report_status_cancel_retry_scheduled)
        FeedbackState.CANCEL_FAILED ->
            activity.getString(R.string.app_report_error_cancel_failed)
        FeedbackState.SENT -> activity.getString(
            if (record.localArchiveRemoved) {
                R.string.app_report_status_sent
            } else {
                R.string.app_report_status_sent_cleanup_pending
            },
        )
        FeedbackState.CANCELED -> activity.getString(
            if (record.localArchiveRemoved) {
                R.string.app_report_status_canceled
            } else {
                R.string.app_report_status_canceled_cleanup_pending
            },
        )
        FeedbackState.FAILED -> when (record.failureCategory) {
            FeedbackFailureCategory.ARCHIVE_INVALID ->
                activity.getString(R.string.app_report_error_archive_invalid)
            FeedbackFailureCategory.CONFIGURATION ->
                activity.getString(R.string.app_report_error_configuration)
            FeedbackFailureCategory.SERVER_REJECTED,
            FeedbackFailureCategory.INVALID_RESPONSE,
            -> activity.getString(R.string.app_report_error_rejected)
            else -> activity.getString(R.string.app_report_error_delivery)
        }
    }

    private fun clearSensitiveDraft() {
        userNote = ""
        invalidateScreenshotCapture()
        entries = emptyList()
    }

    private fun resetDraft() {
        phase = Phase.EXPLANATION
        clearSensitiveDraft()
        statusMessage = null
    }

    private fun invalidateScreenshotCapture() {
        screenshotCaptureGuard.invalidate()
        activeScreenshotCaptureToken = null
        screenshotCaptureJob?.cancel()
        screenshotCaptureJob = null
        screenshotCaptureInProgress = false
        screenshotCaptureSurfaceHidden = false
        includeScreenshot = false
        screenshotAvailable = false
        capturedScreenPng = null
    }

    private fun compressPng(bitmap: Bitmap): ByteArray? = runCatching {
        ByteArrayOutputStream().use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            output.toByteArray()
        }
    }.getOrNull()
}

private suspend fun awaitUnderlyingScreenForScreenshot(view: View) {
    repeat(2) {
        suspendCancellableCoroutine { continuation ->
            val callback = Runnable {
                if (continuation.isActive) continuation.resume(Unit)
            }
            view.postOnAnimation(callback)
            continuation.invokeOnCancellation {
                view.removeCallbacks(callback)
            }
        }
    }
}

private fun captureVisibleWindow(view: View): Bitmap? = runCatching {
    val size = FeedbackScreenshotPreview.captureSize(view.width, view.height)
        ?: return@runCatching null
    Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888).also { bitmap ->
        Canvas(bitmap).apply {
            scale(
                size.width.toFloat() / view.width.toFloat(),
                size.height.toFloat() / view.height.toFloat(),
            )
            view.draw(this)
        }
    }
}.getOrNull()

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AppDiagnosticReportSheet(controller: AppDiagnosticReportController) {
    if (!controller.isPresented || controller.screenshotCaptureSurfaceHidden) return

    ModalBottomSheet(
        onDismissRequest = controller::close,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Palette.surfaceBase,
        contentColor = Palette.textPrimary,
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxHeight(0.96f)
                .padding(horizontal = 20.dp, vertical = 18.dp),
        ) {
            ReportSheetTitle(controller)
            Spacer(Modifier.height(18.dp))
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .testTag("noop.app-report.scroll"),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                when (controller.phase) {
                    AppDiagnosticReportController.Phase.EXPLANATION ->
                        ReportExplanation(controller)
                    AppDiagnosticReportController.Phase.BUILDING ->
                        ReportBuilding()
                    AppDiagnosticReportController.Phase.REVIEW ->
                        ReportReview(controller)
                    AppDiagnosticReportController.Phase.QUEUED,
                    AppDiagnosticReportController.Phase.UPLOADING,
                    AppDiagnosticReportController.Phase.RETRY_SCHEDULED,
                    AppDiagnosticReportController.Phase.SENT,
                    AppDiagnosticReportController.Phase.CANCELED,
                    -> ReportDelivery(controller)
                    AppDiagnosticReportController.Phase.FAILED ->
                        ReportFailure(controller)
                }
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}

@Composable
private fun ReportSheetTitle(controller: AppDiagnosticReportController) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.BugReport,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(28.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(
                uiString(R.string.app_report_title),
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
            Text(
                uiString(R.string.app_report_subtitle),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        androidx.compose.material3.IconButton(
            onClick = controller::close,
            enabled = !controller.preventsDismissal,
        ) {
            Icon(
                Icons.Filled.Close,
                contentDescription = uiString(R.string.app_report_close_content_description),
            )
        }
    }
}

@Composable
private fun ReportExplanation(controller: AppDiagnosticReportController) {
    val snapshotConsentLabel = uiString(R.string.app_report_include_snapshot)
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            title = uiString(R.string.app_report_capture_title),
            detail = uiString(R.string.app_report_capture_detail),
        )

        NoopCard {
            Column {
                EvidenceRow(
                    Icons.Filled.Speed,
                    uiString(R.string.app_report_evidence_performance_title),
                    uiString(R.string.app_report_evidence_performance_detail),
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Layers,
                    uiString(R.string.app_report_evidence_recent_path_title),
                    uiString(R.string.app_report_evidence_recent_path_detail),
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Storage,
                    uiString(R.string.app_report_evidence_data_pipeline_title),
                    uiString(R.string.app_report_evidence_data_pipeline_detail),
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Bluetooth,
                    uiString(R.string.app_report_evidence_band_status_title),
                    uiString(R.string.app_report_evidence_band_status_detail),
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.PhoneAndroid,
                    uiString(R.string.app_report_evidence_android_title),
                    uiString(R.string.app_report_evidence_android_detail),
                )
            }
        }

        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    uiString(R.string.app_report_user_note_title),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    uiString(R.string.app_report_user_note_detail),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                OutlinedTextField(
                    value = controller.userNote,
                    onValueChange = controller::updateUserNote,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("noop.app-report.user-note"),
                    minLines = 3,
                    maxLines = 6,
                    placeholder = {
                        Text(uiString(R.string.app_report_user_note_placeholder))
                    },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Palette.surfaceRaised,
                        unfocusedContainerColor = Palette.surfaceRaised,
                        focusedTextColor = Palette.textPrimary,
                        unfocusedTextColor = Palette.textPrimary,
                    ),
                )
                Text(
                    uiString(
                        R.string.app_report_character_count,
                        controller.userNote.length,
                        TestBundleAssembler.MAX_USER_NOTE_CHARACTERS,
                    ),
                    style = NoopType.mono,
                    color = Palette.textTertiary,
                    modifier = Modifier.align(Alignment.End),
                )
            }
        }

        NoopCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("noop.app-report.include-screenshot")
                    .toggleable(
                        value = controller.includeScreenshot,
                        role = Role.Switch,
                        onValueChange = controller::updateScreenshotInclusion,
                    )
                    .semantics(mergeDescendants = true) {
                        contentDescription = snapshotConsentLabel
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    Icons.Filled.PhotoCamera,
                    contentDescription = null,
                    tint = Palette.accent,
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        uiString(R.string.app_report_include_snapshot),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        if (controller.screenshotAvailable) {
                            uiString(R.string.app_report_snapshot_available_detail)
                        } else {
                            uiString(R.string.app_report_snapshot_unavailable_detail)
                        },
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                NoopToggleSwitch(
                    checked = controller.includeScreenshot,
                    onCheckedChange = null,
                )
            }
        }

        Text(
            uiString(R.string.app_report_privacy_detail),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )

        NoopButton(
            text = uiString(R.string.app_report_build),
            leadingIcon = Icons.Filled.Description,
            fullWidth = true,
            enabled = !controller.screenshotCaptureInProgress,
            onClick = controller::build,
        )
        NoopButton(
            text = uiString(R.string.app_report_cancel),
            leadingIcon = Icons.Filled.Close,
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            onClick = controller::close,
        )
    }
}

@Composable
private fun ReportBuilding() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 52.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        CircularProgressIndicator(color = Palette.accent)
        Text(uiString(R.string.app_report_preparing_title), style = NoopType.title2)
        Text(
            uiString(R.string.app_report_preparing_detail),
            style = NoopType.body,
            color = Palette.textSecondary,
        )
    }
}

@Composable
private fun ReportReview(controller: AppDiagnosticReportController) {
    val screenshotBytes = controller.screenAttachmentBytes
    var screenshotBitmap by remember(screenshotBytes) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(screenshotBytes) {
        val pending = AtomicReference<Bitmap?>()
        try {
            withContext(Dispatchers.Default) {
                pending.set(screenshotBytes?.let(FeedbackScreenshotPreview::decode))
            }
            screenshotBitmap = pending.getAndSet(null)
        } finally {
            pending.getAndSet(null)?.recycle()
        }
    }
    DisposableEffect(screenshotBitmap) {
        val displayedBitmap = screenshotBitmap
        onDispose { displayedBitmap?.recycle() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            uiString(R.string.app_report_ready_title),
            uiString(R.string.app_report_ready_detail),
        )
        NoopCard {
            Column {
                controller.entries.forEachIndexed { index, entry ->
                    if (index > 0) HorizontalDivider(color = Palette.hairline)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            if (entry.first.endsWith(".png")) {
                                Icons.Filled.PhotoCamera
                            } else {
                                Icons.Filled.Description
                            },
                            contentDescription = null,
                            tint = Palette.accent,
                        )
                        Text(
                            entry.first,
                            style = NoopType.footnote,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            android.text.format.Formatter.formatShortFileSize(
                                androidx.compose.ui.platform.LocalContext.current,
                                entry.second.size.toLong(),
                            ),
                            style = NoopType.mono,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
        }

        screenshotBitmap?.let { bitmap ->
            Text(
                uiString(R.string.app_report_snapshot_preview_title),
                style = NoopType.overline,
                color = Palette.textSecondary,
            )
            NoopCard {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription =
                        uiString(R.string.app_report_snapshot_preview_content_description),
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(220.dp)
                        .testTag("noop.app-report.snapshot-preview"),
                )
            }
        }

        if (controller.reviewPreview.isNotBlank()) {
            Text(
                uiString(R.string.app_report_redacted_preview),
                style = NoopType.overline,
                color = Palette.textSecondary,
            )
            NoopCard {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 260.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        controller.reviewPreview,
                        color = Palette.textSecondary,
                        fontFamily = FontFamily.Monospace,
                        style = NoopType.footnote,
                    )
                }
            }
        }

        controller.statusMessage?.let {
            Text(it, style = NoopType.footnote, color = Palette.textSecondary)
        }

        NoopButton(
            text = uiString(R.string.app_report_send_feedback),
            leadingIcon = Icons.Filled.CloudUpload,
            fullWidth = true,
            modifier = Modifier.testTag("noop.app-report.send-feedback"),
            onClick = controller::sendFeedback,
        )
        if (controller.includesScreenAttachment) {
            NoopButton(
                text = uiString(R.string.app_report_remove_snapshot),
                leadingIcon = Icons.Filled.Delete,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = controller::removeScreenAttachment,
            )
        }
    }
}

@Composable
private fun ReportDelivery(controller: AppDiagnosticReportController) {
    val state = controller.deliveryState
    val icon = when (state) {
        FeedbackState.SENT -> Icons.Filled.CheckCircle
        FeedbackState.RETRY_SCHEDULED,
        FeedbackState.CANCEL_RETRY_SCHEDULED,
        -> Icons.Filled.Schedule
        FeedbackState.CANCELED -> Icons.Filled.Close
        else -> Icons.Filled.CloudUpload
    }
    val tint = when (state) {
        FeedbackState.SENT -> Palette.statusPositive
        FeedbackState.RETRY_SCHEDULED,
        FeedbackState.CANCEL_RETRY_SCHEDULED,
        -> Palette.statusWarning
        FeedbackState.CANCELED -> Palette.textSecondary
        else -> Palette.accent
    }
    val title = when (state) {
        FeedbackState.QUEUED -> uiString(R.string.app_report_queued_title)
        FeedbackState.UPLOADING -> uiString(R.string.app_report_uploading_title)
        FeedbackState.RETRY_SCHEDULED ->
            uiString(R.string.app_report_retry_scheduled_title)
        FeedbackState.CANCELING ->
            uiString(R.string.app_report_canceling_title)
        FeedbackState.CANCEL_RETRY_SCHEDULED ->
            uiString(R.string.app_report_cancel_retry_title)
        FeedbackState.SENT -> uiString(R.string.app_report_sent_title)
        FeedbackState.CANCELED -> uiString(R.string.app_report_canceled_title)
        else -> uiString(R.string.app_report_queued_title)
    }
    val progressText = if (state == FeedbackState.UPLOADING) {
        uiString(R.string.app_report_progress_percent, controller.uploadProgress)
    } else {
        null
    }
    val accessibilityState = listOfNotNull(
        title,
        controller.statusMessage,
        progressText,
    ).joinToString(". ")

    Column(
        modifier = Modifier
            .testTag("noop.app-report.delivery-status")
            .semantics {
                liveRegion = LiveRegionMode.Polite
                stateDescription = accessibilityState
            },
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        NoopCard {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(36.dp),
                )
                Text(title, style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    controller.statusMessage.orEmpty(),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
                if (state == FeedbackState.UPLOADING) {
                    LinearProgressIndicator(
                        progress = { controller.uploadProgress / 100f },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("noop.app-report.upload-progress"),
                        color = Palette.accent,
                        trackColor = Palette.hairline,
                    )
                    Text(
                        progressText.orEmpty(),
                        style = NoopType.mono,
                        color = Palette.textTertiary,
                    )
                }
                if (state == FeedbackState.SENT) {
                    Text(
                        controller.receipt?.let {
                            uiString(R.string.app_report_receipt, it)
                        } ?: uiString(R.string.app_report_receipt_confirmed),
                        modifier = Modifier.testTag("noop.app-report.receipt"),
                        style = NoopType.mono,
                        color = Palette.statusPositiveText,
                    )
                }
            }
        }

        if (controller.canRetryDelivery) {
            NoopButton(
                text = uiString(R.string.app_report_retry_now),
                leadingIcon = Icons.Filled.Refresh,
                fullWidth = true,
                modifier = Modifier.testTag("noop.app-report.retry"),
                onClick = controller::retryFeedback,
            )
        }
        if (controller.canCancelDelivery) {
            NoopButton(
                text = uiString(R.string.app_report_cancel_send),
                leadingIcon = Icons.Filled.Close,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                modifier = Modifier.testTag("noop.app-report.cancel-send"),
                onClick = controller::cancelFeedback,
            )
        }
        NoopButton(
            text = when (state) {
                FeedbackState.SENT,
                FeedbackState.CANCELED,
                -> uiString(R.string.app_report_close)
                else -> uiString(R.string.app_report_continue_background)
            },
            leadingIcon = Icons.Filled.Close,
            kind = NoopButtonKind.Tertiary,
            fullWidth = true,
            onClick = controller::close,
        )
    }
}

@Composable
private fun ReportFailure(controller: AppDiagnosticReportController) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            if (controller.isDeliveryFailure) {
                uiString(R.string.app_report_send_failed_title)
            } else {
                uiString(R.string.app_report_not_ready_title)
            },
            controller.statusMessage ?: uiString(R.string.app_report_prepare_zip_fallback),
        )
        if (controller.isDeliveryFailure) {
            if (controller.canRetryDelivery) {
                NoopButton(
                    text = uiString(R.string.app_report_retry_now),
                    leadingIcon = Icons.Filled.Refresh,
                    fullWidth = true,
                    modifier = Modifier.testTag("noop.app-report.retry"),
                    onClick = controller::retryFeedback,
                )
            }
            if (controller.canCancelDelivery) {
                NoopButton(
                    text = uiString(R.string.app_report_cancel_send),
                    leadingIcon = Icons.Filled.Close,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    modifier = Modifier.testTag("noop.app-report.cancel-send"),
                    onClick = controller::cancelFeedback,
                )
            }
        } else {
            NoopButton(
                text = uiString(R.string.app_report_try_again),
                leadingIcon = Icons.Filled.BugReport,
                fullWidth = true,
                onClick = controller::build,
            )
        }
        NoopButton(
            text = uiString(R.string.app_report_close),
            leadingIcon = Icons.Filled.Close,
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            onClick = controller::close,
        )
    }
}

@Composable
private fun ReportHeader(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(title, style = NoopType.title2, color = Palette.textPrimary)
        Text(detail, style = NoopType.body, color = Palette.textSecondary)
    }
}

@Composable
private fun EvidenceRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    detail: String,
) {
    Row(
        modifier = Modifier.padding(vertical = 11.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Palette.accent)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

private fun reportFailureKind(error: Throwable): String = when (error) {
    is FeedbackArchiveException -> "archive_rejected"
    is FeedbackOutboxException -> when (error.reason) {
        FeedbackOutboxException.Reason.FULL -> "outbox_full"
        FeedbackOutboxException.Reason.RECORD_NOT_FOUND -> "record_missing"
        FeedbackOutboxException.Reason.INVALID_RECORD,
        FeedbackOutboxException.Reason.INVALID_TRANSITION,
        -> "outbox_invalid"
        FeedbackOutboxException.Reason.STATE_UNAVAILABLE -> "outbox_read"
        FeedbackOutboxException.Reason.WRITE_FAILED -> "outbox_write"
    }
    is java.io.IOException -> "io"
    is SecurityException -> "permission"
    else -> "unexpected"
}
