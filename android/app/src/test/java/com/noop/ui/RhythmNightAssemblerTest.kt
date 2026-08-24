package com.noop.ui

import com.noop.analytics.RhythmRegularity
import com.noop.data.DismissedWorkout
import com.noop.data.GravitySample
import com.noop.data.RrInterval
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class RhythmNightAssemblerTest {
    private val start = 1_700_000_000L
    private val end = start + 300L

    @Test
    fun stillRestingWindow_isReadable() {
        val readout = RhythmNightAssembler.assemble(
            rr = rrSeries(rrMs = 1_000),
            gravity = stillGravity(),
            workouts = emptyList(),
            from = start,
            to = end,
        )

        assertEquals(1, readout.windows.size)
        assertEquals(RhythmRegularity.STEADY, readout.windows.single().label)
        assertEquals(1, readout.night?.readableWindows)
    }

    @Test
    fun overlappingWorkout_isUnreadableEvenWithStillWrist() {
        val readout = RhythmNightAssembler.assemble(
            rr = rrSeries(rrMs = 1_000),
            gravity = stillGravity(),
            workouts = listOf(workout(start + 60L, start + 240L)),
            from = start,
            to = end,
        )

        assertEquals(RhythmRegularity.UNREADABLE, readout.windows.single().label)
        assertEquals(0, readout.night?.readableWindows)
    }

    @Test
    fun dismissedDetectedWorkout_doesNotSuppressWindow() {
        val detected = workout(
            from = start + 60L,
            to = start + 240L,
            deviceId = "band-noop",
            source = "band-noop",
        )
        val readout = RhythmNightAssembler.assemble(
            rr = rrSeries(rrMs = 1_000),
            gravity = stillGravity(),
            workouts = listOf(detected),
            dismissedWorkouts = listOf(
                DismissedWorkout(detected.deviceId, detected.startTs, detected.endTs),
            ),
            from = start,
            to = end,
        )

        assertEquals(RhythmRegularity.STEADY, readout.windows.single().label)
        assertEquals(1, readout.night?.readableWindows)
    }

    @Test
    fun completeCanonicalRrSource_winsOverSparseActiveSource() {
        val readout = RhythmNightAssembler.assembleBest(
            rrSources = listOf(
                rrSeries(rrMs = 1_000).take(20),
                rrSeries(rrMs = 1_000),
            ),
            gravity = stillGravity(),
            workouts = emptyList(),
            dismissedWorkouts = emptyList(),
            from = start,
            to = end,
        )

        assertEquals(1, readout.windows.size)
        assertEquals(RhythmRegularity.STEADY, readout.windows.single().label)
    }

    @Test
    fun readableCanonicalRrSource_winsOverDenserUnreadableSource() {
        val readout = RhythmNightAssembler.assembleBest(
            rrSources = listOf(
                rrSeries(rrMs = 400),
                rrSeries(rrMs = 1_000).take(250),
            ),
            gravity = stillGravity(),
            workouts = emptyList(),
            dismissedWorkouts = emptyList(),
            from = start,
            to = end,
        )

        assertEquals(1, readout.windows.size)
        assertEquals(RhythmRegularity.STEADY, readout.windows.single().label)
        assertEquals(1, readout.night?.readableWindows)
    }

    @Test
    fun elevatedExerciseRateAndMissingMotionEvidence_failClosed() {
        val highRate = RhythmNightAssembler.assemble(
            rr = rrSeries(rrMs = 400),
            gravity = stillGravity(),
            workouts = emptyList(),
            from = start,
            to = end,
        )
        val noMotion = RhythmNightAssembler.assemble(
            rr = rrSeries(rrMs = 1_000),
            gravity = emptyList(),
            workouts = emptyList(),
            from = start,
            to = end,
        )

        assertEquals(RhythmRegularity.UNREADABLE, highRate.windows.single().label)
        assertEquals(RhythmRegularity.UNREADABLE, noMotion.windows.single().label)
        assertNotNull(noMotion.night)
    }

    private fun rrSeries(rrMs: Int): List<RrInterval> =
        (0 until 300).map { offset ->
            val phase = offset % 8
            val triangular = if (phase < 4) phase else 8 - phase
            RrInterval(
                deviceId = "band",
                ts = start + offset,
                rrMs = rrMs + (triangular * 2 - 4) * 8,
                seq = 0,
            )
        }

    private fun stillGravity(): List<GravitySample> =
        listOf(0L, 60L, 120L, 180L, 240L).map { offset ->
            GravitySample(
                deviceId = "band",
                ts = start + offset,
                x = 0.0,
                y = 0.0,
                z = 1.0,
            )
        }

    private fun workout(
        from: Long,
        to: Long,
        deviceId: String = "band",
        source: String = "manual",
    ) = WorkoutRow(
        deviceId = deviceId,
        startTs = from,
        endTs = to,
        sport = "Cycling",
        source = source,
    )
}
