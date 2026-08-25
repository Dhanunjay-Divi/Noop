package com.noop.notif

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLifecycleLedgerTest {
    @Test
    fun boundedLedgerRetainsNewestEntriesInInsertionOrder() {
        var encoded: String? = null
        repeat(NotificationLifecycleLedger.MAX_ENTRIES + 12) { index ->
            encoded = NotificationLifecycleLedger.appendEncoded(
                raw = encoded,
                entry = entry(
                    identifier = if (index % 2 == 0) {
                        NotificationLifecycleId.HYDRATION
                    } else {
                        NotificationLifecycleId.WIND_DOWN
                    },
                    timestamp = index + 1L,
                ),
            )
        }

        val decoded = NotificationLifecycleLedger.decode(encoded)
        assertEquals(NotificationLifecycleLedger.MAX_ENTRIES, decoded.size)
        assertEquals(13L, decoded.first().timestamp)
        assertEquals(
            (NotificationLifecycleLedger.MAX_ENTRIES + 12).toLong(),
            decoded.last().timestamp,
        )
        assertEquals(decoded.map { it.timestamp }.sorted(), decoded.map { it.timestamp })
    }

    @Test
    fun encodedRecordsContainOnlyTheFourPrivacySafeKeys() {
        val encoded = NotificationLifecycleLedger.encode(
            listOf(
                entry(
                    identifier = NotificationLifecycleId.HYDRATION,
                    timestamp = 42L,
                ),
            ),
        )
        val row = JSONArray(encoded).getJSONObject(0)

        assertEquals(
            setOf("identifier", "category", "state", "timestamp"),
            row.keys().asSequence().toSet(),
        )
        assertEquals(NotificationLifecycleId.HYDRATION, row.getString("identifier"))
        assertFalse(encoded.contains("title"))
        assertFalse(encoded.contains("body"))
        assertFalse(encoded.contains("recipient"))
        assertFalse(encoded.contains("metric"))
    }

    @Test
    fun corruptExtraOrDynamicRecordsAreIgnored() {
        val valid = JSONObject()
            .put("identifier", NotificationLifecycleId.WIND_DOWN)
            .put("category", NotificationLifecycleCategory.REMINDER)
            .put("state", "scheduled")
            .put("timestamp", 10L)
        val extraPrivateField = JSONObject(valid.toString()).put("title", "private copy")
        val dynamicIdentifier = JSONObject(valid.toString())
            .put("identifier", "hydration:slot:2026-08-24")
        val invalidState = JSONObject(valid.toString()).put("state", "delivered")
        val invalidTimestamp = JSONObject(valid.toString()).put("timestamp", 0L)
        val raw = JSONArray()
            .put(extraPrivateField)
            .put(dynamicIdentifier)
            .put(invalidState)
            .put(invalidTimestamp)
            .put(valid)
            .toString()

        assertEquals(listOf(10L), NotificationLifecycleLedger.decode(raw).map { it.timestamp })
        assertTrue(NotificationLifecycleLedger.decode("not-json").isEmpty())
        assertTrue(NotificationLifecycleLedger.decode("""{"identifier":"wrong-shape"}""").isEmpty())
    }

    @Test
    fun invalidAppendCannotPersistDynamicMetadata() {
        val encoded = NotificationLifecycleLedger.appendEncoded(
            raw = null,
            entry = entry(
                identifier = "hydration_slot_20260824",
                timestamp = 99L,
            ),
        )

        assertTrue(NotificationLifecycleLedger.decode(encoded).isEmpty())
        assertEquals("[]", encoded)
    }

    @Test
    fun postedStateExplicitlyDisclaimsOsDelivery() {
        val disclaimer = NotificationLifecycleLedger.POSTED_DISCLAIMER
        assertTrue(disclaimer.contains("API call returned without throwing"))
        assertTrue(disclaimer.contains("no entry confirms"))
        assertTrue(disclaimer.contains("OS"))
        assertTrue(disclaimer.contains("delivered"))
        assertEquals("posted", NotificationLifecycleState.POSTED.wireValue)
    }

    private fun entry(
        identifier: String,
        timestamp: Long,
    ) = NotificationLifecycleEntry(
        identifier = identifier,
        category = NotificationLifecycleCategory.REMINDER,
        state = NotificationLifecycleState.SCHEDULED,
        timestamp = timestamp,
    )
}
