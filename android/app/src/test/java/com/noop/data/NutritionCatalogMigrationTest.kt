package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NutritionCatalogMigrationTest {
    @Test
    fun migrationIsAdditiveAndPinsCrossPlatformShape() {
        assertEquals(32, WhoopDatabase.MIGRATION_32_33.startVersion)
        assertEquals(33, WhoopDatabase.MIGRATION_32_33.endVersion)

        val sql = WhoopDatabase.NUTRITION_CATALOG_MIGRATION_SQL.joinToString("\n")
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `nutritionCatalogItem`"))
        assertTrue(sql.contains("`barcode` TEXT"))
        assertTrue(sql.contains("`isSaved` INTEGER NOT NULL"))
        assertTrue(sql.contains("idx_nutritionCatalogItem_barcode"))
        assertTrue(sql.contains("idx_nutritionCatalogItem_saved_used"))
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
    }
}
