package com.noop.data

import android.content.Context
import android.content.SharedPreferences
import com.noop.AppDiagnosticsRecorder
import com.noop.alarm.SmartAlarmStore
import com.noop.alarm.WindDownScheduler
import com.noop.alarm.WindDownStore
import com.noop.notif.DailyReviewReminders
import com.noop.notif.HydrationReminderScheduler
import com.noop.ui.AppearancePrefs
import com.noop.ui.ChartStylePrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import java.io.IOException
import java.time.LocalDate
import java.time.ZoneId
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
 * The whitelist is the portable contract. Shared keys keep the same canonical names and JSON kinds
 * as Apple; v5 adds portable weekday wake overrides and v6 adds independent daily-review opt-ins
 * that older readers safely ignore. V1 carried profile/unit
 * values, v2 added a schema stamp and exact civil birthday, v3 added a bounded set of durable,
 * user-authored display, dashboard, reminder, HRV, and Sleep Planner preferences, v4 adds the
 * optional user-selected target weight, v5 preserves validated user-authored weekday wake
 * overrides, and v6 preserves the morning-review and journal-reminder choices. Only stable,
 * non-device-specific values are allowed. NEVER add credentials, device/peripheral/install ids,
 * sync cursors, active alarm epochs, or delivery de-dup state: backups get
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
    const val SCHEMA_VERSION = 6
    const val SCHEMA_VERSION_KEY = "settings.schemaVersion"
    const val DATE_OF_BIRTH_KEY = "profile.dateOfBirth"
    const val DAILY_REVIEW_MORNING_ENABLED_KEY = "dailyReview.morningEnabled"
    const val DAILY_REVIEW_JOURNAL_ENABLED_KEY = "dailyReview.journalEnabled"
    internal const val LEGACY_RECOVERY_MINUTES_KEY = "windDown.recoveryMinutes"

    /** The JSON kind a whitelisted key must decode to. Anything else is dropped, never guessed at. */
    enum class Kind { BOOL, INT, DOUBLE, STRING, CIVIL_DATE }

    /**
     * THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
     * (platform-neutral) names. Shared keys mirror Apple; Android-only additive keys remain
     * unknown-key-safe for older and cross-platform readers.
     *
     * Profile fields power zones/calories/baselines. V3 adds only preferences describing the user's
     * intended setup. Deliberately excluded: credentials, step calibration, device bindings,
     * permission receipts, install/migration state, sync cursors, scheduled-alarm epochs, notification
     * delivery de-duplication, and active alarm epochs.
     */
    val WHITELIST: Map<String, Kind> = linkedMapOf(
        SCHEMA_VERSION_KEY to Kind.INT,
        "profile.age" to Kind.INT,
        DATE_OF_BIRTH_KEY to Kind.CIVIL_DATE,
        "profile.sex" to Kind.STRING,
        "profile.weightKg" to Kind.DOUBLE,
        "profile.targetWeightKg" to Kind.DOUBLE,
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
        "windDown.perDayWakeMinutes" to Kind.STRING,
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
        DAILY_REVIEW_MORNING_ENABLED_KEY to Kind.BOOL,
        DAILY_REVIEW_JOURNAL_ENABLED_KEY to Kind.BOOL,
    )
    private val LEGACY_ROUND_TRIP_ONLY: Map<String, Kind> = mapOf(
        LEGACY_RECOVERY_MINUTES_KEY to Kind.INT,
    )

    /**
     * Encode the whitelisted subset of [values] as the flat `settings.json` object, or null when
     * nothing whitelisted is present (the exporter then omits only `settings.json`; the database and
     * integrity manifest are still written).
     */
    fun encode(values: Map<String, Any?>): String? {
        val obj = JSONObject()
        for ((key, kind) in WHITELIST + LEGACY_ROUND_TRIP_ONLY) {
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
        for ((key, kind) in WHITELIST + LEGACY_ROUND_TRIP_ONLY) {
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
            "profile.targetWeightKg" -> boundedDouble(coerced, 30.0..250.0)
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
            LEGACY_RECOVERY_MINUTES_KEY ->
                boundedInt(coerced, 0..WindDownStore.RECOVERY_MAX)
            "windDown.leadMinutes" -> boundedInt(coerced, 0..120)
            "windDown.perDayWakeMinutes" ->
                (coerced as? String)?.let(WindDownStore::normalizedWakeOverrides)
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
    private const val PROFILE_PREFS = "noop_profile"
    internal const val RESTORE_MAINTENANCE_PREFS = "noop_restore_maintenance"
    internal const val HYDRATION_RETRY_NEEDED = "hydration_reconcile_retry_needed"
    internal const val DAILY_REVIEW_RETRY_NEEDED = "daily_review_reconcile_retry_needed"
    private val restoreSchedulerRetryStateLock = Any()
    private const val PROFILE_DOB = "date_of_birth"
    private const val PROFILE_AGE = "age"
    private const val PROFILE_SEX = "sex"
    private const val PROFILE_AGE_CONFIRMED = "age_input_confirmed"
    private const val PROFILE_SEX_CONFIRMED = "sex_input_confirmed"
    private const val PROFILE_WEIGHT = "weight_kg"
    private const val PROFILE_WEIGHT_CONFIRMED = "weight_input_confirmed"
    private const val PROFILE_TARGET_WEIGHT = "target_weight_kg"
    private const val PROFILE_HEIGHT = "height_cm"
    private const val PROFILE_HEIGHT_CONFIRMED = "height_input_confirmed"
    private const val PROFILE_WAIST = "waist_cm"
    private const val PROFILE_HR_MAX = "hr_max_override"
    private const val PROFILE_FITNESS_AGE_PROVENANCE_REQUIRED =
        "fitness_age_provenance_required"
    private const val PROFILE_VO2_MAX_PROVENANCE_REQUIRED =
        "vo2max_provenance_required"
    private const val PROFILE_VITALITY_PROVENANCE_REQUIRED =
        "vitality_provenance_required"

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
        "sleepPlanner.wakeMinutes" to "windDown.wakeMinutes",
        "windDown.perDayWakeMinutes" to "windDown.perDayWakeMinutes",
    )
    private val DAILY_REVIEW_KEYS = linkedMapOf(
        BackupSettingsCodec.DAILY_REVIEW_MORNING_ENABLED_KEY to
            DailyReviewReminders.MORNING_ENABLED_KEY,
        BackupSettingsCodec.DAILY_REVIEW_JOURNAL_ENABLED_KEY to
            DailyReviewReminders.JOURNAL_ENABLED_KEY,
    )

    /** Canonical non-profile keys with an explicit SharedPreferences destination. */
    internal val mappedCanonicalKeys: Set<String>
        get() = buildSet {
            addAll(NOOP_PREFS_KEYS.keys)
            addAll(NOTIFICATION_KEYS.keys)
            addAll(INACTIVITY_KEYS.keys)
            addAll(HYDRATION_REMINDER_KEYS.keys)
            addAll(WIND_DOWN_KEYS.keys)
            addAll(DAILY_REVIEW_KEYS.keys)
        }

    internal data class RestorePreferenceTargets(
        val profile: SharedPreferences,
        val noop: SharedPreferences,
        val notifications: SharedPreferences,
        val inactivity: SharedPreferences,
        val hydrationReminders: SharedPreferences,
        val windDown: SharedPreferences,
        val dailyReview: SharedPreferences,
    )

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
        snapshotDailyReview(
            context.getSharedPreferences(
                DailyReviewReminders.PREFS_NAME,
                Context.MODE_PRIVATE,
            ),
            values,
        )
        return BackupSettingsCodec.encode(values)
    }

    /** Apply a validated live-sync payload. Database restore uses [applyRestoreDurably] instead. */
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
        applyWindDownSettings(
            prefs = context.getSharedPreferences("noop_wind_down", Context.MODE_PRIVATE),
            values = values,
        )
        applyDailyReviewSettings(
            prefs = context.getSharedPreferences(
                DailyReviewReminders.PREFS_NAME,
                Context.MODE_PRIVATE,
            ),
            values = values,
        )
    }

    /**
     * Restore-only persistence boundary. Every preference file is changed with one synchronous
     * [SharedPreferences.Editor.commit] batch. A false return fails the restore before its rollback
     * database or staging files can be discarded.
     */
    @Throws(IOException::class)
    fun applyRestoreDurably(context: Context, json: String?) {
        val appContext = context.applicationContext
        applyRestoreValuesDurably(
            targets = RestorePreferenceTargets(
                profile = appContext.getSharedPreferences(PROFILE_PREFS, Context.MODE_PRIVATE),
                noop = NoopPrefs.of(appContext),
                notifications = appContext.getSharedPreferences(
                    "noop_notif_prefs",
                    Context.MODE_PRIVATE,
                ),
                inactivity = appContext.getSharedPreferences(
                    "noop_inactivity_prefs",
                    Context.MODE_PRIVATE,
                ),
                hydrationReminders = appContext.getSharedPreferences(
                    "noop_hydration_reminders",
                    Context.MODE_PRIVATE,
                ),
                windDown = appContext.getSharedPreferences(
                    "noop_wind_down",
                    Context.MODE_PRIVATE,
                ),
                dailyReview = appContext.getSharedPreferences(
                    DailyReviewReminders.PREFS_NAME,
                    Context.MODE_PRIVATE,
                ),
            ),
            values = json?.let(BackupSettingsCodec::decode).orEmpty(),
        )
    }

    @Throws(IOException::class)
    internal fun applyRestoreValuesDurably(
        targets: RestorePreferenceTargets,
        values: Map<String, Any>,
    ) {
        commitProfileRestore(targets.profile, values)
        commitMappedRestore(targets.noop, NOOP_PREFS_KEYS, values)
        commitMappedRestore(targets.notifications, NOTIFICATION_KEYS, values)
        commitMappedRestore(targets.inactivity, INACTIVITY_KEYS, values)
        commitMappedRestore(targets.hydrationReminders, HYDRATION_REMINDER_KEYS, values)
        commitDailyReviewRestore(targets.dailyReview, values)

        // Recovery minutes are derived from current evidence and must never survive a database
        // restore. Remove them in the same durable batch as restored wind-down preferences.
        val windDownEditor = targets.windDown.edit()
        writeMapped(windDownEditor, WIND_DOWN_KEYS, values)
        windDownEditor.remove(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY)
        commitOrThrow(windDownEditor)
    }

    internal fun applyWindDownSettings(
        prefs: SharedPreferences,
        values: Map<String, Any>,
        clearDerivedPlannerState: Boolean = false,
    ) {
        val editor = prefs.edit()
        writeMapped(editor, WIND_DOWN_KEYS, values)
        if (clearDerivedPlannerState) {
            editor.remove(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY)
        }
        editor.apply()
    }

    internal fun applyDailyReviewSettings(
        prefs: SharedPreferences,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        if (writeDailyReview(editor, prefs, values)) {
            editor.apply()
        }
    }

    /** Refresh process mirrors and OS schedules after settings were committed with the restored DB. */
    fun reconcileAfterRestore(context: Context) {
        val appContext = context.applicationContext
        AppearancePrefs.load(appContext)
        ChartStylePrefs.load(appContext)
        reconcileSchedulerForConfirmedRestore(
            operation = { HydrationReminderScheduler.reconcile(appContext) },
            onFailure = {
                AppDiagnosticsRecorder.record(
                    "database.restore_reconcile",
                    fields = mapOf(
                        "outcome" to "failed",
                        "component" to "hydration",
                    ),
                )
            },
            persistRetryNeeded = { needed ->
                persistRestoreSchedulerRetryNeeded(
                    preferences = restoreMaintenancePreferences(appContext),
                    key = HYDRATION_RETRY_NEEDED,
                    needed = needed,
                )
            },
        )
        val windDownPrefs = appContext.getSharedPreferences(
            "noop_wind_down",
            Context.MODE_PRIVATE,
        )
        val windDown = WindDownStore(windDownPrefs)
        if (!windDown.hasExplicitWakeMinutes) {
            commitOrThrow(
                windDownPrefs.edit().putInt(
                    WIND_DOWN_KEYS.getValue("sleepPlanner.wakeMinutes"),
                    SmartAlarmStore.from(appContext).targetMinutes,
                ),
            )
        }
        try {
            WindDownScheduler.reconcilePersisted(appContext, windDown)
        } catch (failure: Exception) {
            if (!windDown.setEnabledDurably(false)) {
                throw IOException(
                    "Restored wind-down state could not be disabled durably.",
                    failure,
                )
            }
            try {
                WindDownScheduler.cancel(appContext)
            } catch (cancelFailure: Exception) {
                failure.addSuppressed(cancelFailure)
                throw IOException("Restored wind-down schedule could not be reconciled.", failure)
            }
            AppDiagnosticsRecorder.record(
                "database.restore_reconcile",
                fields = mapOf(
                    "outcome" to "disabled",
                    "component" to "wind_down",
                ),
            )
        }
        reconcileSchedulerForConfirmedRestore(
            operation = { DailyReviewReminders.reconcile(appContext) },
            onFailure = {
                AppDiagnosticsRecorder.record(
                    "database.restore_reconcile",
                    fields = mapOf(
                        "outcome" to "failed",
                        "component" to "daily_review",
                    ),
                )
            },
            persistRetryNeeded = { needed ->
                persistRestoreSchedulerRetryNeeded(
                    preferences = restoreMaintenancePreferences(appContext),
                    key = DAILY_REVIEW_RETRY_NEEDED,
                    needed = needed,
                )
            },
        )
    }

    internal enum class RestoreSchedulerRetryOutcome(val wireValue: String) {
        RETRY_COMPLETED("retry_completed"),
        RETRY_FAILED("retry_failed"),
        STATE_READ_FAILED("state_read_failed"),
        STATE_CLEAR_FAILED("state_clear_failed"),
    }

    internal fun persistRestoreSchedulerRetryNeeded(
        preferences: SharedPreferences,
        key: String,
        needed: Boolean,
    ) {
        synchronized(restoreSchedulerRetryStateLock) {
            val editor = preferences.edit()
            if (needed) {
                editor.putBoolean(key, true)
            } else {
                editor.remove(key)
            }
            if (!editor.commit()) {
                throw IOException("Restore maintenance retry state could not be persisted.")
            }
        }
    }

    internal fun runRestoreSchedulerMaintenanceAfterDatabaseReady(
        ensureDatabaseReady: () -> Unit,
        retryNeeded: () -> Boolean,
        reconcileWithoutRetry: Boolean = true,
        reconcile: () -> Unit,
        clearRetryNeeded: () -> Unit,
        onRetryOutcome: (RestoreSchedulerRetryOutcome) -> Unit,
    ): Boolean {
        ensureDatabaseReady()
        return synchronized(restoreSchedulerRetryStateLock) {
            val pendingRetry = try {
                retryNeeded()
            } catch (_: Exception) {
                onRetryOutcome(RestoreSchedulerRetryOutcome.STATE_READ_FAILED)
                return@synchronized false
            }
            if (!pendingRetry && !reconcileWithoutRetry) return@synchronized true
            val reconciled = runBestEffortReconcile(
                operation = reconcile,
                onFailure = {
                    if (pendingRetry) {
                        onRetryOutcome(RestoreSchedulerRetryOutcome.RETRY_FAILED)
                    }
                },
            )
            if (!reconciled || !pendingRetry) return@synchronized reconciled
            try {
                clearRetryNeeded()
                onRetryOutcome(RestoreSchedulerRetryOutcome.RETRY_COMPLETED)
                true
            } catch (_: Exception) {
                onRetryOutcome(RestoreSchedulerRetryOutcome.STATE_CLEAR_FAILED)
                false
            }
        }
    }

    internal fun reconcileHydrationAfterDatabaseReady(
        context: Context,
        ensureDatabaseReady: () -> Unit,
    ): Boolean {
        val appContext = context.applicationContext
        return reconcileSchedulerAfterDatabaseReady(
            appContext = appContext,
            ensureDatabaseReady = ensureDatabaseReady,
            retryKey = HYDRATION_RETRY_NEEDED,
            component = "hydration",
            reconcile = { HydrationReminderScheduler.reconcile(appContext) },
        )
    }

    internal fun reconcileDailyReviewAfterDatabaseReady(
        context: Context,
        ensureDatabaseReady: () -> Unit,
    ): Boolean {
        val appContext = context.applicationContext
        return reconcileSchedulerAfterDatabaseReady(
            appContext = appContext,
            ensureDatabaseReady = ensureDatabaseReady,
            retryKey = DAILY_REVIEW_RETRY_NEEDED,
            component = "daily_review",
            reconcileWithoutRetry = false,
            reconcile = { DailyReviewReminders.reconcile(appContext) },
        )
    }

    private fun reconcileSchedulerAfterDatabaseReady(
        appContext: Context,
        ensureDatabaseReady: () -> Unit,
        retryKey: String,
        component: String,
        reconcileWithoutRetry: Boolean = true,
        reconcile: () -> Unit,
    ): Boolean {
        val preferences = restoreMaintenancePreferences(appContext)
        return runRestoreSchedulerMaintenanceAfterDatabaseReady(
            ensureDatabaseReady = ensureDatabaseReady,
            retryNeeded = { preferences.getBoolean(retryKey, false) },
            reconcileWithoutRetry = reconcileWithoutRetry,
            reconcile = reconcile,
            clearRetryNeeded = {
                persistRestoreSchedulerRetryNeeded(
                    preferences = preferences,
                    key = retryKey,
                    needed = false,
                )
            },
            onRetryOutcome = { outcome ->
                AppDiagnosticsRecorder.record(
                    "database.restore_reconcile",
                    fields = restoreSchedulerRetryDiagnosticFields(outcome, component),
                )
            },
        )
    }

    internal fun restoreSchedulerRetryDiagnosticFields(
        outcome: RestoreSchedulerRetryOutcome,
        component: String,
    ): Map<String, String> = mapOf(
        "outcome" to outcome.wireValue,
        "component" to component,
    )

    /**
     * OS scheduling is repairable process maintenance, not part of database acceptance. A failed
     * scheduler is recorded and retried by [com.noop.NoopApplication.deferProcessMaintenance]
     * without trapping the restored health database behind an unbounded startup loop.
     */
    internal fun runBestEffortReconcile(
        operation: () -> Unit,
        onFailure: () -> Unit,
    ): Boolean = try {
        operation()
        true
    } catch (_: Exception) {
        try {
            onFailure()
        } catch (_: Throwable) {
            // Diagnostics are best effort and must not turn a repairable scheduler failure into
            // another restore-finalization failure.
        }
        false
    }

    internal fun reconcileSchedulerForConfirmedRestore(
        operation: () -> Unit,
        onFailure: () -> Unit,
        persistRetryNeeded: (Boolean) -> Unit,
    ): Boolean = synchronized(restoreSchedulerRetryStateLock) {
        val reconciled = runBestEffortReconcile(operation, onFailure)
        persistRetryNeeded(!reconciled)
        reconciled
    }

    private fun restoreMaintenancePreferences(context: Context): SharedPreferences =
        context.getSharedPreferences(RESTORE_MAINTENANCE_PREFS, Context.MODE_PRIVATE)

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

    private fun snapshotDailyReview(
        prefs: SharedPreferences,
        destination: MutableMap<String, Any>,
    ) {
        snapshot(prefs, DAILY_REVIEW_KEYS, destination)
        if (!prefs.contains(DailyReviewReminders.LEGACY_ENABLED_KEY)) return
        val legacyEnabled = prefs.getBoolean(DailyReviewReminders.LEGACY_ENABLED_KEY, false)
        destination.putIfAbsent(
            BackupSettingsCodec.DAILY_REVIEW_MORNING_ENABLED_KEY,
            legacyEnabled,
        )
        destination.putIfAbsent(
            BackupSettingsCodec.DAILY_REVIEW_JOURNAL_ENABLED_KEY,
            legacyEnabled,
        )
    }

    private fun apply(
        prefs: SharedPreferences,
        mapping: Map<String, String>,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        writeMapped(editor, mapping, values)
        editor.apply()
    }

    private fun writeMapped(
        editor: SharedPreferences.Editor,
        mapping: Map<String, String>,
        values: Map<String, Any>,
    ): Boolean {
        var changed = false
        for ((canonical, stored) in mapping) {
            when (val value = values[canonical]) {
                is Boolean -> {
                    editor.putBoolean(stored, value)
                    changed = true
                }
                is Int -> {
                    editor.putInt(stored, value)
                    changed = true
                }
                is String -> {
                    if (canonical == "units.temperature" && value.isEmpty()) editor.remove(stored)
                    else editor.putString(stored, value)
                    changed = true
                }
            }
        }
        return changed
    }

    private fun writeDailyReview(
        editor: SharedPreferences.Editor,
        prefs: SharedPreferences,
        values: Map<String, Any>,
    ): Boolean {
        val touchesMorning =
            values[BackupSettingsCodec.DAILY_REVIEW_MORNING_ENABLED_KEY] is Boolean
        val touchesJournal =
            values[BackupSettingsCodec.DAILY_REVIEW_JOURNAL_ENABLED_KEY] is Boolean
        if (!touchesMorning && !touchesJournal) return false

        writeMapped(editor, DAILY_REVIEW_KEYS, values)
        val legacyEnabled = prefs.getBoolean(
            DailyReviewReminders.LEGACY_ENABLED_KEY,
            false,
        )
        val morningEnabled =
            values[BackupSettingsCodec.DAILY_REVIEW_MORNING_ENABLED_KEY] as? Boolean
                ?: prefs.takeIf {
                    it.contains(DailyReviewReminders.MORNING_ENABLED_KEY)
                }?.getBoolean(DailyReviewReminders.MORNING_ENABLED_KEY, false)
                ?: legacyEnabled
        val journalEnabled =
            values[BackupSettingsCodec.DAILY_REVIEW_JOURNAL_ENABLED_KEY] as? Boolean
                ?: prefs.takeIf {
                    it.contains(DailyReviewReminders.JOURNAL_ENABLED_KEY)
                }?.getBoolean(DailyReviewReminders.JOURNAL_ENABLED_KEY, false)
                ?: legacyEnabled
        editor
            .putBoolean(
                DailyReviewReminders.LEGACY_ENABLED_KEY,
                morningEnabled || journalEnabled,
            )
            .putBoolean(DailyReviewReminders.SPLIT_MIGRATED_KEY, true)
        return true
    }

    @Throws(IOException::class)
    private fun commitMappedRestore(
        prefs: SharedPreferences,
        mapping: Map<String, String>,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        if (writeMapped(editor, mapping, values)) commitOrThrow(editor)
    }

    @Throws(IOException::class)
    private fun commitDailyReviewRestore(
        prefs: SharedPreferences,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        if (writeDailyReview(editor, prefs, values)) commitOrThrow(editor)
    }

    @Throws(IOException::class)
    private fun commitProfileRestore(
        prefs: SharedPreferences,
        values: Map<String, Any>,
    ) {
        val editor = prefs.edit()
        var changed = false

        val restoredDob = (values[BackupSettingsCodec.DATE_OF_BIRTH_KEY] as? String)?.let { raw ->
            LocalDate.parse(raw)
                .atStartOfDay(ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli()
        } ?: (values["profile.age"] as? Number)?.let { age ->
            ProfileStore.dobForAge(age.toInt())
        }
        if (restoredDob != null) {
            editor
                .putLong(PROFILE_DOB, restoredDob)
                .putInt(PROFILE_AGE, ProfileStore.yearsFromDob(restoredDob).coerceIn(13, 100))
                .putBoolean(PROFILE_AGE_CONFIRMED, true)
                .putBoolean(PROFILE_FITNESS_AGE_PROVENANCE_REQUIRED, true)
                .putBoolean(PROFILE_VO2_MAX_PROVENANCE_REQUIRED, true)
                .putBoolean(PROFILE_VITALITY_PROVENANCE_REQUIRED, true)
            changed = true
        }
        (values["profile.sex"] as? String)?.let { sex ->
            editor
                .putString(PROFILE_SEX, sex)
                .putBoolean(PROFILE_SEX_CONFIRMED, true)
                .putBoolean(PROFILE_FITNESS_AGE_PROVENANCE_REQUIRED, true)
                .putBoolean(PROFILE_VO2_MAX_PROVENANCE_REQUIRED, true)
            changed = true
        }
        (values["profile.weightKg"] as? Number)?.let { weight ->
            editor
                .putFloat(PROFILE_WEIGHT, weight.toFloat())
                .putBoolean(PROFILE_WEIGHT_CONFIRMED, true)
            changed = true
        }
        (values["profile.targetWeightKg"] as? Number)?.let { target ->
            editor.putFloat(PROFILE_TARGET_WEIGHT, target.toFloat())
            changed = true
        }
        (values["profile.heightCm"] as? Number)?.let { height ->
            editor
                .putFloat(PROFILE_HEIGHT, height.toFloat())
                .putBoolean(PROFILE_HEIGHT_CONFIRMED, true)
            changed = true
        }
        (values["profile.waistCm"] as? Number)?.let { waist ->
            editor
                .putFloat(PROFILE_WAIST, waist.toFloat())
                .putBoolean(PROFILE_VO2_MAX_PROVENANCE_REQUIRED, true)
            changed = true
        }
        (values["profile.hrMax"] as? Number)?.let { hrMax ->
            editor.putInt(PROFILE_HR_MAX, hrMax.toInt())
            changed = true
        }

        if (changed) commitOrThrow(editor)
    }

    @Throws(IOException::class)
    private fun commitOrThrow(editor: SharedPreferences.Editor) {
        if (!editor.commit()) {
            throw IOException("Restored preferences could not be committed to durable storage.")
        }
    }
}
