package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectSyncStateMigrationTest {
    @Test
    fun migrationIsAdditiveAndPinsRoomShape() {
        assertEquals(27, WhoopDatabase.MIGRATION_27_28.startVersion)
        assertEquals(28, WhoopDatabase.MIGRATION_27_28.endVersion)

        val sql = WhoopDatabase.HEALTH_CONNECT_SYNC_STATE_MIGRATION_SQL
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `healthConnectSyncState`"))
        assertTrue(sql.contains("`recordType` TEXT NOT NULL"))
        assertTrue(sql.contains("`changesToken` TEXT NOT NULL"))
        assertTrue(sql.contains("`updatedAt` INTEGER NOT NULL"))
        assertTrue(sql.contains("PRIMARY KEY(`recordType`)"))
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
    }
}
