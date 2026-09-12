package com.noop.data

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HydrationEntryMigrationTest {
    @Test
    fun migrationIsAdditiveLocalOnlyAndFailClosedForLegacyEdges() {
        assertEquals(48, WhoopDatabase.MIGRATION_48_49.startVersion)
        assertEquals(49, WhoopDatabase.MIGRATION_48_49.endVersion)
        assertEquals(51, NOOP_DATABASE_SCHEMA_VERSION)

        val schemaSql = WhoopDatabase.HYDRATION_ENTRY_MIGRATION_SQL.joinToString("\n")
        val selectSql = WhoopDatabase.HYDRATION_ENTRY_LEGACY_SELECT_SQL
        val sql = listOf(
            schemaSql,
            selectSql,
            WhoopDatabase.HYDRATION_ENTRY_LEGACY_INSERT_SQL,
        ).joinToString("\n")
        assertTrue(sql.contains("CREATE TABLE IF NOT EXISTS `hydrationEntry`"))
        assertTrue(sql.contains("PRIMARY KEY(`id`)"))
        assertTrue(sql.contains("idx_hydrationEntry_device_day_loggedAt"))
        assertTrue(sql.contains("printf("))
        assertTrue(sql.contains("'00000000-0000-5000-8000-%012x'"))
        assertTrue(sql.contains("`deviceId` = '${HydrationEntryContract.SOURCE_ID}'"))
        assertTrue(sql.contains("`key` = '${HydrationEntryContract.METRIC_KEY}'"))
        assertTrue(sql.contains("`day` = date(`day`, '+0 days')"))
        assertTrue(sql.contains("`value` = CAST(`value` AS INTEGER)"))
        assertTrue(sql.contains("`value` <= ${HydrationEntryContract.MAX_DAY_ML}"))
        assertFalse(sql.contains("strftime('%s'"))
        assertFalse(sql.contains(WhoopRepository.HEALTH_CONNECT_SOURCE))
        assertFalse(sql.uppercase().contains("DROP TABLE"))
        assertFalse(sql.uppercase().contains("DELETE FROM"))
        assertFalse(sql.contains("managedDocument"))
        assertFalse(sql.contains("managedDirty"))
    }

    @Test
    fun legacyTimestampStaysAtLocalNoonAcrossExtremeUtcOffsets() {
        val day = LocalDate.parse("2026-09-08")
        val zones = listOf(
            ZoneOffset.ofHours(14),
            ZoneOffset.UTC,
            ZoneOffset.ofHours(-12),
        )

        zones.forEach { zone ->
            val loggedAt = requireNotNull(
                WhoopDatabase.legacyHydrationLoggedAt(day.toString(), zone),
            )
            val local = Instant.ofEpochSecond(loggedAt).atZone(zone)
            assertEquals("day must survive in $zone", day, local.toLocalDate())
            assertEquals("legacy entry must use a stable daytime anchor in $zone", LocalTime.NOON, local.toLocalTime())
        }
    }

    @Test
    fun skippedCivilDayRemainsScalarOnlyInsteadOfMovingToAnotherDay() {
        assertNull(
            WhoopDatabase.legacyHydrationLoggedAt(
                "2011-12-30",
                ZoneId.of("Pacific/Apia"),
            ),
        )
    }

    @Test
    fun projectionGuardAcceptsOnlyMatchingDurableRows() {
        val row = HydrationEntryRow(
            id = "719c47b0-7ed1-44a2-94b5-aa6b926e4d5b",
            deviceId = HydrationEntryContract.SOURCE_ID,
            day = "2026-09-10",
            amountML = 500,
            loggedAt = 1_789_000_000L,
        )

        assertEquals(0L, HydrationEntryContract.requireEditableProjection(null, emptyList()))
        assertEquals(0L, HydrationEntryContract.requireEditableProjection(0.0, emptyList()))
        assertEquals(500L, HydrationEntryContract.requireEditableProjection(500.0, listOf(row)))
        assertFails { HydrationEntryContract.requireEditableProjection(500.0, emptyList()) }
        assertFails { HydrationEntryContract.requireEditableProjection(500.5, emptyList()) }
        assertFails { HydrationEntryContract.requireEditableProjection(700.0, listOf(row)) }
    }

    private fun assertFails(block: () -> Unit) {
        var failed = false
        try {
            block()
        } catch (_: HydrationEntryIntegrityException) {
            failed = true
        }
        assertTrue("expected hydration integrity rejection", failed)
    }
}
