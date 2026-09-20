package com.noop.managed

import java.io.File
import java.util.Base64
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ManagedDocumentEnvelopeTest {
    @Test
    fun sharedGoldenVectorMatchesAndroidImplementation() {
        val vector = fixture().getJSONObject("document")
        val metadata = ManagedDocumentEnvelopeMetadata(
            vector.getString("account_scope_hash"),
            ManagedDocumentKind.fromWire(vector.getString("document_kind")),
            UUID.fromString(vector.getString("document_id")),
            vector.getLong("revision"),
        )
        assertEquals(vector.getString("aad_hex"), metadata.authenticatedData.hex())
        val envelope = ManagedDocumentEnvelope.seal(
            Base64.getDecoder().decode(vector.getString("plaintext_base64")),
            vector.getString("key_hex").hexBytes(),
            metadata,
            vector.getString("nonce_hex").hexBytes(),
        )
        assertEquals(
            vector.getString("envelope_base64"),
            Base64.getEncoder().encodeToString(envelope),
        )
        assertEquals(vector.getString("envelope_sha256"), sha256(envelope))
        assertArrayEquals(
            Base64.getDecoder().decode(vector.getString("plaintext_base64")),
            ManagedDocumentEnvelope.open(
                envelope,
                vector.getString("key_hex").hexBytes(),
                metadata,
            ),
        )
    }

    @Test
    fun tamperCrossAccountAndRevisionReplayAreRejected() {
        val vector = fixture().getJSONObject("document")
        val envelope = Base64.getDecoder().decode(vector.getString("envelope_base64"))
        val key = vector.getString("key_hex").hexBytes()
        val id = UUID.fromString(vector.getString("document_id"))
        val kind = ManagedDocumentKind.fromWire(vector.getString("document_kind"))
        val tampered = envelope.copyOf().also { it[it.lastIndex] = (it.last() xor 1) }

        listOf(
            tampered to vector.getString("account_scope_hash") to vector.getLong("revision"),
            envelope to "b".repeat(64) to vector.getLong("revision"),
            envelope to vector.getString("account_scope_hash") to vector.getLong("revision") + 1,
        ).forEach { nested ->
            val pair = nested.first
            assertThrows(ManagedStorageException.InvalidResponse::class.java) {
                ManagedDocumentEnvelope.open(
                    pair.first,
                    key,
                    ManagedDocumentEnvelopeMetadata(
                        pair.second,
                        kind,
                        id,
                        nested.second,
                    ),
                )
            }
        }
    }

    @Test
    fun keyWrappingGoldenVectorMatches() {
        val vector = fixture().getJSONObject("key_wrap")
        val wrapped = ManagedDocumentKeyWrapEnvelope.seal(
            documentKey = vector.getString("document_key_hex").hexBytes(),
            accountScopeHash = vector.getString("account_scope_hash"),
            keyId = UUID.fromString(vector.getString("document_key_id")),
            wrappingKeyId = UUID.fromString(vector.getString("wrapping_key_id")),
            wrappingRevision = vector.getInt("wrapping_revision"),
            wrappingKey = vector.getString("wrapping_key_hex").hexBytes(),
            suppliedNonce = vector.getString("nonce_hex").hexBytes(),
        )
        assertEquals(
            vector.getString("wrapped_key_base64"),
            Base64.getEncoder().encodeToString(wrapped),
        )
        assertEquals(vector.getString("wrapped_key_sha256"), sha256(wrapped))
    }

    private fun fixture(): JSONObject {
        val fixture = File(
            managedTestRepositoryRoot(),
            "Fixtures/managed-document-sync/v1/golden-vectors.json",
        )
        check(fixture.isFile) { "Managed document fixture is missing." }
        return JSONObject(fixture.readText())
    }

    private fun String.hexBytes(): ByteArray =
        chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

    private infix fun Byte.xor(value: Int): Byte = (toInt() xor value).toByte()
}
