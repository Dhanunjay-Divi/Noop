package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin parity for StrandAnalytics/CaptureAccumulatorTests.swift (#965): each active mode's captured-day
 * count is the number of DISTINCT days that mode produced its own trace on. Production persists only the
 * extracted day tokens in bounded Test Centre state; these pure vectors pin the extraction/parity logic.
 */
class CaptureAccumulatorTest {

    private val report = """
        [sleep] gate run=0 day=2026-07-02 spanS=1163 DROPPED gate=minSleepMin
        [sleep] gate run=1 day=2026-07-01 spanS=25000 KEPT gate=accepted
        [sleep] gate run=2 day=2026-06-30 spanS=26000 KEPT gate=accepted
        [steps] stepsRaw day=2026-07-02 counterSamples=29248 firstCounter=65046 lastCounter=5336
        [steps] stepsRaw day=2026-07-01 counterSamples=1000
        [battery] bank soc=26.0 t=1782957600s
        [battery] bank soc=25.0 t=1782961200s
        [battery] bank soc=24.0 t=1782964800s
        [universal] dayOwner day=2026-07-02 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
        [universal] dayOwner day=2026-07-01 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
    """.trimIndent()

    @Test
    fun sleep_countsDistinctNights() {
        assertEquals(3, CaptureAccumulator.capturedDays(TestDomain.SLEEP, report, 0L))
    }

    @Test
    fun steps_countsDistinctDays() {
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.STEPS, report, 0L))
    }

    @Test
    fun battery_foldsEpochSamplesToOneDay() {
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.BATTERY, report, 0L))
    }

    @Test
    fun universal_countsScoredDays() {
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.UNIVERSAL, report, 0L))
    }

    @Test
    fun modesAccumulateIndependently() {
        assertEquals(3, CaptureAccumulator.capturedDays(TestDomain.SLEEP, report, 0L))
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.STEPS, report, 0L))
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.BATTERY, report, 0L))
    }

    @Test
    fun deadTraceIsZero() {
        val onlyBattery = "[battery] bank soc=50.0 t=1782957600s"
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.SLEEP, onlyBattery, 0L))
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.STEPS, onlyBattery, 0L))
    }

    @Test
    fun unmarkedDomainIsZero() {
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.CONNECTION, report, 0L))
    }

    @Test
    fun dayKeyDoesNotLeakAcrossModes() {
        val cross =
            "[workouts] autoDetect day=2026-07-05 windows=1\n" +
                "[sleep] gate run=1 day=2026-07-02 KEPT"
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.SLEEP, cross, 0L))
    }

    @Test
    fun battery_localDayFold() {
        // 1782957600 = 2026-07-02 02:00 UTC. At UTC-9h (-32400s) it is 2026-07-01 17:00 local => prior day.
        val one = "[battery] bank soc=40.0 t=1782957600s"
        assertEquals(setOf("2026-07-02"), CaptureAccumulator.capturedDayKeys(TestDomain.BATTERY, one, 0L))
        assertEquals(setOf("2026-07-01"), CaptureAccumulator.capturedDayKeys(TestDomain.BATTERY, one, -32400L))
    }

    @Test
    fun batteryUsesTheOffsetAtTheHistoricalSampleRatherThanTodaysOffset() {
        // 2026-07-02 04:30 UTC is July 2 at UTC-4 but July 1 at UTC-5. The event-time
        // offset therefore decides the captured day near midnight.
        val eventUnix = 1_782_966_600L
        val observedEpochs = mutableListOf<Long>()
        assertEquals(
            "2026-07-02",
            CaptureAccumulator.capturedDayKey(
                TestDomain.BATTERY,
                "[battery] bank soc=40.0 t=${eventUnix}s",
                tzOffsetSeconds = -18_000L,
                offsetForEpoch = { epoch ->
                    observedEpochs += epoch
                    -14_400L
                },
            ),
        )
        assertEquals(listOf(eventUnix), observedEpochs)
    }

    @Test
    fun extractsOneValidatedTokenWithoutRetainingTheTrace() {
        assertEquals(
            "2026-07-02",
            CaptureAccumulator.capturedDayKey(
                TestDomain.SLEEP,
                "[sleep] gate run=1 day=2026-07-02 KEPT",
                0L,
            ),
        )
        assertEquals(
            "2026-07-01",
            CaptureAccumulator.capturedDayKey(
                TestDomain.BATTERY,
                "[battery] bank soc=40.0 t=1782957600s",
                -32400L,
            ),
        )
        assertEquals(
            null,
            CaptureAccumulator.capturedDayKey(
                TestDomain.SLEEP,
                "[battery] bank soc=40.0 t=1782957600s",
                0L,
            ),
        )
    }
}
