package com.noop.ingest

import android.content.Context
import android.content.SharedPreferences
import com.noop.analytics.WhoopReferenceCalibration
import org.json.JSONObject

/**
 * Durable provenance evidence for official metric/day pairs written by the current CSV importer.
 *
 * Existing Room tables predate per-row importer revisions. This tiny manifest lets calibration reject
 * legacy rows that cannot prove their import path without rewriting or deleting biometric values.
 */
class WhoopReferenceImportManifest private constructor(
    private val preferences: SharedPreferences,
    private val namespace: String = "noop.whoopReferenceImportManifest.v2",
) {
    fun replaceOfficialMetrics(
        entries: List<Pair<String, String>>,
        deviceId: String,
        schemaRevision: String,
        from: String,
        to: String,
        managedKeys: Set<String>,
    ): Boolean {
        if (deviceId.isBlank() ||
            schemaRevision.isBlank() ||
            !WhoopReferenceCalibration.validDay(from) ||
            !WhoopReferenceCalibration.validDay(to) ||
            from > to
        ) {
            return false
        }
        val keys = managedKeys.filterTo(linkedSetOf(), ::validMetricKey)
        if (keys.isEmpty()) return false

        val state = load(deviceId)
        val retained = JSONObject()
        state.keys().forEach { metricDay ->
            val parsed = parseMetricDayKey(metricDay)
            if (parsed == null ||
                parsed.first !in from..to ||
                parsed.second !in keys
            ) {
                retained.put(metricDay, state.optString(metricDay))
            }
        }
        entries.forEach { (day, metricKey) ->
            if (day in from..to &&
                WhoopReferenceCalibration.validDay(day) &&
                metricKey in keys
            ) {
                retained.put(metricDayKey(day, metricKey), schemaRevision)
            }
        }
        // Imports are rare and this manifest is tiny. A synchronous commit is intentional: callers
        // invalidate the affected range before replacing SQLite rows, so a process death can only leave
        // a false negative (re-import required), never stale verification attached to changed values.
        return preferences.edit().putString(storageKey(deviceId), retained.toString()).commit()
    }

    fun invalidateOfficialMetrics(
        deviceId: String,
        schemaRevision: String,
        from: String,
        to: String,
        managedKeys: Set<String>,
    ): Boolean = replaceOfficialMetrics(
        entries = emptyList(),
        deviceId = deviceId,
        schemaRevision = schemaRevision,
        from = from,
        to = to,
        managedKeys = managedKeys,
    )

    fun remove(deviceId: String): Boolean {
        return preferences.edit().remove(storageKey(deviceId)).commit()
    }

    fun verifiedDays(
        deviceId: String,
        schemaRevision: String,
        metricKey: String,
    ): Set<String> {
        if (deviceId.isBlank() || schemaRevision.isBlank() || !validMetricKey(metricKey)) {
            return emptySet()
        }
        val suffix = "|$metricKey"
        val state = load(deviceId)
        return buildSet {
            state.keys().forEach { metricDay ->
                if (state.optString(metricDay) != schemaRevision || !metricDay.endsWith(suffix)) {
                    return@forEach
                }
                val day = metricDay.removeSuffix(suffix)
                if (WhoopReferenceCalibration.validDay(day)) add(day)
            }
        }
    }

    private fun load(deviceId: String): JSONObject {
        val raw = preferences.getString(storageKey(deviceId), null) ?: return JSONObject()
        return runCatching { JSONObject(raw) }.getOrElse {
            preferences.edit().remove(storageKey(deviceId)).commit()
            JSONObject()
        }
    }

    private fun storageKey(deviceId: String) = "$namespace.$deviceId"

    companion object {
        private const val PREFERENCES_NAME = "noop.reference-import-manifest"

        fun from(context: Context): WhoopReferenceImportManifest =
            WhoopReferenceImportManifest(
                context.applicationContext.getSharedPreferences(
                    PREFERENCES_NAME,
                    Context.MODE_PRIVATE,
                ),
            )

        internal fun forTesting(
            preferences: SharedPreferences,
            namespace: String = "noop.whoopReferenceImportManifest.v2",
        ) = WhoopReferenceImportManifest(preferences, namespace)

        private fun metricDayKey(day: String, metricKey: String) = "$day|$metricKey"

        private fun parseMetricDayKey(value: String): Pair<String, String>? {
            val split = value.split("|", limit = 2)
            if (split.size != 2 ||
                !WhoopReferenceCalibration.validDay(split[0]) ||
                !validMetricKey(split[1])
            ) {
                return null
            }
            return split[0] to split[1]
        }

        private fun validMetricKey(key: String): Boolean =
            key.isNotEmpty() &&
                key.length <= 80 &&
                key.all { it.isLetterOrDigit() || it == '_' }
    }
}
