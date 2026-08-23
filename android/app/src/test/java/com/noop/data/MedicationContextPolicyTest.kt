package com.noop.data

import java.time.LocalDate
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MedicationContextPolicyTest {
    @Test fun recentStartOrDoseChangeIsContext() {
        val entries = listOf(MedicationEntry(name = "Example", changeDay = "2026-08-10"))
        assertTrue(
            MedicationContextPolicy.hasRecentChange(entries, LocalDate.parse("2026-08-23"))
        )
    }

    @Test fun stableFutureAndMalformedDatesAreNotRecent() {
        val entries = listOf(
            MedicationEntry(name = "Stable", changeDay = "2026-01-01"),
            MedicationEntry(name = "Future", changeDay = "2026-08-24"),
            MedicationEntry(name = "Malformed", changeDay = "2026-02-30"),
        )
        assertFalse(
            MedicationContextPolicy.hasRecentChange(entries, LocalDate.parse("2026-08-23"))
        )
    }

    @Test fun fourteenDayBoundaryIsInclusive() {
        val entries = listOf(MedicationEntry(name = "Example", changeDay = "2026-08-09"))
        assertTrue(
            MedicationContextPolicy.hasRecentChange(entries, LocalDate.parse("2026-08-23"))
        )
        assertFalse(
            MedicationContextPolicy.hasRecentChange(entries, LocalDate.parse("2026-08-24"))
        )
    }
}
