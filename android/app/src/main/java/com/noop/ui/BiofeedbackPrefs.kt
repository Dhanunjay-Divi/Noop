package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import com.noop.analytics.ResonanceEngine
import com.noop.analytics.StressOnsetDetector

/**
 * BiofeedbackPrefs — the small, on-device pref surface for the haptic-biofeedback pillar (the Kotlin twin
 * of Strand/Screens/BiofeedbackPrefs.swift): the locked resonance pace + its date (L1), the
 * retired automatic stress-check-in choices + the replay-safe StressOnsetDetector state (L3).
 *
 * SharedPreferences-backed via [NoopPrefs.of] (the same store the rest of the app uses), single-user,
 * on-device — nothing here leaves the device. Automatic nudges remain capability-gated to OFF until a
 * live source supplies timestamp-matched wrist motion alongside its R-R evidence. The old key strings
 * remain only so upgrades can disarm a stale opt-in without touching manual Breathe preferences.
 *
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
object BiofeedbackPrefs {

    /** Evidence contract required before an interruptive automatic stress cue can be credible. */
    enum class AutomaticStressNudgeCapability(val isAvailable: Boolean) {
        UNAVAILABLE_NEEDS_TIMESTAMP_MATCHED_WRIST_MOTION(false),
        AVAILABLE_WITH_TIMESTAMP_MATCHED_WRIST_MOTION(true),
    }

    /** Current live BLE truth. Changing this requires wiring timestamp-aligned wrist motion and R-R. */
    val automaticStressNudgeCapability: AutomaticStressNudgeCapability =
        AutomaticStressNudgeCapability.UNAVAILABLE_NEEDS_TIMESTAMP_MATCHED_WRIST_MOTION

    val automaticStressNudgesAvailable: Boolean
        get() = automaticStressNudgeCapability.isAvailable

    private const val KEY_LOCKED_PACE = "biofeedback.resonanceBpm"
    private const val KEY_LOCKED_DATE = "biofeedback.resonanceLockedAt"
    private const val KEY_CHECK_IN = "biofeedback.stressCheckIn"
    private const val KEY_AUTO_NUDGE = "biofeedback.stressAutoNudge"
    private const val KEY_QUIET_HOURS = "biofeedback.stressQuietHours"
    private const val KEY_USE_RESONANCE = "biofeedback.stressUseResonancePace"
    private const val KEY_QUIET_START = "biofeedback.stressQuietStartMin"
    private const val KEY_QUIET_END = "biofeedback.stressQuietEndMin"
    private const val KEY_ST_BASELINE = "biofeedback.stOnsetBaseline"
    private const val KEY_ST_WAS_BELOW = "biofeedback.stOnsetWasBelow"
    private const val KEY_ST_LAST_FIRE = "biofeedback.stOnsetLastFire"
    private const val KEY_ST_TRUSTED_COUNT = "biofeedback.stOnsetTrustedWindowCount"
    private const val KEY_ST_LAST_FINGERPRINT = "biofeedback.stOnsetLastWindowFingerprint"
    private const val KEY_ST_LAST_WINDOW_AT = "biofeedback.stOnsetLastWindowAt"

    // ── L1 locked resonance pace ──────────────────────────────────────────────

    /** The user's locked resonance pace (br/min), or null if they've never locked one. */
    fun lockedPace(context: Context): Double? {
        val v = NoopPrefs.of(context).getFloat(KEY_LOCKED_PACE, 0f).toDouble()
        return if (v > 0.0) v else null
    }

    /** Epoch-millis when the pace was measured (0 = never) — shown dated; the pace drifts. */
    fun lockedPaceDateMs(context: Context): Long = NoopPrefs.of(context).getLong(KEY_LOCKED_DATE, 0L)

    fun saveLockedPace(context: Context, bpm: Double, dateMs: Long) {
        NoopPrefs.of(context).edit()
            .putFloat(KEY_LOCKED_PACE, bpm.toFloat())
            .putLong(KEY_LOCKED_DATE, dateMs)
            .apply()
    }

    // ── L3 toggles → engine Config ────────────────────────────────────────────

    internal data class AutomaticStressNudgePreferences(
        val checkInEnabled: Boolean,
        val autoNudge: Boolean,
    )

    /** Pure policy seam: a stale stored opt-in can never bypass the current source capability. */
    internal fun canonicalAutomaticStressNudgePreferences(
        storedCheckInEnabled: Boolean,
        storedAutoNudge: Boolean,
        capability: AutomaticStressNudgeCapability,
    ): AutomaticStressNudgePreferences {
        val enabled = capability.isAvailable && storedCheckInEnabled
        return AutomaticStressNudgePreferences(
            checkInEnabled = enabled,
            autoNudge = enabled && storedAutoNudge,
        )
    }

    fun checkInEnabled(context: Context): Boolean {
        val prefs = NoopPrefs.of(context)
        return canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = prefs.getBoolean(KEY_CHECK_IN, false),
            storedAutoNudge = prefs.getBoolean(KEY_AUTO_NUDGE, false),
            capability = automaticStressNudgeCapability,
        ).checkInEnabled
    }

    /** Retained for the future card's Turn off action; unsupported builds refuse a true write. */
    fun setCheckInEnabled(context: Context, on: Boolean) {
        val enabled = automaticStressNudgesAvailable && on
        NoopPrefs.of(context).edit()
            .putBoolean(KEY_CHECK_IN, enabled)
            .apply {
                if (!enabled) putBoolean(KEY_AUTO_NUDGE, false)
            }
            .apply()
    }

    fun autoNudge(context: Context): Boolean {
        val prefs = NoopPrefs.of(context)
        return canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = prefs.getBoolean(KEY_CHECK_IN, false),
            storedAutoNudge = prefs.getBoolean(KEY_AUTO_NUDGE, false),
            capability = automaticStressNudgeCapability,
        ).autoNudge
    }

    fun setAutoNudge(context: Context, on: Boolean) {
        val prefs = NoopPrefs.of(context)
        val enabled = automaticStressNudgesAvailable &&
            prefs.getBoolean(KEY_CHECK_IN, false) && on
        prefs.edit().putBoolean(KEY_AUTO_NUDGE, enabled).apply()
    }

    /**
     * Upgrade migration for the retired automatic permission. Writing explicit false values is
     * rollback-safe: an older build cannot reinterpret a retained true as permission to interrupt.
     * Resonance pace/date and every manual Breathe preference are deliberately left untouched.
     */
    fun migrateAutomaticStressNudgePreferences(context: Context) {
        migrateAutomaticStressNudgePreferences(NoopPrefs.of(context))
    }

    internal fun migrateAutomaticStressNudgePreferences(
        prefs: SharedPreferences,
    ): AutomaticStressNudgePreferences {
        val storedCheckIn = prefs.getBoolean(KEY_CHECK_IN, false)
        val storedAutoNudge = prefs.getBoolean(KEY_AUTO_NUDGE, false)
        val canonical = canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = storedCheckIn,
            storedAutoNudge = storedAutoNudge,
            capability = automaticStressNudgeCapability,
        )
        if (
            storedCheckIn != canonical.checkInEnabled ||
            storedAutoNudge != canonical.autoNudge
        ) {
            prefs.edit()
                .putBoolean(KEY_CHECK_IN, canonical.checkInEnabled)
                .putBoolean(KEY_AUTO_NUDGE, canonical.autoNudge)
                .apply()
        }
        return canonical
    }

    fun quietHoursEnabled(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_QUIET_HOURS, true)
    fun setQuietHoursEnabled(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_QUIET_HOURS, on).apply()

    fun useResonancePace(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_USE_RESONANCE, true)
    fun setUseResonancePace(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_USE_RESONANCE, on).apply()

    private fun quietStartMin(context: Context): Int = NoopPrefs.of(context).getInt(KEY_QUIET_START, 22 * 60)
    private fun quietEndMin(context: Context): Int = NoopPrefs.of(context).getInt(KEY_QUIET_END, 7 * 60)

    /** Build the effective config. The capability gate is repeated here, independent of migration/UI. */
    fun stressConfig(context: Context): StressOnsetDetector.Config {
        val prefs = NoopPrefs.of(context)
        return stressConfig(
            storedCheckInEnabled = prefs.getBoolean(KEY_CHECK_IN, false),
            storedAutoNudge = prefs.getBoolean(KEY_AUTO_NUDGE, false),
            capability = automaticStressNudgeCapability,
            quietHoursEnabled = quietHoursEnabled(context),
            quietStartMinutes = quietStartMin(context),
            quietEndMinutes = quietEndMin(context),
        )
    }

    /** Pure overload used by tests and any future source-capability negotiation. */
    internal fun stressConfig(
        storedCheckInEnabled: Boolean,
        storedAutoNudge: Boolean,
        capability: AutomaticStressNudgeCapability,
        quietHoursEnabled: Boolean = true,
        quietStartMinutes: Int = 22 * 60,
        quietEndMinutes: Int = 7 * 60,
    ): StressOnsetDetector.Config {
        val effective = canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = storedCheckInEnabled,
            storedAutoNudge = storedAutoNudge,
            capability = capability,
        )
        return StressOnsetDetector.Config(
            enabled = effective.checkInEnabled,
            autoNudge = effective.autoNudge,
            quietHoursEnabled = quietHoursEnabled,
            quietStartMinutes = quietStartMinutes,
            quietEndMinutes = quietEndMinutes,
            buzzLoops = 1,
        )
    }

    // ── L3 replay-safe state ──────────────────────────────────────────────────

    fun loadStressState(context: Context): StressOnsetDetector.State {
        val p = NoopPrefs.of(context)
        return StressOnsetDetector.State(
            baselineRMSSD = p.getFloat(KEY_ST_BASELINE, 0f).toDouble(),
            wasBelow = p.getBoolean(KEY_ST_WAS_BELOW, false),
            lastFireAt = p.getLong(KEY_ST_LAST_FIRE, 0L),
            // These keys did not exist before the credibility/warm-up migration. Their zero defaults are
            // deliberate: a legacy ungated EMA must earn four new trusted windows instead of firing at once.
            trustedWindowCount = p.getInt(KEY_ST_TRUSTED_COUNT, 0)
                .coerceIn(0, StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS),
            // Swift persists the UInt64 fingerprint as a decimal String under this shared key. Accept that
            // shape and Android's signed Long shape so either platform/older local state remains readable.
            lastTrustedWindowFingerprint = runCatching {
                p.getString(KEY_ST_LAST_FINGERPRINT, null)?.toULongOrNull()?.toLong()
            }.getOrNull()
                ?: runCatching { p.getLong(KEY_ST_LAST_FINGERPRINT, 0L) }.getOrDefault(0L),
            lastTrustedWindowAt = p.getLong(KEY_ST_LAST_WINDOW_AT, 0L),
        )
    }

    fun saveStressState(context: Context, s: StressOnsetDetector.State) {
        NoopPrefs.of(context).edit()
            .putFloat(KEY_ST_BASELINE, s.baselineRMSSD.toFloat())
            .putBoolean(KEY_ST_WAS_BELOW, s.wasBelow)
            .putLong(KEY_ST_LAST_FIRE, s.lastFireAt)
            .putInt(
                KEY_ST_TRUSTED_COUNT,
                s.trustedWindowCount.coerceIn(0, StressOnsetDetector.MINIMUM_TRUSTED_BASELINE_WINDOWS),
            )
            .putString(KEY_ST_LAST_FINGERPRINT, s.lastTrustedWindowFingerprint.toULong().toString())
            .putLong(KEY_ST_LAST_WINDOW_AT, s.lastTrustedWindowAt)
            .apply()
    }

    /** The coherence fallback pace, re-exported so UI code reads it from one place. */
    val fallbackBpm: Double get() = ResonanceEngine.FALLBACK_BPM
}
