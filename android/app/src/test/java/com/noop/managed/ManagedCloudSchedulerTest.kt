package com.noop.managed

import androidx.work.NetworkType
import com.noop.testing.FakeSharedPreferences
import com.noop.ui.Terms
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManagedCloudSchedulerTest {
    @Test
    fun managedRuntimeRequiresTheExactCurrentTermsVersion() {
        assertTrue(ManagedRuntimeGate.acceptsCurrentTerms(Terms.CURRENT_VERSION))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms(null))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms(""))
        assertFalse(ManagedRuntimeGate.acceptsCurrentTerms("2.4"))
    }

    @Test
    fun backgroundBackupWaitsForNetworkBatteryAndStorageHeadroom() {
        val constraints = ManagedCloudScheduler.constraints

        assertEquals(NetworkType.CONNECTED, constraints.requiredNetworkType)
        assertTrue(constraints.requiresBatteryNotLow())
        assertTrue(constraints.requiresStorageNotLow())
    }

    @Test
    fun successfulPartialPassContinuesWithoutEnteringFailureBackoff() {
        assertTrue(ManagedCloudScheduler.successfulPassNeedsContinuation(hasMore = true))
        assertEquals(
            false,
            ManagedCloudScheduler.successfulPassNeedsContinuation(hasMore = false),
        )
    }

    @Test
    fun retryFailureCategoriesAreBoundedAndDoNotExposeExceptionText() {
        assertEquals(
            "network_transport",
            ManagedCloudScheduler.retryFailureKind(
                ManagedStorageException.Network(),
            ),
        )
        assertEquals(
            "rate_limited",
            ManagedCloudScheduler.retryFailureKind(
                ManagedStorageException.Server(429, 300_000L),
            ),
        )
        assertEquals(
            "server_unavailable",
            ManagedCloudScheduler.retryFailureKind(
                ManagedStorageException.Server(503),
            ),
        )
        assertEquals(
            "other",
            ManagedCloudScheduler.retryFailureKind(
                IllegalStateException("must not enter diagnostics"),
            ),
        )
    }

    @Test
    fun coreFailureDoesNotPreventSocialOrSafetyCatchUp() = runTest {
        val attempted = mutableListOf<String>()

        val failures = ManagedCloudScheduler.runCatchUpScopeAttempts(
            core = {
                attempted += "core"
                throw ManagedStorageException.Network()
            },
            social = {
                attempted += "social"
            },
            safety = {
                attempted += "safety"
            },
        )

        assertEquals(listOf("core", "social", "safety"), attempted)
        assertEquals(1, failures.size)
        assertEquals(ManagedCloudScheduler.CatchUpScope.CORE, failures.single().scope)
        assertTrue(failures.single().error is ManagedStorageException.Network)
    }

    @Test
    fun safetyFailureSelectsNetworkOnlySafetyScopedRetry() {
        val safetySpec = ManagedCloudScheduler.retryWorkSpec(
            ManagedCloudScheduler.CatchUpScope.SAFETY,
        )

        assertEquals(
            ManagedCloudScheduler.CatchUpScope.SAFETY,
            ManagedCloudScheduler.retryScope(safetySpec.scopeToken),
        )
        assertEquals(
            NetworkType.CONNECTED,
            safetySpec.constraints.requiredNetworkType,
        )
        assertFalse(safetySpec.constraints.requiresBatteryNotLow())
        assertFalse(safetySpec.constraints.requiresStorageNotLow())
        assertTrue(
            ManagedCloudScheduler.shouldAttemptScope(
                ManagedCloudScheduler.retryScope(safetySpec.scopeToken),
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                ManagedCloudRetryState(
                    failureCount = 1,
                    notBeforeMs = 100L,
                ),
                nowMs = 100L,
            ),
        )
        assertFalse(
            ManagedCloudScheduler.shouldAttemptScope(
                ManagedCloudScheduler.retryScope(safetySpec.scopeToken),
                ManagedCloudScheduler.CatchUpScope.CORE,
                ManagedCloudRetryState(),
                nowMs = 100L,
            ),
        )

        val coreSpec = ManagedCloudScheduler.retryWorkSpec(
            ManagedCloudScheduler.CatchUpScope.CORE,
        )
        assertTrue(coreSpec.constraints.requiresBatteryNotLow())
        assertTrue(coreSpec.constraints.requiresStorageNotLow())

        val socialSpec = ManagedCloudScheduler.retryWorkSpec(
            ManagedCloudScheduler.CatchUpScope.SOCIAL,
        )
        assertTrue(socialSpec.constraints.requiresBatteryNotLow())
        assertTrue(socialSpec.constraints.requiresStorageNotLow())
    }

    @Test
    fun retryDeadlinesRemainIsolatedByScope() {
        val nowMs = 1_000L
        val (core, corePlan) = ManagedCloudRetryState().afterFailure(
            nowMs = nowMs,
            retryAfterMillis = 60_000L,
            jitterUnit = 0.5,
        )
        val (safety, safetyPlan) = ManagedCloudRetryState().afterFailure(
            nowMs = nowMs,
            retryAfterMillis = 900_000L,
            jitterUnit = 0.5,
        )

        assertTrue(corePlan.retryAfterApplied)
        assertTrue(safetyPlan.retryAfterApplied)
        assertTrue(core.shouldAttempt(nowMs + 60_000L))
        assertFalse(safety.shouldAttempt(nowMs + 60_000L))
        assertTrue(safety.shouldAttempt(nowMs + 900_000L))

        val clearedCore = ManagedCloudRetryState()
        assertTrue(clearedCore.shouldAttempt(nowMs))
        assertFalse(safety.shouldAttempt(nowMs))
    }

    @Test
    fun requestedRetryReschedulesForItsExactPersistedRemainingDelay() {
        val futureSafety = ManagedCloudRetryState(
            failureCount = 2,
            notBeforeMs = 10_000L,
        )

        assertFalse(
            ManagedCloudScheduler.shouldAttemptScope(
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                futureSafety,
                nowMs = 9_999L,
            ),
        )
        assertTrue(
            ManagedCloudScheduler.shouldAttemptScope(
                requestedScope = null,
                candidateScope = ManagedCloudScheduler.CatchUpScope.CORE,
                retryState = ManagedCloudRetryState(),
                nowMs = 9_999L,
            ),
        )
        assertTrue(
            ManagedCloudScheduler.shouldAttemptScope(
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                futureSafety,
                nowMs = 10_000L,
            ),
        )
        val schedule = ManagedCloudScheduler.earlyScopedRetrySchedule(
            ManagedCloudScheduler.CatchUpScope.SAFETY,
            futureSafety,
            nowMs = 9_001L,
        )
        requireNotNull(schedule)
        assertEquals(
            "safety",
            schedule.workSpec.scopeToken,
        )
        assertEquals(
            999L,
            schedule.delayMillis,
        )
        assertNull(
            ManagedCloudScheduler.earlyScopedRetrySchedule(
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                futureSafety,
                nowMs = 10_000L,
            ),
        )
        assertNull(
            ManagedCloudScheduler.earlyScopedRetrySchedule(
                ManagedCloudScheduler.CatchUpScope.SAFETY,
                ManagedCloudRetryState(),
                nowMs = 9_001L,
            ),
        )
        assertNull(
            ManagedCloudScheduler.earlyScopedRetrySchedule(
                requestedScope = null,
                retryState = futureSafety,
                nowMs = 9_001L,
            ),
        )
    }

    @Test
    fun earlyRetryEnqueueReceivesTheUnmodifiedCalculatedDelay() = runTest {
        val schedule = ManagedCloudScheduler.earlyScopedRetrySchedule(
            requestedScope = ManagedCloudScheduler.CatchUpScope.CORE,
            retryState = ManagedCloudRetryState(
                failureCount = 3,
                notBeforeMs = 75_000L,
            ),
            nowMs = 12_345L,
        )
        requireNotNull(schedule)
        var captured: ManagedCloudScheduler.RetrySchedule? = null

        val succeeded = ManagedCloudScheduler.retryScheduleEnqueueSucceeded(
            schedule,
        ) {
            captured = it
        }

        assertTrue(succeeded)
        assertEquals(62_655L, captured?.delayMillis)
        assertEquals("core", captured?.workSpec?.scopeToken)
    }

    @Test
    fun asynchronousEnqueueFailureFallsBackToTheCurrentWorkersRetry() = runTest {
        assertTrue(
            ManagedCloudScheduler.isAutomaticRetryable(
                ManagedStorageException.Network(),
            ),
        )
        val completion = CompletableDeferred<Unit>()
        val result = async(start = CoroutineStart.UNDISPATCHED) {
            ManagedCloudScheduler.retryEnqueueSucceeded {
                completion.await()
            }
        }

        assertFalse(result.isCompleted)
        completion.completeExceptionally(
            IllegalStateException("synthetic asynchronous enqueue failure"),
        )
        assertFalse(result.await())
        assertFalse(
            ManagedCloudScheduler.isAutomaticRetryable(
                ManagedStorageException.InvalidResponse(),
            ),
        )
    }

    @Test
    fun failedScopedEnqueueReleasesDeadlineBeforeUnscopedWorkerRetry() = runTest {
        val scope = ManagedCloudScheduler.CatchUpScope.SOCIAL
        val nowMs = 1_000L
        var persistedState = ManagedCloudRetryState(
            failureCount = 2,
            notBeforeMs = 61_000L,
        )
        val schedule = ManagedCloudScheduler.RetrySchedule(
            workSpec = ManagedCloudScheduler.retryWorkSpec(scope),
            delayMillis = persistedState.notBeforeMs - nowMs,
        )

        val outcome = ManagedCloudScheduler.scopedRetryEnqueueTransition(
            schedule = schedule,
            releasePersistedDeadline = {
                persistedState = ManagedCloudRetryState()
                true
            },
            enqueue = {
                throw IllegalStateException("synthetic scoped enqueue failure")
            },
        )

        assertEquals(
            ManagedCloudScheduler.RetryEnqueueOutcome.WORKER_RETRY,
            outcome,
        )
        assertEquals("worker_retry", outcome.diagnosticToken)
        assertFalse(persistedState.pending)
        assertTrue(
            ManagedCloudScheduler.shouldAttemptScope(
                requestedScope = null,
                candidateScope = scope,
                retryState = persistedState,
                nowMs = nowMs,
            ),
        )
    }

    @Test
    fun failedEnqueueAndDeadlineCommitStayRetryableUntilScopedWorkIsRecovered() = runTest {
        val scope = ManagedCloudScheduler.CatchUpScope.SOCIAL
        val nowMs = 1_000L
        val preferences = FakeSharedPreferences(
            commitResults = listOf(
                true, // Scope migration.
                true, // Persist the retry deadline.
                false, // Fail the attempted deadline release.
            ),
        )
        val retryStore = ManagedCloudRetryStore(preferences)
        val plan = retryStore.recordFailure(
            scope = scope,
            nowMs = nowMs,
            retryAfterMillis = 60_000L,
            jitterUnit = 0.5,
        )
        val schedule = ManagedCloudScheduler.RetrySchedule(
            workSpec = ManagedCloudScheduler.retryWorkSpec(scope),
            delayMillis = plan.delayMillis,
        )

        val outcome = ManagedCloudScheduler.scopedRetryEnqueueTransition(
            schedule = schedule,
            releasePersistedDeadline = {
                retryStore.clear(scope)
            },
            enqueue = {
                throw IllegalStateException("synthetic scoped enqueue failure")
            },
        )

        assertEquals(
            ManagedCloudScheduler.RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED,
            outcome,
        )
        assertEquals("deadline_release_failed", outcome.diagnosticToken)
        assertTrue(retryStore.state(scope).pending)
        assertEquals(
            ManagedCloudScheduler.RetryWorkerDecision.RETRY,
            ManagedCloudScheduler.retryWorkerDecision(outcome),
        )

        val recoverySchedules = ManagedCloudScheduler.retryRecoverySchedules(
            requestedScope = null,
            runAttemptCount = 1,
            retryStates = ManagedCloudScheduler.CatchUpScope.entries.associateWith {
                retryStore.state(it)
            },
            nowMs = nowMs + 1_000L,
        )
        assertEquals(1, recoverySchedules.size)
        assertEquals(scope.token, recoverySchedules.single().workSpec.scopeToken)
        assertEquals(
            retryStore.state(scope).notBeforeMs - (nowMs + 1_000L),
            recoverySchedules.single().delayMillis,
        )

        assertFalse(
            ManagedCloudScheduler.recoverPersistedRetrySchedules(
                recoverySchedules,
            ) {
                throw IllegalStateException("synthetic recovery enqueue failure")
            },
        )

        var recoveredSchedule: ManagedCloudScheduler.RetrySchedule? = null
        assertTrue(
            ManagedCloudScheduler.recoverPersistedRetrySchedules(
                recoverySchedules,
            ) {
                recoveredSchedule = it
            },
        )
        assertEquals(recoverySchedules.single(), recoveredSchedule)
    }

    @Test
    fun retryOutcomeAggregationKeepsPersistenceFailureTerminal() {
        val scheduled = ManagedCloudScheduler.RetryEnqueueOutcome.SCHEDULED
        val retry = ManagedCloudScheduler.RetryEnqueueOutcome.WORKER_RETRY
        val persistenceFailure =
            ManagedCloudScheduler.RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED

        assertEquals(
            retry,
            ManagedCloudScheduler.aggregateRetryEnqueueOutcome(
                scheduled,
                retry,
            ),
        )
        assertEquals(
            persistenceFailure,
            ManagedCloudScheduler.aggregateRetryEnqueueOutcome(
                retry,
                persistenceFailure,
            ),
        )
        assertEquals(
            ManagedCloudScheduler.RetryWorkerDecision.RETRY,
            ManagedCloudScheduler.retryWorkerDecision(retry),
        )
        assertEquals(
            ManagedCloudScheduler.RetryWorkerDecision.RETRY,
            ManagedCloudScheduler.retryWorkerDecision(persistenceFailure),
        )
    }

    @Test
    fun firstAttemptAndScopedRetriesDoNotRunUnscopedRecovery() {
        val state = ManagedCloudRetryState(
            failureCount = 1,
            notBeforeMs = 60_000L,
        )
        val states = mapOf(ManagedCloudScheduler.CatchUpScope.CORE to state)

        assertTrue(
            ManagedCloudScheduler.retryRecoverySchedules(
                requestedScope = null,
                runAttemptCount = 0,
                retryStates = states,
                nowMs = 1_000L,
            ).isEmpty(),
        )
        assertTrue(
            ManagedCloudScheduler.retryRecoverySchedules(
                requestedScope = ManagedCloudScheduler.CatchUpScope.CORE,
                runAttemptCount = 1,
                retryStates = states,
                nowMs = 1_000L,
            ).isEmpty(),
        )
    }

    @Test
    fun urgentSafetyCatchUpWaitsOnlyForNetwork() {
        val constraints = ManagedCloudScheduler.urgentNetworkConstraints

        assertEquals(NetworkType.CONNECTED, constraints.requiredNetworkType)
        assertFalse(constraints.requiresBatteryNotLow())
        assertFalse(constraints.requiresStorageNotLow())
    }

    @Test
    fun safetyPushWorkIdentityIsStableAndStrict() {
        val incidentId = UUID.fromString(
            "00000000-0000-0000-0000-000000000301",
        )

        assertEquals(
            "noop_managed_safety_push_v1:$incidentId",
            ManagedCloudScheduler.safetyPushWorkName(incidentId),
        )
        assertEquals(
            incidentId,
            ManagedCloudScheduler.safetyPushIncidentId(incidentId.toString()),
        )
        assertNull(ManagedCloudScheduler.safetyPushIncidentId("not-a-uuid"))
        assertNull(ManagedCloudScheduler.safetyPushIncidentId(null))
    }
}
