package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BandOrderLinkTest {
    @Test
    fun orderUrlRequiresPublicHttpsWithoutCredentials() {
        assertEquals(
            "https://shop.example.com/band",
            validatedBandOrderUrl(" https://shop.example.com/band "),
        )

        listOf(
            null,
            "",
            "\$(NOOP_BAND_ORDER_URL)",
            "http://shop.example.com/band",
            "https://user:secret@shop.example.com/band",
            "https:///band",
        ).forEach { rejected ->
            assertNull(rejected, validatedBandOrderUrl(rejected))
        }
    }
}
