package com.noop.analytics

import com.noop.data.GravitySample
import kotlin.math.sqrt

data class TimestampedWristMotionEvidence(
    val movementG: Double,
    val observedAtMillis: Long,
    val sampleCount: Int,
)

/** Bounds opted-in live stress DB reads while still reacting far sooner than a full history handover. */
object StressEvaluationCadence {
    const val MINIMUM_INTERVAL_MILLIS = 15_000L

    fun shouldRequest(
        lastRequestAtMillis: Long?,
        nowMillis: Long,
        force: Boolean = false,
    ): Boolean {
        if (force) return true
        val last = lastRequestAtMillis ?: return true
        val elapsed = nowMillis - last
        return elapsed < 0L || elapsed >= MINIMUM_INTERVAL_MILLIS
    }
}

/**
 * Converts banked wrist-gravity rows into the one contemporaneous motion value the stress detector may
 * trust. Historical offload can return hours of perfectly valid motion; that does not prove the wearer is
 * still now. This boundary therefore returns null unless a dense short window ends close to wall-clock time.
 * Null is intentionally fail-closed by [StressOnsetDetector].
 */
object StressMotionEvidence {

    const val LOOKBACK_SECONDS: Long = 120L
    /** Maximum age of the newest banked gravity row. Older evidence cannot support a "while still" cue. */
    const val MAX_MOTION_AGE_SECONDS: Long = 90L
    /** A sparse offload must not counterfeit a continuously observed resting window. */
    const val MAX_SAMPLE_GAP_SECONDS: Long = 10L

    /** Trailing window used for the mean gravity delta. */
    const val SMOOTHING_WINDOW_SECONDS: Long = 60L

    /** Enough distinct seconds to distinguish observed stillness from a lone zero-seeded sample. */
    const val MIN_DISTINCT_SAMPLES: Int = 8
    const val MIN_SPAN_SECONDS: Long = 10L

    /**
     * Return a timestamped mean L2 gravity delta (g), or null when the evidence is missing, sparse,
     * stale, future-dated, gapped, or non-finite. Duplicate timestamps collapse deterministically to
     * the last row.
     */
    fun derive(gravity: List<GravitySample>, nowSec: Long): TimestampedWristMotionEvidence? {
        if (gravity.isEmpty() || nowSec < 0L) return null

        val byTimestamp = LinkedHashMap<Long, GravitySample>()
        for (row in gravity.sortedBy { it.ts }) {
            if (
                row.ts < nowSec - LOOKBACK_SECONDS ||
                row.ts > nowSec + 5L ||
                !row.x.isFinite() ||
                !row.y.isFinite() ||
                !row.z.isFinite()
            ) continue
            byTimestamp[row.ts] = row
        }
        val latest = byTimestamp.values.lastOrNull() ?: return null
        val age = nowSec - latest.ts
        if (age !in 0L..MAX_MOTION_AGE_SECONDS) return null

        val rows = byTimestamp.values.toList()
        if (rows.size < MIN_DISTINCT_SAMPLES || rows.last().ts - rows.first().ts < MIN_SPAN_SECONDS) {
            return null
        }
        if (rows.zipWithNext().any { (previous, current) ->
                current.ts - previous.ts > MAX_SAMPLE_GAP_SECONDS
            }
        ) return null

        val windowStart = latest.ts - SMOOTHING_WINDOW_SECONDS
        val recentRows = rows.filter { it.ts >= windowStart }

        var sum = 0.0
        var deltas = 0
        for (index in 1 until recentRows.size) {
            val previous = recentRows[index - 1]
            val current = recentRows[index]
            val dx = current.x - previous.x
            val dy = current.y - previous.y
            val dz = current.z - previous.z
            val delta = sqrt(dx * dx + dy * dy + dz * dz)
            if (!delta.isFinite()) return null
            sum += delta
            deltas += 1
        }
        if (deltas == 0) return null
        return TimestampedWristMotionEvidence(
            movementG = sum / deltas.toDouble(),
            observedAtMillis = latest.ts * 1_000L,
            sampleCount = recentRows.size,
        )
    }

    /** Compatibility helper for analytics callers that only need the qualified motion magnitude. */
    fun recentIntensityG(gravity: List<GravitySample>, nowSec: Long): Double? =
        derive(gravity, nowSec)?.movementG
}

/** Cross-signal freshness and source-integrity gate, matching the Apple stress evidence policy. */
object StressEvidencePolicy {
    const val MAXIMUM_PHYSIOLOGY_AGE_MILLIS: Long = 15_000L
    const val MAXIMUM_RR_BUFFER_GAP_MILLIS: Long = 30_000L
    const val MAXIMUM_MOTION_RR_SKEW_MILLIS: Long = 90_000L

    fun shouldResetRrBuffer(previousReceivedAtMillis: Long?, currentReceivedAtMillis: Long): Boolean {
        val previous = previousReceivedAtMillis ?: return false
        val gap = currentReceivedAtMillis - previous
        return gap < 0L || gap > MAXIMUM_RR_BUFFER_GAP_MILLIS
    }

    fun qualifiedMotion(
        nowMillis: Long,
        rrReceivedAtMillis: Long?,
        heartRateReceivedAtMillis: Long?,
        motion: TimestampedWristMotionEvidence?,
        connected: Boolean,
        bonded: Boolean,
        encryptedBond: Boolean,
        worn: Boolean,
    ): Double? {
        if (!connected || !bonded || !encryptedBond || !worn) return null
        val rrAt = rrReceivedAtMillis ?: return null
        val heartRateAt = heartRateReceivedAtMillis ?: return null
        if (!isFresh(rrAt, nowMillis) || !isFresh(heartRateAt, nowMillis)) return null
        val observedMotion = motion ?: return null
        if (!observedMotion.movementG.isFinite()) return null
        if (kotlin.math.abs(observedMotion.observedAtMillis - rrAt) > MAXIMUM_MOTION_RR_SKEW_MILLIS) {
            return null
        }
        return observedMotion.movementG
    }

    private fun isFresh(observedAtMillis: Long, nowMillis: Long): Boolean {
        val age = nowMillis - observedAtMillis
        return age in 0L..MAXIMUM_PHYSIOLOGY_AGE_MILLIS
    }
}
