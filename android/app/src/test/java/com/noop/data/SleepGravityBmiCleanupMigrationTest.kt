package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepGravityBmiCleanupMigrationTest {
    @Test
    fun migrationPersistsNullableGravityEvidenceAndPurgesLegacyDerivedBmi() {
        assertEquals(
            listOf(
                "ALTER TABLE `sleepSession` ADD COLUMN `gravitySparse` INTEGER",
                "DELETE FROM `metricSeries` WHERE `deviceId` = 'health-connect' AND `key` = 'bmi'",
            ),
            WhoopDatabase.SLEEP_GRAVITY_BMI_CLEANUP_MIGRATION_SQL,
        )
        assertEquals(45, WhoopDatabase.MIGRATION_45_46.startVersion)
        assertEquals(46, WhoopDatabase.MIGRATION_45_46.endVersion)
        assertEquals(46, NOOP_DATABASE_SCHEMA_VERSION)
    }

    @Test
    fun sleepEntityKeepsUnknownEvidenceDistinctFromDenseMotion() {
        val unknown = SleepSession("test", 100, 200)
        val dense = unknown.copy(gravitySparse = false)

        assertTrue(unknown.gravitySparse == null)
        assertEquals(false, dense.gravitySparse)
    }
}
