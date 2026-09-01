package com.noop.analytics

import com.noop.data.GravitySample
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Resolves one daily Effort value from cardiovascular load and low-intensity movement.
 *
 * Edwards TRIMP contributes nothing below 50% heart-rate reserve. For the daily score, measured steps
 * therefore provide a conservative movement floor: steps become walking minutes at 100 steps/minute,
 * each minute receives one quarter of Edwards zone 1's weight, and the resulting low-intensity TRIMP
 * uses the same logarithmic 0..100 map. The final score is max(cardio, movement), never a sum, so workout
 * steps are not counted twice.
 *
 * When a step counter is unavailable, dense-enough wrist gravity provides a conservative fallback.
 * Missing movement leaves the cardiovascular score unchanged. This is approximate, not a reproduction
 * of any proprietary wearable score. Mirrors DailyEffortScorer.swift.
 */
object DailyEffortScorer {
    const val walkingCadenceStepsPerMinute: Double = 100.0
    const val lightMovementWeight: Double = 0.25
    const val walkingMotionThresholdG: Double = 0.15
    const val maximumMotionEvidenceGapSeconds: Double = 120.0
    const val maximumCreditedMotionSeconds: Double = 60.0

    fun score(
        cardioEffort: Double?,
        steps: Int?,
        gravity: List<GravitySample> = emptyList(),
    ): Double? {
        val movement = movementEffort(steps, gravity) ?: return cardioEffort
        return cardioEffort?.let { maxOf(it, movement) } ?: movement
    }

    fun movementEffort(
        steps: Int?,
        gravity: List<GravitySample> = emptyList(),
    ): Double? {
        if (steps != null && steps > 0) return movementEffort(steps)
        val minutes = activeMotionMinutes(gravity) ?: return null
        return movementEffortFromMinutes(minutes)
    }

    fun movementEffort(steps: Int): Double? {
        if (steps <= 0) return null
        return movementEffortFromMinutes(steps.toDouble() / walkingCadenceStepsPerMinute)
    }

    fun activeMotionMinutes(gravity: List<GravitySample>): Double? {
        val rows = gravity
            .filter { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() }
            .sortedBy { it.ts }
        if (rows.size < 2) return null

        var activeSeconds = 0.0
        for (index in 1 until rows.size) {
            val previous = rows[index - 1]
            val current = rows[index]
            val gap = current.ts.toDouble() - previous.ts.toDouble()
            if (gap <= 0.0 || gap > maximumMotionEvidenceGapSeconds) continue

            val dx = current.x - previous.x
            val dy = current.y - previous.y
            val dz = current.z - previous.z
            val intensity = sqrt(dx * dx + dy * dy + dz * dz)
            if (intensity >= walkingMotionThresholdG) {
                activeSeconds += min(gap, maximumCreditedMotionSeconds)
            }
        }
        return if (activeSeconds > 0.0) activeSeconds / 60.0 else null
    }

    private fun movementEffortFromMinutes(minutes: Double): Double? {
        if (!minutes.isFinite() || minutes <= 0.0) return null
        val lowIntensityTrimp = minutes * lightMovementWeight
        return min(StrainScorer.maxStrain, StrainScorer.trimpToStrain(lowIntensityTrimp))
    }
}
