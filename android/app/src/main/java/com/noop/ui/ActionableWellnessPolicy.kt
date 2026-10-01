package com.noop.ui

internal object ActionableWellnessPolicy {
    const val BREATHING_DURATION_SECONDS = 60
    const val MOVEMENT_DURATION_SECONDS = 120

    fun elapsedSeconds(
        startedAtElapsedRealtimeMs: Long,
        nowElapsedRealtimeMs: Long,
    ): Int {
        val elapsedMs =
            (nowElapsedRealtimeMs - startedAtElapsedRealtimeMs).coerceAtLeast(0L)
        return (elapsedMs / 1_000L)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }

    fun shouldCompleteBreathingSession(
        isOneMinuteSession: Boolean,
        elapsedSeconds: Int,
    ): Boolean =
        isOneMinuteSession && elapsedSeconds >= BREATHING_DURATION_SECONDS

    fun shouldStopBreathingForBondTransition(
        wasBonded: Boolean,
        isBonded: Boolean,
        isRunning: Boolean,
    ): Boolean = isRunning && wasBonded && !isBonded

    fun movementRemainingSecondsAfterTick(remainingSeconds: Int): Int =
        (remainingSeconds - 1).coerceAtLeast(0)

    fun movementRemainingSeconds(
        startedAtElapsedRealtimeMs: Long,
        nowElapsedRealtimeMs: Long,
    ): Int {
        val elapsedSeconds = elapsedSeconds(
            startedAtElapsedRealtimeMs,
            nowElapsedRealtimeMs,
        )
        return (MOVEMENT_DURATION_SECONDS - elapsedSeconds).coerceAtLeast(0)
    }

    fun movementProgress(remainingSeconds: Int): Float {
        val boundedRemaining =
            remainingSeconds.coerceIn(0, MOVEMENT_DURATION_SECONDS)
        return (MOVEMENT_DURATION_SECONDS - boundedRemaining).toFloat() /
            MOVEMENT_DURATION_SECONDS.toFloat()
    }
}
