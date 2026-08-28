package com.noop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import com.noop.R
import kotlin.math.max

/**
 * Android twin of StrandDesign's ObsidianFlowBackground.
 *
 * One static satin-obsidian asset replaces the old coloured sky across primary screens. The base
 * surface is always painted first, so a missing/failed image still leaves a usable monochrome page.
 */
@Composable
fun ObsidianFlowBackground(
    compact: Boolean = false,
    intensity: Float = 1f,
    modifier: Modifier = Modifier,
) {
    val strength = intensity.coerceIn(0f, 1f)
    val imageAlpha = when {
        Palette.isLight -> 0.10f
        Palette.isBlack -> 0.36f
        else -> 0.66f
    } * strength

    Box(
        modifier = modifier
            .background(Palette.surfaceBase)
            .clearAndSetSemantics {},
    ) {
        Image(
            painter = painterResource(R.drawable.obsidian_flow),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            alignment = Alignment.TopCenter,
            alpha = imageAlpha,
            modifier = Modifier.fillMaxSize(),
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    if (Palette.isLight) {
                        Brush.verticalGradient(
                            colorStops = arrayOf(
                                0f to Color.White.copy(alpha = 0.30f),
                                0.32f to Color.Transparent,
                                1f to Palette.surfaceBase.copy(alpha = if (compact) 0.96f else 0.68f),
                            ),
                        )
                    } else {
                        Brush.verticalGradient(
                            colorStops = if (compact) {
                                arrayOf(
                                    0f to Color.Black.copy(alpha = 0.04f),
                                    0.30f to Color.Transparent,
                                    1f to Palette.surfaceBase.copy(alpha = 0.94f),
                                )
                            } else {
                                arrayOf(
                                    0f to Color.Black.copy(alpha = 0.04f),
                                    0.30f to Color.Transparent,
                                    0.76f to Palette.surfaceBase.copy(alpha = 0.52f),
                                    1f to Palette.surfaceBase,
                                )
                            },
                        )
                    },
                ),
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawWithCache {
                    val topLight = Brush.radialGradient(
                        colors = listOf(
                            Color.White.copy(
                                alpha = if (Palette.isLight) {
                                    0.12f * strength
                                } else if (Palette.isBlack) {
                                    0.07f * strength
                                } else {
                                    0.15f * strength
                                },
                            ),
                            Color.Transparent,
                        ),
                        center = Offset(size.width * 0.72f, size.height * 0.02f),
                        radius = max(size.width, size.height) * 0.72f,
                    )
                    onDrawBehind { drawRect(topLight) }
                },
        )
    }
}
