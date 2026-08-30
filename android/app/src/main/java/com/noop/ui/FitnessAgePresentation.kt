package com.noop.ui

import com.noop.R
import kotlin.math.abs
import kotlin.math.roundToInt

internal data class FitnessAgeParts(
    val totalMonths: Int,
    val years: Int,
    val months: Int,
)

/** Month-precise presentation shared by Today, Health, and metric history. */
internal object FitnessAgePresentation {
    fun parts(estimate: Double): FitnessAgeParts {
        val totalMonths = (estimate * 12.0).roundToInt().coerceAtLeast(0)
        return FitnessAgeParts(
            totalMonths = totalMonths,
            years = totalMonths / 12,
            months = totalMonths % 12,
        )
    }

    fun value(estimate: Double): String {
        val parts = parts(estimate)
        // Product notation: 23.11 means 23 years and 11 months, not 23.11 decimal years.
        return "${parts.years}.${parts.months}"
    }

    fun vesselValue(estimate: Double): String = value(estimate)

    fun spokenValue(estimate: Double): String = duration(parts(estimate).totalMonths)

    fun localizedSpokenValue(estimate: Double): String =
        localizedDuration(parts(estimate).totalMonths)

    fun duration(totalMonths: Int): String {
        val months = totalMonths.coerceAtLeast(0)
        val yearsPart = months / 12
        val monthsPart = months % 12
        return when {
            yearsPart == 0 -> "$monthsPart mo"
            monthsPart == 0 -> "$yearsPart yr"
            else -> "$yearsPart yr $monthsPart mo"
        }
    }

    fun comparison(estimate: Double, profileAge: Int): String {
        val deltaMonths = profileAge * 12 - parts(estimate).totalMonths
        if (deltaMonths == 0) return "About the same as your profile age"
        val difference = duration(abs(deltaMonths))
        return if (deltaMonths > 0) {
            "$difference younger than your profile age"
        } else {
            "$difference older than your profile age"
        }
    }

    fun localizedComparison(estimate: Double, profileAge: Int): String {
        val deltaMonths = profileAge * 12 - parts(estimate).totalMonths
        if (deltaMonths == 0) {
            return uiString(R.string.appwide_fitness_age_same_profile_age)
        }
        val difference = localizedDuration(abs(deltaMonths))
        return if (deltaMonths > 0) {
            uiString(R.string.appwide_fitness_age_younger_duration_profile_age, difference)
        } else {
            uiString(R.string.appwide_fitness_age_older_duration_profile_age, difference)
        }
    }

    fun weeklyProgress(current: Double, previous: Double): String {
        val improvementMonths = parts(previous).totalMonths - parts(current).totalMonths
        if (improvementMonths == 0) return "No change this week"
        val difference = duration(abs(improvementMonths))
        return if (improvementMonths > 0) {
            "$difference younger this week"
        } else {
            "$difference older this week"
        }
    }

    fun localizedWeeklyProgress(current: Double, previous: Double): String {
        val improvementMonths = parts(previous).totalMonths - parts(current).totalMonths
        if (improvementMonths == 0) {
            return uiString(R.string.appwide_fitness_age_no_change_this_week)
        }
        val difference = localizedDuration(abs(improvementMonths))
        return if (improvementMonths > 0) {
            uiString(R.string.appwide_fitness_age_younger_this_week, difference)
        } else {
            uiString(R.string.appwide_fitness_age_older_this_week, difference)
        }
    }

    private fun localizedDuration(totalMonths: Int): String {
        val months = totalMonths.coerceAtLeast(0)
        val yearsPart = months / 12
        val monthsPart = months % 12
        return when {
            yearsPart == 0 -> uiString(R.string.appwide_fitness_age_duration_months, monthsPart)
            monthsPart == 0 -> uiString(R.string.appwide_fitness_age_duration_years, yearsPart)
            else -> uiString(
                R.string.appwide_fitness_age_duration_years_months,
                yearsPart,
                monthsPart,
            )
        }
    }
}
