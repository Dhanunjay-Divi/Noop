package com.noop.safety

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Pure policy and message construction for NOOP's manual Safety Center.
 *
 * This is not a fall detector, medical-event detector, dispatcher, or background delivery service. It
 * only describes a user-armed local reminder and prepares text the user may choose to share through the
 * operating system. Keep behavior aligned with Swift SafetyCheckInPolicy.swift.
 */
enum class SafetyShareIntent {
    NEED_HELP_NOW,
    FEEL_UNSAFE,
    MISSED_CHECK_IN,
}

/** Platform-supplied copy for the user-confirmed safety draft. */
data class SafetyShareCopy(
    val needHelpNowOpening: String,
    val feelUnsafeOpening: String,
    val missedCheckInOpening: String,
    val immediateDangerInstruction: String,
    val locationLabel: String,
    val locationCapturedFormat: String,
    val locationCapturedAccuracyFormat: String,
    val noteLabel: String,
    val preparedAtFormat: String,
    val deliveryBoundary: String,
) {
    fun opening(intent: SafetyShareIntent): String = when (intent) {
        SafetyShareIntent.NEED_HELP_NOW -> needHelpNowOpening
        SafetyShareIntent.FEEL_UNSAFE -> feelUnsafeOpening
        SafetyShareIntent.MISSED_CHECK_IN -> missedCheckInOpening
    }

    companion object {
        val English = SafetyShareCopy(
            needHelpNowOpening = "I need help now. Please call me.",
            feelUnsafeOpening = "I feel unsafe. Please call me and stay on the line if you can.",
            missedCheckInOpening = "I missed a planned check-in. Please contact me.",
            immediateDangerInstruction =
                "If you think I am in immediate danger, contact local emergency services.",
            locationLabel = "Location",
            locationCapturedFormat = "Location captured at %1\$s.",
            locationCapturedAccuracyFormat =
                "Location captured at %1\$s, accuracy about %2\$d m.",
            noteLabel = "Note",
            preparedAtFormat = "Prepared at %1\$s.",
            deliveryBoundary =
                "NOOP did not send this automatically and does not monitor or contact emergency services.",
        )
    }
}

data class SafetyLocation(
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracyMeters: Double? = null,
    val capturedAtUnix: Long,
) {
    companion object {
        const val MAXIMUM_AGE_SECONDS = 5 * 60L
        const val MAXIMUM_FUTURE_CLOCK_SKEW_SECONDS = 60L
    }

    val isValid: Boolean
        get() = latitude.isFinite() && longitude.isFinite() &&
            latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            capturedAtUnix > 0L

    fun isUsable(atUnix: Long): Boolean {
        if (!isValid || atUnix <= 0L) return false
        val age = atUnix - capturedAtUnix
        return age >= -MAXIMUM_FUTURE_CLOCK_SKEW_SECONDS && age <= MAXIMUM_AGE_SECONDS
    }
}

object SafetyShareMessage {
    const val MAX_NAME_CHARACTERS = 80
    const val MAX_NOTE_CHARACTERS = 240

    fun build(
        intent: SafetyShareIntent,
        displayName: String? = null,
        note: String? = null,
        location: SafetyLocation? = null,
        preparedAtUnix: Long,
        copy: SafetyShareCopy = SafetyShareCopy.English,
    ): String {
        val cleanName = clean(displayName, MAX_NAME_CHARACTERS)
        val cleanNote = clean(note, MAX_NOTE_CHARACTERS)
        val parts = mutableListOf<String>()
        val opening = copy.opening(intent)

        parts += if (cleanName != null) "$cleanName: $opening" else opening
        parts += copy.immediateDangerInstruction

        if (location?.isUsable(preparedAtUnix) == true) {
            parts += "${copy.locationLabel}: ${mapUrl(location)}"
            val accuracy = location.horizontalAccuracyMeters
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.roundToInt()
            parts += if (accuracy != null) {
                String.format(
                    Locale.getDefault(),
                    copy.locationCapturedAccuracyFormat,
                    utcTimestamp(location.capturedAtUnix),
                    accuracy,
                )
            } else {
                String.format(
                    Locale.getDefault(),
                    copy.locationCapturedFormat,
                    utcTimestamp(location.capturedAtUnix),
                )
            }
        }

        if (cleanNote != null) parts += "${copy.noteLabel}: $cleanNote"
        if (preparedAtUnix > 0L) {
            parts += String.format(
                Locale.getDefault(),
                copy.preparedAtFormat,
                utcTimestamp(preparedAtUnix),
            )
        }
        parts += copy.deliveryBoundary
        return parts.joinToString("\n")
    }

    internal fun mapUrl(location: SafetyLocation): String {
        val latitude = String.format(Locale.US, "%.6f", location.latitude)
        val longitude = String.format(Locale.US, "%.6f", location.longitude)
        return "https://www.google.com/maps/search/?api=1&query=$latitude,$longitude"
    }

    internal fun utcTimestamp(unix: Long): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(unix))

    internal fun clean(raw: String?, maxCharacters: Int): String? {
        if (raw == null) return null
        val collapsed = raw
            .map { if (it.isWhitespace() || it.isISOControl()) ' ' else it }
            .joinToString("")
            .trim()
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        if (collapsed.isEmpty()) return null
        return collapsed.take(maxCharacters.coerceAtLeast(0))
    }
}

sealed class SafetyCheckInState {
    data object Inactive : SafetyCheckInState()
    data class Active(val remainingSeconds: Long) : SafetyCheckInState()
    data class DueSoon(val remainingSeconds: Long) : SafetyCheckInState()
    data class Overdue(val elapsedSeconds: Long) : SafetyCheckInState()
}

object SafetyCheckInPolicy {
    const val MINIMUM_DURATION_SECONDS = 5 * 60L
    const val MAXIMUM_DURATION_SECONDS = 24 * 60 * 60L
    const val DUE_SOON_WINDOW_SECONDS = 10 * 60L

    const val NOTIFICATION_TITLE = "Personal check-in"
    const val NOTIFICATION_BODY =
        "Your timer ended. Check in with someone you trust if you still need to."

    fun clampedDurationSeconds(requested: Long): Long =
        requested.coerceIn(MINIMUM_DURATION_SECONDS, MAXIMUM_DURATION_SECONDS)

    fun dueAtUnix(startedAtUnix: Long, requestedDurationSeconds: Long): Long? {
        if (startedAtUnix <= 0L) return null
        val duration = clampedDurationSeconds(requestedDurationSeconds)
        if (startedAtUnix > Long.MAX_VALUE - duration) return null
        return startedAtUnix + duration
    }

    fun state(dueAtUnix: Long?, nowUnix: Long): SafetyCheckInState {
        if (dueAtUnix == null || dueAtUnix <= 0L || nowUnix <= 0L) return SafetyCheckInState.Inactive
        val remaining = dueAtUnix - nowUnix
        return when {
            remaining <= 0L -> SafetyCheckInState.Overdue((-remaining).coerceAtLeast(0L))
            remaining <= DUE_SOON_WINDOW_SECONDS -> SafetyCheckInState.DueSoon(remaining)
            else -> SafetyCheckInState.Active(remaining)
        }
    }

    fun statusLabel(state: SafetyCheckInState): String = when (state) {
        SafetyCheckInState.Inactive -> "No check-in timer is active."
        is SafetyCheckInState.Active -> "Check-in due in ${durationLabel(state.remainingSeconds)}."
        is SafetyCheckInState.DueSoon ->
            "Check-in due soon: ${durationLabel(state.remainingSeconds)} remaining."
        is SafetyCheckInState.Overdue ->
            "Check-in overdue by ${durationLabel(state.elapsedSeconds)}. No message was sent automatically."
    }

    internal fun durationLabel(seconds: Long): String {
        val safe = seconds.coerceAtLeast(0L)
        if (safe < 60L) return "${safe}s"
        if (safe < 3_600L) return "${safe / 60L}m"
        val hours = safe / 3_600L
        val minutes = (safe % 3_600L) / 60L
        return if (minutes == 0L) "${hours}h" else "${hours}h ${minutes}m"
    }
}
