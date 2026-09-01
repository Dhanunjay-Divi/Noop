package com.noop.analytics

import kotlin.math.abs

/**
 * Sustained-exertion guidance for a user-started workout.
 *
 * Kotlin twin of WorkoutCautionPolicy.swift. HRmax is an exertion reference, not a medical limit, and
 * PAUSE_AND_ASSESS never means a medical event was detected.
 */
class WorkoutCautionPolicy(
    private val config: Config,
    private val startTs: Long,
) {
    data class Config(val hrMax: Double)

    enum class Status { WARMUP, ACTIVE, STALE }
    enum class Level { COMFORTABLE, HIGH, VERY_HIGH }
    enum class Cue { EASE_OFF, PAUSE_AND_ASSESS, RECOVERED }

    data class Output(
        val status: Status,
        val level: Level,
        val smoothedBpm: Double?,
        val sampleArrived: Boolean,
        val cue: Cue?,
    )

    private data class Reading(val ts: Long, val bpm: Int)

    private val buffer = ArrayDeque<Reading>()
    private var lastValidTs: Long? = null
    private var lastAcceptedBpm: Double? = null
    private var pendingJumpBpm: Double? = null
    private var pendingJumpAt: Long? = null
    private var easeSince: Long? = null
    private var pauseSince: Long? = null
    private var lastEaseAt: Long? = null
    private var lastPauseAt: Long? = null
    private var lastCueAt: Long? = null
    private var recoveryArmed = false

    fun update(now: Long, bpm: Int?): Output {
        if (lastValidTs?.let { now - it > STALE_AFTER_SEC } == true) resetAfterGap()

        var sampleArrived = false
        if (bpm != null && accept(bpm, now)) {
            buffer.addLast(Reading(now, bpm))
            lastValidTs = now
            lastAcceptedBpm = bpm.toDouble()
            sampleArrived = true
        }

        while (buffer.firstOrNull()?.ts?.let { it < now - SMOOTHING_WINDOW_SEC } == true) {
            buffer.removeFirst()
        }
        val stale = lastValidTs?.let { now - it > STALE_AFTER_SEC } ?: true
        if (stale || buffer.isEmpty()) {
            return Output(Status.STALE, Level.COMFORTABLE, null, sampleArrived, null)
        }

        val smoothed = median(buffer.map { it.bpm.toDouble() })
        val pauseThreshold = config.hrMax * PAUSE_FRACTION_OF_MAX
        val easeThreshold = config.hrMax * EASE_FRACTION_OF_MAX
        val level = when {
            smoothed >= pauseThreshold -> Level.VERY_HIGH
            smoothed >= easeThreshold -> Level.HIGH
            else -> Level.COMFORTABLE
        }

        if (smoothed >= pauseThreshold) {
            if (pauseSince == null) pauseSince = now
        } else if (smoothed < config.hrMax * PAUSE_RESET_FRACTION_OF_MAX) {
            pauseSince = null
        }
        if (smoothed >= easeThreshold) {
            if (easeSince == null) easeSince = now
        } else if (smoothed < config.hrMax * EASE_RESET_FRACTION_OF_MAX) {
            easeSince = null
        }

        val status = if (now - startTs < WARMUP_SEC) Status.WARMUP else Status.ACTIVE
        if (status != Status.ACTIVE || !sampleArrived) {
            return Output(status, level, smoothed, sampleArrived, null)
        }

        var cue: Cue? = null
        val globalReady = lastCueAt?.let { now - it >= MINIMUM_CUE_GAP_SEC } ?: true
        if (recoveryArmed && smoothed < config.hrMax * EASE_RESET_FRACTION_OF_MAX) {
            cue = Cue.RECOVERED
            recoveryArmed = false
        } else if (
            globalReady &&
            pauseSince?.let { now - it >= PAUSE_DWELL_SEC } == true &&
            (lastPauseAt?.let { now - it >= PAUSE_COOLDOWN_SEC } ?: true)
        ) {
            cue = Cue.PAUSE_AND_ASSESS
            lastPauseAt = now
            lastCueAt = now
            pauseSince = now
            easeSince = now
            recoveryArmed = true
        } else if (
            globalReady &&
            smoothed < pauseThreshold &&
            easeSince?.let { now - it >= EASE_DWELL_SEC } == true &&
            (lastEaseAt?.let { now - it >= EASE_COOLDOWN_SEC } ?: true)
        ) {
            cue = Cue.EASE_OFF
            lastEaseAt = now
            lastCueAt = now
            easeSince = now
            recoveryArmed = true
        }

        return Output(status, level, smoothed, sampleArrived, cue)
    }

    private fun accept(bpm: Int, now: Long): Boolean {
        val value = bpm.toDouble()
        if (
            !config.hrMax.isFinite() ||
            config.hrMax !in 100.0..240.0 ||
            value < MIN_PLAUSIBLE_BPM ||
            value > MAX_PLAUSIBLE_BPM
        ) return false

        val prior = lastAcceptedBpm
        val priorAt = lastValidTs
        if (
            prior == null ||
            priorAt == null ||
            now - priorAt > SMOOTHING_WINDOW_SEC ||
            abs(value - prior) <= MAX_JUMP_BPM
        ) {
            pendingJumpBpm = null
            pendingJumpAt = null
            return true
        }

        val pending = pendingJumpBpm
        val pendingAt = pendingJumpAt
        if (
            pending != null &&
            pendingAt != null &&
            now - pendingAt <= JUMP_CORROBORATION_SEC &&
            abs(value - pending) <= JUMP_CORROBORATION_BPM
        ) {
            pendingJumpBpm = null
            pendingJumpAt = null
            return true
        }
        pendingJumpBpm = value
        pendingJumpAt = now
        return false
    }

    private fun resetAfterGap() {
        buffer.clear()
        easeSince = null
        pauseSince = null
        pendingJumpBpm = null
        pendingJumpAt = null
        recoveryArmed = false
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            sorted[mid]
        }
    }

    companion object {
        const val EASE_FRACTION_OF_MAX = 0.90
        const val PAUSE_FRACTION_OF_MAX = 0.97
        const val EASE_RESET_FRACTION_OF_MAX = 0.87
        const val PAUSE_RESET_FRACTION_OF_MAX = 0.94
        const val SMOOTHING_WINDOW_SEC = 12L
        const val STALE_AFTER_SEC = 8L
        const val WARMUP_SEC = 60L
        const val EASE_DWELL_SEC = 45L
        const val PAUSE_DWELL_SEC = 45L
        const val EASE_COOLDOWN_SEC = 5L * 60L
        const val PAUSE_COOLDOWN_SEC = 10L * 60L
        const val MINIMUM_CUE_GAP_SEC = 90L
        const val MIN_PLAUSIBLE_BPM = 25.0
        const val MAX_PLAUSIBLE_BPM = 240.0
        const val MAX_JUMP_BPM = 45.0
        const val JUMP_CORROBORATION_SEC = 5L
        const val JUMP_CORROBORATION_BPM = 8.0
    }
}
