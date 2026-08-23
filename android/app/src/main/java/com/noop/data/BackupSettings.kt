package com.noop.data

import android.content.Context
import android.content.SharedPreferences
import com.noop.alarm.SmartAlarmStore
import com.noop.alarm.WindDownScheduler
import com.noop.alarm.WindDownStore
import com.noop.notif.HydrationReminderScheduler
import com.noop.ui.AppearancePrefs
import com.noop.ui.ChartStylePrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import java.time.LocalDate
import org.json.JSONObject

/**
 * The `settings.json` payload inside a `.noopbak` backup (#1000) — the Android twin of the Apple
 * `BackupSettings` in Packages/WhoopStore.
 *
 * A `.noopbak` is a ZIP whose first entry is the SQLite database. That round-trips every row, but the
 * user's profile (age / sex / weight / height / HR-max override) and display preferences live in
 * SharedPreferences (UserDefaults on Apple), so a restore onto a fresh device silently reset them —
 * the "restore doesn't bring back settings/weight/height" half of #1000. This adds a SECOND, optional
 * ZIP entry — `settings.json`, a flat JSON object — carrying exactly one WHITELISTED set of keys.
 *
 * The whitelist is the contract, defined once per platform and mirrored byte-for-byte by the Apple
 * `BackupSettings.whitelist` (same canonical key strings, same JSON kinds). V1 carried profile/unit
 * values, v2 added a schema stamp and exact civil birthday, and v3 adds a bounded set of durable,
 * user-authored display, dashboard, reminder, HRV, and Sleep Planner preferences. Only stable,
 * non-device-specific values are allowed. NEVER add credentials, device/peripheral/install ids,
 * sync cursors, active alarm epochs, delivery de-dup state, or derived planner outputs: backups get
 * copied into cloud folders and attached to GitHub issues, so this file must stay safe to share.
 * Unknown keys in an incoming `settings.json` are dropped; a backup with no `settings.json` (every
 * pre-#1000 backup) is a DB-only restore, as before.
 *
 * [BackupSettingsCodec] is pure JSON + whitelist (plain-JVM unit-testable, no Context); the
 * SharedPreferences boundary lives in [BackupSettingsBridge] below.
 */
object BackupSettingsCodec {

    /** Canonical entry name inside the `.noopbak` ZIP. Matches the Apple exporter byte-for-byte. */
    const val ENTRY_NAME = "settings.json"
    const val SCHEMA_VERSION = 3
    const val SCHEMA_VERSION_KEY = "settings.schemaVersion"
    const val DATE_OF_BIRTH_KEY = "profile.dateOfBirth"

    /** The JSON kind a whitelisted key must decode to. Anything else is dropped, never guessed at. */
    enum class Kind { BOOL, INT, DOUBLE, STRING, CIVIL_DATE }

    /**
     * THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
     * (platform-neutral) names. Mirrors the Apple `BackupSettings.whitelist` exactly.
     *
     * Profile fields power zones/calories/baselines. V3 adds only preferences describing the user's
     * intended setup. Deliberately excluded: credentials, step calibration, device bindings,
     * permission receipts, install/migration state, sync cursors, scheduled-alarm epochs, notification
     * delivery de-duplication, and planner-derived recovery minutes.
     */
    val WHITELIST: Map<String, Kind> = linkedMapOf(
        SCHEMA_VERSION_KEY to Kind.INT,
        "profile.age" to Kind.INT,
        DATE_OF_BIRTH_KEY to Kind.CIVIL_DATE,
        "profile.sex" to Kind.STRING,
        "profile.weightKg" to Kind.DOUBLE,
        "profile.heightCm" to Kind.DOUBLE,
        "profile.waistCm" to Kind.DOUBLE,
        "profile.hrMax" to Kind.INT,
        "units.system" to Kind.STRING,
        "units.mass" to Kind.STRING,
        "units.height" to Kind.STRING,
        "units.temperature" to Kind.STRING,
        "effort.scale" to Kind.STRING,
        "hrv.window" to Kind.STRING,
        "theme.appearance" to Kind.STRING,
        "chart.style" to Kind.STRING,
        "trend.chart.style" to Kind.STRING,
        "noop.showDayCycleBackground" to Kind.BOOL,
        "noop.skyBehindCards" to Kind.BOOL,
        "noop.cardOpacityPercent" to Kind.INT,
        "workoutKeepScreenOn" to Kind.BOOL,
        "today.sectionOrder" to Kind.STRING,
        "today.keyMetrics" to Kind.STRING,
        "today.keyMetricsDetailed" to Kind.BOOL,
        "today.keyMetricsWindowDays" to Kind.INT,
        "noop.hydrationTracking" to Kind.BOOL,
        "windDown.enabled" to Kind.BOOL,
        "windDown.sleepNeedMinutes" to Kind.INT,
        "windDown.goalMode" to Kind.STRING,
        "windDown.leadMinutes" to Kind.INT,
        "sleepPlanner.wakeMinutes" to Kind.INT,
        "notif.masterEnabled" to Kind.BOOL,
        "notif.onlyWhenWorn" to Kind.BOOL,
        "notif.quietHoursEnabled" to Kind.BOOL,
        "notif.quietStartMinutes" to Kind.INT,
        "notif.quietEndMinutes" to Kind.INT,
        "inactivity.enabled" to Kind.BOOL,
        "inactivity.thresholdMinutes" to Kind.INT,
        "inactivity.reNudgeMinutes" to Kind.INT,
        "inactivity.buzzLoops" to Kind.INT,
        "inactivity.activeHoursEnabled" to Kind.BOOL,
        "inactivity.activeStartMinutes" to Kind.INT,
        "inactivity.activeEndMinutes" to Kind.INT,
        "hydrationReminders.enabled" to Kind.BOOL,
        "hydrationReminders.intervalMinutes" to Kind.INT,
        "hydrationReminders.activeStartMinutes" to Kind.INT,
        "hydrationReminders.activeEndMinutes" to Kind.INT,
        "hydrationReminders.adaptiveEnabled" to Kind.BOOL,
        "hydrationReminders.strapBuzzEnabled" to Kind.BOOL,
    )

    /**
     * Encode the whitelisted subset of [values] as the flat `settings.json` object, or null when
     * nothing whitelisted is present (the exporter then omits only `settings.json`; the database and
     * integrity manifest are still written).
     */
    fun encode(values: Map<String, Any?>): String? {
        val obj = JSONObject()
        for ((key, kind) in WHITELIST) {
            if (key == SCHEMA_VERSION_KEY) continue
            val coerced = normalized(key, values[key], kind) ?: continue
            obj.put(key, coerced)
        }
        if (obj.length() == 0) return null
        obj.put(SCHEMA_VERSION_KEY, SCHEMA_VERSION)
        return obj.toString()
    }

    /**
     * Decode a `settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
     * JSON, unknown keys and wrong-typed values all degrade to "fewer keys" - never an error, because
     * a bad settings entry must not fail a restore whose DB half is fine.
     */
    fun decode(json: String): Map<String, Any> {
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return emptyMap()
        val out = LinkedHashMap<String, Any>()
        for ((key, kind) in WHITELIST) {
            if (!obj.has(key)) continue
            normalized(key, obj.opt(key), kind)?.let { out[key] = it }
        }
        return out
    }

    /**
     * Coerce a JSON-decoded (or caller-supplied) value to the whitelist's declared kind, or null.
     * JSON booleans are not [Number]s on the JVM, so `true` can never become age 1 (the Apple side
     * refuses NSNumber-booleans explicitly for the same reason).
     */
    private fun coerce(value: Any?, kind: Kind): Any? = when (kind) {
        Kind.BOOL -> value as? Boolean
        Kind.STRING -> value as? String
        Kind.INT -> (value as? Number)?.toDouble()?.takeIf {
            it.isFinite() && it % 1.0 == 0.0 && it >= Int.MIN_VALUE && it <= Int.MAX_VALUE
        }?.toInt()
        Kind.DOUBLE -> (value as? Number)?.toDouble()?.takeIf(Double::isFinite)
        Kind.CIVIL_DATE -> (value as? String)?.takeIf { raw ->
            runCatching { LocalDate.parse(raw).toString() == raw }.getOrDefault(false)
        }
    }

    /** Type plus key-specific range/enum validation; malformed hand-edited preferences are dropped. */
    private fun normalized(key: String, value: Any?, kind: Kind): Any? {
        val coerced = coerce(value, kind) ?: return null
        return when (key) {
            "profile.age" -> boundedInt(coerced, 13..100)
            DATE_OF_BIRTH_KEY -> (coerced as? String)?.takeIf { encoded ->
                runCatching {
                    val age = java.time.Period.between(LocalDate.parse(encoded), LocalDate.now()).years
                    age in 13..100
                }.getOrDefault(false)
            }
            "profile.sex" -> allowedString(coerced, setOf("male", "female", "nonbinary"))
            "profile.weightKg" -> boundedDouble(coerced, 30.0..250.0)
            "profile.heightCm" -> boundedDouble(coerced, 120.0..230.0)
            "profile.waistCm" -> boundedDouble(coerced, 0.0..200.0)
            "profile.hrMax" -> boundedInt(coerced, 0..230)
            "units.system" -> allowedString(coerced, setOf("metric", "imperial"))
            "units.mass" -> allowedString(coerced, setOf("", "kg", "lb"))
            "units.height" -> allowedString(coerced, setOf("", "cm", "ft_in"))
            "units.temperature" -> allowedString(coerced, setOf("", "celsius", "fahrenheit"))
            "effort.scale" -> allowedString(coerced, setOf("hundred", "whoop"))
            "hrv.window" -> allowedString(coerced, setOf("whole", "deep"))
            "theme.appearance" ->
                allowedString(coerced, setOf("system", "light", "dark", "black"))
            "chart.style" -> allowedString(coerced, setOf("titanium", "classic"))
            "trend.chart.style" -> allowedString(coerced, setOf("line", "bar"))
            "today.sectionOrder" -> (coerced as? String)?.takeIf {
                it.toByteArray(Charsets.UTF_8).size <= 2_048 &&
                    it.all { char -> char.isLetterOrDigit() || char in ".,_- " }
            }
            "today.keyMetrics" -> (coerced as? String)?.takeIf {
                it.toByteArray(Charsets.UTF_8).size <= 2_048 &&
                    it.all { char -> char.isLetterOrDigit() || char in ".,_- " }
            }?.let(::normalizedKeyMetricSelection)
            "noop.cardOpacityPercent" -> boundedInt(coerced, 0..100)
            "today.keyMetricsWindowDays" ->
                (coerced as? Int)?.takeIf { it in setOf(2, 7, 14) }
            "windDown.sleepNeedMinutes" -> boundedInt(coerced, 5 * 60..11 * 60)
            "windDown.goalMode" ->
                allowedString(coerced, setOf("target", "balance", "extraOpportunity"))
            "windDown.leadMinutes" -> boundedInt(coerced, 0..120)
            "sleepPlanner.wakeMinutes",
            "notif.quietStartMinutes", "notif.quietEndMinutes",
            "inactivity.activeStartMinutes", "inactivity.activeEndMinutes",
            "hydrationReminders.activeStartMinutes", "hydrationReminders.activeEndMinutes" ->
                boundedInt(coerced, 0 until 24 * 60)
            "inactivity.thresholdMinutes", "inactivity.reNudgeMinutes" ->
                boundedInt(coerced, 15..120)
            "inactivity.buzzLoops" -> boundedInt(coerced, 1..4)
            "hydrationReminders.intervalMinutes" -> boundedInt(coerced, 60..240)
            else -> coerced
        }
    }

    private fun allowedString(value: Any, allowed: Set<String>): String? =
        (value as? String)?.takeIf(allowed::contains)

    /**
     * Keep the portable dashboard preference inside the app's one-to-five pin contract. Older backups
     * may contain all ten metrics; their first five valid unique ids survive in saved order.
     */
    private fun normalizedKeyMetricSelection(raw: String): String? {
        val allowed = setOf(
            "charge", "effort", "rest", "hrv", "restingHr",
            "bloodOxygen", "respiratory", "steps", "weight", "calories",
        )
        return raw.split(",").asSequence()
            .map(String::trim)
            .filter(allowed::contains)
            .distinct()
            .take(5)
            .toList()
            .takeIf { it.isNotEmpty() }
            ?.joinToString(",")
    }

    private fun boundedInt(value: Any, range: IntRange): Int? =
        (value as? Int)?.takeIf(range::contains)

    private fun boundedDouble(value: Any, range: ClosedFloatingPointRange<Double>): Double? =
        (value as? Double)?.takeIf(range::contains)
}

/**
 * The SharedPreferences boundary for [BackupSettingsCodec]: snapshot this device's whitelisted
 * settings for export, and re-apply a restored payload. Kept separate from the codec so the codec
 * stays plain-JVM testable (this object needs a real Context).
 *
 * Storage mapping (canonical key → where it actually lives here):
 *  - `profile.*`  → the `noop_profile` prefs via [ProfileStore.backupSnapshot]/[ProfileStore.applyBackup]
 *                   (canonical `profile.hrMax` ↔ ProfileStore's `hr_max_override`).
 *  - display, dashboard, and hydration-tracking keys → [NoopPrefs];
 *  - notification, inactivity, hydration-reminder, wind-down, and Sleep Planner keys → their explicit
 *    feature-owned preference files below.
 */
object BackupSettingsBridge {
    private val NOOP_PREFS_KEYS = linkedMapOf(
        "units.system" to NoopPrefs.KEY_UNIT_SYSTEM,
        "units.mass" to NoopPrefs.KEY_MASS_UNIT,
        "units.height" to NoopPrefs.KEY_HEIGHT_UNIT,
        "units.temperature" to NoopPrefs.KEY_TEMPERATURE_UNIT,
        "effort.scale" to UnitPrefs.KEY_EFFORT_SCALE,
        "hrv.window" to UnitPrefs.KEY_HRV_WINDOW,
        "theme.appearance" to "theme.appearance",
        "chart.style" to "chart.style",
        "trend.chart.style" to UnitPrefs.KEY_TREND_CHART_STYLE,
        "noop.showDayCycleBackground" to NoopPrefs.KEY_SHOW_DAY_CYCLE_BACKGROUND,
        "noop.skyBehindCards" to NoopPrefs.KEY_SKY_BEHIND_CARDS,
        "noop.cardOpacityPercent" to NoopPrefs.KEY_CARD_OPACITY,
        "workoutKeepScreenOn" to "workoutKeepScreenOn",
        "today.sectionOrder" to "today.sectionOrder",
        "today.keyMetrics" to "today.keyMetrics",
        "today.keyMetricsDetailed" to "today.keyMetricsDetailed",
        "today.keyMetricsWindowDays" to "today.keyMetricsWindowDays",
        "noop.hydrationTracking" to NoopPrefs.KEY_HYDRATION_TRACKING,
    )
    private val NOTIFICATION_KEYS = linkedMapOf(
        "notif.masterEnabled" to "notif.masterEnabled",
        "notif.onlyWhenWorn" to "notif.onlyWhenWorn",
        "notif.quietHoursEnabled" to "notif.quietHoursEnabled",
        "notif.quietStartMinutes" to "notif.quietStartMinutes",
        "notif.quietEndMinutes" to "notif.quietEndMinutes",
    )
    private val INACTIVITY_KEYS = linkedMapOf(
        "inactivity.enabled" to "inactivity.enabled",
        "inactivity.thresholdMinutes" to "inactivity.thresholdMinutes",
        "inactivity.reNudgeMinutes" to "inactivity.reNudgeMinutes",
        "inactivity.buzzLoops" to "inactivity.buzzLoops",
        "inactivity.activeHoursEnabled" to "inactivity.activeHoursEnabled",
        "inactivity.activeStartMinutes" to "inactivity.activeStartMinutes",
        "inactivity.activeEndMinutes" to "inactivity.activeEndMinutes",
    )
    private val HYDRATION_REMINDER_KEYS = linkedMapOf(
        "hydrationReminders.enabled" to "hydration.reminders.enabled",
        "hydrationReminders.intervalMinutes" to "hydration.reminders.intervalMinutes",
        "hydrationReminders.activeStartMinutes" to "hydration.reminders.startMinutes",
        "hydrationReminders.activeEndMinutes" to "hydration.reminders.endMinutes",
        "hydrationReminders.adaptiveEnabled" to "hydration.reminders.adaptiveEnabled",
        "hydrationReminders.strapBuzzEnabled" to "hydration.reminders.strapBuzz",
    )
    private val WIND_DOWN_KEYS = linkedMapOf(
        "windDown.enabled" to "windDown.enabled",
        "windDown.sleepNeedMinutes" to "windDown.sleepNeedMinutes",
        "windDown.goalMode" to "windDown.goalMode",
        "windDown.leadMinutes" to "windDown.leadMinutes",
    )
    private val SLEEP_PLANNER_KEYS = linkedMapOf(
        "sleepPlanner.wakeMinutes" to "alarm.targetMinutes",
    )

    /** Canonical non-profile keys with an explicit SharedPreferences destination. */
    internal val mappedCanonicalKeys: Set<String>
        get() = buildSet {
            addAll(NOOP_PREFS_KEYS.keys)
            addAll(NOTIFICATION_KEYS.keys)
            addAll(INACTIVITY_KEYS.keys)
            addAll(HYDRATION_REMINDER_KEYS.keys)
            addAll(WIND_DOWN_KEYS.keys)
            addAll(SLEEP_PLANNER_KEYS.keys)
        }

    /** The whitelisted, user-SET settings of this device as the `settings.json` string, or null. */
    fun snapshotJson(context: Context): String? {
        val values = LinkedHashMap<String, Any>()
        values.putAll(ProfileStore.from(context).backupSnapshot())
        val noop = NoopPrefs.of(context)
        snapshot(noop, NOOP_PREFS_KEYS, values)
        snapshot(
            context.getSharedPreferences("noop_notif_prefs", Context.MODE_PRIVATE),
            NOTIFICATION_KEYS,
            values,
        )
        snapshot(
            context.getSharedPreferences("noop_inactivity_prefs", Context.MODE_PRIVATE),
            INACTIVITY_KEYS,
            values,
        )
        snapshot(
            context.getSharedPreferences("noop_hydration_reminders", Context.MODE_PRIVATE),
            HYDRATION_REMINDER_KEYS,
            values,
        )
        snapshot(
            context.getSharedPreferences("noop_wind_down", Context.MODE_PRIVATE),
            WIND_DOWN_KEYS,
            values,
        )
        snapshot(
            context.getSharedPreferences("noop_smart_alarm", Context.MODE_PRIVATE),
            SLEEP_PLANNER_KEYS,
            values,
        )
        return BackupSettingsCodec.encode(values)
    }

    /**
     * Re-apply a restored `settings.json` to this device. The caller ([DataBackup.importFrom]) invokes
     * this only AFTER the DB swap succeeded — never on a failed or rolled-back restore. Keys absent
     * from the payload leave the device's current values alone; the profile setters clamp to their
     * normal ranges, so a hand-edited payload can't write absurd values.
     */
    fun apply(context: Context, json: String) {
        val values = BackupSettingsCodec.decode(json)
        if (values.isEmpty()) return

        ProfileStore.from(context).applyBackup(values)
        apply(NoopPrefs.of(context), NOOP_PREFS_KEYS, values)
        apply(
            context.getSharedPreferences("noop_notif_prefs", Context.MODE_PRIVATE),
            NOTIFICATION_KEYS,
            values,
        )
        apply(
            context.getSharedPreferences("noop_inactivity_prefs", Context.MODE_PRIVATE),
            INACTIVITY_KEYS,
            values,
        )
        apply(
            context.getSharedPreferences("noop_hydration_reminders", Context.MODE_PRIVATE),
            HYDRATION_REMINDER_KEYS,
            values,
        )
        apply(
            context.getSharedPreferences("noop_wind_down", Context.MODE_PRIVATE),
            WIND_DOWN_KEYS,
            values,
        )
        apply(
            context.getSharedPreferences("noop_smart_alarm", Context.MODE_PRIVATE),
            SLEEP_PLANNER_KEYS,
            values,
        )
    }

    /** Refresh process mirrors and OS schedules after settings were committed with the restored DB. */
    fun reconcileAfterRestore(context: Context) {
        val appContext = context.applicationContext
        AppearancePrefs.load(appContext)
        ChartStylePrefs.load(appContext)
        runCatching { HydrationReminderScheduler.reconcile(appContext) }
        runCatching {
            val windDown = WindDownStore.from(appContext)
            if (windDown.enabled) {
                WindDownScheduler.schedule(
                    appContext,
                    windDown,
                    SmartAlarmStore.from(appContext).targetMinutes,
                )
            } else {
                WindDownScheduler.cancel(appContext)
            }
        }
    }

    private fun snapshot(
        prefs: SharedPreferences,
        mapping: Map<String, String>,
        destination: MutableMap<String, Any>,
    ) {
        val all = prefs.all
        for ((canonical, stored) in mapping) {
            if (!prefs.contains(stored)) continue
            all[stored]?.let { destination[canonical] = it }
        }
    }

    private fun apply(
        prefs: SharedPreferences,
        mapping: Map<String, String>,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        for ((canonical, stored) in mapping) {
            when (val value = values[canonical]) {
                is Boolean -> editor.putBoolean(stored, value)
                is Int -> editor.putInt(stored, value)
                is String -> {
                    if (canonical == "units.temperature" && value.isEmpty()) editor.remove(stored)
                    else editor.putString(stored, value)
                }
            }
        }
        editor.apply()
    }
}
