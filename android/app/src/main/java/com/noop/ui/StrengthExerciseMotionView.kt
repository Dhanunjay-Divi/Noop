package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.StrengthExerciseGuidance
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthMuscleStatus

private const val STRENGTH_MEDIA_COMPACT = "strength.exerciseMediaCompact.v2"

enum class StrengthExerciseMediaPresentation {
    WORKOUT,
    DETAIL,
}

/** Native, cached exercise media shared by previews and the guided workout player. */
@Composable
fun StrengthExerciseMotionView(
    exercise: StrengthExerciseRow,
    modifier: Modifier = Modifier,
    showsTechniqueButton: Boolean = true,
    presentation: StrengthExerciseMediaPresentation = StrengthExerciseMediaPresentation.WORKOUT,
) {
    val context = LocalContext.current
    val guide = remember(exercise) { StrengthExerciseGuidance.guide(exercise) }
    val reduceMotion = rememberPoseStill()
    val preferences = remember(context.applicationContext) { NoopPrefs.of(context) }
    var minimized by remember {
        mutableStateOf(preferences.getBoolean(STRENGTH_MEDIA_COMPACT, true))
    }
    val mediaAspectRatio = when (presentation) {
        StrengthExerciseMediaPresentation.WORKOUT -> if (minimized) 2.15f else 1f
        StrengthExerciseMediaPresentation.DETAIL -> 1f
    }
    val mediaModifier = modifier.aspectRatio(mediaAspectRatio)

    if (guide.animationVariant != null) {
        StrengthNativeExerciseMedia(
            exercise = exercise,
            reduceMotion = reduceMotion,
            minimized = minimized,
            showsTechniqueButton = showsTechniqueButton,
            showsSizeButton = presentation == StrengthExerciseMediaPresentation.WORKOUT,
            onToggleSize = {
                minimized = !minimized
                preferences.edit().putBoolean(STRENGTH_MEDIA_COMPACT, minimized).apply()
            },
            modifier = mediaModifier,
            fallback = {
                StrengthNativeFallbackMotionView(mediaModifier)
            },
        )
    } else {
        StrengthNativeFallbackMotionView(mediaModifier)
    }
}

@Composable
private fun StrengthNativeFallbackMotionView(modifier: Modifier) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier = modifier
            .background(Palette.surfaceInset, shape)
            .border(1.dp, Palette.hairline, shape),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Filled.FitnessCenter,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(30.dp),
            )
            Text(
                stringResource(R.string.strength_exercise_guide),
                style = NoopType.caption,
                color = Palette.textSecondary,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

enum class StrengthBodyMapMode {
    LOAD,
    RECOVERY,
}

@Composable
fun StrengthBodyMapView(
    statuses: List<StrengthMuscleStatus>,
    mode: StrengthBodyMapMode,
    selectedMuscles: Set<String>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    StrengthNativeBodyMap(
        statuses = statuses,
        mode = mode,
        selectedMuscles = selectedMuscles,
        onSelect = onSelect,
        modifier = modifier
            .fillMaxWidth()
            .height(306.dp),
    )
}
