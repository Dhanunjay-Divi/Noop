package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SleepFormattingTest {
    @Test
    fun missingPercentUsesTheSharedMissingValue() {
        assertEquals(NoopDisplayFormat.MISSING, pctValue(null))
    }

    @Test
    fun unavailableTypicalComparisonUsesTheSharedMissingValue() {
        assertEquals(
            "vs typical ${NoopDisplayFormat.MISSING}",
            vsTypical(latest = null, typical = 80.0, suffix = "%"),
        )
        assertEquals(
            "vs typical ${NoopDisplayFormat.MISSING}",
            vsTypical(latest = 80.0, typical = null, suffix = "%"),
        )
        assertEquals(
            "vs typical ${NoopDisplayFormat.MISSING}",
            vsTypical(latest = 80.0, typical = 0.0, suffix = "%"),
        )
    }

    @Test
    fun availableValuesKeepTheirUnitsAndTrueMinus() {
        assertEquals("82%", pctValue(81.6))
        assertEquals("−4% vs typical", vsTypical(76.0, 80.0, "%"))
        assertEquals("+0.4 rpm vs typical", vsTypical(15.4, 15.0, " rpm", decimals = 1))
    }
}
