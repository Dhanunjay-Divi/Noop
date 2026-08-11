package com.noop.ingest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class StreamCapTest {
    private fun stream(size: Int): InputStream =
        ByteArrayInputStream(ByteArray(size) { (it % 251).toByte() })

    @Test fun readsContentUnderTheCapExactly() {
        val source = ByteArray(5_000) { (it % 251).toByte() }
        assertArrayEquals(source, ByteArrayInputStream(source).readCapped(10_000))
    }

    @Test fun readsAcrossMultipleChunks() {
        val size = 64 * 1024 * 3 + 17
        assertEquals(size, stream(size).readCapped(1L shl 20).size)
    }

    @Test fun exactlyAtTheCapIsAllowed() {
        assertEquals(1_000, stream(1_000).readCapped(1_000L).size)
    }

    @Test fun oneByteOverTheCapThrows() {
        assertThrows(IllegalStateException::class.java) { stream(1_001).readCapped(1_000L) }
    }

    @Test fun emptyStreamIsAllowed() {
        assertEquals(0, stream(0).readCapped(1_000L).size)
    }

    @Test fun failureMessageNamesTheThingAndCap() {
        val input = assertThrows(IllegalStateException::class.java) { stream(50).readCapped(10L) }
        assertEquals("Input exceeds 10 bytes", input.message)
        val entry = assertThrows(IllegalStateException::class.java) {
            stream(50).readCapped(10L, what = "Entry")
        }
        assertEquals("Entry exceeds 10 bytes", entry.message)
    }

    @Test fun throwsBeforeBufferingTheWholeOversizeStream() {
        var consumed = 0
        val counting = object : InputStream() {
            private val inner = stream(64 * 1024 * 40)
            override fun read(): Int = inner.read().also { if (it >= 0) consumed += 1 }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                inner.read(bytes, offset, length).also { if (it > 0) consumed += it }
        }
        assertThrows(IllegalStateException::class.java) { counting.readCapped(128L * 1024) }
        assertTrue(consumed <= 128 * 1024 + 64 * 1024)
    }
}
