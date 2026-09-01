package com.noop.ble

internal enum class HistorySyncProgressActivity {
    STARTING,
    ADVANCING,
    WAITING,
    STALLED,
}

internal enum class HistorySyncPresentationState {
    HIDDEN,
    EXPANDED,
    COMPACT,
    ATTENTION,
}

/** Pure, wall-clock policy shared by the sync watchdog and progress UI. */
internal object HistorySyncDurableProgressPolicy {
    const val WAITING_AFTER_SECONDS = 10L
    const val STALLED_AFTER_SECONDS = 90L

    fun advances(rows: Int, trim: Long?, previousTrim: Long?): Boolean =
        rows > 0 || (trim != null && trim != previousTrim)

    fun activity(
        startedAt: Long?,
        lastDurableProgressAt: Long?,
        now: Long,
        waitingAfterSeconds: Long = WAITING_AFTER_SECONDS,
        stalledAfterSeconds: Long = STALLED_AFTER_SECONDS,
    ): HistorySyncProgressActivity {
        if (startedAt == null) return HistorySyncProgressActivity.STARTING
        val reference = lastDurableProgressAt ?: startedAt
        val idle = (now - reference).coerceAtLeast(0)
        return when {
            idle >= stalledAfterSeconds -> HistorySyncProgressActivity.STALLED
            idle >= waitingAfterSeconds -> HistorySyncProgressActivity.WAITING
            lastDurableProgressAt == null -> HistorySyncProgressActivity.STARTING
            else -> HistorySyncProgressActivity.ADVANCING
        }
    }

    fun shouldStop(
        startedAt: Long?,
        lastDurableProgressAt: Long?,
        now: Long,
        stalledAfterSeconds: Long = STALLED_AFTER_SECONDS,
    ): Boolean = activity(
        startedAt = startedAt,
        lastDurableProgressAt = lastDurableProgressAt,
        now = now,
        stalledAfterSeconds = stalledAfterSeconds,
    ) == HistorySyncProgressActivity.STALLED
}

/** Keeps automatic history recovery visible without making cached screens look blocked for the full drain. */
internal object HistorySyncPresentationPolicy {
    const val EXPANDED_FOR_SECONDS = 3L

    fun state(
        isSyncing: Boolean,
        userInitiated: Boolean = false,
        hasCachedContent: Boolean,
        startedAt: Long?,
        lastDurableProgressAt: Long?,
        now: Long,
    ): HistorySyncPresentationState {
        if (!isSyncing) return HistorySyncPresentationState.HIDDEN
        if (HistorySyncDurableProgressPolicy.activity(
                startedAt = startedAt,
                lastDurableProgressAt = lastDurableProgressAt,
                now = now,
            ) == HistorySyncProgressActivity.STALLED
        ) {
            return HistorySyncPresentationState.ATTENTION
        }
        if (userInitiated || !hasCachedContent) return HistorySyncPresentationState.EXPANDED
        if (startedAt == null) return HistorySyncPresentationState.EXPANDED
        val elapsed = (now - startedAt).coerceAtLeast(0)
        return if (elapsed < EXPANDED_FOR_SECONDS) {
            HistorySyncPresentationState.EXPANDED
        } else {
            HistorySyncPresentationState.COMPACT
        }
    }
}

/** Honest, total-free progress for one contiguous history drain across auto-continue slices. */
internal data class BackfillBurstProgress(
    val batches: Int = 0,
    val rows: Int = 0,
    val oldestUnix: Long? = null,
    val newestUnix: Long? = null,
) {
    fun acknowledgingBatch(): BackfillBurstProgress = copy(batches = batches + 1)

    fun adding(committed: BackfillCommittedChunk): BackfillBurstProgress = copy(
        rows = rows + committed.rows.coerceAtLeast(0),
        oldestUnix = committed.oldestUnix?.let { minOf(oldestUnix ?: it, it) } ?: oldestUnix,
        newestUnix = committed.newestUnix?.let { maxOf(newestUnix ?: it, it) } ?: newestUnix,
    )
}
