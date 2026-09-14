package com.noop.feedback

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.first

/**
 * Debug-only predecessor used to inspect ordering in the production feedback scheduler graph.
 * It holds no report payload, never executes the outbox, and is not packaged in release builds.
 */
object FeedbackContinuityProbe {
    class Session internal constructor(
        val started: CompletableDeferred<Unit> = CompletableDeferred(),
        val release: CompletableDeferred<Unit> = CompletableDeferred(),
        val cancelled: CompletableDeferred<Unit> = CompletableDeferred(),
    )

    @Volatile
    private var activeSession = Session()

    fun reset(): Session = Session().also { activeSession = it }

    internal fun currentSession(): Session = activeSession
}

data class FeedbackContinuityWorkSnapshot(
    val id: UUID,
    val state: WorkInfo.State,
    val tags: Set<String>,
)

object FeedbackContinuityWorkInspector {
    suspend fun snapshots(
        workManager: WorkManager,
        uniqueWorkName: String,
    ): List<FeedbackContinuityWorkSnapshot> =
        workManager.getWorkInfosForUniqueWorkFlow(uniqueWorkName).first().map {
            FeedbackContinuityWorkSnapshot(
                id = it.id,
                state = it.state,
                tags = it.tags,
            )
        }
}

class BlockingFeedbackContinuityProbeWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val session = FeedbackContinuityProbe.currentSession()
        session.started.complete(Unit)
        return try {
            session.release.await()
            Result.success()
        } catch (cancelled: CancellationException) {
            session.cancelled.complete(Unit)
            throw cancelled
        }
    }
}
