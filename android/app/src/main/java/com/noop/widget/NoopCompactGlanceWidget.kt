package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
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

/** Compact 2×1 widget: three honest scores plus last/live HR and battery, without tiny status prose. */
class NoopCompactGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        provideContent { CompactWidgetContent(context, snap, context.noopWidgetAppearance()) }
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
private fun CompactWidgetContent(context: Context, snap: WidgetSnapshot, appearance: NoopWidgetAppearance) {
    val colors = noopWidgetColors(appearance)
    val today = widgetRouteAction(context, NoopNotificationRoute.TODAY)
    val isLive = snap.freshness(System.currentTimeMillis()) == WidgetFreshness.LIVE
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(colors.surface)
            .cornerRadius(20.dp)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = context.getString(
                    if (isLive) R.string.widget_live_prefix else R.string.widget_offline_prefix,
                    snap.compactScoreContextText(context),
                ),
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(
                    color = if (isLive) colors.positive else colors.primary,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            Text(
                text = snap.heartRate?.let { "♥ $it" } ?: "♥ —",
                modifier = GlanceModifier.clickable(widgetRouteAction(context, NoopNotificationRoute.LIVE)),
                style = TextStyle(color = colors.primary, fontSize = 10.sp, fontWeight = FontWeight.Medium),
            )
            Spacer(modifier = GlanceModifier.width(8.dp))
            Text(
                text = snap.batteryPct?.let { context.getString(R.string.widget_battery_value, it) } ?: "▰ —",
                modifier = GlanceModifier.clickable(today),
                style = TextStyle(color = colors.secondary, fontSize = 10.sp),
            )
        }
        Spacer(modifier = GlanceModifier.height(6.dp))
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CompactScoreCell(
                label = context.getString(R.string.l10n_noop_compact_glance_widget_rest_cbaaa181),
                iconRes = R.drawable.ic_widget_rest,
                pct = snap.restPct,
                color = if (snap.restPct == null) colors.secondary else colors.sleep,
                action = widgetRouteAction(context, NoopNotificationRoute.SLEEP),
                modifier = GlanceModifier.defaultWeight(),
            )
            CompactScoreCell(
                label = context.getString(R.string.l10n_noop_compact_glance_widget_charge_49a8cb83),
                iconRes = R.drawable.ic_widget_charge,
                pct = snap.recoveryPct,
                color = recoveryWidgetColor(snap.recoveryPct, colors),
                action = today,
                emphasized = true,
                modifier = GlanceModifier.defaultWeight(),
            )
            CompactScoreCell(
                label = context.getString(R.string.l10n_noop_compact_glance_widget_effort_660752e7),
                iconRes = R.drawable.ic_widget_effort,
                pct = snap.effortPct,
                color = if (snap.effortPct == null) colors.secondary else colors.effort,
                action = widgetRouteAction(context, NoopNotificationRoute.TRENDS),
                modifier = GlanceModifier.defaultWeight(),
            )
        }
    }
}

@Composable
private fun CompactScoreCell(
    label: String,
    iconRes: Int,
    pct: Int?,
    color: ColorProvider,
    action: Action,
    emphasized: Boolean = false,
    modifier: GlanceModifier = GlanceModifier,
) {
    Row(
        modifier = modifier.clickable(action).padding(horizontal = 2.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            provider = ImageProvider(iconRes),
            contentDescription = label,
            modifier = GlanceModifier.width(if (emphasized) 17.dp else 15.dp)
                .height(if (emphasized) 17.dp else 15.dp),
            colorFilter = ColorFilter.tint(color),
        )
        Spacer(modifier = GlanceModifier.width(3.dp))
        Text(
            text = pct?.toString() ?: "—",
            style = TextStyle(
                color = color,
                fontSize = if (emphasized) 21.sp else 18.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
    }
}
