package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WhoopRegistryIdentityTest {

    @Test fun exactAndLegacyLabelsResolveWithoutSubstringGuessing() {
        val fiveLabels = listOf(
            "5.0", "WHOOP 5.0", "5.0 MG", "WHOOP 5.0 / MG", "WHOOP MG", "MG",
        )
        fiveLabels.forEach {
            assertEquals(it, DeviceFamily.WHOOP5, WhoopRegistryIdentity.positivelyIdentifiedFamily(it))
        }
        assertEquals(DeviceFamily.WHOOP4, WhoopRegistryIdentity.positivelyIdentifiedFamily("WHOOP 4.0"))
        assertNull(WhoopRegistryIdentity.positivelyIdentifiedFamily("WHOOP"))
        assertNull(WhoopRegistryIdentity.positivelyIdentifiedFamily("serial-5-unknown"))
    }

    @Test fun connectedFiveServiceRepairsStaleFourButDoesNotEraseExactMg() {
        assertEquals(
            WhoopRegistryIdentity.WHOOP_FIVE_FAMILY,
            WhoopRegistryIdentity.modelUpdateFromService("WHOOP 4.0", DeviceFamily.WHOOP5),
        )
        assertNull(
            WhoopRegistryIdentity.modelUpdateFromService("WHOOP MG", DeviceFamily.WHOOP5),
        )
        assertNull(
            WhoopRegistryIdentity.modelUpdateFromService("WHOOP 5.0", DeviceFamily.WHOOP5),
        )
    }

    @Test fun disWritesOnlyPositiveExactIdentity() {
        assertEquals("WHOOP MG", WhoopRegistryIdentity.exactModelFromDis(Whoop5Variant.MG))
        assertEquals("WHOOP 5.0", WhoopRegistryIdentity.exactModelFromDis(Whoop5Variant.FIVE_ZERO))
        assertNull(WhoopRegistryIdentity.exactModelFromDis(Whoop5Variant.UNKNOWN))
    }
}
