package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSyncStateMigrationTest {
    @Test
    fun migrationIsAdditiveAndCreatesOnlyCompactOperationalTables() {
        val statements = WhoopDatabase.MANAGED_SYNC_STATE_MIGRATION_SQL
        assertEquals(4, statements.size)
        assertTrue(statements.any { it.contains("`managedSyncSource`") })
        assertTrue(statements.any { it.contains("`managedSyncCheckpoint`") })
        assertTrue(statements.any { it.contains("`managedChangeCursor`") })
        assertTrue(statements.any { it.contains("`managedAppliedChange`") })
        for (statement in statements) {
            val normalized = statement.uppercase()
            assertTrue(normalized.startsWith("CREATE TABLE IF NOT EXISTS"))
            assertFalse(normalized.contains("DROP "))
            assertFalse(normalized.contains("DELETE "))
            assertFalse(normalized.contains("ALTER TABLE"))
        }
    }

    @Test
    fun managedStateMigrationVersionPairIs39To40() {
        assertEquals(39, WhoopDatabase.MIGRATION_39_40.startVersion)
        assertEquals(40, WhoopDatabase.MIGRATION_39_40.endVersion)
    }

    @Test
    fun bodyMeasurementMigrationRebuildsPpgAsRealAndAdvances40To41() {
        val statements = WhoopDatabase.BODY_MEASUREMENT_MIGRATION_SQL
        assertEquals(6, statements.size)
        assertTrue(statements[0].contains("`bpm` REAL NOT NULL"))
        assertTrue(statements[1].contains("CAST(`bpm` AS REAL)"))
        assertTrue(statements[2].contains("DROP TABLE `ppgHrSample`"))
        assertTrue(statements[3].contains("RENAME TO `ppgHrSample`"))
        assertTrue(statements[4].contains("`bodyMeasurement`"))
        assertTrue(statements[5].contains("idx_bodyMeasurement_device_measuredAt"))
        assertEquals(40, WhoopDatabase.MIGRATION_40_41.startVersion)
        assertEquals(41, WhoopDatabase.MIGRATION_40_41.endVersion)
    }

    @Test
    fun windowUploadMigrationScopesProgressToAnAccountAndAdvances41To42() {
        val statements = WhoopDatabase.MANAGED_WINDOW_UPLOAD_MIGRATION_SQL
        assertEquals(4, statements.size)
        assertTrue(statements[0].contains("`accountScopeHash` TEXT NOT NULL"))
        assertTrue(
            statements[0].contains(
                "PRIMARY KEY(`accountScopeHash`, `sourceId`, `dataClass`)"
            )
        )
        assertTrue(statements[3].contains("`managedWindowUpload`"))
        assertTrue(statements[3].contains("`objectGeneration` INTEGER"))
        assertTrue(statements[3].contains("`objectCRC32C` TEXT"))
        assertEquals(41, WhoopDatabase.MIGRATION_41_42.startVersion)
        assertEquals(42, WhoopDatabase.MIGRATION_41_42.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun dirtyWindowMigrationSeparatesUploadFromValidationAndAdvances42To43() {
        val statements = WhoopDatabase.MANAGED_DIRTY_WINDOW_MIGRATION_SQL
        assertTrue(statements.any { it.contains("`snapshotGeneration`") })
        assertTrue(statements.any { it.contains("`validatedAtMs`") })
        assertTrue(statements.any { it.contains("`localPrunedAtMs`") })
        assertTrue(statements.any { it.contains("`managedDirtyWindow`") })
        assertTrue(statements.any { it.contains("`managedPruneGuard`") })
        assertTrue(
            statements.any {
                it.contains("SET `phase` = 'awaiting_validation'") &&
                    it.contains("WHERE `phase` = 'completed'")
            },
        )
        assertEquals(42, WhoopDatabase.MIGRATION_42_43.startVersion)
        assertEquals(43, WhoopDatabase.MIGRATION_42_43.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun snapshotRestoreMigrationIsAdditiveAndAdvances43To44() {
        val statement = WhoopDatabase.MANAGED_SNAPSHOT_RESTORE_MIGRATION_SQL
        assertTrue(statement.startsWith("CREATE TABLE IF NOT EXISTS"))
        assertTrue(statement.contains("`managedSnapshotRestore`"))
        assertTrue(statement.contains("`accountScopeHash` TEXT NOT NULL"))
        assertTrue(statement.contains("`requestId` TEXT NOT NULL"))
        assertFalse(statement.contains("DROP "))
        assertFalse(statement.contains("DELETE "))
        assertFalse(statement.contains("ALTER TABLE"))
        assertEquals(43, WhoopDatabase.MIGRATION_43_44.startVersion)
        assertEquals(44, WhoopDatabase.MIGRATION_43_44.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun managedDocumentMigrationAddsOutboxStateAndSnapshotCursorAt44To45() {
        val statements = WhoopDatabase.MANAGED_DOCUMENT_MIGRATION_SQL
        assertTrue(statements.any { it.contains("`managedDocumentDirty`") })
        assertTrue(statements.any { it.contains("`managedDocumentState`") })
        assertTrue(statements.any { it.contains("`managedDocumentApplyGuard`") })
        assertTrue(statements.any { it.contains("`afterDocumentUpdatedAt`") })
        assertTrue(statements.any { it.contains("`afterDocumentKind`") })
        assertTrue(statements.any { it.contains("`afterDocumentId`") })
        assertTrue(statements.any { it.contains("`documentsComplete`") })
        assertFalse(statements.any { it.uppercase().contains("DROP ") })
        assertFalse(statements.any { it.uppercase().contains("DELETE ") })
        assertEquals(44, WhoopDatabase.MIGRATION_44_45.startVersion)
        assertEquals(45, WhoopDatabase.MIGRATION_44_45.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }
}
