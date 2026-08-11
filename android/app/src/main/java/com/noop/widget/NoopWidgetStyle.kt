package com.noop.widget

import android.content.Context
import android.content.res.Configuration
import androidx.compose.ui.graphics.Color
import androidx.glance.action.Action
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.text.DateFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** A restrained black/white surface with small metric accents; shared by every Android widget. */
internal data class NoopWidgetColors(
    val surface: ColorProvider,
    val inset: ColorProvider,
    val primary: ColorProvider,
    val secondary: ColorProvider,
    val hairline: ColorProvider,
    val positive: ColorProvider,
    val warning: ColorProvider,
    val critical: ColorProvider,
    val sleep: ColorProvider,
    val effort: ColorProvider,
)

internal fun noopWidgetColors(dark: Boolean): NoopWidgetColors = NoopWidgetColors(
    surface = ColorProvider(if (dark) Color(0xFF080808) else Color(0xFFF4F4F1)),
    inset = ColorProvider(if (dark) Color(0xFF181818) else Color(0xFFFFFFFF)),
    primary = ColorProvider(if (dark) Color(0xFFF8F8F6) else Color(0xFF0B0B0B)),
    secondary = ColorProvider(if (dark) Color(0xFFA0A0A0) else Color(0xFF686868)),
    hairline = ColorProvider(if (dark) Color(0xFF2B2B2B) else Color(0xFFE3E3DF)),
    positive = ColorProvider(if (dark) Color(0xFF31D9A2) else Color(0xFF087A58)),
    warning = ColorProvider(if (dark) Color(0xFFFFC45A) else Color(0xFF9A6410)),
    critical = ColorProvider(if (dark) Color(0xFFFF765D) else Color(0xFFA93825)),
    sleep = ColorProvider(if (dark) Color(0xFF76AFFF) else Color(0xFF275FAE)),
    effort = ColorProvider(if (dark) Color(0xFFA28BFF) else Color(0xFF6346BE)),
)

internal fun Context.noopWidgetDarkMode(): Boolean = runCatching {
    when (getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
        .getString("theme.appearance", "system")) {
        "light" -> false
        "dark" -> true
        else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
    }
}.getOrDefault(true)

internal fun recoveryWidgetColor(score: Int?, colors: NoopWidgetColors): ColorProvider = when {
    score == null -> colors.secondary
    score >= 67 -> colors.positive
    score >= 34 -> colors.warning
    else -> colors.critical
}

/** Day + source caption. A carried score names its actual day instead of masquerading as today. */
internal fun WidgetSnapshot.scoreContextText(context: Context, today: LocalDate = LocalDate.now()): String {
    val contextDay = scoreDay ?: vitalsDay
    val contextSource = scoreSource ?: vitalsSource
    val dayText = contextDay?.let { raw ->
        runCatching { LocalDate.parse(raw) }.getOrNull()?.let { day ->
            if (day == today) context.getString(R.string.nav_today)
            else DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
                .withLocale(context.resources.configuration.locales[0])
                .format(day)
        }
    }
    val sourceText = when (WidgetScoreSource.fromStorageKey(contextSource)) {
        WidgetScoreSource.NOOP -> context.getString(R.string.widget_source_noop)
        WidgetScoreSource.WEARABLE -> context.getString(R.string.widget_source_wearable)
        WidgetScoreSource.HEALTH_CONNECT -> context.getString(R.string.widget_source_health_connect)
        WidgetScoreSource.APPLE_HEALTH -> context.getString(R.string.widget_source_apple_health)
        WidgetScoreSource.ACTIVITY_FILE -> context.getString(R.string.widget_source_activity_file)
        null -> null
    }
    return listOfNotNull(dayText, sourceText).joinToString(" · ")
        .ifEmpty { context.getString(R.string.widget_latest_available) }
}

internal fun WidgetSnapshot.compactScoreContextText(
    context: Context,
    today: LocalDate = LocalDate.now(),
): String {
    val shortDay = scoreDay?.let { raw ->
        runCatching { LocalDate.parse(raw) }.getOrNull()?.let { day ->
            if (day == today) context.getString(R.string.nav_today)
            else DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)
                .withLocale(context.resources.configuration.locales[0])
                .format(day)
        }
    }
    return listOfNotNull("NOOP", shortDay).joinToString(" · ")
}

internal fun WidgetSnapshot.wideContextText(
    context: Context,
    today: LocalDate = LocalDate.now(),
): String {
    if (scoreDay == null || vitalsDay == null || scoreDay == vitalsDay) return scoreContextText(context, today)
    fun shortDay(raw: String): String = runCatching { LocalDate.parse(raw) }.getOrNull()?.let { day ->
        if (day == today) context.getString(R.string.nav_today)
        else DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)
            .withLocale(context.resources.configuration.locales[0])
            .format(day)
    } ?: raw
    return context.getString(R.string.widget_mixed_days, shortDay(scoreDay), shortDay(vitalsDay))
}

/** Connection/update copy backed by the explicit freshness state, never by an assumed live cadence. */
internal fun WidgetSnapshot.freshnessText(context: Context, nowMs: Long = System.currentTimeMillis()): String {
    val formattedTime = updatedAtMs.takeIf { it > 0L }?.let {
        DateFormat.getTimeInstance(DateFormat.SHORT).format(java.util.Date(it))
    }
    return when (freshness(nowMs)) {
        WidgetFreshness.LIVE -> context.getString(R.string.widget_connected)
        WidgetFreshness.RECENT -> context.getString(R.string.widget_updated_at, formattedTime ?: "—")
        WidgetFreshness.STALE -> context.getString(R.string.widget_last_update_at, formattedTime ?: "—")
        WidgetFreshness.EMPTY -> context.getString(R.string.widget_open_noop)
    }
}

internal fun formatWidgetSleep(context: Context, minutes: Int?): String {
    if (minutes == null || minutes < 0) return "—"
    return context.getString(R.string.widget_sleep_duration_format, minutes / 60, minutes % 60)
}

internal fun widgetRouteAction(context: Context, route: NoopNotificationRoute): Action =
    actionStartActivity(NotificationRouteBridge.launchIntent(context, route))
