package com.noop.ui

import android.speech.tts.TextToSpeech
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.data.StrengthAdaptivePlanner
import com.noop.data.StrengthDayRecommendationReason
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthExerciseHistoryPoint
import com.noop.data.StrengthExercisePlan
import com.noop.data.StrengthMuscleFocus
import com.noop.data.StrengthMuscleStatus
import com.noop.data.StrengthProgressionReason
import com.noop.data.StrengthProgressCalculator
import com.noop.data.StrengthProgramRequest
import com.noop.data.StrengthTrainingExperience
import com.noop.data.StrengthTrainingStyle
import com.noop.data.StrengthWeeklyProgress
import com.noop.data.StrengthRoutineExerciseRow
import com.noop.data.StrengthRoutineRow
import com.noop.data.StrengthRoutineSnapshot
import com.noop.data.StrengthRoutineCompletion
import com.noop.data.StrengthScheduleDay
import com.noop.data.StrengthSessionRow
import com.noop.data.StrengthSessionSnapshot
import com.noop.data.StrengthSetRow
import com.noop.data.StrengthSummary
import com.noop.data.StrengthTrainingContract
import com.noop.data.StrengthWorkoutPlanner
import com.noop.data.StrengthWorkoutPrescription
import java.text.NumberFormat
import java.time.Instant
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.UUID
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private data class StrengthBlockDraft(
    val key: String,
    val exercise: StrengthExerciseRow,
    val position: Int,
    val restSeconds: Int,
    val sets: List<StrengthSetRow>,
    val supersetGroup: Int? = null,
    val sourceRoutineExerciseId: String? = null,
)

private data class StrengthTodayExercisePlan(
    val prescription: StrengthRoutineExerciseRow,
    val exercise: StrengthExerciseRow,
    val workout: StrengthWorkoutPrescription,
)

private enum class StrengthGymTab(@StringRes val labelRes: Int) {
    TODAY(R.string.appwide_gym_tab_today),
    PLAN(R.string.appwide_gym_tab_plan),
    LIBRARY(R.string.appwide_gym_tab_library),
    PROGRESS(R.string.appwide_gym_tab_progress),
}

private data class StrengthRoutineEditorTarget(val initial: StrengthRoutineSnapshot?)

private data class StrengthRoutineExerciseDraft(
    val id: String,
    val exercise: StrengthExerciseRow,
    val targetSets: Int,
    val targetRepsMin: Int,
    val targetRepsMax: Int,
    val targetRPE: Double?,
    val restSeconds: Int,
    val note: String,
    val plan: StrengthExercisePlan,
    val createdAt: Long,
)

private const val STRENGTH_PROFILE_EXPERIENCE = "strength.profile.experience"
private const val STRENGTH_PROFILE_STYLE = "strength.profile.style"
private const val STRENGTH_PROFILE_SESSION_MINUTES = "strength.profile.sessionMinutes"
private const val STRENGTH_PROFILE_DAY_COUNT = "strength.profile.dayCount"
private const val STRENGTH_PROFILE_WEEKDAYS = "strength.profile.weekdays"
private const val STRENGTH_PROFILE_FOCUS_MUSCLES = "strength.profile.focusMuscles"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StrengthTrainerSheet(
    vm: AppViewModel,
    onDismiss: () -> Unit,
    initialGuideExerciseId: String? = null,
) {
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
    var routineEditor by remember { mutableStateOf<StrengthRoutineEditorTarget?>(null) }
    var programBuilder by remember { mutableStateOf(false) }
    var didOfferProgramBuilder by remember { mutableStateOf(false) }
    var customExerciseEditor by remember { mutableStateOf(false) }
    var exerciseDetail by remember {
        mutableStateOf<Pair<StrengthExerciseRow, List<StrengthExerciseHistoryPoint>>?>(null)
    }
    var starting by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<StrengthSessionSnapshot?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var exerciseGuideId by rememberSaveable { mutableStateOf(initialGuideExerciseId) }
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { target ->
            (
                editor == null &&
                    exerciseGuideId == null &&
                    routineEditor == null &&
                    !programBuilder &&
                    !customExerciseEditor
                ) || target != SheetValue.Hidden
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
            val loadedExercises = loaded[0] as List<StrengthExerciseRow>
            @Suppress("UNCHECKED_CAST")
            val loadedRoutines = loaded[1] as List<StrengthRoutineSnapshot>
            @Suppress("UNCHECKED_CAST")
            val loadedSessions = loaded[2] as List<StrengthSessionSnapshot>
            summary = loaded[3] as StrengthSummary
            exercises = loadedExercises
            routines = loadedRoutines
            sessions = loadedSessions
            errorMessage = null
            if (
                loadedExercises.isNotEmpty() &&
                loadedRoutines.isEmpty() &&
                loadedSessions.none { it.session.endedAt == null } &&
                !didOfferProgramBuilder
            ) {
                didOfferProgramBuilder = true
                programBuilder = true
            }
        }.onFailure { errorMessage = it.strengthMessage(saveError) }
        loading = false
    }

    fun startSession(routine: StrengthRoutineSnapshot?) {
        if (starting) return
        starting = true
        scope.launch {
            sessions.firstOrNull { it.session.endedAt == null }?.let {
                editor = it
                starting = false
                return@launch
            }
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
            val exerciseById = exercises.associateBy { it.id }
            val routineExercises = routine?.exercises.orEmpty()
            val sets = routineExercises.flatMap { prescription ->
                val exercise = exerciseById[prescription.exerciseId] ?: return@flatMap emptyList()
                val plan = StrengthTrainingContract.exercisePlan(prescription.planJSON)
                val continuesSuperset = plan.supersetGroup?.let { group ->
                    val members = routineExercises.filter {
                        StrengthTrainingContract.exercisePlan(it.planJSON).supersetGroup == group
                    }
                    members.lastOrNull()?.id != prescription.id
                } ?: false
                val planned = StrengthWorkoutPlanner.prescription(
                    exercise = exercise,
                    prescription = prescription,
                    history = sessions,
                )
                planned.sets.mapIndexed { setPosition, target ->
                    StrengthSetRow(
                        id = UUID.randomUUID().toString().lowercase(),
                        sessionId = sessionId,
                        exerciseId = prescription.exerciseId,
                        exercisePosition = prescription.position,
                        setPosition = setPosition,
                        setType = target.setType,
                        reps = target.reps,
                        loadKg = target.loadKg,
                        durationS = target.durationS,
                        restSeconds = StrengthWorkoutPlanner.resolvedRestSeconds(
                            target = target,
                            prescriptionRestSeconds = prescription.restSeconds,
                            continuesSuperset = continuesSuperset,
                        ),
                        createdAt = now,
                        updatedAt = now,
                    )
                }
            }
            val draft = StrengthSessionSnapshot(session, sets)
            editor = draft
            starting = false
            runCatching { vm.repo.saveStrengthSession(session, sets) }
                .onSuccess {
                    if (editor?.session?.id == sessionId) editor = it
                    reloadToken += 1
                }
                .onFailure { errorMessage = it.strengthMessage(saveError) }
            starting = false
        }
    }

    fun startFocusSession(name: String, selectedExercises: List<StrengthExerciseRow>) {
        if (starting || selectedExercises.isEmpty()) return
        starting = true
        scope.launch {
            sessions.firstOrNull { it.session.endedAt == null }?.let {
                editor = it
                starting = false
                return@launch
            }
            val prefs = NoopPrefs.of(context)
            val experience = runCatching {
                StrengthTrainingExperience.valueOf(
                    prefs.getString(
                        STRENGTH_PROFILE_EXPERIENCE,
                        StrengthTrainingExperience.BEGINNER.name,
                    ) ?: StrengthTrainingExperience.BEGINNER.name,
                )
            }.getOrDefault(StrengthTrainingExperience.BEGINNER)
            val style = runCatching {
                StrengthTrainingStyle.valueOf(
                    prefs.getString(
                        STRENGTH_PROFILE_STYLE,
                        StrengthTrainingStyle.BALANCED.name,
                    ) ?: StrengthTrainingStyle.BALANCED.name,
                )
            }.getOrDefault(StrengthTrainingStyle.BALANCED)
            val minutes = prefs.getInt(STRENGTH_PROFILE_SESSION_MINUTES, 45)
            val templates = StrengthAdaptivePlanner.focusWorkout(
                exercises = selectedExercises,
                experience = experience,
                style = style,
                sessionMinutes = minutes,
            )
            val now = Instant.now().epochSecond
            val sessionId = UUID.randomUUID().toString().lowercase()
            val session = StrengthSessionRow(
                id = sessionId,
                name = name,
                startedAt = now,
                createdAt = now,
                updatedAt = now,
            )
            val exerciseById = selectedExercises.associateBy { it.id }
            val sets = templates.flatMapIndexed { position, template ->
                val exercise = exerciseById[template.exerciseId] ?: return@flatMapIndexed emptyList()
                val prescription = StrengthRoutineExerciseRow(
                    id = "focus-$sessionId-$position",
                    routineId = "focus-$sessionId",
                    exerciseId = template.exerciseId,
                    position = position,
                    targetSets = template.targetSets,
                    targetRepsMin = template.targetRepsMin,
                    targetRepsMax = template.targetRepsMax,
                    targetRPE = template.targetRPE,
                    restSeconds = template.restSeconds,
                    planJSON = checkNotNull(
                        StrengthTrainingContract.encodeExercisePlan(template.plan),
                    ),
                    createdAt = now,
                    updatedAt = now,
                )
                val planned = StrengthWorkoutPlanner.prescription(
                    exercise = exercise,
                    prescription = prescription,
                    history = sessions,
                )
                planned.sets.mapIndexed { setPosition, target ->
                    StrengthSetRow(
                        id = UUID.randomUUID().toString().lowercase(),
                        sessionId = sessionId,
                        exerciseId = template.exerciseId,
                        exercisePosition = position,
                        setPosition = setPosition,
                        setType = target.setType,
                        reps = target.reps,
                        loadKg = target.loadKg,
                        durationS = target.durationS,
                        restSeconds = StrengthWorkoutPlanner.resolvedRestSeconds(
                            target = target,
                            prescriptionRestSeconds = template.restSeconds,
                            continuesSuperset = false,
                        ),
                        createdAt = now,
                        updatedAt = now,
                    )
                }
            }
            val draft = StrengthSessionSnapshot(session, sets)
            editor = draft
            starting = false
            runCatching { vm.repo.saveStrengthSession(session, sets) }
                .onSuccess {
                    if (editor?.session?.id == sessionId) editor = it
                    reloadToken += 1
                }
                .onFailure { errorMessage = it.strengthMessage(saveError) }
            starting = false
        }
    }

    val exerciseGuide = exerciseGuideId?.let { id ->
        exercises.firstOrNull { it.id == id }
    }

    ModalBottomSheet(
        onDismissRequest = {
            if (exerciseGuideId != null) {
                exerciseGuideId = null
            } else if (
                editor == null &&
                routineEditor == null &&
                !programBuilder &&
                !customExerciseEditor
            ) {
                onDismiss()
            }
        },
        sheetState = sheetState,
        containerColor = Palette.surfaceBase,
        dragHandle = null,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(if (exerciseGuide == null) 0.96f else 1f)
        ) {
            LiquidScreenSky(fillHeight = true)
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 24.dp),
            ) {
                if (
                    editor == null &&
                    exerciseGuide == null &&
                    exerciseDetail == null &&
                    routineEditor == null &&
                    !programBuilder &&
                    !customExerciseEditor
                ) {
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
                        onStartFocus = ::startFocusSession,
                        onEdit = { editor = it },
                        onExercise = { exercise, history -> exerciseDetail = exercise to history },
                        onDelete = { deleteCandidate = it },
                        onNewRoutine = { routineEditor = StrengthRoutineEditorTarget(null) },
                        onBuildProgram = { programBuilder = true },
                        onEditRoutine = { routineEditor = StrengthRoutineEditorTarget(it) },
                        onCreateExercise = { customExerciseEditor = true },
                        onGuide = { exerciseGuideId = it.id },
                        onClose = onDismiss,
                    )
                } else if (exerciseGuide != null) {
                    StrengthExerciseGuidePanel(
                        exercise = exerciseGuide,
                        onClose = { exerciseGuideId = null },
                    )
                } else if (routineEditor != null) {
                    StrengthRoutineEditor(
                        vm = vm,
                        initial = routineEditor!!.initial,
                        exercises = exercises,
                        massUnit = massUnit,
                        onClose = {
                            routineEditor = null
                            reloadToken += 1
                        },
                    )
                } else if (programBuilder) {
                    StrengthProgramBuilder(
                        vm = vm,
                        routines = routines,
                        onClose = {
                            programBuilder = false
                            reloadToken += 1
                        },
                    )
                } else if (customExerciseEditor) {
                    StrengthCustomExerciseEditor(
                        vm = vm,
                        onClose = {
                            customExerciseEditor = false
                            reloadToken += 1
                        },
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
                        history = sessions,
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

    if (errorMessage != null && exercises.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    stringResource(R.string.strength_title),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            },
            text = {
                Text(
                    errorMessage.orEmpty(),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) {
                    Text(
                        stringResource(R.string.strength_done),
                        color = Palette.effortColor,
                    )
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
    onStartFocus: (String, List<StrengthExerciseRow>) -> Unit,
    onEdit: (StrengthSessionSnapshot) -> Unit,
    onExercise: (StrengthExerciseRow, List<StrengthExerciseHistoryPoint>) -> Unit,
    onDelete: (StrengthSessionSnapshot) -> Unit,
    onNewRoutine: () -> Unit,
    onBuildProgram: () -> Unit,
    onEditRoutine: (StrengthRoutineSnapshot) -> Unit,
    onCreateExercise: () -> Unit,
    onGuide: (StrengthExerciseRow) -> Unit,
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
    var selectedTab by rememberSaveable { mutableStateOf(StrengthGymTab.TODAY) }
    var libraryQuery by rememberSaveable { mutableStateOf("") }
    var libraryMuscle by rememberSaveable { mutableStateOf("all") }
    var libraryEquipment by rememberSaveable { mutableStateOf("all") }
    var bodyMapMode by rememberSaveable { mutableStateOf(StrengthBodyMapMode.LOAD) }
    var selectedFocusMuscles by rememberSaveable {
        mutableStateOf(emptyList<String>())
    }
    var selectedFocusExerciseIds by rememberSaveable {
        mutableStateOf(emptySet<String>())
    }
    val profileMinutes = prefs.getInt(STRENGTH_PROFILE_SESSION_MINUTES, 45)
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
    val muscleStatuses = remember(exercises, sessions) {
        StrengthProgressCalculator.muscleStatus(
            exercises = exercises,
            sessions = sessions,
            now = Instant.now().epochSecond,
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
        StrengthGymTabs(selected = selectedTab, onSelect = { selectedTab = it })
        Column(
            modifier = Modifier
                .weight(1f)
                .clipToBounds()
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
                    if (selectedTab == StrengthGymTab.TODAY) {
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

                        StrengthTodaySchedule(
                            routines = routines,
                            exercises = exercises,
                            history = sessions,
                            active = active,
                            starting = starting,
                            massUnit = massUnit,
                            onStart = onStart,
                            onOpenPlan = {
                                if (routines.isEmpty()) {
                                    onBuildProgram()
                                } else {
                                    selectedTab = StrengthGymTab.PLAN
                                }
                            },
                            onGuide = onGuide,
                        )

                        StrengthMuscleCoach(
                            exercises = exercises,
                            statuses = muscleStatuses,
                            mode = bodyMapMode,
                            selectedMuscles = selectedFocusMuscles,
                            selectedExerciseIds = selectedFocusExerciseIds,
                            sessionMinutes = profileMinutes,
                            active = active,
                            starting = starting,
                            onMode = { bodyMapMode = it },
                            onMuscle = { muscle ->
                                selectedFocusMuscles =
                                    if (muscle in selectedFocusMuscles) {
                                        selectedFocusMuscles - muscle
                                    } else {
                                        selectedFocusMuscles + muscle
                                    }
                                val limit = when {
                                    profileMinutes <= 30 -> 3
                                    profileMinutes <= 45 -> 4
                                    profileMinutes <= 60 -> 5
                                    else -> 6
                                }
                                val candidates = strengthFocusExercises(
                                    selectedFocusMuscles,
                                    exercises,
                                )
                                val candidateIds = candidates.mapTo(mutableSetOf()) { it.id }
                                val retained = selectedFocusExerciseIds.intersect(candidateIds)
                                selectedFocusExerciseIds = retained + candidates
                                    .asSequence()
                                    .map { it.id }
                                    .filterNot { it in retained }
                                    .take((limit - retained.size).coerceAtLeast(0))
                                    .toSet()
                            },
                            onToggleExercise = { id ->
                                selectedFocusExerciseIds =
                                    if (id in selectedFocusExerciseIds) {
                                        selectedFocusExerciseIds - id
                                    } else {
                                        selectedFocusExerciseIds + id
                                    }
                            },
                            onGuide = onGuide,
                            onStart = { name, selected -> onStartFocus(name, selected) },
                            onResume = onEdit,
                        )

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

                        SectionHeader(
                            stringResource(R.string.appwide_gym_this_week),
                            overline = stringResource(R.string.appwide_gym_your_goals),
                        )
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
                    }

                    if (selectedTab == StrengthGymTab.PROGRESS) {
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
                            if (summary.loadedVolumeSetCount == 0) "-"
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

                        SectionHeader(
                            stringResource(R.string.appwide_strength_muscle_map),
                            overline = stringResource(R.string.appwide_gym_working_set_exposure),
                        )
                        StrengthMuscleMap(muscleFocus)
                    }

                    if (selectedTab == StrengthGymTab.PLAN) {
                        StrengthWeekSchedule(routines)
                        NoopButton(
                            text = stringResource(R.string.strength_build_smart_plan),
                            leadingIcon = Icons.Filled.FitnessCenter,
                            fullWidth = true,
                            onClick = onBuildProgram,
                        )
                        NoopButton(
                            text = stringResource(R.string.appwide_gym_new_routine),
                            leadingIcon = Icons.Filled.Add,
                            fullWidth = true,
                            onClick = onNewRoutine,
                        )
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
                                            .clickable { onEditRoutine(routine) }
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
                                        Icon(
                                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                            contentDescription = null,
                                            tint = Palette.textTertiary,
                                        )
                                    }
                                    if (index < routines.lastIndex) HorizontalDivider(color = Palette.hairline)
                                }
                            }
                        }
                        }
                    }

                    if (selectedTab == StrengthGymTab.PROGRESS) {
                        SectionHeader(
                        stringResource(R.string.appwide_strength_exercise_records),
                        overline = stringResource(R.string.appwide_gym_history_and_prs),
                        trailing = exerciseRows.size.takeIf { it > 0 }?.toString(),
                    )
                        if (exerciseRows.isEmpty()) {
                        ScreenStateCard(
                            kind = ScreenStateKind.Empty,
                            title = stringResource(R.string.appwide_strength_no_exercise_records),
                            body = stringResource(R.string.appwide_gym_finish_workout_records),
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
                    }

                    if (selectedTab == StrengthGymTab.TODAY) {
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
                    }

                    if (selectedTab == StrengthGymTab.LIBRARY) {
                        StrengthExerciseLibrary(
                            exercises = exercises,
                            query = libraryQuery,
                            selectedMuscle = libraryMuscle,
                            selectedEquipment = libraryEquipment,
                            onQuery = { libraryQuery = it },
                            onMuscle = { libraryMuscle = it },
                            onEquipment = { libraryEquipment = it },
                            onCreate = onCreateExercise,
                            onGuide = onGuide,
                        )
                    }

                    if (selectedTab == StrengthGymTab.PROGRESS) {
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

}

@Composable
private fun StrengthExerciseGuidePanel(
    exercise: StrengthExerciseRow,
    onClose: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(
                onClick = onClose,
                modifier = Modifier.size(44.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.strength_done),
                    tint = Palette.textPrimary,
                )
            }
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(top = 12.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    strengthExerciseName(exercise),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
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
            StrengthExerciseMotionView(
                exercise = exercise,
                showsTechniqueButton = false,
                presentation = StrengthExerciseMediaPresentation.DETAIL,
                modifier = Modifier.fillMaxWidth(),
            )
            SectionHeader(
                stringResource(R.string.strength_form_info),
                overline = stringResource(R.string.strength_exercise_guide),
            )
            StrengthExerciseTechnique(exercise = exercise)
        }
    }
}

@Composable
private fun StrengthGymTabs(
    selected: StrengthGymTab,
    onSelect: (StrengthGymTab) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 12.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        StrengthGymTab.entries.forEach { tab ->
            TextButton(
                onClick = { onSelect(tab) },
                modifier = Modifier
                    .weight(1f)
                    .testTag("noop.strength.tab.${tab.name.lowercase()}")
                    .clip(RoundedCornerShape(6.dp))
                    .background(
                        if (selected == tab) Palette.surfaceOverlay else Color.Transparent,
                    ),
            ) {
                Text(
                    stringResource(tab.labelRes),
                    style = NoopType.caption,
                    color = if (selected == tab) Palette.textPrimary else Palette.textSecondary,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun StrengthMuscleCoach(
    exercises: List<StrengthExerciseRow>,
    statuses: List<StrengthMuscleStatus>,
    mode: StrengthBodyMapMode,
    selectedMuscles: List<String>,
    selectedExerciseIds: Set<String>,
    sessionMinutes: Int,
    active: StrengthSessionSnapshot?,
    starting: Boolean,
    onMode: (StrengthBodyMapMode) -> Unit,
    onMuscle: (String) -> Unit,
    onToggleExercise: (String) -> Unit,
    onGuide: (StrengthExerciseRow) -> Unit,
    onStart: (String, List<StrengthExerciseRow>) -> Unit,
    onResume: (StrengthSessionSnapshot) -> Unit,
) {
    val matching = remember(selectedMuscles, exercises) {
        strengthFocusExercises(selectedMuscles, exercises)
    }
    val selected = matching.filter { it.id in selectedExerciseIds }
    val status = selectedMuscles.singleOrNull()?.let { muscle ->
        statuses.firstOrNull { it.muscle == muscle }
    }
    SectionHeader(
        stringResource(R.string.strength_train_by_muscle),
        overline = stringResource(R.string.strength_load_and_recovery),
    )
    NoopCard(tint = Palette.effortColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Palette.surfaceInset)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                listOf(
                    StrengthBodyMapMode.LOAD to stringResource(R.string.strength_body_load),
                    StrengthBodyMapMode.RECOVERY to stringResource(R.string.strength_body_recovery),
                ).forEach { (item, label) ->
                    TextButton(
                        onClick = { onMode(item) },
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(
                                if (mode == item) Palette.surfaceOverlay else Color.Transparent,
                            ),
                    ) {
                        Text(
                            label,
                            style = NoopType.caption,
                            color = if (mode == item) {
                                Palette.textPrimary
                            } else {
                                Palette.textSecondary
                            },
                        )
                    }
                }
            }

            StrengthBodyMapView(
                statuses = statuses,
                mode = mode,
                selectedMuscles = selectedMuscles.toSet(),
                onSelect = onMuscle,
            )

            if (selectedMuscles.isEmpty()) {
                Text(
                    stringResource(R.string.strength_select_muscle_prompt),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    modifier = Modifier.fillMaxWidth(),
                )
                return@Column
            }

            HorizontalDivider(color = Palette.hairline)
            val muscleLabel = selectedMuscles
                .map { muscle -> strengthDescriptor(muscle) }
                .joinToString(" + ")
            val focusSessionName = stringResource(
                R.string.strength_focus_session_name,
                muscleLabel,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    muscleLabel,
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                status?.let {
                    Text(
                        if (mode == StrengthBodyMapMode.LOAD) {
                            stringResource(
                                R.string.strength_body_weighted_sets,
                                it.sevenDayExposure,
                            )
                        } else {
                            stringResource(
                                R.string.strength_body_recovered,
                                (it.recoveryScore * 100).roundToInt(),
                            )
                        },
                        style = NoopType.captionNumber,
                        color = Palette.textSecondary,
                    )
                }
            }
            Text(
                stringResource(
                    if (mode == StrengthBodyMapMode.LOAD) {
                        R.string.strength_body_load_explanation
                    } else {
                        R.string.strength_body_recovery_explanation
                    },
                ),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )

            matching.take(6).forEach { exercise ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onToggleExercise(exercise.id) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = exercise.id in selectedExerciseIds,
                        onCheckedChange = { onToggleExercise(exercise.id) },
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
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
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    }
                    IconButton(onClick = { onGuide(exercise) }) {
                        Icon(
                            Icons.Filled.FitnessCenter,
                            contentDescription = stringResource(R.string.strength_exercise_guide),
                            tint = Palette.effortColor,
                        )
                    }
                }
            }

            NoopButton(
                text = if (active == null) {
                    stringResource(R.string.strength_start_focus, selected.size)
                } else {
                    stringResource(R.string.strength_resume_active)
                },
                leadingIcon = if (active == null) Icons.Filled.PlayArrow else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                fullWidth = true,
                enabled = !starting && (active != null || selected.isNotEmpty()),
            ) {
                if (active != null) {
                    onResume(active)
                } else {
                    onStart(focusSessionName, selected)
                }
            }

            Text(
                stringResource(
                    R.string.strength_focus_duration_profile,
                    sessionMinutes,
                ),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

private fun strengthFocusExercises(
    muscles: List<String>,
    exercises: List<StrengthExerciseRow>,
): List<StrengthExerciseRow> {
    if (muscles.isEmpty()) return emptyList()
    val rankedByMuscle = muscles.map { muscle ->
        exercises.filter { exercise ->
            exercise.primaryMuscle == muscle ||
                StrengthTrainingContract.secondaryMuscles(exercise.secondaryMusclesJSON)
                    .orEmpty()
                    .contains(muscle)
        }.sortedWith(
            compareByDescending<StrengthExerciseRow> { it.primaryMuscle == muscle }
                .thenBy { it.isCustom }
                .thenBy { it.name },
        )
    }
    val interleaved = mutableListOf<StrengthExerciseRow>()
    val seen = mutableSetOf<String>()
    for (rank in 0 until (rankedByMuscle.maxOfOrNull { it.size } ?: 0)) {
        for (candidates in rankedByMuscle) {
            candidates.getOrNull(rank)?.let { exercise ->
                if (seen.add(exercise.id)) interleaved += exercise
            }
        }
    }
    return interleaved
}

@Composable
private fun StrengthTodaySchedule(
    routines: List<StrengthRoutineSnapshot>,
    exercises: List<StrengthExerciseRow>,
    history: List<StrengthSessionSnapshot>,
    active: StrengthSessionSnapshot?,
    starting: Boolean,
    massUnit: MassUnit,
    onStart: (StrengthRoutineSnapshot?) -> Unit,
    onOpenPlan: () -> Unit,
    onGuide: (StrengthExerciseRow) -> Unit,
) {
    val today = LocalDate.now()
    val recommendation = remember(today, routines, history) {
        strengthAdaptiveRecommendation(today, routines, history)
    }
    val routine = recommendation.routineId?.let { routineId ->
        routines.firstOrNull { it.routine.id == routineId }
    }
    SectionHeader(
        stringResource(R.string.appwide_gym_todays_training),
        overline = today.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault()),
    )
    if (recommendation.reason == StrengthDayRecommendationReason.COMPLETED) {
        NoopCard(tint = Palette.statusPositive) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = Palette.statusPositive,
                )
                Spacer(Modifier.width(12.dp))
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        stringResource(R.string.strength_today_complete_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.strength_today_complete_body),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
    } else if (routine == null) {
        NoopCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Palette.restColor)
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        stringResource(R.string.appwide_gym_no_routine_scheduled),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.appwide_gym_no_routine_scheduled_body),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
                TextButton(onClick = onOpenPlan) {
                    Text(stringResource(R.string.appwide_gym_plan), color = Palette.effortColor)
                }
            }
        }
    } else {
        val plans = strengthTodayPlans(routine, exercises, history)
        val totalSets = plans.sumOf { it.workout.sets.size }
        val minutes = ((strengthEstimatedDurationSeconds(plans) + 59) / 60).coerceAtLeast(1)
        val muscles = plans
            .map { strengthDescriptor(it.exercise.primaryMuscle) }
            .distinct()
        NoopCard(tint = Palette.effortColor) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(42.dp)
                            .clip(CircleShape)
                            .background(Palette.effortColor.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Filled.FitnessCenter,
                            contentDescription = null,
                            tint = Palette.effortColor,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(
                            routine.routine.name,
                            style = NoopType.title2,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(
                                R.string.strength_today_summary,
                                plans.size,
                                totalSets,
                                minutes,
                            ),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                }

                if (
                    recommendation.reason == StrengthDayRecommendationReason.MAKE_UP &&
                    recommendation.originallyScheduledDateKey != null
                ) {
                    Text(
                        stringResource(
                            R.string.strength_make_up_label,
                            strengthDisplayDateKey(recommendation.originallyScheduledDateKey),
                        ),
                        style = NoopType.footnote,
                        color = Palette.statusWarning,
                    )
                }

                if (muscles.isNotEmpty()) {
                    Text(
                        stringResource(
                            R.string.strength_plan_muscles,
                            muscles.joinToString(" · "),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }

                HorizontalDivider(color = Palette.hairline)

                plans.forEachIndexed { index, plan ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(30.dp)
                                .clip(CircleShape)
                                .background(Palette.surfaceInset),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                (index + 1).toString(),
                                style = NoopType.number(15f),
                                color = Palette.effortColor,
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(
                                strengthExerciseName(plan.exercise),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                strengthTodayTargetLabel(plan, massUnit),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                            Text(
                                strengthDescriptor(plan.exercise.primaryMuscle),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                        }
                        IconButton(onClick = { onGuide(plan.exercise) }) {
                            Icon(
                                Icons.Filled.FitnessCenter,
                                contentDescription = stringResource(
                                    R.string.strength_play_guide,
                                ),
                                tint = Palette.effortColor,
                            )
                        }
                    }
                    if (index < plans.lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(start = 42.dp),
                            color = Palette.hairline,
                        )
                    }
                }

                NoopButton(
                    text = stringResource(R.string.strength_start_today_workout),
                    leadingIcon = Icons.Filled.PlayArrow,
                    fullWidth = true,
                    enabled = active == null && !starting,
                ) { onStart(routine) }
            }
        }
    }
}

private fun strengthAdaptiveRecommendation(
    today: LocalDate,
    routines: List<StrengthRoutineSnapshot>,
    history: List<StrengthSessionSnapshot>,
) = StrengthAdaptivePlanner.recommendation(
    today = StrengthScheduleDay(today.toString(), today.dayOfWeek.value),
    previousDaysNearestFirst = (1..StrengthAdaptivePlanner.MAXIMUM_MAKE_UP_AGE_DAYS).map { offset ->
        val day = today.minusDays(offset.toLong())
        StrengthScheduleDay(day.toString(), day.dayOfWeek.value)
    },
    routines = routines,
    completions = history.mapNotNull { item ->
        val routineId = item.session.routineId
        if (item.session.endedAt == null || routineId == null) {
            null
        } else {
            StrengthRoutineCompletion(
                dateKey = Instant.ofEpochSecond(item.session.startedAt)
                    .atZone(ZoneId.systemDefault())
                    .toLocalDate()
                    .toString(),
                routineId = routineId,
            )
        }
    },
)

private fun strengthDisplayDateKey(key: String): String =
    runCatching {
        LocalDate.parse(key).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
    }.getOrDefault(key)

private fun strengthTodayPlans(
    routine: StrengthRoutineSnapshot,
    exercises: List<StrengthExerciseRow>,
    history: List<StrengthSessionSnapshot>,
): List<StrengthTodayExercisePlan> =
    routine.exercises.sortedBy { it.position }.mapNotNull { prescription ->
        val exercise = exercises.firstOrNull { it.id == prescription.exerciseId }
            ?: return@mapNotNull null
        StrengthTodayExercisePlan(
            prescription = prescription,
            exercise = exercise,
            workout = StrengthWorkoutPlanner.prescription(
                exercise = exercise,
                prescription = prescription,
                history = history,
            ),
        )
    }

private fun strengthEstimatedDurationSeconds(plans: List<StrengthTodayExercisePlan>): Int =
    plans.mapIndexed { exerciseIndex, plan ->
        plan.workout.sets.mapIndexed { setIndex, set ->
            val work = set.durationS ?: ((set.reps ?: 8) * 4).coerceIn(20, 75)
            val rest = if (setIndex < plan.workout.sets.lastIndex) {
                set.restSecondsAfter ?: plan.prescription.restSeconds
            } else {
                0
            }
            work + rest
        }.sum() + if (exerciseIndex < plans.lastIndex) 45 else 0
    }.sum()

@Composable
private fun strengthTodayTargetLabel(
    plan: StrengthTodayExercisePlan,
    massUnit: MassUnit,
): String {
    val working = plan.workout.sets.filter { it.setType != "warmup" }
    val representative = working.firstOrNull() ?: plan.workout.sets.firstOrNull()
        ?: return stringResource(R.string.strength_no_planned_sets)
    val warmups = plan.workout.sets.size - working.size
    val warmupSuffix = if (warmups > 0) {
        " · $warmups ${
            stringResource(R.string.strength_set_type_warmup).lowercase(Locale.getDefault())
        }"
    } else {
        ""
    }
    representative.durationS?.let { seconds ->
        return stringResource(
            R.string.strength_plan_target_time,
            working.size,
            seconds,
        ) + warmupSuffix
    }
    val reps = representative.reps ?: plan.prescription.targetRepsMin ?: 8
    representative.loadKg?.let { loadKg ->
        return stringResource(
            R.string.strength_plan_target_reps,
            working.size,
            reps,
        ) + " · " + UnitFormatter.massFromKilograms(loadKg, massUnit) + warmupSuffix
    }
    return stringResource(
        R.string.strength_plan_target_reps,
        working.size,
        reps,
    ) + warmupSuffix
}

@Composable
private fun StrengthWeekSchedule(routines: List<StrengthRoutineSnapshot>) {
    SectionHeader(
        stringResource(R.string.appwide_gym_week_schedule),
        overline = stringResource(R.string.appwide_gym_repeatable_plan),
    )
    NoopCard(padding = 0.dp) {
        Column {
            (1..7).forEach { day ->
                val assigned = routines.filter {
                    day in StrengthTrainingContract.scheduledWeekdays(it.routine.scheduledWeekdaysJSON)
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        DayOfWeek.of(day).getDisplayName(TextStyle.FULL, Locale.getDefault()),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        modifier = Modifier.width(96.dp),
                    )
                    Text(
                        if (assigned.isEmpty()) {
                            stringResource(R.string.appwide_gym_rest)
                        } else {
                            assigned.joinToString(" · ") { it.routine.name }
                        },
                        style = NoopType.footnote,
                        color = if (assigned.isEmpty()) Palette.textTertiary else Palette.effortColor,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (day < 7) HorizontalDivider(color = Palette.hairline)
            }
        }
    }
}

@Composable
private fun StrengthExerciseLibrary(
    exercises: List<StrengthExerciseRow>,
    query: String,
    selectedMuscle: String,
    selectedEquipment: String,
    onQuery: (String) -> Unit,
    onMuscle: (String) -> Unit,
    onEquipment: (String) -> Unit,
    onCreate: () -> Unit,
    onGuide: (StrengthExerciseRow) -> Unit,
) {
    val filtered = exercises.filter { exercise ->
        (
            query.isBlank() ||
                exercise.name.contains(query, ignoreCase = true) ||
                exercise.primaryMuscle.contains(query, ignoreCase = true) ||
                exercise.equipment.contains(query, ignoreCase = true)
            ) &&
            (selectedMuscle == "all" || exercise.primaryMuscle == selectedMuscle) &&
            (selectedEquipment == "all" || exercise.equipment == selectedEquipment)
    }
    SectionHeader(
        stringResource(R.string.appwide_gym_exercise_library),
        overline = stringResource(R.string.appwide_gym_search_and_filter),
        trailing = filtered.size.toString(),
    )
    OutlinedTextField(
        value = query,
        onValueChange = onQuery,
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        label = { Text(stringResource(R.string.strength_search_exercises)) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StrengthFilterMenu(
            label = if (selectedMuscle == "all") {
                stringResource(R.string.appwide_gym_all_muscles)
            } else {
                strengthDescriptor(selectedMuscle)
            },
            options = listOf("all" to stringResource(R.string.appwide_gym_all_muscles)) +
                StrengthTrainingContract.MUSCLES.sorted().map { it to strengthDescriptor(it) },
            selected = selectedMuscle,
            onSelected = onMuscle,
            modifier = Modifier.weight(1f),
        )
        StrengthFilterMenu(
            label = if (selectedEquipment == "all") {
                stringResource(R.string.appwide_gym_any_equipment)
            } else {
                strengthDescriptor(selectedEquipment)
            },
            options = listOf("all" to stringResource(R.string.appwide_gym_any_equipment)) +
                StrengthTrainingContract.EQUIPMENT.sorted().map { it to strengthDescriptor(it) },
            selected = selectedEquipment,
            onSelected = onEquipment,
            modifier = Modifier.weight(1f),
        )
    }
    NoopButton(
        text = stringResource(R.string.appwide_gym_create_exercise),
        leadingIcon = Icons.Filled.Add,
        fullWidth = true,
        onClick = onCreate,
    )
    if (filtered.isEmpty()) {
        ScreenStateCard(
            kind = ScreenStateKind.Empty,
            title = stringResource(R.string.appwide_gym_no_matching_exercises),
            body = stringResource(R.string.appwide_gym_no_matching_exercises_body),
        )
    } else {
        filtered.forEach { exercise ->
            NoopCard(modifier = Modifier.clickable { onGuide(exercise) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StrengthExerciseThumbnail(
                        exercise = exercise,
                        modifier = Modifier.size(52.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(strengthExerciseName(exercise), style = NoopType.headline, color = Palette.textPrimary)
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
                    if (exercise.isCustom) {
                        Text(
                            stringResource(R.string.appwide_gym_custom),
                            style = NoopType.caption,
                            color = Palette.accent,
                        )
                    } else {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = Palette.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StrengthFilterMenu(
    label: String,
    options: List<Pair<String, String>>,
    selected: String,
    onSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        TextButton(
            onClick = { expanded = true },
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(7.dp))
                .background(Palette.surfaceInset),
        ) {
            Text(label, style = NoopType.footnote, color = Palette.textPrimary, maxLines = 1)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (value, display) ->
                DropdownMenuItem(
                    text = {
                        Text(
                            if (value == selected) {
                                stringResource(R.string.strength_selected_option, display)
                            } else {
                                display
                            },
                        )
                    },
                    onClick = {
                        expanded = false
                        onSelected(value)
                    },
                )
            }
        }
    }
}

@Composable
private fun StrengthProgramBuilder(
    vm: AppViewModel,
    routines: List<StrengthRoutineSnapshot>,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val profilePrefs = remember(context) { NoopPrefs.of(context) }
    val storedDayCount = remember(profilePrefs) {
        profilePrefs.getInt(STRENGTH_PROFILE_DAY_COUNT, 3).coerceIn(2, 6)
    }
    val storedDays = remember(profilePrefs, storedDayCount) {
        profilePrefs.getStringSet(STRENGTH_PROFILE_WEEKDAYS, emptySet())
            .orEmpty()
            .mapNotNull(String::toIntOrNull)
            .filter { it in 1..7 }
            .toSet()
            .takeIf { it.size == storedDayCount }
            ?: StrengthAdaptivePlanner.suggestedWeekdays(storedDayCount).toSet()
    }
    val storedFocusMuscles = remember(profilePrefs) {
        profilePrefs.getStringSet(STRENGTH_PROFILE_FOCUS_MUSCLES, emptySet())
            .orEmpty()
            .filter { it in StrengthProgressCalculator.BODY_MAP_MUSCLES }
            .take(2)
            .toSet()
    }
    var dayCount by rememberSaveable { mutableIntStateOf(storedDayCount) }
    var selectedDays by rememberSaveable {
        mutableStateOf(storedDays)
    }
    var experience by rememberSaveable {
        mutableStateOf(
            runCatching {
                StrengthTrainingExperience.valueOf(
                    profilePrefs.getString(
                        STRENGTH_PROFILE_EXPERIENCE,
                        StrengthTrainingExperience.BEGINNER.name,
                    ) ?: StrengthTrainingExperience.BEGINNER.name,
                )
            }.getOrDefault(StrengthTrainingExperience.BEGINNER),
        )
    }
    var trainingStyle by rememberSaveable {
        mutableStateOf(
            runCatching {
                StrengthTrainingStyle.valueOf(
                    profilePrefs.getString(
                        STRENGTH_PROFILE_STYLE,
                        StrengthTrainingStyle.BALANCED.name,
                    ) ?: StrengthTrainingStyle.BALANCED.name,
                )
            }.getOrDefault(StrengthTrainingStyle.BALANCED),
        )
    }
    var sessionMinutes by rememberSaveable {
        mutableIntStateOf(profilePrefs.getInt(STRENGTH_PROFILE_SESSION_MINUTES, 45))
    }
    var focusMuscles by rememberSaveable { mutableStateOf(storedFocusMuscles) }
    var focusMenuOpen by remember { mutableStateOf(false) }
    var replaceSchedule by rememberSaveable { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val program = remember(
        selectedDays,
        experience,
        trainingStyle,
        sessionMinutes,
        focusMuscles,
    ) {
        StrengthAdaptivePlanner.program(
            StrengthProgramRequest(
                weekdays = selectedDays.toList(),
                experience = experience,
                style = trainingStyle,
                sessionMinutes = sessionMinutes,
                focusMuscles = focusMuscles.toList(),
            ),
        )
    }
    val adaptiveNote = stringResource(R.string.strength_adaptive_plan_note)
    val saveError = stringResource(R.string.strength_plan_build_failed)
    val focusMuscleLabels = mutableListOf<String>()
    for (muscle in focusMuscles.sorted()) {
        focusMuscleLabels += strengthDescriptor(muscle)
    }

    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose, enabled = !saving) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.strength_close_plan_builder),
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.strength_build_training_week),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.strength_build_training_week_body),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
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
                stringResource(R.string.strength_about_training),
                overline = stringResource(R.string.strength_starting_point),
            )
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StrengthFilterMenu(
                        label = stringResource(
                            when (experience) {
                                StrengthTrainingExperience.BEGINNER ->
                                    R.string.strength_experience_beginner
                                StrengthTrainingExperience.INTERMEDIATE ->
                                    R.string.strength_experience_intermediate
                                StrengthTrainingExperience.EXPERIENCED ->
                                    R.string.strength_experience_experienced
                            },
                        ),
                        options = listOf(
                            StrengthTrainingExperience.BEGINNER.name to
                                stringResource(R.string.strength_experience_beginner),
                            StrengthTrainingExperience.INTERMEDIATE.name to
                                stringResource(R.string.strength_experience_intermediate),
                            StrengthTrainingExperience.EXPERIENCED.name to
                                stringResource(R.string.strength_experience_experienced),
                        ),
                        selected = experience.name,
                        onSelected = { raw ->
                            experience = StrengthTrainingExperience.valueOf(raw)
                            profilePrefs.edit()
                                .putString(STRENGTH_PROFILE_EXPERIENCE, experience.name)
                                .apply()
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    StrengthFilterMenu(
                        label = stringResource(
                            when (trainingStyle) {
                                StrengthTrainingStyle.BALANCED ->
                                    R.string.strength_style_balanced
                                StrengthTrainingStyle.STRENGTH ->
                                    R.string.strength_style_strength
                                StrengthTrainingStyle.MUSCLE ->
                                    R.string.strength_style_muscle
                                StrengthTrainingStyle.CONDITIONING ->
                                    R.string.strength_style_conditioning
                            },
                        ),
                        options = listOf(
                            StrengthTrainingStyle.BALANCED.name to
                                stringResource(R.string.strength_style_balanced),
                            StrengthTrainingStyle.STRENGTH.name to
                                stringResource(R.string.strength_style_strength),
                            StrengthTrainingStyle.MUSCLE.name to
                                stringResource(R.string.strength_style_muscle),
                            StrengthTrainingStyle.CONDITIONING.name to
                                stringResource(R.string.strength_style_conditioning),
                        ),
                        selected = trainingStyle.name,
                        onSelected = { raw ->
                            trainingStyle = StrengthTrainingStyle.valueOf(raw)
                            profilePrefs.edit()
                                .putString(STRENGTH_PROFILE_STYLE, trainingStyle.name)
                                .apply()
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )

                    Text(
                        stringResource(R.string.strength_time_per_workout),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(Palette.surfaceInset)
                            .padding(3.dp),
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        listOf(30, 45, 60, 75).forEach { minutes ->
                            TextButton(
                                onClick = {
                                    sessionMinutes = minutes
                                    profilePrefs.edit()
                                        .putInt(STRENGTH_PROFILE_SESSION_MINUTES, minutes)
                                        .apply()
                                },
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(
                                        if (sessionMinutes == minutes) {
                                            Palette.surfaceOverlay
                                        } else {
                                            Color.Transparent
                                        },
                                    ),
                            ) {
                                Text(
                                    stringResource(
                                        R.string.strength_minutes_short,
                                        minutes,
                                    ),
                                    style = NoopType.captionNumber,
                                    color = if (sessionMinutes == minutes) {
                                        Palette.textPrimary
                                    } else {
                                        Palette.textSecondary
                                    },
                                )
                            }
                        }
                    }

                    Box {
                        TextButton(
                            onClick = { focusMenuOpen = true },
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(7.dp))
                                .background(Palette.surfaceInset),
                        ) {
                            Text(
                                if (focusMuscles.isEmpty()) {
                                    stringResource(R.string.strength_priority_balanced)
                                } else {
                                    focusMuscleLabels.joinToString(", ")
                                },
                                style = NoopType.footnote,
                                color = Palette.textPrimary,
                                maxLines = 1,
                            )
                        }
                        DropdownMenu(
                            expanded = focusMenuOpen,
                            onDismissRequest = { focusMenuOpen = false },
                        ) {
                            StrengthProgressCalculator.BODY_MAP_MUSCLES.forEach { muscle ->
                                val selected = muscle in focusMuscles
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            if (selected) {
                                                stringResource(
                                                    R.string.strength_selected_option,
                                                    strengthDescriptor(muscle),
                                                )
                                            } else {
                                                strengthDescriptor(muscle)
                                            },
                                        )
                                    },
                                    onClick = {
                                        val updated = when {
                                            selected -> focusMuscles - muscle
                                            focusMuscles.size < 2 -> focusMuscles + muscle
                                            else -> focusMuscles
                                        }
                                        focusMuscles = updated
                                        profilePrefs.edit()
                                            .putStringSet(
                                                STRENGTH_PROFILE_FOCUS_MUSCLES,
                                                updated,
                                            )
                                            .apply()
                                    },
                                )
                            }
                        }
                    }
                }
            }

            SectionHeader(
                stringResource(R.string.strength_gym_days),
                overline = stringResource(R.string.strength_two_to_six_sessions),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Palette.surfaceInset)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                (2..6).forEach { count ->
                    TextButton(
                        onClick = {
                            dayCount = count
                            val suggested = StrengthAdaptivePlanner
                                .suggestedWeekdays(count)
                                .toSet()
                            selectedDays = suggested
                            profilePrefs.edit()
                                .putInt(STRENGTH_PROFILE_DAY_COUNT, count)
                                .putStringSet(
                                    STRENGTH_PROFILE_WEEKDAYS,
                                    suggested.map(Int::toString).toSet(),
                                )
                                .apply()
                        },
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(
                                if (dayCount == count) {
                                    Palette.surfaceOverlay
                                } else {
                                    Color.Transparent
                                },
                            ),
                    ) {
                        Text(
                            count.toString(),
                            style = NoopType.number(15f),
                            color = if (dayCount == count) {
                                Palette.textPrimary
                            } else {
                                Palette.textSecondary
                            },
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                (1..7).forEach { day ->
                    val selected = day in selectedDays
                    TextButton(
                        onClick = {
                            val updated = if (selected) {
                                selectedDays - day
                            } else if (selectedDays.size < dayCount) {
                                selectedDays + day
                            } else {
                                selectedDays
                            }
                            selectedDays = updated
                            profilePrefs.edit()
                                .putStringSet(
                                    STRENGTH_PROFILE_WEEKDAYS,
                                    updated.map(Int::toString).toSet(),
                                )
                                .apply()
                        },
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(7.dp))
                            .background(
                                if (selected) Palette.effortColor else Palette.surfaceInset,
                            ),
                    ) {
                        Text(
                            DayOfWeek.of(day)
                                .getDisplayName(TextStyle.NARROW, Locale.getDefault())
                                .uppercase(),
                            style = NoopType.caption,
                            color = if (selected) Color.White else Palette.textSecondary,
                        )
                    }
                }
            }

            if (selectedDays.size != dayCount) {
                Text(
                    stringResource(R.string.strength_choose_exact_days, dayCount),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }

            SectionHeader(
                stringResource(R.string.strength_your_program),
                overline = stringResource(R.string.strength_editable_after_creation),
            )
            program.forEach { template ->
                NoopCard(tint = Palette.effortColor) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            stringResource(
                                R.string.strength_program_day_title,
                                DayOfWeek.of(template.isoWeekday)
                                    .getDisplayName(TextStyle.FULL, Locale.getDefault()),
                                template.name,
                            ),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            template.exercises.joinToString(" · ") { item ->
                                StrengthTrainingContract.BUILT_IN_EXERCISES
                                    .firstOrNull { it.id == item.exerciseId }
                                    ?.let { exercise ->
                                        strengthExerciseNameResource(exercise.id)
                                            ?.let(context::getString)
                                            ?: exercise.name
                                    }
                                    ?: item.exerciseId
                            },
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { replaceSchedule = !replaceSchedule },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = replaceSchedule,
                    onCheckedChange = { replaceSchedule = it },
                )
                Spacer(Modifier.width(8.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        stringResource(R.string.strength_replace_weekday_assignments),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.strength_replace_weekday_assignments_body),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
            }

            NoopButton(
                text = stringResource(R.string.strength_create_day_plan, dayCount),
                leadingIcon = Icons.Filled.Check,
                fullWidth = true,
                enabled = !saving && program.size == dayCount,
            ) {
                saving = true
                scope.launch {
                    runCatching {
                        val now = Instant.now().epochSecond
                        if (replaceSchedule) {
                            routines.forEach { item ->
                                vm.repo.saveStrengthRoutine(
                                    item.routine.copy(
                                        scheduledWeekdaysJSON = null,
                                        updatedAt = now,
                                    ),
                                    item.exercises,
                                )
                            }
                        }
                        program.forEach { template ->
                            val routineId = UUID.randomUUID().toString().lowercase()
                            val routine = StrengthRoutineRow(
                                id = routineId,
                                name = template.name,
                                note = adaptiveNote,
                                scheduledWeekdaysJSON =
                                    StrengthTrainingContract.encodeScheduledWeekdays(
                                        listOf(template.isoWeekday),
                                    ),
                                createdAt = now,
                                updatedAt = now,
                            )
                            val rows = template.exercises.mapIndexed { index, item ->
                                StrengthRoutineExerciseRow(
                                    id = UUID.randomUUID().toString().lowercase(),
                                    routineId = routineId,
                                    exerciseId = item.exerciseId,
                                    position = index,
                                    targetSets = item.targetSets,
                                    targetRepsMin = item.targetRepsMin,
                                    targetRepsMax = item.targetRepsMax,
                                    targetRPE = item.targetRPE,
                                    restSeconds = item.restSeconds,
                                    planJSON = checkNotNull(
                                        StrengthTrainingContract.encodeExercisePlan(item.plan),
                                    ),
                                    createdAt = now,
                                    updatedAt = now,
                                )
                            }
                            vm.repo.saveStrengthRoutine(routine, rows)
                        }
                    }.onSuccess {
                        onClose()
                    }.onFailure {
                        errorMessage = it.strengthMessage(saveError)
                        saving = false
                    }
                }
            }
        }
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    stringResource(R.string.strength_plan_build_failed),
                    style = NoopType.title2,
                )
            },
            text = {
                Text(message, style = NoopType.body, color = Palette.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) {
                    Text(stringResource(R.string.strength_ok), color = Palette.accent)
                }
            },
        )
    }
}

@Composable
private fun StrengthRoutineEditor(
    vm: AppViewModel,
    initial: StrengthRoutineSnapshot?,
    exercises: List<StrengthExerciseRow>,
    massUnit: MassUnit,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val unableSaveRoutine = stringResource(R.string.appwide_gym_unable_save_routine)
    val now = remember { Instant.now().epochSecond }
    val routineId = remember(initial?.routine?.id) {
        initial?.routine?.id ?: UUID.randomUUID().toString().lowercase()
    }
    val createdAt = remember(initial?.routine?.id) { initial?.routine?.createdAt ?: now }
    val exerciseById = remember(exercises) { exercises.associateBy { it.id } }
    var name by remember(initial?.routine?.id) { mutableStateOf(initial?.routine?.name.orEmpty()) }
    var note by remember(initial?.routine?.id) { mutableStateOf(initial?.routine?.note.orEmpty()) }
    var weekdays by remember(initial?.routine?.id) {
        mutableStateOf(
            StrengthTrainingContract
                .scheduledWeekdays(initial?.routine?.scheduledWeekdaysJSON)
                .toSet(),
        )
    }
    var items by remember(initial?.routine?.id, exercises) {
        mutableStateOf(
            initial?.exercises.orEmpty().mapNotNull { row ->
                val exercise = exerciseById[row.exerciseId] ?: return@mapNotNull null
                StrengthRoutineExerciseDraft(
                    id = row.id,
                    exercise = exercise,
                    targetSets = row.targetSets,
                    targetRepsMin = row.targetRepsMin ?: 8,
                    targetRepsMax = row.targetRepsMax ?: row.targetRepsMin ?: 8,
                    targetRPE = row.targetRPE,
                    restSeconds = row.restSeconds,
                    note = row.note.orEmpty(),
                    plan = StrengthTrainingContract.exercisePlan(row.planJSON),
                    createdAt = row.createdAt,
                )
            },
        )
    }
    var exercisePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    fun update(id: String, transform: (StrengthRoutineExerciseDraft) -> StrengthRoutineExerciseDraft) {
        items = items.map { if (it.id == id) transform(it) else it }
    }

    fun move(id: String, offset: Int) {
        val source = items.indexOfFirst { it.id == id }
        if (source < 0) return
        val destination = (source + offset).coerceIn(0, items.lastIndex)
        if (source == destination) return
        val mutable = items.toMutableList()
        val item = mutable.removeAt(source)
        mutable.add(destination, item)
        items = mutable
    }

    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose, enabled = !saving) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.appwide_gym_close_routine_editor),
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    if (initial == null) {
                        stringResource(R.string.appwide_gym_new_routine)
                    } else {
                        name.ifBlank { stringResource(R.string.appwide_gym_edit_routine) }
                    },
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.appwide_gym_routine_editor_subtitle),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
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
            NoopCard(tint = Palette.effortColor) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text(stringResource(R.string.strength_routine_name)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = note,
                        onValueChange = { note = it },
                        label = { Text(stringResource(R.string.appwide_gym_notes_optional)) },
                        minLines = 2,
                        maxLines = 4,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

                SectionHeader(
                    stringResource(R.string.appwide_gym_training_days),
                    overline = stringResource(R.string.appwide_gym_weekly_schedule),
                )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                (1..7).forEach { day ->
                    val selected = day in weekdays
                    TextButton(
                        onClick = {
                            weekdays = if (selected) weekdays - day else weekdays + day
                        },
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(7.dp))
                            .background(
                                if (selected) Palette.effortColor else Palette.surfaceInset,
                            ),
                    ) {
                        Text(
                            DayOfWeek.of(day)
                                .getDisplayName(TextStyle.NARROW, Locale.getDefault())
                                .uppercase(),
                            style = NoopType.caption,
                            color = if (selected) Color.White else Palette.textSecondary,
                        )
                    }
                }
            }

            SectionHeader(
                    stringResource(R.string.appwide_gym_exercises),
                    overline = stringResource(R.string.appwide_gym_ordered_prescription),
                trailing = items.size.takeIf { it > 0 }?.toString(),
            )
            if (items.isEmpty()) {
                ScreenStateCard(
                    kind = ScreenStateKind.Empty,
                    title = stringResource(R.string.appwide_gym_add_first_exercise),
                    body = stringResource(R.string.appwide_gym_add_first_exercise_body),
                )
            } else {
                items.forEach { item ->
                    StrengthRoutineDraftCard(
                        item = item,
                        massUnit = massUnit,
                        onChange = { changed -> update(item.id) { changed } },
                        onMoveUp = { move(item.id, -1) },
                        onMoveDown = { move(item.id, 1) },
                        onRemove = { items = items.filterNot { it.id == item.id } },
                    )
                }
            }
            NoopButton(
                text = stringResource(R.string.strength_add_exercise),
                leadingIcon = Icons.Filled.Add,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
            ) { exercisePicker = true }
            NoopButton(
                text = stringResource(R.string.appwide_gym_save_routine),
                leadingIcon = Icons.Filled.Check,
                fullWidth = true,
                enabled = !saving && name.isNotBlank() && items.isNotEmpty(),
            ) {
                saving = true
                scope.launch {
                    val savedAt = Instant.now().epochSecond
                    val routine = StrengthRoutineRow(
                        id = routineId,
                        name = name.trim(),
                        note = note.trim().takeIf { it.isNotEmpty() },
                        scheduledWeekdaysJSON = StrengthTrainingContract.encodeScheduledWeekdays(
                            weekdays.toList(),
                        ),
                        createdAt = createdAt,
                        updatedAt = savedAt,
                    )
                    val encodedPlans = items.map {
                        StrengthTrainingContract.encodeExercisePlan(it.plan)
                    }
                    if (encodedPlans.any { it == null }) {
                        errorMessage = unableSaveRoutine
                        saving = false
                        return@launch
                    }
                    val rows = items.mapIndexed { position, item ->
                        StrengthRoutineExerciseRow(
                            id = item.id,
                            routineId = routineId,
                            exerciseId = item.exercise.id,
                            position = position,
                            targetSets = item.targetSets,
                            targetRepsMin = if (item.plan.mode == "timed") null else item.targetRepsMin,
                            targetRepsMax = if (item.plan.mode == "timed") {
                                null
                            } else {
                                maxOf(item.targetRepsMin, item.targetRepsMax)
                            },
                            targetRPE = item.targetRPE,
                            restSeconds = item.restSeconds,
                            note = item.note.trim().takeIf { it.isNotEmpty() },
                            planJSON = checkNotNull(encodedPlans[position]),
                            createdAt = item.createdAt,
                            updatedAt = savedAt,
                        )
                    }
                    runCatching { vm.repo.saveStrengthRoutine(routine, rows) }
                        .onSuccess { onClose() }
                        .onFailure {
                            errorMessage = it.strengthMessage(unableSaveRoutine)
                            saving = false
                        }
                }
            }
        }
    }

    if (exercisePicker) {
        StrengthExercisePicker(
            exercises = exercises.filter { exercise -> items.none { it.exercise.id == exercise.id } },
            onDismiss = { exercisePicker = false },
            onPick = { exercise ->
                val created = Instant.now().epochSecond
                val timed = exercise.movementPattern == "cardio"
                items = items + StrengthRoutineExerciseDraft(
                    id = UUID.randomUUID().toString().lowercase(),
                    exercise = exercise,
                    targetSets = if (timed) 1 else 3,
                    targetRepsMin = 8,
                    targetRepsMax = 12,
                    targetRPE = null,
                    restSeconds = if (timed) 0 else 120,
                    note = "",
                    plan = StrengthExercisePlan(
                        mode = if (timed) "timed" else "reps",
                        targetDurationS = if (timed) 1_200 else null,
                        progression = if (timed) "time" else "double_progression",
                    ),
                    createdAt = created,
                )
                exercisePicker = false
            },
        )
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = {
                Text(stringResource(R.string.appwide_gym_routine), style = NoopType.title2)
            },
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
private fun StrengthRoutineDraftCard(
    item: StrengthRoutineExerciseDraft,
    massUnit: MassUnit,
    onChange: (StrengthRoutineExerciseDraft) -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onRemove: () -> Unit,
) {
    val timed = item.plan.mode == "timed" || item.exercise.movementPattern == "cardio"
    val repsLabel = stringResource(R.string.strength_reps)
    val timedLabel = stringResource(R.string.appwide_gym_timed)
    val noRestLabel = stringResource(R.string.appwide_gym_no_rest)
    val manualLabel = stringResource(R.string.appwide_gym_manual)
    val noSupersetLabel = stringResource(R.string.appwide_gym_no_superset)
    NoopCard(tint = Palette.effortColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (timed) Icons.Filled.Timer else Icons.Filled.FitnessCenter,
                    contentDescription = null,
                    tint = Palette.effortColor,
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(strengthExerciseName(item.exercise), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        stringResource(
                            R.string.strength_descriptor_pair,
                            strengthDescriptor(item.exercise.primaryMuscle),
                            strengthDescriptor(item.exercise.equipment),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
                IconButton(onClick = onMoveUp) {
                    Icon(
                        Icons.Filled.KeyboardArrowUp,
                        contentDescription = stringResource(R.string.appwide_gym_move_exercise_up),
                    )
                }
                IconButton(onClick = onMoveDown) {
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = stringResource(R.string.appwide_gym_move_exercise_down),
                    )
                }
                IconButton(onClick = onRemove) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription = stringResource(R.string.appwide_gym_remove_exercise),
                        tint = Palette.statusCritical,
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(7.dp))
                    .background(Palette.surfaceInset)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                listOf("reps" to repsLabel, "timed" to timedLabel).forEach { (value, label) ->
                    TextButton(
                        onClick = {
                            val timedMode = value == "timed" ||
                                item.exercise.movementPattern == "cardio"
                            onChange(
                                item.copy(
                                    plan = item.plan.copy(
                                        mode = if (timedMode) "timed" else "reps",
                                        progression = if (timedMode) {
                                            if (item.plan.progression in setOf("none", "time")) {
                                                item.plan.progression
                                            } else {
                                                "time"
                                            }
                                        } else if (item.plan.progression == "time") {
                                            "double_progression"
                                        } else {
                                            item.plan.progression
                                        },
                                        targetDurationS = if (timedMode) {
                                            item.plan.targetDurationS ?: 30
                                        } else {
                                            null
                                        },
                                    ),
                                ),
                            )
                        },
                        enabled = item.exercise.movementPattern != "cardio" || value == "timed",
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(
                                if (item.plan.mode == value) Palette.surfaceOverlay else Color.Transparent,
                            ),
                    ) {
                        Text(
                            label,
                            style = NoopType.footnote,
                            color = if (item.plan.mode == value) Palette.textPrimary else Palette.textSecondary,
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StrengthPlanNumberField(
                    label = stringResource(R.string.appwide_gym_sets),
                    value = item.targetSets.toString(),
                    keyboard = KeyboardType.Number,
                    modifier = Modifier.weight(1f),
                ) { text ->
                    onChange(item.copy(targetSets = text.toIntOrNull()?.coerceIn(1, 20) ?: 1))
                }
                if (timed) {
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_seconds),
                        value = (item.plan.targetDurationS ?: 30).toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        val value = text.toIntOrNull()?.coerceIn(1, StrengthTrainingContract.MAX_DURATION_SECONDS)
                        onChange(item.copy(plan = item.plan.copy(targetDurationS = value)))
                    }
                } else {
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_min_reps),
                        value = item.targetRepsMin.toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        onChange(item.copy(targetRepsMin = text.toIntOrNull()?.coerceIn(1, 100) ?: 1))
                    }
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_max_reps),
                        value = item.targetRepsMax.toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        onChange(item.copy(targetRepsMax = text.toIntOrNull()?.coerceIn(1, 100) ?: 1))
                    }
                }
            }

            if (!timed) {
                val displayLoad = item.plan.targetLoadKg?.let {
                    if (massUnit == MassUnit.POUNDS) UnitFormatter.kgToPounds(it) else it
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StrengthPlanNumberField(
                        label = stringResource(
                            R.string.appwide_gym_starting_load_format,
                            massUnit.raw,
                        ),
                        value = displayLoad?.strengthNumber().orEmpty(),
                        keyboard = KeyboardType.Decimal,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        val display = text.strengthDouble()
                        val kilograms = display?.let {
                            if (massUnit == MassUnit.POUNDS) UnitFormatter.poundsToKg(it) else it
                        }
                        onChange(item.copy(plan = item.plan.copy(targetLoadKg = kilograms)))
                    }
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_load_step_kg),
                        value = item.plan.loadStepKg.strengthNumber(),
                        keyboard = KeyboardType.Decimal,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        onChange(
                            item.copy(
                                plan = item.plan.copy(
                                    loadStepKg = text.strengthDouble()?.coerceIn(0.1, 100.0) ?: 0.1,
                                ),
                            ),
                        )
                    }
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_warmups),
                        value = item.plan.warmupSets.toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.weight(1f),
                    ) { text ->
                        onChange(
                            item.copy(
                                plan = item.plan.copy(
                                    warmupSets = text.toIntOrNull()?.coerceIn(0, 5) ?: 0,
                                ),
                            ),
                        )
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = item.plan.repsPerSide,
                        onCheckedChange = {
                            onChange(item.copy(plan = item.plan.copy(repsPerSide = it)))
                        },
                    )
                    Text(
                        stringResource(R.string.appwide_gym_reps_per_side),
                        style = NoopType.footnote,
                        color = Palette.textPrimary,
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StrengthChoiceMenu(
                    label = strengthRestLabel(item.restSeconds),
                    options = listOf(
                        0 to noRestLabel,
                        60 to stringResource(R.string.appwide_gym_rest_60_short),
                        90 to stringResource(R.string.appwide_gym_rest_90_short),
                        120 to stringResource(R.string.appwide_gym_rest_2_min_short),
                        180 to stringResource(R.string.appwide_gym_rest_3_min_short),
                        300 to stringResource(R.string.appwide_gym_rest_5_min_short),
                    ),
                    selected = item.restSeconds,
                    onSelected = { onChange(item.copy(restSeconds = it)) },
                    modifier = Modifier.weight(1f),
                )
                StrengthChoiceMenu(
                    label = strengthProgressionLabel(item.plan.progression),
                    options = if (timed) {
                        listOf(
                            "time" to stringResource(R.string.appwide_gym_add_time),
                            "none" to manualLabel,
                        )
                    } else {
                        listOf(
                            "double_progression" to stringResource(R.string.appwide_gym_rep_range),
                            "linear" to stringResource(R.string.appwide_gym_linear),
                            "none" to manualLabel,
                        )
                    },
                    selected = item.plan.progression,
                    onSelected = {
                        onChange(item.copy(plan = item.plan.copy(progression = it)))
                    },
                    modifier = Modifier.weight(1f),
                )
                StrengthChoiceMenu(
                    label = item.plan.supersetGroup?.let {
                        stringResource(
                            R.string.appwide_gym_superset_format,
                            ('A'.code + it - 1).toChar().toString(),
                        )
                    } ?: noSupersetLabel,
                    options = listOf(null to noSupersetLabel) +
                        (1..4).map {
                            it to stringResource(
                                R.string.appwide_gym_superset_format,
                                ('A'.code + it - 1).toChar().toString(),
                            )
                        },
                    selected = item.plan.supersetGroup,
                    onSelected = {
                        onChange(item.copy(plan = item.plan.copy(supersetGroup = it)))
                    },
                    modifier = Modifier.weight(1f),
                )
            }

            if (!timed) {
                StrengthChoiceMenu(
                    label = when (item.plan.setStyle) {
                        "drop" -> stringResource(R.string.appwide_gym_drop_cluster)
                        "rest_pause" -> stringResource(R.string.appwide_gym_rest_pause_cluster)
                        else -> stringResource(R.string.appwide_gym_straight_sets)
                    },
                    options = listOf(
                        "straight" to stringResource(R.string.appwide_gym_straight_sets),
                        "drop" to stringResource(R.string.appwide_gym_drop_cluster),
                        "rest_pause" to stringResource(R.string.appwide_gym_rest_pause_cluster),
                    ),
                    selected = item.plan.setStyle,
                    onSelected = {
                        onChange(item.copy(plan = item.plan.copy(setStyle = it)))
                    },
                )
                if (item.plan.setStyle == "drop") {
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_drop_load_percent),
                        value = item.plan.dropPercent.toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.fillMaxWidth(),
                    ) { text ->
                        onChange(
                            item.copy(
                                plan = item.plan.copy(
                                    dropPercent = text.toIntOrNull()?.coerceIn(5, 50) ?: 20,
                                ),
                            ),
                        )
                    }
                } else if (item.plan.setStyle == "rest_pause") {
                    StrengthPlanNumberField(
                        label = stringResource(R.string.appwide_gym_pause_seconds),
                        value = item.plan.restPauseSeconds.toString(),
                        keyboard = KeyboardType.Number,
                        modifier = Modifier.fillMaxWidth(),
                    ) { text ->
                        onChange(
                            item.copy(
                                plan = item.plan.copy(
                                    restPauseSeconds = text.toIntOrNull()?.coerceIn(5, 60) ?: 15,
                                ),
                            ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun <T> StrengthChoiceMenu(
    label: String,
    options: List<Pair<T, String>>,
    selected: T,
    onSelected: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        TextButton(
            onClick = { expanded = true },
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(7.dp))
                .background(Palette.surfaceInset),
        ) {
            Text(label, style = NoopType.footnote, color = Palette.textPrimary, maxLines = 1)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (value, display) ->
                DropdownMenuItem(
                    text = {
                        Text(
                            if (value == selected) {
                                stringResource(R.string.strength_selected_option, display)
                            } else {
                                display
                            },
                        )
                    },
                    onClick = {
                        expanded = false
                        onSelected(value)
                    },
                )
            }
        }
    }
}

@Composable
private fun StrengthPlanNumberField(
    label: String,
    value: String,
    keyboard: KeyboardType,
    modifier: Modifier,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = { text ->
            onChange(
                text.filter { char ->
                    char.isDigit() || (keyboard == KeyboardType.Decimal && (char == '.' || char == ','))
                },
            )
        },
        label = { Text(label, style = NoopType.footnote) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = modifier,
    )
}

@Composable
private fun strengthRestLabel(seconds: Int): String = when (seconds) {
    0 -> stringResource(R.string.appwide_gym_no_rest)
    60 -> stringResource(R.string.appwide_gym_rest_60_short)
    90 -> stringResource(R.string.appwide_gym_rest_90_short)
    120 -> stringResource(R.string.appwide_gym_rest_2_min_short)
    180 -> stringResource(R.string.appwide_gym_rest_3_min_short)
    300 -> stringResource(R.string.appwide_gym_rest_5_min_short)
    else -> if (seconds < 120) {
        stringResource(R.string.appwide_gym_rest_seconds_format, seconds)
    } else {
        stringResource(R.string.appwide_gym_rest_minutes_format, seconds / 60)
    }
}

@Composable
private fun strengthProgressionLabel(value: String): String = when (value) {
    "linear" -> stringResource(R.string.appwide_gym_linear)
    "time" -> stringResource(R.string.appwide_gym_add_time)
    "none" -> stringResource(R.string.appwide_gym_manual)
    else -> stringResource(R.string.appwide_gym_rep_range)
}

@Composable
private fun StrengthCustomExerciseEditor(
    vm: AppViewModel,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val unableSaveExercise = stringResource(R.string.appwide_gym_unable_save_exercise)
    var name by remember { mutableStateOf("") }
    var muscle by remember { mutableStateOf("other") }
    var equipment by remember { mutableStateOf("other") }
    var pattern by remember { mutableStateOf("other") }
    var saving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    Column(modifier = Modifier.fillMaxHeight()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose, enabled = !saving) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.appwide_gym_close_exercise_editor),
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.appwide_gym_create_exercise),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.appwide_gym_custom_exercise_body),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
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
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text(stringResource(R.string.appwide_gym_exercise_name)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    StrengthChoiceMenu(
                        label = stringResource(
                            R.string.appwide_gym_primary_format,
                            strengthDescriptor(muscle),
                        ),
                        options = StrengthTrainingContract.MUSCLES.sorted().map {
                            it to strengthDescriptor(it)
                        },
                        selected = muscle,
                        onSelected = { muscle = it },
                    )
                    StrengthChoiceMenu(
                        label = stringResource(
                            R.string.appwide_gym_equipment_format,
                            strengthDescriptor(equipment),
                        ),
                        options = StrengthTrainingContract.EQUIPMENT.sorted().map {
                            it to strengthDescriptor(it)
                        },
                        selected = equipment,
                        onSelected = { equipment = it },
                    )
                    StrengthChoiceMenu(
                        label = stringResource(
                            R.string.appwide_gym_movement_format,
                            strengthVocabulary(pattern),
                        ),
                        options = StrengthTrainingContract.MOVEMENT_PATTERNS.sorted().map {
                            it to strengthVocabulary(it)
                        },
                        selected = pattern,
                        onSelected = { pattern = it },
                    )
                }
            }
            NoopButton(
                text = stringResource(R.string.appwide_gym_save_exercise),
                leadingIcon = Icons.Filled.Check,
                fullWidth = true,
                enabled = name.isNotBlank() && !saving,
            ) {
                saving = true
                scope.launch {
                    val timestamp = Instant.now().epochSecond
                    val exercise = StrengthExerciseRow(
                        id = "custom-${UUID.randomUUID().toString().lowercase()}",
                        name = name.trim(),
                        primaryMuscle = muscle,
                        secondaryMusclesJSON = "[]",
                        equipment = equipment,
                        movementPattern = pattern,
                        isCustom = true,
                        createdAt = timestamp,
                        updatedAt = timestamp,
                    )
                    runCatching { vm.repo.upsertStrengthExercises(listOf(exercise)) }
                        .onSuccess { onClose() }
                        .onFailure {
                            errorMessage = it.strengthMessage(unableSaveExercise)
                            saving = false
                        }
                }
            }
        }
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = {
                Text(stringResource(R.string.appwide_gym_exercise), style = NoopType.title2)
            },
            text = { Text(message, style = NoopType.body, color = Palette.textSecondary) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) {
                    Text(stringResource(R.string.strength_ok), color = Palette.accent)
                }
            },
        )
    }
}

private fun strengthVocabulary(value: String): String =
    value.replace('_', ' ').split(' ').joinToString(" ") { word ->
        word.replaceFirstChar { char -> char.titlecase(Locale.getDefault()) }
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
                if (weekly.loadedVolumeKg > 0) {
                    stringResource(
                        R.string.appwide_gym_reps_and_volume_format,
                        weekly.totalReps,
                        UnitFormatter.massFromKilograms(weekly.loadedVolumeKg, massUnit),
                    )
                } else {
                    stringResource(R.string.appwide_strength_reps_format, weekly.totalReps)
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
            body = stringResource(R.string.appwide_gym_muscle_map_empty_body),
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
                overline = stringResource(R.string.appwide_gym_all_time),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatTile(
                    stringResource(R.string.appwide_gym_heaviest_load),
                    heaviest?.let { UnitFormatter.massFromKilograms(it, massUnit) } ?: "-",
                    Modifier.weight(1f),
                    stringResource(R.string.appwide_gym_external_load),
                    Palette.effortColor,
                )
                StatTile(
                    stringResource(R.string.appwide_gym_most_reps),
                    mostReps?.toString() ?: "-",
                    Modifier.weight(1f),
                    stringResource(R.string.appwide_gym_one_completed_set),
                    Palette.accent,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatTile(
                    stringResource(R.string.appwide_gym_best_set_volume),
                    bestVolume?.let { UnitFormatter.massFromKilograms(it, massUnit) } ?: "-",
                    Modifier.weight(1f),
                    stringResource(R.string.appwide_gym_load_times_reps),
                    Palette.metricPurple,
                )
                StatTile(
                    stringResource(R.string.appwide_strength_completed_sets),
                    completedSets.toString(),
                    Modifier.weight(1f),
                    stringResource(R.string.appwide_gym_sessions_format, history.size),
                    Palette.metricCyan,
                )
            }
            SectionHeader(
                stringResource(R.string.appwide_gym_history),
                overline = stringResource(R.string.appwide_gym_newest_first),
            )
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

@Composable
private fun exerciseRecordSummary(
    history: List<StrengthExerciseHistoryPoint>,
    massUnit: MassUnit,
): String {
    val parts = mutableListOf(stringResource(R.string.appwide_gym_sessions_format, history.size))
    history.mapNotNull { it.maxLoadKg }.maxOrNull()?.let {
        parts += stringResource(
            R.string.appwide_gym_heaviest_format,
            UnitFormatter.massFromKilograms(it, massUnit),
        )
    }
    history.mapNotNull { it.maxReps }.maxOrNull()?.let {
        parts += stringResource(R.string.appwide_gym_up_to_reps_format, it)
    }
    return parts.joinToString(" · ")
}

@Composable
private fun exerciseHistoryDetail(
    point: StrengthExerciseHistoryPoint,
    massUnit: MassUnit,
): String {
    val parts = mutableListOf(
        stringResource(R.string.appwide_strength_reps_format, point.totalReps),
    )
    point.maxLoadKg?.let {
        parts += stringResource(
            R.string.appwide_gym_heaviest_format,
            UnitFormatter.massFromKilograms(it, massUnit),
        )
    }
    point.bestSetVolumeKg?.let {
        parts += stringResource(
            R.string.appwide_gym_best_set_format,
            UnitFormatter.massFromKilograms(it, massUnit),
        )
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
    history: List<StrengthSessionSnapshot>,
    massUnit: MassUnit,
    onClose: () -> Unit,
    onSaved: (StrengthSessionSnapshot) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val saveError = stringResource(R.string.strength_save_error)
    val setRequirementsError = stringResource(R.string.strength_set_requirements_error)
    val completedReplacementError = stringResource(R.string.strength_replace_completed_error)
    val activeTimerReplacementError = stringResource(R.string.strength_replace_timer_error)
    val sourceRoutineReplacementError = stringResource(R.string.strength_replace_source_error)
    var session by remember(initial.session.id) { mutableStateOf(initial.session) }
    var blocks by remember(initial.session.id) {
        mutableStateOf(strengthBlocks(initial, exercises, routines))
    }
    var saving by remember { mutableStateOf(false) }
    var pendingSave by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var exercisePicker by remember { mutableStateOf(false) }
    var replacementBlockKey by remember { mutableStateOf<String?>(null) }
    var pendingReplacement by remember {
        mutableStateOf<Pair<String, StrengthExerciseRow>?>(null)
    }
    var routinePrompt by remember { mutableStateOf(false) }
    var routineName by remember { mutableStateOf(initial.session.name.orEmpty()) }
    var restEndMs by remember { mutableLongStateOf(0L) }
    var workSetId by remember { mutableStateOf<String?>(null) }
    var workStartedMs by remember { mutableLongStateOf(0L) }
    var workEndMs by remember { mutableLongStateOf(0L) }
    var timedCountdownSetId by remember { mutableStateOf<String?>(null) }
    var timedCountdownDuration by remember { mutableIntStateOf(0) }
    var timedCountdownEndMs by remember { mutableLongStateOf(0L) }
    var pacedSetId by remember { mutableStateOf<String?>(null) }
    var pacedStartedMs by remember { mutableLongStateOf(0L) }
    var pacedRepetitions by remember { mutableIntStateOf(0) }
    var pacedFinished by remember { mutableStateOf(false) }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var currentBlockKey by rememberSaveable(initial.session.id) {
        mutableStateOf(
            strengthBlocks(initial, exercises, routines)
                .firstOrNull { block -> block.sets.any { it.completedAt == null } }
                ?.key,
        )
    }

    val view = LocalView.current
    val context = LocalContext.current
    val coachingPrefs = remember(context) { NoopPrefs.of(context) }
    var voiceCoaching by rememberSaveable {
        mutableStateOf(coachingPrefs.getBoolean("strength.voiceCoaching", false))
    }
    var repTempoSeconds by rememberSaveable {
        mutableIntStateOf(
            coachingPrefs.getInt("strength.repTempoSeconds", 4).coerceIn(3, 6),
        )
    }
    var speechEngine by remember { mutableStateOf<TextToSpeech?>(null) }
    var speechReady by remember { mutableStateOf(false) }
    DisposableEffect(Unit) {
        val keepScreenOn = NoopPrefs.of(context).getBoolean("workoutKeepScreenOn", false)
        if (keepScreenOn) view.keepScreenOn = true
        val engine = TextToSpeech(context) { status ->
            speechReady = status == TextToSpeech.SUCCESS
            if (speechReady) {
                speechEngine?.language = Locale.getDefault()
            }
        }
        speechEngine = engine
        onDispose {
            view.keepScreenOn = false
            engine.stop()
            engine.shutdown()
            speechEngine = null
            speechReady = false
        }
    }

    fun speak(text: String, flush: Boolean = false) {
        if (!voiceCoaching || !speechReady) return
        speechEngine?.speak(
            text,
            if (flush) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
            null,
            "noop-strength-${System.nanoTime()}",
        )
    }

    fun normalizedRows(): List<StrengthSetRow> =
        blocks.flatMapIndexed { blockIndex, block ->
            block.sets.mapIndexed { setIndex, row ->
                row.copy(
                    exercisePosition = blockIndex,
                    setPosition = setIndex,
                )
            }
        }

    suspend fun persist(endedAt: Long? = session.endedAt): StrengthSessionSnapshot? {
        if (saving) {
            pendingSave = true
            return null
        }
        var saved: StrengthSessionSnapshot? = null
        do {
            pendingSave = false
            saving = true
            val now = Instant.now().epochSecond
            val cleanSession = session.copy(endedAt = endedAt, updatedAt = now)
            val rows = normalizedRows().map { it.copy(updatedAt = now) }
            saved = runCatching { vm.repo.saveStrengthSession(cleanSession, rows) }
                .onSuccess {
                    session = it.session
                    onSaved(it)
                }
                .onFailure { errorMessage = it.strengthMessage(saveError) }
                .getOrNull()
            saving = false
            if (saved == null) {
                pendingSave = false
                return null
            }
        } while (pendingSave)
        return saved
    }

    fun autosave() {
        scope.launch { persist() }
    }

    fun moveCurrentBlock(offset: Int) {
        if (blocks.isEmpty()) return
        val currentIndex = blocks.indexOfFirst { it.key == currentBlockKey }
            .takeIf { it >= 0 } ?: 0
        val nextIndex = (currentIndex + offset).coerceIn(0, blocks.lastIndex)
        if (nextIndex != currentIndex) currentBlockKey = blocks[nextIndex].key
    }

    fun advanceIfExerciseFinished(updated: List<StrengthBlockDraft>, completedBlockKey: String) {
        val completedIndex = updated.indexOfFirst { it.key == completedBlockKey }
        if (
            completedIndex < 0 ||
            currentBlockKey != completedBlockKey ||
            updated[completedIndex].sets.any { it.completedAt == null }
        ) return
        val nextIndex = ((completedIndex + 1)..updated.lastIndex)
            .firstOrNull { index -> updated[index].sets.any { it.completedAt == null } }
            ?: (0 until completedIndex)
                .firstOrNull { index -> updated[index].sets.any { it.completedAt == null } }
        if (nextIndex != null) currentBlockKey = updated[nextIndex].key
    }

    fun completeSet(blockKey: String, row: StrengthSetRow, restSeconds: Int) {
        if (pacedSetId == row.id) {
            pacedSetId = null
            pacedStartedMs = 0L
            pacedRepetitions = 0
            pacedFinished = false
            speechEngine?.stop()
        }
        val now = Instant.now().epochSecond
        val completedAt = session.endedAt ?: now
        runCatching {
            StrengthTrainingContract.validated(
                row.copy(completedAt = completedAt, updatedAt = now),
            )
        }.onSuccess { validated ->
            val updated = blocks.map { candidate ->
                if (candidate.key != blockKey) candidate else candidate.copy(
                    sets = candidate.sets.map {
                        if (it.id == row.id) validated else it
                    },
                )
            }
            blocks = updated
            if (restSeconds > 0) {
                restEndMs = System.currentTimeMillis() + restSeconds * 1_000L
            }
            advanceIfExerciseFinished(updated, blockKey)
            autosave()
        }.onFailure {
            errorMessage = it.strengthMessage(setRequirementsError)
        }
    }

    fun cancelTimedSet() {
        workSetId = null
        workStartedMs = 0L
        workEndMs = 0L
    }

    fun activateTimedSet(setId: String, duration: Int) {
        val exists = blocks.any { block ->
            block.sets.any { it.id == setId && it.completedAt == null }
        }
        if (!exists || duration <= 0 || workSetId != null) return
        val now = System.currentTimeMillis()
        restEndMs = 0L
        workSetId = setId
        workStartedMs = now
        workEndMs = now + duration * 1_000L
    }

    fun clearTimedCountdown(stopSpeech: Boolean = true) {
        timedCountdownSetId = null
        timedCountdownDuration = 0
        timedCountdownEndMs = 0L
        if (stopSpeech) speechEngine?.stop()
    }

    fun startTimedSet(row: StrengthSetRow) {
        val duration = row.durationS ?: return
        if (
            duration <= 0 ||
            workSetId != null ||
            pacedSetId != null ||
            timedCountdownSetId != null
        ) return
        if (voiceCoaching) {
            restEndMs = 0L
            timedCountdownSetId = row.id
            timedCountdownDuration = duration
            timedCountdownEndMs = System.currentTimeMillis() + 3_000L
        } else {
            activateTimedSet(row.id, duration)
        }
    }

    fun finishTimedSet(useTargetDuration: Boolean) {
        val setId = workSetId ?: return
        val block = blocks.firstOrNull { candidate ->
            candidate.sets.any { it.id == setId }
        } ?: run {
            cancelTimedSet()
            return
        }
        val row = block.sets.firstOrNull { it.id == setId } ?: run {
            cancelTimedSet()
            return
        }
        val target = row.durationS ?: 1
        val elapsed = ((System.currentTimeMillis() - workStartedMs) / 1_000L)
            .toInt()
            .coerceAtLeast(1)
        val completed = row.copy(
            durationS = if (useTargetDuration) target else minOf(target, elapsed),
        )
        val restSeconds = row.restSeconds ?: block.restSeconds
        cancelTimedSet()
        completeSet(block.key, completed, restSeconds)
        speak(context.getString(R.string.strength_voice_timed_complete), flush = true)
    }

    fun startPacedSet(row: StrengthSetRow, repetitions: Int) {
        if (
            repetitions <= 0 ||
            pacedSetId != null ||
            workSetId != null ||
            timedCountdownSetId != null
        ) return
        restEndMs = 0L
        pacedSetId = row.id
        pacedStartedMs = 0L
        pacedRepetitions = repetitions
        pacedFinished = false
    }

    fun cancelPacedSet() {
        pacedSetId = null
        pacedStartedMs = 0L
        pacedRepetitions = 0
        pacedFinished = false
        speechEngine?.stop()
    }

    fun completePacedSet(setId: String) {
        val block = blocks.firstOrNull { candidate ->
            candidate.sets.any { it.id == setId }
        } ?: run {
            cancelPacedSet()
            return
        }
        val row = block.sets.firstOrNull { it.id == setId } ?: run {
            cancelPacedSet()
            return
        }
        val restSeconds = row.restSeconds ?: block.restSeconds
        cancelPacedSet()
        completeSet(block.key, row, restSeconds)
    }

    fun removeExercise(blockKey: String) {
        val removedIndex = blocks.indexOfFirst { it.key == blockKey }
        val removedCurrent = currentBlockKey == blockKey
        val updated = normalizeBlocks(blocks.filterNot { it.key == blockKey })
        blocks = updated
        if (removedCurrent) {
            currentBlockKey = updated.getOrNull(
                removedIndex.coerceAtMost((updated.size - 1).coerceAtLeast(0)),
            )?.key
        }
        autosave()
    }

    fun beginExerciseReplacement(blockKey: String) {
        val block = blocks.firstOrNull { it.key == blockKey } ?: return
        if (block.sets.any { it.completedAt != null }) {
            errorMessage = completedReplacementError
            return
        }
        if (workSetId != null || timedCountdownSetId != null || pacedSetId != null) {
            errorMessage = activeTimerReplacementError
            return
        }
        replacementBlockKey = blockKey
        exercisePicker = true
    }

    fun replaceExercise(
        blockKey: String,
        replacement: StrengthExerciseRow,
        updateRoutine: Boolean,
    ) {
        scope.launch {
            val blockIndex = blocks.indexOfFirst { it.key == blockKey }
            if (blockIndex < 0 || blocks[blockIndex].sets.any { it.completedAt != null }) {
                errorMessage = completedReplacementError
                return@launch
            }

            if (updateRoutine) {
                val routineId = session.routineId
                val sourceId = blocks[blockIndex].sourceRoutineExerciseId
                val sourceRoutine = routines.firstOrNull { it.routine.id == routineId }
                val sourceIndex = sourceRoutine?.exercises?.indexOfFirst { it.id == sourceId } ?: -1
                if (routineId == null || sourceId == null || sourceRoutine == null || sourceIndex < 0) {
                    errorMessage = sourceRoutineReplacementError
                    return@launch
                }
                val now = Instant.now().epochSecond
                val prescriptions = sourceRoutine.exercises.mapIndexed { index, row ->
                    if (index == sourceIndex) {
                        row.copy(exerciseId = replacement.id, updatedAt = now)
                    } else {
                        row
                    }
                }
                val routineSaved = runCatching {
                    vm.repo.saveStrengthRoutine(
                        sourceRoutine.routine.copy(updatedAt = now),
                        prescriptions,
                    )
                }.onFailure {
                    errorMessage = it.strengthMessage(saveError)
                }.isSuccess
                if (!routineSaved) return@launch
            }

            val now = Instant.now().epochSecond
            blocks = blocks.map { block ->
                if (block.key != blockKey) {
                    block
                } else {
                    block.copy(
                        exercise = replacement,
                        sets = block.sets.map {
                            it.copy(exerciseId = replacement.id, updatedAt = now)
                        },
                    )
                }
            }
            persist()
        }
    }

    fun reorderExercise(blockKey: String, offset: Int) {
        val source = blocks.indexOfFirst { it.key == blockKey }
        if (source < 0) return
        val destination = (source + offset).coerceIn(0, blocks.lastIndex)
        if (source == destination) return
        val changed = blocks.toMutableList()
        val block = changed.removeAt(source)
        changed.add(destination, block)
        blocks = normalizeBlocks(changed)
        autosave()
    }

    LaunchedEffect(session.startedAt, session.endedAt) {
        do {
            nowMs = System.currentTimeMillis()
            if (session.endedAt != null) break
            delay(1_000)
        } while (true)
    }

    LaunchedEffect(
        restEndMs,
        workEndMs,
        timedCountdownEndMs,
        pacedSetId,
        pacedFinished,
    ) {
        nowMs = System.currentTimeMillis()
        while (
            (restEndMs > 0L && nowMs < restEndMs) ||
            (workEndMs > 0L && nowMs < workEndMs) ||
            (timedCountdownEndMs > 0L && nowMs < timedCountdownEndMs) ||
            (pacedSetId != null && !pacedFinished)
        ) {
            delay(
                if (
                    workEndMs > nowMs ||
                    timedCountdownEndMs > nowMs ||
                    (pacedSetId != null && !pacedFinished)
                ) {
                    200
                } else {
                    1_000
                },
            )
            nowMs = System.currentTimeMillis()
        }
    }

    LaunchedEffect(workSetId, workEndMs) {
        val setId = workSetId ?: return@LaunchedEffect
        val targetEnd = workEndMs
        delay((targetEnd - System.currentTimeMillis()).coerceAtLeast(0L))
        if (workSetId == setId && workEndMs == targetEnd) {
            finishTimedSet(useTargetDuration = true)
        }
    }

    LaunchedEffect(timedCountdownSetId) {
        val setId = timedCountdownSetId ?: return@LaunchedEffect
        for (number in 3 downTo 1) {
            if (timedCountdownSetId != setId) return@LaunchedEffect
            speak(number.toString(), flush = true)
            delay(1_000)
        }
        if (timedCountdownSetId != setId) return@LaunchedEffect
        val duration = timedCountdownDuration
        clearTimedCountdown(stopSpeech = false)
        activateTimedSet(setId, duration)
        speak(context.getString(R.string.strength_voice_go), flush = true)
    }

    LaunchedEffect(pacedSetId) {
        val setId = pacedSetId ?: return@LaunchedEffect
        for (number in 3 downTo 1) {
            if (pacedSetId != setId) return@LaunchedEffect
            speak(number.toString(), flush = true)
            delay(1_000)
        }
        if (pacedSetId != setId) return@LaunchedEffect
        pacedStartedMs = System.currentTimeMillis()
        repeat(pacedRepetitions.coerceAtLeast(1)) { index ->
            if (pacedSetId != setId) return@LaunchedEffect
            speak(
                context.getString(
                    R.string.strength_voice_controlled_phase,
                    index + 1,
                ),
                flush = true,
            )
            val controlledMs = (repTempoSeconds * 1_000L * 6L) / 10L
            delay(controlledMs)
            if (pacedSetId != setId) return@LaunchedEffect
            speak(
                context.getString(R.string.strength_voice_effort_phase),
                flush = true,
            )
            delay((repTempoSeconds * 1_000L - controlledMs).coerceAtLeast(500L))
        }
        if (pacedSetId != setId) return@LaunchedEffect
        pacedFinished = true
        speak(context.getString(R.string.strength_voice_pacing_complete), flush = true)
    }

    LaunchedEffect(restEndMs) {
        val target = restEndMs
        if (target <= 0L) return@LaunchedEffect
        delay((target - System.currentTimeMillis()).coerceAtLeast(0L))
        if (restEndMs == target) {
            speak(context.getString(R.string.strength_voice_rest_complete), flush = true)
        }
    }

    LaunchedEffect(blocks.map { it.key }, currentBlockKey) {
        if (blocks.isNotEmpty() && blocks.none { it.key == currentBlockKey }) {
            currentBlockKey = blocks.firstOrNull { block ->
                block.sets.any { it.completedAt == null }
            }?.key ?: blocks.first().key
        }
    }

    val completedSetCount = normalizedRows().count { it.completedAt != null }
    val totalSetCount = normalizedRows().size
    val currentBlockIndex = blocks.indexOfFirst { it.key == currentBlockKey }
        .takeIf { it >= 0 } ?: 0
    val currentBlock = blocks.getOrNull(currentBlockIndex)
    val currentSourcePrescription = currentBlock?.let { block ->
        routines
            .firstOrNull { it.routine.id == session.routineId }
            ?.exercises
            ?.firstOrNull {
                it.position == block.position &&
                    it.exerciseId == block.exercise.id
            }
    }
    val currentProgression = currentBlock?.let { block ->
        currentSourcePrescription?.let { prescription ->
            when (
                StrengthWorkoutPlanner.prescription(
                    exercise = block.exercise,
                    prescription = prescription,
                    history = history,
                ).reason
            ) {
                StrengthProgressionReason.FIRST_SESSION ->
                    stringResource(R.string.strength_progression_first)
                StrengthProgressionReason.REPEAT_LOAD ->
                    stringResource(R.string.strength_progression_repeat)
                StrengthProgressionReason.REP_RANGE_ADVANCED ->
                    stringResource(R.string.strength_progression_rep_range)
                StrengthProgressionReason.LINEAR_ADVANCED ->
                    stringResource(R.string.strength_progression_linear)
                StrengthProgressionReason.TIME_ADVANCED ->
                    stringResource(R.string.strength_progression_time)
                StrengthProgressionReason.BODYWEIGHT_REP_PROGRESS ->
                    stringResource(R.string.strength_progression_bodyweight)
            }
        } ?: stringResource(R.string.strength_progression_freestyle)
    }
    val elapsedSeconds = (
        (session.endedAt?.times(1_000L) ?: nowMs) - session.startedAt * 1_000L
        ).coerceAtLeast(0L) / 1_000L
    val swipeThreshold = with(LocalDensity.current) { 56.dp.toPx() }
    var exerciseSwipeX by remember(currentBlock?.key) { mutableFloatStateOf(0f) }

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
                    stringResource(R.string.strength_default_workout_name),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.strength_follow_plan_title),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            StatePill(
                stringResource(
                    R.string.strength_complete_count,
                    completedSetCount,
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
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = session.name.orEmpty(),
                            onValueChange = { session = session.copy(name = it.ifBlank { null }) },
                            label = { Text(stringResource(R.string.strength_workout_name_optional)) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(horizontalAlignment = Alignment.End) {
                            Text(
                                strengthRestTime(elapsedSeconds),
                                style = NoopType.number(20f),
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(R.string.strength_elapsed),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                        }
                    }
                    Row {
                        Text(
                            stringResource(
                                R.string.strength_sets_progress,
                                completedSetCount,
                                totalSetCount,
                            ),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            stringResource(
                                R.string.strength_exercise_progress,
                                if (blocks.isEmpty()) 0 else currentBlockIndex + 1,
                                blocks.size,
                            ),
                            style = NoopType.footnote,
                            color = Palette.effortColor,
                        )
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(5.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(Palette.surfaceInset),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(
                                    completedSetCount.toFloat() /
                                        totalSetCount.coerceAtLeast(1).toFloat(),
                                )
                                .fillMaxHeight()
                                .background(Palette.effortColor),
                        )
                    }
                }
            }

            currentBlock?.let { block ->
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                strengthExerciseName(block.exercise),
                                style = NoopType.title2,
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
                        block.supersetGroup?.let { group ->
                            StatePill(
                                stringResource(
                                    R.string.appwide_gym_superset_format,
                                    ('A'.code + group - 1).toChar().toString(),
                                ),
                                tone = StrandTone.Accent,
                                showsDot = false,
                            )
                        }
                    }

                    StrengthExerciseMotionView(
                        exercise = block.exercise,
                        modifier = Modifier
                            .fillMaxWidth()
                            .pointerInput(block.key, blocks.size) {
                                detectHorizontalDragGestures(
                                    onDragStart = { exerciseSwipeX = 0f },
                                    onDragEnd = {
                                        when {
                                            exerciseSwipeX <= -swipeThreshold ->
                                                moveCurrentBlock(1)
                                            exerciseSwipeX >= swipeThreshold ->
                                                moveCurrentBlock(-1)
                                        }
                                        exerciseSwipeX = 0f
                                    },
                                    onHorizontalDrag = { _, amount ->
                                        exerciseSwipeX += amount
                                    },
                                )
                            },
                    )

                    StrengthExercisePerformanceContext(
                        exercise = block.exercise,
                        history = history,
                        currentSessionId = session.id,
                        massUnit = massUnit,
                    )

                    currentProgression?.let { progression ->
                        Text(
                            progression,
                            style = NoopType.footnote,
                            color = Palette.metricCyan,
                        )
                    }
                    currentSourcePrescription?.note
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() }
                        ?.let { note ->
                            Text(
                                note,
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                }
            }

            NoopCard(tint = if (voiceCoaching) Palette.metricCyan else null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Filled.FitnessCenter,
                            contentDescription = null,
                            tint = if (voiceCoaching) {
                                Palette.metricCyan
                            } else {
                                Palette.textTertiary
                            },
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            stringResource(R.string.strength_voice_coaching),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(
                            checked = voiceCoaching,
                            onCheckedChange = { enabled ->
                                voiceCoaching = enabled
                                coachingPrefs.edit()
                                    .putBoolean("strength.voiceCoaching", enabled)
                                    .apply()
                                if (!enabled) speechEngine?.stop()
                            },
                        )
                    }
                    if (voiceCoaching) {
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            (3..6).forEach { seconds ->
                                TextButton(
                                    onClick = {
                                        repTempoSeconds = seconds
                                        coachingPrefs.edit()
                                            .putInt("strength.repTempoSeconds", seconds)
                                            .apply()
                                    },
                                    modifier = Modifier
                                        .weight(1f)
                                        .clip(RoundedCornerShape(7.dp))
                                        .background(
                                            if (repTempoSeconds == seconds) {
                                                Palette.surfaceOverlay
                                            } else {
                                                Palette.surfaceInset
                                            },
                                        ),
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.strength_tempo_seconds,
                                            seconds,
                                        ),
                                        style = NoopType.caption,
                                        color = if (repTempoSeconds == seconds) {
                                            Palette.textPrimary
                                        } else {
                                            Palette.textSecondary
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (timedCountdownSetId != null && timedCountdownEndMs > 0L) {
                val remaining = (
                    (timedCountdownEndMs - nowMs).coerceAtLeast(0L) + 999L
                    ) / 1_000L
                NoopCard(tint = Palette.effortColor) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Filled.Timer,
                            contentDescription = null,
                            tint = Palette.effortColor,
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                stringResource(R.string.strength_get_ready),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                remaining.coerceAtLeast(1L).toString(),
                                style = NoopType.number(28f),
                                color = Palette.textPrimary,
                            )
                        }
                        TextButton(onClick = { clearTimedCountdown() }) {
                            Text(
                                stringResource(R.string.strength_cancel),
                                color = Palette.textSecondary,
                            )
                        }
                    }
                }
            }

            pacedSetId?.let { setId ->
                val tempoMs = repTempoSeconds.coerceAtLeast(3) * 1_000L
                val elapsed = if (pacedStartedMs > 0L) {
                    (nowMs - pacedStartedMs).coerceAtLeast(0L)
                } else {
                    0L
                }
                val repetition = (
                    elapsed / tempoMs
                    ).toInt().plus(1).coerceIn(1, pacedRepetitions.coerceAtLeast(1))
                val controlled = elapsed % tempoMs < tempoMs * 6L / 10L
                val total = tempoMs * pacedRepetitions.coerceAtLeast(1)
                val progress = if (pacedFinished) {
                    1f
                } else {
                    (elapsed.toFloat() / total.coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
                }
                NoopCard(tint = Palette.metricCyan) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                Icons.Filled.Timer,
                                contentDescription = null,
                                tint = Palette.metricCyan,
                            )
                            Spacer(Modifier.width(10.dp))
                            Column(
                                modifier = Modifier.weight(1f),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                Text(
                                    when {
                                        pacedFinished -> stringResource(
                                            R.string.strength_pacing_complete,
                                        )
                                        pacedStartedMs == 0L -> stringResource(
                                            R.string.strength_get_ready,
                                        )
                                        else -> stringResource(
                                            R.string.strength_rep_progress,
                                            repetition,
                                            pacedRepetitions,
                                        )
                                    },
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    when {
                                        pacedFinished -> stringResource(
                                            R.string.strength_confirm_set_ready,
                                        )
                                        pacedStartedMs == 0L -> stringResource(
                                            R.string.strength_paced_starts_after_countdown,
                                        )
                                        controlled -> stringResource(
                                            R.string.strength_controlled_inhale,
                                        )
                                        else -> stringResource(
                                            R.string.strength_effort_exhale,
                                        )
                                    },
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                )
                            }
                            TextButton(onClick = ::cancelPacedSet) {
                                Text(
                                    stringResource(R.string.strength_cancel),
                                    color = Palette.textSecondary,
                                )
                            }
                            TextButton(onClick = { completePacedSet(setId) }) {
                                Text(
                                    stringResource(R.string.strength_complete_set),
                                    color = Palette.metricCyan,
                                )
                            }
                        }
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(5.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(Palette.surfaceInset),
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(progress)
                                    .fillMaxHeight()
                                    .background(Palette.metricCyan),
                            )
                        }
                    }
                }
            }

            if (workSetId != null && workStartedMs > 0L && workEndMs > 0L) {
                val total = (workEndMs - workStartedMs).coerceAtLeast(1L)
                val remainingMs = (workEndMs - nowMs).coerceAtLeast(0L)
                val remainingSeconds = (remainingMs + 999L) / 1_000L
                NoopCard(tint = Palette.effortColor) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Timer, contentDescription = null, tint = Palette.effortColor)
                            Spacer(Modifier.width(10.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    stringResource(R.string.strength_timed_set),
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    stringResource(
                                        R.string.strength_seconds_remaining,
                                        remainingSeconds,
                                    ),
                                    style = NoopType.number(22f),
                                    color = Palette.textPrimary,
                                )
                            }
                            TextButton(onClick = ::cancelTimedSet) {
                                Text(
                                    stringResource(R.string.strength_cancel),
                                    color = Palette.textSecondary,
                                )
                            }
                            TextButton(onClick = {
                                finishTimedSet(useTargetDuration = false)
                            }) {
                                Text(
                                    stringResource(R.string.strength_done),
                                    color = Palette.effortColor,
                                )
                            }
                        }
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(5.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(Palette.surfaceInset),
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth((remainingMs.toFloat() / total.toFloat()).coerceIn(0f, 1f))
                                    .fillMaxHeight()
                                    .background(Palette.effortColor),
                            )
                        }
                    }
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
                if (currentBlock != null) {
                    val nextSet = currentBlock.sets.firstOrNull { it.completedAt == null }

                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (nextSet != null) {
                            NoopCard(tint = Palette.effortColor) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(
                                        modifier = Modifier.weight(1f),
                                        verticalArrangement = Arrangement.spacedBy(3.dp),
                                    ) {
                                        Text(
                                            stringResource(R.string.appwide_gym_up_next),
                                            style = NoopType.caption,
                                            color = Palette.effortColor,
                                        )
                                        Text(
                                            strengthTargetLabel(
                                                row = nextSet,
                                                exercise = currentBlock.exercise,
                                                massUnit = massUnit,
                                            ),
                                            style = NoopType.headline,
                                            color = Palette.textPrimary,
                                        )
                                        Text(
                                            strengthSetType(nextSet.setType),
                                            style = NoopType.footnote,
                                            color = Palette.textSecondary,
                                        )
                                    }
                                    if (
                                        nextSet.reps == null &&
                                        (nextSet.durationS ?: 0) > 0
                                    ) {
                                        IconButton(
                                            enabled = workSetId == null &&
                                                timedCountdownSetId == null &&
                                                pacedSetId == null,
                                            onClick = { startTimedSet(nextSet) },
                                        ) {
                                            Icon(
                                                Icons.Filled.PlayArrow,
                                                contentDescription = stringResource(
                                                    R.string.strength_start_timed_set,
                                                    nextSet.durationS ?: 0,
                                                ),
                                                tint = Palette.effortColor,
                                            )
                                        }
                                    } else if ((nextSet.reps ?: 0) > 0) {
                                        IconButton(
                                            enabled = workSetId == null &&
                                                timedCountdownSetId == null &&
                                                pacedSetId == null,
                                            onClick = {
                                                startPacedSet(
                                                    nextSet,
                                                    nextSet.reps ?: 0,
                                                )
                                            },
                                        ) {
                                            Icon(
                                                Icons.Filled.FitnessCenter,
                                                contentDescription = stringResource(
                                                    R.string.strength_coach_repetitions,
                                                    nextSet.reps ?: 0,
                                                ),
                                                tint = Palette.metricCyan,
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            Text(
                                stringResource(R.string.strength_all_sets_complete),
                                style = NoopType.headline,
                                color = Palette.statusPositive,
                            )
                        }
                    }

                    val block = currentBlock
                    StrengthExerciseCard(
                        block = block,
                        massUnit = massUnit,
                        showHeader = false,
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
                            completeSet(block.key, row, restSeconds)
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
                            val recordedAt = session.endedAt ?: now
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
                                createdAt = recordedAt,
                                updatedAt = now,
                            )
                            blocks = blocks.map {
                                if (it.key == block.key) it.copy(sets = it.sets + added) else it
                            }
                            autosave()
                        },
                        onDeleteExercise = {
                            removeExercise(block.key)
                        },
                        onReplaceExercise = {
                            beginExerciseReplacement(block.key)
                        },
                        onMoveEarlier = {
                            reorderExercise(block.key, -1)
                        },
                        onMoveLater = {
                            reorderExercise(block.key, 1)
                        },
                        canMoveEarlier = block.position > 0,
                        canMoveLater = block.position < blocks.lastIndex,
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        NoopButton(
                            text = stringResource(R.string.strength_previous),
                            leadingIcon = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            kind = NoopButtonKind.Secondary,
                            enabled = currentBlockIndex > 0,
                            modifier = Modifier.weight(1f),
                        ) { moveCurrentBlock(-1) }
                        NoopButton(
                            text = stringResource(R.string.strength_next),
                            leadingIcon = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            kind = NoopButtonKind.Secondary,
                            enabled = currentBlockIndex < blocks.lastIndex,
                            modifier = Modifier.weight(1f),
                        ) { moveCurrentBlock(1) }
                    }
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
                    val endedAt = session.endedAt ?: run {
                        val now = Instant.now().epochSecond
                        val latest = normalizedRows().mapNotNull { it.completedAt }.maxOrNull() ?: now
                        if (now - session.startedAt <= StrengthTrainingContract.MAX_DURATION_SECONDS) {
                            now
                        } else {
                            minOf(latest, session.startedAt + StrengthTrainingContract.MAX_DURATION_SECONDS)
                        }
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
            onDismiss = {
                exercisePicker = false
                replacementBlockKey = null
            },
            onPick = { exercise ->
                val replacementKey = replacementBlockKey
                if (replacementKey != null) {
                    pendingReplacement = replacementKey to exercise
                    exercisePicker = false
                    replacementBlockKey = null
                    return@StrengthExercisePicker
                }
                val now = Instant.now().epochSecond
                val recordedAt = session.endedAt ?: now
                val position = blocks.size
                val sets = (0 until 3).map { setPosition ->
                    StrengthSetRow(
                        id = UUID.randomUUID().toString().lowercase(),
                        sessionId = session.id,
                        exerciseId = exercise.id,
                        exercisePosition = position,
                        setPosition = setPosition,
                        setType = if (exercise.equipment == "bodyweight") "bodyweight" else "working",
                        createdAt = recordedAt,
                        updatedAt = now,
                    )
                }
                val added = StrengthBlockDraft(
                    key = "$position-${exercise.id}",
                    exercise = exercise,
                    position = position,
                    restSeconds = 120,
                    sets = sets,
                    sourceRoutineExerciseId = null,
                )
                blocks = blocks + added
                currentBlockKey = added.key
                exercisePicker = false
                autosave()
            },
        )
    }

    pendingReplacement?.let { (blockKey, replacement) ->
        val canUpdateRoutine = blocks.firstOrNull { it.key == blockKey }
            ?.sourceRoutineExerciseId != null
        AlertDialog(
            onDismissRequest = { pendingReplacement = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    stringResource(R.string.strength_replace_scope_title),
                    style = NoopType.title2,
                )
            },
            text = {
                Text(
                    stringResource(
                        R.string.strength_replace_scope_body,
                        strengthExerciseName(replacement),
                    ),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = {
                        pendingReplacement = null
                        replaceExercise(blockKey, replacement, updateRoutine = false)
                    }) {
                        Text(
                            stringResource(R.string.strength_replace_today_only),
                            color = Palette.effortColor,
                        )
                    }
                    if (canUpdateRoutine) {
                        TextButton(onClick = {
                            pendingReplacement = null
                            replaceExercise(blockKey, replacement, updateRoutine = true)
                        }) {
                            Text(
                                stringResource(R.string.strength_replace_future),
                                color = Palette.effortColor,
                            )
                        }
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingReplacement = null }) {
                    Text(
                        stringResource(R.string.strength_cancel),
                        color = Palette.textSecondary,
                    )
                }
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
                            val sourceRoutine = routines.firstOrNull {
                                it.routine.id == session.routineId
                            }
                            runCatching {
                                val prescription = blocks.map { block ->
                                    val source = sourceRoutine?.exercises?.firstOrNull {
                                        it.position == block.position &&
                                            it.exerciseId == block.exercise.id
                                    }
                                    val baseSets = strengthRoutineBaseSets(block)
                                    val reps = baseSets.mapNotNull { it.reps }
                                    val plan = strengthRoutinePlan(block, source, baseSets)
                                    val planJSON = requireNotNull(
                                        StrengthTrainingContract.encodeExercisePlan(plan),
                                    ) { saveError }
                                    StrengthRoutineExerciseRow(
                                        id = UUID.randomUUID().toString().lowercase(),
                                        routineId = routineId,
                                        exerciseId = block.exercise.id,
                                        position = block.position,
                                        targetSets = maxOf(1, baseSets.size),
                                        targetRepsMin = if (plan.mode == "timed") {
                                            null
                                        } else {
                                            reps.minOrNull()
                                        },
                                        targetRepsMax = if (plan.mode == "timed") {
                                            null
                                        } else {
                                            reps.maxOrNull()
                                        },
                                        targetRPE = source?.targetRPE,
                                        restSeconds = source?.restSeconds ?: block.restSeconds,
                                        note = source?.note,
                                        planJSON = planJSON,
                                        createdAt = now,
                                        updatedAt = now,
                                    )
                                }
                                vm.repo.saveStrengthRoutine(routine, prescription)
                            }
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
private fun StrengthExercisePerformanceContext(
    exercise: StrengthExerciseRow,
    history: List<StrengthSessionSnapshot>,
    currentSessionId: String,
    massUnit: MassUnit,
) {
    val context = LocalContext.current
    val completedSessions = history
        .filter {
            it.session.id != currentSessionId && it.session.endedAt != null
        }
        .sortedByDescending { it.session.startedAt }
    val lastSets = completedSessions.firstNotNullOfOrNull { item ->
        item.sets
            .filter {
                it.exerciseId == exercise.id &&
                    it.completedAt != null &&
                    it.setType != "warmup"
            }
            .sortedBy { it.setPosition }
            .takeIf { it.isNotEmpty() }
    }
    val allSets = completedSessions
        .flatMap { it.sets }
        .filter {
            it.exerciseId == exercise.id &&
                it.completedAt != null &&
                it.setType != "warmup"
        }
    val best = allSets.maxByOrNull(::strengthSetPerformanceValue)
    if (lastSets == null && best == null) return

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            lastSets?.let { sets ->
                StrengthPerformanceRow(
                    title = stringResource(R.string.strength_last_session),
                    value = sets.take(3).joinToString(" · ") {
                        strengthSetPerformanceLabel(context, it, massUnit)
                    },
                )
            }
            best?.let { set ->
                StrengthPerformanceRow(
                    title = stringResource(R.string.strength_best_set),
                    value = strengthSetPerformanceLabel(context, set, massUnit),
                )
            }
        }
    }
}

@Composable
private fun StrengthPerformanceRow(title: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            title,
            style = NoopType.caption,
            color = Palette.textTertiary,
            modifier = Modifier.width(88.dp),
        )
        Text(
            value,
            style = NoopType.subhead,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

private fun strengthSetPerformanceValue(set: StrengthSetRow): Double =
    set.volumeKg?.times(1_000.0)
        ?: set.durationS?.toDouble()
        ?: set.reps?.toDouble()
        ?: 0.0

private fun strengthSetPerformanceLabel(
    context: android.content.Context,
    set: StrengthSetRow,
    massUnit: MassUnit,
): String {
    if (set.durationS != null && set.reps == null) {
        return context.getString(R.string.strength_performance_seconds, set.durationS)
    }
    val repetitions = set.reps ?: 0
    return set.loadKg?.let { load ->
        context.getString(
            R.string.strength_performance_loaded,
            repetitions,
            UnitFormatter.massFromKilograms(load, massUnit),
        )
    } ?: context.getString(R.string.strength_performance_reps, repetitions)
}

private data class StrengthNextSetTarget(
    val block: StrengthBlockDraft,
    val set: StrengthSetRow,
)

private fun strengthSetQueue(blocks: List<StrengthBlockDraft>): List<StrengthNextSetTarget> {
    val ordered = blocks.sortedBy { it.position }
    val handledGroups = mutableSetOf<Int>()
    return buildList {
        ordered.forEach { block ->
            val group = block.supersetGroup
            if (group == null) {
                block.sets.sortedBy { it.setPosition }.forEach {
                    add(StrengthNextSetTarget(block, it))
                }
            } else if (handledGroups.add(group)) {
                val members = ordered.filter { it.supersetGroup == group }
                members.forEach { member ->
                    member.sets.filter { it.setType == "warmup" }.forEach {
                        add(StrengthNextSetTarget(member, it))
                    }
                }
                val workSets = members.associateWith { member ->
                    member.sets.filter { it.setType != "warmup" }
                }
                val setCount = workSets.values.maxOfOrNull { it.size } ?: 0
                repeat(setCount) { setIndex ->
                    members.forEach { member ->
                        workSets.getValue(member).getOrNull(setIndex)?.let {
                            add(StrengthNextSetTarget(member, it))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StrengthNextSetGuide(blocks: List<StrengthBlockDraft>) {
    val target = strengthSetQueue(blocks).firstOrNull { it.set.completedAt == null } ?: return
    val setGuide = stringResource(
        R.string.appwide_gym_set_guide_format,
        target.set.setPosition + 1,
        strengthSetType(target.set.setType),
    )
    val guide = target.block.supersetGroup?.let {
        "${stringResource(
            R.string.appwide_gym_superset_format,
            ('A'.code + it - 1).toChar().toString(),
        )} · $setGuide"
    } ?: setGuide
    NoopCard(tint = Palette.effortColor) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Palette.effortColor)
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    stringResource(R.string.appwide_gym_up_next),
                    style = NoopType.caption,
                    color = Palette.effortColor,
                )
                Text(
                    strengthExerciseName(target.block.exercise),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(guide, style = NoopType.footnote, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun StrengthExerciseCard(
    block: StrengthBlockDraft,
    massUnit: MassUnit,
    showHeader: Boolean = true,
    onChange: (StrengthBlockDraft) -> Unit,
    onRestChange: (Int) -> Unit,
    onComplete: (StrengthSetRow, Int) -> Unit,
    onUncomplete: (StrengthSetRow) -> Unit,
    onDeleteSet: (StrengthSetRow) -> Unit,
    onAddSet: () -> Unit,
    onDeleteExercise: () -> Unit,
    onReplaceExercise: () -> Unit,
    onMoveEarlier: () -> Unit,
    onMoveLater: () -> Unit,
    canMoveEarlier: Boolean,
    canMoveLater: Boolean,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val nextSetId = block.sets.firstOrNull { it.completedAt == null }?.id
    NoopCard(padding = 0.dp, tint = Palette.effortColor) {
        Column {
            if (showHeader) {
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
                        Icon(
                            Icons.Filled.FitnessCenter,
                            contentDescription = null,
                            tint = Palette.effortColor,
                        )
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
                    block.supersetGroup?.let { group ->
                        Text(
                            stringResource(
                                R.string.appwide_gym_superset_format,
                                ('A'.code + group - 1).toChar().toString(),
                            ),
                            style = NoopType.caption,
                            color = Palette.effortColor,
                        )
                    }
                    StrengthExerciseMenu(
                        block = block,
                        menuOpen = menuOpen,
                        onMenuOpen = { menuOpen = it },
                        onRestChange = onRestChange,
                        onDeleteExercise = onDeleteExercise,
                        onReplaceExercise = onReplaceExercise,
                        onMoveEarlier = onMoveEarlier,
                        onMoveLater = onMoveLater,
                        canMoveEarlier = canMoveEarlier,
                        canMoveLater = canMoveLater,
                    )
                }
                HorizontalDivider(color = Palette.hairline)
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(
                            R.string.strength_sets_progress,
                            block.sets.count { it.completedAt != null },
                            block.sets.size,
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    StrengthExerciseMenu(
                        block = block,
                        menuOpen = menuOpen,
                        onMenuOpen = { menuOpen = it },
                        onRestChange = onRestChange,
                        onDeleteExercise = onDeleteExercise,
                        onReplaceExercise = onReplaceExercise,
                        onMoveEarlier = onMoveEarlier,
                        onMoveLater = onMoveLater,
                        canMoveEarlier = canMoveEarlier,
                        canMoveLater = canMoveLater,
                    )
                }
                HorizontalDivider(color = Palette.hairline)
            }
            block.sets.forEachIndexed { index, row ->
                StrengthSetEditorRow(
                    index = index,
                    row = row,
                    isCurrent = row.id == nextSetId,
                    massUnit = massUnit,
                    onChange = { changed ->
                        onChange(block.copy(sets = block.sets.map { if (it.id == changed.id) changed else it }))
                    },
                    onComplete = {
                        if (row.completedAt == null) {
                            onComplete(row, row.restSeconds ?: block.restSeconds)
                        } else {
                            onUncomplete(row)
                        }
                    },
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
private fun StrengthExerciseMenu(
    block: StrengthBlockDraft,
    menuOpen: Boolean,
    onMenuOpen: (Boolean) -> Unit,
    onRestChange: (Int) -> Unit,
    onDeleteExercise: () -> Unit,
    onReplaceExercise: () -> Unit,
    onMoveEarlier: () -> Unit,
    onMoveLater: () -> Unit,
    canMoveEarlier: Boolean,
    canMoveLater: Boolean,
) {
    Box {
        IconButton(onClick = { onMenuOpen(true) }) {
            Icon(
                Icons.Filled.MoreVert,
                contentDescription = stringResource(R.string.strength_exercise_actions),
            )
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { onMenuOpen(false) }) {
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
                        onMenuOpen(false)
                        onRestChange(value)
                    },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.strength_replace_exercise)) },
                onClick = {
                    onMenuOpen(false)
                    onReplaceExercise()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.strength_move_earlier)) },
                enabled = canMoveEarlier,
                onClick = {
                    onMenuOpen(false)
                    onMoveEarlier()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.strength_move_later)) },
                enabled = canMoveLater,
                onClick = {
                    onMenuOpen(false)
                    onMoveLater()
                },
            )
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(R.string.strength_remove_exercise),
                        color = Palette.statusCritical,
                    )
                },
                onClick = {
                    onMenuOpen(false)
                    onDeleteExercise()
                },
            )
        }
    }
}

@Composable
private fun StrengthSetEditorRow(
    index: Int,
    row: StrengthSetRow,
    isCurrent: Boolean,
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
            .background(
                when {
                    complete -> Palette.statusPositive.copy(alpha = 0.06f)
                    isCurrent -> Palette.effortColor.copy(alpha = 0.08f)
                    else -> Color.Transparent
                },
            )
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
                    listOf("working", "warmup", "drop", "rest_pause", "failure", "bodyweight").forEach { type ->
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
            supersetGroup = prescription?.planJSON
                ?.let(StrengthTrainingContract::exercisePlan)
                ?.supersetGroup,
            sourceRoutineExerciseId = prescription?.id,
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
                )
            },
        )
    }

private fun strengthRoutineBaseSets(block: StrengthBlockDraft): List<StrengthSetRow> {
    val base = block.sets.filter { it.setType !in setOf("warmup", "drop", "rest_pause") }
    if (base.isNotEmpty()) return base
    return block.sets.filter { it.setType != "warmup" }.ifEmpty { block.sets }
}

private fun strengthRoutinePlan(
    block: StrengthBlockDraft,
    source: StrengthRoutineExerciseRow?,
    baseSets: List<StrengthSetRow>,
): StrengthExercisePlan {
    var plan = source?.let {
        StrengthTrainingContract.exercisePlan(it.planJSON)
    } ?: StrengthExercisePlan()
    val timed = block.exercise.movementPattern == "cardio" ||
        (baseSets.any { it.durationS != null } && baseSets.none { it.reps != null })
    plan = plan.copy(
        mode = if (timed) "timed" else "reps",
        supersetGroup = block.supersetGroup,
    )
    if (timed) {
        return plan.copy(
            targetDurationS = baseSets.mapNotNull { it.durationS }.maxOrNull()
                ?: plan.targetDurationS
                ?: 30,
            progression = if (plan.progression in setOf("none", "time")) {
                plan.progression
            } else {
                "time"
            },
            warmupSets = 0,
            setStyle = "straight",
        )
    }

    plan = plan.copy(
        targetDurationS = null,
        targetLoadKg = baseSets.mapNotNull { it.loadKg }.maxOrNull() ?: plan.targetLoadKg,
        progression = if (plan.progression == "time") "double_progression" else plan.progression,
        warmupSets = block.sets.count { it.setType == "warmup" }.coerceAtMost(5),
    )
    val drop = block.sets.firstOrNull { it.setType == "drop" }
    if (drop != null) {
        val workLoad = baseSets.mapNotNull { it.loadKg }.maxOrNull()
        val dropPercent = if (workLoad != null && workLoad > 0.0 &&
            drop.loadKg != null && drop.loadKg < workLoad
        ) {
            ((1.0 - drop.loadKg / workLoad) * 100.0).roundToInt().coerceIn(5, 50)
        } else {
            plan.dropPercent
        }
        return plan.copy(setStyle = "drop", dropPercent = dropPercent)
    }
    val restPauseIndex = block.sets.indexOfFirst { it.setType == "rest_pause" }
    if (restPauseIndex >= 0) {
        val pause = block.sets.getOrNull(restPauseIndex - 1)?.restSeconds
            ?.coerceIn(5, 60)
            ?: plan.restPauseSeconds
        return plan.copy(setStyle = "rest_pause", restPauseSeconds = pause)
    }
    return plan.copy(setStyle = "straight")
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
    val completed = item.sets.filter {
        it.completedAt != null && it.setType != "warmup"
    }
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
internal fun strengthExerciseName(exercise: StrengthExerciseRow): String {
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
    "barbell_front_squat" -> R.string.appwide_gym_exercise_barbell_front_squat
    "goblet_squat" -> R.string.appwide_gym_exercise_goblet_squat
    "hack_squat" -> R.string.appwide_gym_exercise_hack_squat
    "leg_extension" -> R.string.appwide_gym_exercise_leg_extension
    "lying_leg_curl" -> R.string.appwide_gym_exercise_lying_leg_curl
    "barbell_hip_thrust" -> R.string.appwide_gym_exercise_barbell_hip_thrust
    "glute_bridge" -> R.string.appwide_gym_exercise_glute_bridge
    "bulgarian_split_squat" -> R.string.appwide_gym_exercise_bulgarian_split_squat
    "walking_lunge" -> R.string.appwide_gym_exercise_walking_lunge
    "standing_calf_raise" -> R.string.appwide_gym_exercise_standing_calf_raise
    "seated_calf_raise" -> R.string.appwide_gym_exercise_seated_calf_raise
    "incline_barbell_bench_press" ->
        R.string.appwide_gym_exercise_incline_barbell_bench_press
    "dumbbell_bench_press" -> R.string.appwide_gym_exercise_dumbbell_bench_press
    "push_up" -> R.string.appwide_gym_exercise_push_up
    "chest_fly" -> R.string.appwide_gym_exercise_chest_fly
    "cable_crossover" -> R.string.appwide_gym_exercise_cable_crossover
    "machine_chest_press" -> R.string.appwide_gym_exercise_machine_chest_press
    "one_arm_dumbbell_row" -> R.string.appwide_gym_exercise_one_arm_dumbbell_row
    "seated_cable_row" -> R.string.appwide_gym_exercise_seated_cable_row
    "chest_supported_row" -> R.string.appwide_gym_exercise_chest_supported_row
    "chin_up" -> R.string.appwide_gym_exercise_chin_up
    "face_pull" -> R.string.appwide_gym_exercise_face_pull
    "dumbbell_shoulder_press" -> R.string.appwide_gym_exercise_dumbbell_shoulder_press
    "lateral_raise" -> R.string.appwide_gym_exercise_lateral_raise
    "rear_delt_fly" -> R.string.appwide_gym_exercise_rear_delt_fly
    "hammer_curl" -> R.string.appwide_gym_exercise_hammer_curl
    "preacher_curl" -> R.string.appwide_gym_exercise_preacher_curl
    "skull_crusher" -> R.string.appwide_gym_exercise_skull_crusher
    "overhead_triceps_extension" ->
        R.string.appwide_gym_exercise_overhead_triceps_extension
    "parallel_bar_dip" -> R.string.appwide_gym_exercise_parallel_bar_dip
    "hanging_leg_raise" -> R.string.appwide_gym_exercise_hanging_leg_raise
    "cable_crunch" -> R.string.appwide_gym_exercise_cable_crunch
    "side_plank" -> R.string.appwide_gym_exercise_side_plank
    "ab_wheel_rollout" -> R.string.appwide_gym_exercise_ab_wheel_rollout
    "farmers_carry" -> R.string.appwide_gym_exercise_farmers_carry
    "kettlebell_swing" -> R.string.appwide_gym_exercise_kettlebell_swing
    "back_extension" -> R.string.appwide_gym_exercise_back_extension
    "band_pull_apart" -> R.string.appwide_gym_exercise_band_pull_apart
    "resistance_band_row" -> R.string.appwide_gym_exercise_resistance_band_row
    "treadmill_run" -> R.string.appwide_gym_exercise_treadmill_run
    "indoor_cycling" -> R.string.appwide_gym_exercise_indoor_cycling
    "rowing_ergometer" -> R.string.appwide_gym_exercise_rowing_ergometer
    "stair_climber" -> R.string.appwide_gym_exercise_stair_climber
    else -> null
}

@Composable
internal fun strengthDescriptor(value: String): String = when (value) {
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
    "rest_pause" -> stringResource(R.string.appwide_gym_rest_pause)
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

@Composable
private fun strengthTargetLabel(
    row: StrengthSetRow,
    exercise: StrengthExerciseRow,
    massUnit: MassUnit,
): String {
    val parts = mutableListOf(stringResource(R.string.strength_set_number, row.setPosition + 1))
    if (row.reps == null && row.durationS != null) {
        parts += stringResource(R.string.strength_target_seconds, row.durationS)
        return parts.joinToString(" · ")
    }
    row.loadKg?.let { loadKg ->
        val load = if (massUnit == MassUnit.POUNDS) UnitFormatter.kgToPounds(loadKg) else loadKg
        parts += stringResource(
            R.string.strength_target_load,
            load.strengthNumber(),
            massUnit.raw,
        )
    } ?: if (exercise.equipment == "bodyweight") {
        parts += stringResource(R.string.strength_descriptor_bodyweight)
    } else {
        Unit
    }
    row.reps?.let { parts += stringResource(R.string.strength_target_reps, it) }
    return parts.joinToString(" · ")
}

private fun Double.strengthNumber(): String =
    if (this % 1.0 == 0.0) toInt().toString() else "%.1f".format(this)

private fun String.strengthDouble(): Double? =
    replace(',', '.').filter { it.isDigit() || it == '.' }.toDoubleOrNull()

private fun Throwable.strengthMessage(fallback: String): String =
    message?.takeIf { it.isNotBlank() } ?: fallback
