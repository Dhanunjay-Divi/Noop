package com.noop.ble

/**
 * Keeps an Oura history resume cursor behind every asynchronous Room write.
 *
 * The transport owns callbacks and ring timestamps. This pure state machine owns ordering, failure,
 * timeout, and stale-generation decisions so reconnect behavior is deterministic and unit-testable.
 * Swift twin: `OuraHistoryPersistenceGate`.
 */
internal class OuraHistoryPersistenceGate {
    data class Resolution(
        val drainCompleted: Boolean,
        val allWritesSucceeded: Boolean,
    )

    data class WriteResult(
        val accepted: Boolean,
        val resolution: Resolution?,
    )

    @get:Synchronized
    var generation: Long = 0
        private set
    @get:Synchronized
    var isActive: Boolean = false
        private set
    @get:Synchronized
    var pendingWriteCount: Int = 0
        private set
    @get:Synchronized
    var sawWriteFailure: Boolean = false
        private set
    @get:Synchronized
    var requestedFinish: Boolean? = null
        private set
    @get:Synchronized
    var isSealed: Boolean = false
        private set

    @Synchronized
    fun begin(): Long {
        generation += 1
        isActive = true
        pendingWriteCount = 0
        sawWriteFailure = false
        requestedFinish = null
        isSealed = false
        return generation
    }

    @Synchronized
    fun invalidate() {
        generation += 1
        isActive = false
        pendingWriteCount = 0
        sawWriteFailure = false
        requestedFinish = null
        isSealed = false
    }

    @Synchronized
    fun register(candidateGeneration: Long): Boolean {
        if (!isActive || candidateGeneration != generation) return false
        pendingWriteCount += 1
        return true
    }

    @Synchronized
    fun completeWrite(candidateGeneration: Long, succeeded: Boolean): WriteResult {
        if (!isActive || candidateGeneration != generation || pendingWriteCount <= 0) {
            return WriteResult(accepted = false, resolution = null)
        }
        pendingWriteCount -= 1
        if (!succeeded) sawWriteFailure = true
        return WriteResult(accepted = true, resolution = resolveIfReady())
    }

    @Synchronized
    fun requestFinish(drainCompleted: Boolean): Resolution? {
        if (!isActive) return null
        requestedFinish = drainCompleted
        return resolveIfReady()
    }

    /** Seal at the next GetEvents request boundary, not at the terminal-summary quiet timer. */
    @Synchronized
    fun seal(): Resolution? {
        if (!isActive || requestedFinish == null) return null
        isSealed = true
        return resolveIfReady()
    }

    @get:Synchronized
    val shouldStartTimeout: Boolean
        get() = isActive && isSealed && requestedFinish != null && pendingWriteCount > 0

    /**
     * Invalidate rather than cancel writes: a Room transaction may already have committed, but its late
     * callback must not move a later drain's cursor.
     */
    @Synchronized
    fun timeOut(candidateGeneration: Long): Boolean {
        if (!isActive || !isSealed ||
            candidateGeneration != generation || requestedFinish == null
        ) return false
        invalidate()
        return true
    }

    @Synchronized
    private fun resolveIfReady(): Resolution? {
        val completed = requestedFinish ?: return null
        if (!isActive || !isSealed || pendingWriteCount != 0) return null
        val resolution = Resolution(
            drainCompleted = completed,
            allWritesSucceeded = !sawWriteFailure,
        )
        isActive = false
        requestedFinish = null
        return resolution
    }
}

/**
 * Associates a partially assembled hypnogram with the drain that delivered it. A receipt containing null
 * means a live burst; a null [pendingReceipt] means no burst is currently buffered.
 */
internal class OuraHypnogramReceiptTracker {
    data class Receipt(val historyGeneration: Long?)

    var pendingReceipt: Receipt? = null
        private set

    fun rotate(toGeneration: Long?): Receipt? {
        val incoming = Receipt(toGeneration)
        val current = pendingReceipt
        if (current == null) {
            pendingReceipt = incoming
            return null
        }
        if (current == incoming) return null
        pendingReceipt = incoming
        return current
    }

    fun takeForFlush(): Receipt? {
        val receipt = pendingReceipt
        pendingReceipt = null
        return receipt
    }

    fun reset() {
        pendingReceipt = null
    }
}
