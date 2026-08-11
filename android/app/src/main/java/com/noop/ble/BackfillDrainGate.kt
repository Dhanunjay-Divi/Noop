package com.noop.ble

import java.util.ArrayDeque

/**
 * Serial ownership gate for historical frames.
 *
 * Enqueue and the empty-queue ownership handoff share one monitor, so a producer can never leave a
 * frame stranded between an empty poll and owner release. [reset] advances the connection generation;
 * a coroutine from an old connection can then neither drain nor release the new connection's owner.
 */
internal class BackfillDrainGate<T> {
    internal data class Lease internal constructor(
        internal val generation: Long,
        internal val ownerId: Long,
    )

    private val lock = Any()
    private val pending = ArrayDeque<T>()
    private var generation = 0L
    private var nextOwnerId = 0L
    private var owner: Lease? = null

    /** Enqueue [item], returning a lease only when this caller must start the serial drain. */
    fun enqueue(item: T): Lease? = synchronized(lock) {
        pending.addLast(item)
        if (owner != null) return@synchronized null
        Lease(generation, ++nextOwnerId).also { owner = it }
    }

    /** Poll for [lease], releasing ownership atomically when its queue becomes empty. */
    fun pollOrRelease(lease: Lease): T? = synchronized(lock) {
        if (owner != lease) return@synchronized null
        if (pending.isEmpty()) {
            owner = null
            null
        } else {
            pending.removeFirst()
        }
    }

    /** Release after an exceptional drain exit. A stale lease is intentionally harmless. */
    fun release(lease: Lease) = synchronized(lock) {
        if (owner == lease) owner = null
    }

    /** Drop queued frames without invalidating the current connection's drain owner. */
    fun clear() = synchronized(lock) { pending.clear() }

    /** Begin a new connection generation and invalidate all old leases and queued frames. */
    fun reset() = synchronized(lock) {
        generation += 1
        owner = null
        pending.clear()
    }
}
