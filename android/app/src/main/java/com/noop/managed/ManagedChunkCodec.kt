package com.noop.managed

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

enum class ManagedChunkCompression(val wireValue: String) {
    NONE("none"),
    GZIP("gzip");

    companion object {
        fun fromWire(value: String): ManagedChunkCompression =
            entries.firstOrNull { it.wireValue == value }
                ?: throw ManagedStorageException.InvalidResponse()
    }
}

object ManagedChunkCodec {
    private const val ABSOLUTE_MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024

    fun encode(bytes: ByteArray, compression: ManagedChunkCompression): ByteArray =
        when (compression) {
            ManagedChunkCompression.NONE -> bytes.copyOf()
            ManagedChunkCompression.GZIP -> ByteArrayOutputStream().use { output ->
                GZIPOutputStream(output).use { it.write(bytes) }
                output.toByteArray()
            }
        }

    fun decode(
        bytes: ByteArray,
        compression: String,
        expectedUncompressedBytes: Int,
    ): ByteArray {
        if (expectedUncompressedBytes !in 1..ABSOLUTE_MAX_UNCOMPRESSED_BYTES) {
            throw ManagedStorageException.InvalidResponse()
        }
        val decoded = when (ManagedChunkCompression.fromWire(compression)) {
            ManagedChunkCompression.NONE -> bytes.copyOf()
            ManagedChunkCompression.GZIP -> decodeGzip(bytes, expectedUncompressedBytes)
        }
        if (decoded.size != expectedUncompressedBytes) {
            throw ManagedStorageException.InvalidResponse()
        }
        return decoded
    }

    fun decodePayload(bytes: ByteArray): ManagedChunkPayload {
        val root = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        }
        return try {
            val streams = root.getJSONArray("streams").objects().map { stream ->
                ManagedChunkStreamPayload(
                    streamKey = stream.getString("stream_key"),
                    schemaRevision = stream.getInt("schema_revision"),
                    columns = stream.getJSONArray("columns").strings(),
                    rows = stream.getJSONArray("rows").arrays().map { row ->
                        row.values().map(::managedValue)
                    },
                )
            }
            ManagedChunkPayload(
                chunkId = UUID.fromString(root.getString("chunk_id")),
                sourceId = UUID.fromString(root.getString("source_id")),
                dataClass = root.getString("data_class"),
                schemaVersion = root.getInt("schema_version"),
                eventStartMs = root.getLong("event_start_ms"),
                eventEndMs = root.getLong("event_end_ms"),
                streams = streams,
            )
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    fun verifyCanonical(payload: ManagedChunkPayload): ManagedPreparedChunk {
        val prepared = try {
            ManagedPreparedChunk.prepare(
                sourceId = payload.sourceId,
                dataClass = payload.dataClass,
                eventStartMs = payload.eventStartMs,
                eventEndMs = payload.eventEndMs,
                streams = payload.streams,
            )
        } catch (_: IllegalArgumentException) {
            throw ManagedStorageException.InvalidResponse()
        } ?: throw ManagedStorageException.InvalidResponse()
        if (payload.schemaVersion != 1 ||
            prepared.chunkId != payload.chunkId ||
            prepared.streams != payload.streams
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return prepared
    }

    private fun decodeGzip(bytes: ByteArray, expectedSize: Int): ByteArray =
        try {
            GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
                val output = ByteArrayOutputStream(expectedSize)
                val buffer = ByteArray(16 * 1024)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > expectedSize || total > ABSOLUTE_MAX_UNCOMPRESSED_BYTES) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        }

    private fun managedValue(value: Any): ManagedJsonValue = when (value) {
        JSONObject.NULL -> ManagedJsonValue.NullValue
        is Boolean -> ManagedJsonValue.BooleanValue(value)
        is Byte -> ManagedJsonValue.IntegerValue(value.toLong())
        is Short -> ManagedJsonValue.IntegerValue(value.toLong())
        is Int -> ManagedJsonValue.IntegerValue(value.toLong())
        is Long -> ManagedJsonValue.IntegerValue(value)
        is Float -> value.toDouble().managedNumber()
        is Double -> value.managedNumber()
        is Number -> value.toDouble().managedNumber()
        is String -> ManagedJsonValue.StringValue(value)
        else -> throw ManagedStorageException.InvalidResponse()
    }

    private fun Double.managedNumber(): ManagedJsonValue.NumberValue {
        if (!isFinite()) throw ManagedStorageException.InvalidResponse()
        return ManagedJsonValue.NumberValue(this)
    }

    private fun JSONArray.objects(): List<JSONObject> =
        List(length()) { index -> getJSONObject(index) }

    private fun JSONArray.arrays(): List<JSONArray> =
        List(length()) { index -> getJSONArray(index) }

    private fun JSONArray.strings(): List<String> =
        List(length()) { index -> getString(index) }

    private fun JSONArray.values(): List<Any> =
        List(length()) { index -> get(index) }
}
