package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthTrainingMigrationTest {
    @Test
    fun migrationIsAdditiveNormalizedAndSeedsOwnedCatalog() {
        assertEquals(29, WhoopDatabase.MIGRATION_29_30.startVersion)
        assertEquals(30, WhoopDatabase.MIGRATION_29_30.endVersion)
        assertEquals(30, WhoopDatabase.MIGRATION_30_31.startVersion)
        assertEquals(31, WhoopDatabase.MIGRATION_30_31.endVersion)
        assertEquals(36, WhoopDatabase.MIGRATION_36_37.startVersion)
        assertEquals(37, WhoopDatabase.MIGRATION_36_37.endVersion)

        val statements = WhoopDatabase.STRENGTH_TRAINING_MIGRATION_SQL
        val sql = statements.joinToString("\n")
        listOf(
            "strengthExercise",
            "strengthRoutine",
            "strengthRoutineExercise",
            "strengthSession",
            "strengthSet",
        ).forEach { table ->
            assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `$table`"))
        }
        assertTrue(sql.contains("idx_strengthRoutineExercise_routine_position"))
        assertTrue(sql.contains("idx_strengthSet_session_order"))
        assertTrue(sql.contains("idx_strengthSet_exercise_completed"))
        assertEquals(
            StrengthTrainingContract.BUILT_IN_EXERCISES.size,
            statements.count { it.startsWith("INSERT OR IGNORE INTO `strengthExercise`") },
        )
        StrengthTrainingContract.BUILT_IN_EXERCISES.forEach { exercise ->
            assertTrue(sql.contains("'${exercise.id}'"))
        }
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
        assertEquals(
            "ALTER TABLE `strengthSet` ADD COLUMN `restSeconds` INTEGER",
            WhoopDatabase.STRENGTH_SET_REST_MIGRATION_SQL,
        )
        val planning = WhoopDatabase.STRENGTH_GYM_PLANNING_MIGRATION_SQL
        assertTrue(planning.contains(
            "ALTER TABLE `strengthRoutine` ADD COLUMN `scheduledWeekdaysJSON` TEXT",
        ))
        assertTrue(planning.contains(
            "ALTER TABLE `strengthRoutineExercise` ADD COLUMN `planJSON` TEXT",
        ))
        assertEquals(
            StrengthTrainingContract.BUILT_IN_EXERCISES.size,
            planning.count { it.startsWith("INSERT OR IGNORE INTO `strengthExercise`") },
        )
    }
}
