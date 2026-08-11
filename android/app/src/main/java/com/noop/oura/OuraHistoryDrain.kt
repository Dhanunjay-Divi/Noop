package com.noop.oura

/**
 * Pure decision core for one Oura GetEvents history drain.
 *
 * The 0x11 summary reports a remaining-byte count, not a cursor. In-session continuation advances from
 * the newest observed event envelope. The durable resume cursor advances independently, and only from
 * a sample the live source placed on a real ring-time-to-UTC anchor.
 */
class OuraHistoryDrain {
    private var minBytesLeftSeen = Long.MAX_VALUE
    private var stallCount = 0

    /** Newest stored, anchored history sample seen during this drain. */
    var maxStoredRingTime: Long = 0
        private set

    /** Newest event envelope seen during this drain, anchored or not. */
    var maxSeenRingTime: Long = 0
        private set

    /** Valid event envelopes observed since the most recent GetEvents request. */
    var eventsSinceLastRequest: Int = 0
        private set

    /** True when the ring served stored data older than the cursor used to start this drain. */
    var sawPreResumeData: Boolean = false
        private set

    fun reset() {
        minBytesLeftSeen = Long.MAX_VALUE
        stallCount = 0
        maxStoredRingTime = 0
        maxSeenRingTime = 0
        eventsSinceLastRequest = 0
        sawPreResumeData = false
    }

    /** Return true while the drain should continue; flat bytes-left and a hard deadline stop loops. */
    fun onSummary(bytesLeft: Long, moreData: Boolean, elapsedSeconds: Double): Boolean {
        if (!moreData) return false
        if (bytesLeft < minBytesLeftSeen) {
            minBytesLeftSeen = bytesLeft
            stallCount = 0
        } else {
            stallCount += 1
            if (stallCount >= MAX_STALL_SUMMARIES) return false
        }
        if (elapsedSeconds > MAX_DRAIN_SECONDS) return false
        return true
    }

    /** Record a history sample only after it was stored with a real anchor. */
    fun noteStoredRingTime(ringTimestamp: Long, resumeCursorAtFetchStart: Long) {
        if (ringTimestamp !in 0..MAX_PLAUSIBLE_RESUME_TICKS) return
        if (ringTimestamp > maxStoredRingTime) maxStoredRingTime = ringTimestamp
        if (resumeCursorAtFetchStart > 0 && ringTimestamp < resumeCursorAtFetchStart) {
            sawPreResumeData = true
        }
    }

    /** Record an observed history envelope for this connection's next request, whether anchored or not. */
    fun noteSeenRingTime(ringTimestamp: Long) {
        if (ringTimestamp !in 0..MAX_PLAUSIBLE_RESUME_TICKS) return
        if (ringTimestamp > maxSeenRingTime) maxSeenRingTime = ringTimestamp
        eventsSinceLastRequest += 1
    }

    /**
     * Return one tick past the newest envelope only when this batch moved beyond [lastRequestCursor].
     * Consumes this batch's event count so a second request cannot reuse stale progress.
     */
    fun continuationCursor(lastRequestCursor: Long): Long? {
        if (eventsSinceLastRequest <= 0 || maxSeenRingTime >= UINT32_MAX) return null
        val next = maxSeenRingTime + 1
        if (next <= lastRequestCursor) return null
        eventsSinceLastRequest = 0
        return next
    }

    /** Compute the cursor to persist after the drain ends. */
    fun resumeCursorAtDrainEnd(currentCursor: Long, resolvesUnderAnchor: Boolean): Long {
        if (sawPreResumeData) return 0
        if (maxStoredRingTime > currentCursor && resolvesUnderAnchor) return maxStoredRingTime
        return currentCursor
    }

    companion object {
        /** ~1.6 years of ticks; larger values are pre-fix garbage, not plausible ring time. */
        const val MAX_PLAUSIBLE_RESUME_TICKS = 500_000_000L
        const val MAX_STALL_SUMMARIES = 3
        const val MAX_DRAIN_SECONDS = 300.0
        private const val UINT32_MAX = 0xFFFF_FFFFL

        /** Reset a corrupt persisted cursor to an honest full pull. */
        fun sanitizeLoadedCursor(persisted: Long): Long =
            if (persisted in 0..MAX_PLAUSIBLE_RESUME_TICKS) persisted else 0
    }
}
