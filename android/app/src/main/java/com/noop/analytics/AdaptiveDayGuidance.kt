package com.noop.analytics

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Evidence-gated daily guidance. This is the Kotlin twin of AdaptiveDayGuidance.swift.
 *
 * It ranks observations but never infers why a routine changed. Missing or stale evidence fails closed.
 */
object AdaptiveDayGuidance {
    const val MINIMUM_ROUTINE_NIGHTS = 5
    const val STRONG_ROUTINE_NIGHTS = 7
    const val ROUTINE_LOOKBACK_DAYS = 21
    const val LATEST_SLEEP_MAXIMUM_AGE_SECONDS = 30 * 60 * 60
    const val SHORT_SLEEP_THRESHOLD_MINUTES = 60
    const val LATE_ROUTINE_THRESHOLD_MINUTES = 90
    const val ROUTINE_DURATION_DROP_MINUTES = 45
    const val TRAVEL_THRESHOLD_SECONDS = 2 * 60 * 60
    const val TRAVEL_MAXIMUM_AGE_SECONDS = 36 * 60 * 60

    enum class Kind { TRAVEL_ADJUSTMENT, ROUTINE_RECOVERY, SLEEP_RECOVERY }
    enum class Confidence { BUILDING, STRONG }

    data class SleepDay(val day: String, val totalSleepMinutes: Double?)
    data class SleepWindow(val startSec: Long, val endSec: Long)
    data class TimeZoneChange(
        val previousOffsetSec: Int,
        val currentOffsetSec: Int,
        val observedAtSec: Long,
    )

    data class Input(
        val today: String,
        val nowSec: Long,
        val currentTimeZoneOffsetSec: Int,
        val sleepTargetMinutes: Int,
        val sleepDays: List<SleepDay>,
        val sleepWindows: List<SleepWindow>,
        val timeZoneChange: TimeZoneChange?,
    )

    data class Recommendation(
        val kind: Kind,
        val observedAtSec: Long,
        val maximumAgeSeconds: Int,
        val confidence: Confidence,
        val fingerprint: String,
        val evidence: List<String>,
    )

    fun recommendation(input: Input): Recommendation? {
        travelRecommendation(input)?.let { return it }
        val windows = eligibleWindows(input)
        routineRecommendation(input, windows)?.let { return it }
        return sleepRecommendation(input, windows)
    }

    private fun travelRecommendation(input: Input): Recommendation? {
        val change = input.timeZoneChange ?: return null
        val age = input.nowSec - change.observedAtSec
        val delta = normalizedTravelDeltaSeconds(
            previousOffsetSec = change.previousOffsetSec,
            currentOffsetSec = change.currentOffsetSec,
        )
        if (
            age !in (-5 * 60L)..TRAVEL_MAXIMUM_AGE_SECONDS.toLong() ||
            abs(change.previousOffsetSec) > 14 * 60 * 60 ||
            abs(change.currentOffsetSec) > 14 * 60 * 60 ||
            abs(delta) < TRAVEL_THRESHOLD_SECONDS
        ) return null
        return Recommendation(
            kind = Kind.TRAVEL_ADJUSTMENT,
            observedAtSec = change.observedAtSec,
            maximumAgeSeconds = TRAVEL_MAXIMUM_AGE_SECONDS,
            confidence = Confidence.STRONG,
            fingerprint =
                "travel:${change.previousOffsetSec}:${change.currentOffsetSec}:${change.observedAtSec / 3600L}",
            evidence = listOf(if (delta > 0) "timezone-east" else "timezone-west", "offset-change"),
        )
    }

    /**
     * Shortest wall-clock shift between two UTC offsets. A raw 22-hour Date Line change is the same
     * circadian shift as two hours; a raw 24-hour change leaves the local clock unchanged.
     */
    fun normalizedTravelDeltaSeconds(previousOffsetSec: Int, currentOffsetSec: Int): Int {
        val day = 24 * 60 * 60
        val halfDay = day / 2
        val raw = currentOffsetSec - previousOffsetSec
        return ((raw + halfDay) % day + day) % day - halfDay
    }

    private fun eligibleWindows(input: Input): List<SleepWindow> {
        val oldest = input.nowSec - ROUTINE_LOOKBACK_DAYS * 24L * 60L * 60L
        val seen = mutableSetOf<String>()
        val eligible = input.sleepWindows
            .filter { window ->
                val duration = window.endSec - window.startSec
                window.startSec >= oldest &&
                    window.endSec <= input.nowSec &&
                    duration in (3 * 60 * 60L)..(14 * 60 * 60L) &&
                    isOvernightOnset(window.startSec, input.currentTimeZoneOffsetSec) &&
                    seen.add("${window.startSec}:${window.endSec}")
            }
            .sortedBy { it.endSec }

        // Split or duplicated blocks from one night are one routine observation, not several.
        return eligible
            .groupBy { sleepNightKey(it.startSec, input.currentTimeZoneOffsetSec) }
            .values
            .map { windows ->
                windows.maxWithOrNull(
                    compareBy<SleepWindow> { it.endSec - it.startSec }.thenBy { it.endSec },
                )!!
            }
            .sortedBy { it.endSec }
    }

    private fun routineRecommendation(
        input: Input,
        windows: List<SleepWindow>,
    ): Recommendation? {
        val latest = windows.lastOrNull() ?: return null
        if (input.nowSec - latest.endSec > LATEST_SLEEP_MAXIMUM_AGE_SECONDS) return null
        val history = windows.dropLast(1).takeLast(14)
        if (history.size < MINIMUM_ROUTINE_NIGHTS) return null

        val baselineOnset = median(
            history.map { bedtimeCoordinate(it.startSec, input.currentTimeZoneOffsetSec) },
        )
        val latestOnset = bedtimeCoordinate(latest.startSec, input.currentTimeZoneOffsetSec)
        val delay = latestOnset - baselineOnset
        val baselineDuration = median(history.map { (it.endSec - it.startSec) / 60.0 })
        val latestDuration = (latest.endSec - latest.startSec) / 60.0
        val target = input.sleepTargetMinutes.coerceIn(5 * 60, 11 * 60).toDouble()
        val shortened =
            latestDuration <= baselineDuration - ROUTINE_DURATION_DROP_MINUTES ||
                latestDuration <= target - SHORT_SLEEP_THRESHOLD_MINUTES
        if (delay < LATE_ROUTINE_THRESHOLD_MINUTES || !shortened) return null

        return Recommendation(
            kind = Kind.ROUTINE_RECOVERY,
            observedAtSec = latest.endSec,
            maximumAgeSeconds = 18 * 60 * 60,
            confidence = if (history.size >= STRONG_ROUTINE_NIGHTS) {
                Confidence.STRONG
            } else {
                Confidence.BUILDING
            },
            fingerprint = "routine:${latest.startSec / 900L}:${latest.endSec / 900L}",
            evidence = listOf("personal-sleep-timing", "later-onset", "shorter-sleep"),
        )
    }

    private fun sleepRecommendation(
        input: Input,
        windows: List<SleepWindow>,
    ): Recommendation? {
        val target = input.sleepTargetMinutes.coerceIn(5 * 60, 11 * 60).toDouble()
        val current = input.sleepDays.lastOrNull { it.day == input.today }
        val minutes = current?.totalSleepMinutes
        if (
            minutes != null &&
            minutes.isFinite() &&
            minutes in 120.0..900.0 &&
            target - minutes >= SHORT_SLEEP_THRESHOLD_MINUTES
        ) {
            val observedAt = windows.lastOrNull()?.endSec?.takeIf { endSec ->
                input.nowSec - endSec in
                    (-5 * 60L)..LATEST_SLEEP_MAXIMUM_AGE_SECONDS.toLong()
            } ?: input.nowSec
            return Recommendation(
                kind = Kind.SLEEP_RECOVERY,
                observedAtSec = observedAt,
                maximumAgeSeconds = 18 * 60 * 60,
                confidence = Confidence.STRONG,
                fingerprint = "sleep:${input.today}:${minutes.roundToInt()}",
                evidence = listOf("current-sleep", "below-explicit-target"),
            )
        }

        val latest = windows.lastOrNull() ?: return null
        if (input.nowSec - latest.endSec > LATEST_SLEEP_MAXIMUM_AGE_SECONDS) return null
        val duration = (latest.endSec - latest.startSec) / 60.0
        if (target - duration < SHORT_SLEEP_THRESHOLD_MINUTES) return null
        return Recommendation(
            kind = Kind.SLEEP_RECOVERY,
            observedAtSec = latest.endSec,
            maximumAgeSeconds = 18 * 60 * 60,
            confidence = Confidence.BUILDING,
            fingerprint = "sleep-window:${latest.startSec / 900L}:${latest.endSec / 900L}",
            evidence = listOf("recent-sleep-window", "below-explicit-target"),
        )
    }

    private fun isOvernightOnset(epochSec: Long, offsetSec: Int): Boolean {
        val minute = localMinute(epochSec, offsetSec)
        return minute >= 18 * 60 || minute < 6 * 60
    }

    private fun sleepNightKey(epochSec: Long, offsetSec: Int): Long =
        Math.floorDiv(epochSec + offsetSec - 12L * 60L * 60L, 24L * 60L * 60L)

    private fun bedtimeCoordinate(epochSec: Long, offsetSec: Int): Double {
        val minute = localMinute(epochSec, offsetSec)
        return (if (minute < 12 * 60) minute + 24 * 60 else minute).toDouble()
    }

    private fun localMinute(epochSec: Long, offsetSec: Int): Int {
        val day = 24 * 60 * 60L
        val local = ((epochSec + offsetSec) % day + day) % day
        return (local / 60L).toInt()
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        if (sorted.isEmpty()) return 0.0
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            sorted[mid]
        }
    }
}
