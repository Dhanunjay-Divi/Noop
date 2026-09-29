package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SupplierPairingInputPolicyTest {
    @Test
    fun keepsAtMostFourAsciiDigits() {
        assertEquals("1234", supplierPairingPasswordInput("12345"))
    }

    @Test
    fun rejectsUnicodeDigitsAcceptedByGenericDigitPredicates() {
        assertEquals(
            "45",
            supplierPairingPasswordInput(
                "\u0661\u0662\u06F3\u096A4\uFF125",
            ),
        )
    }
}
