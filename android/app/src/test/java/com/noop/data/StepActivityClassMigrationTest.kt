package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v12 -> v13 Room migration for the compatibility-only
 * `stepSample.activityClass` column. This environment has no Robolectric / Room-testing, so the
 * migration's SQL is exposed as an internal constant ([WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL]) and
 * pinned here to Room's generated shape:
 *
 *  - one ALTER ... ADD COLUMN statement, a nullable INTEGER (an `Int?` field): no NOT NULL, no DEFAULT.
 *  - ADDITIVE: only ALTER ADD COLUMN; no DROP/DELETE/UPDATE/INSERT/CREATE on existing data.
 *
 * Legacy backups may still carry this value, so the model-mapping boundary remains pinned even though
 * current protocol decode no longer emits activity_class from byte @63.
 */
class StepActivityClassMigrationTest {

    @Test
    fun migration_isAdditive_onlyAddColumnStatement() {
        val sql = WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL
        assertEquals("one ADD COLUMN statement", 1, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only ALTER ADD COLUMN allowed, got: $s", up.startsWith("ALTER TABLE") && up.contains("ADD COLUMN"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "CREATE ", "NOT NULL", "DEFAULT")) {
                assertTrue("additive nullable migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_addsExactColumn() {
        assertEquals(
            listOf("ALTER TABLE `stepSample` ADD COLUMN `activityClass` INTEGER"),
            WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is12to13() {
        assertEquals(12, WhoopDatabase.MIGRATION_12_13.startVersion)
        assertEquals(13, WhoopDatabase.MIGRATION_12_13.endVersion)
    }

    /**
     * Compatibility values on an explicitly constructed [StepRow] survive the repository's entity
     * mapping. This does not establish that the values are gait labels.
     */
    @Test
    fun legacyActivityClass_survivesCompatibilityMapping() {
        val deviceId = "my-whoop"
        val rows = listOf(
            StepRow(ts = 1_780_916_200, counter = 60, activityClass = 0),
            StepRow(ts = 1_780_916_201, counter = 61, activityClass = 1),
            StepRow(ts = 1_780_916_202, counter = 62, activityClass = 2),
            StepRow(ts = 1_780_916_203, counter = 63, activityClass = null),
        )
        // The exact mapping WhoopRepository.insert applies before dao.insertSteps(...).
        val entities = rows.map { StepSample(deviceId, it.ts, it.counter, it.activityClass) }

        assertEquals(listOf(0, 1, 2, null), entities.map { it.activityClass })
        assertEquals(listOf(60, 61, 62, 63), entities.map { it.counter })
        assertNull(entities.last().activityClass)
    }
}
