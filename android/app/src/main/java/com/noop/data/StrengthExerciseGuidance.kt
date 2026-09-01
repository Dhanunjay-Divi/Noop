package com.noop.data

/**
 * NOOP-owned movement vocabulary for the native exercise demonstrator.
 *
 * These are semantic motion profiles, not third-party media identifiers. Compose and SwiftUI
 * render matching offline animations from this contract.
 */
enum class StrengthExerciseMotionProfile {
    SQUAT,
    LEG_PRESS,
    DEADLIFT,
    HIP_THRUST,
    LUNGE,
    BENCH_PRESS,
    PUSH_UP,
    CHEST_FLY,
    OVERHEAD_PRESS,
    LATERAL_RAISE,
    REAR_DELT_FLY,
    ROW,
    PULL_UP,
    LAT_PULLDOWN,
    BAND_PULL_APART,
    CURL,
    TRICEPS_PUSHDOWN,
    TRICEPS_EXTENSION,
    SKULL_CRUSHER,
    DIP,
    LEG_EXTENSION,
    LEG_CURL,
    CALF_RAISE,
    PLANK,
    SIDE_PLANK,
    HANGING_LEG_RAISE,
    CABLE_CRUNCH,
    AB_ROLLOUT,
    CARRY,
    KETTLEBELL_SWING,
    BACK_EXTENSION,
    RUN,
    CYCLE,
    ROWING_ERGOMETER,
    STAIR_CLIMB,
    GENERIC,
}

/** Stable visual identities for every exercise in NOOP's built-in catalog. */
enum class StrengthExerciseAnimationVariant(val exerciseId: String) {
    BACK_SQUAT("barbell_back_squat"),
    BENCH_PRESS("barbell_bench_press"),
    DEADLIFT("conventional_deadlift"),
    OVERHEAD_PRESS("overhead_press"),
    BENT_OVER_ROW("bent_over_row"),
    PULL_UP("pull_up"),
    LAT_PULLDOWN("lat_pulldown"),
    LEG_PRESS("leg_press"),
    ROMANIAN_DEADLIFT("romanian_deadlift"),
    DUMBBELL_LUNGE("dumbbell_lunge"),
    BICEPS_CURL("biceps_curl"),
    TRICEPS_PUSHDOWN("triceps_pushdown"),
    PLANK("plank"),
    FRONT_SQUAT("barbell_front_squat"),
    GOBLET_SQUAT("goblet_squat"),
    HACK_SQUAT("hack_squat"),
    LEG_EXTENSION("leg_extension"),
    LYING_LEG_CURL("lying_leg_curl"),
    HIP_THRUST("barbell_hip_thrust"),
    GLUTE_BRIDGE("glute_bridge"),
    BULGARIAN_SPLIT_SQUAT("bulgarian_split_squat"),
    WALKING_LUNGE("walking_lunge"),
    STANDING_CALF_RAISE("standing_calf_raise"),
    SEATED_CALF_RAISE("seated_calf_raise"),
    INCLINE_BENCH_PRESS("incline_barbell_bench_press"),
    DUMBBELL_BENCH_PRESS("dumbbell_bench_press"),
    PUSH_UP("push_up"),
    CHEST_FLY("chest_fly"),
    CABLE_CROSSOVER("cable_crossover"),
    MACHINE_CHEST_PRESS("machine_chest_press"),
    ONE_ARM_DUMBBELL_ROW("one_arm_dumbbell_row"),
    SEATED_CABLE_ROW("seated_cable_row"),
    CHEST_SUPPORTED_ROW("chest_supported_row"),
    CHIN_UP("chin_up"),
    FACE_PULL("face_pull"),
    DUMBBELL_SHOULDER_PRESS("dumbbell_shoulder_press"),
    LATERAL_RAISE("lateral_raise"),
    REAR_DELT_FLY("rear_delt_fly"),
    HAMMER_CURL("hammer_curl"),
    PREACHER_CURL("preacher_curl"),
    SKULL_CRUSHER("skull_crusher"),
    OVERHEAD_TRICEPS_EXTENSION("overhead_triceps_extension"),
    DIP("parallel_bar_dip"),
    HANGING_LEG_RAISE("hanging_leg_raise"),
    CABLE_CRUNCH("cable_crunch"),
    SIDE_PLANK("side_plank"),
    AB_WHEEL_ROLLOUT("ab_wheel_rollout"),
    FARMERS_CARRY("farmers_carry"),
    KETTLEBELL_SWING("kettlebell_swing"),
    BACK_EXTENSION("back_extension"),
    BAND_PULL_APART("band_pull_apart"),
    RESISTANCE_BAND_ROW("resistance_band_row"),
    TREADMILL_RUN("treadmill_run"),
    INDOOR_CYCLING("indoor_cycling"),
    ROWING_ERGOMETER("rowing_ergometer"),
    STAIR_CLIMBER("stair_climber"),
    ;

    companion object {
        private val byExerciseId = entries.associateBy { it.exerciseId }

        fun forExerciseId(exerciseId: String): StrengthExerciseAnimationVariant? =
            byExerciseId[exerciseId]
    }
}

data class StrengthExerciseGuide(
    val profile: StrengthExerciseMotionProfile,
    val animationVariant: StrengthExerciseAnimationVariant?,
    val cycleDurationSeconds: Float,
    val isExerciseSpecific: Boolean,
)

object StrengthExerciseGuidance {
    fun guide(exercise: StrengthExerciseRow): StrengthExerciseGuide {
        val animationVariant = if (exercise.isCustom) {
            null
        } else {
            StrengthExerciseAnimationVariant.forExerciseId(exercise.id)
        }
        val profile = if (exercise.isCustom) fallbackProfile(exercise) else builtInProfile(exercise)
        return StrengthExerciseGuide(
            profile = profile,
            animationVariant = animationVariant,
            cycleDurationSeconds = cycleDuration(profile),
            isExerciseSpecific = animationVariant != null &&
                profile != StrengthExerciseMotionProfile.GENERIC,
        )
    }

    private fun builtInProfile(exercise: StrengthExerciseRow): StrengthExerciseMotionProfile =
        when (exercise.id) {
            "barbell_back_squat", "barbell_front_squat", "goblet_squat", "hack_squat" ->
                StrengthExerciseMotionProfile.SQUAT
            "leg_press" -> StrengthExerciseMotionProfile.LEG_PRESS
            "conventional_deadlift", "romanian_deadlift" ->
                StrengthExerciseMotionProfile.DEADLIFT
            "barbell_hip_thrust", "glute_bridge" ->
                StrengthExerciseMotionProfile.HIP_THRUST
            "dumbbell_lunge", "bulgarian_split_squat", "walking_lunge" ->
                StrengthExerciseMotionProfile.LUNGE
            "barbell_bench_press", "incline_barbell_bench_press",
            "dumbbell_bench_press", "machine_chest_press" ->
                StrengthExerciseMotionProfile.BENCH_PRESS
            "push_up" -> StrengthExerciseMotionProfile.PUSH_UP
            "chest_fly", "cable_crossover" -> StrengthExerciseMotionProfile.CHEST_FLY
            "overhead_press", "dumbbell_shoulder_press" ->
                StrengthExerciseMotionProfile.OVERHEAD_PRESS
            "lateral_raise" -> StrengthExerciseMotionProfile.LATERAL_RAISE
            "rear_delt_fly", "face_pull" -> StrengthExerciseMotionProfile.REAR_DELT_FLY
            "bent_over_row", "one_arm_dumbbell_row", "seated_cable_row",
            "chest_supported_row", "resistance_band_row" ->
                StrengthExerciseMotionProfile.ROW
            "pull_up", "chin_up" -> StrengthExerciseMotionProfile.PULL_UP
            "lat_pulldown" -> StrengthExerciseMotionProfile.LAT_PULLDOWN
            "band_pull_apart" -> StrengthExerciseMotionProfile.BAND_PULL_APART
            "biceps_curl", "hammer_curl", "preacher_curl" ->
                StrengthExerciseMotionProfile.CURL
            "triceps_pushdown" -> StrengthExerciseMotionProfile.TRICEPS_PUSHDOWN
            "overhead_triceps_extension" -> StrengthExerciseMotionProfile.TRICEPS_EXTENSION
            "skull_crusher" -> StrengthExerciseMotionProfile.SKULL_CRUSHER
            "parallel_bar_dip" -> StrengthExerciseMotionProfile.DIP
            "leg_extension" -> StrengthExerciseMotionProfile.LEG_EXTENSION
            "lying_leg_curl" -> StrengthExerciseMotionProfile.LEG_CURL
            "standing_calf_raise", "seated_calf_raise" ->
                StrengthExerciseMotionProfile.CALF_RAISE
            "plank" -> StrengthExerciseMotionProfile.PLANK
            "side_plank" -> StrengthExerciseMotionProfile.SIDE_PLANK
            "hanging_leg_raise" -> StrengthExerciseMotionProfile.HANGING_LEG_RAISE
            "cable_crunch" -> StrengthExerciseMotionProfile.CABLE_CRUNCH
            "ab_wheel_rollout" -> StrengthExerciseMotionProfile.AB_ROLLOUT
            "farmers_carry" -> StrengthExerciseMotionProfile.CARRY
            "kettlebell_swing" -> StrengthExerciseMotionProfile.KETTLEBELL_SWING
            "back_extension" -> StrengthExerciseMotionProfile.BACK_EXTENSION
            "treadmill_run" -> StrengthExerciseMotionProfile.RUN
            "indoor_cycling" -> StrengthExerciseMotionProfile.CYCLE
            "rowing_ergometer" -> StrengthExerciseMotionProfile.ROWING_ERGOMETER
            "stair_climber" -> StrengthExerciseMotionProfile.STAIR_CLIMB
            else -> fallbackProfile(exercise)
        }

    private fun fallbackProfile(exercise: StrengthExerciseRow): StrengthExerciseMotionProfile =
        when (exercise.movementPattern) {
            "squat" -> StrengthExerciseMotionProfile.SQUAT
            "hinge" -> StrengthExerciseMotionProfile.DEADLIFT
            "lunge" -> StrengthExerciseMotionProfile.LUNGE
            "horizontal_push" -> if (exercise.equipment == "bodyweight") {
                StrengthExerciseMotionProfile.PUSH_UP
            } else {
                StrengthExerciseMotionProfile.BENCH_PRESS
            }
            "vertical_push" -> StrengthExerciseMotionProfile.OVERHEAD_PRESS
            "horizontal_pull" -> StrengthExerciseMotionProfile.ROW
            "vertical_pull" -> if (exercise.equipment == "bodyweight") {
                StrengthExerciseMotionProfile.PULL_UP
            } else {
                StrengthExerciseMotionProfile.LAT_PULLDOWN
            }
            "carry" -> StrengthExerciseMotionProfile.CARRY
            "cardio" -> StrengthExerciseMotionProfile.RUN
            else -> StrengthExerciseMotionProfile.GENERIC
        }

    private fun cycleDuration(profile: StrengthExerciseMotionProfile): Float = when (profile) {
        StrengthExerciseMotionProfile.RUN,
        StrengthExerciseMotionProfile.CYCLE,
        StrengthExerciseMotionProfile.ROWING_ERGOMETER,
        StrengthExerciseMotionProfile.STAIR_CLIMB,
        StrengthExerciseMotionProfile.CARRY,
        -> 1.6f
        StrengthExerciseMotionProfile.KETTLEBELL_SWING -> 2.0f
        StrengthExerciseMotionProfile.PLANK,
        StrengthExerciseMotionProfile.SIDE_PLANK,
        -> 3.2f
        StrengthExerciseMotionProfile.GENERIC -> 3.0f
        else -> 2.6f
    }
}
