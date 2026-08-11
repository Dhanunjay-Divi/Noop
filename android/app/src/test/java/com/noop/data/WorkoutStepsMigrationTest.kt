package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class WorkoutStepsMigrationTest {
    @Test
    fun migrationIsAdditiveNullableAndVersioned() {
        assertEquals(
            listOf("ALTER TABLE `workout` ADD COLUMN `steps` INTEGER"),
            WhoopDatabase.WORKOUT_STEPS_MIGRATION_SQL,
        )
        assertEquals(25, WhoopDatabase.MIGRATION_25_26.startVersion)
        assertEquals(26, WhoopDatabase.MIGRATION_25_26.endVersion)
        assertFalse(WhoopDatabase.WORKOUT_STEPS_MIGRATION_SQL.single().uppercase().contains("NOT NULL"))
    }

    @Test
    fun freshEntityKeepsLegacyRowsNullableAndCarriesMeasuredSteps() {
        assertNull(WorkoutRow("legacy", 1, 2, "walk", "manual").steps)
        assertEquals(3_000, WorkoutRow(
            deviceId = "activity-file", startTs = 1, endTs = 2,
            sport = "walk", source = "activity-file", steps = 3_000,
        ).steps)
    }
}
