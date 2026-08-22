package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthExerciseHistoryPoint
import com.noop.data.StrengthMuscleFocus
import com.noop.data.StrengthProgressCalculator
import com.noop.data.StrengthWeeklyProgress
import com.noop.data.StrengthRoutineExerciseRow
import com.noop.data.StrengthRoutineRow
import com.noop.data.StrengthRoutineSnapshot
import com.noop.data.StrengthSessionRow
import com.noop.data.StrengthSessionSnapshot
import com.noop.data.StrengthSetRow
import com.noop.data.StrengthSummary
import com.noop.data.StrengthTrainingContract
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class StrengthBlockDraft(
    val key: String,
    val exercise: StrengthExerciseRow,
    val position: Int,
    val restSeconds: Int,
    val sets: List<StrengthSetRow>,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StrengthTrainerSheet(vm: AppViewModel, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val massUnit = UnitPrefs.mass(context)
    val saveError = stringResource(R.string.strength_save_error)

    var exercises by remember { mutableStateOf<List<StrengthExerciseRow>>(emptyList()) }
    var routines by remember { mutableStateOf<List<StrengthRoutineSnapshot>>(emptyList()) }
    var sessions by remember { mutableStateOf<List<StrengthSessionSnapshot>>(emptyList()) }
    var summary by remember { mutableStateOf(StrengthSummary(0, 0, 0, 0.0, 0)) }
    var loading by remember { mutableStateOf(true) }
    var reloadToken by remember { mutableIntStateOf(0) }
    var editor by remember { mutableStateOf<StrengthSessionSnapshot?>(null) }
    var exerciseDetail by remember {
        mutableStateOf<Pair<StrengthExerciseRow, List<StrengthExerciseHistoryPoint>>?>(null)
    }
    var starting by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<StrengthSessionSnapshot?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { target ->
            editor == null || target != SheetValue.Hidden
        },
    )

    LaunchedEffect(reloadToken) {
        loading = true
        runCatching {
            val loadedExercises = vm.repo.strengthExercises()
            val loadedRoutines = vm.repo.strengthRoutines()
            val loadedSessions = vm.repo.strengthSessions()
            val loadedSummary = vm.repo.strengthSummary(0, Long.MAX_VALUE)
            arrayOf(loadedExercises, loadedRoutines, loadedSessions, loadedSummary)
        }.onSuccess { loaded ->
            @Suppress("UNCHECKED_CAST")
            exercises = loaded[0] as List<StrengthExerciseRow>
            @Suppress("UNCHECKED_CAST")
            routines = loaded[1] as List<StrengthRoutineSnapshot>
            @Suppress("UNCHECKED_CAST")
            sessions = loaded[2] as List<StrengthSessionSnapshot>
            summary = loaded[3] as StrengthSummary
            errorMessage = null
        }.onFailure { errorMessage = it.strengthMessage(saveError) }
        loading = false
    }

    fun startSession(routine: StrengthRoutineSnapshot?) {
        if (starting) return
        starting = true
        scope.launch {
            val now = Instant.now().epochSecond
            val sessionId = UUID.randomUUID().toString().lowercase()
            val session = StrengthSessionRow(
                id = sessionId,
                routineId = routine?.routine?.id,
                name = routine?.routine?.name,
                startedAt = now,
                createdAt = now,
                updatedAt = now,
            )
            val sets = routine?.exercises.orEmpty().flatMap { prescription ->
                (0 until prescription.targetSets).map { setPosition ->
                    StrengthSetRow(
                        id = UUID.randomUUID().toString().lowercase(),
                        sessionId = sessionId,
                        exerciseId = prescription.exerciseId,
                        exercisePosition = prescription.position,
                        setPosition = setPosition,
                        restSeconds = prescription.restSeconds,
                        createdAt = now,
                        updatedAt = now,
                    )
                }
            }
            runCatching { vm.repo.saveStrengthSession(session, sets) }
                .onSuccess {
                    editor = it
                    reloadToken += 1
                }
                .onFailure { errorMessage = it.strengthMessage(saveError) }
            starting = false
        }
    }

    ModalBottomSheet(
        onDismissRequest = { if (editor == null) onDismiss() },
        sheetState = sheetState,
        containerColor = Palette.surfaceOverlay,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.96f)
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
        ) {
            if (editor == null && exerciseDetail == null) {
                StrengthDashboard(
                    exercises = exercises,
                    routines = routines,
                    sessions = sessions,
                    summary = summary,
                    massUnit = massUnit,
                    loading = loading,
                    starting = starting,
                    error = errorMessage,
                    onRetry = { reloadToken += 1 },
                    onStart = ::startSession,
                    onEdit = { editor = it },
                    onExercise = { exercise, history -> exerciseDetail = exercise to history },
                    onDelete = { deleteCandidate = it },
                    onClose = onDismiss,
                )
            } else if (exerciseDetail != null) {
                StrengthExerciseProgressPanel(
                    exercise = exerciseDetail!!.first,
                    history = exerciseDetail!!.second,
                    massUnit = massUnit,
                    onClose = { exerciseDetail = null },
                )
            } else {
                StrengthSessionEditor(
                    vm = vm,
                    initial = editor!!,
                    exercises = exercises,
                    routines = routines,
                    massUnit = massUnit,
                    onClose = {
                        editor = null
                        reloadToken += 1
                    },
                    onSaved = { saved ->
                        editor = saved
                        reloadToken += 1
                    },
                )
            }
        }
    }

    deleteCandidate?.let { candidate ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            containerColor = Palette.surfaceOverlay,
            title = { Text(stringResource(R.string.strength_delete_title), style = NoopType.title2) },
            text = {
                Text(
                    stringResource(R.string.strength_delete_message),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    deleteCandidate = null
                    scope.launch {
                        runCatching { vm.repo.deleteStrengthSession(candidate.session.id) }
                            .onSuccess { reloadToken += 1 }
                            .onFailure { errorMessage = it.strengthMessage(saveError) }
                    }
                }) { Text(stringResource(R.string.strength_delete), color = Palette.statusCritical) }
            },
            dismissButton = {
                TextButton(onClick = { deleteCandidate = null }) {
                    Text(stringResource(R.string.strength_cancel), color = Palette.textSecondary)
                }
            },
        )
    }
}

@Composable
private fun StrengthDashboard(
    exercises: List<StrengthExerciseRow>,
    routines: List<StrengthRoutineSnapshot>,
    sessions: List<StrengthSessionSnapshot>,
    summary: StrengthSummary,
    massUnit: MassUnit,
    loading: Boolean,
    starting: Boolean,
    error: String?,
    onRetry: () -> Unit,
    onStart: (StrengthRoutineSnapshot?) -> Unit,
    onEdit: (StrengthSessionSnapshot) -> Unit,
    onExercise: (StrengthExerciseRow, List<StrengthExerciseHistoryPoint>) -> Unit,
    onDelete: (StrengthSessionSnapshot) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val active = sessions.firstOrNull { it.session.endedAt == null }
    val prefs = remember(context) { NoopPrefs.of(context) }
    var weeklySessionGoal by rememberSaveable {
        mutableIntStateOf(prefs.getInt("strength.goal.weeklySessions", 3).coerceIn(1, 14))
    }
    var weeklySetGoal by rememberSaveable {
        mutableIntStateOf(prefs.getInt("strength.goal.weeklySets", 12).coerceIn(1, 100))
    }
    val weekRange = remember { currentStrengthWeekRange() }
    val weekly = remember(sessions, weekRange) {
        StrengthProgressCalculator.weeklyProgress(sessions, weekRange.first, weekRange.second)
    }
    val muscleFocus = remember(exercises, sessions, weekRange) {
        StrengthProgressCalculator.muscleFocus(
            exercises,
            sessions,
            weekRange.first,
            weekRange.second,
        )
    }
    val exerciseRows = remember(exercises, sessions) {
        exercises.mapNotNull { exercise ->
            val history = StrengthProgressCalculator.exerciseHistory(exercise.id, sessions)
            if (history.isEmpty()) null else exercise to history
        }.sortedWith(
            compareByDescending<Pair<StrengthExerciseRow, List<StrengthExerciseHistoryPoint>>> {
                it.second.firstOrNull()?.startedAt ?: 0L
            }.thenBy { it.first.name },
        )
    }
    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.FitnessCenter,
                contentDescription = null,
                tint = Palette.effortColor,
                modifier = Modifier.size(26.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.strength_title), style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.strength_subtitle),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            IconButton(onClick = onClose) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.strength_close_trainer),
                )
            }
        }
        HorizontalDivider(color = Palette.hairline)
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            when {
                loading && exercises.isEmpty() -> ScreenStateCard(
                    kind = ScreenStateKind.Loading,
                    title = stringResource(R.string.strength_loading_title),
                    body = stringResource(R.string.strength_loading_body),
                )
                error != null && exercises.isEmpty() -> ScreenStateCard(
                    kind = ScreenStateKind.Error,
                    title = stringResource(R.string.strength_unavailable_title),
                    body = stringResource(R.string.strength_unavailable_body),
                    actionLabel = stringResource(R.string.strength_try_again),
                    onAction = onRetry,
                )
                else -> {
                    active?.let {
                        NoopCard(tint = Palette.statusWarning) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.Timer, contentDescription = null, tint = Palette.statusWarning)
                                Spacer(Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        stringResource(R.string.strength_in_progress),
                                        style = NoopType.headline,
                                        color = Palette.textPrimary,
                                    )
                                    Text(
                                        stringResource(
                                            R.string.strength_active_summary,
                                            it.sets.count { set -> set.completedAt != null },
                                            strengthDate(it.session.startedAt),
                                        ),
                                        style = NoopType.footnote,
                                        color = Palette.textSecondary,
                                    )
                                }
                                TextButton(onClick = { onEdit(it) }) {
                                    Text(stringResource(R.string.strength_resume), color = Palette.effortColor)
                                }
                            }
                        }
                    }

                    NoopCard(tint = Palette.effortColor) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(
                                stringResource(R.string.strength_log_real_work),
                                style = NoopType.title2,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(R.string.strength_manual_authority_body),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                            NoopButton(
                                text = if (active == null) {
                                    stringResource(R.string.strength_start_empty)
                                } else {
                                    stringResource(R.string.strength_resume_active)
                                },
                                leadingIcon = if (active == null) Icons.Filled.Add else Icons.Filled.PlayArrow,
                                fullWidth = true,
                                enabled = !starting,
                            ) {
                                if (active == null) onStart(null) else onEdit(active)
                            }
                        }
                    }

                    SectionHeader("This week", overline = "Your goals")
                    StrengthWeeklyGoals(
                        weekly = weekly,
                        sessionGoal = weeklySessionGoal,
                        setGoal = weeklySetGoal,
                        massUnit = massUnit,
                        onSessionGoal = {
                            weeklySessionGoal = it
                            prefs.edit().putInt("strength.goal.weeklySessions", it).apply()
                        },
                        onSetGoal = {
                            weeklySetGoal = it
                            prefs.edit().putInt("strength.goal.weeklySets", it).apply()
                        },
                    )

                    SectionHeader(
                        stringResource(R.string.strength_all_time_work),
                        overline = stringResource(R.string.strength_summary_overline),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        StatTile(
                            stringResource(R.string.strength_sessions),
                            "${summary.sessionCount}",
                            Modifier.weight(1f),
                            stringResource(R.string.strength_finished),
                            Palette.effortColor,
                        )
                        StatTile(
                            stringResource(R.string.strength_completed_sets),
                            "${summary.completedSetCount}",
                            Modifier.weight(1f),
                            stringResource(R.string.strength_manual),
                            Palette.accent,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        StatTile(
                            stringResource(R.string.strength_reps),
                            NumberFormat.getIntegerInstance().format(summary.totalReps),
                            Modifier.weight(1f),
                            stringResource(R.string.strength_recorded),
                            Palette.metricCyan,
                        )
                        StatTile(
                            stringResource(R.string.strength_loaded_volume),
                            if (summary.loadedVolumeSetCount == 0) "—"
                            else UnitFormatter.massFromKilograms(summary.loadedVolumeKg, massUnit),
                            Modifier.weight(1f),
                            if (summary.loadedVolumeSetCount == 0) {
                                stringResource(R.string.strength_needs_load_reps)
                            } else {
                                stringResource(
                                    R.string.strength_loaded_sets,
                                    summary.loadedVolumeSetCount,
                                )
                            },
                            Palette.metricPurple,
                        )
                    }

                    SectionHeader("Muscle map", overline = "This week's set exposure")
                    StrengthMuscleMap(muscleFocus)

                    SectionHeader(
                        stringResource(R.string.strength_routines),
                        overline = stringResource(R.string.strength_repeatable_plans),
                        trailing = routines.size.takeIf { it > 0 }?.toString(),
                    )
                    if (routines.isEmpty()) {
                        ScreenStateCard(
                            kind = ScreenStateKind.Empty,
                            title = stringResource(R.string.strength_no_routines_title),
                            body = stringResource(R.string.strength_no_routines_body),
                        )
                    } else {
                        NoopCard(padding = 0.dp) {
                            Column {
                                routines.forEachIndexed { index, routine ->
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable(enabled = active == null && !starting) { onStart(routine) }
                                            .padding(16.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(Icons.AutoMirrored.Filled.List, contentDescription = null, tint = Palette.effortColor)
                                        Spacer(Modifier.width(12.dp))
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(routine.routine.name, style = NoopType.headline, color = Palette.textPrimary)
                                            Text(
                                                routineDetail(routine, exercises),
                                                style = NoopType.footnote,
                                                color = Palette.textSecondary,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                        Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Palette.effortColor)
                                    }
                                    if (index < routines.lastIndex) HorizontalDivider(color = Palette.hairline)
                                }
                            }
                        }
                    }

                    SectionHeader(
                        stringResource(R.string.appwide_strength_exercise_records),
                        overline = "History and PRs",
                        trailing = exerciseRows.size.takeIf { it > 0 }?.toString(),
                    )
                    if (exerciseRows.isEmpty()) {
                        ScreenStateCard(
                            kind = ScreenStateKind.Empty,
                            title = stringResource(R.string.appwide_strength_no_exercise_records),
                            body = "Finish a workout to build factual load, rep, and set-volume records.",
                        )
                    } else {
                        NoopCard(padding = 0.dp) {
                            Column {
                                exerciseRows.forEachIndexed { index, (exercise, history) ->
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable { onExercise(exercise, history) }
                                            .padding(16.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(
                                            Icons.Filled.FitnessCenter,
                                            contentDescription = null,
                                            tint = Palette.effortColor,
                                        )
                                        Spacer(Modifier.width(12.dp))
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                strengthExerciseName(exercise),
                                                style = NoopType.headline,
                                                color = Palette.textPrimary,
                                            )
                                            Text(
                                                exerciseRecordSummary(history, massUnit),
                                                style = NoopType.footnote,
                                                color = Palette.textSecondary,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                        Icon(
                                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                            contentDescription = null,
                                            tint = Palette.textTertiary,
                                        )
                                    }
                                    if (index < exerciseRows.lastIndex) {
                                        HorizontalDivider(color = Palette.hairline)
                                    }
                                }
                            }
                        }
                    }

                    val finished = sessions.filter { it.session.endedAt != null }
                    SectionHeader(
                        stringResource(R.string.strength_recent_sessions),
                        overline = stringResource(R.string.strength_editable_history),
                        trailing = finished.size.takeIf { it > 0 }?.toString(),
                    )
                    if (finished.isEmpty()) {
                        ScreenStateCard(
                            kind = ScreenStateKind.Empty,
                            title = stringResource(R.string.strength_no_finished_title),
                            body = stringResource(R.string.strength_no_finished_body),
                        )
                    } else {
                        NoopCard(padding = 0.dp) {
                            Column {
                                finished.take(20).forEachIndexed { index, item ->
                                    StrengthHistoryRow(item, exercises, massUnit, onEdit, onDelete)
                                    if (index < finished.take(20).lastIndex) {
                                        HorizontalDivider(color = Palette.hairline)
                                    }
                                }
                            }
                        }
                    }

                    NoopCard {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                stringResource(R.string.strength_numbers_meaning_title),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(R.string.strength_numbers_meaning_body),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StrengthWeeklyGoals(
    weekly: StrengthWeeklyProgress,
    sessionGoal: Int,
    setGoal: Int,
    massUnit: MassUnit,
    onSessionGoal: (Int) -> Unit,
    onSetGoal: (Int) -> Unit,
) {
    NoopCard(tint = Palette.effortColor) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            StrengthGoalRow(
                title = stringResource(R.string.appwide_strength_sessions_goal),
                completed = weekly.sessionCount,
                goal = sessionGoal,
                range = 1..14,
                onChange = onSessionGoal,
            )
            HorizontalDivider(color = Palette.hairline)
            StrengthGoalRow(
                title = stringResource(R.string.appwide_strength_completed_sets),
                completed = weekly.completedSetCount,
                goal = setGoal,
                range = 1..100,
                onChange = onSetGoal,
            )
            Text(
                buildString {
                    append(NumberFormat.getIntegerInstance().format(weekly.totalReps))
                    append(" reps")
                    if (weekly.loadedVolumeKg > 0) {
                        append(" · ")
                        append(UnitFormatter.massFromKilograms(weekly.loadedVolumeKg, massUnit))
                        append(" loaded volume")
                    }
                },
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun StrengthGoalRow(
    title: String,
    completed: Int,
    goal: Int,
    range: IntRange,
    onChange: (Int) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.appwide_strength_progress_format, completed, goal),
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                )
            }
            IconButton(
                onClick = { onChange((goal - 1).coerceAtLeast(range.first)) },
                enabled = goal > range.first,
            ) {
                Icon(
                    Icons.Filled.Remove,
                    contentDescription = stringResource(R.string.appwide_strength_decrease_goal),
                )
            }
            Text(
                NumberFormat.getIntegerInstance().format(goal),
                style = NoopType.bodyNumber,
                color = Palette.textPrimary,
                modifier = Modifier.width(28.dp),
            )
            IconButton(
                onClick = { onChange((goal + 1).coerceAtMost(range.last)) },
                enabled = goal < range.last,
            ) {
                Icon(
                    Icons.Filled.Add,
                    contentDescription = stringResource(R.string.appwide_strength_increase_goal),
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 7.dp, max = 7.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.surfaceInset),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth((completed.toFloat() / goal.coerceAtLeast(1)).coerceIn(0f, 1f))
                    .fillMaxHeight()
                    .background(
                        if (completed >= goal) Palette.statusPositive else Palette.effortColor,
                    ),
            )
        }
    }
}

@Composable
private fun StrengthMuscleMap(focus: List<StrengthMuscleFocus>) {
    if (focus.isEmpty()) {
        ScreenStateCard(
            kind = ScreenStateKind.Empty,
            title = stringResource(R.string.appwide_strength_no_muscle_exposure),
            body = "Complete manual sets to see where your training has been concentrated.",
        )
        return
    }
    val maximum = (focus.firstOrNull()?.weightedSetExposure ?: 0.0).coerceAtLeast(1.0)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                stringResource(R.string.appwide_strength_muscle_map_explanation),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            focus.take(8).forEach { item ->
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Row {
                        Text(
                            strengthDescriptor(item.muscle),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            item.weightedSetExposure.strengthNumber(),
                            style = NoopType.captionNumber,
                            color = Palette.textSecondary,
                        )
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 7.dp, max = 7.dp)
                            .clip(RoundedCornerShape(50))
                            .background(Palette.surfaceInset),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(
                                    (item.weightedSetExposure / maximum).toFloat().coerceIn(0f, 1f),
                                )
                                .fillMaxHeight()
                                .background(Palette.effortColor),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StrengthExerciseProgressPanel(
    exercise: StrengthExerciseRow,
    history: List<StrengthExerciseHistoryPoint>,
    massUnit: MassUnit,
    onClose: () -> Unit,
) {
    val heaviest = history.mapNotNull { it.maxLoadKg }.maxOrNull()
    val mostReps = history.mapNotNull { it.maxReps }.maxOrNull()
    val bestVolume = history.mapNotNull { it.bestSetVolumeKg }.maxOrNull()
    val completedSets = history.sumOf { it.completedSetCount }
    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.FitnessCenter,
                contentDescription = null,
                tint = Palette.effortColor,
                modifier = Modifier.size(26.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(strengthExerciseName(exercise), style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.appwide_strength_factual_records),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            IconButton(onClick = onClose) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(
                        R.string.appwide_strength_close_exercise_records,
                    ),
                )
            }
        }
        HorizontalDivider(color = Palette.hairline)
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SectionHeader(
                stringResource(R.string.appwide_strength_personal_records),
                overline = "All time",
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatTile(
                    "Heaviest load",
                    heaviest?.let { UnitFormatter.massFromKilograms(it, massUnit) } ?: "—",
                    Modifier.weight(1f),
                    "external load",
                    Palette.effortColor,
                )
                StatTile(
                    "Most reps",
                    mostReps?.toString() ?: "—",
                    Modifier.weight(1f),
                    "one completed set",
                    Palette.accent,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatTile(
                    "Best set volume",
                    bestVolume?.let { UnitFormatter.massFromKilograms(it, massUnit) } ?: "—",
                    Modifier.weight(1f),
                    "load × reps",
                    Palette.metricPurple,
                )
                StatTile(
                    "Completed sets",
                    completedSets.toString(),
                    Modifier.weight(1f),
                    "${history.size} sessions",
                    Palette.metricCyan,
                )
            }
            SectionHeader("History", overline = "Newest first")
            NoopCard(padding = 0.dp) {
                Column {
                    history.forEachIndexed { index, point ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(
                                    strengthDate(point.startedAt),
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    exerciseHistoryDetail(point, massUnit),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                )
                            }
                            Text(
                                stringResource(
                                    R.string.appwide_strength_sets_format,
                                    point.completedSetCount,
                                ),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                        }
                        if (index < history.lastIndex) HorizontalDivider(color = Palette.hairline)
                    }
                }
            }
            NoopCard {
                Text(
                    stringResource(R.string.appwide_strength_direct_records_disclaimer),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

private fun currentStrengthWeekRange(): Pair<Long, Long> {
    val zone = ZoneId.systemDefault()
    val now = LocalDate.now(zone)
    val firstDay = WeekFields.of(Locale.getDefault()).firstDayOfWeek
    val start = now.with(TemporalAdjusters.previousOrSame(firstDay)).atStartOfDay(zone).toEpochSecond()
    val end = now.with(TemporalAdjusters.next(firstDay)).atStartOfDay(zone).toEpochSecond() - 1
    return start to end
}

private fun exerciseRecordSummary(
    history: List<StrengthExerciseHistoryPoint>,
    massUnit: MassUnit,
): String {
    val parts = mutableListOf("${history.size} sessions")
    history.mapNotNull { it.maxLoadKg }.maxOrNull()?.let {
        parts += "heaviest ${UnitFormatter.massFromKilograms(it, massUnit)}"
    }
    history.mapNotNull { it.maxReps }.maxOrNull()?.let { parts += "up to $it reps" }
    return parts.joinToString(" · ")
}

private fun exerciseHistoryDetail(
    point: StrengthExerciseHistoryPoint,
    massUnit: MassUnit,
): String {
    val parts = mutableListOf("${point.totalReps} reps")
    point.maxLoadKg?.let { parts += "heaviest ${UnitFormatter.massFromKilograms(it, massUnit)}" }
    point.bestSetVolumeKg?.let {
        parts += "best set ${UnitFormatter.massFromKilograms(it, massUnit)}"
    }
    return parts.joinToString(" · ")
}

@Composable
private fun StrengthHistoryRow(
    item: StrengthSessionSnapshot,
    exercises: List<StrengthExerciseRow>,
    massUnit: MassUnit,
    onEdit: (StrengthSessionSnapshot) -> Unit,
    onDelete: (StrengthSessionSnapshot) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onEdit(item) }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    item.session.name ?: stringResource(R.string.strength_default_workout_name),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                Text(strengthDate(item.session.startedAt), style = NoopType.footnote, color = Palette.textTertiary)
            }
            Text(
                sessionDetail(item, exercises, massUnit),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = stringResource(R.string.strength_session_actions),
                )
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.strength_edit_session)) },
                    onClick = { menuOpen = false; onEdit(item) },
                )
                DropdownMenuItem(
                    text = {
                        Text(
                            stringResource(R.string.strength_delete_session),
                            color = Palette.statusCritical,
                        )
                    },
                    onClick = { menuOpen = false; onDelete(item) },
                    leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = Palette.statusCritical) },
                )
            }
        }
    }
}

@Composable
private fun StrengthSessionEditor(
    vm: AppViewModel,
    initial: StrengthSessionSnapshot,
    exercises: List<StrengthExerciseRow>,
    routines: List<StrengthRoutineSnapshot>,
    massUnit: MassUnit,
    onClose: () -> Unit,
    onSaved: (StrengthSessionSnapshot) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val saveError = stringResource(R.string.strength_save_error)
    val setRequirementsError = stringResource(R.string.strength_set_requirements_error)
    var session by remember(initial.session.id) { mutableStateOf(initial.session) }
    var blocks by remember(initial.session.id, initial.sets) {
        mutableStateOf(strengthBlocks(initial, exercises, routines))
    }
    var saving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var exercisePicker by remember { mutableStateOf(false) }
    var routinePrompt by remember { mutableStateOf(false) }
    var routineName by remember { mutableStateOf(initial.session.name.orEmpty()) }
    var restEndMs by remember { mutableLongStateOf(0L) }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }

    LaunchedEffect(restEndMs) {
        while (restEndMs > 0L) {
            nowMs = System.currentTimeMillis()
            if (nowMs >= restEndMs) break
            delay(1_000)
        }
    }

    fun normalizedRows(): List<StrengthSetRow> =
        blocks.flatMapIndexed { blockIndex, block ->
            block.sets.mapIndexed { setIndex, row ->
                row.copy(
                    exercisePosition = blockIndex,
                    setPosition = setIndex,
                    restSeconds = block.restSeconds,
                )
            }
        }

    suspend fun persist(endedAt: Long? = session.endedAt): StrengthSessionSnapshot? {
        if (saving) return null
        saving = true
        val now = Instant.now().epochSecond
        val cleanSession = session.copy(endedAt = endedAt, updatedAt = now)
        val rows = normalizedRows().map { it.copy(updatedAt = now) }
        return runCatching { vm.repo.saveStrengthSession(cleanSession, rows) }
            .onSuccess {
                session = it.session
                onSaved(it)
            }
            .onFailure { errorMessage = it.strengthMessage(saveError) }
            .getOrNull()
            .also { saving = false }
    }

    fun autosave() {
        scope.launch { persist() }
    }

    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = {
                scope.launch {
                    if (persist() != null) onClose()
                }
            }, enabled = !saving) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.strength_close_workout),
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    if (session.endedAt == null) {
                        stringResource(R.string.strength_log_workout)
                    } else {
                        stringResource(R.string.strength_edit_workout)
                    },
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.strength_manual_load_unit, massUnit.raw),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            StatePill(
                stringResource(
                    R.string.strength_complete_count,
                    normalizedRows().count { it.completedAt != null },
                ),
                tone = StrandTone.Positive,
                showsDot = false,
            )
        }
        HorizontalDivider(color = Palette.hairline)
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            NoopCard(tint = Palette.effortColor) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = session.name.orEmpty(),
                        onValueChange = { session = session.copy(name = it.ifBlank { null }) },
                        label = { Text(stringResource(R.string.strength_workout_name_optional)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        stringResource(R.string.strength_started, strengthDate(session.startedAt)),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
            }

            if (restEndMs > 0L) {
                val remaining = ((restEndMs - nowMs).coerceAtLeast(0L) + 999L) / 1_000L
                NoopCard(tint = Palette.metricCyan) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (remaining == 0L) Icons.Filled.CheckCircle else Icons.Filled.Timer,
                            contentDescription = null,
                            tint = Palette.metricCyan,
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                if (remaining == 0L) {
                                    stringResource(R.string.strength_rest_complete)
                                } else {
                                    stringResource(R.string.strength_rest_timer)
                                },
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                if (remaining == 0L) {
                                    stringResource(R.string.strength_ready)
                                } else {
                                    stringResource(
                                        R.string.strength_rest_remaining,
                                        strengthRestTime(remaining),
                                    )
                                },
                                style = NoopType.number(18f),
                                color = Palette.textSecondary,
                            )
                        }
                        if (remaining > 0L) {
                            TextButton(onClick = { restEndMs += 30_000L }) {
                                Text(
                                    stringResource(R.string.strength_add_30_seconds),
                                    color = Palette.metricCyan,
                                )
                            }
                        }
                        TextButton(onClick = { restEndMs = 0L }) {
                            Text(
                                if (remaining == 0L) {
                                    stringResource(R.string.strength_done)
                                } else {
                                    stringResource(R.string.strength_skip)
                                },
                                color = Palette.textSecondary,
                            )
                        }
                    }
                }
            }

            if (blocks.isEmpty()) {
                ScreenStateCard(
                    kind = ScreenStateKind.Empty,
                    title = stringResource(R.string.strength_add_first_exercise_title),
                    body = stringResource(R.string.strength_add_first_exercise_body),
                )
            } else {
                blocks.forEach { block ->
                    StrengthExerciseCard(
                        block = block,
                        massUnit = massUnit,
                        onChange = { changed ->
                            blocks = blocks.map { if (it.key == changed.key) changed else it }
                        },
                        onRestChange = { seconds ->
                            blocks = blocks.map { candidate ->
                                if (candidate.key != block.key) candidate else candidate.copy(
                                    restSeconds = seconds,
                                    sets = candidate.sets.map { it.copy(restSeconds = seconds) },
                                )
                            }
                            autosave()
                        },
                        onComplete = { row, restSeconds ->
                            if (row.reps == null && row.durationS == null) {
                                errorMessage = setRequirementsError
                            } else {
                                val now = Instant.now().epochSecond
                                blocks = blocks.map { candidate ->
                                    if (candidate.key != block.key) candidate else candidate.copy(
                                        sets = candidate.sets.map {
                                            if (it.id == row.id) it.copy(completedAt = now, updatedAt = now) else it
                                        },
                                    )
                                }
                                if (restSeconds > 0) {
                                    restEndMs = System.currentTimeMillis() + restSeconds * 1_000L
                                }
                                autosave()
                            }
                        },
                        onUncomplete = { row ->
                            blocks = blocks.map { candidate ->
                                if (candidate.key != block.key) candidate else candidate.copy(
                                    sets = candidate.sets.map {
                                        if (it.id == row.id) it.copy(completedAt = null) else it
                                    },
                                )
                            }
                            autosave()
                        },
                        onDeleteSet = { row ->
                            blocks = normalizeBlocks(
                                blocks.map { candidate ->
                                    if (candidate.key != block.key) candidate
                                    else candidate.copy(sets = candidate.sets.filterNot { it.id == row.id })
                                },
                            )
                            autosave()
                        },
                        onAddSet = {
                            val now = Instant.now().epochSecond
                            val previous = block.sets.lastOrNull()
                            val added = StrengthSetRow(
                                id = UUID.randomUUID().toString().lowercase(),
                                sessionId = session.id,
                                exerciseId = block.exercise.id,
                                exercisePosition = block.position,
                                setPosition = block.sets.size,
                                setType = previous?.setType ?: "working",
                                reps = previous?.reps,
                                loadKg = previous?.loadKg,
                                durationS = previous?.durationS,
                                restSeconds = block.restSeconds,
                                createdAt = now,
                                updatedAt = now,
                            )
                            blocks = blocks.map {
                                if (it.key == block.key) it.copy(sets = it.sets + added) else it
                            }
                            autosave()
                        },
                        onDeleteExercise = {
                            blocks = normalizeBlocks(blocks.filterNot { it.key == block.key })
                            autosave()
                        },
                    )
                }
            }

            NoopButton(
                text = stringResource(R.string.strength_add_exercise),
                leadingIcon = Icons.Filled.Add,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
            ) { exercisePicker = true }

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NoopButton(
                    text = stringResource(R.string.strength_save_as_routine),
                    leadingIcon = Icons.AutoMirrored.Filled.List,
                    kind = NoopButtonKind.Secondary,
                    enabled = blocks.isNotEmpty() && !saving,
                    modifier = Modifier.weight(1f),
                ) { routinePrompt = true }
                NoopButton(
                    text = stringResource(R.string.strength_save_close),
                    leadingIcon = Icons.Filled.Save,
                    kind = NoopButtonKind.Secondary,
                    enabled = !saving,
                    modifier = Modifier.weight(1f),
                ) {
                    scope.launch {
                        if (persist() != null) onClose()
                    }
                }
            }
            NoopButton(
                text = if (session.endedAt == null) {
                    stringResource(R.string.strength_finish_workout)
                } else {
                    stringResource(R.string.strength_save_changes)
                },
                leadingIcon = Icons.Filled.Check,
                fullWidth = true,
                enabled = normalizedRows().any { it.completedAt != null } && !saving,
            ) {
                scope.launch {
                    val now = Instant.now().epochSecond
                    val latest = normalizedRows().mapNotNull { it.completedAt }.maxOrNull() ?: now
                    val endedAt = if (now - session.startedAt <= StrengthTrainingContract.MAX_DURATION_SECONDS) {
                        now
                    } else {
                        minOf(latest, session.startedAt + StrengthTrainingContract.MAX_DURATION_SECONDS)
                    }
                    if (persist(endedAt) != null) onClose()
                }
            }
            Text(
                stringResource(R.string.strength_rest_timer_limit),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }

    if (exercisePicker) {
        StrengthExercisePicker(
            exercises = exercises.filter { exercise -> blocks.none { it.exercise.id == exercise.id } },
            onDismiss = { exercisePicker = false },
            onPick = { exercise ->
                val now = Instant.now().epochSecond
                val position = blocks.size
                val sets = (0 until 3).map { setPosition ->
                    StrengthSetRow(
                        id = UUID.randomUUID().toString().lowercase(),
                        sessionId = session.id,
                        exerciseId = exercise.id,
                        exercisePosition = position,
                        setPosition = setPosition,
                        setType = if (exercise.equipment == "bodyweight") "bodyweight" else "working",
                        createdAt = now,
                        updatedAt = now,
                    )
                }
                blocks = blocks + StrengthBlockDraft(
                    key = "$position-${exercise.id}",
                    exercise = exercise,
                    position = position,
                    restSeconds = 120,
                    sets = sets,
                )
                exercisePicker = false
                autosave()
            },
        )
    }

    if (routinePrompt) {
        AlertDialog(
            onDismissRequest = { routinePrompt = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    stringResource(R.string.strength_save_as_routine),
                    style = NoopType.title2,
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        stringResource(R.string.strength_routine_storage_explanation),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                    OutlinedTextField(
                        value = routineName,
                        onValueChange = { routineName = it },
                        label = { Text(stringResource(R.string.strength_routine_name)) },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = routineName.isNotBlank(),
                    onClick = {
                        routinePrompt = false
                        scope.launch {
                            val now = Instant.now().epochSecond
                            val routineId = UUID.randomUUID().toString().lowercase()
                            val routine = StrengthRoutineRow(
                                id = routineId,
                                name = routineName.trim(),
                                createdAt = now,
                                updatedAt = now,
                            )
                            val prescription = blocks.map { block ->
                                val reps = block.sets.mapNotNull { it.reps }
                                StrengthRoutineExerciseRow(
                                    id = UUID.randomUUID().toString().lowercase(),
                                    routineId = routineId,
                                    exerciseId = block.exercise.id,
                                    position = block.position,
                                    targetSets = maxOf(1, block.sets.size),
                                    targetRepsMin = reps.minOrNull(),
                                    targetRepsMax = reps.maxOrNull(),
                                    restSeconds = block.restSeconds,
                                    createdAt = now,
                                    updatedAt = now,
                                )
                            }
                            runCatching { vm.repo.saveStrengthRoutine(routine, prescription) }
                                .onFailure { errorMessage = it.strengthMessage(saveError) }
                        }
                    },
                ) { Text(stringResource(R.string.strength_save), color = Palette.accent) }
            },
            dismissButton = {
                TextButton(onClick = { routinePrompt = false }) {
                    Text(stringResource(R.string.strength_cancel), color = Palette.textSecondary)
                }
            },
        )
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            containerColor = Palette.surfaceOverlay,
            title = { Text(stringResource(R.string.strength_title), style = NoopType.title2) },
            text = { Text(message, style = NoopType.body, color = Palette.textSecondary) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) {
                    Text(stringResource(R.string.strength_ok), color = Palette.accent)
                }
            },
        )
    }
}

@Composable
private fun StrengthExerciseCard(
    block: StrengthBlockDraft,
    massUnit: MassUnit,
    onChange: (StrengthBlockDraft) -> Unit,
    onRestChange: (Int) -> Unit,
    onComplete: (StrengthSetRow, Int) -> Unit,
    onUncomplete: (StrengthSetRow) -> Unit,
    onDeleteSet: (StrengthSetRow) -> Unit,
    onAddSet: () -> Unit,
    onDeleteExercise: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    NoopCard(padding = 0.dp, tint = Palette.effortColor) {
        Column {
            Row(
                modifier = Modifier.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(Palette.surfaceInset),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.FitnessCenter, contentDescription = null, tint = Palette.effortColor)
                }
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        strengthExerciseName(block.exercise),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(
                            R.string.strength_descriptor_pair,
                            strengthDescriptor(block.exercise.primaryMuscle),
                            strengthDescriptor(block.exercise.equipment),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(
                            Icons.Filled.MoreVert,
                            contentDescription = stringResource(R.string.strength_exercise_actions),
                        )
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        listOf(
                            0 to R.string.strength_rest_no_timer,
                            60 to R.string.strength_rest_60_seconds,
                            90 to R.string.strength_rest_90_seconds,
                            120 to R.string.strength_rest_2_minutes,
                            180 to R.string.strength_rest_3_minutes,
                            300 to R.string.strength_rest_5_minutes,
                        ).forEach { (value, labelResource) ->
                            val label = stringResource(labelResource)
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        if (block.restSeconds == value) {
                                            stringResource(R.string.strength_selected_option, label)
                                        } else {
                                            label
                                        },
                                    )
                                },
                                onClick = {
                                    menuOpen = false
                                    onRestChange(value)
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = {
                                Text(
                                    stringResource(R.string.strength_remove_exercise),
                                    color = Palette.statusCritical,
                                )
                            },
                            onClick = { menuOpen = false; onDeleteExercise() },
                        )
                    }
                }
            }
            HorizontalDivider(color = Palette.hairline)
            block.sets.forEachIndexed { index, row ->
                StrengthSetEditorRow(
                    index = index,
                    row = row,
                    massUnit = massUnit,
                    onChange = { changed ->
                        onChange(block.copy(sets = block.sets.map { if (it.id == changed.id) changed else it }))
                    },
                    onComplete = { if (row.completedAt == null) onComplete(row, block.restSeconds) else onUncomplete(row) },
                    onDelete = { onDeleteSet(row) },
                )
                if (index < block.sets.lastIndex) HorizontalDivider(color = Palette.hairline)
            }
            TextButton(onClick = onAddSet, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = Palette.effortColor)
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.strength_add_set), color = Palette.effortColor)
            }
        }
    }
}

@Composable
private fun StrengthSetEditorRow(
    index: Int,
    row: StrengthSetRow,
    massUnit: MassUnit,
    onChange: (StrengthSetRow) -> Unit,
    onComplete: () -> Unit,
    onDelete: () -> Unit,
) {
    var typeMenu by remember { mutableStateOf(false) }
    val complete = row.completedAt != null
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(if (complete) Palette.statusPositive.copy(alpha = 0.06f) else Color.Transparent)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onComplete) {
                Icon(
                    if (complete) Icons.Filled.CheckCircle else Icons.Filled.Check,
                    contentDescription = if (complete) {
                        stringResource(R.string.strength_mark_set_incomplete)
                    } else {
                        stringResource(R.string.strength_complete_set_number, index + 1)
                    },
                    tint = if (complete) Palette.statusPositive else Palette.textTertiary,
                )
            }
            Text(
                stringResource(R.string.strength_set_number, index + 1),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(onClick = { typeMenu = true }) {
                    Text(strengthSetType(row.setType), color = Palette.textSecondary)
                }
                DropdownMenu(expanded = typeMenu, onDismissRequest = { typeMenu = false }) {
                    listOf("working", "warmup", "drop", "failure", "bodyweight").forEach { type ->
                        DropdownMenuItem(
                            text = { Text(strengthSetType(type)) },
                            onClick = { typeMenu = false; onChange(row.copy(setType = type)) },
                        )
                    }
                }
            }
            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = stringResource(R.string.strength_delete_set_number, index + 1),
                    tint = Palette.textTertiary,
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StrengthField(
                value = row.reps?.toString().orEmpty(),
                label = stringResource(R.string.strength_reps),
                keyboard = KeyboardType.Number,
                modifier = Modifier.weight(1f),
            ) { text -> onChange(row.copy(reps = text.filter(Char::isDigit).toIntOrNull())) }
            val displayLoad = row.loadKg?.let {
                if (massUnit == MassUnit.POUNDS) UnitFormatter.kgToPounds(it) else it
            }
            StrengthField(
                value = displayLoad?.strengthNumber().orEmpty(),
                label = massUnit.raw,
                keyboard = KeyboardType.Decimal,
                modifier = Modifier.weight(1f),
            ) { text ->
                val display = text.strengthDouble()
                onChange(
                    row.copy(
                        loadKg = display?.let {
                            if (massUnit == MassUnit.POUNDS) UnitFormatter.poundsToKg(it) else it
                        },
                    ),
                )
            }
            StrengthField(
                value = row.durationS?.toString().orEmpty(),
                label = stringResource(R.string.strength_seconds_short),
                keyboard = KeyboardType.Number,
                modifier = Modifier.weight(1f),
            ) { text -> onChange(row.copy(durationS = text.filter(Char::isDigit).toIntOrNull())) }
            StrengthField(
                value = row.rpe?.strengthNumber().orEmpty(),
                label = stringResource(R.string.strength_rpe),
                keyboard = KeyboardType.Decimal,
                modifier = Modifier.weight(1f),
            ) { text -> onChange(row.copy(rpe = text.strengthDouble())) }
        }
    }
}

@Composable
private fun StrengthField(
    value: String,
    label: String,
    keyboard: KeyboardType,
    modifier: Modifier,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label, style = NoopType.footnote) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = modifier,
    )
}

@Composable
private fun StrengthExercisePicker(
    exercises: List<StrengthExerciseRow>,
    onDismiss: () -> Unit,
    onPick: (StrengthExerciseRow) -> Unit,
) {
    var search by remember { mutableStateOf("") }
    val context = LocalContext.current
    val filtered = exercises.filter {
        val localizedName = strengthExerciseNameResource(it.id)?.let(context::getString) ?: it.name
        search.isBlank() ||
            it.name.contains(search, ignoreCase = true) ||
            localizedName.contains(search, ignoreCase = true) ||
            it.primaryMuscle.contains(search, ignoreCase = true) ||
            it.equipment.contains(search, ignoreCase = true)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(stringResource(R.string.strength_choose_exercise), style = NoopType.title2) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    label = { Text(stringResource(R.string.strength_search_exercises)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Column(
                    modifier = Modifier
                        .heightIn(max = 420.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    if (filtered.isEmpty()) {
                        Text(
                            stringResource(R.string.strength_no_matching_exercises),
                            style = NoopType.body,
                            color = Palette.textSecondary,
                            modifier = Modifier.padding(vertical = 20.dp),
                        )
                    }
                    filtered.forEach { exercise ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onPick(exercise) }
                                .padding(vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.FitnessCenter, contentDescription = null, tint = Palette.effortColor)
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(
                                    strengthExerciseName(exercise),
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    stringResource(
                                        R.string.strength_descriptor_pair,
                                        strengthDescriptor(exercise.primaryMuscle),
                                        strengthDescriptor(exercise.equipment),
                                    ),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.strength_cancel), color = Palette.textSecondary)
            }
        },
    )
}

private fun strengthBlocks(
    initial: StrengthSessionSnapshot,
    exercises: List<StrengthExerciseRow>,
    routines: List<StrengthRoutineSnapshot>,
): List<StrengthBlockDraft> {
    val sourceRoutine = routines.firstOrNull { it.routine.id == initial.session.routineId }
    return initial.sets.groupBy { it.exercisePosition }.toSortedMap().mapNotNull { (position, rows) ->
        val first = rows.firstOrNull() ?: return@mapNotNull null
        val exercise = exercises.firstOrNull { it.id == first.exerciseId } ?: return@mapNotNull null
        val prescription = sourceRoutine?.exercises?.firstOrNull {
            it.position == position && it.exerciseId == first.exerciseId
        }
        StrengthBlockDraft(
            key = "$position-${first.exerciseId}",
            exercise = exercise,
            position = position,
            restSeconds = first.restSeconds ?: prescription?.restSeconds ?: 120,
            sets = rows.sortedBy { it.setPosition },
        )
    }
}

private fun normalizeBlocks(blocks: List<StrengthBlockDraft>): List<StrengthBlockDraft> =
    blocks.mapIndexed { blockIndex, block ->
        block.copy(
            position = blockIndex,
            sets = block.sets.mapIndexed { setIndex, row ->
                row.copy(
                    exercisePosition = blockIndex,
                    setPosition = setIndex,
                    restSeconds = block.restSeconds,
                )
            },
        )
    }

@Composable
private fun routineDetail(
    routine: StrengthRoutineSnapshot,
    exercises: List<StrengthExerciseRow>,
): String {
    val names = mutableListOf<String>()
    for (row in routine.exercises) {
        val exercise = exercises.firstOrNull { it.id == row.exerciseId } ?: continue
        names += strengthExerciseName(exercise)
    }
    return stringResource(
        R.string.strength_routine_detail,
        names.joinToString(" · "),
        routine.exercises.sumOf { it.targetSets },
    )
}

@Composable
private fun sessionDetail(
    item: StrengthSessionSnapshot,
    exercises: List<StrengthExerciseRow>,
    massUnit: MassUnit,
): String {
    val completed = item.sets.filter { it.completedAt != null }
    val names = mutableListOf<String>()
    val ordered = item.sets.sortedWith(compareBy({ it.exercisePosition }, { it.setPosition }))
        .distinctBy { it.exerciseId }
    for (row in ordered) {
        val exercise = exercises.firstOrNull { it.id == row.exerciseId } ?: continue
        names += strengthExerciseName(exercise)
    }
    val volume = completed.mapNotNull { it.volumeKg }.sum()
    val reps = completed.mapNotNull { it.reps }.sum()
    return if (volume > 0) {
        stringResource(
            R.string.strength_session_detail_with_volume,
            completed.size,
            reps,
            UnitFormatter.massFromKilograms(volume, massUnit),
            names.joinToString(),
        )
    } else {
        stringResource(
            R.string.strength_session_detail_without_volume,
            completed.size,
            reps,
            names.joinToString(),
        )
    }
}

@Composable
private fun strengthExerciseName(exercise: StrengthExerciseRow): String {
    val resource = strengthExerciseNameResource(exercise.id)
    return if (resource == null) exercise.name else stringResource(resource)
}

private fun strengthExerciseNameResource(id: String): Int? = when (id) {
    "barbell_back_squat" -> R.string.strength_exercise_back_squat
    "barbell_bench_press" -> R.string.strength_exercise_bench_press
    "conventional_deadlift" -> R.string.strength_exercise_deadlift
    "overhead_press" -> R.string.strength_exercise_overhead_press
    "bent_over_row" -> R.string.strength_exercise_bent_over_row
    "pull_up" -> R.string.strength_exercise_pull_up
    "lat_pulldown" -> R.string.strength_exercise_lat_pulldown
    "leg_press" -> R.string.strength_exercise_leg_press
    "romanian_deadlift" -> R.string.strength_exercise_romanian_deadlift
    "dumbbell_lunge" -> R.string.strength_exercise_dumbbell_lunge
    "biceps_curl" -> R.string.strength_exercise_biceps_curl
    "triceps_pushdown" -> R.string.strength_exercise_triceps_pushdown
    "plank" -> R.string.strength_exercise_plank
    else -> null
}

@Composable
private fun strengthDescriptor(value: String): String = when (value) {
    "chest" -> stringResource(R.string.strength_descriptor_chest)
    "back" -> stringResource(R.string.strength_descriptor_back)
    "shoulders" -> stringResource(R.string.strength_descriptor_shoulders)
    "biceps" -> stringResource(R.string.strength_descriptor_biceps)
    "triceps" -> stringResource(R.string.strength_descriptor_triceps)
    "forearms" -> stringResource(R.string.strength_descriptor_forearms)
    "core" -> stringResource(R.string.strength_descriptor_core)
    "quadriceps" -> stringResource(R.string.strength_descriptor_quadriceps)
    "hamstrings" -> stringResource(R.string.strength_descriptor_hamstrings)
    "glutes" -> stringResource(R.string.strength_descriptor_glutes)
    "calves" -> stringResource(R.string.strength_descriptor_calves)
    "full_body" -> stringResource(R.string.strength_descriptor_full_body)
    "barbell" -> stringResource(R.string.strength_descriptor_barbell)
    "dumbbell" -> stringResource(R.string.strength_descriptor_dumbbell)
    "kettlebell" -> stringResource(R.string.strength_descriptor_kettlebell)
    "cable" -> stringResource(R.string.strength_descriptor_cable)
    "machine" -> stringResource(R.string.strength_descriptor_machine)
    "bodyweight" -> stringResource(R.string.strength_descriptor_bodyweight)
    "band" -> stringResource(R.string.strength_descriptor_band)
    else -> stringResource(R.string.strength_descriptor_other)
}

@Composable
private fun strengthSetType(value: String): String = when (value) {
    "warmup" -> stringResource(R.string.strength_set_type_warmup)
    "drop" -> stringResource(R.string.strength_set_type_drop)
    "failure" -> stringResource(R.string.strength_set_type_failure)
    "bodyweight" -> stringResource(R.string.strength_set_type_bodyweight)
    else -> stringResource(R.string.strength_set_type_working)
}

private fun strengthDate(seconds: Long): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withZone(ZoneId.systemDefault())
        .format(Instant.ofEpochSecond(seconds))

private fun strengthRestTime(seconds: Long): String =
    "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"

private fun Double.strengthNumber(): String =
    if (this % 1.0 == 0.0) toInt().toString() else "%.1f".format(this)

private fun String.strengthDouble(): Double? =
    replace(',', '.').filter { it.isDigit() || it == '.' }.toDoubleOrNull()

private fun Throwable.strengthMessage(fallback: String): String =
    message?.takeIf { it.isNotBlank() } ?: fallback
