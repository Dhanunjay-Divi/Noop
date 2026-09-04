package com.noop.managed

import org.json.JSONObject
import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

sealed interface ManagedJsonValue {
    data class IntegerValue(val value: Long) : ManagedJsonValue
    data class NumberValue(val value: Double) : ManagedJsonValue
    data class StringValue(val value: String) : ManagedJsonValue
    data class BooleanValue(val value: Boolean) : ManagedJsonValue
    data object NullValue : ManagedJsonValue
}

data class ManagedChunkStreamPayload(
    val streamKey: String,
    val columns: List<String>,
    val rows: List<List<ManagedJsonValue>>,
    val schemaRevision: Int = 1,
)

data class ManagedChunkPayload(
    val chunkId: UUID,
    val sourceId: UUID,
    val dataClass: String,
    val schemaVersion: Int,
    val eventStartMs: Long,
    val eventEndMs: Long,
    val streams: List<ManagedChunkStreamPayload>,
)

data class ManagedChunkStreamManifest(
    val streamKey: String,
    val sampleCount: Int,
    val firstEventAt: String?,
    val lastEventAt: String?,
    val encodedBytes: Int,
    val schemaRevision: Int = 1,
)

data class ManagedPreparedChunk(
    val chunkId: UUID,
    val sourceId: UUID,
    val dataClass: String,
    val eventStartMs: Long,
    val eventEndMs: Long,
    val streams: List<ManagedChunkStreamPayload>,
    val uncompressed: ByteArray,
    val uncompressedSha256: String,
    val manifests: List<ManagedChunkStreamManifest>,
) {
    fun reservation(compressed: ByteArray, compression: String): ManagedChunkReservation =
        ManagedChunkReservation(
            chunkId = chunkId,
            requestId = ManagedStableIdentifier.uuid(
                "noop-managed-reservation-v1\u0000$chunkId".toByteArray(StandardCharsets.UTF_8),
            ),
            sourceId = sourceId,
            dataClass = dataClass,
            eventStart = Instant.ofEpochMilli(eventStartMs).toString(),
            eventEnd = Instant.ofEpochMilli(eventEndMs).toString(),
            compression = compression,
            expectedSha256 = ManagedDigest.sha256(compressed),
            expectedCompressedBytes = compressed.size,
            expectedUncompressedBytes = uncompressed.size,
            streams = manifests,
        )

    companion object {
        fun prepare(
            sourceId: UUID,
            dataClass: String,
            eventStartMs: Long,
            eventEndMs: Long,
            streams: List<ManagedChunkStreamPayload>,
        ): ManagedPreparedChunk? {
            require(eventStartMs >= 0L && eventEndMs >= eventStartMs && dataClass.isNotBlank())
            val ordered = streams.sortedBy { it.streamKey }
            if (ordered.isEmpty()) return null
            require(ordered.map { it.streamKey }.distinct().size == ordered.size)
            ordered.forEach { stream ->
                require(stream.streamKey.isNotBlank())
                require(stream.columns.firstOrNull() == "event_at_ms")
                require(stream.columns.distinct().size == stream.columns.size)
                stream.rows.forEach { row ->
                    require(row.size == stream.columns.size)
                    val timestamp = (row.firstOrNull() as? ManagedJsonValue.IntegerValue)?.value
                    require(timestamp != null && timestamp in eventStartMs..eventEndMs)
                }
            }

            val withoutId = canonicalPayload(
                chunkId = null,
                sourceId = sourceId,
                dataClass = dataClass,
                eventStartMs = eventStartMs,
                eventEndMs = eventEndMs,
                streams = ordered,
            )
            val chunkId = ManagedStableIdentifier.uuid(
                "noop-managed-chunk-v1\u0000".toByteArray(StandardCharsets.UTF_8) + withoutId,
            )
            val encoded = canonicalPayload(
                chunkId = chunkId,
                sourceId = sourceId,
                dataClass = dataClass,
                eventStartMs = eventStartMs,
                eventEndMs = eventEndMs,
                streams = ordered,
            )
            val manifests = ordered.map { stream ->
                val timestamps = stream.rows.map {
                    (it.first() as ManagedJsonValue.IntegerValue).value
                }
                ManagedChunkStreamManifest(
                    streamKey = stream.streamKey,
                    sampleCount = stream.rows.size,
                    firstEventAt = timestamps.minOrNull()?.let {
                        Instant.ofEpochMilli(it).toString()
                    },
                    lastEventAt = timestamps.maxOrNull()?.let {
                        Instant.ofEpochMilli(it).toString()
                    },
                    encodedBytes = canonicalStream(stream).size,
                    schemaRevision = stream.schemaRevision,
                )
            }
            return ManagedPreparedChunk(
                chunkId = chunkId,
                sourceId = sourceId,
                dataClass = dataClass,
                eventStartMs = eventStartMs,
                eventEndMs = eventEndMs,
                streams = ordered,
                uncompressed = encoded,
                uncompressedSha256 = ManagedDigest.sha256(encoded),
                manifests = manifests,
            )
        }

        private fun canonicalPayload(
            chunkId: UUID?,
            sourceId: UUID,
            dataClass: String,
            eventStartMs: Long,
            eventEndMs: Long,
            streams: List<ManagedChunkStreamPayload>,
        ): ByteArray = buildString {
            append('{')
            if (chunkId != null) {
                append("\"chunk_id\":")
                appendQuoted(chunkId.toString())
                append(',')
            }
            append("\"data_class\":")
            appendQuoted(dataClass)
            append(",\"event_end_ms\":").append(eventEndMs)
            append(",\"event_start_ms\":").append(eventStartMs)
            append(",\"schema_version\":1")
            append(",\"source_id\":")
            appendQuoted(sourceId.toString())
            append(",\"streams\":[")
            streams.forEachIndexed { index, stream ->
                if (index > 0) append(',')
                append(String(canonicalStream(stream), StandardCharsets.UTF_8))
            }
            append("]}")
        }.toByteArray(StandardCharsets.UTF_8)

        private fun canonicalStream(stream: ManagedChunkStreamPayload): ByteArray = buildString {
            append("{\"columns\":[")
            stream.columns.forEachIndexed { index, column ->
                if (index > 0) append(',')
                appendQuoted(column)
            }
            append("],\"rows\":[")
            stream.rows.forEachIndexed { rowIndex, row ->
                if (rowIndex > 0) append(',')
                append('[')
                row.forEachIndexed { valueIndex, value ->
                    if (valueIndex > 0) append(',')
                    appendValue(value)
                }
                append(']')
            }
            append("],\"schema_revision\":").append(stream.schemaRevision)
            append(",\"stream_key\":")
            appendQuoted(stream.streamKey)
            append('}')
        }.toByteArray(StandardCharsets.UTF_8)

        private fun StringBuilder.appendQuoted(value: String) {
            append(JSONObject.quote(value))
        }

        private fun StringBuilder.appendValue(value: ManagedJsonValue) {
            when (value) {
                is ManagedJsonValue.IntegerValue -> append(value.value)
                is ManagedJsonValue.NumberValue -> {
                    require(value.value.isFinite())
                    append(BigDecimal.valueOf(value.value).stripTrailingZeros().toPlainString())
                }
                is ManagedJsonValue.StringValue -> appendQuoted(value.value)
                is ManagedJsonValue.BooleanValue -> append(if (value.value) "true" else "false")
                ManagedJsonValue.NullValue -> append("null")
            }
        }
    }

    override fun equals(other: Any?): Boolean =
        other is ManagedPreparedChunk &&
            chunkId == other.chunkId &&
            sourceId == other.sourceId &&
            dataClass == other.dataClass &&
            eventStartMs == other.eventStartMs &&
            eventEndMs == other.eventEndMs &&
            streams == other.streams &&
            uncompressed.contentEquals(other.uncompressed) &&
            uncompressedSha256 == other.uncompressedSha256 &&
            manifests == other.manifests

    override fun hashCode(): Int =
        31 * chunkId.hashCode() + uncompressed.contentHashCode()
}

object ManagedStableIdentifier {
    fun uuid(seed: ByteArray): UUID {
        val bytes = MessageDigest.getInstance("SHA-256").digest(seed).copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long)
    }
}

object ManagedAccountIdentifier {
    private val BASE_INSTALLATION = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
    private val ACCOUNT_SCOPE = Regex("^[0-9a-f]{64}$")

    fun installationId(baseInstallationId: String, accountScopeHash: String): String {
        require(baseInstallationId.matches(BASE_INSTALLATION))
        require(accountScopeHash.matches(ACCOUNT_SCOPE))
        return ManagedStableIdentifier.uuid(
            "noop-managed-installation-v2\u0000$baseInstallationId\u0000$accountScopeHash"
                .toByteArray(Charsets.UTF_8),
        ).toString().lowercase()
    }
}

object ManagedDigest {
    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
}
