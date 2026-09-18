package com.noop.managed

import java.time.Duration
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.ceil
import kotlin.math.pow

data class ManagedStorageRetryPlan(
    val failureCount: Int,
    val delayMillis: Long,
    val retryAfterApplied: Boolean,
    val delayBucket: String,
)

object ManagedStorageRetryPolicy {
    const val MAXIMUM_FAILURE_COUNT = 7
    const val INITIAL_DELAY_MILLIS = 30_000L
    const val MAXIMUM_BACKOFF_DELAY_MILLIS = 30L * 60L * 1_000L
    const val MAXIMUM_RETRY_AFTER_MILLIS = 6L * 60L * 60L * 1_000L

    fun plan(
        afterFailure: Int,
        retryAfterMillis: Long?,
        jitterUnit: Double,
    ): ManagedStorageRetryPlan {
        val boundedCount = afterFailure.coerceIn(1, MAXIMUM_FAILURE_COUNT)
        val exponent = boundedCount - 1
        val exponential = minOf(
            MAXIMUM_BACKOFF_DELAY_MILLIS.toDouble(),
            INITIAL_DELAY_MILLIS * 2.0.pow(exponent),
        )
        val boundedJitter = jitterUnit.coerceIn(0.0, 1.0)
        val jittered = minOf(
            MAXIMUM_BACKOFF_DELAY_MILLIS,
            ceil(exponential * (0.75 + boundedJitter * 0.5)).toLong(),
        )
        val boundedRetryAfter = retryAfterMillis?.coerceIn(
            1L,
            MAXIMUM_RETRY_AFTER_MILLIS,
        )
        val delay = maxOf(jittered, boundedRetryAfter ?: 0L)
        return ManagedStorageRetryPlan(
            failureCount = boundedCount,
            delayMillis = delay,
            retryAfterApplied =
                boundedRetryAfter?.let { it > jittered } ?: false,
            delayBucket = delayBucket(delay),
        )
    }

    fun retryAfterMillis(
        rawValue: String?,
        now: Instant = Instant.now(),
    ): Long? {
        val value = rawValue?.trim()
            ?.takeIf { it.isNotEmpty() && it.toByteArray().size <= 128 }
            ?: return null
        value.toLongOrNull()?.takeIf { it > 0L }?.let { seconds ->
            return minOf(
                Math.multiplyExact(seconds.coerceAtMost(Long.MAX_VALUE / 1_000L), 1_000L),
                MAXIMUM_RETRY_AFTER_MILLIS,
            )
        }
        val date = runCatching {
            ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME)
                .toInstant()
        }.getOrNull() ?: return null
        val deltaMillis = Duration.between(now, date).toMillis()
        if (deltaMillis <= 0L) return null
        val roundedToSecond = (
            (deltaMillis.coerceAtMost(Long.MAX_VALUE - 999L) + 999L) /
                1_000L
            ) * 1_000L
        return minOf(roundedToSecond, MAXIMUM_RETRY_AFTER_MILLIS)
    }

    fun delayBucket(delayMillis: Long): String = when {
        delayMillis < 60_000L -> "under_1m"
        delayMillis < 5L * 60L * 1_000L -> "1_to_5m"
        delayMillis < 30L * 60L * 1_000L -> "5_to_30m"
        delayMillis < 2L * 60L * 60L * 1_000L -> "30m_to_2h"
        else -> "2h_to_6h"
    }
}

internal val Throwable.managedRetryAfterMillis: Long?
    get() = (this as? ManagedStorageException.Server)?.retryAfterMillis

internal val Throwable.isManagedAutomaticRetryable: Boolean
    get() = when (this) {
        is ManagedStorageException.Network -> true
        is ManagedStorageException.Server ->
            statusCode == 408 || statusCode == 429 || statusCode >= 500
        else -> false
    }
