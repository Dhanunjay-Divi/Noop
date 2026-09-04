package com.noop.managed

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedChunkCodecTest {
    @Test
    fun gzipRoundTripIsDeterministicAndBounded() {
        val input = ByteArray(20_000) { index ->
            ((index * 31) xor (index shr 3)).toByte()
        }

        val first = ManagedChunkCodec.encode(input, ManagedChunkCompression.GZIP)
        val second = ManagedChunkCodec.encode(input, ManagedChunkCompression.GZIP)

        assertArrayEquals(first, second)
        assertEquals(
            listOf(0x1f, 0x8b, 0x08, 0x00),
            first.take(4).map { it.toInt() and 0xff },
        )
        assertTrue(first.size < input.size)
        assertArrayEquals(
            input,
            ManagedChunkCodec.decode(first, "gzip", input.size),
        )
    }

    @Test
    fun gzipRejectsCorruptTrailerExpansionAndUnexpectedSize() {
        val input = "managed health payload".toByteArray()
        val corrupt = ManagedChunkCodec.encode(input, ManagedChunkCompression.GZIP).also {
            it[it.lastIndex - 7] = (it[it.lastIndex - 7].toInt() xor 0xff).toByte()
        }

        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            ManagedChunkCodec.decode(corrupt, "gzip", input.size)
        }
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            ManagedChunkCodec.decode(
                ManagedChunkCodec.encode(input, ManagedChunkCompression.GZIP),
                "gzip",
                input.size + 1,
            )
        }
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            ManagedChunkCodec.decode(
                ManagedChunkCodec.encode(ByteArray(4_096), ManagedChunkCompression.GZIP),
                "gzip",
                16,
            )
        }
    }
}
