package com.noop.ui

import com.noop.R
import com.noop.brand.CustomerFacingBrand
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

// MARK: - WhatsNewSheet (ported from Strand/Screens/WhatsNewView.swift)
//
// A proper in-app changelog, shown automatically after an update and reachable any time
// from Settings. It also restates, up top, what NOOP is and what to expect, so people who
// never open GitHub still understand the experimental footing and the WHOOP 5/MG status.
//
// macOS parity notes:
//  - macOS rendered a fixed 560×640 panel with a header / scroll / footer split and a
//    hairline divider between each region. On phone the panel is presented full-screen
//    (the integration step wraps this in a Dialog/overlay), so we fill the surface and let
//    the body scroll. The header → divider → scroll → divider → "Got it" footer order is
//    preserved exactly, as is the "WHAT TO EXPECT" card then one card per release.
//  - The xmark.circle.fill close glyph maps to Icons.Filled.Close; the borderedProminent
//    "Got it" maps to a Palette.accent Material Button.

enum class WhatsNewPresentation {
    Welcome,
    History,
}

@Composable
fun WhatsNewSheet(
    onClose: () -> Unit,
    presentation: WhatsNewPresentation = WhatsNewPresentation.History,
    showFirstInstallGlow: Boolean = false,
    onSkip: () -> Unit = onClose,
) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize()) {
                // A scenic Charge-tinted hero behind the title region — the same premium backdrop
                // the Today rings float over, so the changelog opens on-brand.
                Box {
                    ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Charge, starCount = 28)
                    Header(presentation = presentation, onClose = onClose)
                }
                Hairline()

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
                ) {
                    val releases = if (presentation == WhatsNewPresentation.Welcome) {
                        AppChangelog.releases.take(1)
                    } else {
                        AppChangelog.releases
                    }
                    releases.forEachIndexed { index, release ->
                        ReleaseCard(release, isLatest = index == 0)
                        if (presentation == WhatsNewPresentation.History && index == 0) {
                            ExpectationsCard()
                        }
                    }
                }

                Hairline()
                Footer(
                    presentation = presentation,
                    onSkip = onSkip,
                    onClose = onClose,
                )
            }

            if (showFirstInstallGlow && presentation == WhatsNewPresentation.Welcome) {
                FirstInstallEdgeGlow()
            }
        }
    }
}

// MARK: - Header ("What's new" + "NOOP <version>" + close X)

@Composable
private fun Header(
    presentation: WhatsNewPresentation,
    onClose: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Overline("What's new", color = Palette.textTertiary)
            Text(
                if (presentation == WhatsNewPresentation.Welcome) {
                    uiString(R.string.whats_new_welcome_version, AppChangelog.CURRENT_VERSION)
                } else {
                    uiString(
                        R.string.l10n_whats_new_sheet_noop_appchangelog_current_version_05dae27c,
                        AppChangelog.CURRENT_VERSION,
                    )
                },
                style = NoopType.display(26f),
                color = Palette.textPrimary,
            )
            Text(uiString(R.string.l10n_whats_new_sheet_release_notes_cd5af734), style = NoopType.caption, color = Palette.textSecondary)
        }
        if (presentation == WhatsNewPresentation.History) {
            IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = uiString(R.string.l10n_whats_new_sheet_close_bbfa773e),
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

// MARK: - "WHAT TO EXPECT" card (icon + title + body per expectation)

@Composable
private fun ExpectationsCard() {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("What to expect")
            AppChangelog.expectations.forEach { e ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        e.icon,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier
                            .padding(top = 2.dp)
                            .size(22.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(CustomerFacingBrand.text(e.title), style = NoopType.headline, color = Palette.textPrimary)
                        Text(CustomerFacingBrand.text(e.body), style = NoopType.subhead, color = Palette.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Release card (v-badge + title + date, then bulleted items)

@Composable
private fun ReleaseCard(release: AppChangelog.Release, isLatest: Boolean = false) {
    NoopCard(padding = 20.dp, tint = if (isLatest) Palette.accent else null) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceBadge("v${release.version}")
                androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                Text(release.date, style = NoopType.caption, color = Palette.textTertiary)
            }
            Text(
                CustomerFacingBrand.text(release.title),
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.fillMaxWidth(),
            )
            release.items.forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Box(
                        modifier = Modifier
                            .padding(top = 7.dp)
                            .size(5.dp)
                            .clip(CircleShape)
                            .background(Palette.accent),
                    )
                    Text(
                        releaseNote(item),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

private fun releaseNote(source: String): AnnotatedString {
    val rendered = CustomerFacingBrand.text(source)
    return buildAnnotatedString {
        var cursor = 0
        var emphasized = false
        while (cursor < rendered.length) {
            val marker = rendered.indexOf("**", startIndex = cursor)
            val end = if (marker >= 0) marker else rendered.length
            val segment = rendered.substring(cursor, end)
            if (emphasized) {
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = Palette.textPrimary)) {
                    append(segment)
                }
            } else {
                append(segment)
            }
            if (marker < 0) break
            emphasized = !emphasized
            cursor = marker + 2
        }
    }
}

// MARK: - Footer

@Composable
private fun Footer(
    presentation: WhatsNewPresentation,
    onSkip: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (presentation == WhatsNewPresentation.Welcome) {
            TextButton(onClick = onSkip, modifier = Modifier.height(48.dp)) {
                Text(
                    uiString(R.string.l10n_insights_screen_skip_3da47453),
                    color = Palette.textSecondary,
                )
            }
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            Button(
                onClick = onClose,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Text(stringResource(android.R.string.ok), style = NoopType.captionNumber)
            }
        } else {
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            Button(
                onClick = onClose,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Text(uiString(R.string.l10n_whats_new_sheet_got_it_5b8027fa), style = NoopType.captionNumber)
            }
        }
    }
}

@Composable
private fun FirstInstallEdgeGlow() {
    val still = rememberPoseStill()
    val alpha = if (still) {
        0.72f
    } else {
        val transition = rememberInfiniteTransition(
            label = uiString(R.string.l10n_whats_new_sheet_release_notes_cd5af734),
        )
        val animated by transition.animateFloat(
            initialValue = 0.48f,
            targetValue = 0.95f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1_800),
                repeatMode = RepeatMode.Reverse,
            ),
            label = uiString(R.string.l10n_whats_new_sheet_release_notes_cd5af734),
        )
        animated
    }

    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(4.dp),
    ) {
        val innerWidth = 2.dp.toPx()
        val outerWidth = 7.dp.toPx()
        val inset = outerWidth / 2f
        val bounds = Size(
            width = (size.width - outerWidth).coerceAtLeast(0f),
            height = (size.height - outerWidth).coerceAtLeast(0f),
        )
        val radius = CornerRadius(22.dp.toPx(), 22.dp.toPx())
        val edgeBrush = Brush.linearGradient(
            colors = listOf(
                Palette.chargeBright,
                Palette.effortBright,
                Palette.restBright,
                Palette.chargeBright,
            ),
            start = Offset.Zero,
            end = Offset(size.width, size.height),
        )
        drawRoundRect(
            color = Palette.chargeGlow.copy(alpha = alpha * 0.18f),
            topLeft = Offset(inset, inset),
            size = bounds,
            cornerRadius = radius,
            style = Stroke(width = outerWidth),
        )
        drawRoundRect(
            brush = edgeBrush,
            topLeft = Offset(inset, inset),
            size = bounds,
            cornerRadius = radius,
            alpha = alpha,
            style = Stroke(width = innerWidth),
        )
    }
}

// MARK: - Hairline divider (mirrors the macOS Divider().overlay(hairline))

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}
