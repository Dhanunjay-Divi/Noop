package com.noop.managed

import androidx.work.NetworkType
import com.noop.ui.Terms
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManagedCloudSchedulerTest {
    @Test
    fun managedRuntimeRequiresTheExactCurrentTermsVersion() {
        assertTrue(ManagedRuntimeGate.acceptsCurrentTerms(Terms.CURRENT_VERSION))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms(null))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms(""))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms("2.4"))
    }

    @Test
    fun backgroundBackupWaitsForNetworkBatteryAndStorageHeadroom() {
        val constraints = ManagedCloudScheduler.constraints

        assertEquals(NetworkType.CONNECTED, constraints.requiredNetworkType)
        assertTrue(constraints.requiresBatteryNotLow())
        assertTrue(constraints.requiresStorageNotLow())
    }

    @Test
    fun successfulPartialPassContinuesWithoutEnteringFailureBackoff() {
        assertTrue(ManagedCloudScheduler.successfulPassNeedsContinuation(hasMore = true))
        assertEquals(
            false,
            ManagedCloudScheduler.successfulPassNeedsContinuation(hasMore = false),
        )
    }

    @Test
    fun urgentSafetyCatchUpWaitsOnlyForNetwork() {
        val constraints = ManagedCloudScheduler.urgentNetworkConstraints

        assertEquals(NetworkType.CONNECTED, constraints.requiredNetworkType)
        assertFalse(constraints.requiresBatteryNotLow())
        assertFalse(constraints.requiresStorageNotLow())
    }

    @Test
    fun safetyPushWorkIdentityIsStableAndStrict() {
        val incidentId = UUID.fromString(
            "00000000-0000-0000-0000-000000000301",
        )

        assertEquals(
            "noop_managed_safety_push_v1:$incidentId",
            ManagedCloudScheduler.safetyPushWorkName(incidentId),
        )
        assertEquals(
            incidentId,
            ManagedCloudScheduler.safetyPushIncidentId(incidentId.toString()),
        )
        assertNull(ManagedCloudScheduler.safetyPushIncidentId("not-a-uuid"))
        assertNull(ManagedCloudScheduler.safetyPushIncidentId(null))
    }
}
