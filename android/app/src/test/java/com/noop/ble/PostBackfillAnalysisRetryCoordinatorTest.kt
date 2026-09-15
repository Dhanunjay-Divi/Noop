package com.noop.ble

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PostBackfillAnalysisRetryCoordinatorTest {
    @Test
    fun replacementFailurePreservesLastViableWakeAndMarker() = runTest {
        val scheduled = retry("existing-work", 225_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
            enqueueSucceeds = false,
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 125_000L,
            nowEpochMillis = 100_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.FAILED, outcome)
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.states[scheduled.workId])
        assertSame(scheduled, store.currentValue())
        assertEquals(listOf("state:existing-work", "enqueue"), backend.operations)
        assertEquals(0, backend.cancelUniqueCalls)
    }

    @Test
    fun laterBoundaryKeepsTheEarlierWaitingWake() = runTest {
        val operations = mutableListOf<String>()
        val scheduled = retry("existing-work", 125_000L)
        val store = FakeStateStore(initial = scheduled, operations = operations)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
            operations = operations,
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 225_000L,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.DEDUPLICATED, outcome)
        assertEquals(listOf("load", "state:existing-work"), operations)
        assertTrue(backend.enqueued.isEmpty())
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.states[scheduled.workId])
        assertSame(scheduled, store.currentValue())
        assertEquals(0, backend.cancelUniqueCalls)
    }

    @Test
    fun earlierBoundaryIsDurablyEnqueuedBeforeNewMarkerIsSaved() = runTest {
        val operations = mutableListOf<String>()
        val scheduled = retry("existing-work", 225_000L)
        val store = FakeStateStore(initial = scheduled, operations = operations)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
            operations = operations,
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 125_000L,
            nowEpochMillis = 100_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.RESCHEDULED, outcome)
        assertEquals(listOf("load", "state:existing-work", "enqueue", "save"), operations)
        val replacement = backend.enqueued.single()
        assertNotEquals(scheduled.workId, replacement.workId)
        assertEquals(125_000L, replacement.retryAtEpochMillis)
        assertEquals(PostBackfillRetryWorkState.FINISHED, backend.states[scheduled.workId])
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.states[replacement.workId])
        assertEquals(replacement.workId, store.currentValue()?.workId)
    }

    @Test
    fun cancellationAfterPublicationStartsStillPublishesTheReplacement() = runTest {
        val enqueueStarted = CompletableDeferred<Unit>()
        val releaseEnqueue = CompletableDeferred<Unit>()
        val scheduled = retry("existing-work", 90_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.RUNNING),
            beforeEnqueue = {
                enqueueStarted.complete(Unit)
                releaseEnqueue.await()
            },
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val scheduling = launch {
            coordinator.schedule(
                retryAtEpochMillis = 225_000L,
                nowEpochMillis = 100_000L,
            )
        }
        enqueueStarted.await()
        scheduling.cancel()
        releaseEnqueue.complete(Unit)
        scheduling.join()

        assertTrue(scheduling.isCancelled)
        val replacement = backend.enqueued.single()
        assertEquals(225_000L, replacement.retryAtEpochMillis)
        assertEquals(PostBackfillRetryWorkState.FINISHED, backend.states[scheduled.workId])
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.states[replacement.workId])
        assertEquals(replacement.workId, store.currentValue()?.workId)
    }

    @Test
    fun cancellationBeforePublicationStartsLeavesTheExistingWakeAndMarkerIntact() = runTest {
        val stateReadStarted = CompletableDeferred<Unit>()
        val releaseStateRead = CompletableDeferred<Unit>()
        val scheduled = retry("existing-work", 90_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.RUNNING),
            beforeState = {
                stateReadStarted.complete(Unit)
                releaseStateRead.await()
            },
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val scheduling = launch {
            coordinator.schedule(
                retryAtEpochMillis = 225_000L,
                nowEpochMillis = 100_000L,
            )
        }
        stateReadStarted.await()
        scheduling.cancel()
        releaseStateRead.complete(Unit)
        scheduling.join()

        assertTrue(scheduling.isCancelled)
        assertTrue(backend.enqueued.isEmpty())
        assertEquals(PostBackfillRetryWorkState.RUNNING, backend.states[scheduled.workId])
        assertSame(scheduled, store.currentValue())
    }

    @Test
    fun publicationTimeoutIsBoundedAndPreservesTheExistingWakeAndMarker() = runTest {
        val enqueueStarted = CompletableDeferred<Unit>()
        val neverReleaseEnqueue = CompletableDeferred<Unit>()
        val scheduled = retry("existing-work", 90_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.RUNNING),
            beforeEnqueue = {
                enqueueStarted.complete(Unit)
                neverReleaseEnqueue.await()
            },
        )
        val coordinator = PostBackfillRetryCoordinator(
            stateStore = store,
            backend = backend,
            publicationTimeoutMillis = 100L,
        )

        val outcome = async {
            coordinator.schedule(
                retryAtEpochMillis = 225_000L,
                nowEpochMillis = 100_000L,
            )
        }
        enqueueStarted.await()
        advanceTimeBy(100L)
        runCurrent()

        assertEquals(PostBackfillRetryScheduleOutcome.FAILED, outcome.await())
        assertTrue(backend.enqueued.isEmpty())
        assertEquals(PostBackfillRetryWorkState.RUNNING, backend.states[scheduled.workId])
        assertSame(scheduled, store.currentValue())
    }

    @Test
    fun postEnqueueMarkerFailureIsRecoveredByTheReplacementWork() = runTest {
        val scheduled = retry("existing-work", 225_000L)
        val store = FakeStateStore(initial = scheduled, saveSucceeds = false)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 125_000L,
            nowEpochMillis = 100_000L,
        )
        val replacement = backend.enqueued.single()

        assertEquals(PostBackfillRetryScheduleOutcome.RECOVERY_PENDING, outcome)
        assertSame(scheduled, store.currentValue())
        assertEquals(PostBackfillRetryWorkState.FINISHED, backend.states[scheduled.workId])
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.states[replacement.workId])

        store.saveSucceeds = true
        backend.states[replacement.workId] = PostBackfillRetryWorkState.RUNNING
        val decision = coordinator.beginExecution(
            workId = replacement.workId,
            retryAtEpochMillis = replacement.retryAtEpochMillis,
            protocolVersion = replacement.protocolVersion,
        )

        assertEquals(PostBackfillRetryExecutionDecision.RECOVERED, decision)
        assertEquals(replacement.workId, store.currentValue()?.workId)
    }

    @Test
    fun missingMarkerIsRecoveredOnlyByAStillViableV2Work() = runTest {
        val store = FakeStateStore()
        val backend = FakeWorkBackend(
            states = mutableMapOf("running-work" to PostBackfillRetryWorkState.RUNNING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val decision = coordinator.beginExecution(
            workId = "running-work",
            retryAtEpochMillis = 225_000L,
            protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
        )

        assertEquals(PostBackfillRetryExecutionDecision.RECOVERED, decision)
        assertEquals("running-work", store.currentValue()?.workId)
    }

    @Test
    fun mismatchedWorkIsRejectedWhileSelectedReplacementIsViable() = runTest {
        val scheduled = retry("replacement-work", 225_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(
                scheduled.workId to PostBackfillRetryWorkState.WAITING,
                "stale-work" to PostBackfillRetryWorkState.RUNNING,
            ),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val decision = coordinator.beginExecution(
            workId = "stale-work",
            retryAtEpochMillis = 125_000L,
            protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
        )

        assertEquals(PostBackfillRetryExecutionDecision.STALE, decision)
        assertSame(scheduled, store.currentValue())
        assertTrue(store.saved.isEmpty())
    }

    @Test
    fun legacyV1WorkIsRejectedWithoutReadingOrMutatingState() = runTest {
        val scheduled = retry("replacement-work", 225_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend()
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val decision = coordinator.beginExecution(
            workId = "legacy-work",
            retryAtEpochMillis = 125_000L,
            protocolVersion = 0,
        )

        assertEquals(PostBackfillRetryExecutionDecision.LEGACY, decision)
        assertSame(scheduled, store.currentValue())
        assertEquals(0, store.loadCalls)
        assertTrue(backend.operations.isEmpty())
    }

    @Test
    fun activeBoundaryIsDeduplicatedWithoutReplacement() = runTest {
        val scheduled = retry("existing-work", 125_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = scheduled.retryAtEpochMillis,
            nowEpochMillis = 100_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.DEDUPLICATED, outcome)
        assertSame(scheduled, store.currentValue())
        assertTrue(backend.enqueued.isEmpty())
    }

    @Test
    fun runningBoundaryAlwaysInstallsOneSuccessor() = runTest {
        val scheduled = retry("running-work", 125_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.RUNNING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = scheduled.retryAtEpochMillis,
            nowEpochMillis = 100_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.RESCHEDULED, outcome)
        assertEquals(1, backend.enqueued.size)
        assertEquals(0, backend.cancelUniqueCalls)
    }

    @Test
    fun runningBoundaryUsesTheNewlyRequestedFutureBoundary() = runTest {
        val scheduled = retry("running-work", 90_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.RUNNING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 225_000L,
            nowEpochMillis = 100_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.RESCHEDULED, outcome)
        assertEquals(225_000L, backend.enqueued.single().retryAtEpochMillis)
        assertEquals(125_000L, backend.enqueued.single().initialDelayMillis)
        assertEquals(backend.enqueued.single().workId, store.currentValue()?.workId)
    }

    @Test
    fun clockChangeWithPendingSourceUsesAtomicReplacementWithoutPreCancel() = runTest {
        val scheduled = retry("stale-work", 125_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.reconcileClockChange(
            pendingSources = PostBackfillPendingSourceRead.PRESENT,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.RESCHEDULED, outcome)
        assertEquals(1, backend.enqueued.size)
        assertEquals(200_000L, backend.enqueued.single().retryAtEpochMillis)
        assertEquals(0, backend.cancelUniqueCalls)
    }

    @Test
    fun clockChangeReadFailureLeavesWakeAndMarkerUntouched() = runTest {
        val scheduled = retry("existing-work", 125_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.reconcileClockChange(
            pendingSources = PostBackfillPendingSourceRead.FAILED,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.SOURCE_READ_FAILED, outcome)
        assertSame(scheduled, store.currentValue())
        assertTrue(backend.operations.isEmpty())
        assertEquals(0, backend.cancelUniqueCalls)
    }

    @Test
    fun clockChangeWithProvenEmptySourcesCancelsAndClears() = runTest {
        val scheduled = retry("existing-work", 125_000L)
        val store = FakeStateStore(initial = scheduled)
        val backend = FakeWorkBackend(
            states = mutableMapOf(scheduled.workId to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.reconcileClockChange(
            pendingSources = PostBackfillPendingSourceRead.EMPTY,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.CLEARED, outcome)
        assertEquals(1, backend.cancelUniqueCalls)
        assertEquals(PostBackfillRetryStateRead.Empty, store.load())
    }

    @Test
    fun scheduleStateReadFailureDoesNotReplaceExistingWork() = runTest {
        val store = FakeStateStore(loadFails = true)
        val backend = FakeWorkBackend(
            states = mutableMapOf("existing-work" to PostBackfillRetryWorkState.WAITING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 225_000L,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.FAILED, outcome)
        assertTrue(backend.operations.isEmpty())
    }

    @Test
    fun corruptScheduleStateIsClearedBeforeAReplacementIsPublished() = runTest {
        val operations = mutableListOf<String>()
        val store = FakeStateStore(corrupt = true, operations = operations)
        val backend = FakeWorkBackend(operations = operations)
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val outcome = coordinator.schedule(
            retryAtEpochMillis = 225_000L,
            nowEpochMillis = 200_000L,
        )

        assertEquals(PostBackfillRetryScheduleOutcome.SCHEDULED, outcome)
        assertEquals(listOf("load", "clear", "enqueue", "save"), operations)
        assertEquals(1, backend.enqueued.size)
        assertEquals(backend.enqueued.single().workId, store.currentValue()?.workId)
    }

    @Test
    fun viableRunningWorkRepairsCorruptSelectorState() = runTest {
        val store = FakeStateStore(corrupt = true)
        val backend = FakeWorkBackend(
            states = mutableMapOf("running-work" to PostBackfillRetryWorkState.RUNNING),
        )
        val coordinator = PostBackfillRetryCoordinator(store, backend)

        val decision = coordinator.beginExecution(
            workId = "running-work",
            retryAtEpochMillis = 225_000L,
            protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
        )

        assertEquals(PostBackfillRetryExecutionDecision.RECOVERED, decision)
        assertEquals("running-work", store.currentValue()?.workId)
    }

    @Test
    fun completionDoesNotClearAReplacementMarker() = runTest {
        val replacement = retry("replacement-work", 225_000L)
        val store = FakeStateStore(initial = replacement)
        val coordinator = PostBackfillRetryCoordinator(store, FakeWorkBackend())

        val finished = coordinator.finishExecution("old-work")

        assertTrue(finished)
        assertSame(replacement, store.currentValue())
        assertEquals(0, store.clearCalls)
    }

    @Test
    fun completionClearFailureRetainsMarkerAndRequestsRetry() = runTest {
        val current = retry("current-work", 225_000L)
        val store = FakeStateStore(initial = current, clearSucceeds = false)
        val coordinator = PostBackfillRetryCoordinator(store, FakeWorkBackend())

        val finished = coordinator.finishExecution(current.workId)

        assertFalse(finished)
        assertSame(current, store.currentValue())
        assertEquals(1, store.clearCalls)
    }

    private fun retry(workId: String, boundary: Long) =
        PostBackfillScheduledRetry(workId, boundary)

    private class FakeStateStore(
        initial: PostBackfillScheduledRetry? = null,
        var saveSucceeds: Boolean = true,
        var clearSucceeds: Boolean = true,
        var loadFails: Boolean = false,
        var corrupt: Boolean = false,
        private val operations: MutableList<String> = mutableListOf(),
    ) : PostBackfillRetryStateStore {
        private var value: PostBackfillScheduledRetry? = initial
        val saved = mutableListOf<PostBackfillScheduledRetry>()
        var loadCalls = 0
            private set
        var clearCalls = 0
            private set

        override fun load(): PostBackfillRetryStateRead {
            loadCalls += 1
            operations += "load"
            if (loadFails) return PostBackfillRetryStateRead.Failed
            if (corrupt) return PostBackfillRetryStateRead.Corrupt
            return value?.let(PostBackfillRetryStateRead::Present)
                ?: PostBackfillRetryStateRead.Empty
        }

        override fun save(value: PostBackfillScheduledRetry): Boolean {
            operations += "save"
            saved += value
            if (!saveSucceeds) return false
            this.value = value
            return true
        }

        override fun clear(expectedWorkId: String?): Boolean {
            operations += "clear"
            clearCalls += 1
            if (!clearSucceeds) return false
            corrupt = false
            if (expectedWorkId == null || value?.workId == expectedWorkId) {
                value = null
            }
            return true
        }

        fun currentValue(): PostBackfillScheduledRetry? = value
    }

    private class FakeWorkBackend(
        val states: MutableMap<String, PostBackfillRetryWorkState> = mutableMapOf(),
        var enqueueSucceeds: Boolean = true,
        var cancelUniqueSucceeds: Boolean = true,
        val operations: MutableList<String> = mutableListOf(),
        val beforeState: suspend () -> Unit = {},
        val beforeEnqueue: suspend () -> Unit = {},
    ) : PostBackfillRetryWorkBackend {
        val enqueued = mutableListOf<PostBackfillRetryWorkSpec>()
        var cancelUniqueCalls = 0
            private set

        override suspend fun state(workId: String): PostBackfillRetryWorkState {
            operations += "state:$workId"
            beforeState()
            return states[workId] ?: PostBackfillRetryWorkState.MISSING
        }

        override suspend fun enqueueReplacement(spec: PostBackfillRetryWorkSpec): Boolean {
            operations += "enqueue"
            beforeEnqueue()
            enqueued += spec
            if (!enqueueSucceeds) return false
            states.entries.forEach { entry ->
                if (
                    entry.value == PostBackfillRetryWorkState.WAITING ||
                    entry.value == PostBackfillRetryWorkState.RUNNING
                ) {
                    entry.setValue(PostBackfillRetryWorkState.FINISHED)
                }
            }
            states[spec.workId] = PostBackfillRetryWorkState.WAITING
            return true
        }

        override suspend fun cancelUnique(): Boolean {
            operations += "cancel_unique"
            cancelUniqueCalls += 1
            if (!cancelUniqueSucceeds) return false
            states.entries.forEach { entry ->
                if (
                    entry.value == PostBackfillRetryWorkState.WAITING ||
                    entry.value == PostBackfillRetryWorkState.RUNNING
                ) {
                    entry.setValue(PostBackfillRetryWorkState.FINISHED)
                }
            }
            return true
        }
    }
}
