package com.noop.ble

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
