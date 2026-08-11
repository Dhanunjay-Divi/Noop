package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

/** #1002/#1003: Health Connect day keys use a record's own offset, with a DST-safe region fallback. */
class HealthConnectZoneOffsetTest {
    private val london = ZoneId.of("Europe/London")
    private val tokyo = ZoneOffset.ofHours(9)

    @Test
    fun regionFallbackAppliesHistoricalDstRulesAtTheRecordInstant() {
        val winter = Instant.parse("2026-01-15T23:30:00Z")
        val summer = Instant.parse("2026-07-15T23:30:00Z")

        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(winter, null, london))
        assertEquals("2026-07-16", HealthConnectImporter.localDayKey(summer, null, london))
    }

    @Test
    fun recordOffsetPreservesTheCivilDayAcrossPhoneRelocation() {
        val recordedInTokyo = Instant.parse("2026-01-15T16:30:00Z") // Jan 16, 01:30 +09:00
        val sydney = ZoneId.of("Australia/Sydney")

        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(recordedInTokyo, tokyo, london))
        assertEquals(
            HealthConnectImporter.localDayKey(recordedInTokyo, tokyo, london),
            HealthConnectImporter.localDayKey(recordedInTokyo, tokyo, sydney),
        )
        // Without a record offset, the phone's current zone is deliberately the fallback.
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(recordedInTokyo, null, london))
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(recordedInTokyo, null, sydney))
    }

    @Test
    fun westernRecordOffsetCanKeepAnInstantOnThePreviousDay() {
        val instant = Instant.parse("2026-01-16T02:00:00Z")

        assertEquals(
            "2026-01-15",
            HealthConnectImporter.localDayKey(instant, ZoneOffset.ofHours(-8), london),
        )
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(instant, null, london))
    }

    @Test
    fun explicitOffsetOnlyChangesKeysAtARealCivilDayBoundary() {
        val midday = Instant.parse("2026-01-15T12:00:00Z")

        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(midday, null, london))
        assertEquals(
            "2026-01-15",
            HealthConnectImporter.localDayKey(midday, ZoneOffset.UTC, london),
        )
    }
}
