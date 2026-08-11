package com.noop.notif

/** One local wall-clock hydration-reminder slot. [epochDay] is LocalDate.toEpochDay(). */
internal data class HydrationReminderSlot(
    val epochDay: Long,
    val minuteOfDay: Int,
) {
    val key: String get() = "$epochDay:$minuteOfDay"
    val absoluteMinute: Long get() = epochDay * HydrationReminderPolicy.MINUTES_PER_DAY + minuteOfDay
}

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

    fun shouldNotify(enabled: Boolean, currentSlotKey: String?, lastNotifiedSlotKey: String?): Boolean =
        enabled && currentSlotKey != null && currentSlotKey != lastNotifiedSlotKey

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
        currentSlotKey != null && currentSlotKey != lastBuzzedSlotKey

    /** Generic lock-screen copy: deliberately contains no intake, goal, score or biometric value. */
    fun notificationCopy(): Pair<String, String> =
        "Hydration check-in" to "Take a moment to drink some water if you need it."
}
