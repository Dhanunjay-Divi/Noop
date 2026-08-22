package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NutritionEntryMigrationTest {
    @Test
    fun migrationIsAdditiveAndPinsCrossPlatformShape() {
        assertEquals(28, WhoopDatabase.MIGRATION_28_29.startVersion)
        assertEquals(29, WhoopDatabase.MIGRATION_28_29.endVersion)

        val sql = WhoopDatabase.NUTRITION_ENTRY_MIGRATION_SQL.joinToString("\n")
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `nutritionEntry`"))
        assertTrue(sql.contains("`id` TEXT NOT NULL"))
        assertTrue(sql.contains("`origin` TEXT NOT NULL"))
        assertTrue(sql.contains("`caloriesKcal` REAL"))
        assertTrue(sql.contains("`proteinG` REAL"))
        assertTrue(sql.contains("`createdAt` INTEGER NOT NULL"))
        assertTrue(sql.contains("PRIMARY KEY(`id`)"))
        assertTrue(sql.contains("idx_nutritionEntry_device_day_occurredAt"))
        assertTrue(sql.contains("idx_nutritionEntry_device_origin_day"))
        assertTrue(sql.contains("'nutrition-csv:' || `day`"))
        assertTrue(sql.contains("SELECT 'nutrition-log'"))
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
    }
}
