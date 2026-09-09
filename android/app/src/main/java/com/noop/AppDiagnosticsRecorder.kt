package com.noop

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.Window
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/**
 * Lightweight, always-on evidence for app hangs and slow UI on Android.
 *
 * Only fixed operational facts are accepted: lifecycle edges, fixed route names, operation durations,
 * frame summaries, process resources, and OS-authored exit traces. Health rows, account identifiers,
 * endpoints, credentials, request/response bodies, and user-entered text never enter this recorder.
 * Current/previous sessions and OS exit evidence are bounded in the app cache and are redacted again by
 * [com.noop.testcentre.TestBundleAssembler] before a user can share them.
 */
object AppDiagnosticsRecorder {
    class OperationToken internal constructor(
        internal val id: String,
        internal val name: String,
        internal val startedAtMs: Long,
    )

    const val CURRENT_SESSION_ENTRY = "app-session-current.jsonl"
    const val PREVIOUS_SESSION_ENTRY = "app-session-previous.jsonl"
    const val EXIT_HISTORY_ENTRY = "android-exit-history.jsonl"
    const val LAST_ANR_ENTRY = "android-last-anr.txt"

    const val SESSION_CAP_BYTES = 512 * 1024
    const val EXIT_CAP_BYTES = 512 * 1024
    const val MAIN_THREAD_STALL_MS = 1_000L
    private const val TRIM_SLACK_BYTES = 64 * 1024
    private const val WATCHDOG_INTERVAL_MS = 500L
    private const val SMOOTH_FRAME_SUMMARY_INTERVAL_MS = 60_000L
    private const val FRAME_WINDOW_SIZE = 120
    private const val HITCH_MS = 50L
    private const val SEVERE_HITCH_MS = 150L
    private val sensitiveFieldFragments = setOf(
        "account_id",
        "account_scope",
        "address",
        "authorization",
        "biometric",
        "body",
        "challenge_id",
        "claim_id",
        "contact_id",
        "cookie",
        "credential",
        "delivery_id",
        "device_id",
        "dispatch_id",
        "email",
        "endpoint",
        "enrollment_id",
        "health_value",
        "incident_id",
        "installation_id",
        "invite",
        "journal",
        "latitude",
        "location",
        "longitude",
        "member_id",
        "message",
        "note",
        "object_key",
        "otp",
        "password",
        "path",
        "payload",
        "phone",
        "poke_id",
        "profile_id",
        "query",
        "request_id",
        "serial",
        "session_id",
        "secret",
        "signed_url",
        "source_id",
        "text",
        "token",
        "url",
        "user_id",
        "uuid",
    )

    private val startLock = Any()
    private val operationCounter = AtomicLong()
    private val ioExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "noop-app-diagnostics-io").apply { isDaemon = true }
    }
    private val watchdogExecutor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "noop-app-diagnostics-watchdog").apply { isDaemon = true }
    }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val watchdogLock = Any()

    @Volatile
    private var started = false
    private lateinit var appContext: Context
    private var watchdogFuture: ScheduledFuture<*>? = null
    private var pendingPingId = 0L
    private var pendingPingStartedAtMs = 0L
    private var stallWasLogged = false
    private var lastHeartbeatAtMs = 0L

    private val frameThread by lazy {
        HandlerThread("noop-app-diagnostics-frames").apply { start() }
    }
    private val frameHandler by lazy { Handler(frameThread.looper) }
    private var attachedWindow: Window? = null
    @Volatile
    private var currentScreen = "unknown"
    private var frameScreen = "unknown"
    private var frameCount = 0
    private var hitchCount = 0
    private var severeHitchCount = 0
    private var droppedFrameCallbacks = 0
    private var frameTotalMs = 0L
    private var worstFrameMs = 0L
    private var worstInputMs = 0L
    private var worstLayoutMs = 0L
    private var worstDrawMs = 0L
    private var worstSyncMs = 0L
    private var frameWindowStartedAtMs = 0L
    private var lastSmoothFrameSummaryAtMs = 0L

    private val frameListener = Window.OnFrameMetricsAvailableListener { _, metrics, dropped ->
        foldFrame(metrics, dropped)
    }

    fun start(context: Context) {
        synchronized(startLock) {
            if (started) return
            appContext = context.applicationContext
            runCatching {
                diagnosticsDirectory().mkdirs()
                previousSessionFile().delete()
                if (currentSessionFile().exists()) {
                    currentSessionFile().renameTo(previousSessionFile())
                }
                // Exit reasons are refreshed from Android on every process launch. Remove the prior snapshot
                // first so an OS-pruned ANR cannot be mistaken for evidence from the current failure window.
                exitHistoryFile().delete()
                lastAnrFile().delete()
                currentSessionFile().createNewFile()
            }
            started = true
        }
        record(
            "process.launch",
            fields = mapOf(
                "app_version" to BuildConfig.VERSION_NAME,
                "app_build" to BuildConfig.VERSION_CODE.toString(),
                "app_tier" to BuildConfig.TIER,
                "android_sdk" to Build.VERSION.SDK_INT.toString(),
            ),
            includeResourceSnapshot = true,
        )
        runCatching {
            ioExecutor.execute {
                runCatching { captureHistoricalExits() }
            }
        }
    }

    fun record(
        event: String,
        fields: Map<String, String> = emptyMap(),
        includeResourceSnapshot: Boolean = false,
    ) {
        if (!started) return
        val safeEvent = sanitizedToken(event)
        val safeFields = sanitizedFields(fields)
        val at = System.currentTimeMillis()
        val uptime = SystemClock.elapsedRealtime()
        runCatching {
            ioExecutor.execute {
                runCatching {
                    appendEvent(
                        event = safeEvent,
                        fields = safeFields,
                        includeResourceSnapshot = includeResourceSnapshot,
                        atMs = at,
                        uptimeMs = uptime,
                    )
                }
            }
        }
    }

    /** Best-effort synchronous edge for a process that is about to terminate from an uncaught exception. */
    fun recordCritical(
        event: String,
        fields: Map<String, String> = emptyMap(),
        includeResourceSnapshot: Boolean = true,
    ) {
        if (!started) return
        val task = runCatching {
            ioExecutor.submit {
                appendEvent(
                    event = sanitizedToken(event),
                    fields = sanitizedFields(fields),
                    includeResourceSnapshot = includeResourceSnapshot,
                    atMs = System.currentTimeMillis(),
                    uptimeMs = SystemClock.elapsedRealtime(),
                )
            }
        }.getOrNull() ?: return
        runCatching { task.get(350, TimeUnit.MILLISECONDS) }
    }

    fun beginOperation(
        name: String,
        fields: Map<String, String> = emptyMap(),
    ): OperationToken {
        val token = OperationToken(
            id = "op_${operationCounter.incrementAndGet()}",
            name = sanitizedToken(name),
            startedAtMs = SystemClock.elapsedRealtime(),
        )
        record(
            "operation.begin",
            fields + mapOf(
                "operation" to token.name,
                "operation_id" to token.id,
            ),
        )
        return token
    }

    fun endOperation(
        token: OperationToken,
        outcome: String = "completed",
        fields: Map<String, String> = emptyMap(),
        includeResourceSnapshot: Boolean = false,
    ) {
        record(
            "operation.end",
            fields + mapOf(
                "operation" to token.name,
                "operation_id" to token.id,
                "outcome" to sanitizedToken(outcome),
                "duration_ms" to max(
                    0L,
                    SystemClock.elapsedRealtime() - token.startedAtMs,
                ).toString(),
            ),
            includeResourceSnapshot,
        )
    }

    /**
     * Starts/stops the one-second main-thread watchdog. The scheduled callback exists only while the app
     * is foregrounded, so diagnostics add no periodic background wake-up.
     */
    fun setApplicationActive(active: Boolean) {
        if (!started) return
        synchronized(watchdogLock) {
            if (active) {
                if (watchdogFuture != null) return
                pendingPingStartedAtMs = 0
                stallWasLogged = false
                lastHeartbeatAtMs = 0
                watchdogFuture = watchdogExecutor.scheduleAtFixedRate(
                    ::watchdogTick,
                    WATCHDOG_INTERVAL_MS,
                    WATCHDOG_INTERVAL_MS,
                    TimeUnit.MILLISECONDS,
                )
            } else {
                watchdogFuture?.cancel(false)
                watchdogFuture = null
                pendingPingStartedAtMs = 0
                stallWasLogged = false
            }
        }
        record(
            if (active) "scene.active" else "scene.not_active",
            includeResourceSnapshot = active,
        )
    }

    /** Fixed navigation route only. Dynamic arguments are removed before this value reaches disk. */
    fun setScreen(route: String?) {
        val safe = sanitizedRoute(route)
        if (!started) return
        frameHandler.post {
            if (safe == currentScreen) return@post
            flushFrameWindow("screen_changed")
            currentScreen = safe
            frameScreen = safe
        }
        record("ui.screen_visible", mapOf("screen" to safe))
    }

    /** Register OS frame metrics while one Activity window is visible. Main-thread call only. */
    fun attachWindow(window: Window) {
        if (!started || attachedWindow === window) return
        detachWindow()
        attachedWindow = window
        frameHandler.post {
            resetFrameWindow()
            frameScreen = currentScreen
        }
        window.addOnFrameMetricsAvailableListener(frameListener, frameHandler)
    }

    /** Remove the listener and flush one bounded summary. Main-thread call only. */
    fun detachWindow() {
        val window = attachedWindow ?: return
        runCatching { window.removeOnFrameMetricsAvailableListener(frameListener) }
        attachedWindow = null
        frameHandler.post { flushFrameWindow("window_hidden") }
    }

    /**
     * Read a consistent snapshot after all previously queued breadcrumbs. Call this from a worker
     * dispatcher; it intentionally blocks only that worker while the serial file queue drains.
     */
    fun diagnosticEntries(): List<Pair<String, ByteArray>> {
        if (!started) return emptyList()
        val task: Future<List<Pair<String, ByteArray>>> = runCatching {
            ioExecutor.submit<List<Pair<String, ByteArray>>> {
                listOf(
                    CURRENT_SESSION_ENTRY to currentSessionFile(),
                    PREVIOUS_SESSION_ENTRY to previousSessionFile(),
                    EXIT_HISTORY_ENTRY to exitHistoryFile(),
                    LAST_ANR_ENTRY to lastAnrFile(),
                ).mapNotNull { (name, file) ->
                    file.takeIf { it.isFile && it.length() > 0L }?.readBytes()?.let { name to it }
                }
            }
        }.getOrNull() ?: return emptyList()
        return runCatching { task.get(2, TimeUnit.SECONDS) }.getOrDefault(emptyList())
    }

    private fun appendEvent(
        event: String,
        fields: Map<String, String>,
        includeResourceSnapshot: Boolean,
        atMs: Long,
        uptimeMs: Long,
    ) {
        val json = JSONObject()
            .put("schema", 1)
            .put("at", Instant.ofEpochMilli(atMs).toString())
            .put("uptime_ms", uptimeMs)
            .put("event", event)
        if (fields.isNotEmpty()) json.put("fields", JSONObject(fields))
        if (includeResourceSnapshot) json.put("resources", JSONObject(resourceSnapshot()))
        appendBoundedLine(currentSessionFile(), json.toString(), SESSION_CAP_BYTES)
    }

    private fun appendBoundedLine(file: File, line: String, capBytes: Int) {
        file.parentFile?.mkdirs()
        FileOutputStream(file, true).use { output ->
            output.write(line.toByteArray(Charsets.UTF_8))
            output.write('\n'.code)
        }
        if (file.length() <= capBytes + TRIM_SLACK_BYTES) return
        val bounded = boundedJSONLTail(file.readBytes(), capBytes)
        file.writeBytes(bounded)
    }

    fun boundedJSONLTail(data: ByteArray, maxBytes: Int): ByteArray {
        if (maxBytes <= 0) return byteArrayOf()
        if (data.size <= maxBytes) return data
        val marker =
            "{\"schema\":1,\"event\":\"log.trimmed\",\"fields\":{\"reason\":\"older records removed\"}}\n"
                .toByteArray()
        if (maxBytes <= marker.size) return marker.copyOf(maxBytes)
        val suffixBudget = maxBytes - marker.size
        val suffixStart = max(0, data.size - suffixBudget)
        var firstNewline = suffixStart
        while (firstNewline < data.size && data[firstNewline] != '\n'.code.toByte()) {
            firstNewline++
        }
        val tailStart = minOf(data.size, firstNewline + 1)
        return (marker + data.copyOfRange(tailStart, data.size)).copyOf(maxBytes)
    }

    private fun resourceSnapshot(): Map<String, Any> = buildMap {
        val memory = Debug.MemoryInfo()
        Debug.getMemoryInfo(memory)
        put("memory_pss_mb", memory.totalPss / 1_024)
        val runtime = Runtime.getRuntime()
        put("java_heap_bytes", runtime.totalMemory() - runtime.freeMemory())
        put("native_heap_bytes", Debug.getNativeHeapAllocatedSize())
        put("database_bytes", databaseFootprintBytes())
        put("disk_available_bytes", runCatching {
            StatFs(appContext.cacheDir.path).availableBytes
        }.getOrDefault(-1L))
        val power = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        put("low_power_mode", power?.isPowerSaveMode ?: false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            put("thermal_status", thermalStatusName(power?.currentThermalStatus))
        }
        put("memory_class_bytes", activityMemoryBytes())
    }

    private fun databaseFootprintBytes(): Long {
        val path = appContext.getDatabasePath(com.noop.data.WhoopDatabase.DB_NAME).path
        return listOf("", "-wal", "-shm").sumOf { suffix ->
            File(path + suffix).takeIf(File::isFile)?.length() ?: 0L
        }
    }

    private fun activityMemoryBytes(): Long {
        val manager = appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        return manager?.memoryClass?.toLong()?.times(1_024L * 1_024L) ?: -1L
    }

    private fun watchdogTick() {
        val now = SystemClock.elapsedRealtime()
        var pingToPost: Long? = null
        var stallMs: Long? = null
        var heartbeat = false
        synchronized(watchdogLock) {
            if (watchdogFuture == null) return
            if (lastHeartbeatAtMs == 0L || now - lastHeartbeatAtMs >= 60_000L) {
                lastHeartbeatAtMs = now
                heartbeat = true
            }
            if (pendingPingStartedAtMs > 0L) {
                val delay = now - pendingPingStartedAtMs
                if (delay >= MAIN_THREAD_STALL_MS && !stallWasLogged) {
                    stallWasLogged = true
                    stallMs = delay
                }
            } else {
                pendingPingId += 1
                pendingPingStartedAtMs = now
                pingToPost = pendingPingId
            }
        }
        if (heartbeat) record("process.heartbeat", includeResourceSnapshot = true)
        stallMs?.let {
            record(
                "main_thread.stall_detected",
                mapOf("blocked_ms" to it.toString(), "screen" to currentScreen),
                includeResourceSnapshot = true,
            )
        }
        pingToPost?.let { id -> mainHandler.post { acknowledgeMainThreadPing(id) } }
    }

    private fun acknowledgeMainThreadPing(id: Long) {
        val now = SystemClock.elapsedRealtime()
        var recoveredMs: Long? = null
        synchronized(watchdogLock) {
            if (id != pendingPingId || pendingPingStartedAtMs == 0L) return
            if (stallWasLogged) recoveredMs = max(0L, now - pendingPingStartedAtMs)
            pendingPingStartedAtMs = 0
            stallWasLogged = false
        }
        recoveredMs?.let {
            record(
                "main_thread.stall_recovered",
                mapOf("blocked_ms" to it.toString(), "screen" to currentScreen),
                includeResourceSnapshot = true,
            )
        }
    }

    private fun foldFrame(metrics: FrameMetrics, dropped: Int) {
        val total = metricMs(metrics, FrameMetrics.TOTAL_DURATION)
        if (total <= 0L || total >= 5_000L) return
        if (frameCount == 0) {
            frameWindowStartedAtMs = SystemClock.elapsedRealtime()
            frameScreen = currentScreen
        }
        frameCount++
        frameTotalMs += total
        if (total >= HITCH_MS) hitchCount++
        if (total >= SEVERE_HITCH_MS) severeHitchCount++
        droppedFrameCallbacks += max(0, dropped)
        worstFrameMs = max(worstFrameMs, total)
        worstInputMs = max(worstInputMs, metricMs(metrics, FrameMetrics.INPUT_HANDLING_DURATION))
        worstLayoutMs = max(worstLayoutMs, metricMs(metrics, FrameMetrics.LAYOUT_MEASURE_DURATION))
        worstDrawMs = max(worstDrawMs, metricMs(metrics, FrameMetrics.DRAW_DURATION))
        worstSyncMs = max(worstSyncMs, metricMs(metrics, FrameMetrics.SYNC_DURATION))
        if (frameCount >= FRAME_WINDOW_SIZE) flushFrameWindow("window_complete")
    }

    private fun flushFrameWindow(reason: String) {
        if (frameCount <= 0) {
            resetFrameWindow()
            return
        }
        val now = SystemClock.elapsedRealtime()
        val smoothSummaryDue =
            now - lastSmoothFrameSummaryAtMs >= SMOOTH_FRAME_SUMMARY_INTERVAL_MS
        if (hitchCount > 0 || smoothSummaryDue) {
            if (hitchCount == 0) lastSmoothFrameSummaryAtMs = now
            record(
                "ui.frame.summary",
                fields = mapOf(
                    "screen" to frameScreen,
                    "reason" to reason,
                    "frames" to frameCount.toString(),
                    "mean_frame_ms" to (frameTotalMs / frameCount).toString(),
                    "hitches_50ms" to hitchCount.toString(),
                    "severe_hitches_150ms" to severeHitchCount.toString(),
                    "worst_frame_ms" to worstFrameMs.toString(),
                    "worst_input_ms" to worstInputMs.toString(),
                    "worst_layout_ms" to worstLayoutMs.toString(),
                    "worst_draw_ms" to worstDrawMs.toString(),
                    "worst_sync_ms" to worstSyncMs.toString(),
                    "dropped_callbacks" to droppedFrameCallbacks.toString(),
                    "duration_ms" to max(0L, now - frameWindowStartedAtMs).toString(),
                ),
                includeResourceSnapshot = severeHitchCount > 0,
            )
        }
        resetFrameWindow()
    }

    private fun resetFrameWindow() {
        frameCount = 0
        hitchCount = 0
        severeHitchCount = 0
        droppedFrameCallbacks = 0
        frameTotalMs = 0
        worstFrameMs = 0
        worstInputMs = 0
        worstLayoutMs = 0
        worstDrawMs = 0
        worstSyncMs = 0
        frameWindowStartedAtMs = 0
        frameScreen = currentScreen
    }

    private fun metricMs(metrics: FrameMetrics, id: Int): Long =
        max(0L, metrics.getMetric(id) / 1_000_000L)

    private fun captureHistoricalExits() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val manager = appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val exits = runCatching {
            manager.getHistoricalProcessExitReasons(appContext.packageName, 0, 5)
        }.getOrDefault(emptyList())
        if (exits.isEmpty()) return

        val lines = exits.joinToString(separator = "\n", postfix = "\n") { exit ->
            JSONObject()
                .put("schema", 1)
                .put("at", Instant.ofEpochMilli(exit.timestamp).toString())
                .put("event", "process.historical_exit")
                .put(
                    "fields",
                    JSONObject(
                        mapOf(
                            "reason" to exitReasonName(exit.reason),
                            "status" to exit.status.toString(),
                            "importance" to exit.importance.toString(),
                            "pss_kb" to exit.pss.toString(),
                            "rss_kb" to exit.rss.toString(),
                        ),
                    ),
                )
                .toString()
        }
        exitHistoryFile().writeBytes(
            boundedJSONLTail(lines.toByteArray(), EXIT_CAP_BYTES),
        )

        val anr = exits.firstOrNull { it.reason == ApplicationExitInfo.REASON_ANR } ?: return
        runCatching {
            anr.traceInputStream?.use { stream ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1_024)
                while (out.size() < EXIT_CAP_BYTES) {
                    val read = stream.read(
                        buffer,
                        0,
                        minOf(buffer.size, EXIT_CAP_BYTES - out.size()),
                    )
                    if (read <= 0) break
                    out.write(buffer, 0, read)
                }
                val header = buildString {
                    appendLine("Android OS ANR trace")
                    appendLine("captured_at: ${Instant.ofEpochMilli(anr.timestamp)}")
                    appendLine("reason: ${exitReasonName(anr.reason)}")
                    appendLine()
                }.toByteArray()
                lastAnrFile().writeBytes((header + out.toByteArray()).take(EXIT_CAP_BYTES).toByteArray())
            }
        }
    }

    private fun diagnosticsDirectory(): File =
        File(appContext.cacheDir, "NOOP/AppDiagnostics")

    private fun currentSessionFile() = File(diagnosticsDirectory(), "current-session.jsonl")
    private fun previousSessionFile() = File(diagnosticsDirectory(), "previous-session.jsonl")
    private fun exitHistoryFile() = File(diagnosticsDirectory(), "exit-history.jsonl")
    private fun lastAnrFile() = File(diagnosticsDirectory(), "last-anr.txt")

    internal fun sanitizedFields(fields: Map<String, String>): Map<String, String> = buildMap {
        var redacted = 0
        fields.entries.take(24).forEach { (key, value) ->
            val safeKey = sanitizedToken(key)
            if (sensitiveFieldFragments.any { safeKey.contains(it, ignoreCase = true) }) {
                redacted += 1
            } else {
                put(safeKey, sanitizedFieldValue(value))
            }
        }
        if (redacted > 0) put("redacted_fields", redacted.toString())
    }

    private fun sanitizedToken(value: String): String {
        val token = value.take(96).map { character ->
            if (character.isLetterOrDigit() || character in "._-") character else '_'
        }.joinToString("")
        return token.ifBlank { "unknown" }
    }

    private fun sanitizedFieldValue(value: String): String =
        value.take(512).map { character ->
            if (character.isLetterOrDigit() || character in "._-/:{}+") {
                character
            } else {
                '_'
            }
        }.joinToString("")

    internal fun sanitizedRoute(route: String?): String {
        val staticRoute = route
            ?.substringBefore('/')
            ?.substringBefore('?')
            ?.substringBefore('#')
            ?.trim()
            .orEmpty()
        return sanitizedToken(staticRoute)
    }

    internal fun freshnessBucket(ageSeconds: Long?): String = when {
        ageSeconds == null -> "missing"
        ageSeconds < -60L -> "future_clock"
        ageSeconds < 120L -> "under_2m"
        ageSeconds < 15L * 60L -> "2m_to_15m"
        ageSeconds < 2L * 60L * 60L -> "15m_to_2h"
        else -> "over_2h"
    }

    private fun thermalStatusName(status: Int?): String = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> "none"
        PowerManager.THERMAL_STATUS_LIGHT -> "light"
        PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
        PowerManager.THERMAL_STATUS_SEVERE -> "severe"
        PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
        PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
        PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
        else -> "unknown"
    }

    private fun exitReasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
        else -> "other_$reason"
    }
}
