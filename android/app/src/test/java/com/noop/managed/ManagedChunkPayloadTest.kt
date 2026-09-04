package com.noop.managed

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManagedChunkPayloadTest {
    private val sourceId = UUID.fromString("fe5d19f4-b8ea-4c97-9c3f-e6532f083883")

    @Test
    fun accountScopedInstallationIdentityMatchesCrossPlatformVector() {
        val first = ManagedAccountIdentifier.installationId(
            "installation",
            "a".repeat(64),
        )
        val second = ManagedAccountIdentifier.installationId(
            "installation",
            "b".repeat(64),
        )

        assertEquals("8aef8f93-975e-5622-b49d-589684e87197", first)
        assertNotEquals(first, second)
        assertThrows(IllegalArgumentException::class.java) {
            ManagedAccountIdentifier.installationId("installation", "not-a-scope")
        }
    }

    @Test
    fun canonicalChunkIsStableAndManifestBound() {
        val stream = heartRate(68)
        val first = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_788_436_800_000,
                1_788_440_399_999,
                listOf(stream),
            ),
        )
        val second = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_788_436_800_000,
                1_788_440_399_999,
                listOf(stream),
            ),
        )

        assertEquals(first.chunkId, second.chunkId)
        assertTrue(first.uncompressed.contentEquals(second.uncompressed))
        assertEquals(1, first.manifests.single().sampleCount)
        assertEquals(64, first.uncompressedSha256.length)
        val json = JSONObject(first.uncompressed.toString(Charsets.UTF_8))
        assertEquals(first.chunkId.toString(), json.getString("chunk_id"))
        assertEquals("essential_timeseries", json.getString("data_class"))
    }

    @Test
    fun contentChangeCreatesNewChunkIdentity() {
        fun prepare(bpm: Long) = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_788_436_800_000,
                1_788_440_399_999,
                listOf(heartRate(bpm)),
            ),
        )
        assertNotEquals(prepare(68).chunkId, prepare(69).chunkId)
    }

    @Test
    fun emptySnapshotIsCanonicalAndManifestHasNoEventWindow() {
        val prepared = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_788_436_800_000,
                1_788_440_399_999,
                listOf(
                    ManagedChunkStreamPayload(
                        "heart_rate",
                        listOf("event_at_ms", "bpm", "quality", "provenance"),
                        emptyList(),
                    ),
                ),
            ),
        )

        assertEquals(0, prepared.manifests.single().sampleCount)
        assertEquals(null, prepared.manifests.single().firstEventAt)
        assertEquals(null, prepared.manifests.single().lastEventAt)
        assertEquals(prepared, ManagedChunkCodec.verifyCanonical(
            ManagedChunkCodec.decodePayload(prepared.uncompressed),
        ))
    }

    @Test
    fun canonicalVerificationRejectsPayloadTampering() {
        val prepared = requireNotNull(
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_788_436_800_000,
                1_788_440_399_999,
                listOf(heartRate(68)),
            ),
        )
        val tampered = prepared.uncompressed.toString(Charsets.UTF_8)
            .replace(",68,", ",69,")
            .toByteArray()

        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            ManagedChunkCodec.verifyCanonical(ManagedChunkCodec.decodePayload(tampered))
        }
    }

    @Test
    fun rejectsRowsOutsideReservedWindow() {
        assertThrows(IllegalArgumentException::class.java) {
            ManagedPreparedChunk.prepare(
                sourceId,
                "essential_timeseries",
                1_000,
                2_000,
                listOf(
                    ManagedChunkStreamPayload(
                        "heart_rate",
                        listOf("event_at_ms", "bpm", "quality", "provenance"),
                        listOf(
                            listOf(
                                ManagedJsonValue.IntegerValue(2_001),
                                ManagedJsonValue.IntegerValue(68),
                                ManagedJsonValue.NullValue,
                                ManagedJsonValue.StringValue("sensor"),
                            ),
                        ),
                    ),
                ),
            )
        }
    }

    private fun heartRate(bpm: Long) = ManagedChunkStreamPayload(
        "heart_rate",
        listOf("event_at_ms", "bpm", "quality", "provenance"),
        listOf(
            listOf(
                ManagedJsonValue.IntegerValue(1_788_436_800_000),
                ManagedJsonValue.IntegerValue(bpm),
                ManagedJsonValue.NullValue,
                ManagedJsonValue.StringValue("sensor"),
            ),
        ),
    )
}
