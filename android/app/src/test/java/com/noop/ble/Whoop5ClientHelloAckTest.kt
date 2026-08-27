package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Whoop5ClientHelloAckTest {
    @Test
    fun noOutstandingHelloDoesNotEstablishBond() {
        assertFalse(
            WhoopBleClient.shouldEstablishWhoop5Bond(
                DeviceFamily.WHOOP5,
                alreadyBonded = false,
                purpose = WhoopBleClient.WritePurpose.COMMAND,
                callbackMatchesCommandCharacteristic = true,
            ),
        )
    }

    @Test
    fun callbackFromAnotherCharacteristicDoesNotEstablishBond() {
        assertFalse(
            WhoopBleClient.shouldEstablishWhoop5Bond(
                DeviceFamily.WHOOP5,
                alreadyBonded = false,
                purpose = WhoopBleClient.WritePurpose.CLIENT_HELLO,
                callbackMatchesCommandCharacteristic = false,
            ),
        )
    }

    @Test
    fun ownOutstandingHelloEstablishesBond() {
        assertTrue(
            WhoopBleClient.shouldEstablishWhoop5Bond(
                DeviceFamily.WHOOP5,
                alreadyBonded = false,
                purpose = WhoopBleClient.WritePurpose.CLIENT_HELLO,
                callbackMatchesCommandCharacteristic = true,
            ),
        )
    }

    @Test
    fun alreadyBondedOrLegacyFamilyDoesNotReestablishBond() {
        assertFalse(
            WhoopBleClient.shouldEstablishWhoop5Bond(
                DeviceFamily.WHOOP5,
                alreadyBonded = true,
                purpose = WhoopBleClient.WritePurpose.CLIENT_HELLO,
                callbackMatchesCommandCharacteristic = true,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldEstablishWhoop5Bond(
                DeviceFamily.WHOOP4,
                alreadyBonded = false,
                purpose = WhoopBleClient.WritePurpose.CLIENT_HELLO,
                callbackMatchesCommandCharacteristic = true,
            ),
        )
    }
}
