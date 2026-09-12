package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalysisDirtySourceMigrationTest {
    @Test
    fun migrationDeclaresGenerationLedgerForEveryScoreBearingTable() {
        assertEquals(47, WhoopDatabase.MIGRATION_47_48.startVersion)
        assertEquals(48, WhoopDatabase.MIGRATION_47_48.endVersion)
        assertEquals(51, NOOP_DATABASE_SCHEMA_VERSION)
        assertTrue(
            WhoopDatabase.CREATE_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "`generation` INTEGER NOT NULL",
            ),
        )
        assertTrue(
            WhoopDatabase.CREATE_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "`acknowledgedGeneration` INTEGER NOT NULL",
            ),
        )
        assertTrue(
            WhoopDatabase.CREATE_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "`earliestAffectedTs` INTEGER",
            ),
        )
        assertTrue(
            WhoopDatabase.CREATE_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "`latestAffectedTs` INTEGER",
            ),
        )
        assertTrue(
            WhoopDatabase.CREATE_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "PRIMARY KEY(`deviceId`)",
            ),
        )
        assertTrue(
            WhoopDatabase.SEED_ANALYSIS_DIRTY_SOURCE_SQL.contains(
                "SELECT `deviceId`, 1, 0, MIN(`ts`), MAX(`ts`)",
            ),
        )
        assertTrue(WhoopDatabase.SEED_ANALYSIS_DIRTY_SOURCE_SQL.contains("GROUP BY `deviceId`"))
        assertTrue(WhoopDatabase.SEED_ANALYSIS_DIRTY_SOURCE_SQL.contains("char(9)"))
        assertTrue(WhoopDatabase.SEED_ANALYSIS_DIRTY_SOURCE_SQL.contains("char(13)"))

        val specs = WhoopDatabase.ANALYSIS_DIRTY_TRIGGER_SPECS
        val statements = WhoopDatabase.analysisDirtySourceTriggerSQL()
        assertEquals(10, specs.size)
        assertEquals(specs.size * 3, statements.size)

        specs.forEachIndexed { index, spec ->
            assertTrue(WhoopDatabase.SEED_ANALYSIS_DIRTY_SOURCE_SQL.contains("`${spec.table}`"))
            val insert = statements[index * 3]
            val delete = statements[index * 3 + 1]
            val update = statements[index * 3 + 2]

            assertTrue(insert.contains("`analysis_dirty_${spec.table}_insert`"))
            assertTrue(insert.contains("AFTER INSERT ON `${spec.table}`"))
            assertTrue(insert.contains("SET `generation` = `generation` + 1"))
            assertTrue(insert.contains("SELECT NEW.`deviceId`, 1, 0,"))
            assertTrue(insert.contains("NEW.`ts`, NEW.`ts`"))
            assertTrue(insert.contains("NOT EXISTS"))
            assertTrue(insert.contains("char(9)"))

            assertTrue(delete.contains("AFTER DELETE ON `${spec.table}`"))
            assertTrue(delete.contains("SELECT OLD.`deviceId`, 1, 0,"))
            assertTrue(delete.contains("OLD.`ts`, OLD.`ts`"))
            assertTrue(delete.contains("SET `generation` = `generation` + 1"))
            assertTrue(delete.contains("NOT EXISTS"))

            assertTrue(update.contains("AFTER UPDATE OF"))
            assertTrue(update.contains("SELECT OLD.`deviceId`, 1, 0,"))
            assertTrue(update.contains("SELECT NEW.`deviceId`, 1, 0,"))
            assertTrue(update.contains("NEW.`deviceId` != OLD.`deviceId`"))
            assertTrue(update.contains("MIN(OLD.`ts`, NEW.`ts`)"))
            assertTrue(update.contains("MAX(OLD.`ts`, NEW.`ts`)"))
            assertEquals(2, "SET `generation` = `generation` \\+ 1".toRegex().findAll(update).count())
            assertEquals(
                2,
                "`earliestAffectedTs` = CASE".toRegex().findAll(update).count(),
            )
            assertEquals(2, "AND NOT EXISTS".toRegex().findAll(update).count())

            assertFalse(update.contains("`synced`"))
            for (statement in listOf(insert, delete, update)) {
                assertFalse(statement.contains("INSERT OR "))
                assertFalse(statement.contains("ON CONFLICT"))
            }
        }
    }
}
