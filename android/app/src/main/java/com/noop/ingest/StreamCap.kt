package com.noop.ingest

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * Read a whole untrusted stream into memory, refusing to exceed [cap] bytes.
 *
 * Importers keep their own file-type-specific caps; this shared mechanism ensures every path rejects
 * before buffering the chunk that crosses its limit.
 */
internal fun InputStream.readCapped(cap: Long, what: String = "Input"): ByteArray {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val count = read(chunk)
        if (count < 0) break
        total += count
        if (total > cap) throw IllegalStateException("$what exceeds $cap bytes")
        buffer.write(chunk, 0, count)
    }
    return buffer.toByteArray()
}
