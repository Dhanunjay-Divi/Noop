package com.noop.widget

import android.content.Context
import android.content.res.Configuration
import android.widget.RemoteViews
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.glance.action.Action
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.color.ColorProvider as DayNightColorProvider
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.BlackTokens
import com.noop.ui.DarkTokens
import com.noop.ui.LightTokens
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

/** SYSTEM stays distinct so Glance can emit day/night-aware RemoteViews instead of freezing whichever
 * mode happened to be active during the last widget recomposition. */
internal enum class NoopWidgetAppearance { SYSTEM, LIGHT, DARK, BLACK }

internal data class NoopWidgetTokenPair(
    val day: com.noop.ui.PaletteTokens,
    val night: com.noop.ui.PaletteTokens,
)

internal fun noopWidgetTokenPair(appearance: NoopWidgetAppearance): NoopWidgetTokenPair = when (appearance) {
    NoopWidgetAppearance.SYSTEM -> NoopWidgetTokenPair(LightTokens, DarkTokens)
    NoopWidgetAppearance.LIGHT -> NoopWidgetTokenPair(LightTokens, LightTokens)
    NoopWidgetAppearance.DARK -> NoopWidgetTokenPair(DarkTokens, DarkTokens)
    NoopWidgetAppearance.BLACK -> NoopWidgetTokenPair(BlackTokens, BlackTokens)
}

/** Raw values make exact app/widget parity testable before Glance wraps them in providers. */
internal data class NoopWidgetColorValues(
    val surface: Color,
    val inset: Color,
    val primary: Color,
    val secondary: Color,
    val hairline: Color,
    val positive: Color,
    val warning: Color,
    val critical: Color,
    val sleep: Color,
    val effort: Color,
)

internal fun noopWidgetColorValues(
    appearance: NoopWidgetAppearance,
    systemDark: Boolean = false,
): NoopWidgetColorValues {
    val pair = noopWidgetTokenPair(appearance)
    val tokens = if (systemDark) pair.night else pair.day
    return NoopWidgetColorValues(
        surface = tokens.surfaceBase,
        inset = tokens.surfaceRaised,
        primary = tokens.textPrimary,
        secondary = tokens.textSecondary,
        hairline = tokens.hairline,
        positive = tokens.statusPositive,
        warning = tokens.statusWarning,
        critical = tokens.statusCritical,
        sleep = tokens.restColor,
        effort = tokens.effortColor,
    )
}

internal fun noopWidgetColors(appearance: NoopWidgetAppearance): NoopWidgetColors {
    val day = noopWidgetColorValues(appearance, systemDark = false)
    val night = noopWidgetColorValues(appearance, systemDark = true)
    fun adaptive(dayColor: Color, nightColor: Color): ColorProvider =
        if (dayColor == nightColor) ColorProvider(dayColor)
        else DayNightColorProvider(day = dayColor, night = nightColor)
    return NoopWidgetColors(
        surface = adaptive(day.surface, night.surface),
        inset = adaptive(day.inset, night.inset),
        primary = adaptive(day.primary, night.primary),
        secondary = adaptive(day.secondary, night.secondary),
        hairline = adaptive(day.hairline, night.hairline),
        positive = adaptive(day.positive, night.positive),
        warning = adaptive(day.warning, night.warning),
        critical = adaptive(day.critical, night.critical),
        sleep = adaptive(day.sleep, night.sleep),
        effort = adaptive(day.effort, night.effort),
    )
}

/** Resolve the persisted value without collapsing System into a one-time configuration snapshot. */
internal fun resolveNoopWidgetAppearance(raw: String?): NoopWidgetAppearance = when (raw) {
    "system" -> NoopWidgetAppearance.SYSTEM
    "light" -> NoopWidgetAppearance.LIGHT
    "dark" -> NoopWidgetAppearance.DARK
    "black" -> NoopWidgetAppearance.BLACK
    else -> NoopWidgetAppearance.BLACK
}

internal fun Context.noopWidgetAppearance(): NoopWidgetAppearance = runCatching {
    resolveNoopWidgetAppearance(
        getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
            .getString("theme.appearance", "black"),
    )
}.getOrDefault(NoopWidgetAppearance.BLACK)

/** Composition-failure fallback that still honors explicit Light/Dark/Black app appearance. */
internal fun Context.noopWidgetErrorRemoteViews(): RemoteViews {
    val systemDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    val values = noopWidgetColorValues(noopWidgetAppearance(), systemDark)
    return RemoteViews(packageName, R.layout.noop_widget_error).apply {
        setInt(R.id.noop_widget_error_root, "setBackgroundColor", values.surface.toArgb())
        setTextColor(R.id.noop_widget_error_root, values.secondary.toArgb())
    }
}

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
        WidgetFreshness.RECENT -> context.getString(R.string.widget_updated_at, formattedTime ?: "-")
        WidgetFreshness.STALE -> context.getString(R.string.widget_last_update_at, formattedTime ?: "-")
        WidgetFreshness.EMPTY -> context.getString(R.string.widget_open_noop)
    }
}

internal fun formatWidgetSleep(context: Context, minutes: Int?): String {
    if (minutes == null || minutes < 0) return "-"
    return context.getString(R.string.widget_sleep_duration_format, minutes / 60, minutes % 60)
}

internal fun widgetRouteAction(context: Context, route: NoopNotificationRoute): Action =
    actionStartActivity(NotificationRouteBridge.launchIntent(context, route))
