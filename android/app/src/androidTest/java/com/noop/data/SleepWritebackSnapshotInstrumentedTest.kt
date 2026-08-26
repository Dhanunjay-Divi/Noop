package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.analytics.SleepStageTotals
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SleepWritebackSnapshotInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var dao: WhoopDao
    private lateinit var repository: WhoopRepository

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        dao = database.whoopDao()
        repository = WhoopRepository(database)
    }

    @After
    fun closeDatabase() {
        if (database.isOpen) database.close()
    }

    @Test
    fun snapshotReadsAndResolvesCompleteSourceHistory() = runBlocking {
        val day = 86_400L
        val firstStart = 1_760_000_000L
        val rows = (0 until SleepStageTotals.HABITUAL_MIN_DAYS).map { index ->
            val start = firstStart + index * day
            SleepSession(
                deviceId = "whoop-active-noop",
                startTs = start,
                endTs = start + 8 * 3_600L,
                stagesJSON =
                    """[{"start":$start,"end":${start + 8 * 3_600L},"stage":"light"}]""",
            )
        }
        dao.upsertSleepSessions(rows)

        val snapshot = repository.sleepWritebackSnapshot(
            deviceId = "whoop-active",
            from = 0L,
            to = rows.last().endTs + day,
        )

        assertEquals(rows.map(SleepSession::startTs), snapshot.sessions.map(SleepSession::startTs))
        assertNotNull(snapshot.habitualMidsleepSec)
    }

    @Test
    fun failedLocalReadThrowsInsteadOfBecomingEmptySnapshot() = runBlocking {
        val failingDao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw IllegalStateException("forced ${method.name} read failure")
        } as WhoopDao
        val failingRepository = WhoopRepository(failingDao)

        val failure = runCatching {
            failingRepository.sleepWritebackSnapshot(
                deviceId = "whoop-active",
                from = 0L,
                to = 1_800_000_000L,
            )
        }.exceptionOrNull()

        assertTrue(
            "an unreadable local store must abort external replacement",
            failure is IllegalStateException,
        )
    }
}
