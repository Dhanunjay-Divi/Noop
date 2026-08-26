package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the v18 -> v19 Room migration (#376): the Oura/WHOOP efficiency-unit HEAL, the byte-parity twin
 * of the Swift WhoopStore `v26-efficiency-heal` GRDB migration. UPDATE-only, NO schema change — divides
 * `sleepSession.efficiency` and `dailyMetric.efficiency` by 100 for legacy percentage-scale values.
 * The later generic-series omission is repaired in its own v33 -> v34 migration so this already-shipped
 * migration remains immutable.
 *
 * This JVM test pins the migration SQL as a fast contract check. Its instrumentation companion creates an
 * actual v33 Room database, executes v33 -> v34, validates the resulting schema, and queries the repaired
 * values. Unlike the additive migrations elsewhere in this suite (which assert the SQL is ONLY ALTER/CREATE,
 * never UPDATE/DELETE/INSERT), this migration is intentionally UPDATE-only with no schema mutation, so the
 * polarity of the "what's allowed" check is inverted here on purpose.
 */
class EfficiencyHealMigrationTest {

    @Test
    fun migration_versionPair_is18to19() {
        assertEquals(18, WhoopDatabase.MIGRATION_18_19.startVersion)
        assertEquals(19, WhoopDatabase.MIGRATION_18_19.endVersion)
    }

    @Test
    fun migration_healsBothTables_exactSql() {
        assertEquals(
            listOf(
                "UPDATE `sleepSession` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
                "UPDATE `dailyMetric` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
            ),
            WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_isUpdateOnly_noSchemaMutation() {
        // Opposite of the additive migrations' guard: this one must be ONLY an UPDATE (no ALTER/CREATE/
        // DROP/INSERT/DELETE — no schema change, no row added or removed, just an in-place value rescale).
        val sql = WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL
        assertEquals("one UPDATE per healed table", 2, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("must be an UPDATE, got: $s", up.startsWith("UPDATE"))
            for (banned in listOf("ALTER ", "CREATE ", "DROP ", "INSERT ", "DELETE ", "RENAME ")) {
                assertTrue("heal migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_targetsOnlySleepSessionAndDailyMetric() {
        val tables = WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL.map { sql ->
            sql.substringAfter("UPDATE `").substringBefore("`")
        }
        assertEquals(listOf("sleepSession", "dailyMetric"), tables)
    }

    @Test
    fun migration_thresholdAndDivisorMatchTheSwiftHeal() {
        // Same predicate as WhoopStore's v26-efficiency-heal (Database.swift): `> 1.5` / `/ 100.0`, not
        // deviceId-scoped, so both the Oura API importer's and the WHOOP CSV importer's percent-scale rows
        // are healed by the same UPDATE regardless of which strap/brand deviceId they were imported under.
        for (s in WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL) {
            assertTrue("must divide by exactly 100.0: $s", s.contains("/ 100.0"))
            assertTrue("must gate on > 1.5: $s", s.contains("> 1.5"))
            assertTrue("must not scope to a deviceId: $s", !s.uppercase().contains("DEVICEID"))
        }
    }

    @Test
    fun genericSeriesRepairUsesAnewIdempotentMigration() {
        assertEquals(33, WhoopDatabase.MIGRATION_33_34.startVersion)
        assertEquals(34, WhoopDatabase.MIGRATION_33_34.endVersion)
        val series = WhoopDatabase.METRIC_SERIES_EFFICIENCY_HEAL_MIGRATION_SQL
        assertTrue(series.contains("`key` = 'sleep_efficiency'"))
        assertTrue(series.contains("`value` > 1.0"))
        assertTrue(series.contains("`value` <= 100.0"))
        assertTrue(series.contains("/ 100.0"))
        assertTrue(!series.uppercase().contains("DEVICEID"))
    }

    @Test
    fun newMigrationAlsoRepairsOnlyEvidenceBackedLegacyImportValues() {
        val statements = WhoopDatabase.CSV_IMPORT_INTEGRITY_HEAL_MIGRATION_SQL
        assertEquals(4, statements.size)
        assertEquals(
            WhoopDatabase.METRIC_SERIES_EFFICIENCY_HEAL_MIGRATION_SQL,
            statements.first(),
        )
        assertTrue(statements[1].contains("`skinTempDevC` > 60.0"))
        assertTrue(statements[1].contains("`skinTempDevC` <= 140.0"))
        assertTrue(statements[2].contains("`key` = 'skin_temp'"))
        assertTrue(statements[3].contains("`m`.`key` = 'awake_min'"))
        assertTrue(statements[3].contains("ABS("))
        for (statement in statements.drop(1)) {
            assertTrue(statement.contains("`deviceId` LIKE 'my-whoop%'"))
        }
    }
}
