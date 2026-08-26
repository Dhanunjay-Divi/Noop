package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActiveZoneMinutesTest {
    private fun time(
        z1: Double = 0.0,
        z2: Double = 0.0,
        z3: Double = 0.0,
        z4: Double = 0.0,
        z5: Double = 0.0,
        below: Double = 0.0,
    ) = TimeInZone(listOf(z1, z2, z3, z4, z5), below)

    private fun hr(ts: Long, bpm: Int) = HrSample("test", ts, bpm)

    @Test
    fun moderateAndVigorousUseGuidelineCredit() {
        val result = ActiveZoneMinutesCalculator.minutes(
            timeInZone = time(z3 = 30.0 * 60.0, z4 = 15.0 * 60.0),
        )!!
        assertEquals(30.0, result.moderateMinutes, 1e-9)
        assertEquals(15.0, result.vigorousMinutes, 1e-9)
        assertEquals(60.0, result.creditedMinutes, 1e-9)
        assertEquals(45.0, result.observedMinutes, 1e-9)
    }

    @Test
    fun seventyFiveVigorousMeetsSameGuidelineAsOneFiftyModerate() {
        val vigorous = ActiveZoneMinutesCalculator.minutes(time(z4 = 75.0 * 60.0))!!
        val moderate = ActiveZoneMinutesCalculator.minutes(time(z3 = 150.0 * 60.0))!!
        assertTrue(vigorous.meetsWeeklyGuideline)
        assertTrue(moderate.meetsWeeklyGuideline)
        assertEquals(vigorous.creditedMinutes, moderate.creditedMinutes, 1e-9)
    }

    @Test
    fun lightZonesAreMeasuredButNotCredited() {
        val result = ActiveZoneMinutesCalculator.minutes(
            time(z1 = 60.0 * 60.0, z2 = 60.0 * 60.0),
        )!!
        assertEquals(0.0, result.creditedMinutes, 1e-9)
        assertEquals(120.0, result.observedMinutes, 1e-9)
        assertFalse(result.meetsWeeklyGuideline)
    }

    @Test
    fun noDataIsMissingRatherThanZero() {
        assertNull(ActiveZoneMinutesCalculator.minutes(null))
        assertNull(ActiveZoneMinutesCalculator.minutes(time()))
    }

    @Test
    fun partialWeekSkipsMissingPeriods() {
        val result = ActiveZoneMinutesCalculator.weekly(
            listOf(time(z3 = 30.0 * 60.0), null, time(z4 = 15.0 * 60.0)),
        )!!
        assertEquals(60.0, result.creditedMinutes, 1e-9)
        assertEquals(45.0, result.observedMinutes, 1e-9)
    }

    @Test
    fun targetProgressIsNotCapped() {
        val result = ActiveZoneMinutesCalculator.minutes(time(z3 = 300.0 * 60.0))!!
        assertEquals(2.0, result.targetFraction, 1e-9)
    }

    @Test
    fun zoneTwoIsNeverCredited() {
        val result = ActiveZoneMinutesCalculator.minutes(time(z2 = 100.0 * 60.0))!!
        assertEquals(0.0, result.creditedMinutes, 1e-9)
    }

    @Test
    fun rawHrCreditsOnlyBoundedObservedIntervals() {
        val moderate = (0L until 60L).map { hr(it, 150) }
        val vigorous = (60L..90L).map { hr(it, 170) }
        val result = ActiveZoneMinutesCalculator.minutes(
            hr = moderate + vigorous,
            zoneSet = HrZones.zones(maxHR = 200.0),
        )!!
        assertEquals(1.0, result.moderateMinutes, 1e-9)
        assertEquals(0.5, result.vigorousMinutes, 1e-9)
        assertEquals(2.0, result.creditedMinutes, 1e-9)
        assertEquals(1.5, result.observedMinutes, 1e-9)
    }

    @Test
    fun rawHrDoesNotFillLongGapOrInventTail() {
        val result = ActiveZoneMinutesCalculator.minutes(
            hr = listOf(hr(0, 170), hr(1, 170), hr(3_601, 170)),
            zoneSet = HrZones.zones(maxHR = 200.0),
        )!!
        assertEquals(1.0 / 60.0, result.vigorousMinutes, 1e-9)
        assertEquals(1.0 / 60.0, result.observedMinutes, 1e-9)
    }

    @Test
    fun disconnectedRawSamplesAreMissing() {
        assertNull(
            ActiveZoneMinutesCalculator.minutes(
                hr = listOf(hr(0, 170), hr(3_600, 170)),
                zoneSet = HrZones.zones(maxHR = 200.0),
            ),
        )
    }

    @Test
    fun corruptTimestampSpanAndWeeklyTargetStayMissing() {
        assertNull(
            ActiveZoneMinutesCalculator.minutes(
                hr = listOf(hr(Long.MIN_VALUE, 170), hr(Long.MAX_VALUE, 170)),
                zoneSet = HrZones.zones(maxHR = 200.0),
            ),
        )
        assertNull(
            ActiveZoneMinutesCalculator.minutes(
                timeInZone = time(z3 = 60.0),
                weeklyTarget = Double.NaN,
            ),
        )
        assertNull(
            ActiveZoneMinutesCalculator.minutes(
                timeInZone = time(z3 = 60.0),
                weeklyTarget = 0.0,
            ),
        )
    }

    @Test
    fun seriesProjectionPersistsMeasuredZeroAndCoverage() {
        val values = ActiveZoneMinutesCalculator.seriesValues(
            ActiveZoneMinutesCalculator.minutes(time(z1 = 600.0)),
        )
        assertEquals(0.0, values[ActiveZoneMinutesCalculator.MODERATE_SERIES_KEY]!!, 0.0)
        assertEquals(0.0, values[ActiveZoneMinutesCalculator.VIGOROUS_SERIES_KEY]!!, 0.0)
        assertEquals(0.0, values[ActiveZoneMinutesCalculator.CREDITED_SERIES_KEY]!!, 0.0)
        assertEquals(10.0, values[ActiveZoneMinutesCalculator.OBSERVED_SERIES_KEY]!!, 0.0)
        assertEquals(ActiveZoneMinutesCalculator.MANAGED_SERIES_KEYS, values.keys)
    }

    @Test
    fun corruptCoverageIsNotProjected() {
        assertTrue(ActiveZoneMinutesCalculator.seriesValues(null).isEmpty())
        assertTrue(
            ActiveZoneMinutesCalculator.seriesValues(
                ActiveZoneMinutes(1.0, 1.0, 150.0, Double.NaN),
            ).isEmpty(),
        )
    }
}
