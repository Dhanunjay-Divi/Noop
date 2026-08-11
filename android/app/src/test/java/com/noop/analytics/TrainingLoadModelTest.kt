package com.noop.analytics

import java.time.LocalDate
import kotlin.math.exp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrainingLoadModelTest {
    private fun day(offset: Int): String = LocalDate.of(2024, 1, 1).plusDays(offset.toLong()).toString()

    private fun entries(count: Int, load: (Int) -> Double): List<TrainingLoadModel.Entry> =
        (0 until count).map { TrainingLoadModel.Entry(day(it), load(it)) }

    @Test
    fun aggregationIsAdditiveAndRejectsInvalidInputs() {
        val result = TrainingLoadModel.aggregate(
            listOf(
                TrainingLoadModel.Entry("2024-01-01", 12.0),
                TrainingLoadModel.Entry("2024-01-01", 8.0),
                TrainingLoadModel.Entry("2024-01-02", 0.0),
                TrainingLoadModel.Entry("2024-02-30", 5.0),
                TrainingLoadModel.Entry("2024-01-03", -1.0),
                TrainingLoadModel.Entry("2024-01-04", Double.NaN),
                TrainingLoadModel.Entry("2024-01-05", Double.MAX_VALUE),
                TrainingLoadModel.Entry("2024-01-05", Double.MAX_VALUE),
            )
        )

        assertEquals(
            listOf(
                TrainingLoadModel.DailyLoad("2024-01-01", 20.0),
                TrainingLoadModel.DailyLoad("2024-01-02", 0.0),
                TrainingLoadModel.DailyLoad("2024-01-05", Double.MAX_VALUE),
            ),
            result.days,
        )
        assertEquals(4, result.rejectedEntryCount)
    }

    @Test
    fun steadyLoadConvergesAndTsbIsExactlyCtlMinusAtl() {
        val latest = TrainingLoadModel.evaluate(entries(60) { 50.0 }).latest!!

        assertEquals(50.0, latest.atl!!, 1e-12)
        assertEquals(50.0, latest.ctl!!, 1e-12)
        assertEquals(latest.ctl!! - latest.atl!!, latest.tsb!!, 1e-12)
        assertEquals(TrainingLoadModel.Quality.OBSERVED, latest.quality)
        assertEquals(TrainingLoadModel.RampDirection.STEADY, latest.rampDirection)
        assertEquals(1.0, latest.observedCoverage, 1e-12)
        assertTrue(latest.interpretation.contains("not a fitness or fatigue measurement"))
    }

    @Test
    fun coldStartAbstainsThenHardDayRaisesAtlMoreThanCtl() {
        val result = TrainingLoadModel.evaluate(entries(14) { if (it == 13) 20.0 else 10.0 })

        assertNull(result.points[12].atl)
        assertNull(result.points[12].ctl)
        val latest = result.latest!!
        val expectedAtl = 10 + (1 - exp(-1.0 / 7.0)) * 10
        val expectedCtl = 10 + (1 - exp(-1.0 / 42.0)) * 10
        assertEquals(expectedAtl, latest.atl!!, 1e-12)
        assertEquals(expectedCtl, latest.ctl!!, 1e-12)
        assertEquals(expectedCtl - expectedAtl, latest.tsb!!, 1e-12)
        assertTrue(latest.tsb!! < 0)
        assertEquals(80.0, latest.currentRampWindowLoad!!, 0.0)
        assertEquals(70.0, latest.previousRampWindowLoad!!, 0.0)
        assertEquals(10.0, latest.rampChange!!, 0.0)
        assertEquals(1.0 / 7.0, latest.rampChangeFraction!!, 1e-12)
        assertEquals(TrainingLoadModel.RampDirection.BUILDING, latest.rampDirection)
        assertEquals(TrainingLoadModel.Quality.PROVISIONAL, latest.quality)
    }

    @Test
    fun strictMissingDayAbstainsAndRestartsWarmup() {
        val inputs = entries(14) { 10.0 }.toMutableList()
        inputs += TrainingLoadModel.Entry(day(15), 10.0)
        val result = TrainingLoadModel.evaluate(inputs)

        assertEquals(day(14), result.points[14].day)
        assertEquals(TrainingLoadModel.DaySource.MISSING, result.points[14].source)
        assertNull(result.points[14].effectiveLoad)
        assertNull(result.points[14].atl)
        val latest = result.latest!!
        assertEquals(TrainingLoadModel.DaySource.OBSERVED, latest.source)
        assertEquals(1, latest.consecutiveHistoryDays)
        assertNull(latest.atl)
        assertEquals(TrainingLoadModel.RampDirection.UNAVAILABLE, latest.rampDirection)
        assertTrue(latest.interpretation.contains("1 of 14"))
    }

    @Test
    fun assumeRestIsExplicitAndKeepsEstimateMarked() {
        val inputs = entries(20) { 10.0 }.filter { it.day != day(14) }
        val configuration = TrainingLoadModel.Configuration(
            missingDayPolicy = TrainingLoadModel.MissingDayPolicy.ASSUME_REST,
        )
        val result = TrainingLoadModel.evaluate(inputs, configuration)

        val gap = result.points[14]
        assertEquals(TrainingLoadModel.DaySource.ASSUMED_REST, gap.source)
        assertEquals(0.0, gap.effectiveLoad!!, 0.0)
        assertNotNull(gap.atl)
        val latest = result.latest!!
        assertEquals(TrainingLoadModel.Quality.ESTIMATED, latest.quality)
        assertEquals(1, latest.assumedRestDaysInWindow)
        assertEquals(1, latest.assumedRestDaysInModelHistory)
        assertEquals(19.0 / 20.0, latest.observedCoverage, 1e-12)
        assertTrue(latest.interpretation.contains("unobserved day treated as rest"))
    }

    @Test
    fun explicitZeroIsObservedRestNotMissingData() {
        val result = TrainingLoadModel.evaluate(
            entries(20) { if (it == 14) 0.0 else 10.0 },
            TrainingLoadModel.Configuration(
                missingDayPolicy = TrainingLoadModel.MissingDayPolicy.ASSUME_REST,
            ),
        )

        assertEquals(TrainingLoadModel.DaySource.OBSERVED, result.points[14].source)
        assertEquals(0.0, result.points[14].observedLoad!!, 0.0)
        assertEquals(0, result.latest?.assumedRestDaysInWindow)
        assertEquals(TrainingLoadModel.Quality.PROVISIONAL, result.latest?.quality)
        assertEquals(1.0, result.latest?.observedCoverage!!, 0.0)
    }

    @Test
    fun oldAssumptionDoesNotBecomeObservedJustBecauseCoverageWindowMoved() {
        val inputs = entries(60) { 10.0 }.filter { it.day != day(5) }
        val result = TrainingLoadModel.evaluate(
            inputs,
            TrainingLoadModel.Configuration(
                missingDayPolicy = TrainingLoadModel.MissingDayPolicy.ASSUME_REST,
            ),
        )

        assertEquals(0, result.latest?.assumedRestDaysInWindow)
        assertEquals(1, result.latest?.assumedRestDaysInModelHistory)
        assertEquals(TrainingLoadModel.Quality.ESTIMATED, result.latest?.quality)
    }

    @Test
    fun adversarialCalendarSpanIsRejectedBeforeTimelineExpansion() {
        val result = TrainingLoadModel.evaluate(
            listOf(
                TrainingLoadModel.Entry("0001-01-01", 10.0),
                TrainingLoadModel.Entry("9999-12-31", 10.0),
            )
        )

        assertEquals(TrainingLoadModel.Series.Status.CALENDAR_SPAN_EXCEEDED, result.status)
        assertEquals(2, result.observedDays.size)
        assertTrue(result.points.isEmpty())
    }

    @Test
    fun extremeFiniteLoadsNeverExposeNonFiniteDerivedValues() {
        val result = TrainingLoadModel.evaluate(entries(30) { Double.MAX_VALUE })

        assertEquals(TrainingLoadModel.Series.Status.COMPLETE, result.status)
        result.points.forEach { point ->
            val derived = listOfNotNull(
                point.atl, point.ctl, point.tsb,
                point.currentRampWindowLoad, point.previousRampWindowLoad,
                point.rampChange, point.rampChangeFraction,
            )
            assertTrue("non-finite output on ${point.day}", derived.all { it.isFinite() })
        }
        val latest = result.latest!!
        assertEquals(Double.MAX_VALUE, latest.atl!!, 0.0)
        assertEquals(Double.MAX_VALUE, latest.ctl!!, 0.0)
        assertEquals(0.0, latest.tsb!!, 0.0)
        assertEquals(TrainingLoadModel.RampDirection.UNAVAILABLE, latest.rampDirection)
        assertNull(latest.currentRampWindowLoad)
        assertNull(latest.rampChangeFraction)
    }

    @Test
    fun overflowingRampFractionIsUnavailableRatherThanInfinite() {
        val tiny = Double.MIN_VALUE
        val large = Double.MAX_VALUE / 8.0
        val latest = TrainingLoadModel.evaluate(
            entries(14) { if (it < 7) tiny else large }
        ).latest!!

        assertEquals(TrainingLoadModel.RampDirection.UNAVAILABLE, latest.rampDirection)
        assertNull(latest.rampChangeFraction)
        assertTrue(latest.currentRampWindowLoad?.isFinite() == true)
        assertTrue(latest.previousRampWindowLoad?.isFinite() == true)
        assertTrue(latest.rampChange?.isFinite() == true)
    }
}
