package com.noop.ble

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BackfillAnalysisRevisionLatchTest {
    @Test
    fun deviceSwitchKeepsEachInFlightRevisionBoundToItsSource() = runTest {
        val firstStarted = CompletableDeferred<Unit>()
        val finishFirst = CompletableDeferred<Unit>()
        val processed = mutableListOf<BackfillAnalysisRevisionLatch.Revision>()
        val worker = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = { revision ->
                processed += revision
                if (revision.deviceId == "band-a") {
                    firstStarted.complete(Unit)
                    finishFirst.await()
                }
            },
        )

        worker.noteCommit("band-a")
        firstStarted.await()
        worker.noteCommit("band-b")
        finishFirst.complete(Unit)
        advanceUntilIdle()

        assertEquals(listOf("band-a", "band-b"), processed.map { it.deviceId })
        assertEquals(listOf(1L, 2L), processed.map { it.value })
    }

    @Test
    fun commitsDuringPassCoalesceIntoExactlyOneTrailingPass() = runTest {
        val firstStarted = CompletableDeferred<Unit>()
        val finishFirst = CompletableDeferred<Unit>()
        val processed = mutableListOf<Long>()
        var durableClears = 0
        val worker = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = { revision ->
                processed += revision.value
                if (processed.size == 1) {
                    firstStarted.complete(Unit)
                    finishFirst.await()
                }
            },
            clearDurablyDirty = { durableClears += 1 },
        )

        worker.noteCommit("band-a")
        firstStarted.await()
        worker.noteCommit("band-a")
        worker.noteCommit("band-a")
        worker.noteCommit("band-a")
        finishFirst.complete(Unit)
        advanceUntilIdle()

        assertEquals(listOf(1L, 4L), processed)
        assertEquals("the source clears only after its trailing revision", 1, durableClears)
    }

    @Test
    fun ordinaryFailureIsContainedAndRetriedWithoutClearingDurableWork() = runTest {
        val durable = linkedSetOf<String>()
        val failures = mutableListOf<Throwable>()
        var attempts = 0
        val worker = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = {
                attempts += 1
                if (attempts == 1) error("database temporarily closed")
            },
            markDurablyDirty = { durable += it },
            clearDurablyDirty = { durable -= it },
            onFailure = { _, failure -> failures += failure },
        )

        worker.noteCommit("band-a")
        runCurrent()
        assertEquals(1, attempts)
        assertEquals(setOf("band-a"), durable)
        assertEquals(1, failures.size)

        advanceTimeBy(100L)
        runCurrent()
        assertEquals(2, attempts)
        assertTrue(durable.isEmpty())
        assertTrue(worker.pendingDeviceIds().isEmpty())
    }

    @Test
    fun transientCancellationIsContainedAndRetriedWhileScopeRemainsActive() = runTest {
        val durable = linkedSetOf<String>()
        val failures = mutableListOf<Throwable>()
        var attempts = 0
        val worker = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = {
                attempts += 1
                if (attempts == 1) throw CancellationException("dependency timed out")
            },
            markDurablyDirty = { durable += it },
            clearDurablyDirty = { durable -= it },
            onFailure = { _, failure -> failures += failure },
        )

        worker.noteCommit("band-a")
        runCurrent()
        assertEquals(1, attempts)
        assertEquals(setOf("band-a"), durable)
        assertEquals(1, failures.size)

        advanceTimeBy(100L)
        runCurrent()
        assertEquals(2, attempts)
        assertTrue(durable.isEmpty())
        assertTrue(worker.pendingDeviceIds().isEmpty())
    }

    @Test
    fun cancellationKeepsDurableWorkForServiceOnlyStartupResume() = runTest {
        val durable = linkedSetOf<String>()
        val processStarted = CompletableDeferred<Unit>()
        val neverCompletes = CompletableDeferred<Unit>()
        val ownerJob = Job()
        val ownerScope = CoroutineScope(ownerJob + StandardTestDispatcher(testScheduler))
        var cancelledAttempts = 0
        val cancelledWorker = BackfillAnalysisWorker(
            scope = ownerScope,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = {
                cancelledAttempts += 1
                processStarted.complete(Unit)
                neverCompletes.await()
            },
            markDurablyDirty = { durable += it },
            clearDurablyDirty = { durable -= it },
        )

        cancelledWorker.noteCommit("band-a")
        runCurrent()
        processStarted.await()
        ownerJob.cancel()
        runCurrent()

        assertEquals(1, cancelledAttempts)
        assertEquals(setOf("band-a"), durable)
        assertEquals(setOf("band-a"), cancelledWorker.pendingDeviceIds())

        val resumedSources = mutableListOf<String>()
        val restartedWorker = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = { resumedSources += it.deviceId },
            clearDurablyDirty = { durable -= it },
        )
        restartedWorker.resume(durable.toList())
        advanceUntilIdle()

        assertEquals(listOf("band-a"), resumedSources)
        assertTrue(durable.isEmpty())
    }

    @Test
    fun cancelledScopeCannotStrandClaimBeforeLaunch() = runTest {
        val latch = BackfillAnalysisRevisionLatch()
        val cancelledJob = Job().apply { cancel() }
        val cancelledScope = CoroutineScope(cancelledJob + StandardTestDispatcher(testScheduler))
        val worker = BackfillAnalysisWorker(
            scope = cancelledScope,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = { fail("cancelled scope must not process work") },
            latch = latch,
        )

        worker.noteCommit("band-a")
        runCurrent()

        assertEquals(setOf("band-a"), latch.pendingDeviceIds())
        assertFalse(latch.hasWorkerClaim())

        val recovered = mutableListOf<String>()
        val replacement = BackfillAnalysisWorker(
            scope = this,
            debounceMillis = 0L,
            retryDelayMillis = 100L,
            processRevision = { recovered += it.deviceId },
            latch = latch,
        )
        replacement.resume(emptyList())
        advanceUntilIdle()

        assertEquals(listOf("band-a"), recovered)
        assertTrue(latch.pendingDeviceIds().isEmpty())
    }

    @Test
    fun concurrentCommitAndCleanReleaseHaveExactlyOneWorkerOwner() {
        assertCommitReleaseOrdering(commitFirst = true)
        assertCommitReleaseOrdering(commitFirst = false)
    }

    @Test
    fun launchAbortRetainsRevisionForReplacementClaim() {
        val latch = BackfillAnalysisRevisionLatch()
        val initial = latch.noteCommitAndClaimWorker("band-a")
        val claim = requireNotNull(initial.workerClaim)

        assertTrue(latch.abortWorkerLaunch(claim))
        assertFalse(latch.hasWorkerClaim())
        assertEquals(setOf("band-a"), latch.pendingDeviceIds())

        val replacement = requireNotNull(latch.claimPendingWorker())
        assertTrue(latch.workerStarted(replacement))
        assertEquals("band-a", latch.nextRevisionOrRelease(replacement)?.deviceId)
    }

    @Test
    fun failedAnalysisCannotRunDependentsOrAdvanceWatermark() = runTest {
        var watermark: String? = "old"
        var dependents = 0
        var writes = 0

        try {
            runFingerprintGatedBackfillAnalysis(
                readFingerprint = { "new" },
                readWatermark = { watermark },
                analyze = { error("scoring failed") },
                afterAnalysis = { dependents += 1 },
                persistWatermark = {
                    writes += 1
                    watermark = it
                },
            )
            fail("analysis failure must propagate to the retry worker")
        } catch (expected: IllegalStateException) {
            assertEquals("scoring failed", expected.message)
        }

        assertEquals(0, dependents)
        assertEquals(0, writes)
        assertEquals("old", watermark)
    }

    @Test
    fun fingerprintFailureCannotRunAnalysisOrAdvanceWatermark() = runTest {
        var analyses = 0
        var writes = 0

        try {
            runFingerprintGatedBackfillAnalysis(
                readFingerprint = { error("fingerprint unavailable") },
                readWatermark = { "old" },
                analyze = { analyses += 1 },
                afterAnalysis = { fail("dependents must not run") },
                persistWatermark = { writes += 1 },
            )
            fail("fingerprint failure must propagate to the retry worker")
        } catch (expected: IllegalStateException) {
            assertEquals("fingerprint unavailable", expected.message)
        }

        assertEquals(0, analyses)
        assertEquals(0, writes)
    }

    private fun assertCommitReleaseOrdering(commitFirst: Boolean) {
        val latch = BackfillAnalysisRevisionLatch()
        val initial = latch.noteCommitAndClaimWorker("band-a")
        val originalClaim = requireNotNull(initial.workerClaim)
        assertTrue(latch.workerStarted(originalClaim))
        val original = requireNotNull(latch.nextRevisionOrRelease(originalClaim))
        latch.complete(originalClaim, original)

        val start = CountDownLatch(1)
        val commitFinished = CountDownLatch(1)
        val releaseFinished = CountDownLatch(1)
        val enqueueResult =
            AtomicReference<BackfillAnalysisRevisionLatch.Enqueue>()
        val releaseResult =
            AtomicReference<BackfillAnalysisRevisionLatch.Revision?>()
        val pool = Executors.newFixedThreadPool(2)
        try {
            val commitFuture = pool.submit {
                start.await()
                if (!commitFirst) releaseFinished.await()
                enqueueResult.set(latch.noteCommitAndClaimWorker("band-b"))
                commitFinished.countDown()
            }
            val releaseFuture = pool.submit {
                start.await()
                if (commitFirst) commitFinished.await()
                releaseResult.set(latch.nextRevisionOrRelease(originalClaim))
                releaseFinished.countDown()
            }

            start.countDown()
            commitFuture.get(5, TimeUnit.SECONDS)
            releaseFuture.get(5, TimeUnit.SECONDS)
        } finally {
            pool.shutdownNow()
        }

        val enqueue = assertNotNull(enqueueResult.get()).let { enqueueResult.get() }
        if (commitFirst) {
            assertNull("existing worker owns the concurrent commit", enqueue.workerClaim)
            assertEquals("band-b", releaseResult.get()?.deviceId)
        } else {
            assertNull("clean worker releases before the commit", releaseResult.get())
            val replacement = assertNotNull(enqueue.workerClaim).let { enqueue.workerClaim!! }
            // A stale finally from the old worker must not clear the replacement's tokenized claim.
            latch.workerStopped(originalClaim)
            assertTrue(latch.hasWorkerClaim())
            assertTrue(latch.workerStarted(replacement))
            assertEquals("band-b", latch.nextRevisionOrRelease(replacement)?.deviceId)
        }
    }
}
