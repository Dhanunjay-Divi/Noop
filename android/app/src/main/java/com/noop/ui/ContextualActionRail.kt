package com.noop.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Bed
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R

@Composable
internal fun ContextualActionRail(
    actions: List<ContextualAction>,
    processingIds: Set<String>,
    expandedId: String?,
    onExpandedChange: (String?) -> Unit,
    onPrimary: (ContextualAction) -> Unit,
    onDismiss: (ContextualAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.animateContentSize(
            animationSpec = tween(durationMillis = 280),
        ),
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        actions.forEach { action ->
            if (expandedId == action.id) {
                ExpandedContextualAction(
                    action = action,
                    processing = action.id in processingIds,
                    onCollapse = { onExpandedChange(null) },
                    onPrimary = { onPrimary(action) },
                    onDismiss = {
                        onExpandedChange(null)
                        onDismiss(action)
                    },
                )
            } else {
                CollapsedContextualAction(
                    action = action,
                    onExpand = { onExpandedChange(action.id) },
                )
            }
        }
    }
}

@Composable
private fun CollapsedContextualAction(
    action: ContextualAction,
    onExpand: () -> Unit,
) {
    val tint = contextualActionTint(action.kind)
    val hint = stringResource(R.string.context_action_show_reason)
    Box(
        modifier = Modifier
            .size(48.dp)
            .testTag("noop.context-action.${action.kind.name.lowercase()}")
            .navigationGlassSurface(CircleShape, accentRim = tint.copy(alpha = 0.42f))
            .clickable(onClick = onExpand)
            .semantics {
                contentDescription = action.title
                onClick(label = hint) {
                    onExpand()
                    true
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        ContextualActionGlyph(action, tint, 19.dp)
    }
}

@Composable
private fun ExpandedContextualAction(
    action: ContextualAction,
    processing: Boolean,
    onCollapse: () -> Unit,
    onPrimary: () -> Unit,
    onDismiss: () -> Unit,
) {
    val tint = contextualActionTint(action.kind)
    val shape = RoundedCornerShape(8.dp)
    Column(
        modifier = Modifier
            .widthIn(min = 250.dp, max = 274.dp)
            .navigationGlassSurface(shape, accentRim = tint.copy(alpha = 0.34f))
            .border(0.8.dp, tint.copy(alpha = 0.30f), shape)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .background(tint.copy(alpha = 0.13f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                ContextualActionGlyph(action, tint, 17.dp)
            }
            Text(
                text = action.title,
                style = NoopType.headline,
                color = Palette.textPrimary,
                maxLines = 3,
                modifier = Modifier.weight(1f),
            )
            ContextualIconControl(
                icon = Icons.Filled.ChevronRight,
                label = stringResource(R.string.context_action_collapse),
                onClick = onCollapse,
            )
            ContextualIconControl(
                icon = Icons.Filled.Close,
                label = stringResource(R.string.context_action_dismiss),
                onClick = onDismiss,
            )
        }

        if (action.detail.isNotBlank()) {
            Text(
                text = action.detail,
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }

        if (action.evidence.isNotEmpty()) {
            Text(
                text = stringResource(R.string.context_action_why_now),
                style = NoopType.overline,
                color = Palette.textTertiary,
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                action.evidence.take(3).forEach { line ->
                    Row(
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(7.dp),
                    ) {
                        Box(
                            Modifier
                                .padding(top = 6.dp)
                                .size(5.dp)
                                .background(tint, CircleShape),
                        )
                        Text(
                            text = line,
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        Button(
            onClick = onPrimary,
            enabled = !processing,
            shape = RoundedCornerShape(8.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = tint,
                contentColor = Color.White,
                disabledContainerColor = tint.copy(alpha = 0.52f),
                disabledContentColor = Color.White.copy(alpha = 0.76f),
            ),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 42.dp)
                .testTag("noop.context-action.primary.${action.kind.name.lowercase()}")
                .alpha(if (processing) 0.72f else 1f),
        ) {
            Icon(
                imageVector = primaryIcon(action),
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = primaryTitle(action),
                style = NoopType.subhead,
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun ContextualIconControl(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Palette.textSecondary,
            modifier = Modifier.size(17.dp),
        )
    }
}

@Composable
private fun ContextualActionGlyph(
    action: ContextualAction,
    tint: Color,
    size: androidx.compose.ui.unit.Dp,
) {
    if (action.kind == ContextualActionKind.HYDRATION) {
        HydrationGlassGlyph(
            fill = 0.38f,
            tint = tint,
            modifier = Modifier
                .width(size)
                .height(size + 3.dp),
        )
    } else {
        Icon(
            imageVector = actionIcon(action),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(size),
        )
    }
}

@Composable
internal fun HydrationLoggedConfirmation(
    amountMl: Int,
    modifier: Modifier = Modifier,
) {
    var targetFill by remember(amountMl) { mutableStateOf(0.08f) }
    val fill by animateFloatAsState(
        targetValue = targetFill,
        animationSpec = tween(durationMillis = 720),
        label = "hydration_glass_fill",
    )
    LaunchedEffect(amountMl) { targetFill = 0.92f }
    val shape = RoundedCornerShape(8.dp)
    val confirmationDescription = stringResource(
        R.string.context_action_logged_water_accessibility,
        amountMl,
    )
    Row(
        modifier = modifier
            .height(52.dp)
            .navigationGlassSurface(shape, accentRim = Palette.metricCyan.copy(alpha = 0.46f))
            .border(0.8.dp, Palette.metricCyan.copy(alpha = 0.42f), shape)
            .padding(horizontal = 14.dp)
            .semantics {
                contentDescription = confirmationDescription
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        HydrationGlassGlyph(
            fill = fill,
            tint = Palette.metricCyan,
            modifier = Modifier
                .width(24.dp)
                .height(29.dp),
        )
        Text(
            text = stringResource(R.string.context_action_logged_water, amountMl),
            style = NoopType.headline,
            color = Palette.textPrimary,
        )
    }
}

@Composable
private fun HydrationGlassGlyph(
    fill: Float,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(3.dp)
    Box(
        modifier = modifier
            .border(1.6.dp, tint, shape)
            .padding(2.dp),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .fillMaxHeight(fill.coerceIn(0f, 1f))
                .background(tint.copy(alpha = 0.88f), RoundedCornerShape(2.dp)),
        )
    }
}

private fun contextualActionTint(kind: ContextualActionKind): Color = when (kind) {
    ContextualActionKind.HYDRATION -> Palette.metricCyan
    ContextualActionKind.BREATHE -> Palette.restColor
    ContextualActionKind.JOURNAL -> Palette.accent
    ContextualActionKind.WIND_DOWN -> Palette.metricPurple
    ContextualActionKind.RECOVERY -> Palette.chargeColor
}

private fun actionIcon(action: ContextualAction): ImageVector =
    if (action.kind == ContextualActionKind.RECOVERY &&
        action.route == NoopNotificationRoute.WORKOUTS
    ) {
        Icons.AutoMirrored.Filled.DirectionsRun
    } else {
        when (action.kind) {
            ContextualActionKind.HYDRATION -> Icons.Filled.WaterDrop
            ContextualActionKind.BREATHE -> Icons.Filled.Air
            ContextualActionKind.JOURNAL -> Icons.Filled.Edit
            ContextualActionKind.WIND_DOWN -> Icons.Filled.Bedtime
            ContextualActionKind.RECOVERY -> Icons.Filled.Bed
        }
    }

private fun primaryIcon(action: ContextualAction): ImageVector =
    if (action.kind == ContextualActionKind.RECOVERY &&
        action.route == NoopNotificationRoute.WORKOUTS
    ) {
        Icons.AutoMirrored.Filled.DirectionsRun
    } else {
        when (action.kind) {
            ContextualActionKind.HYDRATION -> Icons.Filled.Add
            ContextualActionKind.BREATHE -> Icons.Filled.PlayArrow
            ContextualActionKind.JOURNAL -> Icons.Filled.Edit
            ContextualActionKind.WIND_DOWN,
            ContextualActionKind.RECOVERY,
            -> Icons.Filled.Bed
        }
    }

@Composable
private fun primaryTitle(action: ContextualAction): String = when (action.kind) {
    ContextualActionKind.HYDRATION ->
        stringResource(R.string.context_action_add_water, action.amountMl ?: 250)
    ContextualActionKind.BREATHE -> stringResource(R.string.context_action_start_breathing)
    ContextualActionKind.JOURNAL -> stringResource(R.string.context_action_open_journal)
    ContextualActionKind.WIND_DOWN -> stringResource(R.string.context_action_open_sleep)
    ContextualActionKind.RECOVERY ->
        if (action.route == NoopNotificationRoute.WORKOUTS) {
            stringResource(R.string.nav_workouts)
        } else {
            stringResource(R.string.context_action_open_sleep)
        }
}
