package com.noop.feedback

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FeedbackScreenshotSanitizerTest {
    @Test
    fun metadataBearingPngIsStrippedBeforeReview() {
        assertArrayEquals(
            FeedbackScreenshotFixture.sanitized,
            FeedbackScreenshotSanitizer.sanitize(
                FeedbackScreenshotFixture.rawMetadataBearing,
            ),
        )
        assertArrayEquals(
            FeedbackScreenshotFixture.sanitized,
            FeedbackScreenshotSanitizer.sanitize(
                FeedbackScreenshotFixture.sanitized,
            ),
        )
    }

    @Test
    fun malformedAndUnknownCriticalChunksFailClosed() {
        val badChecksum = FeedbackScreenshotFixture.sanitized.copyOf()
        badChecksum[20] = (badChecksum[20].toInt() xor 0xFF).toByte()
        assertNull(FeedbackScreenshotSanitizer.sanitize(badChecksum))

        val unknownCritical = FeedbackScreenshotFixture.sanitized.copyOf()
        "ABCD".toByteArray().copyInto(unknownCritical, destinationOffset = 12)
        assertNull(FeedbackScreenshotSanitizer.sanitize(unknownCritical))
        assertNull(
            FeedbackScreenshotSanitizer.sanitize(
                FeedbackScreenshotFixture.sanitized.copyOf(
                    FeedbackScreenshotFixture.sanitized.size - 1,
                ),
            ),
        )
    }
}
