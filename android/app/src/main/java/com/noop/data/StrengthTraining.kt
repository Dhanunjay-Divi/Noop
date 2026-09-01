package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import org.json.JSONArray
import org.json.JSONObject

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
    val scheduledWeekdaysJSON: String? = null,
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
    val planJSON: String? = null,
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

data class StrengthExercisePlan(
    val mode: String = "reps",
    val targetLoadKg: Double? = null,
    val targetDurationS: Int? = null,
    val progression: String = "double_progression",
    val loadStepKg: Double = 2.5,
    val warmupSets: Int = 0,
    val supersetGroup: Int? = null,
    val repsPerSide: Boolean = false,
    val setStyle: String = "straight",
    val dropPercent: Int = 20,
    val restPauseSeconds: Int = 15,
) {
    companion object {
        val MODES = setOf("reps", "timed")
        val PROGRESSIONS = setOf("none", "double_progression", "linear", "time")
        val SET_STYLES = setOf("straight", "drop", "rest_pause")
    }
}

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
        "horizontal_pull", "vertical_pull", "carry", "rotation", "isolation", "cardio", "other",
    )
    val SET_TYPES = setOf("warmup", "working", "drop", "rest_pause", "failure", "bodyweight")

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
        builtIn("barbell_front_squat", "Front Squat", "quadriceps", listOf("glutes", "core"), "barbell", "squat"),
        builtIn("goblet_squat", "Goblet Squat", "quadriceps", listOf("glutes", "core"), "dumbbell", "squat"),
        builtIn("hack_squat", "Hack Squat", "quadriceps", listOf("glutes"), "machine", "squat"),
        builtIn("leg_extension", "Leg Extension", "quadriceps", emptyList(), "machine", "isolation"),
        builtIn("lying_leg_curl", "Lying Leg Curl", "hamstrings", listOf("calves"), "machine", "isolation"),
        builtIn("barbell_hip_thrust", "Hip Thrust", "glutes", listOf("hamstrings"), "barbell", "hinge"),
        builtIn("glute_bridge", "Glute Bridge", "glutes", listOf("hamstrings"), "bodyweight", "hinge"),
        builtIn(
            "bulgarian_split_squat", "Bulgarian Split Squat", "quadriceps",
            listOf("glutes", "hamstrings"), "dumbbell", "lunge",
        ),
        builtIn("walking_lunge", "Walking Lunge", "quadriceps", listOf("glutes", "hamstrings"), "dumbbell", "lunge"),
        builtIn("standing_calf_raise", "Standing Calf Raise", "calves", emptyList(), "machine", "isolation"),
        builtIn("seated_calf_raise", "Seated Calf Raise", "calves", emptyList(), "machine", "isolation"),
        builtIn(
            "incline_barbell_bench_press", "Incline Bench Press", "chest",
            listOf("shoulders", "triceps"), "barbell", "horizontal_push",
        ),
        builtIn(
            "dumbbell_bench_press", "Dumbbell Bench Press", "chest",
            listOf("shoulders", "triceps"), "dumbbell", "horizontal_push",
        ),
        builtIn("push_up", "Push-up", "chest", listOf("shoulders", "triceps", "core"), "bodyweight", "horizontal_push"),
        builtIn("chest_fly", "Chest Fly", "chest", listOf("shoulders"), "dumbbell", "isolation"),
        builtIn("cable_crossover", "Cable Crossover", "chest", listOf("shoulders"), "cable", "isolation"),
        builtIn(
            "machine_chest_press", "Machine Chest Press", "chest",
            listOf("shoulders", "triceps"), "machine", "horizontal_push",
        ),
        builtIn(
            "one_arm_dumbbell_row", "One-arm Dumbbell Row", "back",
            listOf("biceps", "forearms"), "dumbbell", "horizontal_pull",
        ),
        builtIn("seated_cable_row", "Seated Cable Row", "back", listOf("biceps"), "cable", "horizontal_pull"),
        builtIn("chest_supported_row", "Chest-supported Row", "back", listOf("biceps"), "dumbbell", "horizontal_pull"),
        builtIn("chin_up", "Chin-up", "back", listOf("biceps", "forearms"), "bodyweight", "vertical_pull"),
        builtIn("face_pull", "Face Pull", "shoulders", listOf("back"), "cable", "horizontal_pull"),
        builtIn(
            "dumbbell_shoulder_press", "Dumbbell Shoulder Press", "shoulders",
            listOf("triceps"), "dumbbell", "vertical_push",
        ),
        builtIn("lateral_raise", "Lateral Raise", "shoulders", emptyList(), "dumbbell", "isolation"),
        builtIn("rear_delt_fly", "Rear Delt Fly", "shoulders", listOf("back"), "dumbbell", "isolation"),
        builtIn("hammer_curl", "Hammer Curl", "biceps", listOf("forearms"), "dumbbell", "isolation"),
        builtIn("preacher_curl", "Preacher Curl", "biceps", listOf("forearms"), "barbell", "isolation"),
        builtIn("skull_crusher", "Skull Crusher", "triceps", emptyList(), "barbell", "isolation"),
        builtIn("overhead_triceps_extension", "Overhead Triceps Extension", "triceps", emptyList(), "dumbbell", "isolation"),
        builtIn("parallel_bar_dip", "Dip", "triceps", listOf("chest", "shoulders"), "bodyweight", "vertical_push"),
        builtIn("hanging_leg_raise", "Hanging Leg Raise", "core", listOf("forearms"), "bodyweight", "isolation"),
        builtIn("cable_crunch", "Cable Crunch", "core", emptyList(), "cable", "isolation"),
        builtIn("side_plank", "Side Plank", "core", listOf("shoulders"), "bodyweight", "isolation"),
        builtIn("ab_wheel_rollout", "Ab Wheel Rollout", "core", listOf("shoulders", "back"), "other", "isolation"),
        builtIn(
            "farmers_carry", "Farmer's Carry", "full_body",
            listOf("forearms", "core", "shoulders"), "dumbbell", "carry",
        ),
        builtIn(
            "kettlebell_swing", "Kettlebell Swing", "full_body",
            listOf("glutes", "hamstrings", "core"), "kettlebell", "hinge",
        ),
        builtIn("back_extension", "Back Extension", "back", listOf("glutes", "hamstrings"), "bodyweight", "hinge"),
        builtIn("band_pull_apart", "Band Pull-apart", "shoulders", listOf("back"), "band", "horizontal_pull"),
        builtIn("resistance_band_row", "Resistance Band Row", "back", listOf("biceps"), "band", "horizontal_pull"),
        builtIn(
            "treadmill_run", "Treadmill Run", "full_body",
            listOf("quadriceps", "hamstrings", "calves"), "other", "cardio",
        ),
        builtIn(
            "indoor_cycling", "Indoor Cycling", "quadriceps",
            listOf("glutes", "hamstrings", "calves"), "other", "cardio",
        ),
        builtIn(
            "rowing_ergometer", "Rowing Ergometer", "full_body",
            listOf("back", "quadriceps", "biceps"), "other", "cardio",
        ),
        builtIn("stair_climber", "Stair Climber", "quadriceps", listOf("glutes", "calves"), "machine", "cardio"),
    )

    fun scheduledWeekdays(json: String?): List<Int> =
        runCatching {
            if (json == null) return emptyList()
            val array = JSONArray(json)
            List(array.length()) { index -> strictInt(array.get(index), "weekday[$index]") }
                .filter { it in 1..7 }
                .distinct()
                .sorted()
        }.getOrDefault(emptyList())

    fun encodeScheduledWeekdays(values: List<Int>): String? {
        val clean = values.filter { it in 1..7 }.distinct().sorted()
        return clean.takeIf { it.isNotEmpty() }?.let { JSONArray(it).toString() }
    }

    fun exercisePlan(json: String?): StrengthExercisePlan =
        json?.let(::decodedExercisePlan) ?: StrengthExercisePlan()

    fun encodeExercisePlan(plan: StrengthExercisePlan): String? {
        if (!validPlan(plan)) return null
        return JSONObject()
            .put("dropPercent", plan.dropPercent)
            .put("loadStepKg", plan.loadStepKg)
            .put("mode", plan.mode)
            .put("progression", plan.progression)
            .put("repsPerSide", plan.repsPerSide)
            .put("restPauseSeconds", plan.restPauseSeconds)
            .put("setStyle", plan.setStyle)
            .put("supersetGroup", plan.supersetGroup ?: JSONObject.NULL)
            .put("targetDurationS", plan.targetDurationS ?: JSONObject.NULL)
            .put("targetLoadKg", plan.targetLoadKg ?: JSONObject.NULL)
            .put("warmupSets", plan.warmupSets)
            .toString()
    }

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
            scheduledWeekdaysJSON = row.scheduledWeekdaysJSON?.let {
                require(scheduledWeekdays(it).isNotEmpty()) { "invalid scheduled weekdays" }
                encodeScheduledWeekdays(scheduledWeekdays(it))
            },
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
            planJSON = row.planJSON?.let {
                val plan = decodedExercisePlan(it)
                require(plan != null && encodeExercisePlan(plan) != null) {
                    "invalid strength exercise plan"
                }
                encodeExercisePlan(plan)
            },
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

    private fun validPlan(plan: StrengthExercisePlan): Boolean =
        plan.mode in StrengthExercisePlan.MODES &&
            plan.progression in StrengthExercisePlan.PROGRESSIONS &&
            (
                (plan.mode == "timed" && plan.progression in setOf("none", "time")) ||
                    (plan.mode == "reps" && plan.progression != "time")
            ) &&
            plan.setStyle in StrengthExercisePlan.SET_STYLES &&
            (plan.targetLoadKg == null ||
                (plan.targetLoadKg.isFinite() && plan.targetLoadKg > 0.0 &&
                    plan.targetLoadKg <= MAX_LOAD_KG)) &&
            (plan.targetDurationS == null || plan.targetDurationS in 1..MAX_DURATION_SECONDS) &&
            plan.loadStepKg.isFinite() && plan.loadStepKg > 0.0 && plan.loadStepKg <= 100.0 &&
            plan.warmupSets in 0..5 &&
            (plan.supersetGroup == null || plan.supersetGroup in 1..20) &&
            plan.dropPercent in 5..50 &&
            plan.restPauseSeconds in 5..60

    private fun decodedExercisePlan(json: String): StrengthExercisePlan? =
        runCatching {
            val objectValue = JSONObject(json)
            StrengthExercisePlan(
                mode = objectValue.requiredString("mode"),
                targetLoadKg = objectValue.optionalDouble("targetLoadKg"),
                targetDurationS = objectValue.optionalInt("targetDurationS"),
                progression = objectValue.requiredString("progression"),
                loadStepKg = objectValue.requiredDouble("loadStepKg"),
                warmupSets = objectValue.requiredInt("warmupSets"),
                supersetGroup = objectValue.optionalInt("supersetGroup"),
                repsPerSide = objectValue.requiredBoolean("repsPerSide"),
                setStyle = objectValue.requiredString("setStyle"),
                dropPercent = objectValue.requiredInt("dropPercent"),
                restPauseSeconds = objectValue.requiredInt("restPauseSeconds"),
            ).takeIf(::validPlan)
        }.getOrNull()

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

    private fun JSONObject.requiredValue(key: String): Any {
        require(has(key) && !isNull(key)) { "missing strength plan field: $key" }
        return get(key)
    }

    private fun JSONObject.requiredString(key: String): String =
        requiredValue(key) as? String
            ?: throw IllegalArgumentException("$key must be a string")

    private fun JSONObject.requiredBoolean(key: String): Boolean =
        requiredValue(key) as? Boolean
            ?: throw IllegalArgumentException("$key must be a boolean")

    private fun JSONObject.requiredDouble(key: String): Double {
        val value = requiredValue(key)
        require(value is Number) { "$key must be a number" }
        return value.toDouble().also { require(it.isFinite()) { "$key must be finite" } }
    }

    private fun JSONObject.optionalDouble(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        val value = get(key)
        require(value is Number) { "$key must be a number" }
        return value.toDouble().also { require(it.isFinite()) { "$key must be finite" } }
    }

    private fun JSONObject.requiredInt(key: String): Int =
        strictInt(requiredValue(key), key)

    private fun JSONObject.optionalInt(key: String): Int? {
        if (!has(key) || isNull(key)) return null
        return strictInt(get(key), key)
    }

    private fun strictInt(value: Any, key: String): Int = when (value) {
        is Byte, is Short, is Int -> (value as Number).toInt()
        is Long -> value.also {
            require(it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                "$key is outside Int range"
            }
        }.toInt()
        else -> throw IllegalArgumentException("$key must be an integer")
    }
}
