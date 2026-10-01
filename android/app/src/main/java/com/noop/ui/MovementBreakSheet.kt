package com.noop.ui

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import java.util.Locale
import kotlinx.coroutines.delay

/**
 * A short notification-started movement reset. It records no workout, standing
 * time, or exercise claim; the user can dismiss it at any point.
 */
@Composable
internal fun MovementBreakSheet(
    startedAtElapsedRealtimeMs: Long,
    onDismiss: () -> Unit,
) {
    var remainingSeconds by rememberSaveable(startedAtElapsedRealtimeMs) {
        mutableIntStateOf(
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtElapsedRealtimeMs,
                SystemClock.elapsedRealtime(),
            ),
        )
    }
    var completionHapticPlayed by rememberSaveable(startedAtElapsedRealtimeMs) {
        mutableStateOf(false)
    }
    val completed = remainingSeconds == 0
    val hostView = LocalView.current
    val remainingDescription = stringResource(
        R.string.appwide_wellness_movement_remaining_accessibility,
        remainingSeconds,
    )

    LaunchedEffect(startedAtElapsedRealtimeMs) {
        while (remainingSeconds > 0) {
            delay(250L)
            remainingSeconds = ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtElapsedRealtimeMs,
                SystemClock.elapsedRealtime(),
            )
        }
        if (!completionHapticPlayed) {
            completionHapticPlayed = true
            hostView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            imageVector =
                if (completed) Icons.Filled.CheckCircle
                else Icons.AutoMirrored.Filled.DirectionsWalk,
            contentDescription = null,
            tint =
                if (completed) Palette.statusPositive
                else Palette.accent,
            modifier = Modifier.size(40.dp),
        )
        Text(
            text = stringResource(
                if (completed) R.string.appwide_wellness_movement_complete
                else R.string.appwide_wellness_movement_title,
            ),
            style = NoopType.title2,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            text = stringResource(R.string.appwide_wellness_movement_body),
            style = NoopType.body,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(4.dp))
        Box(
            modifier = Modifier
                .size(164.dp)
                .semantics {
                    contentDescription = remainingDescription
                },
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(
                progress = {
                    ActionableWellnessPolicy.movementProgress(
                        remainingSeconds,
                    )
                },
                modifier = Modifier.size(164.dp),
                color = Palette.accent,
                trackColor = Palette.hairline,
                strokeWidth = 8.dp,
            )
            Text(
                text = String.format(
                    Locale.US,
                    "%d:%02d",
                    remainingSeconds / 60,
                    remainingSeconds % 60,
                ),
                style = NoopType.number(38f),
                color = Palette.textPrimary,
            )
        }
        Spacer(Modifier.height(4.dp))
        NoopButton(
            text = stringResource(R.string.appwide_action_done),
            fullWidth = true,
            onClick = onDismiss,
        )
    }
}
