package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ForegroundRealtimeLeasePolicyTest {
    @Test
    fun defaultState_waitsForExplicitForegroundSignal() {
        val policy = ForegroundRealtimeLeasePolicy()
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.requestLease())
        assertFalse(policy.transportArmed)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.ARM, policy.setForeground(true))
    }

    @Test
    fun openingSurfaceWithoutExplicitLease_doesNotArm() {
        val policy = ForegroundRealtimeLeasePolicy(isForeground = true)
        assertFalse(policy.shouldArm)
        assertFalse(policy.transportArmed)
    }

    @Test
    fun firstLeaseArms_nestedLeasesBalanceOnLastRelease() {
        val policy = ForegroundRealtimeLeasePolicy(isForeground = true)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.ARM, policy.requestLease())
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.requestLease())
        assertEquals(2, policy.leaseCount)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.releaseLease())
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.DISARM, policy.releaseLease())
    }

    @Test
    fun backgroundDisarms_retainsIntent_foregroundRearmsExactlyOnce() {
        val policy = ForegroundRealtimeLeasePolicy(isForeground = true)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.ARM, policy.requestLease())
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.DISARM, policy.setForeground(false))
        assertEquals(1, policy.leaseCount)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.setForeground(false))
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.ARM, policy.setForeground(true))
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.setForeground(true))
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.DISARM, policy.releaseLease())
    }

    @Test
    fun leaseRequestedInBackground_waitsForForeground() {
        val policy = ForegroundRealtimeLeasePolicy(isForeground = false)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.requestLease())
        assertFalse(policy.transportArmed)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.ARM, policy.setForeground(true))
    }

    @Test
    fun extraRelease_clampsWithoutSpuriousEdge() {
        val policy = ForegroundRealtimeLeasePolicy(isForeground = true)
        assertEquals(ForegroundRealtimeLeasePolicy.Transition.NONE, policy.releaseLease())
        assertEquals(0, policy.leaseCount)
        assertFalse(policy.transportArmed)
    }
}
