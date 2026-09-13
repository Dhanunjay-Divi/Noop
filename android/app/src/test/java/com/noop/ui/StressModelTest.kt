package com.noop.ui

import com.noop.analytics.DaytimeStress
import com.noop.analytics.HrvFreqDomain
import com.noop.analytics.StressIndex
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.RrInterval
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * StressModel.build carry (#543). The Today "Stress" metric derives against a 30-day RHR/HRV baseline.
 * Today's own daily row is often vitals-less until the overnight is analyzed (especially right after an
 * app update relaunches and re-runs the analyze pass), and every OTHER Today vital carries last night's
 * value — Stress used to be the one card that didn't, so it dropped to "Calibrating" while the rest showed
 * numbers. These pin the carry: score the newest day that actually has RHR/HRV. Twin of the Swift
 * StressModelCarryTests.
 */
class StressModelTest {

    private fun day(d: String, rhr: Int?, hrv: Double?) =
        DailyMetric(deviceId = "my-whoop", day = d, restingHr = rhr, avgHrv = hrv)

    // 31 days that all carry RHR + HRV: a full 30-day baseline plus one more scorable day.
    private val baseline = (1..30).map { day("2026-06-%02d".format(it), rhr = 55, hrv = 60.0) } +
        day("2026-07-01", rhr = 55, hrv = 60.0)

    @Test
    fun vitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals -> builds (unchanged behaviour).
        assertNotNull(StressModel.build(baseline + day("2026-07-02", rhr = 58, hrv = 45.0), emptyMap()))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does -> carries, not null.
        assertNotNull(
            "a vitals-less today must carry the last day with RHR/HRV, not calibrate",
            StressModel.build(baseline + day("2026-07-02", rhr = null, hrv = null), emptyMap()),
        )
    }

    @Test
    fun noVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored -> honestly calibrating (null).
        val days = (1..5).map { day("2026-07-0$it", rhr = null, hrv = null) }
        assertNull(StressModel.build(days, emptyMap()))
    }

    @Test
    fun storedStressOnLatestVitalsLessDayIsUsedNotSkipped() {
        // An imported latest day carries a STORED stress value but no RHR/HRV (e.g. a Xiaomi / Garmin /
        // WHOOP export). The original gate honoured it; the carry must NOT skip it back to an older vitals
        // day. The stored 2.5 must win over any derived carry.
        val days = baseline + day("2026-07-02", rhr = null, hrv = null)
        val model = StressModel.build(days, mapOf("2026-07-02" to 2.5))
        assertNotNull(model)
        assertEquals("the latest day's stored stress must win over a carry", 2.5, model!!.score, 0.001)
    }

    @Test
    fun postQueryAnalysisPreservesAllThreeFormulaOutputs() = runTest {
        val start = 1_780_300_800L // 2026-06-01 08:00 UTC
        val hr = (0 until 900).map { offset ->
            HrSample(deviceId = "test", ts = start + offset, bpm = 58 + (offset / 300) * 4)
        }
        val rr = (0 until 520).map { offset ->
            RrInterval(
                deviceId = "test",
                ts = start + (offset * 82L / 100L),
                rrMs = 770 + (offset % 9) * 8,
            )
        }

        val readout = analyzeDaytimeStressOffMain(hr, rr, tzOffsetSeconds = 0)

        assertEquals(DaytimeStress.analyze(hr, rr, 0), readout.daytime)
        assertEquals(StressIndex.components(rr), readout.stressIndex)
        assertEquals(HrvFreqDomain.freqDomain(rr), readout.freqHrv)
    }

    @Test
    fun canceledAndSupersededRequestsCannotPublish() = runTest {
        var publications = 0
        val started = CompletableDeferred<Unit>()
        val canceled = launch {
            publishStressAnalysisIfCurrent(
                load = {
                    started.complete(Unit)
                    CompletableDeferred<Int>().await()
                },
                isCurrent = { true },
            ) { _: Int ->
                publications += 1
            }
        }
        started.await()
        canceled.cancelAndJoin()
        assertEquals(0, publications)

        publishStressAnalysisIfCurrent(
            load = { 7 },
            isCurrent = { false },
        ) {
            publications += 1
        }
        assertEquals(0, publications)

        publishStressAnalysisIfCurrent(
            load = { 8 },
            isCurrent = { true },
        ) {
            publications += 1
        }
        assertEquals(1, publications)
    }

    @Test
    fun stressSourceUsesCpuDispatcherCancellationAndBoundedTiming() {
        val source = stressSource()
        val analysisStart = source.indexOf("internal suspend fun analyzeDaytimeStressOffMain(")
        val analysisEnd = source.indexOf(
            "private suspend fun analyzeDaytimeStressTimed(",
            analysisStart,
        )
        assertTrue(analysisStart >= 0 && analysisEnd > analysisStart)

        val analysis = source.substring(analysisStart, analysisEnd)
        assertTrue(analysis.contains("dispatcher: CoroutineDispatcher = Dispatchers.Default"))
        assertTrue(analysis.contains("withContext(dispatcher)"))
        assertTrue(analysis.contains("currentCoroutineContext().ensureActive()"))
        assertTrue(analysis.contains("DaytimeStress.analyze(hr, rr, tzOffsetSeconds)"))
        assertTrue(analysis.contains("StressIndex.components(rr)"))
        assertTrue(analysis.contains("HrvFreqDomain.freqDomain(rr)"))
        assertFalse(analysis.contains("deviceId"))
        assertFalse(analysis.contains("rrMs"))
        assertFalse(analysis.contains("bpm"))

        val timedStart = source.indexOf("private suspend fun analyzeDaytimeStressTimed(")
        val timedEnd = source.indexOf("/**\n * Read TODAY", timedStart)
        assertTrue(timedStart >= 0 && timedEnd > timedStart)
        val timed = source.substring(timedStart, timedEnd)
        assertTrue(timed.contains("\"stress.daytime_analysis\""))
        assertTrue(timed.contains("catch (cancelled: CancellationException)"))
        assertTrue(timed.contains("outcome = \"canceled\""))
        assertTrue(timed.contains("outcome = \"failed\""))
        assertTrue(timed.contains("throw cancelled"))
        assertFalse(timed.contains("deviceId"))
        assertFalse(timed.contains("rrMs"))
        assertFalse(timed.contains("bpm"))
    }

    @Test
    fun zeroStressBandHoursRemainMeasuredZero() {
        val source = stressSource()
        assertTrue(source.contains("l10n_stress_screen_hours_h_7610ac7c, hours"))
        assertFalse(source.contains("hours <= 0"))
    }

    private fun stressSource(): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val file = listOf(
            File(root, "src/main/java/com/noop/ui/StressScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/StressScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/StressScreen.kt"),
        ).firstOrNull(File::isFile)
        return checkNotNull(file) { "Could not locate StressScreen.kt from $root" }.readText()
    }
}
