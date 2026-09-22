package com.noop.feedback

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.await
import androidx.work.workDataOf
import java.io.File
import java.time.Instant
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    private lateinit var workerExecutionProbe: FeedbackWorkerExecutionProbe
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
            workerExecutionProbe = FeedbackWorkerExecutionProbe()
            FeedbackWorkerExecutionObserver.install(workerExecutionProbe)
        }
    }

    @After
    fun removeUniqueWork() {
        try {
            runBlocking {
                workManager.cancelUniqueWork(uniqueWorkName).await()
                probeSession.release.complete(Unit)
                probeSession.unwindRelease.complete(Unit)
                awaitUniqueWorkQuiescence()
            }
            val recordDirectory = File(context.filesDir, "feedback/outbox/$localId")
            assertTrue(
                "Feedback continuity test record must be removed after workers quiesce",
                recordDirectory.deleteRecursively(),
            )
            assertTrue(
                "Feedback continuity test record must not leak into later test classes",
                !recordDirectory.exists(),
            )
        } finally {
            FeedbackWorkerExecutionObserver.clear(workerExecutionProbe)
        }
    }

    @Test
    fun canceledWorkInfoDoesNotProveCoroutineHasUnwound() = runBlocking {
        probeSession = FeedbackContinuityProbe.reset(holdUnwind = true)
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

        workManager.cancelUniqueWork(uniqueWorkName).await()
        val terminalState = withTimeout(15_000L) {
            while (true) {
                val state = FeedbackContinuityWorkInspector.snapshots(
                    workManager,
                    uniqueWorkName,
                ).firstOrNull { it.id == predecessor.id }?.state
                if (state?.isFinished == true) return@withTimeout state
                delay(50L)
            }
            error("unreachable")
        }
        assertEquals(WorkInfo.State.CANCELLED, terminalState)
        assertFalse(probeSession.unwound.isCompleted)

        val quiescence = async {
            awaitUniqueWorkQuiescence()
        }
        delay(200L)
        assertFalse(quiescence.isCompleted)

        probeSession.unwindRelease.complete(Unit)
        quiescence.await()
        assertTrue(probeSession.unwound.isCompleted)
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

    @Test
    fun lateAcceptedWorkerFromTimedOutGenerationCannotReviveFailedRecord() =
        runBlocking {
            val timedOutGeneration = UUID.randomUUID().toString()
            val prepared = outbox.prepareWorker(
                localId = localId,
                replace = false,
                generation = timedOutGeneration,
            )
            val failed = outbox.markFailed(
                localId = localId,
                failure = FeedbackFailureCategory.UNKNOWN,
                expectedWorkerGeneration = timedOutGeneration,
            )
            assertEquals(FeedbackState.FAILED, failed.state)
            assertEquals(null, failed.workerGeneration)

            val lateAccepted =
                OneTimeWorkRequestBuilder<FeedbackUploadWorker>()
                    .setInputData(
                        workDataOf(
                            FeedbackScheduler.INPUT_LOCAL_ID to localId,
                            FeedbackScheduler.INPUT_WORKER_GENERATION to
                                requireNotNull(prepared.workerGeneration),
                        ),
                    )
                    .addTag(
                        FeedbackScheduler.generationTag(
                            requireNotNull(prepared.workerGeneration),
                        ),
                    )
                    .build()
            workManager.enqueueUniqueWork(
                uniqueWorkName,
                ExistingWorkPolicy.REPLACE,
                lateAccepted,
            ).await()

            val terminalState = withTimeout(15_000L) {
                while (true) {
                    val state = FeedbackContinuityWorkInspector.snapshots(
                        workManager,
                        uniqueWorkName,
                    ).firstOrNull { it.id == lateAccepted.id }?.state
                    if (state?.isFinished == true) return@withTimeout state
                    delay(50L)
                }
                error("unreachable")
            }
            assertEquals(WorkInfo.State.SUCCEEDED, terminalState)
            val persisted = requireNotNull(outbox.load(localId))
            assertEquals(FeedbackState.FAILED, persisted.state)
            assertEquals(null, persisted.workerGeneration)
        }

    @Test
    fun completedWorkerBeforeTimeoutFailurePersistenceKeepsTerminalRecord() =
        runBlocking {
            val timedOutGeneration = UUID.randomUUID().toString()
            val prepared = outbox.prepareWorker(
                localId = localId,
                replace = false,
                generation = timedOutGeneration,
            )
            outbox.beginUpload(
                localId = localId,
                attempt = 1,
                expectedWorkerGeneration = timedOutGeneration,
            )
            outbox.bindIdentity(
                localId = localId,
                identitySubjectSha256 = "a".repeat(64),
                expectedWorkerGeneration = timedOutGeneration,
            )
            outbox.saveReservation(
                localId = localId,
                serverReportId = UUID.randomUUID().toString(),
                serverReportToken = "a".repeat(43),
                expectedWorkerGeneration = timedOutGeneration,
            )
            val completed = outbox.commitCompletion(
                localId = localId,
                receipt = "NF-ABCDEFGHIJKLMNOP",
                retainedUntil = Instant.now().plusSeconds(86_400L).toString(),
                expectedWorkerGeneration = timedOutGeneration,
            )
            assertTrue(completed is FeedbackCompletionCommit.Sent)

            val resolution = FeedbackSchedulingFailureResolver.resolve(
                persistFailure = {
                    outbox.markFailed(
                        localId = localId,
                        failure = FeedbackFailureCategory.UNKNOWN,
                        expectedWorkerGeneration =
                            requireNotNull(prepared.workerGeneration),
                    )
                },
                loadCurrent = {
                    outbox.loadForProgress(localId)
                },
            )

            assertTrue(
                resolution is FeedbackSchedulingFailureResolution.CurrentRecord,
            )
            assertEquals(FeedbackState.SENT, resolution.record.state)
            assertEquals("NF-ABCDEFGHIJKLMNOP", resolution.record.receipt)
            assertEquals(null, resolution.record.workerGeneration)
        }

    @Test
    fun staleSchedulingFailureCannotOverwriteNewerWorkerGeneration() =
        runBlocking {
            val failedGeneration = UUID.randomUUID().toString()
            val failedRecord = outbox.prepareWorker(
                localId = localId,
                replace = false,
                generation = failedGeneration,
            )
            val newerGeneration = UUID.randomUUID().toString()
            outbox.prepareWorker(
                localId = localId,
                replace = true,
                generation = newerGeneration,
            )

            val resolution = FeedbackSchedulingFailureResolver.resolve(
                persistFailure = {
                    outbox.markFailed(
                        localId = localId,
                        failure = FeedbackFailureCategory.UNKNOWN,
                        expectedWorkerGeneration =
                            requireNotNull(failedRecord.workerGeneration),
                    )
                },
                loadCurrent = {
                    outbox.loadForProgress(localId)
                },
            )

            assertTrue(
                resolution is FeedbackSchedulingFailureResolution.CurrentRecord,
            )
            assertEquals(FeedbackState.QUEUED, resolution.record.state)
            assertEquals(newerGeneration, resolution.record.workerGeneration)
            val persisted = requireNotNull(outbox.loadForProgress(localId))
            assertEquals(FeedbackState.QUEUED, persisted.state)
            assertEquals(newerGeneration, persisted.workerGeneration)
        }

    private fun feedbackEntries(): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP instrumentation report\n".toByteArray(),
        "meta.json" to """{"schema":1,"app_version":"9.2.1"}""".toByteArray(),
    )

    private suspend fun awaitUniqueWorkQuiescence() {
        withTimeout(15_000L) {
            while (true) {
                val beforeWork = FeedbackContinuityWorkInspector.snapshots(
                    workManager,
                    uniqueWorkName,
                )
                val beforeExecution = workerExecutionProbe.snapshot()
                val probeUnwound =
                    !probeSession.started.isCompleted || probeSession.unwound.isCompleted
                if (
                    beforeWork.all { it.state.isFinished } &&
                    beforeExecution.allStartedExited &&
                    probeUnwound
                ) {
                    delay(100L)
                    val afterWork = FeedbackContinuityWorkInspector.snapshots(
                        workManager,
                        uniqueWorkName,
                    )
                    val afterExecution = workerExecutionProbe.snapshot()
                    val noNewWork =
                        afterWork.mapTo(mutableSetOf()) { it.id } -
                            beforeWork.mapTo(mutableSetOf()) { it.id }
                    val noNewExecutions =
                        afterExecution.started - beforeExecution.started
                    if (
                        afterWork.all { it.state.isFinished } &&
                        afterExecution.allStartedExited &&
                        noNewWork.isEmpty() &&
                        noNewExecutions.isEmpty() &&
                        (
                            !probeSession.started.isCompleted ||
                                probeSession.unwound.isCompleted
                            )
                    ) {
                        return@withTimeout
                    }
                }
                delay(50L)
            }
        }
    }

    private class FeedbackWorkerExecutionProbe : FeedbackWorkerExecutionListener {
        private val started =
            Collections.synchronizedSet(mutableSetOf<UUID>())
        private val exited =
            Collections.synchronizedSet(mutableSetOf<UUID>())

        override fun onExecution(
            workId: UUID,
            phase: FeedbackWorkerExecutionPhase,
        ) {
            when (phase) {
                FeedbackWorkerExecutionPhase.STARTED -> started += workId
                FeedbackWorkerExecutionPhase.EXITED -> exited += workId
            }
        }

        fun snapshot(): FeedbackWorkerExecutionSnapshot = synchronized(started) {
            synchronized(exited) {
                FeedbackWorkerExecutionSnapshot(
                    started = started.toSet(),
                    exited = exited.toSet(),
                )
            }
        }
    }

    private data class FeedbackWorkerExecutionSnapshot(
        val started: Set<UUID>,
        val exited: Set<UUID>,
    ) {
        val allStartedExited: Boolean
            get() = exited.containsAll(started)
    }
}
