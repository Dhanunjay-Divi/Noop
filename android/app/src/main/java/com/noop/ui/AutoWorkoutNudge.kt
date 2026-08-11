package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.CoarseWorkoutClass
import com.noop.data.DailyMetric
import com.noop.notif.AutoWorkoutCandidateNotifier
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Today surface for Off / Ask / confidence-gated Auto-save automatic activity modes.
 *
 * Android twin of iOS `AutoWorkoutCard` (Strand/Screens/AutoWorkoutCard.swift), wired to the byte-parity
 * [AutoWorkoutDetector]. [AutoWorkoutMode.OFF] runs nothing; Ask presents an approval card; Auto-save
 * writes only a stronger 15+ minute candidate as Detected and presents a Keep/undo review. It scans the last
 * couple of days of strap HR through the pure detector, excludes any window that OVERLAPS a saved workout
 * (any source) or was previously dismissed, and surfaces ONE card — the most recent candidate:
 *
 *   "Looks like a workout around <start>–<end> (avg HR <avg>, <dur> min). Save it?"
 *
 * SAVE or Auto-save → builds a `<strap>-noop` Detected row (avg HR filled). DISMISS (× or "Not a
 * workout") records the window in the durable, SEPARATE [AutoWorkoutPrefs] dismissed set so it never
 * re-prompts. Every saved row remains editable/relabelable/dismissible in Workouts.
 *
 * Design-Reset compliant: a flat accent-tinted [NoopCard], NoopMetrics tokens, no gold — matching the
 * other Today cards (matches the iOS source exactly).
 */

/** Generic sport label for a saved auto-detected bout — the user can re-label via Workouts → Edit. */
private const val AUTO_DETECT_SPORT = "Workout"

internal object AutoWorkoutAutomationPolicy {
    const val minimumAutoSaveMinutes = 15

    fun shouldAutoSave(candidate: AutoWorkoutDetector.DetectedWorkout): Boolean {
        if (candidate.startSec <= 0L || candidate.endSec <= candidate.startSec ||
            candidate.durationMin < minimumAutoSaveMinutes || candidate.avgBpm !in 30..220 ||
            candidate.peakBpm !in candidate.avgBpm..250
        ) return false
        if (candidate.suggestedClass != null) {
            val confidence = candidate.suggestionConfidence ?: return false
            if (!confidence.isFinite() ||
                confidence < com.noop.analytics.WorkoutTypeClassifier.minAdvisoryConfidence
            ) return false
        }
        return true
    }
}

internal fun buildDetectedAutoWorkoutRow(
    computedDeviceId: String,
    candidate: AutoWorkoutDetector.DetectedWorkout,
) = WorkoutEditing.buildDetectedSuggestionRow(
    deviceId = computedDeviceId,
    startSeconds = candidate.startSec,
    endSeconds = candidate.endSec,
    sport = acceptedAutoDetectSport(candidate.suggestedClass),
    avgHr = candidate.avgBpm,
    source = computedDeviceId,
)

private fun className(value: CoarseWorkoutClass): String = when (value) {
    CoarseWorkoutClass.WALK -> "Walk"
    CoarseWorkoutClass.RUN -> "Run"
    CoarseWorkoutClass.STRENGTH -> "Strength"
    CoarseWorkoutClass.CYCLE -> "Cycling"
    CoarseWorkoutClass.SKI -> "Skiing"
    CoarseWorkoutClass.OTHER -> "Workout"
}

internal fun acceptedAutoDetectSport(value: CoarseWorkoutClass?): String = when (value) {
    CoarseWorkoutClass.WALK -> "Walking"
    CoarseWorkoutClass.RUN -> "Running"
    CoarseWorkoutClass.STRENGTH -> "Strength Training"
    CoarseWorkoutClass.CYCLE -> "Cycling"
    CoarseWorkoutClass.SKI -> "Skiing"
    CoarseWorkoutClass.OTHER, null -> AUTO_DETECT_SPORT
}

private fun suggestionTitle(w: AutoWorkoutDetector.DetectedWorkout): String =
    w.suggestedClass?.let { "Possible ${className(it)}" } ?: "Looks like a workout"

private val autoNudgeTimeFmt: DateTimeFormatter =
    // HH:mm in the user's locale/timezone — mirrors the iOS card's short-time DateFormatter.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private val autoNudgeDateFmt: DateTimeFormatter =
    // Localized MEDIUM date ("23 Jun 2026") for a bout older than yesterday. Mirrors the iOS card.
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private fun hhmm(epochSec: Long): String = autoNudgeTimeFmt.format(Instant.ofEpochSecond(epochSec))

/** A relative LOCAL-day prefix for the prompt (#719): "" when the bout started today, "yesterday " when
 *  it was yesterday, else "on <date> ". The card showed HH:mm only, so a late-night bout could read as
 *  today; this anchors it to the local day instead of UTC. Mirrors iOS `AutoWorkoutCard.dayLabel`. */
private fun dayLabel(epochSec: Long): String {
    val zone = ZoneId.systemDefault()
    val day = Instant.ofEpochSecond(epochSec).atZone(zone).toLocalDate()
    val today = LocalDate.now(zone)
    return when (day) {
        today -> ""
        today.minusDays(1) -> "yesterday "
        else -> "on ${autoNudgeDateFmt.format(Instant.ofEpochSecond(epochSec))} "
    }
}

/** "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?" Mirrors iOS. */
private fun promptText(w: AutoWorkoutDetector.DetectedWorkout): String =
    "Looks like a workout ${dayLabel(w.startSec)}around ${hhmm(w.startSec)} - ${hhmm(w.endSec)} " +
        "(avg HR ${w.avgBpm}, ${w.durationMin} min). Save it?"

@Composable
fun AutoWorkoutNudgeCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
) {
    val context = LocalContext.current
    // Settings and Today are separate destinations, so reading on composition picks up the latest mode.
    val mode = remember { NoopPrefs.autoWorkoutMode(context) }

    // The single surfaced candidate (null = nothing to suggest). Re-scanned whenever the day data grows.
    var candidate by remember { mutableStateOf<AutoWorkoutDetector.DetectedWorkout?>(null) }
    var autoSavedReview by remember { mutableStateOf<AutoWorkoutPrefs.Review?>(null) }
    // Hide immediately on Save/X without waiting for the next reload (mirrors iOS `handledThisSession`).
    var handledThisSession by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var saveFailed by remember { mutableStateOf(false) }
    val activeDeviceId by viewModel.selectedDeviceId.collectAsStateWithLifecycle()

    // Re-scan after Today appears / when the data refreshes (days = the recompute trigger; the Android
    // analog of the iOS refreshSeq). All reads + detection run off the main thread. Mirrors `reload()`.
    LaunchedEffect(days, mode, activeDeviceId) {
        val storedReview = AutoWorkoutPrefs.pendingReview(context)
        if (storedReview != null) {
            val exists = runCatching {
                viewModel.repo.detectedWorkoutsUnion(
                    activeDeviceId,
                    storedReview.startSec - 1L,
                    storedReview.endSec + 1L,
                    limit = 200,
                ).any {
                    it.startTs == storedReview.startSec && it.sport == storedReview.sport &&
                        it.source == storedReview.source && it.deviceId == storedReview.deviceId
                }
            }.getOrDefault(false)
            if (exists) {
                autoSavedReview = storedReview
                candidate = null
                handledThisSession = false
                return@LaunchedEffect
            }
            AutoWorkoutPrefs.clearReview(context, storedReview.startSec)
        }
        autoSavedReview = null
        if (mode == AutoWorkoutMode.OFF) {
            candidate = null
            return@LaunchedEffect
        }
        val traceSink: ((String) -> Unit)? =
            if (com.noop.testcentre.TestCentre.from(context)
                    .active(com.noop.testcentre.TestDomain.WORKOUTS)
            ) {
                { line -> viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.WORKOUTS) }
            } else null
        val next = runCatching {
            AutoWorkoutCandidateScan.latest(
                repository = viewModel.repo,
                activeDeviceId = activeDeviceId,
                days = days,
                dismissedTokens = AutoWorkoutPrefs.dismissed(context),
                traceSink = traceSink,
            )
        }.getOrNull()
        if (mode == AutoWorkoutMode.AUTO_SAVE && next != null &&
            AutoWorkoutAutomationPolicy.shouldAutoSave(next)
        ) {
            val computedId = viewModel.repo.computedDeviceId(activeDeviceId)
            val row = buildDetectedAutoWorkoutRow(computedId, next)
            val saved = row != null && runCatching {
                viewModel.repo.saveManualWorkout(row)
            }.isSuccess
            if (saved && row != null) {
                val review = AutoWorkoutPrefs.Review(
                    startSec = next.startSec, endSec = next.endSec,
                    sport = row.sport, deviceId = row.deviceId, source = row.source,
                    avgBpm = next.avgBpm, peakBpm = next.peakBpm,
                )
                AutoWorkoutPrefs.recordReview(context, review)
                AutoWorkoutCandidateNotifier.cancelHandled(context)
                AutoWorkoutCandidateNotifier.postAutoSavedIfAuthorized(
                    context, next.startSec, next.endSec,
                )
                viewModel.loadWorkouts()
                autoSavedReview = review
                candidate = null
                handledThisSession = false
                return@LaunchedEffect
            }
            // Never claim a failed write was saved. The candidate stays visible as an explicit retry.
        }
        // A fresh scan that surfaces a DIFFERENT window resets the session guard so a new bout can show.
        if (next != candidate) handledThisSession = false
        candidate = next
    }

    if (handledThisSession) return

    val review = autoSavedReview
    if (review != null) {
        AutoSavedWorkoutReviewCard(
            review = review,
            saving = saving,
            onKeep = {
                AutoWorkoutPrefs.clearReview(context, review.startSec)
                AutoWorkoutCandidateNotifier.cancelHandled(context)
                autoSavedReview = null
                handledThisSession = true
            },
            onUndo = {
                saving = true
                AutoWorkoutPrefs.dismiss(context, review.row())
                viewModel.dismissDetected(review.row())
                AutoWorkoutPrefs.clearReview(context, review.startSec)
                AutoWorkoutCandidateNotifier.cancelHandled(context)
                autoSavedReview = null
                handledThisSession = true
                saving = false
            },
        )
        return
    }

    val w = candidate ?: return

    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.AutoMirrored.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(suggestionTitle(w), style = NoopType.headline, color = Palette.textPrimary)
                }
                // Standard × dismiss → record the window durably so it never re-prompts.
                IconButton(
                    enabled = !saving,
                    onClick = {
                        AutoWorkoutPrefs.dismiss(context, w)
                        AutoWorkoutCandidateNotifier.cancelHandled(context)
                        handledThisSession = true
                        candidate = null
                    },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = uiString(R.string.l10n_auto_workout_nudge_dismiss_this_workout_suggestion_52ace8f3) },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Text(
                promptText(w),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            val hint = w.suggestedClass
            val hintConfidence = w.suggestionConfidence
            if (hint != null && hintConfidence != null) {
                Text(
                    "Experimental type hint · ${className(hint)} · ${(hintConfidence * 100).roundToInt()}% signal confidence",
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    onClick = {
                        // Even an explicitly accepted detector suggestion remains honestly classified as
                        // Detected/NOOP (not Manual) and is editable/dismissible in Workouts.
                        val row = buildDetectedAutoWorkoutRow(
                            viewModel.repo.computedDeviceId(activeDeviceId), w,
                        )
                        // #214 ROOT CAUSE: save on the ViewModel's scope, NOT the card's. Setting
                        // handledThisSession=true removes this card from composition immediately (see the
                        // `return` gate above), which CANCELS its rememberCoroutineScope — so the old
                        // `scope.launch { saveManualWorkout }` was killed before the suspend DB write
                        // committed. The workout never saved and the card kept re-prompting. viewModel
                        // .saveManualWorkout runs on viewModelScope (survives) + reloads the list itself.
                        if (row == null) {
                            saveFailed = true
                        } else {
                            saving = true
                            saveFailed = false
                            viewModel.saveManualWorkout(row) { saved ->
                                saving = false
                                when (AutoWorkoutSuggestionPolicy.afterSave(saved)) {
                                    AutoWorkoutSuggestionPolicy.SaveDisposition.CLEAR_CANDIDATE -> {
                                        AutoWorkoutCandidateNotifier.cancelHandled(context)
                                        handledThisSession = true
                                        candidate = null
                                    }
                                    AutoWorkoutSuggestionPolicy.SaveDisposition.KEEP_FOR_RETRY -> {
                                        // Keep the card/candidate visible so failure cannot look like success.
                                        saveFailed = true
                                    }
                                }
                            }
                        }
                    },
                    enabled = !saving,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) {
                    Text(w.suggestedClass?.let { "Save as ${className(it)}" }
                        ?: uiString(R.string.l10n_auto_workout_nudge_save_it_01d23661))
                }

                OutlinedButton(
                    onClick = {
                        AutoWorkoutPrefs.dismiss(context, w)
                        AutoWorkoutCandidateNotifier.cancelHandled(context)
                        handledThisSession = true
                        candidate = null
                    },
                    enabled = !saving,
                ) { Text(uiString(R.string.l10n_auto_workout_nudge_not_a_workout_15c5f784), color = Palette.textSecondary) }
            }
            if (saveFailed) {
                Text(
                    "Could not save locally. Your suggestion is still here - try again.",
                    style = NoopType.footnote,
                    color = Palette.statusCritical,
                )
            }
        }
    }
}

@Composable
private fun AutoSavedWorkoutReviewCard(
    review: AutoWorkoutPrefs.Review,
    saving: Boolean,
    onKeep: () -> Unit,
    onUndo: () -> Unit,
) {
    val durationMin = maxOf(1L, (review.endSec - review.startSec) / 60L)
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Filled.DirectionsRun,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text("Workout saved automatically", style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                "NOOP detected ${review.sport} from ${hhmm(review.startSec)} - ${hhmm(review.endSec)} " +
                    "(avg HR ${review.avgBpm}, $durationMin min).",
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            Text(
                "Keep it here, mark it as not a workout, or edit its time and activity type anytime in Workouts. Detected workouts are labelled NOOP, not Manual.",
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    onClick = onKeep,
                    enabled = !saving,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) { Text("Keep") }
                OutlinedButton(onClick = onUndo, enabled = !saving) {
                    Text("Not a workout", color = Palette.textSecondary)
                }
            }
        }
    }
}
