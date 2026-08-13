package com.noop.analytics

import com.noop.data.GravitySample
import kotlin.math.sqrt

/**
 * Converts banked wrist-gravity rows into the one contemporaneous motion value the stress detector may
 * trust. Historical offload can return hours of perfectly valid motion; that does not prove the wearer is
 * still now. This boundary therefore returns null unless a dense short window ends close to wall-clock time.
 * Null is intentionally fail-closed by [StressOnsetDetector].
 */
object StressMotionEvidence {

    /** Maximum age of the newest banked gravity row. Older evidence cannot support a "while still" cue. */
    const val MAX_MOTION_AGE_SECONDS: Long = 120L

    /** Trailing window used for the mean gravity delta, matching the workout detector's 10 s smoothing. */
    const val SMOOTHING_WINDOW_SECONDS: Long = 10L

    /** Enough distinct seconds to distinguish observed stillness from a lone zero-seeded sample. */
    const val MIN_DISTINCT_SAMPLES: Int = 5

    /**
     * Return a 10-second mean L2 gravity delta (g), or null when the evidence is missing, sparse, stale,
     * future-dated, or non-finite. Duplicate timestamps collapse deterministically to the last row.
     */
    fun recentIntensityG(gravity: List<GravitySample>, nowSec: Long): Double? {
        if (gravity.isEmpty() || nowSec < 0L) return null

        val byTimestamp = LinkedHashMap<Long, GravitySample>()
        for (row in gravity.sortedBy { it.ts }) {
            if (row.ts < 0L || !row.x.isFinite() || !row.y.isFinite() || !row.z.isFinite()) continue
            byTimestamp[row.ts] = row
        }
        val latest = byTimestamp.values.lastOrNull() ?: return null
        val age = nowSec - latest.ts
        if (age !in 0L..MAX_MOTION_AGE_SECONDS) return null

        val windowStart = latest.ts - SMOOTHING_WINDOW_SECONDS
        val rows = byTimestamp.values.filter { it.ts >= windowStart }
        if (rows.size < MIN_DISTINCT_SAMPLES) return null
        if ((rows.last().ts - rows.first().ts) < (MIN_DISTINCT_SAMPLES - 1).toLong()) return null

        var sum = 0.0
        var deltas = 0
        for (index in 1 until rows.size) {
            val previous = rows[index - 1]
            val current = rows[index]
            val dx = current.x - previous.x
            val dy = current.y - previous.y
            val dz = current.z - previous.z
            val delta = sqrt(dx * dx + dy * dy + dz * dz)
            if (!delta.isFinite()) return null
            sum += delta
            deltas += 1
        }
        return if (deltas > 0) sum / deltas.toDouble() else null
    }
}
