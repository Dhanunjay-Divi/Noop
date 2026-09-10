package com.noop.notif

import android.content.Context

internal enum class ContextualPromptPostResult {
    POSTED,
    GLOBAL_COOLDOWN,
    FAILED,
}

internal enum class ContextualPromptNotificationSlot {
    ADAPTIVE_DAY,
    STRESS_BREATHING,
    VITAL_REVIEW,
}

internal enum class ContextualPromptDeliveryOwner(
    val storageKey: String,
    val notificationSlot: ContextualPromptNotificationSlot,
) {
    ADAPTIVE_DAY("adaptive_day", ContextualPromptNotificationSlot.ADAPTIVE_DAY),
    PLANNED_WORKOUT("planned_workout", ContextualPromptNotificationSlot.ADAPTIVE_DAY),
    STRESS_BREATHING("stress_breathing", ContextualPromptNotificationSlot.STRESS_BREATHING),
    VITAL_REVIEW("vital_review", ContextualPromptNotificationSlot.VITAL_REVIEW),
}

internal data class ContextualPromptDeliveryState(
    val lastGlobalDeliveryMillis: Long? = null,
    val deliveries: Map<ContextualPromptDeliveryOwner, Long> = emptyMap(),
)

internal data class ContextualPromptOwnerReconciliation(
    val nextState: ContextualPromptDeliveryState,
    val ownerRemoved: Boolean,
    val ownedNotificationSlot: Boolean,
)

/** Pure cross-topic anti-pileup rule shared by routine contextual phone prompts. */
internal object ContextualPromptGlobalPolicy {
    const val COOLDOWN_MILLIS = 30L * 60L * 1_000L

    fun canDeliver(lastDeliveryMillis: Long?, nowMillis: Long): Boolean =
        lastDeliveryMillis?.let { nowMillis - it >= COOLDOWN_MILLIS } ?: true
}

/**
 * Process- and restart-safe Android twin of Apple's shared contextual-intervention state.
 *
 * The platform notify call and global timestamp update run under one lock, so concurrent stress,
 * sleep, and vital evaluations cannot all pass a check-then-post race. Strong workout caution is
 * intentionally separate because it is an in-session safety prompt rather than a routine nudge.
 */
internal object ContextualPromptDeliveryLedger {
    private const val PREFS_FILE = "noop_contextual_prompt_delivery"
    private const val KEY_LAST_AT = "global.last.at"
    private val lock = Any()

    internal fun recordedState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        nowMillis: Long,
    ): ContextualPromptDeliveryState = state.copy(
        lastGlobalDeliveryMillis = nowMillis,
        deliveries = state.deliveries + (owner to nowMillis),
    )

    internal fun reconciledState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
    ): ContextualPromptDeliveryState {
        val ownedAt = state.deliveries[owner]
        if (ownedAt != null && ownedAt != expectedAtMillis) return state
        if (ownedAt == null && state.lastGlobalDeliveryMillis != expectedAtMillis) return state

        val remaining = state.deliveries - owner
        return state.copy(
            lastGlobalDeliveryMillis = if (state.lastGlobalDeliveryMillis == expectedAtMillis) {
                remaining.values.maxOrNull()
            } else {
                state.lastGlobalDeliveryMillis
            },
            deliveries = remaining,
        )
    }

    internal fun reconciledOwnerState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptDeliveryState = ownerReconciliation(state, owner).nextState

    internal fun ownerReconciliation(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptOwnerReconciliation {
        val expectedAtMillis = state.deliveries[owner]
            ?: return ContextualPromptOwnerReconciliation(
                nextState = state,
                ownerRemoved = false,
                ownedNotificationSlot = false,
            )
        val latestSlotDeliveryMillis = state.deliveries
            .filterKeys { it.notificationSlot == owner.notificationSlot }
            .values
            .maxOrNull()
        return ContextualPromptOwnerReconciliation(
            nextState = reconciledState(state, owner, expectedAtMillis),
            ownerRemoved = true,
            ownedNotificationSlot = latestSlotDeliveryMillis == expectedAtMillis,
        )
    }

    fun postIfAllowed(
        context: Context,
        nowMillis: Long,
        owner: ContextualPromptDeliveryOwner,
        post: () -> Boolean,
    ): ContextualPromptPostResult = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val state = loadState(prefs)
        if (!ContextualPromptGlobalPolicy.canDeliver(state.lastGlobalDeliveryMillis, nowMillis)) {
            return@synchronized ContextualPromptPostResult.GLOBAL_COOLDOWN
        }
        if (!post()) return@synchronized ContextualPromptPostResult.FAILED
        saveState(prefs, recordedState(state, owner, nowMillis))
        ContextualPromptPostResult.POSTED
    }

    fun reconcileIfOwned(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
    ): Boolean = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val state = loadState(prefs)
        val next = reconciledState(state, owner, expectedAtMillis)
        if (next == state) return@synchronized false
        saveState(prefs, next)
        true
    }

    /**
     * Reconciles one owner and performs shared-slot cleanup before another prompt can post.
     *
     * [onNotificationSlotOwnerRemoved] runs under the same lock as [postIfAllowed], so a newer notification
     * cannot take over the shared slot between the ownership check and platform cancellation.
     */
    fun reconcileOwnerWithOutcome(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        onNotificationSlotOwnerRemoved: () -> Unit = {},
    ): ContextualPromptOwnerReconciliation = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val state = loadState(prefs)
        val outcome = ownerReconciliation(state, owner)
        if (outcome.ownerRemoved) {
            if (outcome.ownedNotificationSlot) onNotificationSlotOwnerRemoved()
            saveState(prefs, outcome.nextState)
        }
        outcome
    }

    fun nextAllowedAtMillis(
        context: Context,
        nowMillis: Long,
    ): Long? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val last = loadState(prefs).lastGlobalDeliveryMillis ?: return@synchronized null
        (last + ContextualPromptGlobalPolicy.COOLDOWN_MILLIS)
            .takeIf { it > nowMillis }
    }

    private fun ownerKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.at"

    private fun loadState(
        prefs: android.content.SharedPreferences,
    ): ContextualPromptDeliveryState {
        val deliveries = ContextualPromptDeliveryOwner.entries.mapNotNull { owner ->
            val key = ownerKey(owner)
            if (!prefs.contains(key)) null else owner to prefs.getLong(key, 0L)
        }.toMap()
        return ContextualPromptDeliveryState(
            lastGlobalDeliveryMillis = prefs.getLong(KEY_LAST_AT, 0L)
                .takeIf { prefs.contains(KEY_LAST_AT) },
            deliveries = deliveries,
        )
    }

    private fun saveState(
        prefs: android.content.SharedPreferences,
        state: ContextualPromptDeliveryState,
    ) {
        val editor = prefs.edit().remove(KEY_LAST_AT)
        ContextualPromptDeliveryOwner.entries.forEach { editor.remove(ownerKey(it)) }
        state.lastGlobalDeliveryMillis?.let { editor.putLong(KEY_LAST_AT, it) }
        state.deliveries.forEach { (owner, atMillis) ->
            editor.putLong(ownerKey(owner), atMillis)
        }
        editor.commit()
    }
}
