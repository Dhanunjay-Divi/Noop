package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AnalysisFingerprintInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var dao: WhoopDao

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        dao = database.whoopDao()
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun aggregateTracksEveryScoringInputAndExcludesHousekeeping() = runBlocking {
        val source = "noop-band"
        dao.insertHr(listOf(HrSample(source, 101, 61)))
        dao.insertPpgHr(listOf(PpgHrSample(source, 102, 62, 0.9)))
        dao.insertRr(listOf(RrInterval(source, 103, 980)))
        dao.insertGravity(listOf(GravitySample(source, 104, 0.0, 0.0, 1.0)))
        dao.insertResp(listOf(RespSample(source, 105, 42)))
        dao.insertSkinTemp(listOf(SkinTempSample(source, 106, 3_200)))
        dao.insertSpo2(listOf(Spo2Sample(source, 107, 500, 450)))
        dao.insertSteps(listOf(StepSample(source, 108, 12)))
        dao.insertSleepState(listOf(SleepStateSampleEntity(source, 109, 2)))
        dao.insertEvents(listOf(EventRow(source, 110, "wear", "{}")))

        // These rows are durable, but neither is consumed directly by daily scoring.
        dao.insertBattery(listOf(BatterySample(source, 1_000, soc = 80.0)))
        dao.insertPpgWaveform(listOf(PpgWaveformSampleEntity(source, 1_001, byteArrayOf(1, 2))))

        val repository = WhoopRepository(dao)
        assertEquals("9:noop-band:10:110", repository.analysisFingerprint(source))
    }
}
