package com.noop.ble

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal sealed interface BackfillAnalysisProcessResult {
    data object Completed : BackfillAnalysisProcessResult

    data object RetryRequired : BackfillAnalysisProcessResult

    data class Deferred(
        val retryAtEpochMillis: Long,
        val retryScheduled: Boolean = false,
    ) : BackfillAnalysisProcessResult
}

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
     * Releases a revision that remains durably dirty outside this in-memory queue. A later service-level
     * retry calls [noteCommitAndClaimWorker] again after its evaluable boundary; the source must not be
     * requeued here or this sole worker would immediately spin on the same deferred claim.
     */
    fun defer(claim: WorkerClaim, revision: Revision): Boolean = synchronized(lock) {
        check(owner == claim && ownerStarted) { "post-backfill worker does not own this claim" }
        check(inFlight == revision) { "post-backfill worker deferred a revision it does not own" }
        inFlight = null
        pendingByDevice.isNotEmpty()
    }

    /** Returns the current revision to the durable in-memory queue before the owner releases it. */
    fun requeue(claim: WorkerClaim, revision: Revision): Boolean = synchronized(lock) {
        check(owner == claim && ownerStarted) { "post-backfill worker does not own this claim" }
        check(inFlight == revision) { "post-backfill worker requeued a revision it does not own" }
        val newer = pendingByDevice[revision.deviceId]
        if (newer == null || newer.value < revision.value) {
            pendingByDevice[revision.deviceId] = revision
        }
        inFlight = null
        pendingByDevice.isNotEmpty()
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

    internal fun hasNewerPendingRevision(revision: Revision): Boolean = synchronized(lock) {
        val newer = pendingByDevice[revision.deviceId]
        newer != null && newer.value > revision.value
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
    private val processRevision:
        suspend (BackfillAnalysisRevisionLatch.Revision) -> BackfillAnalysisProcessResult,
    private val scheduleDeferredRetry: suspend (Long) -> Boolean = { false },
    private val markDurablyDirty: (String) -> Unit = {},
    private val clearDurablyDirty: (String) -> Unit = {},
    private val onFailure: (String, Throwable) -> Unit = { _, _ -> },
    private val latch: BackfillAnalysisRevisionLatch = BackfillAnalysisRevisionLatch(),
) {
    private data class CompletionWaiter(
        val revisionValue: Long,
        val result: CompletableDeferred<BackfillAnalysisProcessResult>,
    )

    private val coordinationLock = Any()
    private val completionWaiters = mutableMapOf<String, MutableList<CompletionWaiter>>()
    private val resumeMutex = Mutex()
    private var applicationWorkerControl: CompletableJob? = null
    private var callerTakeoverActive = false
    private var suppressedApplicationClaim: BackfillAnalysisRevisionLatch.WorkerClaim? = null

    init {
        require(debounceMillis >= 0L)
        require(retryDelayMillis > 0L)
        require(maxRetryDelayMillis >= retryDelayMillis)
    }

    /** Durably records a committed source before making its revision visible to a worker. */
    fun noteCommit(deviceId: String): BackfillAnalysisRevisionLatch.Revision {
        var persistenceFailure: Throwable? = null
        var claimToLaunch: BackfillAnalysisRevisionLatch.WorkerClaim? = null
        val enqueue = synchronized(coordinationLock) {
            try {
                markDurablyDirty(deviceId)
            } catch (t: Throwable) {
                persistenceFailure = t
            }
            latch.noteCommitAndClaimWorker(deviceId).also {
                claimToLaunch = reserveApplicationClaimLocked(it.workerClaim)
            }
        }
        persistenceFailure?.let { reportFailure(deviceId, it) }
        claimToLaunch?.let(::launchClaim)
        return enqueue.revision
    }

    /**
     * Re-enqueues durable sources after process/service recreation. The active source should be supplied
     * last to preserve deterministic active-source ordering; each source's analysis generation is
     * acknowledged independently by the processor.
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
            claim = reserveApplicationClaimLocked(claim)
        }
        claim?.let(::launchClaim)
        return revisions
    }

    /**
     * Re-enqueues durable sources and waits until each submitted revision either completes or is
     * durably rearmed for a later evaluable boundary. WorkManager uses this so it cannot report success
     * while the application-owned worker is still only queued in another coroutine.
     */
    suspend fun resumeAndAwait(
        deviceIds: Collection<String>,
    ): List<BackfillAnalysisProcessResult> = resumeMutex.withLock {
        val registered = mutableListOf<Pair<String, CompletionWaiter>>()
        var claim: BackfillAnalysisRevisionLatch.WorkerClaim? = null
        val applicationWorker = synchronized(coordinationLock) {
            callerTakeoverActive = true
            deviceIds.asSequence().filter { it.isNotBlank() }.distinct().forEach { deviceId ->
                val enqueue = latch.noteCommitAndClaimWorker(deviceId)
                val waiter = CompletionWaiter(
                    revisionValue = enqueue.revision.value,
                    result = CompletableDeferred(),
                )
                completionWaiters.getOrPut(deviceId) { mutableListOf() }.add(waiter)
                registered += deviceId to waiter
                if (claim == null) claim = enqueue.workerClaim
            }
            applicationWorkerControl
        }
        var resumeApplicationWorker = false
        try {
            applicationWorker?.cancelAndJoin()
            synchronized(coordinationLock) {
                if (claim == null) {
                    claim = suppressedApplicationClaim
                    suppressedApplicationClaim = null
                }
                if (claim == null) claim = latch.claimPendingWorker()
            }
            claim?.let { runClaimInCaller(it) }
            registered.map { it.second.result }.awaitAll().also { outcomes ->
                resumeApplicationWorker = outcomes.none {
                    it is BackfillAnalysisProcessResult.RetryRequired
                }
            }
        } finally {
            val replacement = synchronized(coordinationLock) {
                registered.forEach { (deviceId, waiter) ->
                    completionWaiters[deviceId]?.let { waiters ->
                        waiters.remove(waiter)
                        if (waiters.isEmpty()) completionWaiters.remove(deviceId)
                    }
                }
                callerTakeoverActive = false
                val reserved = suppressedApplicationClaim
                suppressedApplicationClaim = null
                if (resumeApplicationWorker) {
                    reserved ?: latch.claimPendingWorker()
                } else {
                    reserved?.let(latch::abortWorkerLaunch)
                    null
                }
            }
            replacement?.let(::launchClaim)
        }
    }

    internal fun pendingDeviceIds(): Set<String> = latch.pendingDeviceIds()
    internal fun hasWorkerClaim(): Boolean = latch.hasWorkerClaim()

    private fun launchClaim(claim: BackfillAnalysisRevisionLatch.WorkerClaim) {
        val control = Job(scope.coroutineContext[Job])
        val shouldLaunch = synchronized(coordinationLock) {
            if (callerTakeoverActive) {
                suppressedApplicationClaim = claim
                false
            } else {
                applicationWorkerControl = control
                true
            }
        }
        if (!shouldLaunch) {
            control.complete()
            return
        }

        val entered = AtomicBoolean(false)
        var launchFailure: Throwable? = null
        try {
            CoroutineScope(scope.coroutineContext + control).launch(
                start = CoroutineStart.UNDISPATCHED,
            ) {
                try {
                    entered.set(true)
                    if (!latch.workerStarted(claim)) return@launch
                    workerEntry(claim, callerOwned = false)
                } finally {
                    synchronized(coordinationLock) {
                        if (applicationWorkerControl === control) {
                            applicationWorkerControl = null
                        }
                    }
                    control.complete()
                }
            }
        } catch (t: Throwable) {
            launchFailure = t
        }

        if (!entered.get()) {
            val stillPending = synchronized(coordinationLock) {
                if (applicationWorkerControl === control) {
                    applicationWorkerControl = null
                }
                latch.abortWorkerLaunch(claim)
            }
            control.complete()
            reportFailure(
                "<worker>",
                launchFailure ?: CancellationException("post-backfill worker scope was not launchable"),
            )
            if (stillPending && scope.coroutineContext.isActive) requestPendingWorker()
        }
    }

    private suspend fun runClaimInCaller(claim: BackfillAnalysisRevisionLatch.WorkerClaim) {
        var started = false
        try {
            currentCoroutineContext().ensureActive()
            started = latch.workerStarted(claim)
            if (started) workerEntry(claim, callerOwned = true)
        } finally {
            if (!started) {
                synchronized(coordinationLock) {
                    latch.abortWorkerLaunch(claim)
                }
            }
        }
    }

    private suspend fun workerEntry(
        claim: BackfillAnalysisRevisionLatch.WorkerClaim,
        callerOwned: Boolean,
    ) {
        try {
            runWorker(claim, callerOwned)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (t: Throwable) {
            reportFailure("<worker>", t)
            if (callerOwned) {
                val waiters = synchronized(coordinationLock) {
                    takeAllCompletionWaitersLocked()
                }
                waiters.forEach { it.complete(BackfillAnalysisProcessResult.RetryRequired) }
            }
        } finally {
            synchronized(coordinationLock) {
                latch.workerStopped(claim)
            }
        }
    }

    private suspend fun runWorker(
        claim: BackfillAnalysisRevisionLatch.WorkerClaim,
        callerOwned: Boolean,
    ) {
        var shouldDebounce = true
        workerLoop@ while (true) {
            currentCoroutineContext().ensureActive()
            if (shouldDebounce && debounceMillis > 0L) delay(debounceMillis)

            val revision = latch.nextRevisionOrRelease(claim) ?: return
            var attempt = 0
            lateinit var processResult: BackfillAnalysisProcessResult
            while (true) {
                try {
                    processResult = processRevision(revision)
                    break
                } catch (cancelled: CancellationException) {
                    // A timeout or dependency may use CancellationException without cancelling this
                    // worker. Retry that failure here; a real owner shutdown remains cancelled and the
                    // outer finally requeues the immutable revision for the next service instance.
                    currentCoroutineContext().ensureActive()
                    attempt += 1
                    reportFailure(revision.deviceId, cancelled)
                    if (callerOwned) {
                        completeCallerRetry(claim, revision)
                        return
                    }
                    delay(retryDelayFor(attempt))
                } catch (t: Throwable) {
                    attempt += 1
                    reportFailure(revision.deviceId, t)
                    if (callerOwned) {
                        completeCallerRetry(claim, revision)
                        return
                    }
                    delay(retryDelayFor(attempt))
                }
            }

            if (processResult is BackfillAnalysisProcessResult.Deferred) {
                val deferred = processResult
                var scheduleAttempt = 0
                while (true) {
                    val retryScheduled = try {
                        scheduleDeferredRetry(deferred.retryAtEpochMillis)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        false
                    }
                    if (!retryScheduled) {
                        if (callerOwned) {
                            completeCallerRetry(claim, revision)
                            return
                        }
                        scheduleAttempt += 1
                        delay(retryDelayFor(scheduleAttempt))
                        continue
                    }

                    val completedResult = deferred.copy(retryScheduled = true)
                    val (hasPendingWork, waiters) = synchronized(coordinationLock) {
                        latch.defer(claim, revision) to takeCompletionWaitersLocked(revision)
                    }
                    waiters.forEach { it.complete(completedResult) }
                    shouldDebounce = hasPendingWork
                    continue@workerLoop
                }
            }

            var clearAttempt = 0
            while (true) {
                var clearFailure: Throwable? = null
                val completed = synchronized(coordinationLock) {
                    if (!latch.hasNewerPendingRevision(revision)) {
                        try {
                            clearDurablyDirty(revision.deviceId)
                        } catch (t: Throwable) {
                            clearFailure = t
                        }
                    }
                    if (clearFailure == null) {
                        latch.complete(claim, revision) to takeCompletionWaitersLocked(revision)
                    } else {
                        null
                    }
                }
                val failure = clearFailure
                if (failure != null) {
                    reportFailure(revision.deviceId, failure)
                    if (callerOwned) {
                        completeCallerRetry(claim, revision)
                        return
                    }
                    clearAttempt += 1
                    delay(retryDelayFor(clearAttempt))
                    continue
                }
                val (completion, waiters) = checkNotNull(completed)
                waiters.forEach { it.complete(BackfillAnalysisProcessResult.Completed) }
                shouldDebounce = completion.hasPendingWork
                break
            }
        }
    }

    private fun completeCallerRetry(
        claim: BackfillAnalysisRevisionLatch.WorkerClaim,
        revision: BackfillAnalysisRevisionLatch.Revision,
    ) {
        val waiters = synchronized(coordinationLock) {
            latch.requeue(claim, revision)
            takeAllCompletionWaitersLocked()
        }
        waiters.forEach { it.complete(BackfillAnalysisProcessResult.RetryRequired) }
    }

    private fun takeCompletionWaitersLocked(
        revision: BackfillAnalysisRevisionLatch.Revision,
    ): List<CompletableDeferred<BackfillAnalysisProcessResult>> {
        val waiters = completionWaiters[revision.deviceId] ?: return emptyList()
        val completed = waiters
            .filter { it.revisionValue <= revision.value }
            .map(CompletionWaiter::result)
        waiters.removeAll { it.revisionValue <= revision.value }
        if (waiters.isEmpty()) completionWaiters.remove(revision.deviceId)
        return completed
    }

    private fun takeAllCompletionWaitersLocked():
        List<CompletableDeferred<BackfillAnalysisProcessResult>> {
        val waiters = completionWaiters.values
            .asSequence()
            .flatten()
            .map(CompletionWaiter::result)
            .toList()
        completionWaiters.clear()
        return waiters
    }

    private fun requestPendingWorker() {
        val replacement = synchronized(coordinationLock) {
            reserveApplicationClaimLocked(latch.claimPendingWorker())
        }
        replacement?.let(::launchClaim)
    }

    private fun reserveApplicationClaimLocked(
        claim: BackfillAnalysisRevisionLatch.WorkerClaim?,
    ): BackfillAnalysisRevisionLatch.WorkerClaim? {
        if (claim == null) return null
        if (!callerTakeoverActive) return claim
        suppressedApplicationClaim = claim
        return null
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
