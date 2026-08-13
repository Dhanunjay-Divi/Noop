package com.noop.analytics

import kotlin.math.roundToInt

/**
 * Profile provenance stored beside age-shaped metric rows. Tokens are small exact integers encoded as
 * `Double`, so stale-profile values can be rejected without a Room/schema migration.
 */
object AgeMetricProfile {
    const val FITNESS_AGE_KEY = "fitness_age_profile_v1"
    const val VO2MAX_ESTIMATE_KEY = "vo2max_est_profile_v1"
    /**
     * The v1 marker accompanied scores that could use provenance-free DailyMetric.steps. Keep its key
     * only so the computed-series upgrade cleanup can remove it; readers must require the v2 marker.
     */
    const val LEGACY_VITALITY_KEY = "vitality_profile_v1"
    const val VITALITY_KEY = "vitality_profile_v2"

    fun fitnessAgeToken(age: Double, sex: String): Double? {
        val wholeAge = age.roundToInt()
        val sexCode = when (sex.trim().lowercase()) {
            "male" -> 1
            "female" -> 2
            else -> return null
        }
        return (wholeAge * 10 + sexCode).toDouble()
    }

    fun vo2maxEstimateToken(age: Double, sex: String, waistCm: Double): Double? {
        val fitness = fitnessAgeToken(age, sex) ?: return null
        if (!waistCm.isFinite() || waistCm !in 50.0..200.0) return null
        return fitness * 100_000.0 + (waistCm * 100.0).roundToInt()
    }

    fun vitalityToken(age: Double): Double = age.roundToInt().toDouble()

    /** Vitality v2 has no legacy-token grace period: a missing marker may describe a steps-era score. */
    fun acceptsVitality(stored: Double?, current: Double?): Boolean =
        current != null && stored == current

    /** Accept pre-provenance rows only until a relevant profile edit makes provenance mandatory. */
    fun accepts(stored: Double?, current: Double?, provenanceRequired: Boolean): Boolean {
        current ?: return false
        return stored?.let { it == current } ?: !provenanceRequired
    }
}
