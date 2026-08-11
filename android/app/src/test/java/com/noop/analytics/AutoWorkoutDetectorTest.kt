package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity tests for the MVP [AutoWorkoutDetector] — mirrors
 * StrandAnalytics/AutoWorkoutDetectorTests.swift case-for-case so the two platforms stay
 * byte-parity on the detection logic.
 *
 * Cases: elevated span detected; brief dip tolerated; short/low spans rejected; only short-gap
 * windows merged; window overlapping a saved workout excluded.
 */
class AutoWorkoutDetectorTest {

    private val dev = "test-device"
    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun grav(ts: Long, x: Double) =
        GravitySample(deviceId = dev, ts = ts, x = x, y = 0.0, z = 1.0)

    /** Build a flat 1 Hz HR block [start, start+durS) at [bpm]. */
    private fun block(start: Long, durS: Int, bpm: Int): List<HrSample> =
        (0 until durS).map { hr(start + it, bpm) }

    // resting 60 → floor = 90. Workout bpm 120 is elevated; rest bpm 65 is not.

    @Test fun elevatedSpanIsDetected() {
        // 20 min sustained at 120 bpm, embedded in rest. One workout, ~20 min, avg/peak 120.
        val rest = 60
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals(1, out.size)
        val w = out[0]
        assertEquals(120, w.avgBpm)
        assertEquals(120, w.peakBpm)
        assertTrue("duration ${w.durationMin} min", w.durationMin >= 19)
        assertEquals(start, w.startSec)
        assertEquals(AutoWorkoutDetector.detectorVersion, w.detectorVersion)
        assertEquals(null, w.eventConfidence)
        assertEquals(AutoWorkoutDetector.ConfidenceStatus.UNCALIBRATED, w.confidenceStatus)
        assertEquals(AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_ONLY, w.evidenceProvenance)
        assertEquals(AutoWorkoutDetector.TypeSuggestionStatus.UNKNOWN, w.typeSuggestionStatus)
    }

    @Test fun briefDipIsTolerated() {
        // 10 min at 120, a 60 s dip to 70 (below floor, but <= 90 s), then 10 min at 120.
        // The dip must NOT split the span → one ~21 min workout.
        val rest = 60
        val start = 2_000_000L
        val first = block(start, 600, 120)
        val dip = block(start + 600, 60, 70)
        val second = block(start + 660, 600, 120)
        val hr = block(start - 300, 300, 65) + first + dip + second + block(start + 1260, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals("dip split the span into ${out.size}", 1, out.size)
        assertTrue("merged span too short: ${out[0].durationMin} min", out[0].durationMin >= 20)
    }

    @Test fun shortSpanIsRejected() {
        // 8 min at 120 (< 10 min minimum) → nothing.
        val rest = 60
        val start = 3_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 8 * 60, 120) + block(start + 480, 300, 65)
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest).isEmpty())
    }

    @Test fun lowSpanIsRejected() {
        // 20 min at 85 bpm: resting 60 → floor 90, so 85 never clears the gate → nothing.
        val rest = 60
        val start = 4_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 85) + block(start + 1200, 300, 65)
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest).isEmpty())
    }

    @Test fun nearWindowsAreMerged() {
        // Two 16 min bouts at 120 separated by a 3 min true rest at 65 (< 5 min merge gap, but the rest
        // is > 90 s so it CLOSES each span). The two closed spans are then MERGED into one (gap < 5 min).
        val rest = 60
        val start = 5_000_000L
        val a = block(start, 16 * 60, 120)
        val gap = block(start + 960, 3 * 60, 65) // 180 s rest > maxDipS → span closes
        val b = block(start + 1140, 16 * 60, 120)
        val hr = block(start - 300, 300, 65) + a + gap + b + block(start + 2100, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals("near windows not merged: ${out.size}", 1, out.size)
        // Merged span runs from the first bout's start to the second bout's end (~33 min).
        assertTrue("merged span too short: ${out[0].durationMin} min", out[0].durationMin >= 30)
    }

    @Test fun farWindowsStaySeparate() {
        // Two 16 min bouts at 120 separated by a 70 min rest (> 5 min merge gap) → two workouts.
        val rest = 60
        val start = 6_000_000L
        val a = block(start, 16 * 60, 120)
        val gap = block(start + 960, 70 * 60, 65)
        val b = block(start + 5160, 16 * 60, 120)
        val hr = block(start - 300, 300, 65) + a + gap + b + block(start + 6120, 300, 65)
        val out = AutoWorkoutDetector.detect(hr, restingHR = rest)
        assertEquals(2, out.size)
    }

    @Test fun separateWorkoutsAnHourApartAreNotMerged() {
        val start = 6_500_000L
        val first = block(start, 20 * 60, 120)
        // First end is start+1199; second starts exactly 3600 seconds after that endpoint.
        val rest = block(start + 1200, 3599, 65)
        val secondStart = start + 4799
        val second = block(secondStart, 20 * 60, 120)
        val hr = block(start - 300, 300, 65) + first + rest + second +
            block(secondStart + 20 * 60, 300, 65)
        assertEquals(2, AutoWorkoutDetector.detect(hr, restingHR = 60).size)
    }

    @Test fun windowOverlappingSavedWorkoutIsExcluded() {
        // A clean 20 min bout, but a saved workout already covers the middle of it → suggestion suppressed.
        val rest = 60
        val start = 7_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        val saved = listOf((start + 300) to (start + 600)) // overlaps the detected span
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest, savedWorkouts = saved).isEmpty())
        // Sanity: with the overlap removed, it IS detected.
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest).size)
    }

    @Test fun motionConfirmationGatesWhenSeriesPresent() {
        // Same elevated HR bout, but the gravity series is perfectly STILL over the window → no motion
        // confirmation → rejected. With no gravity series (HR-only) the same bout IS detected.
        val rest = 60
        val start = 8_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        val still = (start until start + 1200).map { grav(it, 0.0) } // zero motion delta
        assertTrue(AutoWorkoutDetector.detect(hr, restingHR = rest, gravity = still).isEmpty())
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest).size)
        // Moving gravity (alternating x) confirms motion → detected.
        val moving = (start until start + 1200).map { grav(it, ((it - start) % 2).toDouble() * 0.5) }
        val movingOut = AutoWorkoutDetector.detect(hr, restingHR = rest, gravity = moving)
        assertEquals(1, movingOut.size)
        assertEquals(AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_AND_MOTION,
            movingOut.first().evidenceProvenance)
    }

    @Test fun sparseMotionCannotVetoAnHrCandidate() {
        val rest = 60
        val start = 8_500_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        val sparseStill = (start until start + 1200 step 120).map { grav(it, 0.0) }
        val motion = AutoWorkoutDetector.motionIntensityByTs(sparseStill)

        assertEquals(
            AutoWorkoutDetector.MotionConfirmation.Unavailable,
            AutoWorkoutDetector.motionConfirmation(motion, start, start + 1199),
        )
        assertEquals(1, AutoWorkoutDetector.detect(hr, restingHR = rest, gravity = sparseStill).size)
    }

    @Test fun emptyInputIsEmpty() {
        assertTrue(AutoWorkoutDetector.detect(emptyList()).isEmpty())
    }

    @Test fun defaultRestingHrIsUsedWhenNull() {
        // No restingHR → lower-decile observed baseline (65 here), still detects the workout.
        val start = 9_000_000L
        val hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        assertEquals(1, AutoWorkoutDetector.detect(hr).size)
    }

    @Test fun sparseSamplesCannotFakeSustainedActivity() {
        val start = 10_000_000L
        val sparse = (start..start + 20 * 60 step 120).map { hr(it, 130) }
        assertTrue(AutoWorkoutDetector.detect(sparse, restingHR = 60).isEmpty())
    }

    @Test fun missingRhrUsesConservativeObservedBaseline() {
        val hr = block(11_000_000L, 20 * 60, 120)
        assertEquals(100, AutoWorkoutDetector.effectiveRestingBPM(null, hr))
        assertTrue(AutoWorkoutDetector.detect(hr).isEmpty())
    }


    @Test fun thresholdAndConservativeFragmentMergeContract() {
        assertEquals(10.0, AutoWorkoutDetector.minSustainedMin, 0.0)
        assertEquals(5L * 60L, AutoWorkoutDetector.mergeGapS)
        val start = 12_000_000L
        val nineMinutes = block(start, 9 * 60, 120) + block(start + 9 * 60, 300, 65)
        assertTrue(AutoWorkoutDetector.detect(nineMinutes, restingHR = 60).isEmpty())
    }

    @Test fun ongoingSpanWaitsForPostSessionQuietTail() {
        val start = 13_000_000L
        val elevated = block(start, 20 * 60, 120)
        assertTrue("an elevated EOF span is still in progress",
            AutoWorkoutDetector.detect(elevated, restingHR = 60).isEmpty())

        val finalized = elevated + block(start + 20 * 60, AutoWorkoutDetector.maxDipS.toInt() + 2, 65)
        val out = AutoWorkoutDetector.detect(finalized, restingHR = 60)
        assertEquals(1, out.size)
        assertEquals(start, out[0].startSec)
        assertEquals(start + 20 * 60 - 1, out[0].endSec)
    }

    @Test fun duplicateTimestampsCannotManufactureCoverage() {
        val start = 14_000_000L
        val sparse = (start..start + 20 * 60 step 60).flatMap { ts ->
            List(4) { hr(ts, 120) }
        }
        val samples = sparse + block(start + 20 * 60 + 1, AutoWorkoutDetector.maxDipS.toInt() + 2, 65)
        assertTrue(AutoWorkoutDetector.detect(samples, restingHR = 60).isEmpty())
    }

    @Test fun telemetryGapDoesNotEraseLaterDenseBout() {
        val start = 15_000_000L
        val secondStart = start + 17 * 60
        val samples = block(start, 12 * 60, 120) +
            block(secondStart, 12 * 60, 120) +
            block(secondStart + 12 * 60, AutoWorkoutDetector.maxDipS.toInt() + 2, 65)
        val out = AutoWorkoutDetector.detect(samples, restingHR = 60)
        assertEquals(1, out.size)
        assertEquals(secondStart, out.first().startSec)
    }

    @Test fun clumpedMotionIsUnavailableAndCannotVetoHr() {
        val start = 16_000_000L
        val end = start + 20 * 60 - 1
        val samples = block(start, 20 * 60, 120) +
            block(start + 20 * 60, AutoWorkoutDetector.maxDipS.toInt() + 2, 65)
        val clumped = (0 until 15).map { grav(start + it, 0.0) } +
            (0 until 15).map { grav(end - 14 + it, 0.0) }
        val motion = AutoWorkoutDetector.motionIntensityByTs(clumped)
        assertEquals(AutoWorkoutDetector.MotionConfirmation.Unavailable,
            AutoWorkoutDetector.motionConfirmation(motion, start, end))
        val out = AutoWorkoutDetector.detect(samples, restingHR = 60, gravity = clumped)
        assertEquals(1, out.size)
        assertEquals(AutoWorkoutDetector.EvidenceProvenance.HEART_RATE_ONLY,
            out.first().evidenceProvenance)
    }

    @Test fun invalidBpmAndExtremeTimestampSpanAreRejectedSafely() {
        val start = 17_000_000L
        val invalid = block(start, 20 * 60, 1_000) +
            block(start + 20 * 60, AutoWorkoutDetector.maxDipS.toInt() + 2, 65)
        assertTrue(AutoWorkoutDetector.detect(invalid, restingHR = 60).isEmpty())
        assertTrue(!AutoWorkoutDetector.hasSufficientHRCoverage(
            listOf(hr(Long.MIN_VALUE, 120), hr(Long.MAX_VALUE, 120)), Long.MIN_VALUE, Long.MAX_VALUE))
    }
}
