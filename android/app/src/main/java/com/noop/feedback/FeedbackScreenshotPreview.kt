package com.noop.feedback

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

internal class FeedbackScreenshotCaptureGuard {
    private var generation = 0L
    private var optedIn = false

    @Synchronized
    fun updateOptIn(enabled: Boolean): Long? {
        generation += 1L
        optedIn = enabled
        return generation.takeIf { enabled }
    }

    @Synchronized
    fun invalidate() {
        generation += 1L
        optedIn = false
    }

    @Synchronized
    fun accepts(token: Long, isPresented: Boolean): Boolean =
        isPresented && optedIn && token == generation
}

internal data class FeedbackScreenshotSize(
    val width: Int,
    val height: Int,
)

internal object FeedbackScreenshotPreview {
    private const val MAX_SOURCE_EDGE = 16_384
    private const val MAX_SOURCE_PIXELS = 64L * 1024L * 1024L
    private const val TARGET_EDGE = 1_280
    private const val TARGET_PIXELS = 2L * 1024L * 1024L
    private const val TARGET_CAPTURE_EDGE = 1_440
    private const val TARGET_CAPTURE_PIXELS = 2L * 1024L * 1024L
    private const val MAX_ENCODED_BYTES = 8 * 1024 * 1024
    private val pngSignature = byteArrayOf(
        0x89.toByte(),
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
    )

    fun decode(bytes: ByteArray): Bitmap? {
        if (bytes.size !in pngSignature.size..MAX_ENCODED_BYTES ||
            !bytes.copyOfRange(0, pngSignature.size).contentEquals(pngSignature)
        ) {
            return null
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val sampleSize = sampleSize(bounds.outWidth, bounds.outHeight) ?: return null
        return runCatching {
            BitmapFactory.decodeByteArray(
                bytes,
                0,
                bytes.size,
                BitmapFactory.Options().apply {
                    inSampleSize = sampleSize
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            )
        }.getOrNull()
    }

    fun captureSize(width: Int, height: Int): FeedbackScreenshotSize? {
        if (width <= 0 || height <= 0 ||
            width > MAX_SOURCE_EDGE || height > MAX_SOURCE_EDGE ||
            width.toLong() * height.toLong() > MAX_SOURCE_PIXELS
        ) {
            return null
        }
        val edgeScale = min(
            1.0,
            TARGET_CAPTURE_EDGE.toDouble() / maxOf(width, height).toDouble(),
        )
        val pixelScale = min(
            1.0,
            sqrt(TARGET_CAPTURE_PIXELS.toDouble() / (width.toLong() * height.toLong()).toDouble()),
        )
        val scale = min(edgeScale, pixelScale)
        return FeedbackScreenshotSize(
            width = maxOf(1, (width * scale).roundToInt()),
            height = maxOf(1, (height * scale).roundToInt()),
        )
    }

    internal fun sampleSize(width: Int, height: Int): Int? {
        if (width <= 0 || height <= 0 ||
            width > MAX_SOURCE_EDGE || height > MAX_SOURCE_EDGE ||
            width.toLong() * height.toLong() > MAX_SOURCE_PIXELS
        ) {
            return null
        }
        var sample = 1
        while (
            width / sample > TARGET_EDGE ||
            height / sample > TARGET_EDGE ||
            (width.toLong() * height.toLong()) / (sample.toLong() * sample) > TARGET_PIXELS
        ) {
            sample *= 2
        }
        return sample
    }
}
