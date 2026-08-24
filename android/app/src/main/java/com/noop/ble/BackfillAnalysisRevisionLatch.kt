package com.noop.ble

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Source-bound dirty-work queue for post-backfill analysis.
 *
 * Each commit gets an immutable [Revision]. Commits for the same device coalesce while preserving the
 * newest revision, while commits for different devices remain distinct. A tokenized [WorkerClaim] prevents
 * a finishing worker from releasing a replacement that claimed the queue concurrently.
 */
internal class BackfillAnalysisRevisionLatch {
    data class Revision(val value: Long, val deviceId: String)
    data class WorkerClaim(val value: Long)
    data class Enqueue(val revision: Revision, val workerClaim: WorkerClaim?)
    data class Completion(val deviceStillPending: Boolean, val hasPendingWork: Boolean)

    private val lock = Any()
    private var nextRevision = 0L
    private var nextWorkerClaim = 0L
    private val pendingByDevice = linkedMapOf<String, Revision>()
    private var inFlight: Revision? = null
    private var owner: WorkerClaim? = null
    private var ownerStarted = false

    /** Records one commit and, when idle, reserves the sole worker-launch claim. */
    fun noteCommitAndClaimWorker(deviceId: String): Enqueue = synchronized(lock) {
        require(deviceId.isNotBlank()) { "post-backfill analysis requires a device id" }
        val revision = Revision(++nextRevision, deviceId)
        pendingByDevice[deviceId] = revision
        Enqueue(revision, claimPendingWorkerLocked())
    }

    /** Reclaims queued work after an earlier launch was aborted or a worker was cancelled. */
    fun claimPendingWorker(): WorkerClaim? = synchronized(lock) {
        claimPendingWorkerLocked()
    }

    /** Converts a reserved launch claim into the running worker lease. */
    fun workerStarted(claim: WorkerClaim): Boolean = synchronized(lock) {
        if (owner != claim || ownerStarted) return@synchronized false
        ownerStarted = true
        true
    }

    /**
     * Rolls back a claim whose coroutine body never started. Pending revisions are deliberately retained.
     */
    fun abortWorkerLaunch(claim: WorkerClaim): Boolean = synchronized(lock) {
        if (owner != claim || ownerStarted) return@synchronized pendingByDevice.isNotEmpty()
        owner = null
        pendingByDevice.isNotEmpty()
    }

    /**
     * Returns the next immutable revision, or atomically releases this worker when the queue is clean.
     * A commit after the clean release observes no owner and claims its own replacement worker.
     */
    fun nextRevisionOrRelease(claim: WorkerClaim): Revision? = synchronized(lock) {
        check(owner == claim && ownerStarted) { "post-backfill worker does not own this claim" }
        check(inFlight == null) { "post-backfill revision must complete before taking another" }

        val entry = pendingByDevice.entries.firstOrNull()
        if (entry == null) {
            owner = null
            ownerStarted = false
            return@synchronized null
        }

        pendingByDevice.remove(entry.key)
        entry.value.also { inFlight = it }
    }

    /** Completes exactly the revision currently owned by [claim]. */
    fun complete(claim: WorkerClaim, revision: Revision): Completion = synchronized(lock) {
        check(owner == claim && ownerStarted) { "post-backfill worker does not own this claim" }
        check(inFlight == revision) { "post-backfill worker completed a revision it does not own" }
        inFlight = null
        Completion(
            deviceStillPending = pendingByDevice.containsKey(revision.deviceId),
            hasPendingWork = pendingByDevice.isNotEmpty(),
        )
    }

    /**
     * Cancellation/unexpected-exit edge. The in-flight source is requeued unless a newer revision for that
     * source already exists. The claim token ensures an old worker cannot clear a replacement owner.
     */
    fun workerStopped(claim: WorkerClaim): Boolean = synchronized(lock) {
        if (owner != claim) return@synchronized pendingByDevice.isNotEmpty()
        inFlight?.let { interrupted ->
            val newer = pendingByDevice[interrupted.deviceId]
            if (newer == null || newer.value < interrupted.value) {
                pendingByDevice[interrupted.deviceId] = interrupted
            }
        }
        inFlight = null
        owner = null
        ownerStarted = false
        pendingByDevice.isNotEmpty()
    }

    internal fun pendingDeviceIds(): Set<String> = synchronized(lock) {
        buildSet {
            inFlight?.let { add(it.deviceId) }
            addAll(pendingByDevice.keys)
        }
    }

    internal fun hasWorkerClaim(): Boolean = synchronized(lock) { owner != null }

    private fun claimPendingWorkerLocked(): WorkerClaim? {
        if (owner != null || pendingByDevice.isEmpty()) return null
        return WorkerClaim(++nextWorkerClaim).also {
            owner = it
            ownerStarted = false
        }
    }
}

/**
 * Runs one source's fingerprint-gated pass. The success-only callbacks are structurally unreachable when
 * fingerprinting or analysis throws, and the watermark is persisted last as the pass's commit record.
 */
internal suspend fun runFingerprintGatedBackfillAnalysis(
    readFingerprint: suspend () -> String,
    readWatermark: () -> String?,
    analyze: suspend () -> Unit,
    afterAnalysis: suspend () -> Unit,
    persistWatermark: (String) -> Unit,
    onUpToDate: () -> Unit = {},
) {
    val fingerprint = readFingerprint()
    if (fingerprint == readWatermark()) {
        onUpToDate()
        return
    }
    analyze()
    afterAnalysis()
    persistWatermark(fingerprint)
}

/**
 * Coroutine owner for [BackfillAnalysisRevisionLatch].
 *
 * The launch is two-phase: a claim is reserved first, then [CoroutineStart.UNDISPATCHED] proves the body
 * entered and installed its `finally` before launch returns. If the scope was already cancelled and the body
 * never enters, [BackfillAnalysisRevisionLatch.abortWorkerLaunch] returns the claim without dropping work.
 */
internal class BackfillAnalysisWorker(
    private val scope: CoroutineScope,
    private val debounceMillis: Long,
    private val retryDelayMillis: Long,
    private val maxRetryDelayMillis: Long = 60_000L,
    private val processRevision: suspend (BackfillAnalysisRevisionLatch.Revision) -> Unit,
    private val markDurablyDirty: (String) -> Unit = {},
    private val clearDurablyDirty: (String) -> Unit = {},
    private val onFailure: (String, Throwable) -> Unit = { _, _ -> },
    private val latch: BackfillAnalysisRevisionLatch = BackfillAnalysisRevisionLatch(),
) {
    private val coordinationLock = Any()

    init {
        require(debounceMillis >= 0L)
        require(retryDelayMillis > 0L)
        require(maxRetryDelayMillis >= retryDelayMillis)
    }

    /** Durably records a committed source before making its revision visible to a worker. */
    fun noteCommit(deviceId: String): BackfillAnalysisRevisionLatch.Revision {
        var persistenceFailure: Throwable? = null
        val enqueue = synchronized(coordinationLock) {
            try {
                markDurablyDirty(deviceId)
            } catch (t: Throwable) {
                persistenceFailure = t
            }
            latch.noteCommitAndClaimWorker(deviceId)
        }
        persistenceFailure?.let { reportFailure(deviceId, it) }
        enqueue.workerClaim?.let(::launchClaim)
        return enqueue.revision
    }

    /**
     * Re-enqueues durable sources after process/service recreation. The active source should be supplied
     * last so the shared persisted fingerprint finishes on the source the UI currently reads.
     */
    fun resume(deviceIds: Collection<String>): List<BackfillAnalysisRevisionLatch.Revision> {
        val revisions = mutableListOf<BackfillAnalysisRevisionLatch.Revision>()
        var claim: BackfillAnalysisRevisionLatch.WorkerClaim? = null
        synchronized(coordinationLock) {
            deviceIds.asSequence().filter { it.isNotBlank() }.distinct().forEach { deviceId ->
                val enqueue = latch.noteCommitAndClaimWorker(deviceId)
                revisions += enqueue.revision
                if (claim == null) claim = enqueue.workerClaim
            }
            if (claim == null) claim = latch.claimPendingWorker()
        }
        claim?.let(::launchClaim)
        return revisions
    }

    internal fun pendingDeviceIds(): Set<String> = latch.pendingDeviceIds()

    private fun launchClaim(claim: BackfillAnalysisRevisionLatch.WorkerClaim) {
        val entered = AtomicBoolean(false)
        var launchFailure: Throwable? = null
        try {
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                entered.set(true)
                if (!latch.workerStarted(claim)) return@launch
                workerEntry(claim)
            }
        } catch (t: Throwable) {
            launchFailure = t
        }

        if (!entered.get()) {
            val stillPending = synchronized(coordinationLock) {
                latch.abortWorkerLaunch(claim)
            }
            reportFailure(
                "<worker>",
                launchFailure ?: CancellationException("post-backfill worker scope was not launchable"),
            )
            if (stillPending && scope.coroutineContext.isActive) requestPendingWorker()
        }
    }

    private suspend fun workerEntry(claim: BackfillAnalysisRevisionLatch.WorkerClaim) {
        try {
            runWorker(claim)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (t: Throwable) {
            reportFailure("<worker>", t)
        } finally {
            synchronized(coordinationLock) {
                latch.workerStopped(claim)
            }
        }
    }

    private suspend fun runWorker(claim: BackfillAnalysisRevisionLatch.WorkerClaim) {
        var shouldDebounce = true
        while (true) {
            currentCoroutineContext().ensureActive()
            if (shouldDebounce && debounceMillis > 0L) delay(debounceMillis)

            val revision = latch.nextRevisionOrRelease(claim) ?: return
            var attempt = 0
            while (true) {
                try {
                    processRevision(revision)
                    break
                } catch (cancelled: CancellationException) {
                    // A timeout or dependency may use CancellationException without cancelling this
                    // worker. Retry that failure here; a real owner shutdown remains cancelled and the
                    // outer finally requeues the immutable revision for the next service instance.
                    currentCoroutineContext().ensureActive()
                    attempt += 1
                    reportFailure(revision.deviceId, cancelled)
                    delay(retryDelayFor(attempt))
                } catch (t: Throwable) {
                    attempt += 1
                    reportFailure(revision.deviceId, t)
                    delay(retryDelayFor(attempt))
                }
            }

            var clearFailure: Throwable? = null
            val completion = synchronized(coordinationLock) {
                val completed = latch.complete(claim, revision)
                if (!completed.deviceStillPending) {
                    try {
                        clearDurablyDirty(revision.deviceId)
                    } catch (t: Throwable) {
                        clearFailure = t
                    }
                }
                completed
            }
            clearFailure?.let { reportFailure(revision.deviceId, it) }
            shouldDebounce = completion.hasPendingWork
        }
    }

    private fun requestPendingWorker() {
        val replacement = synchronized(coordinationLock) {
            latch.claimPendingWorker()
        }
        replacement?.let(::launchClaim)
    }

    private fun retryDelayFor(attempt: Int): Long {
        val multiplier = 1L shl (attempt - 1).coerceIn(0, 5)
        return if (retryDelayMillis > maxRetryDelayMillis / multiplier) {
            maxRetryDelayMillis
        } else {
            minOf(retryDelayMillis * multiplier, maxRetryDelayMillis)
        }
    }

    private fun reportFailure(deviceId: String, failure: Throwable) {
        try {
            onFailure(deviceId, failure)
        } catch (_: Throwable) {
            // Diagnostics must never become another uncaught worker failure.
        }
    }
}
