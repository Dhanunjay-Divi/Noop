package com.noop.feedback

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32

/**
 * Removes metadata-bearing PNG chunks before an explicitly approved screenshot reaches feedback
 * review. The server independently decodes and validates the resulting PNG.
 */
internal object FeedbackScreenshotSanitizer {
    const val MAXIMUM_BYTES = 8 * 1024 * 1024

    private val signature =
        byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    private val preservedChunkTypes = setOf(
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
    private val singletonChunkTypes = setOf(
        "IHDR",
        "PLTE",
        "tRNS",
        "gAMA",
        "cHRM",
        "sRGB",
        "pHYs",
        "IEND",
    )
    private val preImageChunkTypes = setOf(
        "PLTE",
        "tRNS",
        "gAMA",
        "cHRM",
        "sRGB",
        "pHYs",
    )

    fun sanitize(
        png: ByteArray,
        maximumBytes: Int = MAXIMUM_BYTES,
    ): ByteArray? {
        if (maximumBytes < signature.size ||
            png.size < signature.size ||
            png.size > maximumBytes ||
            signature.indices.any { png[it] != signature[it] }
        ) {
            return null
        }

        val output = ByteArrayOutputStream(png.size)
        output.write(signature)
        var offset = signature.size
        var sawHeader = false
        var sawImageData = false
        var sawEnd = false
        val seenSingletons = linkedSetOf<String>()

        while (offset < png.size) {
            if (sawEnd || png.size - offset < 12) return null
            val chunkLengthValue = readUInt32(png, offset)
            if (chunkLengthValue > maximumBytes.toLong()) return null
            val chunkLength = chunkLengthValue.toInt()
            if (chunkLength > png.size - offset - 12) return null

            val typeOffset = offset + 4
            val dataOffset = typeOffset + 4
            val checksumOffset = dataOffset + chunkLength
            val chunkEnd = checksumOffset + 4
            val typeBytes = png.copyOfRange(typeOffset, typeOffset + 4)
            if (typeBytes.any { !it.isAsciiAlpha() } ||
                typeBytes[2].toInt() and 0x20 != 0
            ) {
                return null
            }
            val chunkType = String(typeBytes, Charsets.US_ASCII)
            val checksum = CRC32().apply {
                update(png, typeOffset, checksumOffset - typeOffset)
            }.value
            if (checksum != readUInt32(png, checksumOffset)) return null

            when (chunkType) {
                "IHDR" -> {
                    if (offset != signature.size || chunkLength != 13 || sawHeader) {
                        return null
                    }
                    sawHeader = true
                }
                "IDAT" -> {
                    if (!sawHeader) return null
                    sawImageData = true
                }
                "IEND" -> {
                    if (!sawHeader ||
                        !sawImageData ||
                        chunkLength != 0 ||
                        chunkEnd != png.size
                    ) {
                        return null
                    }
                    sawEnd = true
                }
                in preImageChunkTypes -> {
                    if (!sawHeader || sawImageData) return null
                }
                else -> {
                    if (!sawHeader) return null
                    val isAncillary = typeBytes[0].toInt() and 0x20 != 0
                    if (!isAncillary) return null
                }
            }

            if (chunkType in preservedChunkTypes) {
                if (chunkType in singletonChunkTypes &&
                    !seenSingletons.add(chunkType)
                ) {
                    return null
                }
                output.write(png, offset, chunkEnd - offset)
                if (output.size() > maximumBytes) return null
            }
            offset = chunkEnd
        }

        if (!sawHeader || !sawImageData || !sawEnd || offset != png.size) {
            return null
        }
        return output.toByteArray()
    }

    private fun Byte.isAsciiAlpha(): Boolean {
        val value = toInt() and 0xFF
        return value in 0x41..0x5A || value in 0x61..0x7A
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)
}
