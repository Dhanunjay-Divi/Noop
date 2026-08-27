package com.noop.ble

import com.noop.oura.OuraDriverPhase

/** Banked history is durable input, never a live HR/R-R/wear update. */
internal object OuraLivePublication {
    fun permits(historyEnvelope: Boolean): Boolean = !historyEnvelope

    fun requiresLiveHrShutdown(
        reachedStreaming: Boolean,
        driverPhase: OuraDriverPhase?,
    ): Boolean = reachedStreaming || driverPhase == OuraDriverPhase.EnablingLiveHR

    fun permitsCurrentState(
        historyEnvelope: Boolean,
        eventUnixSeconds: Long?,
        now: Long,
        toleranceSeconds: Long = 120,
    ): Boolean {
        if (!historyEnvelope) return true
        val timestamp = eventUnixSeconds ?: return false
        return kotlin.math.abs(timestamp - now) <= toleranceSeconds
    }
}

/** Missing history time remains missing; only a real live push may retain its captured arrival time. */
internal object OuraPendingAnchorPolicy {
    fun fallbackTimestamp(historyEnvelope: Boolean, liveArrivalTimestamp: Int?): Int? =
        if (historyEnvelope) null else liveArrivalTimestamp
}
