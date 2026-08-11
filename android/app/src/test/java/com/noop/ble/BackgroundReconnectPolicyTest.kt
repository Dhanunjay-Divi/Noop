package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundReconnectPolicyTest {
    @Test
    fun reconnectRequiresEveryDurableGate() {
        assertFalse(BackgroundReconnectPolicy.decide(false, true, true).reconnect)
        assertFalse(BackgroundReconnectPolicy.decide(true, false, true).reconnect)
        assertFalse(BackgroundReconnectPolicy.decide(true, true, false).reconnect)
        assertTrue(BackgroundReconnectPolicy.decide(true, true, true).reconnect)
    }

    @Test
    fun bootReconnectNeverArmsRealtimeHr() {
        val allowed = BackgroundReconnectPolicy.decide(true, true, true)
        assertTrue(allowed.reconnect)
        assertFalse(allowed.armRealtime)
    }
}
