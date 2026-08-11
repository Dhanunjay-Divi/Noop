package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.BodyTemperatureRecord
import com.noop.data.ImportSummary
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
        assertTrue(ImportSummary("Health Connect", emptyMap(), message = "No data").succeeded)
        assertFalse(ImportSummary.failure("Health Connect", "Read failed").succeeded)
    }
}
