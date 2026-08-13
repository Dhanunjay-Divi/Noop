package com.noop.ui

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide, ref-counted truth for user-started breathing/biofeedback sessions. Each running owner keeps
 * one [Lease]; releasing one session cannot accidentally clear another. A process death ends these UI-owned
 * sessions, so this state deliberately is not persisted.
 */
object StressNudgeSessionRegistry {
    private val leaseCount = AtomicInteger(0)

    val active: Boolean get() = leaseCount.get() > 0

    fun acquire(): Lease {
        leaseCount.incrementAndGet()
        return Lease()
    }

    class Lease internal constructor() {
        private val released = AtomicBoolean(false)

        fun release() {
            if (!released.compareAndSet(false, true)) return
            leaseCount.updateAndGet { count -> (count - 1).coerceAtLeast(0) }
        }
    }
}
