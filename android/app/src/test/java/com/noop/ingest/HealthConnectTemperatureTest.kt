package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.BasalBodyTemperatureRecord
import androidx.health.connect.client.records.BodyTemperatureRecord
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectTemperatureTest {

    @Test fun pinnedSdkPermissionsIncludeBodyAndBasalTemperature() {
        val expected = setOf(
            HealthPermission.getReadPermission(BodyTemperatureRecord::class),
            HealthPermission.getReadPermission(BasalBodyTemperatureRecord::class),
        )
        assertEquals(expected, HealthConnectImporter.TEMPERATURE_PERMISSIONS)
        assertTrue(HealthConnectImporter.PERMISSIONS.containsAll(expected))
    }

    @Test fun reducerKeepsRecordKindsDistinctAndLatestReadingWins() {
        val fallback = ZoneId.of("America/New_York")
        val rows = HealthConnectImporter.temperatureSeriesRows(
            listOf(
                HealthConnectImporter.TemperatureObservation(
                    HealthConnectImporter.TemperatureKind.BODY,
                    // 00:00 on Aug 11 at the record's +02:00 offset, so both BODY
                    // observations occupy the same source-local civil day.
                    Instant.parse("2026-08-10T22:00:00Z"),
                    ZoneOffset.ofHours(2),
                    36.45,
                ),
                HealthConnectImporter.TemperatureObservation(
                    HealthConnectImporter.TemperatureKind.BODY,
                    Instant.parse("2026-08-10T23:30:00Z"),
                    ZoneOffset.ofHours(2),
                    37.04,
                ),
                HealthConnectImporter.TemperatureObservation(
                    HealthConnectImporter.TemperatureKind.BASAL_BODY,
                    Instant.parse("2026-08-11T06:30:00Z"),
                    ZoneOffset.UTC,
                    36.21,
                ),
            ),
            fallback,
        )

        assertEquals(2, rows.size)
        val byKey = rows.associateBy { it.key }
        assertEquals("2026-08-11", byKey.getValue(HealthConnectImporter.BODY_TEMPERATURE_KEY).day)
        assertEquals(37.04, byKey.getValue(HealthConnectImporter.BODY_TEMPERATURE_KEY).value, 1e-9)
        assertEquals("2026-08-11", byKey.getValue(HealthConnectImporter.BASAL_BODY_TEMPERATURE_KEY).day)
        assertEquals(36.21, byKey.getValue(HealthConnectImporter.BASAL_BODY_TEMPERATURE_KEY).value, 1e-9)
        assertTrue(rows.all { it.deviceId == HealthConnectImporter.DEVICE_ID })
    }

    @Test fun bodyTemperatureNeverMasqueradesAsSkinOrSleepingWristTemperature() {
        val rows = HealthConnectImporter.temperatureSeriesRows(
            listOf(
                HealthConnectImporter.TemperatureObservation(
                    HealthConnectImporter.TemperatureKind.BODY,
                    Instant.parse("2026-08-11T12:00:00Z"),
                    ZoneOffset.UTC,
                    36.8,
                ),
            ),
            ZoneId.of("UTC"),
        )
        val keys = rows.mapTo(hashSetOf()) { it.key }
        assertEquals(setOf(HealthConnectImporter.BODY_TEMPERATURE_KEY), keys)
        assertFalse("skin_temp" in keys)
        assertFalse("wrist_temp" in keys)
    }

    @Test fun nonFiniteTemperatureIsNotPersisted() {
        val rows = HealthConnectImporter.temperatureSeriesRows(
            listOf(
                HealthConnectImporter.TemperatureObservation(
                    HealthConnectImporter.TemperatureKind.BODY,
                    Instant.parse("2026-08-11T12:00:00Z"),
                    ZoneOffset.UTC,
                    Double.NaN,
                ),
            ),
            ZoneId.of("UTC"),
        )
        assertTrue(rows.isEmpty())
    }
}
