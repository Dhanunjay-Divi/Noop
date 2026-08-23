package com.noop.notif

import kotlin.math.roundToInt

/** One local wall-clock hydration-reminder slot. [epochDay] is LocalDate.toEpochDay(). */
internal data class HydrationReminderSlot(
    val epochDay: Long,
    val minuteOfDay: Int,
) {
    val key: String get() = "$epochDay:$minuteOfDay"
    val absoluteMinute: Long get() = epochDay * HydrationReminderPolicy.MINUTES_PER_DAY + minuteOfDay
}

internal enum class HydrationAdaptiveReason {
    HIGHER_EFFORT,
    ACTIVE_DAY,
    BEHIND_GOAL,
    AHEAD_OF_GOAL,
}

internal data class HydrationAdaptiveContext(
    val effort: Double?,
    val consumedMl: Double?,
    val goalMl: Int?,
    val minuteOfDay: Int,
)

internal data class HydrationAdaptivePlan(
    val intervalMinutes: Int,
    val reasons: List<HydrationAdaptiveReason>,
)

/**
 * Pure schedule, de-dup and privacy policy for opt-in hydration reminders.
 *
 * The window is start-inclusive/end-exclusive. A matching start/end means all day, which is both useful
 * and less surprising than silently disabling reminders. Overnight windows are supported (for example,
 * 20:00 -> 02:00). Runtime scheduling converts these local slots to instants in the device time zone, so
 * daylight-saving changes are handled by java.time rather than fixed 24-hour arithmetic.
 */
internal object HydrationReminderPolicy {
    const val MINUTES_PER_DAY = 24L * 60L
    const val DEFAULT_INTERVAL_MINUTES = 120
    const val DEFAULT_START_MINUTES = 8 * 60
    const val DEFAULT_END_MINUTES = 21 * 60
    const val MIN_INTERVAL_MINUTES = 60
    const val MAX_INTERVAL_MINUTES = 240
    const val DELIVERY_GRACE_MINUTES = 45

    fun clampMinuteOfDay(raw: Int): Int = raw.coerceIn(0, MINUTES_PER_DAY.toInt() - 1)

    fun clampIntervalMinutes(raw: Int): Int =
        raw.coerceIn(MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES)

    /**
     * Conservatively adjusts a user-selected base interval from signals already available on-device.
     * Missing or non-finite values are ignored rather than estimated. This changes reminder timing only;
     * it never records intake, infers dehydration, or changes any health score.
     */
    fun adaptivePlan(
        baseIntervalMinutes: Int,
        startMinutes: Int,
        endMinutes: Int,
        context: HydrationAdaptiveContext,
    ): HydrationAdaptivePlan {
        var adjustment = 0
        val reasons = mutableListOf<HydrationAdaptiveReason>()

        val effort = context.effort
        if (effort != null && effort.isFinite()) {
            when {
                effort >= 70.0 -> {
                    adjustment -= 30
                    reasons += HydrationAdaptiveReason.HIGHER_EFFORT
                }
                effort >= 40.0 -> {
                    adjustment -= 15
                    reasons += HydrationAdaptiveReason.ACTIVE_DAY
                }
            }
        }

        val start = clampMinuteOfDay(startMinutes)
        val end = clampMinuteOfDay(endMinutes)
        val span = Math.floorMod(end - start, MINUTES_PER_DAY.toInt())
        val duration = if (span == 0) MINUTES_PER_DAY.toInt() else span
        val elapsed = Math.floorMod(clampMinuteOfDay(context.minuteOfDay) - start, MINUTES_PER_DAY.toInt())
        val consumed = context.consumedMl
        val goal = context.goalMl
        if (elapsed < duration &&
            consumed != null && consumed.isFinite() &&
            goal != null && goal > 0
        ) {
            val expected = elapsed.toDouble() / duration.toDouble()
            val actual = consumed.coerceAtLeast(0.0) / goal.toDouble()
            when {
                expected >= 0.25 && actual < expected - 0.20 -> {
                    adjustment -= 15
                    reasons += HydrationAdaptiveReason.BEHIND_GOAL
                }
                actual > expected + 0.25 -> {
                    adjustment += 15
                    reasons += HydrationAdaptiveReason.AHEAD_OF_GOAL
                }
            }
        }

        adjustment = adjustment.coerceIn(-60, 30)
        val adjusted = clampIntervalMinutes(baseIntervalMinutes) + adjustment
        val stepped = (adjusted.toDouble() / 15.0).roundToInt() * 15
        return HydrationAdaptivePlan(
            intervalMinutes = clampIntervalMinutes(stepped),
            reasons = reasons,
        )
    }

    /** Local minutes at which a reminder is due each day, sorted in clock order. */
    fun slotMinutes(
        startMinutes: Int,
        endMinutes: Int,
        intervalMinutes: Int,
    ): List<Int> {
        val start = clampMinuteOfDay(startMinutes)
        val end = clampMinuteOfDay(endMinutes)
        val interval = clampIntervalMinutes(intervalMinutes)
        val duration = when {
            start == end -> MINUTES_PER_DAY.toInt()
            end > start -> end - start
            else -> end + MINUTES_PER_DAY.toInt() - start
        }
        return buildList {
            var offset = 0
            while (offset < duration) {
                add((start + offset) % MINUTES_PER_DAY.toInt())
                offset += interval
            }
        }.distinct().sorted()
    }

    /** Latest slot no more than [graceMinutes] late, or null when no reminder is currently due. */
    fun latestDueSlot(
        epochDay: Long,
        minuteOfDay: Int,
        startMinutes: Int,
        endMinutes: Int,
        intervalMinutes: Int,
        graceMinutes: Int = DELIVERY_GRACE_MINUTES,
    ): HydrationReminderSlot? {
        val now = epochDay * MINUTES_PER_DAY + clampMinuteOfDay(minuteOfDay)
        val grace = graceMinutes.coerceAtLeast(0)
        return slotMinutes(startMinutes, endMinutes, intervalMinutes)
            .flatMap { minute ->
                listOf(
                    HydrationReminderSlot(epochDay - 1L, minute),
                    HydrationReminderSlot(epochDay, minute),
                )
            }
            .filter { it.absoluteMinute <= now && now - it.absoluteMinute <= grace }
            .maxByOrNull { it.absoluteMinute }
    }

    /** First future local slot, strictly after [minuteOfDay] on [epochDay]. */
    fun nextSlot(
        epochDay: Long,
        minuteOfDay: Int,
        startMinutes: Int,
        endMinutes: Int,
        intervalMinutes: Int,
    ): HydrationReminderSlot {
        val now = epochDay * MINUTES_PER_DAY + clampMinuteOfDay(minuteOfDay)
        return slotMinutes(startMinutes, endMinutes, intervalMinutes)
            .flatMap { minute ->
                listOf(
                    HydrationReminderSlot(epochDay, minute),
                    HydrationReminderSlot(epochDay + 1L, minute),
                )
            }
            .filter { it.absoluteMinute > now }
            .minBy { it.absoluteMinute }
    }

    private fun absoluteMinuteFromKey(key: String?): Long? {
        if (key == null) return null
        val parts = key.split(':', limit = 2)
        if (parts.size != 2) return null
        val epochDay = parts[0].toLongOrNull() ?: return null
        val minute = parts[1].toIntOrNull()?.takeIf { it in 0 until MINUTES_PER_DAY.toInt() }
            ?: return null
        return epochDay * MINUTES_PER_DAY + minute
    }

    /**
     * A changed adaptive interval can realign wall-clock slots. Keep separate phone and wrist lanes,
     * but never let that realignment produce two occurrences inside the minimum supported interval.
     */
    private fun sufficientlySeparated(currentSlotKey: String?, previousSlotKey: String?): Boolean {
        if (currentSlotKey == null) return false
        if (previousSlotKey == null) return true
        if (currentSlotKey == previousSlotKey) return false
        val current = absoluteMinuteFromKey(currentSlotKey) ?: return true
        val previous = absoluteMinuteFromKey(previousSlotKey) ?: return true
        return current - previous >= MIN_INTERVAL_MINUTES.toLong()
    }

    fun shouldNotify(enabled: Boolean, currentSlotKey: String?, lastNotifiedSlotKey: String?): Boolean =
        enabled && sufficientlySeparated(currentSlotKey, lastNotifiedSlotKey)

    fun shouldEscalateAfterTapWindow(
        enabled: Boolean,
        bandFirst: Boolean,
        currentSlotKey: String?,
        lastConfirmedSlotKey: String?,
        lastNotifiedSlotKey: String?,
    ): Boolean = enabled && bandFirst && currentSlotKey != null &&
        currentSlotKey != lastConfirmedSlotKey &&
        sufficientlySeparated(currentSlotKey, lastNotifiedSlotKey)

    /** Strap haptics require every trust gate; a remembered/cached HR is not a fresh live sample. */
    fun shouldBuzzStrap(
        enabled: Boolean,
        strapBuzzEnabled: Boolean,
        wristAlertsMasterOn: Boolean,
        connected: Boolean,
        bonded: Boolean,
        encryptedBond: Boolean,
        worn: Boolean,
        freshLiveSample: Boolean,
        inQuietHours: Boolean,
        currentSlotKey: String?,
        lastBuzzedSlotKey: String?,
    ): Boolean = enabled && strapBuzzEnabled && wristAlertsMasterOn &&
        connected && bonded && encryptedBond && worn && freshLiveSample && !inQuietHours &&
        sufficientlySeparated(currentSlotKey, lastBuzzedSlotKey)

    /** Generic lock-screen copy: deliberately contains no intake, goal, score or biometric value. */
    fun notificationCopy(): Pair<String, String> =
        "Hydration check-in" to "Take a moment to drink some water if you need it."
}
