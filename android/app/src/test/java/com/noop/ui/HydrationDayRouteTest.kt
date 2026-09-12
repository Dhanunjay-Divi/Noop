package com.noop.ui

import com.noop.analytics.HydrationStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HydrationDayRouteTest {
    @Test
    fun selectedDayRouteRoundTripsAndInvalidInputFailsClosed() {
        assertEquals("hydration/2026-09-09", hydrationRoute("2026-09-09"))
        assertEquals(
            "2026-09-09",
            hydrationRouteDay("2026-09-09"),
        )
        assertEquals(null, hydrationRouteDay("not-a-day"))
        assertEquals(null, hydrationRouteDay(null))
        assertEquals("Today", hydrationDayTitle("2026-09-11", "2026-09-11"))
        assertEquals("Wed, 9 Sep", hydrationDayTitle("2026-09-09", "2026-09-11"))
    }

    @Test
    fun detailStateNeverCarriesAnotherDaysValueAcrossNavigation() {
        val prior = HydrationDetailReadState(
            dayKey = "2026-09-09",
            reading = HydrationStore.Reading(
                valueMl = 500.0,
                source = HydrationStore.ReadingSource.NOOP,
                noopMl = 500.0,
                healthConnectMl = 0.0,
            ),
            history = listOf("2026-09-09" to 500.0),
            entries = listOf(
                HydrationStore.Entry(
                    id = "3d73552f-bc81-4ada-b9a7-6b1cc6bb36a0",
                    day = "2026-09-09",
                    amountML = 500,
                    loggedAt = 1_788_912_000L,
                ),
            ),
            status = HydrationDetailReadStatus.READY,
        )

        val replacement = hydrationDetailStateForDay(prior, "2026-09-10")

        assertEquals("2026-09-10", replacement.dayKey)
        assertEquals(HydrationDetailReadStatus.LOADING, replacement.status)
        assertEquals(null, replacement.reading)
        assertTrue(replacement.history.isEmpty())
        assertTrue(replacement.entries.isEmpty())
    }

    @Test
    fun firstDetailFailureIsUnavailableButSameDayConfirmedStateCanRemainVisible() {
        val unavailable = hydrationDetailStateAfterFailure(null, "2026-09-10")
        assertEquals(HydrationDetailReadStatus.UNAVAILABLE, unavailable.status)

        val confirmed = HydrationDetailReadState(
            dayKey = "2026-09-10",
            reading = HydrationStore.Reading(
                valueMl = 237.0,
                source = HydrationStore.ReadingSource.NOOP,
                noopMl = 237.0,
                healthConnectMl = 0.0,
            ),
            history = listOf("2026-09-10" to 237.0),
            entries = emptyList(),
            status = HydrationDetailReadStatus.READY,
        )
        assertEquals(
            confirmed,
            hydrationDetailStateAfterFailure(confirmed, "2026-09-10"),
        )
        assertEquals(
            HydrationDetailReadStatus.UNAVAILABLE,
            hydrationDetailStateAfterFailure(confirmed, "2026-09-11").status,
        )

        val previouslyMissing = confirmed.copy(reading = null, history = emptyList())
        assertEquals(
            HydrationDetailReadStatus.UNAVAILABLE,
            hydrationDetailStateAfterFailure(previouslyMissing, "2026-09-10").status,
        )
    }
}
