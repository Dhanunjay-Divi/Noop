package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HydrationAccessibilityContractTest {
    @Test
    fun heroDescriptionIncludesStateGoalAndProgress() {
        assertEquals(
            "Hydration today. Unavailable. Goal 3.2 litres.",
            hydrationHeroDescription(null, 3_200, "Unavailable"),
        )
        assertEquals(
            "Hydration today. 1.2 of 3.2 litres. 37 percent of goal.",
            hydrationHeroDescription(1_200.0, 3_200, "Not logged"),
        )
    }

    @Test
    fun historyDescriptionNamesLoggedAndMissingDays() {
        val description = hydrationHistoryDescription(
            listOf(
                "2026-09-07" to null,
                "2026-09-08" to 1_250.0,
            ),
            "Not logged",
        )

        assertTrue(description.contains("Monday: Not logged"))
        assertTrue(description.contains("Tuesday: 1.3 litres"))
    }
}
