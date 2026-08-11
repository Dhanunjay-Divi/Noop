package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the additive, non-destructive future-R-R quarantine introduced in Room v23. */
class RrFutureQuarantineMigrationTest {

    @Test
    fun migrationAddsNullableColumnThenMarksFutureRowsWithoutDeletingThem() {
        val sql = WhoopDatabase.RR_FUTURE_QUARANTINE_MIGRATION_SQL
        assertEquals("one ADD COLUMN plus one backfill UPDATE", 2, sql.size)

        assertEquals("ALTER TABLE `rrInterval` ADD COLUMN `tsSuspect` INTEGER", sql[0])
        val alter = sql[0].uppercase()
        assertFalse("column stays nullable", alter.contains("NOT NULL"))
        assertFalse("column has no SQL default", alter.contains("DEFAULT"))

        val update = sql[1].uppercase()
        assertTrue(update.startsWith("UPDATE"))
        assertTrue(update.contains("SET `TSSUSPECT` = 1"))
        assertTrue(update.contains("WHERE `TS` >"))
        for (banned in listOf("DELETE", "DROP", "CREATE", "INSERT")) {
            assertFalse("quarantine must not $banned real beats", update.contains(banned))
        }
    }

    @Test
    fun migrationVersionAndFreshEntityShapeArePinned() {
        assertEquals(22, WhoopDatabase.MIGRATION_22_23.startVersion)
        assertEquals(23, WhoopDatabase.MIGRATION_22_23.endVersion)
        assertNull(RrInterval(deviceId = "ring", ts = 1L, rrMs = 800).tsSuspect)
    }
}
