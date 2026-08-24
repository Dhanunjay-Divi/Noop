package com.noop.ui

import androidx.annotation.StringRes
import com.noop.R

/**
 * Localized, medically conservative education shown beneath an Explore trend.
 *
 * Resource ids keep the catalog testable without an Android context and keep translated prose out of
 * metric identity or storage. Unknown long-format metrics intentionally use a generic fallback rather
 * than guessing what a newly imported value means.
 */
internal data class AndroidMetricEducation(
    @StringRes val whatItIs: Int,
    @StringRes val whyItMatters: Int,
    @StringRes val howMeasured: Int,
    @StringRes val limitations: Int,
    @StringRes val whatYouCanTry: Int,
    val isMetricSpecific: Boolean = true,
)

internal object AndroidMetricKnowledge {
    private val recovery = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_recovery_what,
        whyItMatters = R.string.appwide_metric_education_recovery_why,
        howMeasured = R.string.appwide_metric_education_recovery_method,
        limitations = R.string.appwide_metric_education_recovery_limits,
        whatYouCanTry = R.string.appwide_metric_education_recovery_action,
    )
    private val effort = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_effort_what,
        whyItMatters = R.string.appwide_metric_education_effort_why,
        howMeasured = R.string.appwide_metric_education_effort_method,
        limitations = R.string.appwide_metric_education_effort_limits,
        whatYouCanTry = R.string.appwide_metric_education_effort_action,
    )
    private val hrv = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_hrv_what,
        whyItMatters = R.string.appwide_metric_education_hrv_why,
        howMeasured = R.string.appwide_metric_education_hrv_method,
        limitations = R.string.appwide_metric_education_hrv_limits,
        whatYouCanTry = R.string.appwide_metric_education_hrv_action,
    )
    private val restingHeartRate = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_rhr_what,
        whyItMatters = R.string.appwide_metric_education_rhr_why,
        howMeasured = R.string.appwide_metric_education_rhr_method,
        limitations = R.string.appwide_metric_education_rhr_limits,
        whatYouCanTry = R.string.appwide_metric_education_rhr_action,
    )
    private val sleepDuration = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_sleep_what,
        whyItMatters = R.string.appwide_metric_education_sleep_why,
        howMeasured = R.string.appwide_metric_education_sleep_method,
        limitations = R.string.appwide_metric_education_sleep_limits,
        whatYouCanTry = R.string.appwide_metric_education_sleep_action,
    )
    private val sleepEfficiency = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_efficiency_what,
        whyItMatters = R.string.appwide_metric_education_efficiency_why,
        howMeasured = R.string.appwide_metric_education_efficiency_method,
        limitations = R.string.appwide_metric_education_efficiency_limits,
        whatYouCanTry = R.string.appwide_metric_education_efficiency_action,
    )
    private val bloodOxygen = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_spo2_what,
        whyItMatters = R.string.appwide_metric_education_spo2_why,
        howMeasured = R.string.appwide_metric_education_spo2_method,
        limitations = R.string.appwide_metric_education_spo2_limits,
        whatYouCanTry = R.string.appwide_metric_education_spo2_action,
    )
    private val respiratoryRate = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_resp_what,
        whyItMatters = R.string.appwide_metric_education_resp_why,
        howMeasured = R.string.appwide_metric_education_resp_method,
        limitations = R.string.appwide_metric_education_resp_limits,
        whatYouCanTry = R.string.appwide_metric_education_resp_action,
    )
    private val dailyHeartRate = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_daily_hr_what,
        whyItMatters = R.string.appwide_metric_education_daily_hr_why,
        howMeasured = R.string.appwide_metric_education_daily_hr_method,
        limitations = R.string.appwide_metric_education_daily_hr_limits,
        whatYouCanTry = R.string.appwide_metric_education_daily_hr_action,
    )
    private val nutritionLog = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_nutrition_what,
        whyItMatters = R.string.appwide_metric_education_nutrition_why,
        howMeasured = R.string.appwide_metric_education_nutrition_method,
        limitations = R.string.appwide_metric_education_nutrition_limits,
        whatYouCanTry = R.string.appwide_metric_education_nutrition_action,
    )
    private val mood = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_mood_what,
        whyItMatters = R.string.appwide_metric_education_mood_why,
        howMeasured = R.string.appwide_metric_education_mood_method,
        limitations = R.string.appwide_metric_education_mood_limits,
        whatYouCanTry = R.string.appwide_metric_education_mood_action,
    )
    private val bodyTemperature = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_body_temp_what,
        whyItMatters = R.string.appwide_metric_education_body_temp_why,
        howMeasured = R.string.appwide_metric_education_body_temp_method,
        limitations = R.string.appwide_metric_education_body_temp_limits,
        whatYouCanTry = R.string.appwide_metric_education_body_temp_action,
    )
    private val fallback = AndroidMetricEducation(
        whatItIs = R.string.appwide_metric_education_generic_what,
        whyItMatters = R.string.appwide_metric_education_generic_why,
        howMeasured = R.string.appwide_metric_education_generic_method,
        limitations = R.string.appwide_metric_education_generic_limits,
        whatYouCanTry = R.string.appwide_metric_education_generic_action,
        isMetricSpecific = false,
    )

    internal val specificallySupportedKeys: Set<String> = setOf(
        "recovery",
        "strain",
        "effort",
        "hrv",
        "avg_hrv",
        "rhr",
        "resting_hr",
        "sleep",
        "sleep_total_min",
        "efficiency",
        "sleep_efficiency",
        "spo2",
        "spo2_pct",
        "resp",
        "resp_rate",
        "respiratory_rate",
        "avg_hr",
        "max_hr",
        "calories_in",
        "protein_g",
        "carbs_g",
        "fat_g",
        "mood",
        "body_temp",
        "basal_body_temp",
    )

    internal fun educationFor(metricKey: String): AndroidMetricEducation = when (metricKey.lowercase()) {
        "recovery" -> recovery
        "strain", "effort" -> effort
        "hrv", "avg_hrv" -> hrv
        "rhr", "resting_hr" -> restingHeartRate
        "sleep", "sleep_total_min" -> sleepDuration
        "efficiency", "sleep_efficiency" -> sleepEfficiency
        "spo2", "spo2_pct" -> bloodOxygen
        "resp", "resp_rate", "respiratory_rate" -> respiratoryRate
        "avg_hr", "max_hr" -> dailyHeartRate
        "calories_in", "protein_g", "carbs_g", "fat_g" -> nutritionLog
        "mood" -> mood
        "body_temp", "basal_body_temp" -> bodyTemperature
        else -> fallback
    }
}
