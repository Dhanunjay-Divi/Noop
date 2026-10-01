package com.noop.ui

import com.noop.R
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
internal fun BandPairingOptionGroup(content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceRaised)
            .border(1.dp, Palette.hairline, shape),
    ) {
        content()
    }
}

@Composable
internal fun BandPairingOptionRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    enabled: Boolean = true,
    showDivider: Boolean = false,
    onClick: () -> Unit,
) {
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 64.dp)
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .padding(horizontal = Metrics.space14, vertical = Metrics.space10),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val iconShape = RoundedCornerShape(8.dp)
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(iconShape)
                    .background(Palette.surfaceInset)
                    .border(1.dp, Palette.hairline, iconShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = if (enabled) Palette.accent else Palette.textTertiary,
                    modifier = Modifier.size(21.dp),
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Metrics.space2),
            ) {
                Text(
                    title,
                    style = NoopType.headline,
                    color = if (enabled) Palette.textPrimary else Palette.textSecondary,
                )
                Text(
                    subtitle,
                    style = NoopType.caption,
                    color = if (enabled) {
                        Palette.textTertiary
                    } else {
                        Palette.statusWarningText
                    },
                )
            }
            Icon(
                if (enabled) {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                } else {
                    Icons.Filled.Warning
                },
                contentDescription = null,
                tint = if (enabled) Palette.textTertiary else Palette.statusWarning,
                modifier = Modifier.size(20.dp),
            )
        }
        if (showDivider) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 62.dp),
                thickness = 1.dp,
                color = Palette.hairline,
            )
        }
    }
}

internal fun shouldAnimateBandPairingDiscovery(
    searching: Boolean,
    motionSuppressed: Boolean,
): Boolean = searching && !motionSuppressed

/**
 * Static arcs communicate that discovery is ready. A bounded sweep is composed only while a real
 * search is active and motion is allowed, so idle and reduced-motion states do no per-frame work.
 */
@Composable
internal fun BandPairingDiscoveryStage(
    searching: Boolean,
    modifier: Modifier = Modifier,
) {
    val motionSuppressed = rememberPoseStill()
    val animate = shouldAnimateBandPairingDiscovery(searching, motionSuppressed)
    val statusTitle = if (searching) {
        uiString(R.string.appwide_onboarding_device_wizard_searching)
    } else {
        uiString(R.string.appwide_onboarding_device_wizard_idle)
    }
    val sweep = if (animate) {
        val transition = rememberInfiniteTransition(label = statusTitle)
        transition.animateFloat(
            initialValue = 0f,
            targetValue = 360f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 3_200, easing = LinearEasing),
            ),
            label = statusTitle,
        )
    } else {
        null
    }
    val shape = RoundedCornerShape(8.dp)
    val statusBody = if (searching) {
        uiString(R.string.l10n_add_device_wizard_make_sure_it_s_awake_and_8c40e59f)
    } else {
        uiString(R.string.appwide_onboarding_device_wizard_add_body)
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = Metrics.space16, vertical = Metrics.space12),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        Box(
            modifier = Modifier.size(116.dp),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                val center = Offset(size.width / 2f, size.height / 2f)
                val radii = listOf(28.dp.toPx(), 40.dp.toPx(), 52.dp.toPx())
                val stroke = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round)
                radii.forEachIndexed { index, radius ->
                    drawArc(
                        color = Palette.hairlineStrong.copy(alpha = 0.32f + (index * 0.10f)),
                        startAngle = 205f,
                        sweepAngle = 310f,
                        useCenter = false,
                        topLeft = Offset(center.x - radius, center.y - radius),
                        size = Size(radius * 2f, radius * 2f),
                        style = stroke,
                    )
                }
                val motion = sweep?.value ?: 0f
                drawArc(
                    color = Palette.accent.copy(alpha = if (searching) 0.90f else 0.42f),
                    startAngle = if (animate) motion - 34f else -112f,
                    sweepAngle = 68f,
                    useCenter = false,
                    topLeft = Offset(center.x - radii[2], center.y - radii[2]),
                    size = Size(radii[2] * 2f, radii[2] * 2f),
                    style = Stroke(width = 2.5.dp.toPx(), cap = StrokeCap.Round),
                )
                drawArc(
                    color = Palette.accent.copy(alpha = if (searching) 0.52f else 0.28f),
                    startAngle = if (animate) 110f - (motion * 0.68f) else 110f,
                    sweepAngle = 96f,
                    useCenter = false,
                    topLeft = Offset(center.x - radii[1], center.y - radii[1]),
                    size = Size(radii[1] * 2f, radii[1] * 2f),
                    style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round),
                )
                drawArc(
                    color = Palette.accent.copy(alpha = if (searching) 0.32f else 0.18f),
                    startAngle = if (animate) 230f + (motion * 0.42f) else 230f,
                    sweepAngle = 118f,
                    useCenter = false,
                    topLeft = Offset(center.x - radii[0], center.y - radii[0]),
                    size = Size(radii[0] * 2f, radii[0] * 2f),
                    style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round),
                )
            }
            val iconShape = RoundedCornerShape(8.dp)
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(iconShape)
                    .background(Palette.surfaceRaised)
                    .border(1.dp, Palette.hairlineStrong, iconShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Watch,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        Text(statusTitle, style = NoopType.headline, color = Palette.textPrimary)
        Text(
            statusBody,
            style = NoopType.subhead,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}
