package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
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
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

@RunWith(AndroidJUnit4::class)
class AnalysisInputDirtyGateInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var dao: WhoopDao

    private fun claim(
        source: String,
        generation: Long,
        earliest: Long,
        latest: Long = earliest,
    ) = AnalysisInputGenerationClaim(
        deviceId = source,
        generation = generation,
        earliestAffectedTs = earliest,
        latestAffectedTs = latest,
    )

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java)
            .addCallback(object : RoomDatabase.Callback() {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    WhoopDatabase.installAnalysisDirtySourceTriggers(db)
                }
            })
            .build()
        dao = database.whoopDao()
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun freshInstallTriggersAdvanceAllTenScoreBearingTables() = runBlocking {
        val sql = database.openHelper.writableDatabase
        SCORE_TABLES.forEachIndexed { index, table ->
            val source = "source-$table"
            insertScoreBearingRow(sql, table, source, 100L + index)

            var row = dao.analysisDirtySource(source)
            assertEquals("$table insert generation", 1L, row?.generation)
            assertEquals("$table insert acknowledgement", 0L, row?.acknowledgedGeneration)
            assertEquals("$table insert earliest", 100L + index, row?.earliestAffectedTs)
            assertEquals("$table insert latest", 100L + index, row?.latestAffectedTs)
            assertTrue("$table must be pending", dao.isAnalysisSourceDirty(source))

            dao.acknowledgeAnalysisInputClaims(
                listOf(claim(source, 1L, 100L + index)),
            )
            assertFalse("$table insert must acknowledge", dao.isAnalysisSourceDirty(source))
            assertNull(dao.analysisDirtySource(source)?.earliestAffectedTs)
            assertNull(dao.analysisDirtySource(source)?.latestAffectedTs)

            updateScoreBearingRow(sql, table, source)
            row = dao.analysisDirtySource(source)
            assertEquals("$table update generation", 2L, row?.generation)
            assertEquals("$table update acknowledgement", 1L, row?.acknowledgedGeneration)
            assertEquals("$table update earliest", 100L + index, row?.earliestAffectedTs)
            assertEquals("$table update latest", 100L + index, row?.latestAffectedTs)
            assertTrue("$table update must be pending", dao.isAnalysisSourceDirty(source))

            dao.acknowledgeAnalysisInputClaims(
                listOf(claim(source, 2L, 100L + index)),
            )
            sql.execSQL(
                "DELETE FROM `$table` WHERE `deviceId` = ?",
                arrayOf(source),
            )
            row = dao.analysisDirtySource(source)
            assertEquals("$table delete generation", 3L, row?.generation)
            assertEquals("$table delete acknowledgement", 2L, row?.acknowledgedGeneration)
            assertEquals("$table delete earliest", 100L + index, row?.earliestAffectedTs)
            assertEquals("$table delete latest", 100L + index, row?.latestAffectedTs)
            assertTrue("$table delete must be pending", dao.isAnalysisSourceDirty(source))
        }
    }

    @Test
    fun claimSurvivesRepositoryRecreationAndPartialFailureWithoutAcknowledgement() = runBlocking {
        val source = "restart-source"
        dao.insertHr(listOf(HrSample(source, 101L, 61)))

        val firstRepository = WhoopRepository(database)
        val firstClaim = firstRepository.claimAnalysisInput(listOf(source), force = false)!!
        assertEquals(listOf(claim(source, 1L, 101L)), firstClaim.claims)

        // A fresh runtime owner sees the same snapshot because claiming never clears durable state.
        val restartedRepository = WhoopRepository(database)
        assertEquals(
            firstClaim.claims,
            restartedRepository.claimAnalysisInput(listOf(source), force = false)?.claims,
        )

        runCatching {
            restartedRepository.runClaimedAnalysis(firstClaim) { consumption ->
                consumption.markSourceConsumed(source)
                error("persistence failed")
            }
        }
        assertEquals(0L, dao.analysisDirtySource(source)?.acknowledgedGeneration)
        assertTrue(dao.isAnalysisSourceDirty(source))
    }

    @Test
    fun unacknowledgedClaimSurvivesDatabaseCloseAndReopen() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.deleteDatabase(RESTART_DATABASE_NAME)
        try {
            val firstDatabase = openDurableDatabase(context, RESTART_DATABASE_NAME)
            val firstClaim = try {
                val firstDao = firstDatabase.whoopDao()
                firstDao.insertHr(listOf(HrSample("durable-source", 151L, 61)))
                WhoopRepository(firstDatabase).claimAnalysisInput(
                    listOf("durable-source"),
                    force = false,
                )!!
            } finally {
                firstDatabase.close()
            }

            val restartedDatabase = openDurableDatabase(context, RESTART_DATABASE_NAME)
            try {
                val restartedRepository = WhoopRepository(restartedDatabase)
                assertEquals(
                    firstClaim.claims,
                    restartedRepository.claimAnalysisInput(
                        listOf("durable-source"),
                        force = false,
                    )?.claims,
                )

                // Only a successful exact acknowledgement clears the persisted generation.
                restartedRepository.runClaimedAnalysis(firstClaim) { consumption ->
                    consumption.markSourceConsumed("durable-source")
                    consumption.markSourcesEvaluatedForOwnership(
                        listOf("durable-source"),
                        0L,
                        1_000L,
                    )
                }
                assertFalse(restartedDatabase.whoopDao().isAnalysisSourceDirty("durable-source"))
            } finally {
                restartedDatabase.close()
            }
        } finally {
            context.deleteDatabase(RESTART_DATABASE_NAME)
        }
    }

    @Test
    fun dayOwnerChangePersistsOwnershipGenerationAcrossRestartAndExactReplayIsNoOp() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.deleteDatabase(OWNERSHIP_RESTART_DATABASE_NAME)
        try {
            val firstDatabase = openDurableDatabase(context, OWNERSHIP_RESTART_DATABASE_NAME)
            try {
                val registry = DeviceRegistry(firstDatabase)
                registry.setDayOwner("2026-09-10", "band-a", locked = true)
                registry.setDayOwner("2026-09-10", "band-a", locked = true)

                val row = firstDatabase.whoopDao().analysisDirtySource(
                    AnalysisInvalidationSource.OWNERSHIP,
                )
                val expectedDayTs = LocalDate.parse("2026-09-10")
                    .atTime(LocalTime.NOON)
                    .atZone(ZoneId.systemDefault())
                    .toEpochSecond()
                assertEquals(1L, row?.generation)
                assertEquals(0L, row?.acknowledgedGeneration)
                assertEquals(expectedDayTs, row?.earliestAffectedTs)
                assertEquals(expectedDayTs, row?.latestAffectedTs)
            } finally {
                firstDatabase.close()
            }

            val restartedDatabase = openDurableDatabase(context, OWNERSHIP_RESTART_DATABASE_NAME)
            try {
                val dao = restartedDatabase.whoopDao()
                assertEquals(
                    1L,
                    dao.analysisDirtySource(AnalysisInvalidationSource.OWNERSHIP)?.generation,
                )

                DeviceRegistry(restartedDatabase).setDayOwner(
                    "2026-09-10",
                    "band-a",
                    locked = false,
                )
                assertEquals(
                    2L,
                    dao.analysisDirtySource(AnalysisInvalidationSource.OWNERSHIP)?.generation,
                )
                assertTrue(dao.isAnalysisSourceDirty(AnalysisInvalidationSource.OWNERSHIP))
            } finally {
                restartedDatabase.close()
            }
        } finally {
            context.deleteDatabase(OWNERSHIP_RESTART_DATABASE_NAME)
        }
    }

    @Test
    fun concurrentWriteRemainsPendingAfterExactGenerationAcknowledgement() = runBlocking {
        val source = "concurrent-source"
        val repository = WhoopRepository(database)
        dao.insertHr(listOf(HrSample(source, 201L, 61)))
        val firstClaim = repository.claimAnalysisInput(listOf(source), force = false)!!

        dao.insertRr(listOf(RrInterval(source, 202L, 980)))
        assertEquals(2L, dao.analysisDirtySource(source)?.generation)

        repository.runClaimedAnalysis(firstClaim) { consumption ->
            consumption.markSourceConsumed(source)
            consumption.markSourcesEvaluatedForOwnership(listOf(source), 0L, 1_000L)
        }

        val row = dao.analysisDirtySource(source)
        assertEquals(2L, row?.generation)
        assertEquals(0L, row?.acknowledgedGeneration)
        assertEquals(201L, row?.earliestAffectedTs)
        assertEquals(202L, row?.latestAffectedTs)
        assertTrue(dao.isAnalysisSourceDirty(source))
        assertEquals(
            listOf(claim(source, 2L, 201L, 202L)),
            repository.claimAnalysisInput(listOf(source), force = false)?.claims,
        )
    }

    @Test
    fun boundedCoverageShrinksNewestTailThenAcknowledgesExactGeneration() = runBlocking {
        val source = "bounded-source"
        val repository = WhoopRepository(database)
        val now = 1_780_012_345L
        val midnight = com.noop.analytics.IntelligenceEngine.midnightLocal(now, 0L)
        val earliest = midnight - 39L * 86_400L + 1_000L
        val latest = midnight + 1_000L
        dao.insertHr(
            listOf(
                HrSample(source, earliest, 61),
                HrSample(source, latest, 62),
            ),
        )

        val firstLease = repository.claimAnalysisInput(listOf(source), force = false)!!
        val firstPlan = com.noop.analytics.IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = firstLease.claims,
            nowSeconds = now,
            timezoneOffsetSeconds = 0L,
        )
        repository.runClaimedAnalysis(firstLease) { consumption ->
            consumption.markSourceConsumed(source)
            consumption.markSourcesEvaluatedForOwnership(
                listOf(source),
                firstPlan.scanCoverage.startTs,
                firstPlan.scanCoverage.endTs,
            )
        }

        val partiallyAdvanced = requireNotNull(dao.analysisDirtySource(source))
        assertEquals(2L, partiallyAdvanced.generation)
        assertEquals(0L, partiallyAdvanced.acknowledgedGeneration)
        assertEquals(earliest, partiallyAdvanced.earliestAffectedTs)
        assertEquals(firstPlan.scanCoverage.startTs - 1L, partiallyAdvanced.latestAffectedTs)

        val secondLease = repository.claimAnalysisInput(listOf(source), force = false)!!
        val secondPlan = com.noop.analytics.IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = secondLease.claims,
            nowSeconds = now,
            timezoneOffsetSeconds = 0L,
        )
        assertEquals(
            com.noop.analytics.IntelligenceEngine.AnalysisPassKind.HISTORICAL,
            secondPlan.passKind,
        )
        repository.runClaimedAnalysis(secondLease) { consumption ->
            consumption.markSourceConsumed(source)
            consumption.markSourcesEvaluatedForOwnership(
                listOf(source),
                secondPlan.scanCoverage.startTs,
                secondPlan.scanCoverage.endTs,
            )
        }

        assertFalse(dao.isAnalysisSourceDirty(source))
        assertEquals(2L, dao.analysisDirtySource(source)?.acknowledgedGeneration)
        assertNull(dao.analysisDirtySource(source)?.earliestAffectedTs)
        assertNull(dao.analysisDirtySource(source)?.latestAffectedTs)
    }

    @Test
    fun invalidOwnershipBoundsRequireEmptyGlobalScoreBearingHistory() = runBlocking {
        val source = AnalysisInvalidationSource.OWNERSHIP
        val sql = database.openHelper.writableDatabase
        sql.execSQL(
            "INSERT INTO `analysisDirtySource` " +
                "(`deviceId`,`generation`,`acknowledgedGeneration`,`earliestAffectedTs`,`latestAffectedTs`) " +
                "VALUES (?,1,0,NULL,NULL)",
            arrayOf(source),
        )
        val repository = WhoopRepository(database)
        val emptyLease = repository.claimAnalysisInput(listOf(source), force = false)!!
        repository.runClaimedAnalysis(emptyLease) { Unit }
        assertFalse(dao.isAnalysisSourceDirty(source))

        dao.insertHr(listOf(HrSample("band-with-history", 501L, 61)))
        sql.execSQL(
            "UPDATE `analysisDirtySource` SET `generation` = 2, " +
                "`acknowledgedGeneration` = 1, `earliestAffectedTs` = NULL, " +
                "`latestAffectedTs` = NULL WHERE `deviceId` = ?",
            arrayOf(source),
        )
        val populatedLease = repository.claimAnalysisInput(listOf(source), force = false)!!
        repository.runClaimedAnalysis(populatedLease) { consumption ->
            consumption.markSourcesEvaluatedForOwnership(
                listOf("band-with-history"),
                0L,
                1_000L,
            )
        }

        assertTrue(dao.hasAnyScoreBearingHistory())
        assertTrue(dao.hasScoreBearingHistory("band-with-history"))
        assertTrue(dao.isAnalysisSourceDirty(source))
        assertEquals(1L, dao.analysisDirtySource(source)?.acknowledgedGeneration)
    }

    @Test
    fun successfulPassAcknowledgesAndHousekeepingDoesNotAdvance() = runBlocking {
        val source = "ack-source"
        val repository = WhoopRepository(database)
        val sql = database.openHelper.writableDatabase
        dao.insertHr(listOf(HrSample(source, 301L, 61)))
        val claim = repository.claimAnalysisInput(listOf(source), force = false)!!

        repository.runClaimedAnalysis(claim) { consumption ->
            consumption.markSourceConsumed(source)
            consumption.markSourcesEvaluatedForOwnership(listOf(source), 0L, 1_000L)
        }
        assertFalse(dao.isAnalysisSourceDirty(source))
        assertEquals(1L, dao.analysisDirtySource(source)?.acknowledgedGeneration)
        assertNull(dao.analysisDirtySource(source)?.earliestAffectedTs)
        assertNull(dao.analysisDirtySource(source)?.latestAffectedTs)

        sql.execSQL(
            "UPDATE `hrSample` SET `synced` = 1 WHERE `deviceId` = ? AND `ts` = ?",
            arrayOf(source, 301L),
        )
        assertFalse(dao.isAnalysisSourceDirty(source))
        assertEquals(1L, dao.analysisDirtySource(source)?.generation)

        sql.execSQL(
            "UPDATE `hrSample` SET `bpm` = 62 WHERE `deviceId` = ? AND `ts` = ?",
            arrayOf(source, 301L),
        )
        assertEquals(2L, dao.analysisDirtySource(source)?.generation)
        assertTrue(dao.isAnalysisSourceDirty(source))

        dao.insertBattery(listOf(BatterySample(source, 302L, soc = 80.0)))
        dao.insertPpgWaveform(
            listOf(PpgWaveformSampleEntity(source, 303L, byteArrayOf(1, 2))),
        )
        assertEquals(2L, dao.analysisDirtySource(source)?.generation)
    }

    @Test
    fun outerUpsertAndReplaceCannotOverrideTriggerConflictSafety() = runBlocking {
        val source = "conflict-source"
        val sql = database.openHelper.writableDatabase
        sql.execSQL(
            "INSERT INTO `hrSample` (`deviceId`, `ts`, `bpm`, `synced`) VALUES (?, ?, ?, ?)",
            arrayOf<Any?>(source, 401L, 61, 0),
        )
        assertEquals(1L, dao.analysisDirtySource(source)?.generation)

        sql.execSQL(
            """
                INSERT INTO `hrSample` (`deviceId`, `ts`, `bpm`, `synced`)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(`deviceId`, `ts`) DO UPDATE SET `bpm` = excluded.`bpm`
            """.trimIndent(),
            arrayOf<Any?>(source, 401L, 62, 0),
        )
        val afterUpsert = requireNotNull(dao.analysisDirtySource(source)).generation
        assertTrue(afterUpsert > 1L)

        sql.execSQL(
            "INSERT OR REPLACE INTO `hrSample` (`deviceId`, `ts`, `bpm`, `synced`) " +
                "VALUES (?, ?, ?, ?)",
            arrayOf<Any?>(source, 401L, 63, 0),
        )
        val afterReplace = requireNotNull(dao.analysisDirtySource(source)).generation
        assertTrue(afterReplace > afterUpsert)
        assertTrue(dao.isAnalysisSourceDirty(source))
    }

    @Test
    fun blankWhitespaceIdsNeverCreateLedgerRows() = runBlocking {
        val sql = database.openHelper.writableDatabase
        listOf("", "   ", "\t", "\n\r").forEachIndexed { index, source ->
            sql.execSQL(
                "INSERT INTO `hrSample` (`deviceId`, `ts`, `bpm`, `synced`) VALUES (?, ?, ?, ?)",
                arrayOf<Any?>(source, 500L + index, 61, 0),
            )
            assertNull(dao.analysisDirtySource(source))
        }

        sql.execSQL(
            "UPDATE `hrSample` SET `deviceId` = 'valid-source' WHERE `ts` = 500",
        )
        assertEquals(1L, dao.analysisDirtySource("valid-source")?.generation)
        sql.execSQL(
            "UPDATE `hrSample` SET `deviceId` = '\t' WHERE `ts` = 500",
        )
        assertTrue(dao.isAnalysisSourceDirty("valid-source"))
        assertNull(dao.analysisDirtySource("\t"))
    }

    @Test
    fun timestampCorrectionAndSourceMoveTrackOldAndNewBounds() = runBlocking {
        val sql = database.openHelper.writableDatabase
        sql.execSQL(
            "INSERT INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`) VALUES ('source-a',100,60,0)",
        )
        dao.acknowledgeAnalysisInputClaims(listOf(claim("source-a", 1L, 100L)))

        sql.execSQL(
            "UPDATE `hrSample` SET `deviceId` = 'source-b', `ts` = 250 " +
                "WHERE `deviceId` = 'source-a' AND `ts` = 100",
        )

        assertEquals(
            claim("source-a", 2L, 100L),
            dao.pendingAnalysisInputClaims(listOf("source-a")).single(),
        )
        assertEquals(
            claim("source-b", 1L, 250L),
            dao.pendingAnalysisInputClaims(listOf("source-b")).single(),
        )

        dao.acknowledgeAnalysisInputClaims(listOf(claim("source-b", 1L, 250L)))
        sql.execSQL(
            "UPDATE `hrSample` SET `ts` = 175 " +
                "WHERE `deviceId` = 'source-b' AND `ts` = 250",
        )
        assertEquals(
            claim("source-b", 2L, 175L, 250L),
            dao.pendingAnalysisInputClaims(listOf("source-b")).single(),
        )
    }

    @Test
    fun deviceDeleteRemovesGenerationAfterRawDeleteTriggersRun() = runBlocking {
        val source = "delete-source"
        dao.insertHr(listOf(HrSample(source, 601L, 61)))
        assertTrue(dao.isAnalysisSourceDirty(source))

        DeviceRegistry(database).deleteDeviceData(source)

        assertNull(dao.analysisDirtySource(source))
        assertEquals(0, database.openHelper.writableDatabase.query(
            "SELECT COUNT(*) FROM `hrSample` WHERE `deviceId` = ?",
            arrayOf(source),
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getInt(0)
        })
    }

    private fun insertScoreBearingRow(
        database: SupportSQLiteDatabase,
        table: String,
        source: String,
        ts: Long,
    ) {
        val (sql, values) = when (table) {
            "hrSample" ->
                "INSERT INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 61, 0)
            "ppgHrSample" ->
                "INSERT INTO `ppgHrSample` (`deviceId`,`ts`,`bpm`,`conf`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 61.0, 0.9, 0)
            "rrInterval" ->
                "INSERT INTO `rrInterval` " +
                    "(`deviceId`,`ts`,`rrMs`,`seq`,`synced`,`tsSuspect`,`ord`,`srcChannel`) " +
                    "VALUES (?,?,?,?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 980, 0, 0, null, null, null)
            "gravitySample" ->
                "INSERT INTO `gravitySample` (`deviceId`,`ts`,`x`,`y`,`z`,`synced`) VALUES (?,?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 0.1, 0.2, 0.3, 0)
            "respSample" ->
                "INSERT INTO `respSample` (`deviceId`,`ts`,`raw`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 0)
            "skinTempSample" ->
                "INSERT INTO `skinTempSample` (`deviceId`,`ts`,`raw`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 0)
            "spo2Sample" ->
                "INSERT INTO `spo2Sample` (`deviceId`,`ts`,`red`,`ir`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 100, 200, 0)
            "stepSample" ->
                "INSERT INTO `stepSample` " +
                    "(`deviceId`,`ts`,`counter`,`activityClass`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 1, 0)
            "sleepStateSample" ->
                "INSERT INTO `sleepStateSample` (`deviceId`,`ts`,`state`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 2, 0)
            "event" ->
                "INSERT INTO `event` (`deviceId`,`ts`,`kind`,`payloadJSON`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, "test", "{}", 0)
            else -> error("unknown score-bearing table $table")
        }
        database.execSQL(sql, values)
    }

    private fun updateScoreBearingRow(
        database: SupportSQLiteDatabase,
        table: String,
        source: String,
    ) {
        val sql = when (table) {
            "hrSample" -> "UPDATE `hrSample` SET `bpm` = 62 WHERE `deviceId` = ?"
            "ppgHrSample" -> "UPDATE `ppgHrSample` SET `conf` = 0.8 WHERE `deviceId` = ?"
            "rrInterval" -> "UPDATE `rrInterval` SET `ord` = 1 WHERE `deviceId` = ?"
            "gravitySample" -> "UPDATE `gravitySample` SET `x` = 0.4 WHERE `deviceId` = ?"
            "respSample" -> "UPDATE `respSample` SET `raw` = 11 WHERE `deviceId` = ?"
            "skinTempSample" -> "UPDATE `skinTempSample` SET `raw` = 11 WHERE `deviceId` = ?"
            "spo2Sample" -> "UPDATE `spo2Sample` SET `red` = 101 WHERE `deviceId` = ?"
            "stepSample" -> "UPDATE `stepSample` SET `counter` = 11 WHERE `deviceId` = ?"
            "sleepStateSample" ->
                "UPDATE `sleepStateSample` SET `state` = 1 WHERE `deviceId` = ?"
            "event" -> "UPDATE `event` SET `payloadJSON` = '{\"changed\":true}' " +
                "WHERE `deviceId` = ?"
            else -> error("unknown score-bearing table $table")
        }
        database.execSQL(sql, arrayOf(source))
    }

    private fun openDurableDatabase(context: Context, name: String): WhoopDatabase =
        Room.databaseBuilder(context, WhoopDatabase::class.java, name)
            .addCallback(object : RoomDatabase.Callback() {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    WhoopDatabase.installAnalysisDirtySourceTriggers(db)
                }
            })
            .build()

    private companion object {
        const val RESTART_DATABASE_NAME = "analysis-input-generation-restart-test"
        const val OWNERSHIP_RESTART_DATABASE_NAME = "analysis-ownership-generation-restart-test"

        val SCORE_TABLES = listOf(
            "hrSample",
            "ppgHrSample",
            "rrInterval",
            "gravitySample",
            "respSample",
            "skinTempSample",
            "spo2Sample",
            "stepSample",
            "sleepStateSample",
            "event",
        )
    }
}
