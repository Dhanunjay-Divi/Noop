package com.noop.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The handful of numbers the home-screen widget shows, persisted to SharedPreferences so the
 * widget can render after a process restart (Glance recomposes from disk, not from app memory).
 */
data class WidgetSnapshot(
    /** Today's recovery / Charge 0–100, null until NOOP has scored enough nights (honest-blank). */
    val recoveryPct: Int? = null,
    /** Today's Rest 0–100 (the sleep_performance composite), null until last night is scored (#516). */
    val restPct: Int? = null,
    /** Today's Effort 0–100 (the day's strain on the 0–100 scale), null until there's a HR window (#516). */
    val effortPct: Int? = null,
    /** Live heart rate, null when not streaming. */
    val heartRate: Int? = null,
    /** Strap battery 0–100, null until the strap reports it. */
    val batteryPct: Int? = null,
    val connected: Boolean = false,
    /** Wall-clock millis of the last push, so the widget can show honest staleness. */
    val updatedAtMs: Long = 0L,
    /** HRV for [vitalsDay], which may be newer than the most recent fully-scored day. */
    val hrvMs: Int? = null,
    /** Resting HR for [vitalsDay], in beats per minute. */
    val restingHr: Int? = null,
    /** Total measured sleep for [vitalsDay], in whole minutes. */
    val sleepMinutes: Int? = null,
    /** ISO yyyy-MM-dd day represented by the score fields; null for snapshots from older builds. */
    val scoreDay: String? = null,
    /** Stable provenance key (see [WidgetScoreSource]); unknown/old snapshots leave this null. */
    val scoreSource: String? = null,
    /** Day/source for overnight vitals when they come from a newer row than the last scored day. */
    val vitalsDay: String? = null,
    val vitalsSource: String? = null,
    /** Last observation of live connection/HR state, distinct from a score-only republish. */
    val liveUpdatedAtMs: Long = 0L,
)

/** Persisted source keys rather than display copy, so locale changes never invalidate a snapshot. */
internal enum class WidgetScoreSource(val storageKey: String) {
    NOOP("noop"),
    WEARABLE("wearable"),
    HEALTH_CONNECT("health_connect"),
    APPLE_HEALTH("apple_health"),
    ACTIVITY_FILE("activity_file");

    companion object {
        fun fromStorageKey(raw: String?): WidgetScoreSource? = entries.firstOrNull { it.storageKey == raw }
    }
}

/** Honest state used by every widget footer. It describes snapshot freshness, not sensor cadence. */
internal enum class WidgetFreshness { LIVE, RECENT, STALE, EMPTY }

/**
 * A live process explicitly asks Glance to rebuild when a System-following day/night configuration
 * flips. A killed process remains safe because [noopWidgetColors] also embeds day+night providers in
 * the RemoteViews itself.
 */
internal fun shouldRefreshSystemWidgetsForNightMode(
    previousDark: Boolean?,
    currentDark: Boolean,
    followsSystem: Boolean,
): Boolean = previousDark != null && previousDark != currentDark && followsSystem

internal fun WidgetSnapshot.freshness(
    nowMs: Long,
    liveWindowMs: Long = 2 * 60_000L,
    staleAfterMs: Long = 6 * 60 * 60_000L,
): WidgetFreshness {
    val liveAge = nowMs - liveUpdatedAtMs
    if (connected && liveUpdatedAtMs > 0L && liveAge in 0..liveWindowMs) return WidgetFreshness.LIVE
    if (updatedAtMs <= 0L) return WidgetFreshness.EMPTY
    val age = nowMs - updatedAtMs
    return if (age in 0..staleAfterMs) WidgetFreshness.RECENT else WidgetFreshness.STALE
}

/**
 * Persists snapshots and tells Glance to recompose. Both producers funnel through [push]:
 * [com.noop.ble.WhoopConnectionService] (long-lived — the widget's heartbeat while the app UI is
 * closed) and [com.noop.ui.AppViewModel] (covers foreground use with the background service off).
 *
 * Throttled by [PushGate] (see its KDoc). CALLER CONTRACT (#82): collect with backpressure
 * (`conflate()` + `collect`), NEVER `collectLatest` — push suspends in Glance machinery longer than
 * the live-HR emission interval (~1/s), so collectLatest cancels every push mid-flight and the
 * widget starves on stale prefs forever while the strap streams.
 */
object WidgetSnapshotStore {
    private const val FILE = "noop_widget"
    private val refreshScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    suspend fun push(context: Context, snap: WidgetSnapshot) {
        val app = context.applicationContext
        // Cheap, non-suspending gate FIRST — at live-HR cadence (~1/s) almost every call ends here.
        if (!PushGate.admit(snap)) return

        // Persist before anything suspending, and only THEN mark the gate (#82: marking before the
        // write let a cancelled push burn the refresh window — the widget starved on stale prefs).
        // Saving even with no widget placed means a widget added later renders fresh data instantly.
        save(app, snap)
        PushGate.markPushed(snap)

        refresh(app)
    }

    /**
     * Recompose placed widgets after a non-snapshot preference change (notably appearance). Glance
     * providers intentionally use `updatePeriodMillis=0`, so waiting for the OS would leave stale
     * chrome on screen. The caller remains non-blocking and failures stay isolated from app UI.
     */
    fun requestRefresh(context: Context) {
        val app = context.applicationContext
        refreshScope.launch { refresh(app) }
    }

    internal suspend fun refresh(context: Context) {
        val standardIds = runCatching {
            GlanceAppWidgetManager(context).getGlanceIds(NoopGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        val compactIds = runCatching {
            GlanceAppWidgetManager(context).getGlanceIds(NoopCompactGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        val wideIds = runCatching {
            GlanceAppWidgetManager(context).getGlanceIds(NoopWideGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        if (standardIds.isEmpty() && compactIds.isEmpty() && wideIds.isEmpty()) return
        runCatching { NoopGlanceWidget().updateAll(context) }
        runCatching { NoopCompactGlanceWidget().updateAll(context) }
        runCatching { NoopWideGlanceWidget().updateAll(context) }
    }

    fun save(context: Context, snap: WidgetSnapshot) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putInt("recovery", snap.recoveryPct ?: -1)
            .putInt("rest", snap.restPct ?: -1)
            .putInt("effort", snap.effortPct ?: -1)
            .putInt("hr", snap.heartRate ?: -1)
            .putInt("battery", snap.batteryPct ?: -1)
            .putBoolean("connected", snap.connected)
            .putLong("updatedAt", snap.updatedAtMs)
            .putInt("hrvMs", snap.hrvMs ?: -1)
            .putInt("restingHr", snap.restingHr ?: -1)
            .putInt("sleepMinutes", snap.sleepMinutes ?: -1)
            .putString("scoreDay", snap.scoreDay)
            .putString("scoreSource", snap.scoreSource)
            .putString("vitalsDay", snap.vitalsDay)
            .putString("vitalsSource", snap.vitalsSource)
            .putLong("liveUpdatedAt", snap.liveUpdatedAtMs)
            .apply()
    }

    fun load(context: Context): WidgetSnapshot {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return WidgetSnapshot(
            recoveryPct = p.getInt("recovery", -1).takeIf { it >= 0 },
            restPct = p.getInt("rest", -1).takeIf { it >= 0 },
            effortPct = p.getInt("effort", -1).takeIf { it >= 0 },
            heartRate = p.getInt("hr", -1).takeIf { it > 0 },
            batteryPct = p.getInt("battery", -1).takeIf { it >= 0 },
            connected = p.getBoolean("connected", false),
            updatedAtMs = p.getLong("updatedAt", 0L),
            hrvMs = p.getInt("hrvMs", -1).takeIf { it >= 0 },
            restingHr = p.getInt("restingHr", -1).takeIf { it > 0 },
            sleepMinutes = p.getInt("sleepMinutes", -1).takeIf { it >= 0 },
            scoreDay = p.getString("scoreDay", null),
            scoreSource = p.getString("scoreSource", null),
            vitalsDay = p.getString("vitalsDay", null),
            vitalsSource = p.getString("vitalsSource", null),
            liveUpdatedAtMs = p.getLong("liveUpdatedAt", 0L),
        )
    }
}

/**
 * The push-throttle decision, extracted pure so it's unit-testable (PushGateTests). Meaningful
 * changes (recovery, battery 5%-bucket, connection, and HR presence — so the FIRST heart-rate
 * sample shows immediately, #82) admit straight away; an unchanged key re-admits once per
 * [HR_REFRESH_MS] so the displayed HR still ticks. Glance re-inflation is far heavier than a
 * notification post, hence the gate.
 */
internal object PushGate {
    private const val HR_REFRESH_MS = 60_000L

    private var lastKey: String? = null
    private var lastPushAtMs = 0L

    private fun keyOf(snap: WidgetSnapshot): String =
        // Rest + Effort join the change-key (#516) so a freshly-scored 2x2 score lands immediately, the
        // same way recovery does — not waiting out the HR refresh window.
        "${snap.recoveryPct}|${snap.restPct}|${snap.effortPct}|" +
            "${snap.hrvMs}|${snap.restingHr}|${snap.sleepMinutes}|" +
            "${snap.scoreDay}|${snap.scoreSource}|${snap.vitalsDay}|${snap.vitalsSource}|" +
            "${snap.batteryPct?.div(5)}|" +
            "${snap.connected}|${snap.heartRate != null}"

    fun admit(snap: WidgetSnapshot): Boolean =
        keyOf(snap) != lastKey || snap.updatedAtMs - lastPushAtMs >= HR_REFRESH_MS

    fun markPushed(snap: WidgetSnapshot) {
        lastKey = keyOf(snap)
        lastPushAtMs = snap.updatedAtMs
    }

    fun resetForTest() {
        lastKey = null
        lastPushAtMs = 0L
    }
}
