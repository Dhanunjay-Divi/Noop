package com.noop.ui

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MonitorWeight
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.vector.ImageVector
import com.noop.R

// MARK: - Editable Key-Metrics layout (#251)
//
// The Today screen's "Key Metrics" grid exposes every Today-ready tile. This lets the user pin three to six in
// their preferred order. Recovery, Sleep, and Effort already lead the Today hero, so a fresh install starts
// with six complementary signals: HRV, resting heart rate, blood oxygen, respiratory rate, steps, and
// weight. Every metric remains available in the editor and full history.
// Persistence is display-only.
//
// Stored as a single comma-joined string of metric keys in SharedPreferences ("today.keyMetrics"), the
// same mechanism every other Android preference uses. Mirrors the macOS KeyMetricPrefs.swift +
// @AppStorage("today.keyMetrics"). Unknown keys are dropped on read so a removed tile can't crash, and
// any known key missing from the saved list is treated as unpinned and remains available in the editor.

/**
 * One of the Today screen's Key-Metric tiles. The [raw] is the stable persisted identifier — keep it
 * byte-identical to the macOS `KeyMetric` enum so a backup/restore reads the same layout on either OS.
 */
enum class KeyMetricGroup {
    DAILY_SIGNAL,
    VITALS,
    SLEEP,
    ACTIVITY,
    WELLBEING,
}

enum class KeyMetricOrigin {
    MEASURED_IMPORTED,
    SOURCE_DEPENDENT,
    NOOP_INSIGHT,
}

enum class KeyMetric(
    val raw: String,
    @StringRes val titleRes: Int,
    val icon: ImageVector,
    val group: KeyMetricGroup,
    val origin: KeyMetricOrigin,
    /** True only when the tile's value has a real, bounded progress axis. Raw vitals deliberately stay
     *  false: mapping HRV, resting HR, respiration, etc. to an arbitrary ceiling makes a decorative fill
     *  look like "more is better" health progress. */
    val isBoundedProgress: Boolean = false,
) {
    CHARGE(
        "charge",
        R.string.l10n_today_screen_recovery_ea924f72,
        Icons.Filled.Bolt,
        KeyMetricGroup.DAILY_SIGNAL,
        KeyMetricOrigin.NOOP_INSIGHT,
        isBoundedProgress = true,
    ),
    EFFORT(
        "effort",
        R.string.trends_effort,
        Icons.Filled.LocalFireDepartment,
        KeyMetricGroup.DAILY_SIGNAL,
        KeyMetricOrigin.NOOP_INSIGHT,
        isBoundedProgress = true,
    ),
    REST(
        "rest",
        R.string.l10n_today_screen_sleep_3cac34e6,
        Icons.Filled.Bedtime,
        KeyMetricGroup.DAILY_SIGNAL,
        KeyMetricOrigin.NOOP_INSIGHT,
        isBoundedProgress = true,
    ),
    HRV(
        "hrv",
        R.string.widget_hrv,
        Icons.Filled.MonitorHeart,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    RESTING_HR(
        "restingHr",
        R.string.l10n_today_screen_resting_hr_26677094,
        Icons.Filled.Favorite,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    AVERAGE_HR(
        "averageHr",
        R.string.explore_metric_average_heart_rate,
        Icons.Filled.Favorite,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    MAX_HR(
        "maxHr",
        R.string.explore_metric_max_heart_rate,
        Icons.Filled.Bolt,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    BLOOD_OXYGEN(
        "bloodOxygen",
        R.string.l10n_today_screen_blood_oxygen_a8ad9ff5,
        Icons.Filled.WaterDrop,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    RESPIRATORY(
        "respiratory",
        R.string.l10n_today_screen_respiratory_1cd8c175,
        Icons.Filled.Air,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    SKIN_TEMP(
        "skinTemp",
        R.string.l10n_health_screen_skin_temperature_f59127f6,
        Icons.Filled.AcUnit,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    VO2_MAX(
        "vo2Max",
        R.string.appwide_metric_vo2_max,
        Icons.Filled.Air,
        KeyMetricGroup.VITALS,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    ASLEEP_TIME(
        "asleepTime",
        R.string.appwide_metric_asleep_time,
        Icons.Filled.Bedtime,
        KeyMetricGroup.SLEEP,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    STEPS(
        "steps",
        R.string.l10n_today_screen_steps_cdde4f20,
        Icons.AutoMirrored.Filled.DirectionsWalk,
        KeyMetricGroup.ACTIVITY,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    CALORIES(
        "calories",
        R.string.l10n_today_screen_calories_3e62ecfe,
        Icons.Filled.LocalFireDepartment,
        KeyMetricGroup.ACTIVITY,
        KeyMetricOrigin.SOURCE_DEPENDENT,
    ),
    STRESS(
        "stress",
        R.string.nav_stress,
        Icons.Filled.MonitorHeart,
        KeyMetricGroup.WELLBEING,
        KeyMetricOrigin.NOOP_INSIGHT,
    ),
    VITALITY(
        "vitality",
        R.string.l10n_health_screen_vitality_be320b06,
        Icons.Filled.Bolt,
        KeyMetricGroup.WELLBEING,
        KeyMetricOrigin.NOOP_INSIGHT,
    ),
    WEIGHT(
        "weight",
        R.string.l10n_today_screen_weight_69c0b815,
        Icons.Filled.MonitorWeight,
        KeyMetricGroup.ACTIVITY,
        KeyMetricOrigin.MEASURED_IMPORTED,
    ),
    HYDRATION(
        "hydration",
        R.string.nav_hydration,
        Icons.Filled.WaterDrop,
        KeyMetricGroup.ACTIVITY,
        KeyMetricOrigin.MEASURED_IMPORTED,
        isBoundedProgress = true,
    );

    companion object {
        fun fromRaw(raw: String?): KeyMetric? = entries.firstOrNull { it.raw == raw }

        /** Canonical catalog order. Includes every choice and orders unselected editor rows. */
        val defaultOrder: List<KeyMetric> = listOf(
            CHARGE, REST, EFFORT,
            HRV, RESTING_HR, AVERAGE_HR, MAX_HR,
            BLOOD_OXYGEN, RESPIRATORY, VO2_MAX, SKIN_TEMP,
            ASLEEP_TIME,
            STEPS, CALORIES, WEIGHT, HYDRATION,
            STRESS, VITALITY,
        )

        /** Fresh-install secondary signals; the hero already owns Recovery, Sleep, and Effort. */
        val defaultSelection: List<KeyMetric> = listOf(
            HRV,
            RESTING_HR,
            BLOOD_OXYGEN,
            RESPIRATORY,
            STEPS,
            WEIGHT,
        )
    }
}

/**
 * Display-only persistence for the Key-Metrics layout. Holds an ORDERED list of pinned tiles; a tile not
 * in the list remains visible after them. SharedPreferences isn't reactive, so Today reads this once into
 * remembered state (like the other prefs) and re-reads on the recomposition the editor's write triggers.
 * Mirrors the macOS KeyMetricPrefs (@AppStorage "today.keyMetrics").
 */
object KeyMetricPrefs {
    internal const val KEY_LAYOUT = "today.keyMetrics"
    const val MIN_SELECTION_COUNT = 3
    const val MAX_SELECTION_COUNT = 6
    private const val KEY_DETAILED = "today.keyMetricsDetailed"

    /** Whether the Key-Metrics tiles render DETAILED — taller/squarer with a 14-day trend graph under the
     *  fill bar. Display-only, default off (the compact ktile look). Set from the #251 editor's switch;
     *  key name is parity-ready for the macOS/iOS twin (@AppStorage "today.keyMetricsDetailed"). */
    fun detailed(context: Context): Boolean =
        NoopPrefs.of(context).getBoolean(KEY_DETAILED, false)

    fun setDetailed(context: Context, value: Boolean) {
        NoopPrefs.of(context).edit().putBoolean(KEY_DETAILED, value).apply()
    }

    private const val KEY_WINDOW = "today.keyMetricsWindowDays"

    /** Trailing trend window (calendar days) the DETAILED tiles graph: 2, 7 or 14 (default). Shared key
     *  with the iOS twin; an unknown stored value coerces to 14 so a bad pref can't skew the window math. */
    fun detailWindowDays(context: Context): Int =
        NoopPrefs.of(context).getInt(KEY_WINDOW, 14).let { if (it == 2 || it == 7 || it == 14) it else 14 }

    fun setDetailWindowDays(context: Context, value: Int) {
        NoopPrefs.of(context).edit().putInt(KEY_WINDOW, value).apply()
    }

    /** The pinned tiles in display order. Empty/unset preferences yield the secondary-signal defaults. */
    fun enabled(context: Context): List<KeyMetric> =
        decodeEnabled(NoopPrefs.of(context).getString(KEY_LAYOUT, null))

    /** Persist a valid ordered pin set; the preference boundary enforces the same invariants as the UI. */
    fun setEnabled(context: Context, metrics: List<KeyMetric>) {
        NoopPrefs.of(context).edit().putString(KEY_LAYOUT, encode(metrics)).apply()
    }

    /** Encode an ordered, deduplicated pin set capped at six. */
    fun encode(metrics: List<KeyMetric>): String =
        normalized(metrics).joinToString(",") { it.raw }

    /**
     * Decode the stored string into an ordered pin set. Empty, unset, or all-unknown data yields the
     * fresh-install defaults. Older versions allowed more than six; their first six survive in order.
     */
    fun decodeEnabled(raw: String?): List<KeyMetric> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return KeyMetric.defaultSelection
        val seen = LinkedHashSet<KeyMetric>()
        trimmed.split(",").forEach { token ->
            if (seen.size < MAX_SELECTION_COUNT) {
                KeyMetric.fromRaw(token.trim())?.let { seen.add(it) }
            }
        }
        return normalized(seen.toList())
    }

    /** Ordered dedupe + bounds. Empty restores the complete default; short custom layouts fill to three. */
    fun normalized(metrics: List<KeyMetric>): List<KeyMetric> {
        val selected = LinkedHashSet(metrics.distinct().take(MAX_SELECTION_COUNT))
        if (selected.isEmpty()) return KeyMetric.defaultSelection
        (KeyMetric.defaultSelection + KeyMetric.defaultOrder).forEach { fallback ->
            if (selected.size < MIN_SELECTION_COUNT) selected.add(fallback)
        }
        return selected.take(MAX_SELECTION_COUNT)
    }

    /** Full catalog with the saved 3-to-6 pins first; display ordering never mutates the saved pins. */
    fun catalogOrder(startingWith: List<KeyMetric>): List<KeyMetric> {
        val selected = normalized(startingWith)
        val selectedSet = selected.toHashSet()
        return selected + KeyMetric.defaultOrder.filter { it !in selectedSet }
    }
}
