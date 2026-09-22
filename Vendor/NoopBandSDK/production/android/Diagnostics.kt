package com.noop.bandsdk

import java.util.ArrayDeque

enum class BandDiagnosticKind {
    DISCOVERY,
    CONNECTION,
    AUTHENTICATION,
    CAPABILITY,
    COMMAND,
    LIVE,
    HISTORY,
    RECONNECT,
    FIRMWARE,
    PRESSURE,
}

enum class BandDiagnosticOutcome {
    BEGAN,
    STAGED,
    COMPLETED,
    CANCELLED,
    REJECTED,
    TIMED_OUT,
    STALE,
    INTERRUPTED,
    FAILED,
}

enum class BandCountBucket {
    ZERO,
    ONE,
    TWO_TO_TEN,
    ELEVEN_TO_HUNDRED,
    OVER_HUNDRED;

    companion object {
        fun from(count: Int): BandCountBucket = when {
            count <= 0 -> ZERO
            count == 1 -> ONE
            count <= 10 -> TWO_TO_TEN
            count <= 100 -> ELEVEN_TO_HUNDRED
            else -> OVER_HUNDRED
        }
    }
}

enum class BandDurationBucket {
    UNDER_SECOND,
    ONE_TO_FIVE_SECONDS,
    SIX_TO_THIRTY_SECONDS,
    THIRTY_ONE_TO_THREE_HUNDRED_SECONDS,
    OVER_THREE_HUNDRED_SECONDS;

    companion object {
        fun from(milliseconds: Int): BandDurationBucket = when {
            milliseconds < 1_000 -> UNDER_SECOND
            milliseconds <= 5_000 -> ONE_TO_FIVE_SECONDS
            milliseconds <= 30_000 -> SIX_TO_THIRTY_SECONDS
            milliseconds <= 300_000 -> THIRTY_ONE_TO_THREE_HUNDRED_SECONDS
            else -> OVER_THREE_HUNDRED_SECONDS
        }
    }
}

data class BandDiagnosticEvent(
    val kind: BandDiagnosticKind,
    val outcome: BandDiagnosticOutcome,
    val countBucket: BandCountBucket? = null,
    val durationBucket: BandDurationBucket? = null,
    val failureCategory: BandFailureCategory? = null,
)

class BandDiagnosticsRecorder(capacity: Int = 128) {
    private val capacity = capacity.coerceIn(1, 512)
    private val events = ArrayDeque<BandDiagnosticEvent>()

    @Synchronized
    fun record(event: BandDiagnosticEvent) {
        append(event)
    }

    @Synchronized
    fun record(events: List<BandDiagnosticEvent>) {
        events.forEach(::append)
    }

    @Synchronized
    fun recordCoalescingConsecutive(event: BandDiagnosticEvent) {
        val last = events.peekLast()
        if (
            last?.kind == event.kind &&
            last.outcome == event.outcome &&
            last.failureCategory == null &&
            event.failureCategory == null
        ) {
            events.removeLast()
            events.addLast(event)
            return
        }
        append(event)
    }

    private fun append(event: BandDiagnosticEvent) {
        if (events.size == capacity) {
            events.removeFirst()
        }
        events.addLast(event)
    }

    @Synchronized
    fun snapshot(): List<BandDiagnosticEvent> = events.toList()
}
