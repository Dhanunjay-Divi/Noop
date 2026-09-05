package com.noop

import android.content.Context
import java.io.File
import java.time.Instant
import java.util.Collections
import java.util.IdentityHashMap

/**
 * Captures the last uncaught exception to a file so a crash that only reproduces on a user's own
 * device — a deterministic crash on a specific data shape, like the Insights tab (#224/#267) — lands
 * in the shareable strap log instead of being lost to a logcat no one can reach without adb. The
 * handler records the trace, then chains to the previous handler so the process still dies normally
 * (we never swallow the crash). [LogExport] appends [lastCrash] to the strap log header.
 */
object CrashCapture {
    private const val FILE = "last_crash.txt"
    private const val SCHEMA_HEADER = "schema: noop.android.crash.v2"

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // The handler itself must never throw, or we replace one crash with another.
            runCatching {
                AppDiagnosticsRecorder.recordCritical(
                    "process.uncaught_exception",
                    fields = mapOf(
                        "thread_kind" to if (thread.name == "main") "main" else "background",
                        "failure_kind" to throwable.javaClass.simpleName,
                    ),
                )
                runCatching {
                    File(appContext.filesDir, FILE).writeText(
                        privacySafeTrace(thread.name, throwable),
                    )
                }
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    /** The captured crash text, or null if there hasn't been one. Surfaced by [LogExport]. */
    fun lastCrash(context: Context): String? {
        val f = File(context.applicationContext.filesDir, FILE)
        if (!f.exists()) return null
        val text = runCatching { f.readText() }.getOrNull()?.ifBlank { null } ?: return null
        if (!text.startsWith(SCHEMA_HEADER)) {
            // Older builds stored Throwable.printStackTrace(), including arbitrary exception messages.
            // Never attach that legacy file to a new privacy-safe report.
            runCatching { f.delete() }
            return null
        }
        return text
    }

    internal fun privacySafeTrace(
        threadName: String,
        throwable: Throwable,
        capturedAtMillis: Long = System.currentTimeMillis(),
    ): String {
        val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        val text = buildString {
            appendLine(SCHEMA_HEADER)
            appendLine("captured_at: ${Instant.ofEpochMilli(capturedAtMillis)}")
            appendLine("thread_kind: ${if (threadName == "main") "main" else "background"}")
            var current: Throwable? = throwable
            var causeIndex = 0
            var frameCount = 0
            while (current != null && causeIndex < MAX_CAUSES && seen.add(current)) {
                appendLine("exception_$causeIndex: ${safeCodeToken(current.javaClass.name)}")
                for (frame in current.stackTrace) {
                    if (frameCount >= MAX_FRAMES) break
                    append("frame_")
                    append(frameCount)
                    append(": ")
                    append(safeCodeToken(frame.className))
                    append(".")
                    append(safeCodeToken(frame.methodName))
                    append(":")
                    appendLine(frame.lineNumber.coerceAtLeast(0))
                    frameCount += 1
                }
                current = current.cause
                causeIndex += 1
            }
            appendLine("frame_count: $frameCount")
            appendLine("cause_count: $causeIndex")
        }
        return text.take(MAX_BYTES)
    }

    private fun safeCodeToken(value: String): String =
        value.take(240).map { character ->
            if (character.isLetterOrDigit() || character in "._\$") character else '_'
        }.joinToString("").ifBlank { "unknown" }

    private const val MAX_CAUSES = 8
    private const val MAX_FRAMES = 256
    private const val MAX_BYTES = 64 * 1024
}
