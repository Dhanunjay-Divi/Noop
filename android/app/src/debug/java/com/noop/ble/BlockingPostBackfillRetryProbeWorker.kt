package com.noop.ble

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation

/**
 * Debug-only probe used by instrumentation to verify a running worker can replace its own unique work.
 * It records lifecycle edges only in process and is never packaged in release builds.
 */
object PostBackfillRetryProbe {
    class Session internal constructor(
        val started: CompletableDeferred<Unit> = CompletableDeferred(),
        val release: CompletableDeferred<Unit> = CompletableDeferred(),
        val cancelled: CompletableDeferred<Unit> = CompletableDeferred(),
    )

    @Volatile
    private var activeSession = Session()

    fun reset(): Session {
        return Session().also { activeSession = it }
    }

    internal fun currentSession(): Session = activeSession
}

class BlockingPostBackfillRetryProbeWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val session = PostBackfillRetryProbe.currentSession()
        session.started.complete(Unit)
        try {
            session.release.await()
            val requestedBoundary = inputData.getLong(
                REQUESTED_BOUNDARY_KEY,
                Long.MIN_VALUE,
            )
            check(requestedBoundary != Long.MIN_VALUE)
            PostBackfillRetryCoordinator(
                stateStore = SharedPreferencesPostBackfillRetryStateStore(applicationContext),
                backend = WorkManagerPostBackfillRetryBackend(applicationContext),
            ).schedule(
                retryAtEpochMillis = requestedBoundary,
                nowEpochMillis = System.currentTimeMillis(),
            )
            awaitCancellation()
        } catch (cancelled: CancellationException) {
            session.cancelled.complete(Unit)
            throw cancelled
        }
    }

    companion object {
        const val REQUESTED_BOUNDARY_KEY = "requested_boundary"
    }
}
