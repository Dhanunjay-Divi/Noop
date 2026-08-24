package com.noop.analytics

/**
 * Describes where today's measured Effort sits relative to an evidence-gated personal range.
 *
 * This is presentation state, not a training prescription. Invalid or missing inputs fail closed so
 * callers never turn a guessed score or range into guidance. Swift twin: DailyEffortGuidance.swift.
 */
object DailyEffortGuidance {
    enum class State { UNAVAILABLE, BELOW_RANGE, IN_RANGE, ABOVE_RANGE }

    data class Result(
        val state: State,
        val current: Double?,
        val range: DailyActionPlanner.EffortRange?,
        val remainingToLower: Double?,
        /** Current Effort normalized to NOOP's canonical 0..100 axis. */
        val progress: Double,
    )

    fun evaluate(
        currentEffort: Double?,
        range: DailyActionPlanner.EffortRange?,
    ): Result {
        if (currentEffort == null ||
            !currentEffort.isFinite() ||
            currentEffort !in 0.0..100.0 ||
            range == null ||
            range.lower !in 0..100 ||
            range.upper !in 0..100 ||
            range.lower > range.upper
        ) {
            return Result(State.UNAVAILABLE, null, null, null, 0.0)
        }

        val state = when {
            currentEffort < range.lower -> State.BELOW_RANGE
            currentEffort <= range.upper -> State.IN_RANGE
            else -> State.ABOVE_RANGE
        }
        return Result(
            state = state,
            current = currentEffort,
            range = range,
            remainingToLower = (range.lower - currentEffort).coerceAtLeast(0.0),
            progress = currentEffort / 100.0,
        )
    }
}
