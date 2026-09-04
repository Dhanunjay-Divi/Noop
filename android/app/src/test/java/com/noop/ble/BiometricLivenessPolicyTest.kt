package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Test

class BiometricLivenessPolicyTest {

    @Test
    fun quietStreamRearmsBeforeReconnect() {
        assertEquals(
            BiometricLivenessAction.REARM_NOTIFICATIONS,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP4,
                millisSinceBiometric = 600_000L,
                notificationsRearmed = false,
                millisSinceWristOff = null,
            ),
        )
        assertEquals(
            BiometricLivenessAction.RECONNECT,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP4,
                millisSinceBiometric = 600_000L,
                notificationsRearmed = true,
                millisSinceWristOff = null,
            ),
        )
    }

    @Test
    fun batteryTrafficCannotMaskStaleBiometrics() {
        val now = 601_000L
        val lastBiometric = 0L
        val lastTransportAfterBatteryRead = 600_000L
        assertEquals(1_000L, now - lastTransportAfterBatteryRead)
        assertEquals(
            BiometricLivenessAction.RECONNECT,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP5,
                millisSinceBiometric = now - lastBiometric,
                notificationsRearmed = true,
                millisSinceWristOff = null,
            ),
        )
    }

    @Test
    fun whoop5UsesLongerFuseThanWhoop4() {
        assertEquals(
            BiometricLivenessAction.RECONNECT,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP4,
                millisSinceBiometric = 121_000L,
                notificationsRearmed = true,
                millisSinceWristOff = null,
            ),
        )
        assertEquals(
            BiometricLivenessAction.NONE,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP5,
                millisSinceBiometric = 121_000L,
                notificationsRearmed = true,
                millisSinceWristOff = null,
            ),
        )
    }

    @Test
    fun freshWristOffSuppressesReconnectButNotInitialRearm() {
        assertEquals(
            BiometricLivenessAction.REARM_NOTIFICATIONS,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP5,
                millisSinceBiometric = 601_000L,
                notificationsRearmed = false,
                millisSinceWristOff = 60_000L,
            ),
        )
        assertEquals(
            BiometricLivenessAction.NONE,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP5,
                millisSinceBiometric = 601_000L,
                notificationsRearmed = true,
                millisSinceWristOff = 60_000L,
            ),
        )
    }

    @Test
    fun staleWristOffCannotSuppressReconnectIndefinitely() {
        assertEquals(
            BiometricLivenessAction.RECONNECT,
            BiometricLivenessPolicy.action(
                family = DeviceFamily.WHOOP5,
                millisSinceBiometric = 601_000L,
                notificationsRearmed = true,
                millisSinceWristOff = BiometricLivenessPolicy.WRIST_OFF_FRESH_MS + 1L,
            ),
        )
    }
}
