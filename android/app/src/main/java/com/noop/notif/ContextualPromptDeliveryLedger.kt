package com.noop.notif

import android.content.Context
import android.content.SharedPreferences

internal enum class ContextualPromptPostStatus {
    ACCEPTED,
    GLOBAL_COOLDOWN,
    FAILED,
}

internal data class ContextualPromptPostResult(
    val status: ContextualPromptPostStatus,
    val receipt: ContextualPromptDeliveryReceipt? = null,
    val notificationPosted: Boolean = false,
)

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

internal data class ContextualPromptPendingDelivery(
    val atMillis: Long,
    val identity: String,
    val notificationAttempted: Boolean = false,
    val notificationPosted: Boolean = false,
)

internal data class ContextualPromptDeliveryState(
    val lastGlobalDeliveryMillis: Long? = null,
    val deliveries: Map<ContextualPromptDeliveryOwner, Long> = emptyMap(),
    val identities: Map<ContextualPromptDeliveryOwner, String> = emptyMap(),
    val pendingDeliveries: Map<
        ContextualPromptDeliveryOwner,
        ContextualPromptPendingDelivery,
    > = emptyMap(),
    val pendingCancellationSlots: Set<ContextualPromptNotificationSlot> = emptySet(),
    val pendingCancellationCutoffs: Map<ContextualPromptNotificationSlot, Long> = emptyMap(),
)

internal data class ContextualPromptDeliveryReceipt(
    val atMillis: Long,
    val identity: String?,
    val pending: Boolean = false,
    val notificationPosted: Boolean = true,
)

internal data class ContextualPromptOwnerReconciliation(
    val nextState: ContextualPromptDeliveryState,
    val ownerRemoved: Boolean,
    val ownedNotificationSlot: Boolean,
    val notificationSlotCutoffMillis: Long? = null,
)

internal data class ContextualPromptForcedCancellationResult(
    val stateCommitted: Boolean,
    val notificationCancelled: Boolean,
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
 * Reservation, platform-attempt, posted-pending, and delivered phases are committed separately. A
 * reservation does not replace the previous visible owner or begin cooldown; an attempted phase is
 * treated as potentially visible until the same identity safely reposts or reconciles. The
 * topic-specific caller durably saves its cooldown before promoting the shared owner. Strong workout
 * caution is intentionally separate because it is an in-session safety prompt rather than a routine
 * nudge.
 */
internal object ContextualPromptDeliveryLedger {
    private const val PREFS_FILE = "noop_contextual_prompt_delivery"
    private const val KEY_LAST_AT = "global.last.at"
    private val lock = Any()

    internal fun recordedState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        nowMillis: Long,
        identity: String? = null,
    ): ContextualPromptDeliveryState = state.copy(
        lastGlobalDeliveryMillis = maxOf(
            state.lastGlobalDeliveryMillis ?: Long.MIN_VALUE,
            nowMillis,
        ),
        deliveries = state.deliveries + (owner to nowMillis),
        identities = if (identity == null) {
            state.identities - owner
        } else {
            state.identities + (owner to identity)
        },
        pendingDeliveries = state.pendingDeliveries - owner,
        pendingCancellationSlots =
            state.pendingCancellationSlots - owner.notificationSlot,
        pendingCancellationCutoffs =
            state.pendingCancellationCutoffs - owner.notificationSlot,
    )

    internal fun reservedState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        nowMillis: Long,
        identity: String,
    ): ContextualPromptDeliveryState = state.copy(
        pendingDeliveries = state.pendingDeliveries + (
            owner to ContextualPromptPendingDelivery(
                atMillis = nowMillis,
                identity = identity,
            )
        ),
    )

    internal fun postedPendingState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        expectedIdentity: String,
    ): ContextualPromptDeliveryState {
        val pending = state.pendingDeliveries[owner] ?: return state
        if (
            pending.atMillis != expectedAtMillis ||
            pending.identity != expectedIdentity ||
            pending.notificationPosted
        ) {
            return state
        }
        return state.copy(
            pendingDeliveries = state.pendingDeliveries + (
                owner to pending.copy(
                    notificationAttempted = true,
                    notificationPosted = true,
                )
            ),
            pendingCancellationSlots =
                state.pendingCancellationSlots - owner.notificationSlot,
            pendingCancellationCutoffs =
                state.pendingCancellationCutoffs - owner.notificationSlot,
        )
    }

    internal fun attemptedState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        expectedIdentity: String,
    ): ContextualPromptDeliveryState {
        val pending = state.pendingDeliveries[owner] ?: return state
        if (
            pending.atMillis != expectedAtMillis ||
            pending.identity != expectedIdentity ||
            pending.notificationAttempted
        ) {
            return state
        }
        return state.copy(
            pendingDeliveries = state.pendingDeliveries + (
                owner to pending.copy(notificationAttempted = true)
            ),
        )
    }

    internal fun confirmedState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        expectedIdentity: String?,
    ): ContextualPromptDeliveryState {
        val pending = state.pendingDeliveries[owner] ?: return state
        if (
            pending.atMillis != expectedAtMillis ||
            pending.identity != expectedIdentity
        ) {
            return state
        }
        return recordedState(
            state = state,
            owner = owner,
            nowMillis = pending.atMillis,
            identity = pending.identity,
        )
    }

    internal fun reconciledState(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
    ): ContextualPromptDeliveryState {
        val removeDelivered = state.deliveries[owner] == expectedAtMillis
        val removePending = state.pendingDeliveries[owner]?.atMillis == expectedAtMillis
        if (!removeDelivered && !removePending) {
            if (
                state.deliveries[owner] == null &&
                state.pendingDeliveries[owner] == null &&
                state.lastGlobalDeliveryMillis == expectedAtMillis
            ) {
                return state.copy(lastGlobalDeliveryMillis = state.deliveries.values.maxOrNull())
            }
            return state
        }

        val remainingDeliveries = if (removeDelivered) {
            state.deliveries - owner
        } else {
            state.deliveries
        }
        return state.copy(
            lastGlobalDeliveryMillis = if (removeDelivered) {
                remainingDeliveries.values.maxOrNull()
            } else {
                state.lastGlobalDeliveryMillis
            },
            deliveries = remainingDeliveries,
            identities = if (removeDelivered) state.identities - owner else state.identities,
            pendingDeliveries = if (removePending) {
                state.pendingDeliveries - owner
            } else {
                state.pendingDeliveries
            },
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
        val deliveredAt = state.deliveries[owner]
        val pending = state.pendingDeliveries[owner]
        if (deliveredAt == null && pending == null) {
            return ContextualPromptOwnerReconciliation(
                nextState = state,
                ownerRemoved = false,
                ownedNotificationSlot = false,
            )
        }
        val ownerVisibleAt = listOfNotNull(
            deliveredAt,
            pending?.atMillis?.takeIf {
                pending.notificationAttempted || pending.notificationPosted
            },
        ).maxOrNull()
        val latestSlotDeliveryMillis = potentiallyVisibleSlotDeliveryMillis(
            state,
            owner.notificationSlot,
        )
        val remainingDeliveries = state.deliveries - owner
        return ContextualPromptOwnerReconciliation(
            nextState = state.copy(
                lastGlobalDeliveryMillis = remainingDeliveries.values.maxOrNull(),
                deliveries = remainingDeliveries,
                identities = state.identities - owner,
                pendingDeliveries = state.pendingDeliveries - owner,
            ),
            ownerRemoved = true,
            ownedNotificationSlot =
                ownerVisibleAt != null && latestSlotDeliveryMillis == ownerVisibleAt,
            notificationSlotCutoffMillis = ownerVisibleAt
                ?.takeIf { latestSlotDeliveryMillis == it },
        )
    }

    fun postIfAllowed(
        context: Context,
        nowMillis: Long,
        owner: ContextualPromptDeliveryOwner,
        identity: String,
        post: () -> Boolean,
    ): ContextualPromptPostResult {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return postIfAllowed(prefs, nowMillis, owner, identity, post)
    }

    internal fun postIfAllowed(
        prefs: SharedPreferences,
        nowMillis: Long,
        owner: ContextualPromptDeliveryOwner,
        identity: String,
        post: () -> Boolean,
    ): ContextualPromptPostResult = synchronized(lock) {
        val state = loadState(prefs)
        val pending = state.pendingDeliveries[owner]
        if (pending?.identity == identity && pending.notificationPosted) {
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.ACCEPTED,
                receipt = pendingReceipt(pending),
            )
        }
        if (
            pending != null &&
            pending.identity != identity &&
            (pending.notificationAttempted || pending.notificationPosted) &&
            nowMillis - pending.atMillis < unresolvedOwnerHoldMillis(owner)
        ) {
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.GLOBAL_COOLDOWN,
            )
        }

        val delivered = deliveryReceipt(state, owner)
        if (delivered?.identity == identity) {
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.ACCEPTED,
                receipt = delivered,
            )
        }
        val cooldownState = if (pending?.identity == identity) {
            state.copy(pendingDeliveries = state.pendingDeliveries - owner)
        } else {
            state
        }
        if (
            !ContextualPromptGlobalPolicy.canDeliver(
                effectiveLastGlobalMillis(cooldownState),
                nowMillis,
            )
        ) {
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.GLOBAL_COOLDOWN,
            )
        }

        val reserved = reservedState(state, owner, nowMillis, identity)
        if (!saveState(prefs, reserved)) {
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.FAILED,
            )
        }
        val attempted = attemptedState(
            state = reserved,
            owner = owner,
            expectedAtMillis = nowMillis,
            expectedIdentity = identity,
        )
        if (!saveState(prefs, attempted)) {
            saveState(prefs, state)
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.FAILED,
            )
        }
        val posted = try {
            post()
        } catch (_: Exception) {
            // The callback may have thrown after the platform accepted notify(). Keep the durable
            // attempted phase so recovery cannot treat the fixed slot as definitely unchanged.
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.FAILED,
            )
        }
        if (!posted) {
            // Callers return false only when the platform notification was not accepted.
            saveState(prefs, state)
            return@synchronized ContextualPromptPostResult(
                status = ContextualPromptPostStatus.FAILED,
            )
        }

        val postedPending = postedPendingState(
            state = attempted,
            owner = owner,
            expectedAtMillis = nowMillis,
            expectedIdentity = identity,
        )
        saveState(prefs, postedPending)
        ContextualPromptPostResult(
            status = ContextualPromptPostStatus.ACCEPTED,
            receipt = ContextualPromptDeliveryReceipt(
                atMillis = nowMillis,
                identity = identity,
                pending = true,
                notificationPosted = true,
            ),
            notificationPosted = true,
        )
    }

    fun reconcileIfOwned(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        onNotificationSlotOwnerRemoved: () -> Boolean = { false },
    ): Boolean = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val state = loadState(prefs)
        val outcome = exactOwnerReconciliation(state, owner, expectedAtMillis)
        if (!outcome.ownerRemoved) return@synchronized false
        persistOwnerReconciliation(
            prefs = prefs,
            state = state,
            outcome = outcome,
            slot = owner.notificationSlot,
            onNotificationSlotOwnerRemoved = onNotificationSlotOwnerRemoved,
        ).ownerRemoved
    }

    internal fun deliveryReceipt(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptDeliveryReceipt? = state.deliveries[owner]?.let { atMillis ->
        ContextualPromptDeliveryReceipt(
            atMillis = atMillis,
            identity = state.identities[owner],
        )
    }

    fun deliveryReceipt(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptDeliveryReceipt? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        deliveryReceipt(loadState(prefs), owner)
    }

    internal fun pendingReceipt(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptDeliveryReceipt? =
        state.pendingDeliveries[owner]?.let(::pendingReceipt)

    fun pendingReceipt(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
    ): ContextualPromptDeliveryReceipt? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        pendingReceipt(loadState(prefs), owner)
    }

    fun confirmPendingIfOwned(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        expectedIdentity: String?,
    ): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return confirmPendingIfOwned(prefs, owner, expectedAtMillis, expectedIdentity)
    }

    internal fun confirmPendingIfOwned(
        prefs: SharedPreferences,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        expectedIdentity: String?,
    ): Boolean = synchronized(lock) {
        val state = loadState(prefs)
        val next = confirmedState(state, owner, expectedAtMillis, expectedIdentity)
        if (next == state) {
            val delivered = deliveryReceipt(state, owner)
            return@synchronized delivered?.atMillis == expectedAtMillis &&
                delivered.identity == expectedIdentity
        }
        saveState(prefs, next)
    }

    /**
     * Reconciles one owner and performs shared-slot cleanup before another prompt can post.
     *
     * Owner removal is committed before cancellation. A durable cancellation tombstone closes the
     * process-death gap; a later retry cancels again, while a durably posted replacement clears the
     * old tombstone.
     */
    fun reconcileOwnerWithOutcome(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        onNotificationSlotOwnerRemoved: () -> Boolean = { false },
    ): ContextualPromptOwnerReconciliation {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return reconcileOwnerWithOutcome(prefs, owner, onNotificationSlotOwnerRemoved)
    }

    internal fun reconcileOwnerWithOutcome(
        prefs: SharedPreferences,
        owner: ContextualPromptDeliveryOwner,
        onNotificationSlotOwnerRemoved: () -> Boolean = { false },
    ): ContextualPromptOwnerReconciliation = synchronized(lock) {
        val state = loadState(prefs)
        val outcome = ownerReconciliation(state, owner)
        persistOwnerReconciliation(
            prefs = prefs,
            state = state,
            outcome = outcome,
            slot = owner.notificationSlot,
            onNotificationSlotOwnerRemoved = onNotificationSlotOwnerRemoved,
        )
    }

    private fun persistOwnerReconciliation(
        prefs: SharedPreferences,
        state: ContextualPromptDeliveryState,
        outcome: ContextualPromptOwnerReconciliation,
        slot: ContextualPromptNotificationSlot,
        onNotificationSlotOwnerRemoved: () -> Boolean,
    ): ContextualPromptOwnerReconciliation {
        val hadPendingCancellation = slot in state.pendingCancellationSlots
        val priorCancellationCutoff = pendingCancellationCutoff(state, slot)
        val latestPotentialDelivery =
            potentiallyVisibleSlotDeliveryMillis(outcome.nextState, slot)
        val retryPendingCancellation =
            hadPendingCancellation &&
                if (priorCancellationCutoff == null) {
                    latestPotentialDelivery == null
                } else {
                    latestPotentialDelivery?.let { it <= priorCancellationCutoff } != false
                }
        val shouldCancel = outcome.ownedNotificationSlot || retryPendingCancellation
        if (!outcome.ownerRemoved && !shouldCancel) return outcome
        val cancellationCutoff = listOfNotNull(
            priorCancellationCutoff,
            outcome.notificationSlotCutoffMillis,
        ).maxOrNull()

        val prepared = outcome.nextState.copy(
            pendingCancellationSlots = if (shouldCancel) {
                outcome.nextState.pendingCancellationSlots + slot
            } else {
                outcome.nextState.pendingCancellationSlots
            },
            pendingCancellationCutoffs =
                if (shouldCancel && cancellationCutoff != null) {
                    outcome.nextState.pendingCancellationCutoffs +
                        (slot to cancellationCutoff)
                } else if (shouldCancel) {
                    outcome.nextState.pendingCancellationCutoffs - slot
                } else {
                    outcome.nextState.pendingCancellationCutoffs
                },
        )
        if (prepared != state && !saveState(prefs, prepared)) {
            return ContextualPromptOwnerReconciliation(
                nextState = state,
                ownerRemoved = false,
                ownedNotificationSlot = false,
            )
        }
        var finalState = prepared
        if (shouldCancel) {
            val cancellationCompleted = try {
                onNotificationSlotOwnerRemoved()
            } catch (_: Exception) {
                false
            }
            if (cancellationCompleted) {
                val cleared = prepared.copy(
                    pendingCancellationSlots = prepared.pendingCancellationSlots - slot,
                    pendingCancellationCutoffs =
                        prepared.pendingCancellationCutoffs - slot,
                )
                if (saveState(prefs, cleared)) {
                    finalState = cleared
                }
            }
        }
        return ContextualPromptOwnerReconciliation(
            nextState = finalState,
            ownerRemoved = outcome.ownerRemoved,
            ownedNotificationSlot = shouldCancel,
        )
    }

    /**
     * Privacy-first cleanup for an entire feature-owned fixed slot after that feature is disabled.
     *
     * The caller must prevent new posts before invoking this method. Cancellation still runs under
     * the shared delivery lock when the owner-state commit fails, so private notification content is
     * removed immediately. The stale owner state remains durable in that case and a later disabled
     * evaluation retries the same cleanup.
     */
    fun forceCancelNotificationSlot(
        context: Context,
        slot: ContextualPromptNotificationSlot,
        cancel: () -> Boolean,
    ): ContextualPromptForcedCancellationResult {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return forceCancelNotificationSlot(prefs, slot, cancel)
    }

    internal fun forceCancelNotificationSlot(
        prefs: SharedPreferences,
        slot: ContextualPromptNotificationSlot,
        cancel: () -> Boolean,
    ): ContextualPromptForcedCancellationResult = synchronized(lock) {
        val state = loadState(prefs)
        val slotOwners = ContextualPromptDeliveryOwner.entries
            .filterTo(linkedSetOf()) { it.notificationSlot == slot }
        val remainingDeliveries = state.deliveries.filterKeys { it !in slotOwners }
        val cancellationCutoff = listOfNotNull(
            pendingCancellationCutoff(state, slot),
            potentiallyVisibleSlotDeliveryMillis(state, slot),
        ).maxOrNull()
        val prepared = state.copy(
            lastGlobalDeliveryMillis = remainingDeliveries.values.maxOrNull(),
            deliveries = remainingDeliveries,
            identities = state.identities.filterKeys { it !in slotOwners },
            pendingDeliveries = state.pendingDeliveries.filterKeys { it !in slotOwners },
            pendingCancellationSlots = state.pendingCancellationSlots + slot,
            pendingCancellationCutoffs =
                if (cancellationCutoff == null) {
                    state.pendingCancellationCutoffs - slot
                } else {
                    state.pendingCancellationCutoffs + (slot to cancellationCutoff)
                },
        )
        var stateCommitted = prepared == state || saveState(prefs, prepared)
        val notificationCancelled = try {
            cancel()
        } catch (_: Exception) {
            false
        }
        if (stateCommitted && notificationCancelled) {
            stateCommitted = saveState(
                prefs,
                prepared.copy(
                    pendingCancellationSlots =
                        prepared.pendingCancellationSlots - slot,
                    pendingCancellationCutoffs =
                        prepared.pendingCancellationCutoffs - slot,
                ),
            )
        }
        ContextualPromptForcedCancellationResult(
            stateCommitted = stateCommitted,
            notificationCancelled = notificationCancelled,
        )
    }

    /**
     * Cleans up a legacy fixed-slot notification only when no durable visible owner currently holds it.
     *
     * The callback runs under the delivery lock so a new owner cannot post into the slot between the
     * ownership check and cancellation.
     */
    fun cancelNotificationSlotIfUnowned(
        context: Context,
        slot: ContextualPromptNotificationSlot,
        cancel: () -> Boolean,
    ): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return cancelNotificationSlotIfUnowned(prefs, slot, cancel)
    }

    internal fun cancelNotificationSlotIfUnowned(
        prefs: SharedPreferences,
        slot: ContextualPromptNotificationSlot,
        cancel: () -> Boolean,
    ): Boolean = synchronized(lock) {
        val state = loadState(prefs)
        val hadPendingCancellation = slot in state.pendingCancellationSlots
        val priorCancellationCutoff = pendingCancellationCutoff(state, slot)
        val latestPotentialDelivery = potentiallyVisibleSlotDeliveryMillis(state, slot)
        if (
            !hadPendingCancellation &&
            latestPotentialDelivery != null
        ) {
            return@synchronized false
        }
        if (
            hadPendingCancellation &&
            priorCancellationCutoff == null &&
            latestPotentialDelivery != null
        ) {
            return@synchronized false
        }
        if (
            hadPendingCancellation &&
            priorCancellationCutoff != null &&
            latestPotentialDelivery != null &&
            latestPotentialDelivery > priorCancellationCutoff
        ) {
            return@synchronized false
        }
        val cancellationCutoff = when {
            priorCancellationCutoff != null -> priorCancellationCutoff
            hadPendingCancellation -> null
            else -> System.currentTimeMillis()
        }
        val prepared = state.copy(
            pendingCancellationSlots = state.pendingCancellationSlots + slot,
            pendingCancellationCutoffs =
                if (cancellationCutoff == null) {
                    state.pendingCancellationCutoffs - slot
                } else {
                    state.pendingCancellationCutoffs + (slot to cancellationCutoff)
                },
        )
        if (prepared != state && !saveState(prefs, prepared)) {
            return@synchronized false
        }
        val cancelled = try {
            cancel()
        } catch (_: Exception) {
            false
        }
        if (!cancelled) return@synchronized false
        val cleared = prepared.copy(
            pendingCancellationSlots = prepared.pendingCancellationSlots - slot,
            pendingCancellationCutoffs =
                prepared.pendingCancellationCutoffs - slot,
        )
        cleared == prepared || saveState(prefs, cleared)
    }

    fun hasPendingCancellation(
        context: Context,
        slot: ContextualPromptNotificationSlot,
    ): Boolean = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        slot in loadState(prefs).pendingCancellationSlots
    }

    /**
     * Cancels a private-state-only orphan without erasing older shared cooldown owners.
     *
     * A process can stop after a topic saves its private delivery but before the shared owner is
     * promoted. The private timestamp is then the only proof that the fixed slot may contain that
     * topic's content. A newer shared attempt supersedes the orphan; otherwise a durable cutoff
     * tombstone makes the cancellation restart-safe while preserving older owner history.
     */
    fun cancelNotificationSlotThroughCutoff(
        context: Context,
        slot: ContextualPromptNotificationSlot,
        cutoffMillis: Long,
        cancel: () -> Boolean,
    ): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return cancelNotificationSlotThroughCutoff(prefs, slot, cutoffMillis, cancel)
    }

    internal fun cancelNotificationSlotThroughCutoff(
        prefs: SharedPreferences,
        slot: ContextualPromptNotificationSlot,
        cutoffMillis: Long,
        cancel: () -> Boolean,
    ): Boolean = synchronized(lock) {
        val state = loadState(prefs)
        val existingCutoff = pendingCancellationCutoff(state, slot)
        val effectiveCutoff = maxOf(existingCutoff ?: Long.MIN_VALUE, cutoffMillis)
        val latestPotentialDelivery = potentiallyVisibleSlotDeliveryMillis(state, slot)
        if (
            latestPotentialDelivery != null &&
            latestPotentialDelivery > effectiveCutoff
        ) {
            return@synchronized true
        }
        val prepared = state.copy(
            pendingCancellationSlots = state.pendingCancellationSlots + slot,
            pendingCancellationCutoffs =
                state.pendingCancellationCutoffs + (slot to effectiveCutoff),
        )
        val stateCommitted = prepared == state || saveState(prefs, prepared)
        val cancelled = try {
            cancel()
        } catch (_: Exception) {
            false
        }
        if (!stateCommitted || !cancelled) return@synchronized false
        val cleared = prepared.copy(
            pendingCancellationSlots = prepared.pendingCancellationSlots - slot,
            pendingCancellationCutoffs =
                prepared.pendingCancellationCutoffs - slot,
        )
        cleared == prepared || saveState(prefs, cleared)
    }

    /**
     * Cancels a fixed-slot notification only when the exact delivery still owns the visible slot.
     *
     * The delivery record remains in place so natural expiry can preserve cooldown history. Running
     * the ownership check and callback under the delivery lock prevents a replacement post from being
     * cancelled between those two operations.
     */
    fun cancelNotificationSlotIfOwned(
        context: Context,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        cancel: () -> Boolean,
    ): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return cancelNotificationSlotIfOwned(prefs, owner, expectedAtMillis, cancel)
    }

    internal fun cancelNotificationSlotIfOwned(
        prefs: SharedPreferences,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
        cancel: () -> Boolean,
    ): Boolean = synchronized(lock) {
        val state = loadState(prefs)
        val ownerVisibleAt = potentiallyVisibleOwnerDeliveryMillis(state, owner)
        if (
            ownerVisibleAt != expectedAtMillis ||
            potentiallyVisibleSlotDeliveryMillis(
                state,
                owner.notificationSlot,
            ) != expectedAtMillis
        ) {
            return@synchronized false
        }
        try {
            cancel()
        } catch (_: Exception) {
            false
        }
    }

    fun nextAllowedAtMillis(
        context: Context,
        nowMillis: Long,
        owner: ContextualPromptDeliveryOwner,
        identity: String,
    ): Long? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val state = loadState(prefs)
        val pending = state.pendingDeliveries[owner]
        val cooldownState = if (
            pending?.identity == identity &&
            !pending.notificationPosted
        ) {
            state.copy(pendingDeliveries = state.pendingDeliveries - owner)
        } else {
            state
        }
        val globalBarrier = effectiveLastGlobalMillis(cooldownState)?.plus(
            ContextualPromptGlobalPolicy.COOLDOWN_MILLIS,
        )
        val ownerBarrier = pending
            ?.takeIf {
                it.identity != identity &&
                    (it.notificationAttempted || it.notificationPosted)
            }
            ?.atMillis
            ?.plus(unresolvedOwnerHoldMillis(owner))
        listOfNotNull(globalBarrier, ownerBarrier)
            .maxOrNull()
            ?.takeIf { it > nowMillis }
    }

    private fun ownerKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.at"

    private fun identityKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.identity"

    private fun legacyPendingKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.pending"

    private fun pendingAtKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.pending.at"

    private fun pendingIdentityKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.pending.identity"

    private fun pendingPostedKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.pending.posted"

    private fun pendingAttemptedKey(owner: ContextualPromptDeliveryOwner): String =
        "owner.${owner.storageKey}.pending.attempted"

    private fun pendingCancellationKey(slot: ContextualPromptNotificationSlot): String =
        "slot.${slot.name.lowercase()}.cancel.pending"

    private fun pendingCancellationCutoffKey(
        slot: ContextualPromptNotificationSlot,
    ): String = "slot.${slot.name.lowercase()}.cancel.cutoff"

    internal fun loadState(
        prefs: SharedPreferences,
    ): ContextualPromptDeliveryState {
        val deliveries = linkedMapOf<ContextualPromptDeliveryOwner, Long>()
        val identities = linkedMapOf<ContextualPromptDeliveryOwner, String>()
        val pendingDeliveries =
            linkedMapOf<ContextualPromptDeliveryOwner, ContextualPromptPendingDelivery>()
        ContextualPromptDeliveryOwner.entries.forEach { owner ->
            val legacyPending = prefs.getBoolean(legacyPendingKey(owner), false)
            val deliveredAt = ownerKey(owner).takeIf(prefs::contains)?.let {
                prefs.getLong(it, 0L)
            }
            val deliveredIdentity = prefs.getString(identityKey(owner), null)
            if (legacyPending && deliveredAt != null && deliveredIdentity != null) {
                pendingDeliveries[owner] = ContextualPromptPendingDelivery(
                    atMillis = deliveredAt,
                    identity = deliveredIdentity,
                )
            } else if (deliveredAt != null) {
                deliveries[owner] = deliveredAt
                deliveredIdentity?.let { identities[owner] = it }
            }

            val pendingAt = pendingAtKey(owner).takeIf(prefs::contains)?.let {
                prefs.getLong(it, 0L)
            }
            val pendingIdentity = prefs.getString(pendingIdentityKey(owner), null)
            if (pendingAt != null && pendingIdentity != null) {
                val notificationPosted = prefs.getBoolean(pendingPostedKey(owner), false)
                pendingDeliveries[owner] = ContextualPromptPendingDelivery(
                    atMillis = pendingAt,
                    identity = pendingIdentity,
                    notificationAttempted =
                        notificationPosted ||
                            prefs.getBoolean(pendingAttemptedKey(owner), false),
                    notificationPosted = notificationPosted,
                )
            }
        }
        return ContextualPromptDeliveryState(
            lastGlobalDeliveryMillis = prefs.getLong(KEY_LAST_AT, 0L)
                .takeIf { prefs.contains(KEY_LAST_AT) },
            deliveries = deliveries,
            identities = identities,
            pendingDeliveries = pendingDeliveries,
            pendingCancellationSlots =
                ContextualPromptNotificationSlot.entries.filterTo(linkedSetOf()) { slot ->
                    prefs.getBoolean(pendingCancellationKey(slot), false)
                },
            pendingCancellationCutoffs =
                ContextualPromptNotificationSlot.entries.mapNotNull { slot ->
                    if (
                        !prefs.getBoolean(pendingCancellationKey(slot), false) ||
                        !prefs.contains(pendingCancellationCutoffKey(slot))
                    ) {
                        null
                    } else {
                        slot to prefs.getLong(
                            pendingCancellationCutoffKey(slot),
                            Long.MIN_VALUE,
                        )
                    }
                }.toMap(),
        )
    }

    internal fun saveState(
        prefs: SharedPreferences,
        state: ContextualPromptDeliveryState,
    ): Boolean {
        val editor = prefs.edit().remove(KEY_LAST_AT)
        ContextualPromptDeliveryOwner.entries.forEach {
            editor.remove(ownerKey(it))
            editor.remove(identityKey(it))
            editor.remove(legacyPendingKey(it))
            editor.remove(pendingAtKey(it))
            editor.remove(pendingIdentityKey(it))
            editor.remove(pendingAttemptedKey(it))
            editor.remove(pendingPostedKey(it))
        }
        ContextualPromptNotificationSlot.entries.forEach {
            editor.remove(pendingCancellationKey(it))
            editor.remove(pendingCancellationCutoffKey(it))
        }
        state.lastGlobalDeliveryMillis?.let { editor.putLong(KEY_LAST_AT, it) }
        state.deliveries.forEach { (owner, atMillis) ->
            editor.putLong(ownerKey(owner), atMillis)
            state.identities[owner]?.let { identity ->
                editor.putString(identityKey(owner), identity)
            }
        }
        state.pendingDeliveries.forEach { (owner, pending) ->
            editor.putLong(pendingAtKey(owner), pending.atMillis)
            editor.putString(pendingIdentityKey(owner), pending.identity)
            if (pending.notificationAttempted) {
                editor.putBoolean(pendingAttemptedKey(owner), true)
            }
            if (pending.notificationPosted) {
                editor.putBoolean(pendingPostedKey(owner), true)
            }
        }
        state.pendingCancellationSlots.forEach { slot ->
            editor.putBoolean(pendingCancellationKey(slot), true)
            state.pendingCancellationCutoffs[slot]?.let { cutoff ->
                editor.putLong(pendingCancellationCutoffKey(slot), cutoff)
            }
        }
        return editor.commit()
    }

    private fun pendingReceipt(
        pending: ContextualPromptPendingDelivery,
    ): ContextualPromptDeliveryReceipt = ContextualPromptDeliveryReceipt(
        atMillis = pending.atMillis,
        identity = pending.identity,
        pending = true,
        notificationPosted = pending.notificationPosted,
    )

    private fun effectiveLastGlobalMillis(
        state: ContextualPromptDeliveryState,
    ): Long? = listOfNotNull(
        state.lastGlobalDeliveryMillis,
        state.pendingDeliveries.values
            .filter {
                it.notificationAttempted || it.notificationPosted
            }
            .maxOfOrNull(ContextualPromptPendingDelivery::atMillis),
    ).maxOrNull()

    private fun potentiallyVisibleSlotDeliveryMillis(
        state: ContextualPromptDeliveryState,
        slot: ContextualPromptNotificationSlot,
    ): Long? = (
        state.deliveries
            .filterKeys { it.notificationSlot == slot }
            .values +
            state.pendingDeliveries
                .filter { (owner, pending) ->
                    owner.notificationSlot == slot &&
                        (pending.notificationAttempted || pending.notificationPosted)
                }
                .values
                .map(ContextualPromptPendingDelivery::atMillis)
        ).maxOrNull()

    private fun potentiallyVisibleOwnerDeliveryMillis(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
    ): Long? = listOfNotNull(
        state.deliveries[owner],
        state.pendingDeliveries[owner]
            ?.takeIf {
                it.notificationAttempted || it.notificationPosted
            }
            ?.atMillis,
    ).maxOrNull()

    private fun pendingCancellationCutoff(
        state: ContextualPromptDeliveryState,
        slot: ContextualPromptNotificationSlot,
    ): Long? {
        if (slot !in state.pendingCancellationSlots) return null
        return state.pendingCancellationCutoffs[slot]
    }

    private fun exactOwnerReconciliation(
        state: ContextualPromptDeliveryState,
        owner: ContextualPromptDeliveryOwner,
        expectedAtMillis: Long,
    ): ContextualPromptOwnerReconciliation {
        val deliveredMatches = state.deliveries[owner] == expectedAtMillis
        val pending = state.pendingDeliveries[owner]
            ?.takeIf { it.atMillis == expectedAtMillis }
        val legacyGlobalMatches =
            !deliveredMatches &&
                pending == null &&
                state.deliveries[owner] == null &&
                state.pendingDeliveries[owner] == null &&
                state.lastGlobalDeliveryMillis == expectedAtMillis
        if (!deliveredMatches && pending == null && !legacyGlobalMatches) {
            return ContextualPromptOwnerReconciliation(
                nextState = state,
                ownerRemoved = false,
                ownedNotificationSlot = false,
            )
        }
        val nextState = reconciledState(state, owner, expectedAtMillis)
        val exactDeliveryMayOwnSlot =
            deliveredMatches ||
                pending?.let {
                    it.notificationAttempted || it.notificationPosted
                } == true
        return ContextualPromptOwnerReconciliation(
            nextState = nextState,
            ownerRemoved = nextState != state,
            ownedNotificationSlot =
                exactDeliveryMayOwnSlot &&
                    potentiallyVisibleSlotDeliveryMillis(
                        state,
                        owner.notificationSlot,
                    ) == expectedAtMillis,
            notificationSlotCutoffMillis = expectedAtMillis
                .takeIf {
                    exactDeliveryMayOwnSlot &&
                        potentiallyVisibleSlotDeliveryMillis(
                            state,
                            owner.notificationSlot,
                        ) == expectedAtMillis
                },
        )
    }

    private fun unresolvedOwnerHoldMillis(
        owner: ContextualPromptDeliveryOwner,
    ): Long = when (owner) {
        ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
        ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        -> 24L * 60L * 60L * 1_000L
        ContextualPromptDeliveryOwner.STRESS_BREATHING ->
            4L * 60L * 60L * 1_000L
        ContextualPromptDeliveryOwner.VITAL_REVIEW ->
            21L * 24L * 60L * 60L * 1_000L
    }
}
