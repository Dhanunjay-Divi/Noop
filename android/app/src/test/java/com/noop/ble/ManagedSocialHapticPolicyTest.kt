package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSocialHapticPolicyTest {
    @Test
    fun pokeRequiresConnectedEncryptedBondAndWristWear() {
        val eligible = LiveState(
            connected = true,
            bonded = true,
            encryptedBond = true,
            worn = true,
        )

        assertTrue(ManagedSocialHapticPolicy.isEligible(eligible))
        assertFalse(ManagedSocialHapticPolicy.isEligible(eligible.copy(connected = false)))
        assertFalse(ManagedSocialHapticPolicy.isEligible(eligible.copy(bonded = false)))
        assertFalse(ManagedSocialHapticPolicy.isEligible(eligible.copy(encryptedBond = false)))
        assertFalse(ManagedSocialHapticPolicy.isEligible(eligible.copy(worn = false)))
    }
}
