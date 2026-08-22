package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoachHistoryMigrationTest {
    @Test
    fun migrationIsAdditiveAndPinsCrossPlatformShape() {
        assertEquals(31, WhoopDatabase.MIGRATION_31_32.startVersion)
        assertEquals(32, WhoopDatabase.MIGRATION_31_32.endVersion)

        val sql = WhoopDatabase.COACH_HISTORY_MEMORY_MIGRATION_SQL.joinToString("\n")
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `coachMessage`"))
        assertTrue(sql.contains("`id` TEXT NOT NULL, `createdAt` INTEGER NOT NULL"))
        assertTrue(sql.contains("`role` TEXT NOT NULL"))
        assertTrue(sql.contains("idx_coachMessage_createdAt"))
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `coachMemory`"))
        assertTrue(sql.contains("`enabled` INTEGER NOT NULL"))
        assertTrue(sql.contains("idx_coachMemory_enabled_updatedAt"))
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
    }
}
