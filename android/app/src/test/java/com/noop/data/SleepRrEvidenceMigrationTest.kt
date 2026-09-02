package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepRrEvidenceMigrationTest {
    @Test
    fun migrationIsAdditiveNullableIntegerColumnsOnly() {
        val sql = WhoopDatabase.SLEEP_RR_EVIDENCE_MIGRATION_SQL

        assertEquals(
            listOf(
                "ALTER TABLE `sleepSession` ADD COLUMN `rrEligibleWindowCount` INTEGER",
                "ALTER TABLE `sleepSession` ADD COLUMN `rrValidWindowCount` INTEGER",
            ),
            sql,
        )
        for (statement in sql) {
            val normalized = statement.uppercase()
            assertTrue(normalized.startsWith("ALTER TABLE"))
            assertTrue(normalized.contains("ADD COLUMN"))
            for (forbidden in listOf("DROP ", "DELETE ", "UPDATE ", "NOT NULL", "DEFAULT")) {
                assertTrue("$forbidden must not appear in $statement", !normalized.contains(forbidden))
            }
        }
    }

    @Test
    fun migrationVersionPairIs34To35() {
        assertEquals(34, WhoopDatabase.MIGRATION_34_35.startVersion)
        assertEquals(35, WhoopDatabase.MIGRATION_34_35.endVersion)
        assertEquals(39, NOOP_DATABASE_SCHEMA_VERSION)
    }
}
