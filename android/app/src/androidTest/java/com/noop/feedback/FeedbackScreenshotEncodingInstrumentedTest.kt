package com.noop.feedback

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeedbackScreenshotEncodingInstrumentedTest {
    @Test
    fun bitmapEncoderOutputSanitizesToServerChunkContract() {
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.rgb(14, 32, 24))
            setPixel(1, 1, Color.rgb(44, 228, 132))
        }
        val encoded = ByteArrayOutputStream().use { output ->
            assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            output.toByteArray()
        }
        bitmap.recycle()

        val sanitized = requireNotNull(
            FeedbackScreenshotSanitizer.sanitize(encoded),
        )
        assertArrayEquals(
            sanitized,
            FeedbackScreenshotSanitizer.sanitize(sanitized),
        )

        val types = chunkTypes(sanitized)
        assertEquals("IHDR", types.first())
        assertEquals("IEND", types.last())
        assertTrue("IDAT" in types)
        assertTrue(
            types.all {
                it in setOf(
                    "IHDR",
                    "PLTE",
                    "tRNS",
                    "gAMA",
                    "cHRM",
                    "sRGB",
                    "pHYs",
                    "IDAT",
                    "IEND",
                )
            },
        )
    }

    private fun chunkTypes(png: ByteArray): List<String> {
        val types = mutableListOf<String>()
        var offset = 8
        while (offset < png.size) {
            val length = readUInt32(png, offset)
            val typeOffset = offset + 4
            types += String(
                png,
                typeOffset,
                4,
                Charsets.US_ASCII,
            )
            offset += 12 + length
        }
        return types
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)
}
