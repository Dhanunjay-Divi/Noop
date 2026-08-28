package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class FitnessAgePresentationTest {
    @Test
    fun continuousYearsArePresentedAsNearestExplicitMonth() {
        assertEquals(
            FitnessAgeParts(totalMonths = 287, years = 23, months = 11),
            FitnessAgePresentation.parts(23.9),
        )
        assertEquals(
            "23.11",
            FitnessAgePresentation.value(23.0 + 11.0 / 12.0),
        )
        assertEquals("23.9", FitnessAgePresentation.value(23.75))
        assertEquals(
            "23 yr 11 mo",
            FitnessAgePresentation.spokenValue(23.0 + 11.0 / 12.0),
        )
    }

    @Test
    fun comparisonsAndWeeklyProgressRetainSubYearChanges() {
        assertEquals(
            "6 mo younger than your profile age",
            FitnessAgePresentation.comparison(29.5, 30),
        )
        assertEquals(
            "3 mo younger this week",
            FitnessAgePresentation.weeklyProgress(current = 29.5, previous = 29.75),
        )
        assertEquals(
            "2 mo older this week",
            FitnessAgePresentation.weeklyProgress(
                current = 29.0 + 2.0 / 12.0,
                previous = 29.0,
            ),
        )
    }
}
