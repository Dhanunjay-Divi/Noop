package com.noop.managed

import androidx.work.NetworkType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedCloudSchedulerTest {
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
}
