package com.noop.ingest

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectBmiProjectionCoordinatorTest {
    private data class LocalProjection(
        val heightCm: Double,
    )

    private data class ProjectionCommit(
        val heightCm: Double,
        val fingerprint: String,
        val updatedAtMs: Long,
    )

    private class Store(
        var applied: String? = null,
        private val failRead: Boolean = false,
        private val failProjection: Boolean = false,
        private val failCommit: Boolean = false,
    ) : HealthConnectBmiProjectionStateStore {
        var loads = 0
        val projections = mutableListOf<LocalProjection>()
        val commits = mutableListOf<ProjectionCommit>()

        override suspend fun loadFingerprint(): String? {
            loads += 1
            if (failRead) error("synthetic read failure")
            return applied
        }

        override suspend fun reconcileLocalProjection(heightCm: Double): Int {
            if (failProjection) error("synthetic projection failure")
            projections += LocalProjection(heightCm)
            return 1
        }

        override suspend fun commitProjectionAndFingerprint(
            heightCm: Double,
            fingerprint: String,
            updatedAtMs: Long,
        ): Int {
            if (failCommit) error("synthetic commit failure")
            commits += ProjectionCommit(heightCm, fingerprint, updatedAtMs)
            applied = fingerprint
            return 1
        }
    }

    private val weightType = HealthConnectBmiProjectionFingerprint.weightRecordType

    @Test
    fun confirmedHeightFingerprintIsStableAndChangesWithStoredProfileHeight() {
        val first = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        val sameStoredFloat = HealthConnectBmiProjectionFingerprint.forHeight(178.0f.toDouble())
        val changed = HealthConnectBmiProjectionFingerprint.forHeight(179.0)

        assertEquals(first, sameStoredFloat)
        assertTrue(first.startsWith("v1:confirmed:"))
        assertFalse(first == changed)
        assertEquals(
            HealthConnectBmiProjectionFingerprint.UNCONFIRMED,
            HealthConnectBmiProjectionFingerprint.forHeight(0.0),
        )
        assertEquals(
            HealthConnectBmiProjectionFingerprint.UNCONFIRMED,
            HealthConnectBmiProjectionFingerprint.forHeight(Double.NaN),
        )
        assertEquals(
            HealthConnectBmiProjectionFingerprint.UNCONFIRMED,
            HealthConnectBmiProjectionFingerprint.forHeight(Double.POSITIVE_INFINITY),
        )
    }

    @Test
    fun missingFingerprintDefersCommitUntilForcedWeightBootstrapSucceeds() = runTest {
        val store = Store()
        val desired = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        var forced: Set<String>? = null

        val result = HealthConnectBmiProjectionCoordinator(store, nowMs = { 123L }).reconcile(
            recordTypes = setOf("Steps", weightType),
            heightCm = 178.0,
        ) {
            assertNull(store.applied)
            assertEquals(1, store.projections.size)
            assertTrue(store.commits.isEmpty())
            forced = it
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.Success)
        assertEquals(setOf(weightType), forced)
        assertEquals(listOf(LocalProjection(178.0)), store.projections)
        assertEquals(listOf(ProjectionCommit(178.0, desired, 123L)), store.commits)
        assertEquals(desired, store.applied)
    }

    @Test
    fun changedOrRemovedHeightForcesAnotherCompleteWeightProjection() = runTest {
        val old = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        val changedStore = Store(applied = old)
        var changedForced: Set<String>? = null
        HealthConnectBmiProjectionCoordinator(changedStore).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 170.0,
        ) {
            changedForced = it
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }
        assertEquals(setOf(weightType), changedForced)
        assertEquals(
            HealthConnectBmiProjectionFingerprint.forHeight(170.0),
            changedStore.applied,
        )

        val removedStore = Store(applied = changedStore.applied)
        var removedForced: Set<String>? = null
        HealthConnectBmiProjectionCoordinator(removedStore).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 0.0,
        ) {
            removedForced = it
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }
        assertEquals(setOf(weightType), removedForced)
        assertEquals(HealthConnectBmiProjectionFingerprint.UNCONFIRMED, removedStore.applied)
    }

    @Test
    fun matchingFingerprintDoesNotForceOrRewriteState() = runTest {
        val desired = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        val store = Store(applied = desired)
        var forced: Set<String>? = null

        val result = HealthConnectBmiProjectionCoordinator(store).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 178.0,
        ) {
            forced = it
            HealthConnectReconcileResult.Success(false, 0, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.Success)
        assertEquals(emptySet<String>(), forced)
        assertTrue(store.projections.isEmpty())
        assertTrue(store.commits.isEmpty())
        assertEquals(desired, store.applied)
    }

    @Test
    fun absentHealthConnectPermissionsStillCorrectLocalProjectionWithoutProviderBootstrap() = runTest {
        val old = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        val store = Store(applied = old)
        var forced: Set<String>? = null
        val desired = HealthConnectBmiProjectionFingerprint.forHeight(170.0)

        val result = HealthConnectBmiProjectionCoordinator(store).reconcile(
            recordTypes = emptySet(),
            heightCm = 170.0,
        ) {
            forced = it
            HealthConnectReconcileResult.Success(false, 0, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.Success)
        assertEquals(emptySet<String>(), forced)
        assertEquals(1, store.loads)
        assertEquals(desired, store.applied)
        assertTrue(store.projections.isEmpty())
        assertEquals(170.0, store.commits.single().heightCm, 0.0)
        assertEquals(desired, store.commits.single().fingerprint)
    }

    @Test
    fun providerFailureKeepsCorrectedLocalProjectionButOldFingerprintForRetry() = runTest {
        val projectionFailureStore = Store()
        val projectionFailure = HealthConnectBmiProjectionCoordinator(projectionFailureStore).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 178.0,
        ) {
            HealthConnectReconcileResult.RetryableFailure("projection failed")
        }
        assertTrue(projectionFailure is HealthConnectReconcileResult.RetryableFailure)
        assertEquals(1, projectionFailureStore.projections.size)
        assertTrue(projectionFailureStore.commits.isEmpty())
        assertNull(projectionFailureStore.applied)
    }

    @Test
    fun cancelledProviderBootstrapLeavesOldFingerprintAndNextRunForcesAgain() = runTest {
        val old = HealthConnectBmiProjectionFingerprint.forHeight(178.0)
        val desired = HealthConnectBmiProjectionFingerprint.forHeight(170.0)
        val store = Store(applied = old)
        val cancellation = CancellationException("synthetic provider cancellation")

        try {
            HealthConnectBmiProjectionCoordinator(store).reconcile(
                recordTypes = setOf(weightType),
                heightCm = 170.0,
            ) {
                throw cancellation
            }
        } catch (caught: CancellationException) {
            assertSame(cancellation, caught)
        }

        assertEquals(old, store.applied)
        assertTrue(store.commits.isEmpty())
        var forcedAgain: Set<String>? = null
        val retry = HealthConnectBmiProjectionCoordinator(store, nowMs = { 456L }).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 170.0,
        ) {
            forcedAgain = it
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }

        assertTrue(retry is HealthConnectReconcileResult.Success)
        assertEquals(setOf(weightType), forcedAgain)
        assertEquals(desired, store.applied)
        assertEquals(2, store.projections.size)
        assertEquals(listOf(ProjectionCommit(170.0, desired, 456L)), store.commits)
    }

    @Test
    fun failedDeferredFingerprintCommitRemainsRetryable() = runTest {
        val store = Store(
            applied = HealthConnectBmiProjectionFingerprint.forHeight(178.0),
            failCommit = true,
        )

        val result = HealthConnectBmiProjectionCoordinator(store).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 170.0,
        ) {
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.RetryableFailure)
        assertEquals(
            HealthConnectBmiProjectionFingerprint.forHeight(178.0),
            store.applied,
        )
    }

    @Test
    fun failedLocalProjectionRemainsRetryableAndDoesNotStartProviderReconciliation() = runTest {
        val store = Store(failProjection = true)
        var providerRan = false
        val result = HealthConnectBmiProjectionCoordinator(store).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 178.0,
        ) {
            providerRan = true
            HealthConnectReconcileResult.Success(true, 1, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.RetryableFailure)
        assertFalse(providerRan)
        assertTrue(store.projections.isEmpty())
        assertNull(store.applied)
    }

    @Test
    fun fingerprintReadFailureDoesNotStartProviderReconciliation() = runTest {
        val store = Store(failRead = true)
        var ran = false

        val result = HealthConnectBmiProjectionCoordinator(store).reconcile(
            recordTypes = setOf(weightType),
            heightCm = 178.0,
        ) {
            ran = true
            HealthConnectReconcileResult.Success(false, 0, 0, 0)
        }

        assertTrue(result is HealthConnectReconcileResult.RetryableFailure)
        assertFalse(ran)
        assertTrue(store.projections.isEmpty())
    }

    @Test
    fun serializedGateReadsQueuedHeightOnlyAfterItOwnsTheLock() = runTest {
        val gate = HealthConnectReconciliationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondStarted = CompletableDeferred<Unit>()
        val observed = mutableListOf<Double>()
        var currentHeight = 178.0

        val first = launch {
            gate.run(currentHeightCm = { currentHeight }) { height ->
                observed += height
                firstStarted.complete(Unit)
                releaseFirst.await()
            }
        }
        firstStarted.await()
        val second = launch {
            gate.run(currentHeightCm = { currentHeight }) { height ->
                observed += height
                secondStarted.complete(Unit)
            }
        }

        currentHeight = 170.0
        assertFalse(secondStarted.isCompleted)
        releaseFirst.complete(Unit)
        first.join()
        second.join()

        assertEquals(listOf(178.0, 170.0), observed)
    }

    @Test
    fun serializedGatePreservesCancellationForAWaitingReconciliation() = runTest {
        val gate = HealthConnectReconciliationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var waitingEntered = false

        val first = launch {
            gate.run(currentHeightCm = { 178.0 }) {
                firstStarted.complete(Unit)
                releaseFirst.await()
            }
        }
        firstStarted.await()
        val waiting = launch {
            gate.run(currentHeightCm = { 170.0 }) {
                waitingEntered = true
            }
        }

        waiting.cancelAndJoin()
        releaseFirst.complete(Unit)
        first.join()
        assertFalse(waitingEntered)
    }

    @Test
    fun localProjectionCancellationIsRethrownUnchanged() = runTest {
        val cancellation = CancellationException("synthetic cancellation")
        val store = object : HealthConnectBmiProjectionStateStore {
            override suspend fun loadFingerprint(): String? = null

            override suspend fun reconcileLocalProjection(heightCm: Double): Int =
                throw cancellation

            override suspend fun commitProjectionAndFingerprint(
                heightCm: Double,
                fingerprint: String,
                updatedAtMs: Long,
            ): Int = error("not reached")
        }

        try {
            HealthConnectBmiProjectionCoordinator(store).reconcile(
                recordTypes = setOf(weightType),
                heightCm = 178.0,
            ) {
                HealthConnectReconcileResult.Success(true, 1, 0, 0)
            }
        } catch (caught: CancellationException) {
            assertSame(cancellation, caught)
            return@runTest
        }
        throw AssertionError("expected cancellation")
    }
}
