package com.noop.brand

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CustomerFacingBrandTest {

    @Test
    fun dynamicCustomerTextRemovesVendorWordingAndLegacyIds() {
        val visible = CustomerFacingBrand.text(
            "WHOOP 5/MG · WHOOP import · my-whoop · whoop_live_hr_in_adv_ind_pkt · " +
                "whoop5-C0FF · OpenWhoop",
        )

        assertFalse(visible.contains("whoop", ignoreCase = true))
        assertTrue(visible.contains("newer band"))
        assertTrue(visible.contains("wearable import"))
        assertTrue(visible.contains("band broadcast setting"))
        assertTrue(visible.contains("band-5-C0FF"))
        assertTrue(visible.contains("NOOP legacy storage"))
    }

    @Test
    fun userAssignedAndAdvertisedNamesAreSafeToRender() {
        assertEquals(
            "My compatible band sensor",
            CustomerFacingBrand.text("My WHOOP sensor"),
        )
    }

    @Test
    fun noopAndUnrelatedProviderNamesRemainUnchanged() {
        assertEquals(
            "Noop Band · Apple Health · Garmin",
            CustomerFacingBrand.text("Noop Band · Apple Health · Garmin"),
        )
    }

}
