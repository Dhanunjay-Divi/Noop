package com.noop

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashCaptureTest {
    @Test fun privacySafeTraceKeepsCodeFramesWithoutExceptionMessages() {
        val cause = IllegalArgumentException("private token and heart rate 137")
        cause.stackTrace = arrayOf(
            StackTraceElement("com.noop.data.Repository", "refresh", "Repository.kt", 42),
        )
        val error = IllegalStateException("private journal text", cause)
        error.stackTrace = arrayOf(
            StackTraceElement("com.noop.ui.AppRoot", "render", "AppRoot.kt", 91),
        )

        val trace = CrashCapture.privacySafeTrace(
            threadName = "private-user-thread-name",
            throwable = error,
            capturedAtMillis = 1_788_000_000_000,
        )

        assertTrue(trace.startsWith("schema: noop.android.crash.v2"))
        assertTrue(trace.contains("thread_kind: background"))
        assertTrue(trace.contains("java.lang.IllegalStateException"))
        assertTrue(trace.contains("com.noop.ui.AppRoot.render:91"))
        assertTrue(trace.contains("java.lang.IllegalArgumentException"))
        assertTrue(trace.contains("com.noop.data.Repository.refresh:42"))
        assertFalse(trace.contains("private journal text"))
        assertFalse(trace.contains("private token"))
        assertFalse(trace.contains("heart rate 137"))
        assertFalse(trace.contains("private-user-thread-name"))
    }
}
