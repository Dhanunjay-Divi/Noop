package com.noop.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.noop.AppDiagnosticsRecorder
import com.noop.BuildConfig
import com.noop.NoopApplication
import com.noop.ble.WhoopModel
import com.noop.data.WhoopDatabase
import com.noop.testcentre.DisplayScreenshot
import com.noop.testcentre.ReportReviewGate
import com.noop.testcentre.TestBundleAssembler
import com.noop.testcentre.TestBundleMeta
import com.noop.testcentre.TestDomain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
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
) {
    enum class Phase {
        EXPLANATION,
        BUILDING,
        REVIEW,
        SHARING,
        FAILED,
    }

    var isPresented by mutableStateOf(false)
        private set
    var phase by mutableStateOf(Phase.EXPLANATION)
        private set
    var userNote by mutableStateOf("")
        private set
    var includeScreenshot by mutableStateOf(false)
    var screenshotAvailable by mutableStateOf(false)
        private set
    var entries by mutableStateOf<List<Pair<String, ByteArray>>>(emptyList())
        private set
    var statusMessage by mutableStateOf<String?>(null)
        private set

    private var lastRequestAtMs: Long? = null
    private var capturedScreenPng: ByteArray? = null

    val preventsDismissal: Boolean
        get() = phase == Phase.BUILDING || phase == Phase.SHARING

    val includesScreenAttachment: Boolean
        get() = entries.any { it.first == DisplayScreenshot.BUNDLE_NAME }

    val reviewPreview: String
        get() {
            val full = ReportReviewGate(entries).previewText
            val limit = 16_000
            if (full.length <= limit) return full
            val half = limit / 2
            return full.take(half) +
                "\n\n[Preview shortened. The complete bounded files are listed above.]\n\n" +
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

        // Draw before mounting the report sheet. Compression runs off-main; bytes stay transient and are
        // excluded unless the user explicitly enables the attachment.
        val bitmap = captureVisibleWindow(activity.window.decorView)
        capturedScreenPng = null
        screenshotAvailable = false
        includeScreenshot = false
        userNote = ""
        entries = emptyList()
        statusMessage = null
        phase = Phase.EXPLANATION
        isPresented = true

        if (bitmap == null) {
            AppDiagnosticsRecorder.record(
                "report.screen_snapshot_captured",
                fields = mapOf("available" to "false"),
            )
            return
        }
        activity.lifecycleScope.launch(Dispatchers.Default) {
            val png = compressPng(bitmap)
            bitmap.recycle()
            val validated = TestBundleAssembler.appReportScreenshotEntry(png)?.second
            withContext(Dispatchers.Main.immediate) {
                if (!isPresented) return@withContext
                capturedScreenPng = validated
                screenshotAvailable = validated != null
                AppDiagnosticsRecorder.record(
                    "report.screen_snapshot_captured",
                    fields = mapOf(
                        "available" to (validated != null).toString(),
                    ),
                )
            }
        }
    }

    fun updateUserNote(value: String) {
        userNote = value.take(TestBundleAssembler.MAX_USER_NOTE_CHARACTERS)
    }

    fun build() {
        if (phase != Phase.EXPLANATION && phase != Phase.FAILED) return
        phase = Phase.BUILDING
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
            val assembled = runCatching {
                withContext(Dispatchers.IO) {
                    val app = activity.application as NoopApplication
                    val dbPath = activity.getDatabasePath(WhoopDatabase.DB_NAME).path
                    val dbBytes = listOf("", "-wal", "-shm").sumOf { suffix ->
                        File(dbPath + suffix).takeIf(File::isFile)?.length() ?: 0L
                    }
                    val latestHr = app.repository.latestHrSampleTsUnion(app.activeDeviceId)
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
                        latestHrUnix = latestHr,
                    )
                    val model = NoopPrefs.of(activity)
                        .getString("noop.selectedWhoopModel", null)
                        ?.let { raw ->
                            runCatching { WhoopModel.valueOf(raw).displayName }.getOrNull()
                        }
                    TestBundleAssembler.assemble(
                        context = activity,
                        profile = TestDomain.MASTER,
                        logText = app.ble.exportLogText(),
                        storage = storage,
                        strapModel = model,
                        purpose = TestBundleAssembler.Purpose.APP_HANG,
                        runtimeDiagnostics = AppDiagnosticsRecorder.diagnosticEntries(),
                        userNote = note,
                        appReportScreenshotPng = screenshot,
                    )
                }
            }.getOrElse {
                AppDiagnosticsRecorder.record(
                    "report.build_failed",
                    fields = mapOf("failure_kind" to it.javaClass.simpleName),
                    includeResourceSnapshot = true,
                )
                emptyList()
            }

            if (assembled.isEmpty()) {
                phase = Phase.FAILED
                statusMessage = "NOOP could not prepare the report. Reopen the app and try again."
                return@launch
            }
            entries = assembled
            phase = Phase.REVIEW
            AppDiagnosticsRecorder.record(
                "report.build_completed",
                fields = mapOf("file_count" to assembled.size.toString()),
            )
        }
    }

    fun removeScreenAttachment() {
        if (phase != Phase.REVIEW || !includesScreenAttachment) return
        entries = entries.filterNot { it.first == DisplayScreenshot.BUNDLE_NAME }
        includeScreenshot = false
        statusMessage = "Screen snapshot removed from this report."
        AppDiagnosticsRecorder.record("report.screen_snapshot_removed")
    }

    fun share() {
        if (phase != Phase.REVIEW || entries.isEmpty()) return
        phase = Phase.SHARING
        statusMessage = null
        val reportEntries = entries
        val name = LogExport.bundleName(
            profile = "app-report",
            platform = "android",
            version = BuildConfig.VERSION_NAME,
        )
        AppDiagnosticsRecorder.record(
            "report.share_requested",
            fields = mapOf("file_count" to reportEntries.size.toString()),
        )
        activity.lifecycleScope.launch {
            val result = LogExport.exportBundle(activity, reportEntries, name)
            phase = if (result == null) Phase.FAILED else Phase.REVIEW
            statusMessage = if (result == null) {
                "The ZIP could not be created. No report was shared."
            } else {
                "Share sheet opened for $name"
            }
        }
    }

    fun close() {
        if (preventsDismissal) return
        isPresented = false
        phase = Phase.EXPLANATION
        userNote = ""
        includeScreenshot = false
        screenshotAvailable = false
        capturedScreenPng = null
        entries = emptyList()
        statusMessage = null
    }

    private fun captureVisibleWindow(view: View): Bitmap? = runCatching {
        if (view.width <= 0 || view.height <= 0) return@runCatching null
        Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { bitmap ->
            view.draw(Canvas(bitmap))
        }
    }.getOrNull()

    private fun compressPng(bitmap: Bitmap): ByteArray? = runCatching {
        ByteArrayOutputStream().use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            output.toByteArray()
        }
    }.getOrNull()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AppDiagnosticReportSheet(controller: AppDiagnosticReportController) {
    if (!controller.isPresented) return

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
                    AppDiagnosticReportController.Phase.REVIEW,
                    AppDiagnosticReportController.Phase.SHARING,
                    -> ReportReview(controller)
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
            Text("App report", style = NoopType.title2, color = Palette.textPrimary)
            Text(
                "Private evidence from this phone",
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        androidx.compose.material3.IconButton(
            onClick = controller::close,
            enabled = !controller.preventsDismissal,
        ) {
            Icon(Icons.Filled.Close, contentDescription = "Close app report")
        }
    }
}

@Composable
private fun ReportExplanation(controller: AppDiagnosticReportController) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            title = "Capture what happened",
            detail = "NOOP will package evidence already on this phone. Nothing uploads automatically.",
        )

        NoopCard {
            Column {
                EvidenceRow(
                    Icons.Filled.Speed,
                    "Performance",
                    "Frame hitches, main-thread stalls, memory pressure, storage and thermal state",
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Layers,
                    "Recent path",
                    "App lifecycle and fixed screen names from this and the previous launch",
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Storage,
                    "Data pipeline",
                    "Database open timing, saved heart-rate freshness and bounded sync outcomes",
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.Bluetooth,
                    "Band status",
                    "The existing redacted connection and history-sync log",
                )
                HorizontalDivider(color = Palette.hairline)
                EvidenceRow(
                    Icons.Filled.PhoneAndroid,
                    "Android diagnostics",
                    "Recent OS exit reason and ANR trace, when Android provides one",
                )
            }
        }

        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "What felt buggy? (optional)",
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    "Say what you tapped, what you expected, and what happened. Avoid names or contact details.",
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
                        Text("Example: Health paused after I opened a metric")
                    },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Palette.surfaceRaised,
                        unfocusedContainerColor = Palette.surfaceRaised,
                        focusedTextColor = Palette.textPrimary,
                        unfocusedTextColor = Palette.textPrimary,
                    ),
                )
                Text(
                    "${controller.userNote.length}/${TestBundleAssembler.MAX_USER_NOTE_CHARACTERS}",
                    style = NoopType.mono,
                    color = Palette.textTertiary,
                    modifier = Modifier.align(Alignment.End),
                )
            }
        }

        NoopCard {
            Row(
                modifier = Modifier.fillMaxWidth(),
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
                        "Include screen snapshot",
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        if (controller.screenshotAvailable) {
                            "Shows the screen before this report opened. It may contain health values."
                        } else {
                            "A screen snapshot is not available yet."
                        },
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                NoopToggleSwitch(
                    checked = controller.includeScreenshot,
                    onCheckedChange = if (controller.screenshotAvailable) {
                        { controller.includeScreenshot = it }
                    } else {
                        null
                    },
                    modifier = Modifier.testTag("noop.app-report.include-screenshot"),
                )
            }
        }

        Text(
            "Never included: your health database, raw sensor history, account credentials or API keys. " +
                "The temporary screen snapshot is discarded when this report closes.",
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )

        NoopButton(
            text = "Build report",
            leadingIcon = Icons.Filled.Description,
            fullWidth = true,
            onClick = controller::build,
        )
        NoopButton(
            text = "Cancel",
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
        Text("Preparing a private ZIP", style = NoopType.title2)
        Text(
            "Reading bounded logs, file size and the latest saved heart-rate timestamp. " +
                "Your health database stays on this phone.",
            style = NoopType.body,
            color = Palette.textSecondary,
        )
    }
}

@Composable
private fun ReportReview(controller: AppDiagnosticReportController) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            "Report ready",
            "Review the attachment list, then choose where to send or save the ZIP.",
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

        if (controller.reviewPreview.isNotBlank()) {
            Text(
                "REDACTED PREVIEW",
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
            text = if (controller.phase == AppDiagnosticReportController.Phase.SHARING) {
                "Preparing ZIP"
            } else {
                "Share ZIP"
            },
            leadingIcon = Icons.Filled.Upload,
            fullWidth = true,
            enabled = controller.phase != AppDiagnosticReportController.Phase.SHARING,
            onClick = controller::share,
        )
        if (controller.includesScreenAttachment) {
            NoopButton(
                text = "Remove screen snapshot",
                leadingIcon = Icons.Filled.Delete,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = controller::removeScreenAttachment,
            )
        }
    }
}

@Composable
private fun ReportFailure(controller: AppDiagnosticReportController) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ReportHeader(
            "Report not ready",
            controller.statusMessage ?: "NOOP could not prepare the ZIP.",
        )
        NoopButton(
            text = "Try again",
            leadingIcon = Icons.Filled.BugReport,
            fullWidth = true,
            onClick = controller::build,
        )
        NoopButton(
            text = "Close",
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
