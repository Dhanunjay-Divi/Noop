package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.NoopNotificationRoute

/** Wide Daily Signal: the three scores plus the overnight vitals people act on most often. */
class NoopWideGlanceWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        provideContent { WideWidgetContent(context, snap, context.noopWidgetAppearance()) }
    }

    override fun onCompositionError(
        context: Context,
        glanceId: GlanceId,
        appWidgetId: Int,
        throwable: Throwable,
    ) {
        runCatching {
            val rv = context.noopWidgetErrorRemoteViews()
            android.appwidget.AppWidgetManager.getInstance(context).updateAppWidget(appWidgetId, rv)
        }
    }
}

@Composable
private fun WideWidgetContent(context: Context, snap: WidgetSnapshot, appearance: NoopWidgetAppearance) {
    val colors = noopWidgetColors(appearance)
    val today = widgetRouteAction(context, NoopNotificationRoute.TODAY)
    val sleep = widgetRouteAction(context, NoopNotificationRoute.SLEEP)
    val health = widgetRouteAction(context, NoopNotificationRoute.HEALTH)
    val live = widgetRouteAction(context, NoopNotificationRoute.LIVE)
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(colors.surface)
            .cornerRadius(24.dp)
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = context.getString(R.string.widget_daily_signal),
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.Bold),
            )
            Spacer(modifier = GlanceModifier.width(8.dp))
            Text(
                text = snap.wideContextText(context),
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(color = colors.secondary, fontSize = 9.sp),
                maxLines = 1,
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            Text(
                text = snap.freshnessText(context),
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(
                    color = if (snap.freshness(System.currentTimeMillis()) == WidgetFreshness.LIVE)
                        colors.positive else colors.secondary,
                    fontSize = 9.sp,
                ),
                maxLines = 1,
            )
        }
        Spacer(modifier = GlanceModifier.height(8.dp))
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(
                modifier = GlanceModifier.defaultWeight()
                    .background(colors.inset)
                    .cornerRadius(16.dp)
                    .clickable(today)
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            ) {
                Text(
                    text = context.getString(R.string.l10n_noop_glance_widget_charge_49a8cb83),
                    style = TextStyle(color = colors.secondary, fontSize = 8.sp, fontWeight = FontWeight.Medium),
                )
                Text(
                    text = snap.recoveryPct?.let { context.getString(R.string.widget_percent_value, it) } ?: "-",
                    style = TextStyle(
                        color = recoveryWidgetColor(snap.recoveryPct, colors),
                        fontSize = 34.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                )
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    MiniScore(
                        label = context.getString(R.string.l10n_noop_glance_widget_rest_cbaaa181),
                        value = snap.restPct,
                        color = if (snap.restPct == null) colors.secondary else colors.sleep,
                        action = sleep,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                    MiniScore(
                        label = context.getString(R.string.l10n_noop_glance_widget_effort_660752e7),
                        value = snap.effortPct,
                        color = if (snap.effortPct == null) colors.secondary else colors.effort,
                        action = widgetRouteAction(context, NoopNotificationRoute.TRENDS),
                        modifier = GlanceModifier.defaultWeight(),
                    )
                }
            }
            Spacer(modifier = GlanceModifier.width(8.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    WideMetric(
                        label = context.getString(R.string.widget_hrv),
                        value = snap.hrvMs?.toString(),
                        unit = context.getString(R.string.widget_unit_ms),
                        action = health,
                        colors = colors,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                    Spacer(modifier = GlanceModifier.width(5.dp))
                    WideMetric(
                        label = context.getString(R.string.widget_resting_hr),
                        value = snap.restingHr?.toString(),
                        unit = context.getString(R.string.widget_unit_bpm),
                        action = health,
                        colors = colors,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                    Spacer(modifier = GlanceModifier.width(5.dp))
                    WideMetric(
                        label = context.getString(R.string.widget_sleep_duration),
                        value = formatWidgetSleep(context, snap.sleepMinutes),
                        action = sleep,
                        colors = colors,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                }
                Spacer(modifier = GlanceModifier.height(6.dp))
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    WideMetric(
                        label = context.getString(R.string.widget_heart_rate),
                        value = snap.heartRate?.toString(),
                        unit = context.getString(R.string.widget_unit_bpm),
                        action = live,
                        colors = colors,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                    Spacer(modifier = GlanceModifier.width(5.dp))
                    WideMetric(
                        label = context.getString(R.string.widget_battery),
                        value = snap.batteryPct?.let { "$it%" },
                        action = today,
                        colors = colors,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                }
            }
        }
    }
}

@Composable
private fun MiniScore(
    label: String,
    value: Int?,
    color: ColorProvider,
    action: Action,
    modifier: GlanceModifier,
) {
    Row(modifier = modifier.clickable(action), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = value?.toString() ?: "-",
            style = TextStyle(color = color, fontSize = 15.sp, fontWeight = FontWeight.Bold),
        )
        Spacer(modifier = GlanceModifier.width(3.dp))
        Text(text = label, style = TextStyle(color = color, fontSize = 8.sp), maxLines = 1)
    }
}

@Composable
private fun WideMetric(
    label: String,
    value: String?,
    unit: String? = null,
    action: Action,
    colors: NoopWidgetColors,
    modifier: GlanceModifier,
) {
    Column(
        modifier = modifier
            .background(colors.inset)
            .cornerRadius(12.dp)
            .clickable(action)
            .padding(horizontal = 7.dp, vertical = 6.dp),
    ) {
        Text(text = label, style = TextStyle(color = colors.secondary, fontSize = 8.sp), maxLines = 1)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = value ?: "-",
                style = TextStyle(color = colors.primary, fontSize = 15.sp, fontWeight = FontWeight.Bold),
                maxLines = 1,
            )
            if (value != null && unit != null) {
                Spacer(modifier = GlanceModifier.width(2.dp))
                Text(text = unit, style = TextStyle(color = colors.secondary, fontSize = 7.sp), maxLines = 1)
            }
        }
    }
}
