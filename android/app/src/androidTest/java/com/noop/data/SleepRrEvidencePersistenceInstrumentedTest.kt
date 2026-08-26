package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SleepRrEvidencePersistenceInstrumentedTest {
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
        database.close()
    }

    @Test
    fun manualMutationsClearEvidenceAndAnalyzedUpdateWritesPairAtomically() = runBlocking {
        val start = 1_750_000_000L
        val original = SleepSession(
            deviceId = "my-band-noop",
            startTs = start,
            endTs = start + 28_800L,
            stagesJSON = """[{"start":1750000000,"end":1750028800,"stage":"light"}]""",
            rrEligibleWindowCount = 96,
            rrValidWindowCount = 24,
        )
        dao.upsertSleepSessions(listOf(original))

        repository.updateSleepSessionTimes(
            original,
            newStartTs = start + 600L,
            newEndTs = original.endTs,
        )
        val edited = dao.sleepSessionByKey(original.deviceId, original.startTs)!!
        assertNull(edited.rrEligibleWindowCount)
        assertNull(edited.rrValidWindowCount)

        dao.upsertSleepSessions(
            listOf(
                edited.copy(
                    rrEligibleWindowCount = 94,
                    rrValidWindowCount = 24,
                ),
            ),
        )
        dao.updateSleepStages(
            edited.deviceId,
            edited.startTs,
            """[{"start":1750000600,"end":1750028800,"stage":"deep"}]""",
        )
        val stageEdited = dao.sleepSessionByKey(edited.deviceId, edited.startTs)!!
        assertNull(stageEdited.rrEligibleWindowCount)
        assertNull(stageEdited.rrValidWindowCount)

        assertEquals(
            1,
            dao.updateAnalyzedSleepStages(
                edited.deviceId,
                edited.startTs,
                stageEdited.stagesJSON!!,
                rrEligibleWindowCount = 94,
                rrValidWindowCount = 24,
            ),
        )
        val analyzed = dao.sleepSessionByKey(edited.deviceId, edited.startTs)!!
        assertEquals(94, analyzed.rrEligibleWindowCount)
        assertEquals(24, analyzed.rrValidWindowCount)
    }

    @Test
    fun editingMissingSessionFailsWithoutFabricatingReplacement() = runBlocking {
        val missing = SleepSession(
            deviceId = "my-band-noop",
            startTs = 1_755_000_000L,
            endTs = 1_755_028_800L,
        )

        assertFalse(
            repository.updateSleepSessionTimes(
                missing,
                newStartTs = missing.startTs + 600L,
                newEndTs = missing.endTs,
            ),
        )
        assertNull(dao.sleepSessionByKey(missing.deviceId, missing.startTs))
    }

    @Test
    fun analysisConflictPreservesEditedWindowStagesEvidenceAndAuxiliariesButRefreshesVitals() =
        runBlocking {
            val start = 1_760_000_000L
            val edited = SleepSession(
                deviceId = "my-band-noop",
                startTs = start,
                endTs = start + 27_000L,
                efficiency = 0.80,
                restingHr = 60,
                avgHrv = 40.0,
                stagesJSON = """[{"start":$start,"end":${start + 27_000},"stage":"deep"}]""",
                userEdited = true,
                startTsAdjusted = start + 600L,
                motionJSON = "[0.1,0.2]",
                sleepStateJSON = "[1,2]",
                rrEligibleWindowCount = 88,
                rrValidWindowCount = 24,
            )
            dao.upsertSleepSessions(listOf(edited))

            dao.upsertSleepSessions(
                listOf(
                    SleepSession(
                        deviceId = edited.deviceId,
                        startTs = start,
                        endTs = start + 28_800L,
                        efficiency = 0.94,
                        restingHr = 51,
                        avgHrv = 72.0,
                        stagesJSON =
                            """[{"start":$start,"end":${start + 28_800},"stage":"rem"}]""",
                        motionJSON = "[9.9]",
                        sleepStateJSON = "[3]",
                        rrEligibleWindowCount = 96,
                        rrValidWindowCount = 30,
                    ),
                ),
            )

            val persisted = dao.sleepSessionByKey(edited.deviceId, start)!!
            assertEquals(edited.endTs, persisted.endTs)
            assertEquals(edited.startTsAdjusted, persisted.startTsAdjusted)
            assertEquals(edited.stagesJSON, persisted.stagesJSON)
            assertEquals(edited.rrEligibleWindowCount, persisted.rrEligibleWindowCount)
            assertEquals(edited.rrValidWindowCount, persisted.rrValidWindowCount)
            assertEquals(edited.motionJSON, persisted.motionJSON)
            assertEquals(edited.sleepStateJSON, persisted.sleepStateJSON)
            assertTrue(persisted.userEdited)
            assertEquals(0.94, persisted.efficiency!!, 0.0)
            assertEquals(51, persisted.restingHr)
            assertEquals(72.0, persisted.avgHrv!!, 0.0)
        }

    @Test
    fun uneditedConflictAcceptsNewAnalysisAndKeepsTargetedAuxiliaries() = runBlocking {
        val start = 1_770_000_000L
        val original = SleepSession(
            deviceId = "my-band-noop",
            startTs = start,
            endTs = start + 25_200L,
            stagesJSON = """[{"start":$start,"end":${start + 25_200},"stage":"light"}]""",
            motionJSON = "[0.1]",
            sleepStateJSON = "[2]",
            rrEligibleWindowCount = 84,
            rrValidWindowCount = 21,
        )
        dao.upsertSleepSessions(listOf(original))
        val replacement = original.copy(
            endTs = start + 28_800L,
            efficiency = 0.92,
            stagesJSON = """[{"start":$start,"end":${start + 28_800},"stage":"deep"}]""",
            motionJSON = "[9.9]",
            sleepStateJSON = "[3]",
            rrEligibleWindowCount = 96,
            rrValidWindowCount = 30,
        )

        dao.upsertSleepSessions(listOf(replacement))

        val persisted = dao.sleepSessionByKey(original.deviceId, start)!!
        assertEquals(replacement.endTs, persisted.endTs)
        assertEquals(replacement.stagesJSON, persisted.stagesJSON)
        assertEquals(96, persisted.rrEligibleWindowCount)
        assertEquals(30, persisted.rrValidWindowCount)
        assertEquals(original.motionJSON, persisted.motionJSON)
        assertEquals(original.sleepStateJSON, persisted.sleepStateJSON)
    }
}
