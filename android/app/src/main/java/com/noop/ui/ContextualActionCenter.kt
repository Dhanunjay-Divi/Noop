package com.noop.ui

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.noop.R
import com.noop.notif.HydrationReminderPrefs
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

internal enum class ContextualActionKind(val priority: Int) {
    HYDRATION(60),
    BREATHE(100),
    JOURNAL(45),
    WIND_DOWN(70),
    RECOVERY(85),
}

internal data class ContextualAction(
    val id: String,
    val kind: ContextualActionKind,
    val title: String,
    val detail: String,
    val evidence: List<String>,
    val createdAtMillis: Long,
    val expiresAtMillis: Long,
    val amountMl: Int? = null,
    val route: NoopNotificationRoute? = null,
)

internal fun ContextualAction.resolvedRecoveryRoute(): NoopNotificationRoute =
    route ?: NoopNotificationRoute.SLEEP

internal object ContextualActionPolicy {
    const val VISIBLE_LIMIT = 3

    fun visible(
        actions: List<ContextualAction>,
        nowMillis: Long,
        limit: Int = VISIBLE_LIMIT,
    ): List<ContextualAction> =
        actions
            .asSequence()
            .filter { it.expiresAtMillis > nowMillis }
            .groupBy { it.kind }
            .values
            .mapNotNull { values -> values.maxByOrNull { it.createdAtMillis } }
            .sortedWith(
                compareByDescending<ContextualAction> { it.kind.priority }
                    .thenByDescending { it.createdAtMillis },
            )
            .take(limit.coerceAtLeast(0))
}

/**
 * Durable in-app companion to accepted wellness notifications.
 *
 * Signal detectors and notification policies remain authoritative. This center only keeps accepted,
 * expiring actions reachable in the app and prevents a handled event from replaying after restart.
 */
internal object ContextualActionCenter {
    private const val PREFS_FILE = "noop_contextual_actions"
    private const val STATE_KEY = "state.v1"
    private const val MAX_STORED_ACTIONS = 12
    private const val MAX_HISTORY_IDS = 64

    private val lock = Any()
    private val handler by lazy { Handler(Looper.getMainLooper()) }
    private val _actions = MutableStateFlow<List<ContextualAction>>(emptyList())
    val actions: StateFlow<List<ContextualAction>> = _actions.asStateFlow()
    private val _processingIds = MutableStateFlow<Set<String>>(emptySet())
    val processingIds: StateFlow<Set<String>> = _processingIds.asStateFlow()

    private var appContext: Context? = null
    private var loaded = false
    private var storedActions = mutableListOf<ContextualAction>()
    private var dismissedIds = linkedSetOf<String>()
    private var completedIds = linkedSetOf<String>()
    private val expiryRunnable = Runnable {
        synchronized(lock) {
            val context = appContext ?: return@synchronized
            removeExpiredLocked(context, System.currentTimeMillis())
        }
    }

    fun refresh(context: Context, nowMillis: Long = System.currentTimeMillis()) {
        synchronized(lock) {
            val app = context.applicationContext
            ensureLoadedLocked(app)
            removeExpiredLocked(app, nowMillis)
        }
    }

    fun presentHydration(
        context: Context,
        fingerprint: String,
        amountMl: Int = HydrationReminderPrefs.config(context).tapAmountMl,
        evidence: List<String> = HydrationReminderPrefs.contextualActionEvidence(context),
        observedAtMillis: Long = System.currentTimeMillis(),
    ) {
        present(
            context = context,
            kind = ContextualActionKind.HYDRATION,
            fingerprint = fingerprint,
            title = context.getString(
                R.string.l10n_hydration_reminders_hydration_check_in_f93a58b5,
            ),
            detail = context.getString(R.string.context_action_hydration_detail),
            evidence = evidence,
            observedAtMillis = observedAtMillis,
            expiresAfterMillis = 2L * 60L * 60L * 1_000L,
            amountMl = amountMl.coerceIn(50, 1_000),
        )
    }

    fun presentStress(
        context: Context,
        fastRmssd: Double?,
        baselineRmssd: Double?,
        fingerprint: String,
        observedAtMillis: Long = System.currentTimeMillis(),
    ) {
        val evidence = buildList {
            add(context.getString(R.string.context_action_stress_fresh_evidence))
            if (
                fastRmssd != null &&
                baselineRmssd != null &&
                fastRmssd.isFinite() &&
                baselineRmssd.isFinite() &&
                baselineRmssd > 0
            ) {
                add(
                    context.getString(
                        R.string.context_action_stress_hrv_evidence,
                        fastRmssd,
                        baselineRmssd,
                    ),
                )
            }
        }
        present(
            context = context,
            kind = ContextualActionKind.BREATHE,
            fingerprint = fingerprint,
            title = context.getString(R.string.appwide_stress_checkin_notification_title),
            detail = context.getString(R.string.context_action_stress_detail),
            evidence = evidence,
            observedAtMillis = observedAtMillis,
            expiresAfterMillis = 45L * 60L * 1_000L,
        )
    }

    fun presentRecovery(
        context: Context,
        title: String,
        detail: String,
        fingerprint: String,
        evidence: List<String>,
        observedAtMillis: Long,
        maximumAgeMillis: Long,
        route: NoopNotificationRoute = NoopNotificationRoute.SLEEP,
    ) {
        present(
            context = context,
            kind = ContextualActionKind.RECOVERY,
            fingerprint = fingerprint,
            title = title,
            detail = detail,
            evidence = readableEvidence(context, evidence),
            observedAtMillis = observedAtMillis,
            expiresAfterMillis = maximumAgeMillis.coerceAtMost(18L * 60L * 60L * 1_000L),
            route = route,
        )
    }

    fun presentJournal(
        context: Context,
        fingerprint: String,
        title: String,
        detail: String,
        observedAtMillis: Long = System.currentTimeMillis(),
    ) {
        present(
            context = context,
            kind = ContextualActionKind.JOURNAL,
            fingerprint = fingerprint,
            title = title,
            detail = detail,
            evidence = listOf(context.getString(R.string.context_action_journal_evidence)),
            observedAtMillis = observedAtMillis,
            expiresAfterMillis = 8L * 60L * 60L * 1_000L,
        )
    }

    fun presentWindDown(
        context: Context,
        fingerprint: String,
        title: String,
        detail: String,
        observedAtMillis: Long = System.currentTimeMillis(),
    ) {
        present(
            context = context,
            kind = ContextualActionKind.WIND_DOWN,
            fingerprint = fingerprint,
            title = title,
            detail = detail,
            evidence = listOf(context.getString(R.string.context_action_wind_down_evidence)),
            observedAtMillis = observedAtMillis,
            expiresAfterMillis = 6L * 60L * 60L * 1_000L,
        )
    }

    fun dismiss(context: Context, action: ContextualAction) {
        synchronized(lock) {
            val app = context.applicationContext
            ensureLoadedLocked(app)
            dismissedIds.add(action.id)
            storedActions.removeAll { it.id == action.id }
            _processingIds.value = _processingIds.value - action.id
            persistLocked(app)
        }
    }

    fun begin(context: Context, action: ContextualAction): Boolean = synchronized(lock) {
        val app = context.applicationContext
        ensureLoadedLocked(app)
        if (
            storedActions.none { it.id == action.id } ||
            action.id in _processingIds.value ||
            action.id in completedIds
        ) {
            return@synchronized false
        }
        _processingIds.value = _processingIds.value + action.id
        true
    }

    fun finish(context: Context, action: ContextualAction, succeeded: Boolean) {
        synchronized(lock) {
            val app = context.applicationContext
            ensureLoadedLocked(app)
            _processingIds.value = _processingIds.value - action.id
            if (!succeeded) return@synchronized
            completedIds.add(action.id)
            storedActions.removeAll { it.id == action.id }
            persistLocked(app)
        }
    }

    fun complete(context: Context, action: ContextualAction) {
        if (begin(context, action)) finish(context, action, succeeded = true)
    }

    fun applyDemoActions(context: Context, nowMillis: Long = System.currentTimeMillis()) {
        presentHydration(
            context = context,
            fingerprint = "demo-hydration",
            amountMl = 250,
            evidence = listOf(
                context.getString(R.string.context_action_hydration_scheduled_evidence),
                context.getString(R.string.context_action_hydration_higher_effort),
            ),
            observedAtMillis = nowMillis,
        )
        presentRecovery(
            context = context,
            title = context.getString(R.string.context_action_demo_recovery_title),
            detail = context.getString(R.string.context_action_demo_recovery_detail),
            fingerprint = "demo-recovery",
            evidence = listOf("current-sleep", "below-explicit-target"),
            observedAtMillis = nowMillis,
            maximumAgeMillis = 12L * 60L * 60L * 1_000L,
        )
        presentStress(
            context = context,
            fastRmssd = 31.0,
            baselineRmssd = 48.0,
            fingerprint = "demo-stress",
            observedAtMillis = nowMillis,
        )
    }

    private fun present(
        context: Context,
        kind: ContextualActionKind,
        fingerprint: String,
        title: String,
        detail: String,
        evidence: List<String>,
        observedAtMillis: Long,
        expiresAfterMillis: Long,
        amountMl: Int? = null,
        route: NoopNotificationRoute? = null,
    ) {
        synchronized(lock) {
            val app = context.applicationContext
            ensureLoadedLocked(app)
            val now = System.currentTimeMillis()
            val expiresAt = observedAtMillis + expiresAfterMillis.coerceAtLeast(60_000L)
            val id = "${kind.name.lowercase(Locale.ROOT)}:$fingerprint"
            if (expiresAt <= now || id in dismissedIds || id in completedIds) return@synchronized
            if (storedActions.any { it.id == id }) {
                removeExpiredLocked(app, now)
                return@synchronized
            }

            val existing = storedActions.firstOrNull { it.kind == kind }
            if (
                existing != null &&
                now - existing.createdAtMillis < 5L * 60L * 1_000L &&
                existing.evidence.size > evidence.size
            ) {
                return@synchronized
            }

            storedActions.removeAll { it.kind == kind }
            storedActions += ContextualAction(
                id = id,
                kind = kind,
                title = title,
                detail = detail,
                evidence = evidence.filter { it.isNotBlank() }.take(3),
                createdAtMillis = observedAtMillis,
                expiresAtMillis = expiresAt,
                amountMl = amountMl,
                route = route,
            )
            persistLocked(app)
        }
    }

    private fun ensureLoadedLocked(context: Context) {
        appContext = context.applicationContext
        if (loaded) return
        loaded = true
        val raw = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .getString(STATE_KEY, null)
        if (raw.isNullOrBlank()) {
            publishLocked()
            return
        }
        runCatching {
            val root = JSONObject(raw)
            storedActions = decodeActions(root.optJSONArray("actions")).toMutableList()
            dismissedIds = decodeStrings(root.optJSONArray("dismissed")).toCollection(linkedSetOf())
            completedIds = decodeStrings(root.optJSONArray("completed")).toCollection(linkedSetOf())
        }.onFailure {
            storedActions.clear()
            dismissedIds.clear()
            completedIds.clear()
        }
        removeExpiredLocked(context, System.currentTimeMillis())
    }

    private fun removeExpiredLocked(context: Context, nowMillis: Long) {
        val changed = storedActions.removeAll { it.expiresAtMillis <= nowMillis }
        val validIds = storedActions.mapTo(hashSetOf()) { it.id }
        _processingIds.value = _processingIds.value.intersect(validIds)
        if (changed) persistLocked(context) else {
            publishLocked(nowMillis)
            scheduleExpiryLocked()
        }
    }

    private fun persistLocked(context: Context) {
        storedActions = storedActions
            .sortedByDescending { it.createdAtMillis }
            .take(MAX_STORED_ACTIONS)
            .toMutableList()
        dismissedIds = dismissedIds.toList().takeLast(MAX_HISTORY_IDS).toCollection(linkedSetOf())
        completedIds = completedIds.toList().takeLast(MAX_HISTORY_IDS).toCollection(linkedSetOf())
        val root = JSONObject()
            .put("actions", JSONArray().apply { storedActions.forEach { put(encode(it)) } })
            .put("dismissed", JSONArray(dismissedIds.toList()))
            .put("completed", JSONArray(completedIds.toList()))
        context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .edit()
            .putString(STATE_KEY, root.toString())
            .apply()
        publishLocked()
        scheduleExpiryLocked()
    }

    private fun publishLocked(nowMillis: Long = System.currentTimeMillis()) {
        _actions.value = ContextualActionPolicy.visible(storedActions, nowMillis)
    }

    private fun scheduleExpiryLocked() {
        handler.removeCallbacks(expiryRunnable)
        val next = storedActions.minOfOrNull { it.expiresAtMillis } ?: return
        handler.postDelayed(expiryRunnable, (next - System.currentTimeMillis()).coerceAtLeast(0L))
    }

    private fun encode(action: ContextualAction): JSONObject = JSONObject()
        .put("id", action.id)
        .put("kind", action.kind.name)
        .put("title", action.title)
        .put("detail", action.detail)
        .put("evidence", JSONArray(action.evidence))
        .put("createdAt", action.createdAtMillis)
        .put("expiresAt", action.expiresAtMillis)
        .apply { action.route?.let { put("route", it.navRoute) } }
        .apply { action.amountMl?.let { put("amountMl", it) } }

    private fun decodeActions(array: JSONArray?): List<ContextualAction> = buildList {
        if (array == null) return@buildList
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val kind = runCatching {
                ContextualActionKind.valueOf(item.getString("kind"))
            }.getOrNull() ?: continue
            val id = item.optString("id").takeIf { it.isNotBlank() } ?: continue
            val expiresAt = item.optLong("expiresAt", Long.MIN_VALUE)
            if (expiresAt == Long.MIN_VALUE) continue
            add(
                ContextualAction(
                    id = id,
                    kind = kind,
                    title = item.optString("title"),
                    detail = item.optString("detail"),
                    evidence = decodeStrings(item.optJSONArray("evidence")),
                    createdAtMillis = item.optLong("createdAt", 0L),
                    expiresAtMillis = expiresAt,
                    amountMl = item.optInt("amountMl").takeIf { item.has("amountMl") },
                    route = NoopNotificationRoute.fromRaw(item.optString("route")),
                ),
            )
        }
    }

    private fun decodeStrings(array: JSONArray?): List<String> = buildList {
        if (array == null) return@buildList
        for (index in 0 until array.length()) {
            array.optString(index).takeIf { it.isNotBlank() }?.let(::add)
        }
    }

    private fun readableEvidence(context: Context, tokens: List<String>): List<String> =
        tokens.mapNotNull { token ->
            when (token) {
                "current-sleep" -> context.getString(R.string.context_action_evidence_current_sleep)
                "recent-sleep-window" ->
                    context.getString(R.string.context_action_evidence_recent_sleep_window)
                "below-explicit-target" ->
                    context.getString(R.string.context_action_evidence_below_sleep_target)
                "personal-sleep-timing" ->
                    context.getString(R.string.context_action_evidence_personal_sleep_timing)
                "later-onset" -> context.getString(R.string.context_action_evidence_later_onset)
                "shorter-sleep" -> context.getString(R.string.context_action_evidence_shorter_sleep)
                "timezone-east", "timezone-west" ->
                    context.getString(R.string.context_action_evidence_timezone_changed)
                "offset-change" -> context.getString(R.string.context_action_evidence_time_shift)
                else -> token.takeIf { it.isNotBlank() }
            }
        }
}
