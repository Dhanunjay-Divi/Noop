package com.noop.ble

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.await
import androidx.work.workDataOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PostBackfillRetryWorkManagerInstrumentedTest {
    private lateinit var context: Context
    private lateinit var workManager: WorkManager
    private lateinit var probeSession: PostBackfillRetryProbe.Session

    @Before
    fun clearProductionRetryState() {
        runBlocking {
            context = ApplicationProvider.getApplicationContext()
            workManager = WorkManager.getInstance(context)
            workManager.cancelUniqueWork(PostBackfillAnalysisRetryPolicy.WORK_NAME).await()
            context.getSharedPreferences(
                SharedPreferencesPostBackfillRetryStateStore.PREFS_NAME,
                Context.MODE_PRIVATE,
            ).edit().clear().commit()
            probeSession = PostBackfillRetryProbe.reset()
        }
    }

    @After
    fun removeProductionRetryWork() {
        runBlocking {
            workManager.cancelUniqueWork(PostBackfillAnalysisRetryPolicy.WORK_NAME).await()
            context.getSharedPreferences(
                SharedPreferencesPostBackfillRetryStateStore.PREFS_NAME,
                Context.MODE_PRIVATE,
            ).edit().clear().commit()
        }
    }

    @Test
    fun replacementRecoveryAndCorruptSelectorUseRealWorkManagerState() = runBlocking {
        val now = System.currentTimeMillis()
        val firstBoundary = now + 86_400_000L
        val earlierBoundary = now + 43_200_000L
        val store = SharedPreferencesPostBackfillRetryStateStore(context)
        val backend = WorkManagerPostBackfillRetryBackend(context)
        val firstCoordinator = PostBackfillRetryCoordinator(store, backend)

        assertEquals(
            PostBackfillRetryScheduleOutcome.SCHEDULED,
            firstCoordinator.schedule(firstBoundary, now),
        )
        val first = (store.load() as PostBackfillRetryStateRead.Present).value
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.state(first.workId))

        val recreatedCoordinator = PostBackfillRetryCoordinator(
            SharedPreferencesPostBackfillRetryStateStore(context),
            WorkManagerPostBackfillRetryBackend(context),
        )
        assertEquals(
            PostBackfillRetryScheduleOutcome.RESCHEDULED,
            recreatedCoordinator.schedule(earlierBoundary, now),
        )
        val replacement =
            (SharedPreferencesPostBackfillRetryStateStore(context).load()
                as PostBackfillRetryStateRead.Present).value
        assertEquals(earlierBoundary, replacement.retryAtEpochMillis)
        assertTrue(
            backend.state(first.workId) in setOf(
                PostBackfillRetryWorkState.FINISHED,
                PostBackfillRetryWorkState.MISSING,
            ),
        )
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.state(replacement.workId))

        assertTrue(SharedPreferencesPostBackfillRetryStateStore(context).clear())
        val recoveredCoordinator = PostBackfillRetryCoordinator(
            SharedPreferencesPostBackfillRetryStateStore(context),
            WorkManagerPostBackfillRetryBackend(context),
        )
        assertEquals(
            PostBackfillRetryExecutionDecision.RECOVERED,
            recoveredCoordinator.beginExecution(
                workId = replacement.workId,
                retryAtEpochMillis = replacement.retryAtEpochMillis,
                protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
            ),
        )

        val preferences = context.getSharedPreferences(
            SharedPreferencesPostBackfillRetryStateStore.PREFS_NAME,
            Context.MODE_PRIVATE,
        )
        assertTrue(
            preferences.edit()
                .clear()
                .putString(SharedPreferencesPostBackfillRetryStateStore.WORK_ID_KEY, "partial")
                .commit(),
        )
        val corruptCoordinator = PostBackfillRetryCoordinator(
            SharedPreferencesPostBackfillRetryStateStore(context),
            WorkManagerPostBackfillRetryBackend(context),
        )
        assertEquals(
            PostBackfillRetryScheduleOutcome.SCHEDULED,
            corruptCoordinator.schedule(now + 21_600_000L, now),
        )
        assertTrue(
            SharedPreferencesPostBackfillRetryStateStore(context).load()
                is PostBackfillRetryStateRead.Present,
        )

        assertTrue(
            preferences.edit()
                .clear()
                .putString(
                    SharedPreferencesPostBackfillRetryStateStore.WORK_ID_KEY,
                    "not-a-workmanager-uuid",
                )
                .putLong(
                    SharedPreferencesPostBackfillRetryStateStore.RETRY_AT_KEY,
                    now + 10_800_000L,
                )
                .commit(),
        )
        assertTrue(
            SharedPreferencesPostBackfillRetryStateStore(context).load()
                is PostBackfillRetryStateRead.Corrupt,
        )
        assertEquals(
            PostBackfillRetryScheduleOutcome.SCHEDULED,
            corruptCoordinator.schedule(now + 10_800_000L, now),
        )
        assertTrue(
            SharedPreferencesPostBackfillRetryStateStore(context).load()
                is PostBackfillRetryStateRead.Present,
        )
    }

    @Test
    fun runningReplacementUsesNewBoundaryAndCancelsTheRunningWorker() = runBlocking {
        val now = System.currentTimeMillis()
        val consumedBoundary = now - 60_000L
        val requestedBoundary = now + 3_600_000L
        val request = OneTimeWorkRequestBuilder<BlockingPostBackfillRetryProbeWorker>()
            .setInputData(
                workDataOf(
                    BlockingPostBackfillRetryProbeWorker.REQUESTED_BOUNDARY_KEY to
                        requestedBoundary,
                ),
            )
            .build()
        workManager.enqueueUniqueWork(
            PostBackfillAnalysisRetryPolicy.WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        ).await()
        withTimeout(15_000L) {
            probeSession.started.await()
        }

        val preferences = context.getSharedPreferences(
            SharedPreferencesPostBackfillRetryStateStore.PREFS_NAME,
            Context.MODE_PRIVATE,
        )
        assertTrue(
            preferences.edit()
                .putString(
                    SharedPreferencesPostBackfillRetryStateStore.WORK_ID_KEY,
                    request.id.toString(),
                )
                .putLong(
                    SharedPreferencesPostBackfillRetryStateStore.RETRY_AT_KEY,
                    consumedBoundary,
                )
                .commit(),
        )

        val store = SharedPreferencesPostBackfillRetryStateStore(context)
        val backend = WorkManagerPostBackfillRetryBackend(context)
        assertEquals(PostBackfillRetryWorkState.RUNNING, backend.state(request.id.toString()))
        probeSession.release.complete(Unit)
        withTimeout(15_000L) {
            probeSession.cancelled.await()
        }
        val replacement = (store.load() as PostBackfillRetryStateRead.Present).value
        assertNotEquals(request.id.toString(), replacement.workId)
        assertEquals(requestedBoundary, replacement.retryAtEpochMillis)
        assertEquals(PostBackfillRetryWorkState.WAITING, backend.state(replacement.workId))
    }
}
