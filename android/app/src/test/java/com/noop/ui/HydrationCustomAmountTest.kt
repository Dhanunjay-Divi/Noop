package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Custom-amount parse tests (#798) - the gate behind the Hydration "Custom amount" dialog's Log button.
 * The field accepts any whole ml in 1..3000. Invalid or out-of-range input remains visible for correction,
 * shows validation, and keeps confirmation disabled instead of silently changing the recorded amount.
 */
class HydrationCustomAmountTest {

    @Test fun parsesAPlainAmount() {
        assertEquals(250, parseCustomHydrationMl("250"))
        assertEquals(1, parseCustomHydrationMl("1"))
    }

    @Test fun trimsSurroundingWhitespace() {
        assertEquals(500, parseCustomHydrationMl("  500 "))
    }

    @Test fun rejectsBlankAndNonNumeric() {
        assertNull(parseCustomHydrationMl(""))
        assertNull(parseCustomHydrationMl("   "))
        assertNull(parseCustomHydrationMl("abc"))
        assertNull(parseCustomHydrationMl("12.5"))   // not a whole-ml integer
    }

    @Test fun rejectsZeroAndNegative() {
        assertNull(parseCustomHydrationMl("0"))
        assertNull(parseCustomHydrationMl("-100"))
    }

    @Test fun rejectsInputAboveTheCapWithoutChangingIt() {
        assertEquals(3000, parseCustomHydrationMl("3000"))
        assertNull(parseCustomHydrationMl("3001"))
        assertNull(parseCustomHydrationMl("9999"))

        val state = customHydrationInputState("9999")
        assertNull(state.amountMl)
        assertTrue(state.showValidation)
        assertFalse(state.canConfirm)
    }

    @Test fun validInputClearsValidationAndEnablesConfirmation() {
        val state = customHydrationInputState("2750")

        assertEquals(2750, state.amountMl)
        assertFalse(state.showValidation)
        assertTrue(state.canConfirm)
    }
}
