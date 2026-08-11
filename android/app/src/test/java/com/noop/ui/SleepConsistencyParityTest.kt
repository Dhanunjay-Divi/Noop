package com.noop.ui

import com.noop.data.SleepSession
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class SleepConsistencyParityTest {
    private var savedTimeZone: TimeZone? = null

    @Before fun forceUtc() {
        savedTimeZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    @After fun restoreTimeZone() { savedTimeZone?.let(TimeZone::setDefault) }

    private fun ts(day: Int, hour: Int, minute: Int): Long = Calendar.getInstance(TimeZone.getTimeZone("UTC")).run {
        clear()
        set(2026, Calendar.JUNE, day, hour, minute, 0)
        timeInMillis / 1000L
    }

    private fun session(start: Long) = SleepSession("my-whoop", start, start + 8 * 3600)

    @Test fun onsetSpreadMatchesIosFormula() {
        val metric = consistencySeries(listOf(session(ts(1, 23, 0)), session(ts(2, 23, 30)), session(ts(3, 22, 30))))
        assertEquals(79.58758, metric.latest!!, 1e-4)
        assertEquals(1, metric.series.size)
    }

    @Test fun fewerThanThreeNightsIsUnavailable() {
        val metric = consistencySeries(listOf(session(ts(1, 23, 0)), session(ts(2, 23, 0))))
        assertNull(metric.latest)
        assertEquals(0, metric.series.size)
    }

    @Test fun editedEffectiveOnsetWins() {
        val edited = SleepSession(
            "my-whoop", ts(2, 21, 0), ts(3, 5, 0),
            startTsAdjusted = ts(2, 23, 0),
        )
        val metric = consistencySeries(listOf(session(ts(3, 23, 0)), edited, session(ts(1, 23, 0))))
        assertEquals(100.0, metric.latest!!, 1e-9)
    }
}
