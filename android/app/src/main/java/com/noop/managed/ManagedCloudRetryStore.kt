package com.noop.managed

import android.content.Context
import android.content.SharedPreferences

internal data class ManagedCloudRetryState(
    val failureCount: Int = 0,
    val notBeforeMs: Long = 0L,
) {
    val pending: Boolean
        get() = failureCount > 0 && notBeforeMs > 0L

    fun shouldAttempt(nowMs: Long): Boolean =
        !pending || notBeforeMs <= nowMs

    fun afterFailure(
        nowMs: Long,
        retryAfterMillis: Long?,
        jitterUnit: Double,
    ): Pair<ManagedCloudRetryState, ManagedStorageRetryPlan> {
        val nextCount = (failureCount.coerceAtLeast(0) + 1)
            .coerceAtMost(ManagedStorageRetryPolicy.MAXIMUM_FAILURE_COUNT)
        val plan = ManagedStorageRetryPolicy.plan(
            afterFailure = nextCount,
            retryAfterMillis = retryAfterMillis,
            jitterUnit = jitterUnit,
        )
        val deadline = if (Long.MAX_VALUE - nowMs < plan.delayMillis) {
            Long.MAX_VALUE
        } else {
            nowMs + plan.delayMillis
        }
        return copy(
            failureCount = plan.failureCount,
            notBeforeMs = deadline,
        ) to plan
    }
}

internal class ManagedCloudRetryStore(
    private val preferences: SharedPreferences,
) {
    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(
            "noop_managed_cloud_retry_v1",
            Context.MODE_PRIVATE,
        ),
    )

    init {
        migrateSharedState()
    }

    @Synchronized
    fun state(scope: ManagedCloudScheduler.CatchUpScope): ManagedCloudRetryState =
        ManagedCloudRetryState(
            failureCount = preferences.getInt(failureCountKey(scope), 0)
                .coerceIn(0, ManagedStorageRetryPolicy.MAXIMUM_FAILURE_COUNT),
            notBeforeMs = preferences.getLong(notBeforeKey(scope), 0L)
                .coerceAtLeast(0L),
        )

    @Synchronized
    fun recordFailure(
        scope: ManagedCloudScheduler.CatchUpScope,
        nowMs: Long,
        retryAfterMillis: Long?,
        jitterUnit: Double,
    ): ManagedStorageRetryPlan {
        val (next, plan) = state(scope).afterFailure(
            nowMs = nowMs,
            retryAfterMillis = retryAfterMillis,
            jitterUnit = jitterUnit,
        )
        preferences.edit()
            .putInt(failureCountKey(scope), next.failureCount)
            .putLong(notBeforeKey(scope), next.notBeforeMs)
            .commit()
        return plan
    }

    @Synchronized
    fun clear(scope: ManagedCloudScheduler.CatchUpScope): Boolean =
        preferences.edit()
            .remove(failureCountKey(scope))
            .remove(notBeforeKey(scope))
            .commit()

    @Synchronized
    fun clearAll() {
        val editor = preferences.edit()
        ManagedCloudScheduler.CatchUpScope.entries.forEach { scope ->
            editor
                .remove(failureCountKey(scope))
                .remove(notBeforeKey(scope))
        }
        editor
            .remove(LEGACY_FAILURE_COUNT)
            .remove(LEGACY_NOT_BEFORE_MS)
            .commit()
    }

    @Synchronized
    private fun migrateSharedState() {
        if (preferences.getBoolean(SCOPE_MIGRATION_COMPLETE, false)) return
        val legacy = ManagedCloudRetryState(
            failureCount = preferences.getInt(LEGACY_FAILURE_COUNT, 0)
                .coerceIn(0, ManagedStorageRetryPolicy.MAXIMUM_FAILURE_COUNT),
            notBeforeMs = preferences.getLong(LEGACY_NOT_BEFORE_MS, 0L)
                .coerceAtLeast(0L),
        )
        val editor = preferences.edit()
        if (legacy.pending) {
            // The old ledger collapsed failed scopes, so its exact owner is
            // unknowable. Conservatively preserve the deadline for every
            // scope once; each scope clears independently after its next pass.
            ManagedCloudScheduler.CatchUpScope.entries.forEach { scope ->
                editor
                    .putInt(failureCountKey(scope), legacy.failureCount)
                    .putLong(notBeforeKey(scope), legacy.notBeforeMs)
            }
        }
        editor
            .remove(LEGACY_FAILURE_COUNT)
            .remove(LEGACY_NOT_BEFORE_MS)
            .putBoolean(SCOPE_MIGRATION_COMPLETE, true)
            .commit()
    }

    private companion object {
        const val LEGACY_FAILURE_COUNT = "failure_count"
        const val LEGACY_NOT_BEFORE_MS = "not_before_ms"
        const val SCOPE_MIGRATION_COMPLETE = "scope_migration_complete_v2"

        fun failureCountKey(scope: ManagedCloudScheduler.CatchUpScope): String =
            "failure_count_${scope.token}"

        fun notBeforeKey(scope: ManagedCloudScheduler.CatchUpScope): String =
            "not_before_ms_${scope.token}"
    }
}
