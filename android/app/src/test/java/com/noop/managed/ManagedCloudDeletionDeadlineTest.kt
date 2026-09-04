package com.noop.managed

import java.time.Instant
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedCloudDeletionDeadlineTest {
    private val now = Instant.parse("2026-09-04T12:00:00Z")

    @Test
    fun deadlineOnlyPassesAtOrAfterValidTimestamp() {
        assertFalse(managedDeletionDeadlinePassed(null, now))
        assertFalse(managedDeletionDeadlinePassed("not-a-time", now))
        assertFalse(
            managedDeletionDeadlinePassed(
                "2026-09-04T12:00:00.001Z",
                now,
            ),
        )
        assertTrue(
            managedDeletionDeadlinePassed(
                "2026-09-04T12:00:00Z",
                now,
            ),
        )
        assertTrue(
            managedDeletionDeadlinePassed(
                "2026-09-04T11:59:59.999Z",
                now,
            ),
        )
    }
}
