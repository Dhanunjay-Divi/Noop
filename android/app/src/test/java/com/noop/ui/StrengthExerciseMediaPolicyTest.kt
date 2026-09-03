package com.noop.ui

import java.io.IOException
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthExerciseMediaPolicyTest {
    @Test
    fun mediaTemplatesAreExtensionAwareAndHttpsOnly() {
        assertEquals(
            "https://cdn.example.com/0054.mp4",
            StrengthExerciseMediaPolicy.mediaUrl(
                template = "https://cdn.example.com/{id}.{ext}",
                mediaId = "0054",
                extension = "mp4",
            ),
        )
        assertEquals(
            "https://cdn.example.com/media/0043.gif",
            StrengthExerciseMediaPolicy.mediaUrl(
                template = "https://cdn.example.com/media",
                mediaId = "0043",
                extension = "gif",
            ),
        )
        assertEquals(
            null,
            StrengthExerciseMediaPolicy.mediaUrl(
                template = "http://cdn.example.com/{id}.gif",
                mediaId = "0043",
                extension = "gif",
            ),
        )
    }

    @Test
    fun licensedGifMustMeetBothNativeDimensions() {
        assertTrue(
            StrengthExerciseMediaPolicy.acceptsGifHeader(
                gifHeader(width = 360, height = 360),
                STRENGTH_MINIMUM_LICENSED_PIXELS,
            ),
        )
        assertFalse(
            StrengthExerciseMediaPolicy.acceptsGifHeader(
                gifHeader(width = 359, height = 720),
                STRENGTH_MINIMUM_LICENSED_PIXELS,
            ),
        )
        assertFalse(
            StrengthExerciseMediaPolicy.acceptsGifHeader(
                gifHeader(width = 720, height = 359),
                STRENGTH_MINIMUM_LICENSED_PIXELS,
            ),
        )
        assertFalse(
            StrengthExerciseMediaPolicy.acceptsGifHeader(
                "not-a-gif!".encodeToByteArray(),
                STRENGTH_MINIMUM_LICENSED_PIXELS,
            ),
        )
    }

    @Test
    fun downloadPolicyAllowsUnknownOrBoundedLengthOnly() {
        assertTrue(StrengthExerciseMediaPolicy.acceptsContentLength(-1))
        assertTrue(
            StrengthExerciseMediaPolicy.acceptsContentLength(
                STRENGTH_MAXIMUM_DOWNLOAD_BYTES,
            ),
        )
        assertFalse(
            StrengthExerciseMediaPolicy.acceptsContentLength(
                STRENGTH_MAXIMUM_DOWNLOAD_BYTES + 1,
            ),
        )
    }

    @Test
    fun boundedBodyStopsAnUnknownLengthStreamPastItsLimit() {
        val accepted = StrengthCappedResponseBody(
            byteArrayOf(1, 2, 3, 4).toResponseBody(),
            maximumBytes = 4,
        )
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), accepted.source().readByteArray())

        val rejected = StrengthCappedResponseBody(
            byteArrayOf(1, 2, 3, 4, 5).toResponseBody(),
            maximumBytes = 4,
        )
        assertThrows(IOException::class.java) {
            rejected.source().readByteArray()
        }
    }

    @Test
    fun playbackDelayNormalizationSlowsMotionAndCapsLongGifHolds() {
        val source = gifWithDelays(100, 10, 40)
        val normalized = StrengthExerciseMediaPolicy.normalizePlaybackDelays(source)

        assertNotSame(source, normalized)
        assertEquals(40, gifDelay(normalized, frame = 0))
        assertEquals(13, gifDelay(normalized, frame = 1))
        assertEquals(40, gifDelay(normalized, frame = 2))
        assertEquals(100, gifDelay(source, frame = 0))
    }

    @Test
    fun playbackDelayNormalizationSlowsSmoothDataAndLeavesMalformedDataUntouched() {
        val smooth = gifWithDelays(10, 20)
        val normalized = StrengthExerciseMediaPolicy.normalizePlaybackDelays(smooth)
        assertEquals(13, gifDelay(normalized, frame = 0))
        assertEquals(25, gifDelay(normalized, frame = 1))
        val malformed = "GIF89a-not-a-complete-gif".encodeToByteArray()
        assertTrue(
            malformed === StrengthExerciseMediaPolicy.normalizePlaybackDelays(malformed),
        )
    }

    private fun gifHeader(width: Int, height: Int): ByteArray =
        "GIF89a".encodeToByteArray() + byteArrayOf(
            width.and(0xff).toByte(),
            width.shr(8).and(0xff).toByte(),
            height.and(0xff).toByte(),
            height.shr(8).and(0xff).toByte(),
        )

    private fun gifWithDelays(vararg delays: Int): ByteArray {
        var data = "GIF89a".encodeToByteArray() + byteArrayOf(
            1, 0,
            1, 0,
            0, 0, 0,
        )
        delays.forEach { delay ->
            data += byteArrayOf(
                0x21,
                0xf9.toByte(),
                4,
                0,
                delay.and(0xff).toByte(),
                delay.shr(8).and(0xff).toByte(),
                0,
                0,
            )
        }
        return data + byteArrayOf(0x3b)
    }

    private fun gifDelay(data: ByteArray, frame: Int): Int {
        val offset = 13 + (frame * 8) + 4
        return data[offset].toInt().and(0xff) or
            (data[offset + 1].toInt().and(0xff) shl 8)
    }
}
