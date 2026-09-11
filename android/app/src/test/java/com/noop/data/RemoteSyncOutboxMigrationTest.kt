package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSyncOutboxMigrationTest {
    @Test
    fun sleepStateOutboxMigrationIsAdditiveAndPendingByDefault() {
        val sql = WhoopDatabase.SLEEP_STATE_SYNC_OUTBOX_MIGRATION_SQL
        val normalized = sql.uppercase()

        assertEquals(
            "ALTER TABLE `sleepStateSample` ADD COLUMN `synced` INTEGER NOT NULL DEFAULT 0",
            sql,
        )
        assertTrue(normalized.startsWith("ALTER TABLE"))
        assertTrue(normalized.contains("ADD COLUMN"))
        assertTrue(normalized.contains("DEFAULT 0"))
        assertFalse(normalized.contains("DROP "))
        assertFalse(normalized.contains("DELETE "))
    }

    @Test
    fun migrationVersionPairIs37To38() {
        assertEquals(37, WhoopDatabase.MIGRATION_37_38.startVersion)
        assertEquals(38, WhoopDatabase.MIGRATION_37_38.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun ppgWaveformOutboxMigrationIsAdditiveAndPendingByDefault() {
        val sql = WhoopDatabase.PPG_WAVEFORM_SYNC_OUTBOX_MIGRATION_SQL
        val normalized = sql.uppercase()

        assertEquals(
            "ALTER TABLE `ppgWaveformSample` ADD COLUMN `synced` INTEGER NOT NULL DEFAULT 0",
            sql,
        )
        assertTrue(normalized.startsWith("ALTER TABLE"))
        assertTrue(normalized.contains("ADD COLUMN"))
        assertTrue(normalized.contains("DEFAULT 0"))
        assertFalse(normalized.contains("DROP "))
        assertFalse(normalized.contains("DELETE "))
        assertEquals(38, WhoopDatabase.MIGRATION_38_39.startVersion)
        assertEquals(39, WhoopDatabase.MIGRATION_38_39.endVersion)
    }
}
