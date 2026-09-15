package com.noop.feedback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FeedbackScreenshotPreviewTest {
    @Test
    fun sampleSizeKeepsOrdinaryScreensBounded() {
        assertEquals(4, FeedbackScreenshotPreview.sampleSize(1_440, 3_120))
        assertEquals(2, FeedbackScreenshotPreview.sampleSize(1_080, 1_920))
        assertEquals(1, FeedbackScreenshotPreview.sampleSize(1_000, 1_200))
    }

    @Test
    fun sampleSizeRejectsInvalidOrDecompressionBombDimensions() {
        assertNull(FeedbackScreenshotPreview.sampleSize(0, 1_000))
        assertNull(FeedbackScreenshotPreview.sampleSize(20_000, 100))
        assertNull(FeedbackScreenshotPreview.sampleSize(10_000, 10_000))
    }

    @Test
    fun captureSizeBoundsTheMainThreadBitmapWithoutChangingAspectRatio() {
        assertEquals(
            FeedbackScreenshotSize(665, 1_440),
            FeedbackScreenshotPreview.captureSize(1_440, 3_120),
        )
        assertEquals(
            FeedbackScreenshotSize(1_000, 1_200),
            FeedbackScreenshotPreview.captureSize(1_000, 1_200),
        )
        val tablet = FeedbackScreenshotPreview.captureSize(2_560, 1_600)
        assertTrue(tablet != null)
        assertTrue(tablet!!.width <= 1_440)
        assertTrue(tablet.width.toLong() * tablet.height.toLong() <= 2L * 1024L * 1024L)
        assertNull(FeedbackScreenshotPreview.captureSize(20_000, 100))
    }

    @Test
    fun captureGuardIssuesTokensOnlyForExplicitOptInAndRejectsOptOut() {
        val guard = FeedbackScreenshotCaptureGuard()
        assertNull(guard.updateOptIn(false))

        val first = requireNotNull(guard.updateOptIn(true))
        assertTrue(guard.accepts(first, isPresented = true))

        assertNull(guard.updateOptIn(false))
        assertFalse(guard.accepts(first, isPresented = true))
    }

    @Test
    fun captureGuardRejectsResultsFromClosedOrReplacedReportSessions() {
        val guard = FeedbackScreenshotCaptureGuard()
        val first = requireNotNull(guard.updateOptIn(true))
        assertTrue(guard.accepts(first, isPresented = true))
        assertFalse(guard.accepts(first, isPresented = false))

        guard.invalidate()
        assertFalse(guard.accepts(first, isPresented = true))

        val second = requireNotNull(guard.updateOptIn(true))
        assertFalse(guard.accepts(first, isPresented = true))
        assertTrue(guard.accepts(second, isPresented = true))
    }
}
