package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HydrationRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectHydrationTest {
    @Test
    fun hydrationIsRequestedAndOwnsOnlyItsMetricSeriesKey() {
        val permission = HealthPermission.getReadPermission(HydrationRecord::class)
        val scope = HealthConnectImporter.projectionScope(setOf(permission))

        assertTrue(HydrationRecord::class in HealthConnectImporter.READ_RECORDS)
        assertTrue(permission in HealthConnectImporter.PERMISSIONS)
        assertTrue(scope.hydration)
        assertEquals(setOf("hydration"), scope.seriesKeys)
    }

    @Test
    fun mirroredWriterTotalsUseTheLargestSourceRatherThanTheirSum() {
        assertEquals(
            1_250.0,
            HealthConnectImporter.observedHydrationML(
                mapOf("phone" to 1_250.0, "bottle-relay" to 1_000.0),
            )!!,
            0.0,
        )
    }

    @Test
    fun missingOrInvalidIntakeDoesNotCreateAReading() {
        assertNull(HealthConnectImporter.observedHydrationML(emptyMap()))
        assertNull(HealthConnectImporter.observedHydrationML(mapOf("writer" to Double.NaN)))
        assertNull(HealthConnectImporter.observedHydrationML(mapOf("writer" to 0.0)))
    }
}
