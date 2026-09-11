package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyHrvMethodMigrationTest {
    @Test
    fun migrationIsOneNullableTextColumn() {
        val sql = WhoopDatabase.DAILY_HRV_METHOD_MIGRATION_SQL
        assertEquals("ALTER TABLE `dailyMetric` ADD COLUMN `hrvMethod` TEXT", sql)
        val normalized = sql.uppercase()
        assertTrue(normalized.startsWith("ALTER TABLE"))
        assertTrue(normalized.contains("ADD COLUMN"))
        for (forbidden in listOf("DROP ", "DELETE ", "UPDATE ", "NOT NULL", "DEFAULT")) {
            assertFalse("$forbidden must not appear in $sql", normalized.contains(forbidden))
        }
    }

    @Test
    fun migrationVersionPairIs35To36() {
        assertEquals(35, WhoopDatabase.MIGRATION_35_36.startVersion)
        assertEquals(36, WhoopDatabase.MIGRATION_35_36.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun methodVocabularyRejectsUnknownValues() {
        assertEquals(DailyHrvMethod.RMSSD, DailyHrvMethod.normalized("rmssd"))
        assertEquals(DailyHrvMethod.SDNN, DailyHrvMethod.normalized("SDNN"))
        assertEquals(null, DailyHrvMethod.normalized("milliseconds"))
        assertEquals(null, DailyHrvMethod.normalized(null))
    }
}
