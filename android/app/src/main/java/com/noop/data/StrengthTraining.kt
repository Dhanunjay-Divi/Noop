package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import org.json.JSONArray

/**
 * Local-first strength detail. Generic [WorkoutRow] remains the session-summary substrate; these
 * normalized rows preserve exercise/routine/set detail without packing mutable JSON into a workout.
 * Load is always stored in kilograms and converted only for display.
 */
@Entity(
    tableName = "strengthExercise",
    indices = [
        Index(
            name = "idx_strengthExercise_custom_archived_name",
            value = ["isCustom", "archivedAt", "name"],
        ),
    ],
)
data class StrengthExerciseRow(
    @PrimaryKey val id: String,
    val name: String,
    val primaryMuscle: String,
    val secondaryMusclesJSON: String,
    val equipment: String,
    val movementPattern: String,
    val isCustom: Boolean,
    val archivedAt: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "strengthRoutine",
    indices = [
        Index(
            name = "idx_strengthRoutine_archived_updated",
            value = ["archivedAt", "updatedAt"],
        ),
    ],
)
data class StrengthRoutineRow(
    @PrimaryKey val id: String,
    val name: String,
    val note: String? = null,
    val archivedAt: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "strengthRoutineExercise",
    indices = [
        Index(
            name = "idx_strengthRoutineExercise_routine_position",
            value = ["routineId", "position"],
            unique = true,
        ),
    ],
)
data class StrengthRoutineExerciseRow(
    @PrimaryKey val id: String,
    val routineId: String,
    val exerciseId: String,
    val position: Int,
    val targetSets: Int = 3,
    val targetRepsMin: Int? = null,
    val targetRepsMax: Int? = null,
    val targetRPE: Double? = null,
    val restSeconds: Int = 120,
    val note: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "strengthSession",
    indices = [
        Index(name = "idx_strengthSession_startedAt", value = ["startedAt", "id"]),
    ],
)
data class StrengthSessionRow(
    @PrimaryKey val id: String,
    val routineId: String? = null,
    val name: String? = null,
    val startedAt: Long,
    val endedAt: Long? = null,
    val note: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "strengthSet",
    indices = [
        Index(
            name = "idx_strengthSet_session_order",
            value = ["sessionId", "exercisePosition", "setPosition"],
            unique = true,
        ),
        Index(
            name = "idx_strengthSet_exercise_completed",
            value = ["exerciseId", "completedAt"],
        ),
    ],
)
data class StrengthSetRow(
    @PrimaryKey val id: String,
    val sessionId: String,
    val exerciseId: String,
    val exercisePosition: Int,
    val setPosition: Int,
    val setType: String = "working",
    val reps: Int? = null,
    val loadKg: Double? = null,
    val durationS: Int? = null,
    val rpe: Double? = null,
    val completedAt: Long? = null,
    val note: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val restSeconds: Int? = null,
) {
    val volumeKg: Double?
        get() = if (completedAt != null && reps != null && loadKg != null) reps * loadKg else null
}

data class StrengthRoutineSnapshot(
    val routine: StrengthRoutineRow,
    val exercises: List<StrengthRoutineExerciseRow>,
)

data class StrengthSessionSnapshot(
    val session: StrengthSessionRow,
    val sets: List<StrengthSetRow>,
)

data class StrengthSummary(
    val sessionCount: Int,
    val completedSetCount: Int,
    val totalReps: Int,
    val loadedVolumeKg: Double,
    val loadedVolumeSetCount: Int,
)

data class StrengthExerciseProgress(
    val exerciseId: String,
    val completedSetCount: Int,
    val maxLoadKg: Double?,
    val maxReps: Int?,
    val bestSetVolumeKg: Double?,
)

/** Stable validation, starter-catalog, and storage vocabulary shared with Swift v40. */
object StrengthTrainingContract {
    const val MAX_NAME_CHARACTERS = 80
    const val MAX_NOTE_CHARACTERS = 500
    const val MAX_LOAD_KG = 2_000.0
    const val MAX_REPS = 1_000
    const val MAX_DURATION_SECONDS = 86_400
    const val MAX_REST_SECONDS = 3_600
    const val MAX_TARGET_SETS = 20

    val MUSCLES = setOf(
        "chest", "back", "shoulders", "biceps", "triceps", "forearms", "core",
        "quadriceps", "hamstrings", "glutes", "calves", "full_body", "other",
    )
    val EQUIPMENT = setOf(
        "barbell", "dumbbell", "kettlebell", "cable", "machine", "bodyweight",
        "band", "other",
    )
    val MOVEMENT_PATTERNS = setOf(
        "squat", "hinge", "lunge", "horizontal_push", "vertical_push",
        "horizontal_pull", "vertical_pull", "carry", "rotation", "isolation", "other",
    )
    val SET_TYPES = setOf("warmup", "working", "drop", "failure", "bodyweight")

    val BUILT_IN_EXERCISES: List<StrengthExerciseRow> = listOf(
        builtIn("barbell_back_squat", "Back Squat", "quadriceps", listOf("glutes", "hamstrings"), "barbell", "squat"),
        builtIn("barbell_bench_press", "Bench Press", "chest", listOf("triceps", "shoulders"), "barbell", "horizontal_push"),
        builtIn("conventional_deadlift", "Deadlift", "hamstrings", listOf("glutes", "back"), "barbell", "hinge"),
        builtIn("overhead_press", "Overhead Press", "shoulders", listOf("triceps"), "barbell", "vertical_push"),
        builtIn("bent_over_row", "Bent-over Row", "back", listOf("biceps"), "barbell", "horizontal_pull"),
        builtIn("pull_up", "Pull-up", "back", listOf("biceps"), "bodyweight", "vertical_pull"),
        builtIn("lat_pulldown", "Lat Pulldown", "back", listOf("biceps"), "cable", "vertical_pull"),
        builtIn("leg_press", "Leg Press", "quadriceps", listOf("glutes"), "machine", "squat"),
        builtIn("romanian_deadlift", "Romanian Deadlift", "hamstrings", listOf("glutes", "back"), "barbell", "hinge"),
        builtIn("dumbbell_lunge", "Dumbbell Lunge", "quadriceps", listOf("glutes", "hamstrings"), "dumbbell", "lunge"),
        builtIn("biceps_curl", "Biceps Curl", "biceps", listOf("forearms"), "dumbbell", "isolation"),
        builtIn("triceps_pushdown", "Triceps Pushdown", "triceps", emptyList(), "cable", "isolation"),
        builtIn("plank", "Plank", "core", listOf("shoulders"), "bodyweight", "isolation"),
    )

    fun validated(row: StrengthExerciseRow): StrengthExerciseRow {
        val clean = row.copy(
            id = validatedId(row.id),
            name = validatedName(row.name),
        )
        require(clean.primaryMuscle in MUSCLES) { "invalid strength muscle" }
        require(clean.equipment in EQUIPMENT) { "invalid strength equipment" }
        require(clean.movementPattern in MOVEMENT_PATTERNS) { "invalid movement pattern" }
        require(secondaryMuscles(clean.secondaryMusclesJSON) != null) {
            "invalid secondary muscles"
        }
        require(clean.createdAt > 0L && clean.updatedAt >= clean.createdAt) {
            "invalid strength timestamps"
        }
        require(clean.archivedAt == null || clean.archivedAt >= clean.createdAt) {
            "invalid strength archive time"
        }
        return clean
    }

    fun validated(row: StrengthRoutineRow): StrengthRoutineRow {
        val clean = row.copy(
            id = validatedId(row.id),
            name = validatedName(row.name),
            note = boundedText(row.note, MAX_NOTE_CHARACTERS, singleLine = false),
        )
        require(clean.createdAt > 0L && clean.updatedAt >= clean.createdAt) {
            "invalid strength timestamps"
        }
        require(clean.archivedAt == null || clean.archivedAt >= clean.createdAt) {
            "invalid strength archive time"
        }
        return clean
    }

    fun validated(row: StrengthRoutineExerciseRow): StrengthRoutineExerciseRow {
        val clean = row.copy(
            id = validatedId(row.id),
            routineId = validatedId(row.routineId),
            exerciseId = validatedId(row.exerciseId),
            note = boundedText(row.note, MAX_NOTE_CHARACTERS, singleLine = false),
        )
        require(clean.position >= 0) { "invalid strength routine position" }
        require(clean.targetSets in 1..MAX_TARGET_SETS) { "invalid target sets" }
        require(clean.restSeconds in 0..MAX_REST_SECONDS) { "invalid rest seconds" }
        clean.targetRepsMin?.let { require(it in 1..MAX_REPS) { "invalid target reps" } }
        clean.targetRepsMax?.let { require(it in 1..MAX_REPS) { "invalid target reps" } }
        if (clean.targetRepsMin != null && clean.targetRepsMax != null) {
            require(clean.targetRepsMin <= clean.targetRepsMax) { "invalid target rep range" }
        }
        validateRpe(clean.targetRPE)
        require(clean.createdAt > 0L && clean.updatedAt >= clean.createdAt) {
            "invalid strength timestamps"
        }
        return clean
    }

    fun validated(row: StrengthSessionRow): StrengthSessionRow {
        val clean = row.copy(
            id = validatedId(row.id),
            routineId = row.routineId?.let(::validatedId),
            name = boundedText(row.name, MAX_NAME_CHARACTERS, singleLine = true),
            note = boundedText(row.note, MAX_NOTE_CHARACTERS, singleLine = false),
        )
        require(clean.startedAt > 0L) { "invalid strength session start" }
        require(
            clean.endedAt == null ||
                (clean.endedAt >= clean.startedAt &&
                    clean.endedAt - clean.startedAt <= MAX_DURATION_SECONDS.toLong()),
        ) { "invalid strength session end" }
        require(clean.createdAt > 0L && clean.updatedAt >= clean.createdAt) {
            "invalid strength timestamps"
        }
        return clean
    }

    fun validated(row: StrengthSetRow): StrengthSetRow {
        val clean = row.copy(
            id = validatedId(row.id),
            sessionId = validatedId(row.sessionId),
            exerciseId = validatedId(row.exerciseId),
            note = boundedText(row.note, MAX_NOTE_CHARACTERS, singleLine = false),
        )
        require(clean.exercisePosition >= 0 && clean.setPosition >= 0) {
            "invalid strength set position"
        }
        require(clean.setType in SET_TYPES) { "invalid strength set type" }
        clean.restSeconds?.let {
            require(it in 0..MAX_REST_SECONDS) { "invalid rest seconds" }
        }
        clean.reps?.let { require(it in 1..MAX_REPS) { "invalid strength reps" } }
        clean.loadKg?.let {
            require(it.isFinite() && it > 0.0 && it <= MAX_LOAD_KG) { "invalid strength load" }
        }
        clean.durationS?.let {
            require(it in 1..MAX_DURATION_SECONDS) { "invalid strength duration" }
        }
        validateRpe(clean.rpe)
        require(clean.completedAt == null || clean.completedAt > 0L) {
            "invalid strength completion time"
        }
        require(clean.completedAt == null || clean.reps != null || clean.durationS != null) {
            "completed strength set needs reps or duration"
        }
        require(clean.createdAt > 0L && clean.updatedAt >= clean.createdAt) {
            "invalid strength timestamps"
        }
        return clean
    }

    fun secondaryMuscles(json: String): List<String>? =
        runCatching {
            val array = JSONArray(json)
            List(array.length()) { array.getString(it) }
                .takeIf { values -> values.all { it in MUSCLES } }
        }.getOrNull()

    fun encodeMuscles(values: List<String>): String = JSONArray(values).toString()

    private fun builtIn(
        id: String,
        name: String,
        primary: String,
        secondary: List<String>,
        equipment: String,
        pattern: String,
    ) = StrengthExerciseRow(
        id = id,
        name = name,
        primaryMuscle = primary,
        secondaryMusclesJSON = encodeMuscles(secondary),
        equipment = equipment,
        movementPattern = pattern,
        isCustom = false,
        createdAt = 1,
        updatedAt = 1,
    )

    private fun validatedId(value: String): String =
        value.trim().also { require(it.isNotEmpty() && it.length <= 128) { "invalid strength id" } }

    private fun validatedName(value: String): String =
        requireNotNull(boundedText(value, MAX_NAME_CHARACTERS, singleLine = true)) {
            "invalid strength name"
        }

    private fun validateRpe(value: Double?) {
        if (value == null) return
        require(value.isFinite() && value in 1.0..10.0) { "invalid strength rpe" }
    }

    private fun boundedText(value: String?, maximum: Int, singleLine: Boolean): String? {
        val cleaned = value
            ?.mapNotNull { char ->
                when {
                    singleLine && (char == '\n' || char == '\r') -> ' '
                    Character.isISOControl(char) && !(char == '\n' && !singleLine) -> null
                    else -> char
                }
            }
            ?.joinToString("")
            ?.trim()
            ?.take(maximum)
        return cleaned?.takeIf { it.isNotEmpty() }
    }
}
