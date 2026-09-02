package com.noop.ui

import java.io.IOException
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthExerciseMediaPolicyTest {
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

    private fun gifHeader(width: Int, height: Int): ByteArray =
        "GIF89a".encodeToByteArray() + byteArrayOf(
            width.and(0xff).toByte(),
            width.shr(8).and(0xff).toByte(),
            height.and(0xff).toByte(),
            height.shr(8).and(0xff).toByte(),
        )
}
