package com.noop.ui

import android.content.Context
import android.content.Intent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Trusted top-level destinations that a NOOP-owned notification may open. */
internal enum class NoopNotificationRoute(val navRoute: String) {
    TODAY("today"),
    TRENDS("trends"),
    SLEEP("sleep"),
    LIVE("live"),
    HEALTH("health"),
    HYDRATION("hydration"),
    BREATHE("breathe"),
    SAFETY("safety"),
    COACH("coach");

    companion object {
        fun fromRaw(raw: String?): NoopNotificationRoute? = entries.firstOrNull { it.navRoute == raw }
    }
}

/**
 * Durable hand-off from [MainActivity]'s launch intent to the Compose navigation shell.
 *
 * A cold launch can receive the notification intent before onboarding/terms/changelog gates allow
 * [AppRoot] to exist. Persisting one trusted pending route covers that case; [routeRequests] wakes an
 * already-mounted warm activity. Consumption removes the route first so it cannot reopen on relaunch.
 */
internal object NotificationRouteBridge {
    const val EXTRA_ROUTE = "com.noop.extra.NOTIFICATION_ROUTE"
    private const val KEY_PENDING_ROUTE = "noop.notification.pendingRoute"

    private val lock = Any()
    private val _routeRequests = MutableStateFlow(0L)
    val routeRequests: StateFlow<Long> = _routeRequests.asStateFlow()

    fun launchIntent(context: Context, route: NoopNotificationRoute): Intent =
        appLaunchIntent(context).putExtra(EXTRA_ROUTE, route.navRoute)

    /** Record a recognized route and consume the intent extra so configuration recreation cannot replay it. */
    fun recordFromIntent(context: Context, intent: Intent?): Boolean {
        val raw = intent?.getStringExtra(EXTRA_ROUTE)
        if (raw != null) intent.removeExtra(EXTRA_ROUTE)
        val route = NoopNotificationRoute.fromRaw(raw) ?: return false
        synchronized(lock) {
            NoopPrefs.of(context).edit().putString(KEY_PENDING_ROUTE, route.navRoute).apply()
            _routeRequests.value += 1L
        }
        return true
    }

    /** Return one pending trusted route, removing it before navigation. */
    fun consumePending(context: Context): NoopNotificationRoute? = synchronized(lock) {
        val prefs = NoopPrefs.of(context)
        val raw = prefs.getString(KEY_PENDING_ROUTE, null)
        prefs.edit().remove(KEY_PENDING_ROUTE).apply()
        NoopNotificationRoute.fromRaw(raw)
    }
}
