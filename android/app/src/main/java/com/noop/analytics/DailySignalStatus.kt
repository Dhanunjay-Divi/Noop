package com.noop.analytics

/**
 * Conservative presentation state for the Daily Signal header.
 *
 * This combines existing engine outputs. It does not calculate another score and never turns missing
 * or thin data into a reassuring green state.
 */
enum class DailySignalStatus {
    BUILDING,
    STEADY,
    WATCH,
    ALERT;

    companion object {
        fun resolve(
            readiness: ReadinessEngine.Readiness?,
            illness: IllnessSignalEngine.Result?,
        ): DailySignalStatus {
            when (illness?.displayState) {
                IllnessSignalEngine.DisplayState.ALERT -> return ALERT
                IllnessSignalEngine.DisplayState.WATCH -> return WATCH
                IllnessSignalEngine.DisplayState.BUILDING -> return BUILDING
                IllnessSignalEngine.DisplayState.STEADY, null -> Unit
            }

            if (readiness == null || readiness.confidence != ScoreConfidence.SOLID) return BUILDING
            return when (readiness.level) {
                ReadinessEngine.Level.PRIMED, ReadinessEngine.Level.BALANCED -> STEADY
                ReadinessEngine.Level.STRAINED, ReadinessEngine.Level.RUNDOWN -> WATCH
                ReadinessEngine.Level.INSUFFICIENT -> BUILDING
            }
        }
    }
}
