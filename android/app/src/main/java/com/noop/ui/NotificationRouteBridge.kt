package com.noop.ui

import android.content.Context
import android.content.Intent
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Trusted top-level destinations that a NOOP-owned notification may open. */
internal enum class NoopNotificationRoute(val navRoute: String) {
    TODAY("today"),
    TRENDS("trends"),
    SLEEP("sleep"),
    LIVE("live"),
    WORKOUTS("workouts"),
    HEALTH("health"),
    HYDRATION("hydration"),
    BREATHE("breathe"),
    JOURNAL("insights"),
    SAFETY("safety"),
    FRIENDS("friends"),
    COACH("coach");

    companion object {
        fun fromRaw(raw: String?): NoopNotificationRoute? = entries.firstOrNull { it.navRoute == raw }
    }
}

internal data class PendingNotificationRouteRequest(
    val route: NoopNotificationRoute,
    val journalDay: LocalDate? = null,
)

/**
 * Durable hand-off from [MainActivity]'s launch intent to the Compose navigation shell.
 *
 * A cold launch can receive the notification intent before onboarding/terms/changelog gates allow
 * [AppRoot] to exist. Persisting one trusted pending route covers that case; [routeRequests] wakes an
 * already-mounted warm activity. Consumption removes the route first so it cannot reopen on relaunch.
 */
internal object NotificationRouteBridge {
    const val EXTRA_ROUTE = "com.noop.extra.NOTIFICATION_ROUTE"
    const val EXTRA_JOURNAL_DAY = "com.noop.extra.NOTIFICATION_JOURNAL_DAY"
    private const val KEY_PENDING_ROUTE = "noop.notification.pendingRoute"
    private const val KEY_PENDING_JOURNAL_DAY = "noop.notification.pendingJournalDay"

    private val lock = Any()
    private val _routeRequests = MutableStateFlow(0L)
    val routeRequests: StateFlow<Long> = _routeRequests.asStateFlow()

    fun launchIntent(
        context: Context,
        route: NoopNotificationRoute,
        journalDay: LocalDate? = null,
    ): Intent = appLaunchIntent(context)
        .putExtra(EXTRA_ROUTE, route.navRoute)
        .apply {
            if (route == NoopNotificationRoute.JOURNAL && journalDay != null) {
                putExtra(EXTRA_JOURNAL_DAY, journalDay.toString())
            }
        }

    /** Record a recognized route and consume the intent extra so configuration recreation cannot replay it. */
    fun recordFromIntent(context: Context, intent: Intent?): Boolean {
        val raw = intent?.getStringExtra(EXTRA_ROUTE)
        val journalDayRaw = intent?.getStringExtra(EXTRA_JOURNAL_DAY)
        if (raw != null) intent.removeExtra(EXTRA_ROUTE)
        if (journalDayRaw != null) intent?.removeExtra(EXTRA_JOURNAL_DAY)
        val route = NoopNotificationRoute.fromRaw(raw) ?: return false
        val journalDay = if (route == NoopNotificationRoute.JOURNAL) {
            parseJournalDay(journalDayRaw)
        } else {
            null
        }
        synchronized(lock) {
            NoopPrefs.of(context).edit()
                .putString(KEY_PENDING_ROUTE, route.navRoute)
                .apply {
                    if (journalDay != null) {
                        putString(KEY_PENDING_JOURNAL_DAY, journalDay.toString())
                    } else {
                        remove(KEY_PENDING_JOURNAL_DAY)
                    }
                }
                .apply()
            _routeRequests.value += 1L
        }
        return true
    }

    /** Return one pending trusted route, removing it before navigation. */
    fun consumePendingRequest(context: Context): PendingNotificationRouteRequest? = synchronized(lock) {
        val prefs = NoopPrefs.of(context)
        val raw = prefs.getString(KEY_PENDING_ROUTE, null)
        val journalDayRaw = prefs.getString(KEY_PENDING_JOURNAL_DAY, null)
        prefs.edit()
            .remove(KEY_PENDING_ROUTE)
            .remove(KEY_PENDING_JOURNAL_DAY)
            .apply()
        val route = NoopNotificationRoute.fromRaw(raw) ?: return@synchronized null
        val journalDay = if (route == NoopNotificationRoute.JOURNAL) {
            parseJournalDay(journalDayRaw)
        } else {
            null
        }
        PendingNotificationRouteRequest(route, journalDay)
    }

    fun consumePending(context: Context): NoopNotificationRoute? =
        consumePendingRequest(context)?.route

    fun journalDayOffset(
        request: PendingNotificationRouteRequest,
        today: LocalDate = LocalDate.now(),
    ): Long? {
        if (request.route != NoopNotificationRoute.JOURNAL) return null
        val day = request.journalDay ?: return null
        return ChronoUnit.DAYS.between(day, today).takeIf { it in -1L..31L }
    }

    fun journalDayOffset(
        journalDay: String?,
        today: LocalDate = LocalDate.now(),
    ): Long? {
        val day = parseJournalDay(journalDay) ?: return null
        return ChronoUnit.DAYS.between(day, today).takeIf { it in -1L..31L }
    }

    fun canonicalJournalDay(raw: String?): String? = parseJournalDay(raw)?.toString()

    private fun parseJournalDay(raw: String?): LocalDate? =
        raw?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
}
