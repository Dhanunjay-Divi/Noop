package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal data class AgeMetricReconciliationOutcome(
    val fitnessFinished: Boolean,
    val vitalityFinished: Boolean,
) {
    val anyFinished: Boolean get() = fitnessFinished || vitalityFinished
    val allFinished: Boolean get() = fitnessFinished && vitalityFinished

    companion object {
        val NONE = AgeMetricReconciliationOutcome(false, false)
    }
}

/**
 * Device-scoped orchestration for the two profile-dependent metric projections.
 *
 * The target is captured before the debounce and supplied to one engine transaction that serializes both
 * projections against normal scoring. A newer schedule cancels the old job, while the final equality check
 * prevents a non-cooperative provider from publishing or persisting after the device or profile changed.
 */
internal class AgeMetricReconciliationRunner<ProfileSnapshot>(
    private val scope: CoroutineScope,
    private val debounceMillis: Long = 350L,
    private val currentTarget: () -> AgeMetricReconciliationTarget,
    private val profileSnapshot: () -> ProfileSnapshot,
    private val recomputeMetrics:
        suspend (ProfileSnapshot, String) -> AgeMetricReconciliationOutcome,
    private val publishCompletedWork: () -> Unit,
    private val persistCompletedTarget: suspend (AgeMetricReconciliationTarget) -> Boolean,
    private val markCompletedTarget: (AgeMetricReconciliationTarget) -> Unit = {},
) {
    private var job: Job? = null

    init {
        require(debounceMillis >= 0L)
    }

    fun schedule() {
        job?.cancel()
        val requestedTarget = currentTarget()
        job = scope.launch {
            delay(debounceMillis)
            val profile = profileSnapshot()
            val outcome = capture {
                recomputeMetrics(profile, requestedTarget.deviceId)
            }.getOrDefault(AgeMetricReconciliationOutcome.NONE)
            if (requestedTarget != currentTarget()) return@launch

            if (outcome.anyFinished) {
                publishCompletedWork()
            }
            if (outcome.allFinished) {
                val persisted = capture {
                    persistCompletedTarget(requestedTarget)
                }.getOrDefault(false)
                if (persisted && requestedTarget == currentTarget()) {
                    markCompletedTarget(requestedTarget)
                }
            }
        }
    }

    fun cancel() {
        job?.cancel()
    }

    private suspend fun <Value> capture(block: suspend () -> Value): Result<Value> =
        try {
            Result.success(block())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            Result.failure(error)
        }
}
