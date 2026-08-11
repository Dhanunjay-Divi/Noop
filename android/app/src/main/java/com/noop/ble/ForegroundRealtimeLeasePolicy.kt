package com.noop.ble

/**
 * Pure lifecycle policy for the battery-intensive, high-rate sensor stream.
 *
 * Logical leases survive a background transition so an explicit Live/workout/session opt-in can resume
 * when the same activity returns. The physical transport is wanted only while the Activity is foreground.
 * Lightweight connection/history sync and the separate Continuous HRV preference bypass this policy.
 */
class ForegroundRealtimeLeasePolicy(
    // Conservative until Activity lifecycle explicitly reaches RESUMED.
    isForeground: Boolean = false,
) {
    enum class Transition { NONE, ARM, DISARM }

    var leaseCount: Int = 0
        private set
    var isForeground: Boolean = isForeground
        private set
    var transportArmed: Boolean = false
        private set

    val shouldArm: Boolean get() = isForeground && leaseCount > 0

    fun requestLease(): Transition {
        leaseCount += 1
        return reconcile()
    }

    fun releaseLease(): Transition {
        leaseCount = (leaseCount - 1).coerceAtLeast(0)
        return reconcile()
    }

    fun setForeground(foreground: Boolean): Transition {
        isForeground = foreground
        return reconcile()
    }

    private fun reconcile(): Transition {
        val wanted = shouldArm
        if (wanted == transportArmed) return Transition.NONE
        transportArmed = wanted
        return if (wanted) Transition.ARM else Transition.DISARM
    }
}
