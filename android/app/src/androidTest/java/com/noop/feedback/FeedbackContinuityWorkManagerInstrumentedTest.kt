package com.noop.feedback

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.await
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeedbackContinuityWorkManagerInstrumentedTest {
    private lateinit var context: Context
    private lateinit var workManager: WorkManager
    private lateinit var localId: String
    private lateinit var uniqueWorkName: String
    private lateinit var probeSession: FeedbackContinuityProbe.Session
    private lateinit var outbox: FeedbackOutbox
    private lateinit var staged: FeedbackRecord

    @Before
    fun prepareUniqueWork() {
        runBlocking {
            context = ApplicationProvider.getApplicationContext()
            workManager = WorkManager.getInstance(context)
            outbox = FeedbackOutbox.from(context)
            staged = outbox.stage(
                entries = feedbackEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
            localId = staged.localId
            uniqueWorkName = FeedbackScheduler.workName(localId)
            workManager.cancelUniqueWork(uniqueWorkName).await()
            probeSession = FeedbackContinuityProbe.reset()
        }
    }

    @After
    fun removeUniqueWork() {
        runBlocking {
            workManager.cancelUniqueWork(uniqueWorkName).await()
        }
        File(context.filesDir, "feedback/outbox/$localId").deleteRecursively()
    }

    @Test
    fun appendOrReplacePersistsProductionWorkerSuccessorAndPreservesOrder() =
        runBlocking {
            val predecessor =
                OneTimeWorkRequestBuilder<BlockingFeedbackContinuityProbeWorker>().build()
            workManager.enqueueUniqueWork(
                uniqueWorkName,
                ExistingWorkPolicy.REPLACE,
                predecessor,
            ).await()
            withTimeout(15_000L) {
                probeSession.started.await()
            }

            val firstGeneration = UUID.randomUUID().toString()
            outbox.prepareWorker(
                localId = localId,
                replace = false,
                generation = firstGeneration,
            )
            outbox.beginUpload(
                localId = localId,
                attempt = 1,
                expectedWorkerGeneration = firstGeneration,
            )
            outbox.bindIdentity(
                localId = localId,
                identitySubjectSha256 =
                    feedbackIdentitySubjectSha256("instrumentation-owner"),
                expectedWorkerGeneration = firstGeneration,
            )
            val schedule = outbox.scheduleContinuityRetry(
                localId = localId,
                lane = FeedbackReservationAttemptLane.DELIVERY,
                allowBoundIdentity = true,
                expectedWorkerGeneration = firstGeneration,
            )
            FeedbackScheduler.enqueueContinuityRetry(
                context = context,
                record = schedule.record,
                delayMillis = schedule.delayMillis,
            )

            val persistedBeforeRelease = FeedbackContinuityWorkInspector.snapshots(
                workManager,
                uniqueWorkName,
            )
            val successorBeforeRelease = persistedBeforeRelease.single {
                it.id != predecessor.id
            }
            assertEquals(
                WorkInfo.State.RUNNING,
                persistedBeforeRelease.single { it.id == predecessor.id }.state,
            )
            assertEquals(WorkInfo.State.BLOCKED, successorBeforeRelease.state)
            assertTrue(
                FeedbackUploadWorker::class.java.name in successorBeforeRelease.tags,
            )
            assertTrue(
                FeedbackScheduler.generationTag(
                    requireNotNull(schedule.record.workerGeneration),
                ) in successorBeforeRelease.tags,
            )

            probeSession.release.complete(Unit)

            val orderedStates = withTimeout(15_000L) {
                while (true) {
                    val work = FeedbackContinuityWorkInspector.snapshots(
                        workManager,
                        uniqueWorkName,
                    )
                    val predecessorState = work.single { it.id == predecessor.id }.state
                    val successorState = work.single {
                        it.id == successorBeforeRelease.id
                    }.state
                    if (
                        predecessorState == WorkInfo.State.SUCCEEDED &&
                        successorState == WorkInfo.State.ENQUEUED
                    ) {
                        return@withTimeout predecessorState to successorState
                    }
                    delay(50L)
                }
                error("unreachable")
            }
            assertEquals(WorkInfo.State.SUCCEEDED, orderedStates.first)
            assertEquals(WorkInfo.State.ENQUEUED, orderedStates.second)
            assertTrue(successorBeforeRelease.id != predecessor.id)
        }

    @Test
    fun replacementCancelsRunningPredecessorAndPersistsProductionWorker() =
        runBlocking {
            val predecessor =
                OneTimeWorkRequestBuilder<BlockingFeedbackContinuityProbeWorker>().build()
            workManager.enqueueUniqueWork(
                uniqueWorkName,
                ExistingWorkPolicy.REPLACE,
                predecessor,
            ).await()
            withTimeout(15_000L) {
                probeSession.started.await()
            }

            val replacementRecord = FeedbackScheduler.enqueue(
                context = context,
                record = staged,
                replace = true,
            )

            withTimeout(15_000L) {
                probeSession.cancelled.await()
            }
            val replacement = withTimeout(15_000L) {
                while (true) {
                    val work = FeedbackContinuityWorkInspector.snapshots(
                        workManager,
                        uniqueWorkName,
                    )
                    val successor = work.firstOrNull {
                        it.id != predecessor.id &&
                            FeedbackUploadWorker::class.java.name in it.tags
                    }
                    if (successor != null) return@withTimeout successor
                    delay(50L)
                }
                error("unreachable")
            }
            assertTrue(replacement.id != predecessor.id)
            assertTrue(
                FeedbackScheduler.generationTag(
                    requireNotNull(replacementRecord.workerGeneration),
                ) in replacement.tags,
            )
        }

    private fun feedbackEntries(): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP instrumentation report\n".toByteArray(),
        "meta.json" to """{"schema":1,"app_version":"9.2.1"}""".toByteArray(),
    )
}
