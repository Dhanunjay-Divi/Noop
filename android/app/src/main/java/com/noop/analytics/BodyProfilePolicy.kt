package com.noop.analytics

enum class BodyWeightTargetAvailability {
    AVAILABLE,
    MEASUREMENTS_UNCONFIRMED,
    ADULT_SCREENING_UNAVAILABLE,
    CURRENT_WEIGHT_NEEDS_CLINICAL_CONTEXT,
    TARGET_NEEDS_CLINICAL_CONTEXT,
    INVALID_MEASUREMENT,
}

/**
 * Conservative policy for BMI display and optional user-selected weight targets.
 *
 * Adult BMI is a limited height-and-weight screening calculation. Ages below 20
 * require age- and sex-specific interpretation, so the adult value is withheld.
 * NOOP never chooses a target or a rate of change.
 */
object BodyProfilePolicy {
    const val ADULT_MINIMUM_AGE = 20
    const val MINIMUM_ADULT_SCREENING_BMI = 18.5

    private val plausibleWeightKg = 20.0..400.0
    private val plausibleHeightCm = 100.0..250.0
    private val plausibleBmi = 5.0..100.0

    fun adultBmi(
        age: Int,
        weightKg: Double,
        heightCm: Double,
        measurementsConfirmed: Boolean,
    ): Double? {
        if (!measurementsConfirmed || age < ADULT_MINIMUM_AGE) return null
        if (!weightKg.isFinite() || weightKg !in plausibleWeightKg) return null
        if (!heightCm.isFinite() || heightCm !in plausibleHeightCm) return null
        val metres = heightCm / 100.0
        val bmi = weightKg / (metres * metres)
        return bmi.takeIf { it.isFinite() && it in plausibleBmi }
    }

    fun targetAvailability(
        age: Int,
        currentWeightKg: Double,
        heightCm: Double,
        targetWeightKg: Double?,
        measurementsConfirmed: Boolean,
    ): BodyWeightTargetAvailability {
        if (!measurementsConfirmed) {
            return BodyWeightTargetAvailability.MEASUREMENTS_UNCONFIRMED
        }
        if (age < ADULT_MINIMUM_AGE) {
            return BodyWeightTargetAvailability.ADULT_SCREENING_UNAVAILABLE
        }
        val currentBmi = adultBmi(
            age = age,
            weightKg = currentWeightKg,
            heightCm = heightCm,
            measurementsConfirmed = true,
        ) ?: return BodyWeightTargetAvailability.INVALID_MEASUREMENT
        if (currentBmi < MINIMUM_ADULT_SCREENING_BMI) {
            return BodyWeightTargetAvailability.CURRENT_WEIGHT_NEEDS_CLINICAL_CONTEXT
        }
        if (targetWeightKg == null) return BodyWeightTargetAvailability.AVAILABLE
        val targetBmi = adultBmi(
            age = age,
            weightKg = targetWeightKg,
            heightCm = heightCm,
            measurementsConfirmed = true,
        ) ?: return BodyWeightTargetAvailability.INVALID_MEASUREMENT
        return if (targetBmi >= MINIMUM_ADULT_SCREENING_BMI) {
            BodyWeightTargetAvailability.AVAILABLE
        } else {
            BodyWeightTargetAvailability.TARGET_NEEDS_CLINICAL_CONTEXT
        }
    }
}
