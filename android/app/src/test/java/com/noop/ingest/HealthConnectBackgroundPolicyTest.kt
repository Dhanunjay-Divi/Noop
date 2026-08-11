package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.BodyTemperatureRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.HeartRateRecord
import com.noop.data.ImportSummary
import com.noop.data.importCompletedSuccessfully
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectBackgroundPolicyTest {
    private val bodyPermission = HealthPermission.getReadPermission(BodyTemperatureRecord::class)
    private val background = HealthConnectBackgroundPolicy.BACKGROUND_PERMISSION

    @Test fun androidThirteenAndEarlyAndroidFourteenStayForegroundOnly() {
        val granted = setOf(bodyPermission)
        assertFalse(HealthConnectBackgroundPolicy.supportsBackground(33))
        assertTrue(HealthConnectBackgroundPolicy.missingPermissionsForAutoSync(33, granted).isEmpty())
        assertFalse(HealthConnectBackgroundPolicy.canRunInBackground(33, granted + background))
        assertFalse(HealthConnectBackgroundPolicy.supportsBackground(34, android14Extension = 12))
        assertTrue(
            HealthConnectBackgroundPolicy.missingPermissionsForAutoSync(
                34,
                granted,
                android14Extension = 12,
            ).isEmpty(),
        )
    }

    @Test fun androidFourteenExtensionThirteenRequestsAndRequiresBackgroundGrant() {
        val missing = HealthConnectBackgroundPolicy.missingPermissionsForAutoSync(
            34,
            setOf(bodyPermission),
            android14Extension = 13,
        )
        assertEquals(setOf(background), missing)
        assertFalse(
            HealthConnectBackgroundPolicy.canRunInBackground(
                34,
                setOf(bodyPermission),
                android14Extension = 13,
            ),
        )
        assertTrue(
            HealthConnectBackgroundPolicy.canRunInBackground(
                34,
                setOf(bodyPermission, background),
                android14Extension = 13,
            ),
        )
    }

    @Test fun androidFifteenSupportsBackgroundWithoutAnExtensionGate() {
        assertTrue(HealthConnectBackgroundPolicy.supportsBackground(35))
    }

    @Test fun partialDataPermissionIsEnoughAndNeverForcesOtherHealthTypes() {
        val missing = HealthConnectBackgroundPolicy.missingPermissionsForAutoSync(
            35,
            setOf(bodyPermission, background),
        )
        assertTrue(missing.isEmpty())
    }

    @Test fun projectionScopeKeepsWorkoutEnrichmentPermissionsIndependent() {
        val scope = HealthConnectImporter.projectionScope(
            setOf(
                HealthPermission.getReadPermission(HeartRateRecord::class),
                HealthPermission.getReadPermission(DistanceRecord::class),
            ),
        )

        assertTrue(scope.heartRate)
        assertTrue(scope.distance)
        assertFalse(scope.activeCalories)
        assertFalse(scope.totalCalories)
        assertFalse(scope.exercise)
    }

    @Test fun noDataGrantRequestsConfiguredTypesPlusBackgroundWhenFeatureExists() {
        val missing = HealthConnectBackgroundPolicy.missingPermissionsForAutoSync(35, emptySet())
        assertTrue(bodyPermission in missing)
        assertTrue(background in missing)
        assertTrue(HealthConnectImporter.PERMISSIONS.all { it in missing })
    }

    @Test fun intervalIsAllowlisted() {
        assertEquals(6L, HealthConnectBackgroundPolicy.intervalHours(6))
        assertEquals(12L, HealthConnectBackgroundPolicy.intervalHours(12))
        assertEquals(24L, HealthConnectBackgroundPolicy.intervalHours(24))
        assertEquals(12L, HealthConnectBackgroundPolicy.intervalHours(1))
    }

    @Test fun importSummarySeparatesEmptySuccessFromFailure() {
        val emptySuccess = ImportSummary("Health Connect", emptyMap(), message = "No data")
        val explicitFailure = ImportSummary.failure("Health Connect", "Read failed")

        assertTrue(emptySuccess.succeeded)
        assertFalse(explicitFailure.succeeded)
        assertTrue(importCompletedSuccessfully(Result.success(emptySuccess)))
        assertFalse(importCompletedSuccessfully(Result.success(explicitFailure)))
        assertFalse(importCompletedSuccessfully(Result.failure(IllegalStateException("provider failed"))))
    }

    @Test fun recordTypeReadCountsSeparateCompletePartialAndFailedReads() {
        assertEquals(HealthConnectReadCounts(0, 0, 0), healthConnectReadCounts(emptyList()))
        assertEquals(HealthConnectReadCounts(2, 2, 0), healthConnectReadCounts(listOf(true, true)))
        assertEquals(HealthConnectReadCounts(3, 2, 1), healthConnectReadCounts(listOf(true, false, true)))
        assertEquals(HealthConnectReadCounts(2, 0, 2), healthConnectReadCounts(listOf(false, false)))
    }

    @Test fun partialReadMessageIsExplicitAndSummaryRetainsCounts() {
        val counts = healthConnectReadCounts(listOf(true, false, true))
        val summary = ImportSummary(
            source = "Health Connect",
            counts = emptyMap(),
            message = healthConnectImportMessage("No Health Connect data found to import.", counts),
            recordTypesAttempted = counts.attempted,
            recordTypesSucceeded = counts.succeeded,
            recordTypesFailed = counts.failed,
        )

        assertTrue(summary.succeeded)
        assertEquals(3, summary.recordTypesAttempted)
        assertEquals(2, summary.recordTypesSucceeded)
        assertEquals(1, summary.recordTypesFailed)
        assertTrue(summary.message.contains("2 of 3 granted data types"))
        assertTrue(summary.message.contains("1 failed"))
    }
}
