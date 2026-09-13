package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.analytics.RecoveryScorer
import java.util.Locale

internal enum class RecoveryBandLevel {
    LOW,
    STEADY,
    STRONG,
}

/**
 * User-facing Recovery vocabulary and color derived from the scoring engine's pinned 34/67 bands.
 * Summary surfaces use these three states so Today, Calendar, and Week in review cannot drift.
 */
internal object RecoveryBandPresentation {
    fun level(score: Double): RecoveryBandLevel = when (RecoveryScorer.band(score)) {
        "red" -> RecoveryBandLevel.LOW
        "yellow" -> RecoveryBandLevel.STEADY
        else -> RecoveryBandLevel.STRONG
    }

    @StringRes
    fun labelRes(score: Double): Int = when (level(score)) {
        RecoveryBandLevel.LOW -> R.string.appwide_calendar_legend_low
        RecoveryBandLevel.STEADY -> R.string.today_trend_direction_steady
        RecoveryBandLevel.STRONG -> R.string.appwide_calendar_legend_strong
    }

    fun color(score: Double): Color = when (level(score)) {
        RecoveryBandLevel.LOW -> Palette.statusCritical
        RecoveryBandLevel.STEADY -> Palette.statusWarning
        RecoveryBandLevel.STRONG -> Palette.statusPositive
    }
}

@Composable
internal fun recoveryBandLabel(score: Double): String =
    stringResource(RecoveryBandPresentation.labelRes(score)).replaceFirstChar {
        if (it.isLowerCase()) it.titlecase(Locale.getDefault()) else it.toString()
    }
