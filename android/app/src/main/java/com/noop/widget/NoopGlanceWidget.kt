package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.TextUnit
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

/**
 * The balanced 2×2 Daily Signal widget. It reads only the private snapshot written by the app/service,
 * never opens Room or BLE, and gives each score a trusted in-app destination.
 */
class NoopGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        provideContent { WidgetContent(context, snap, context.noopWidgetAppearance()) }
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
private fun WidgetContent(context: Context, snap: WidgetSnapshot, appearance: NoopWidgetAppearance) {
    val colors = noopWidgetColors(appearance)
    val today = widgetRouteAction(context, NoopNotificationRoute.TODAY)
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(colors.surface)
            .cornerRadius(22.dp)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "NOOP",
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.Bold),
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            Text(
                text = snap.scoreContextText(context),
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(color = colors.secondary, fontSize = 9.sp),
                maxLines = 1,
            )
        }
        Spacer(modifier = GlanceModifier.height(8.dp))
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.Bottom,
        ) {
            ScoreCell(
                label = context.getString(R.string.l10n_noop_glance_widget_rest_cbaaa181),
                pct = snap.restPct,
                color = if (snap.restPct == null) colors.secondary else colors.sleep,
                valueSize = 23.sp,
                colors = colors,
                action = widgetRouteAction(context, NoopNotificationRoute.SLEEP),
                modifier = GlanceModifier.defaultWeight(),
            )
            ScoreCell(
                label = context.getString(R.string.l10n_noop_glance_widget_charge_49a8cb83),
                pct = snap.recoveryPct,
                color = recoveryWidgetColor(snap.recoveryPct, colors),
                valueSize = 30.sp,
                colors = colors,
                action = today,
                modifier = GlanceModifier.defaultWeight(),
            )
            ScoreCell(
                label = context.getString(R.string.l10n_noop_glance_widget_effort_660752e7),
                pct = snap.effortPct,
                color = if (snap.effortPct == null) colors.secondary else colors.effort,
                valueSize = 23.sp,
                colors = colors,
                action = widgetRouteAction(context, NoopNotificationRoute.TRENDS),
                modifier = GlanceModifier.defaultWeight(),
            )
        }
        Spacer(modifier = GlanceModifier.height(7.dp))
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = snap.freshnessText(context),
                modifier = GlanceModifier.defaultWeight().clickable(today),
                style = TextStyle(
                    color = if (snap.freshness(System.currentTimeMillis()) == WidgetFreshness.LIVE)
                        colors.positive else colors.secondary,
                    fontSize = 10.sp,
                ),
                maxLines = 1,
            )
            MetricPill(
                text = snap.heartRate?.let { "♥ $it" } ?: "♥ -",
                action = widgetRouteAction(context, NoopNotificationRoute.LIVE),
                colors = colors,
            )
            Spacer(modifier = GlanceModifier.width(5.dp))
            MetricPill(
                text = snap.batteryPct?.let { context.getString(R.string.widget_battery_value, it) } ?: "▰ -",
                action = today,
                colors = colors,
            )
        }
    }
}

@Composable
private fun ScoreCell(
    label: String,
    pct: Int?,
    color: ColorProvider,
    valueSize: TextUnit,
    colors: NoopWidgetColors,
    action: Action,
    modifier: GlanceModifier = GlanceModifier,
) {
    Column(
        modifier = modifier
            .background(colors.inset)
            .cornerRadius(13.dp)
            .clickable(action)
            .padding(horizontal = 4.dp, vertical = 5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = pct?.toString() ?: "-",
            style = TextStyle(color = color, fontSize = valueSize, fontWeight = FontWeight.Bold),
        )
        Text(
            text = label,
            style = TextStyle(color = colors.secondary, fontSize = 8.sp, fontWeight = FontWeight.Medium),
            maxLines = 1,
        )
    }
}

@Composable
private fun MetricPill(text: String, action: Action, colors: NoopWidgetColors) {
    Text(
        text = text,
        modifier = GlanceModifier
            .background(colors.inset)
            .cornerRadius(10.dp)
            .clickable(action)
            .padding(horizontal = 7.dp, vertical = 4.dp),
        style = TextStyle(color = colors.primary, fontSize = 10.sp, fontWeight = FontWeight.Medium),
        maxLines = 1,
    )
}
