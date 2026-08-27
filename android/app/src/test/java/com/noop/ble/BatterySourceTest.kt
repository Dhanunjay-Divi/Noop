package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Test

class BatterySourceTest {
    @Test
    fun unresolvedFamilyDefersRegardlessOfStaleValue() {
        assertEquals(BatterySource.DEFER, batterySource(false, DeviceFamily.WHOOP4))
        assertEquals(BatterySource.DEFER, batterySource(false, DeviceFamily.WHOOP5))
    }

    @Test
    fun establishedLegacyBandUsesItsCustomBatteryCommand() {
        assertEquals(
            BatterySource.CUSTOM_COMMAND,
            batterySource(true, DeviceFamily.WHOOP4),
        )
    }

    @Test
    fun establishedNewerBandUsesTheStandardCharacteristic() {
        assertEquals(
            BatterySource.STANDARD_CHARACTERISTIC,
            batterySource(true, DeviceFamily.WHOOP5),
        )
    }
}
