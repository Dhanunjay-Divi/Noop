package com.noop.managed

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

class ManagedDocumentStableIdentifierTest {
    @Test
    fun journalIdentifierMatchesTheSharedSwiftFixture() {
        val key = ManagedCanonicalJson.encode(
            org.json.JSONObject()
                .put("deviceId", "strap")
                .put("day", "2026-09-04")
                .put("question", "late_caffeine"),
        )

        assertEquals(
            UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500"),
            RoomManagedDocumentAdapter.documentId(
                ManagedDocumentKind.JOURNAL,
                "journal",
                key,
            ),
        )
    }
}
