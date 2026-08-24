package com.noop.ui

import com.noop.analytics.RhythmRegularity
import com.noop.analytics.RhythmScreener
import com.noop.data.DismissedWorkout
import com.noop.data.GravitySample
import com.noop.data.RrInterval
import com.noop.data.WorkoutRow
import com.noop.protocol.RrInterval as ProtocolRrInterval
import kotlin.math.sqrt

internal data class RhythmNightReadout(
    val night: RhythmScreener.NightRhythmSummary?,
    val windows: List<RhythmScreener.WindowResult>,
) {
    companion object {
        val Empty = RhythmNightReadout(night = null, windows = emptyList())
    }
}

/**
 * Pure Android twin of Apple RhythmHost's five-minute window assembly.
 *
 * Every window fails closed without enough wrist motion evidence. Non-dismissed recorded activity
 * is checked independently of motion because stationary exercise can otherwise resemble a resting
 * wrist.
 */
internal object RhythmNightAssembler {
    private const val WINDOW_SECONDS = 5L * 60L

    /**
     * Select one R-R source without combining duplicate beat trains. Readable resting windows rank
     * first, then attempted-window coverage, then row count; an exact tie preserves active-first
     * source priority. This prevents sparse or noisy active data from masking a valid canonical night.
     */
    fun assembleBest(
        rrSources: List<List<RrInterval>>,
        gravity: List<GravitySample>,
        workouts: List<WorkoutRow>,
        dismissedWorkouts: List<DismissedWorkout>,
        from: Long,
        to: Long,
    ): RhythmNightReadout {
        var best = RhythmNightReadout.Empty
        var bestReadableCount = -1
        var bestWindowCount = -1
        var bestRowCount = -1
        for (rr in rrSources) {
            val candidate = assemble(
                rr = rr,
                gravity = gravity,
                workouts = workouts,
                dismissedWorkouts = dismissedWorkouts,
                from = from,
                to = to,
            )
            val readableCount = candidate.windows.count { it.label != RhythmRegularity.UNREADABLE }
            val rowCount = rr.count { it.ts >= from && it.ts < to }
            if (readableCount > bestReadableCount ||
                (readableCount == bestReadableCount && candidate.windows.size > bestWindowCount) ||
                (readableCount == bestReadableCount && candidate.windows.size == bestWindowCount &&
                    rowCount > bestRowCount)
            ) {
                best = candidate
                bestReadableCount = readableCount
                bestWindowCount = candidate.windows.size
                bestRowCount = rowCount
            }
        }
        return best
    }

    fun assemble(
        rr: List<RrInterval>,
        gravity: List<GravitySample>,
        workouts: List<WorkoutRow>,
        dismissedWorkouts: List<DismissedWorkout> = emptyList(),
        from: Long,
        to: Long,
    ): RhythmNightReadout {
        if (to <= from || rr.isEmpty()) return RhythmNightReadout.Empty

        val orderedRr = rr.sortedBy { it.ts }
        val orderedGravity = gravity.sortedBy { it.ts }
        val activeWorkouts = WorkoutEditing.filterDismissed(workouts, dismissedWorkouts)
        val results = ArrayList<RhythmScreener.WindowResult>()
        var start = from
        while (start < to) {
            val end = minOf(start + WINDOW_SECONDS, to)
            val windowRr = orderedRr.filter { it.ts >= start && it.ts < end }
            if (windowRr.size >= RhythmScreener.WINDOW_MIN_BEATS) {
                val windowGravity = orderedGravity.filter { it.ts >= start && it.ts < end }
                val activityActive = activeWorkouts.any { workout ->
                    workout.startTs < end && maxOf(workout.endTs, workout.startTs + 1L) > start
                }
                val protocolRr = windowRr.map {
                    ProtocolRrInterval(ts = it.ts.toInt(), rrMs = it.rrMs)
                }
                val input = RhythmScreener.WindowInput.fromRr(
                    rr = protocolRr,
                    motionStill = isStill(windowGravity),
                    activityActive = activityActive,
                )
                results += RhythmScreener.screenWindow(input)
            }
            start = end
        }

        return RhythmNightReadout(
            night = RhythmScreener.summarizeNight(results),
            windows = results,
        )
    }

    internal fun isStill(samples: List<GravitySample>): Boolean {
        if (samples.size < 4) return false
        val magnitudes = samples.map { sqrt(it.x * it.x + it.y * it.y + it.z * it.z) }
        val mean = magnitudes.average()
        if (mean <= 0.0 || !mean.isFinite()) return false
        val variance = magnitudes.sumOf { value ->
            val delta = value - mean
            delta * delta
        } / magnitudes.size.toDouble()
        return sqrt(variance) / mean < 0.03
    }
}
