package com.noop.ui

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
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
// The Today screen's "Key Metrics" grid has ten available tiles. This lets the user pin three to five in
// their preferred order. A fresh install starts with NOOP's three core daily signals — Recovery, Effort,
// and Sleep — while every other metric follows them in the complete catalog. Persistence is display-only.
//
// Stored as a single comma-joined string of metric keys in SharedPreferences ("today.keyMetrics"), the
// same mechanism every other Android preference uses. Mirrors the macOS KeyMetricPrefs.swift +
// @AppStorage("today.keyMetrics"). Unknown keys are dropped on read so a removed tile can't crash, and
// any known key missing from the saved list is treated as unpinned (the editor still re-lists it).

/**
 * One of the Today screen's Key-Metric tiles. The [raw] is the stable persisted identifier — keep it
 * byte-identical to the macOS `KeyMetric` enum so a backup/restore reads the same layout on either OS.
 */
enum class KeyMetric(
    val raw: String,
    @StringRes val titleRes: Int,
    val icon: ImageVector,
    /** True only when the tile's value has a real, bounded progress axis. Raw vitals deliberately stay
     *  false: mapping HRV, resting HR, respiration, etc. to an arbitrary ceiling makes a decorative fill
     *  look like "more is better" health progress. */
    val isBoundedProgress: Boolean = false,
) {
    CHARGE("charge", R.string.l10n_today_screen_recovery_ea924f72, Icons.Filled.Bolt, isBoundedProgress = true),
    EFFORT("effort", R.string.trends_effort, Icons.Filled.LocalFireDepartment, isBoundedProgress = true),
    REST("rest", R.string.l10n_today_screen_sleep_3cac34e6, Icons.Filled.Bedtime, isBoundedProgress = true),
    HRV("hrv", R.string.widget_hrv, Icons.Filled.MonitorHeart),
    RESTING_HR("restingHr", R.string.l10n_today_screen_resting_hr_26677094, Icons.Filled.Favorite),
    BLOOD_OXYGEN("bloodOxygen", R.string.l10n_today_screen_blood_oxygen_a8ad9ff5, Icons.Filled.WaterDrop),
    RESPIRATORY("respiratory", R.string.l10n_today_screen_respiratory_1cd8c175, Icons.Filled.Air),
    STEPS("steps", R.string.l10n_today_screen_steps_cdde4f20, Icons.AutoMirrored.Filled.DirectionsWalk),
    WEIGHT("weight", R.string.l10n_today_screen_weight_69c0b815, Icons.Filled.MonitorWeight),
    CALORIES("calories", R.string.l10n_today_screen_calories_3e62ecfe, Icons.Filled.LocalFireDepartment);

    companion object {
        fun fromRaw(raw: String?): KeyMetric? = entries.firstOrNull { it.raw == raw }

        /** Canonical catalog order. Includes every choice and orders unselected editor rows. */
        val defaultOrder: List<KeyMetric> = listOf(
            CHARGE, EFFORT, REST, HRV, RESTING_HR,
            BLOOD_OXYGEN, RESPIRATORY, STEPS, WEIGHT, CALORIES,
        )

        /** NOOP's useful fresh-install starting point. Users can replace or extend it up to five. */
        val defaultSelection: List<KeyMetric> = listOf(CHARGE, EFFORT, REST)
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
    const val MAX_SELECTION_COUNT = 5
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

    /** The pinned tiles in display order. Empty/unset preferences yield the three core defaults. */
    fun enabled(context: Context): List<KeyMetric> =
        decodeEnabled(NoopPrefs.of(context).getString(KEY_LAYOUT, null))

    /** Persist a valid ordered pin set; the preference boundary enforces the same invariants as the UI. */
    fun setEnabled(context: Context, metrics: List<KeyMetric>) {
        NoopPrefs.of(context).edit().putString(KEY_LAYOUT, encode(metrics)).apply()
    }

    /** Encode an ordered, deduplicated pin set capped at five. */
    fun encode(metrics: List<KeyMetric>): String =
        normalized(metrics).joinToString(",") { it.raw }

    /**
     * Decode the stored string into an ordered pin set. Empty, unset, or all-unknown data yields the
     * three core defaults. Older versions allowed more than five; their first five survive in order.
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

    /** Ordered dedupe + bounds. Short legacy selections retain their order and fill from the defaults. */
    fun normalized(metrics: List<KeyMetric>): List<KeyMetric> {
        val selected = LinkedHashSet(metrics.distinct().take(MAX_SELECTION_COUNT))
        (KeyMetric.defaultSelection + KeyMetric.defaultOrder).forEach { fallback ->
            if (selected.size < MIN_SELECTION_COUNT) selected.add(fallback)
        }
        return selected.take(MAX_SELECTION_COUNT)
    }

    /** Full catalog with the saved 3-to-5 pins first; display ordering never mutates the saved pins. */
    fun catalogOrder(startingWith: List<KeyMetric>): List<KeyMetric> {
        val selected = normalized(startingWith)
        val selectedSet = selected.toHashSet()
        return selected + KeyMetric.defaultOrder.filter { it !in selectedSet }
    }
}
