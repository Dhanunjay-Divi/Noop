package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * The `settings.json` half of #1000 ("restore doesn't bring back settings/weight/height"): the pure
 * whitelist/JSON codec, plus the REAL ZIP container round trip through the same
 * [DataBackup.writeBackupZip] / [DataBackup.stageBackupSqlite] pair the live export/import uses.
 * Plain JVM (real org.json + java.util.zip, no Robolectric); the SharedPreferences apply/snapshot
 * bridge needs a Context and is covered by the shared restore path at the platform level.
 *
 * Twin of the Apple `BackupSettingsTests` in Packages/WhoopStore — the canonical keys and kinds
 * asserted here are the cross-platform contract, so a drift on either side fails one of the twins.
 */
class BackupSettingsCodecTest {

    @get:Rule val tmp = TemporaryFolder()

    // ── Codec: encode/decode round trip ──────────────────────────────────────────

    @Test fun encodeDecodeRoundTripsEveryWhitelistedKey() {
        val values = mapOf(
            "profile.age" to 34,
            "profile.dateOfBirth" to "1992-11-03",
            "profile.sex" to "female",
            "profile.weightKg" to 62.5,
            "profile.targetWeightKg" to 60.0,
            "profile.heightCm" to 168.0,
            "profile.waistCm" to 71.0,
            "profile.hrMax" to 191,
            "units.system" to "imperial",
            "units.mass" to "lb",
            "units.height" to "ft_in",
            "units.temperature" to "celsius",
            "effort.scale" to "whoop",
            "hrv.window" to "deep",
            "theme.appearance" to "black",
            "chart.style" to "classic",
            "trend.chart.style" to "bar",
            "noop.showDayCycleBackground" to false,
            "noop.skyBehindCards" to true,
            "noop.cardOpacityPercent" to 86,
            "workoutKeepScreenOn" to true,
            "today.sectionOrder" to "summary,sleep,health",
            "today.keyMetrics" to "charge,hrv,restingHr",
            "today.keyMetricsDetailed" to true,
            "today.keyMetricsWindowDays" to 7,
            "noop.hydrationTracking" to true,
            "windDown.enabled" to true,
            "windDown.sleepNeedMinutes" to 510,
            "windDown.goalMode" to "extraOpportunity",
            "windDown.leadMinutes" to 45,
            "sleepPlanner.wakeMinutes" to 390,
            "notif.masterEnabled" to true,
            "notif.onlyWhenWorn" to true,
            "notif.quietHoursEnabled" to true,
            "notif.quietStartMinutes" to 1_320,
            "notif.quietEndMinutes" to 420,
            "inactivity.enabled" to true,
            "inactivity.thresholdMinutes" to 45,
            "inactivity.reNudgeMinutes" to 30,
            "inactivity.buzzLoops" to 2,
            "inactivity.activeHoursEnabled" to true,
            "inactivity.activeStartMinutes" to 540,
            "inactivity.activeEndMinutes" to 1_020,
            "hydrationReminders.enabled" to true,
            "hydrationReminders.intervalMinutes" to 120,
            "hydrationReminders.activeStartMinutes" to 480,
            "hydrationReminders.activeEndMinutes" to 1_260,
            "hydrationReminders.adaptiveEnabled" to false,
            "hydrationReminders.strapBuzzEnabled" to false,
        )
        assertEquals(
            "This fixture must cover every settings-schema field",
            BackupSettingsCodec.WHITELIST.keys,
            values.keys + BackupSettingsCodec.SCHEMA_VERSION_KEY,
        )
        val json = requireNotNull(BackupSettingsCodec.encode(values))
        val back = BackupSettingsCodec.decode(json)

        assertEquals(34, back["profile.age"])
        assertEquals("1992-11-03", back["profile.dateOfBirth"])
        assertEquals(4, back[BackupSettingsCodec.SCHEMA_VERSION_KEY])
        assertEquals("female", back["profile.sex"])
        assertEquals(62.5, back["profile.weightKg"])
        assertEquals(60.0, back["profile.targetWeightKg"])
        assertEquals(168.0, back["profile.heightCm"])
        assertEquals(71.0, back["profile.waistCm"])
        assertEquals(191, back["profile.hrMax"])
        assertEquals("imperial", back["units.system"])
        assertEquals("lb", back["units.mass"])
        assertEquals("ft_in", back["units.height"])
        assertEquals("celsius", back["units.temperature"])
        assertEquals("whoop", back["effort.scale"])
        assertEquals("deep", back["hrv.window"])
        assertEquals(false, back["noop.showDayCycleBackground"])
        assertEquals(true, back["today.keyMetricsDetailed"])
        assertEquals("extraOpportunity", back["windDown.goalMode"])
        assertEquals(390, back["sleepPlanner.wakeMinutes"])
        assertEquals(120, back["hydrationReminders.intervalMinutes"])
        assertEquals(false, back["hydrationReminders.adaptiveEnabled"])
        assertEquals(values.size + 1, back.size)
    }

    @Test fun crossPlatformShapedJsonDecodes() {
        // What the Apple exporter writes (JSONSerialization, sorted keys, integral doubles possible).
        val appleJson = """{"settings.schemaVersion":4,"profile.age":34.0,"profile.dateOfBirth":"1992-11-03","profile.hrMax":191,"profile.sex":"male","profile.weightKg":80,"profile.targetWeightKg":75,"units.system":"metric","hrv.window":"deep","today.keyMetricsDetailed":true}"""
        val back = BackupSettingsCodec.decode(appleJson)
        assertEquals("Integral JSON numbers must land as Int for int-kind keys", 34, back["profile.age"])
        assertEquals("1992-11-03", back["profile.dateOfBirth"])
        assertEquals(4, back[BackupSettingsCodec.SCHEMA_VERSION_KEY])
        assertEquals(191, back["profile.hrMax"])
        assertEquals("A bare JSON int must land as Double for double-kind keys", 80.0, back["profile.weightKg"])
        assertEquals(75.0, back["profile.targetWeightKg"])
        assertEquals("male", back["profile.sex"])
        assertEquals("metric", back["units.system"])
        assertEquals("deep", back["hrv.window"])
        assertEquals(true, back["today.keyMetricsDetailed"])
    }

    @Test fun everyNonProfilePayloadFieldHasAnAndroidPreferenceMapping() {
        val profileKeys = setOf(
            "profile.age",
            BackupSettingsCodec.DATE_OF_BIRTH_KEY,
            "profile.sex",
            "profile.weightKg",
            "profile.targetWeightKg",
            "profile.heightCm",
            "profile.waistCm",
            "profile.hrMax",
        )
        assertEquals(
            "A schema field must never be encodable without a restore destination",
            BackupSettingsCodec.WHITELIST.keys -
                BackupSettingsCodec.SCHEMA_VERSION_KEY -
                profileKeys,
            BackupSettingsBridge.mappedCanonicalKeys,
        )
    }

    // ── Codec: whitelist + type enforcement ──────────────────────────────────────

    @Test fun nonWhitelistedKeysAreDroppedOnEncodeAndDecode() {
        val json = requireNotNull(
            BackupSettingsCodec.encode(
                mapOf(
                    "profile.age" to 30,
                    "device.peripheralId" to "AA:BB:CC:DD:EE:FF",
                    "sync.cursor" to 12345,
                ),
            ),
        )
        assertFalse(json.contains("peripheralId"))
        assertFalse(json.contains("cursor"))

        val back = BackupSettingsCodec.decode("""{"profile.age": 28, "injected.key": "evil"}""")
        assertNull(back["injected.key"])
        assertEquals(28, back["profile.age"])
    }

    @Test fun wrongTypedValuesAreDroppedNotCoerced() {
        val back = BackupSettingsCodec.decode(
            """{"profile.age": true, "profile.dateOfBirth":"1992-02-31","profile.sex": 5, "profile.weightKg": "heavy", "profile.hrMax": 185, "today.keyMetricsDetailed":1}""",
        )
        assertNull("JSON true must never become age 1", back["profile.age"])
        assertNull("Invalid civil dates must be dropped", back["profile.dateOfBirth"])
        assertNull(back["profile.sex"])
        assertNull(back["profile.weightKg"])
        assertNull("JSON 1 must never become true", back["today.keyMetricsDetailed"])
        assertEquals("Valid siblings still decode", 185, back["profile.hrMax"])
    }

    @Test fun fractionalIntegersAndOutOfRangeOrInvalidValuesAreDropped() {
        val back = BackupSettingsCodec.decode(
            """{"profile.age":34.5,"profile.weightKg":900,"profile.hrMax":231,"profile.sex":"unknown","units.mass":"pounds","hrv.window":"last-hour","today.sectionOrder":"sleep,<script>","today.keyMetricsWindowDays":30,"windDown.sleepNeedMinutes":100,"sleepPlanner.wakeMinutes":1440,"inactivity.buzzLoops":9,"hydrationReminders.intervalMinutes":30}""",
        )
        assertNull("Fractional numbers must not be truncated into integer fields", back["profile.age"])
        assertNull(back["profile.weightKg"])
        assertNull(back["profile.hrMax"])
        assertNull(back["profile.sex"])
        assertNull(back["units.mass"])
        assertNull(back["hrv.window"])
        assertNull(back["today.sectionOrder"])
        assertNull(back["today.keyMetricsWindowDays"])
        assertNull(back["windDown.sleepNeedMinutes"])
        assertNull(back["sleepPlanner.wakeMinutes"])
        assertNull(back["inactivity.buzzLoops"])
        assertNull(back["hydrationReminders.intervalMinutes"])
    }

    @Test fun keyMetricSelectionIsDeduplicatedFilteredAndCappedAtFive() {
        val json = requireNotNull(
            BackupSettingsCodec.encode(
                mapOf(
                    "today.keyMetrics" to
                        "charge,charge,removedMetric,hrv,restingHr,bloodOxygen,respiratory,steps",
                ),
            ),
        )
        val back = BackupSettingsCodec.decode(json)
        assertEquals(
            "charge,hrv,restingHr,bloodOxygen,respiratory",
            back["today.keyMetrics"],
        )

        val invalid = BackupSettingsCodec.decode(
            """{"today.keyMetrics":"removedMetric,unknown"}""",
        )
        assertNull(invalid["today.keyMetrics"])
    }

    @Test fun garbageDecodesToEmptyAndEmptyEncodesToNull() {
        assertTrue(BackupSettingsCodec.decode("not json at all").isEmpty())
        assertTrue(BackupSettingsCodec.decode("[1,2,3]").isEmpty())
        assertNull(BackupSettingsCodec.encode(emptyMap()))
        assertNull(BackupSettingsCodec.encode(mapOf("unrelated.key" to 1)))
    }

    // ── Container: settings entry round-trips through the real ZIP layer ─────────

    /** The 16-byte SQLite magic, so the staged file passes the importer's header validation. */
    private val sqliteMagic = byteArrayOf(
        0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
    )

    private fun fakeSqlite(payload: String): File {
        val f = tmp.newFile()
        f.outputStream().use { it.write(sqliteMagic); it.write(payload.toByteArray()) }
        return f
    }

    @Test fun zipWithSettingsStagesBothDbAndSettings() {
        val liveDb = fakeSqlite("rows")
        val settingsJson = requireNotNull(
            BackupSettingsCodec.encode(mapOf("profile.age" to 41, "profile.weightKg" to 90.5)),
        )
        val backup = tmp.newFile("with-settings.noopbak")
        DataBackup.writeBackupZip(liveDb, backup, settingsJson)

        val stagedDb = tmp.newFile()
        val stagedSettings = File(tmp.root, "staged-settings.json")
        val stagedManifest = File(tmp.root, "staged-manifest.json")
        val result = DataBackup.stageBackupSqlite(
            backup.inputStream(),
            DataBackup.peekHeader(backup),
            stagedDb,
            stagedSettings,
            stagedManifest,
        )

        assertEquals(DataBackup.StageResult.OK, result)
        assertEquals(liveDb.readBytes().toList(), stagedDb.readBytes().toList())
        assertTrue("settings.json must be staged alongside the DB", stagedSettings.exists())
        val back = BackupSettingsCodec.decode(stagedSettings.readText(Charsets.UTF_8))
        assertEquals(41, back["profile.age"])
        assertEquals(90.5, back["profile.weightKg"])
        val manifest = requireNotNull(BackupManifest.decode(stagedManifest.readText()))
        assertNull(
            manifest.validationProblem(
                stagedDb,
                stagedSettings,
                "noop-backup.sqlite",
                "settings.json",
                BackupManifest.PLATFORM_ANDROID,
                BackupManifest.ENGINE_ROOM,
                NOOP_DATABASE_SCHEMA_VERSION,
            ),
        )
    }

    @Test fun currentZipWithoutSettingsStagesDbAndManifest() {
        val liveDb = fakeSqlite("legacy-rows")
        val backup = tmp.newFile("current-no-settings.noopbak")
        DataBackup.writeBackupZip(liveDb, backup)

        val stagedDb = tmp.newFile()
        val stagedSettings = File(tmp.root, "staged-settings.json")
        val stagedManifest = File(tmp.root, "staged-no-settings-manifest.json")
        val result = DataBackup.stageBackupSqlite(
            backup.inputStream(),
            DataBackup.peekHeader(backup),
            stagedDb,
            stagedSettings,
            stagedManifest,
        )

        assertEquals(DataBackup.StageResult.OK, result)
        assertEquals(liveDb.readBytes().toList(), stagedDb.readBytes().toList())
        assertFalse("No settings entry → no staged settings, no error", stagedSettings.exists())
        assertTrue("Current backups always carry a manifest", stagedManifest.exists())
    }

    @Test fun legacySingleEntryZipStillStages() {
        val liveDb = fakeSqlite("legacy-rows")
        val backup = tmp.newFile("legacy.noopbak")
        ZipOutputStream(backup.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("noop-backup.sqlite"))
            zip.write(liveDb.readBytes())
            zip.closeEntry()
        }

        val stagedDb = tmp.newFile()
        val stagedSettings = File(tmp.root, "legacy-settings.json")
        val stagedManifest = File(tmp.root, "legacy-manifest.json")
        val result = DataBackup.stageBackupSqlite(
            backup.inputStream(),
            DataBackup.peekHeader(backup),
            stagedDb,
            stagedSettings,
            stagedManifest,
        )

        assertEquals(DataBackup.StageResult.OK, result)
        assertEquals(liveDb.readBytes().toList(), stagedDb.readBytes().toList())
        assertFalse(stagedSettings.exists())
        assertFalse(stagedManifest.exists())
    }

    @Test fun stagingWithoutSettingsDestStillWorksAsBefore() {
        // The pre-#1000 call shape (no settingsDest) keeps working for a 2-entry zip.
        val liveDb = fakeSqlite("rows2")
        val backup = tmp.newFile("two-entry.noopbak")
        DataBackup.writeBackupZip(liveDb, backup, """{"profile.age":30}""")

        val stagedDb = tmp.newFile()
        val result = DataBackup.stageBackupSqlite(backup.inputStream(), DataBackup.peekHeader(backup), stagedDb)
        assertEquals(DataBackup.StageResult.OK, result)
        assertEquals(liveDb.readBytes().toList(), stagedDb.readBytes().toList())
    }

    @Test fun zipWithNonCanonicalSqliteEntryIsRejected() {
        val backup = tmp.newFile("wrong-entry.noopbak")
        ZipOutputStream(backup.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("evil.sqlite"))
            zip.write(sqliteMagic)
            zip.write("rows".toByteArray())
            zip.closeEntry()
        }

        val stagedDb = tmp.newFile()
        val result = DataBackup.stageBackupSqlite(
            backup.inputStream(), DataBackup.peekHeader(backup), stagedDb,
        )

        assertEquals(DataBackup.StageResult.NO_DB_IN_ZIP, result)
    }

    @Test fun duplicateCanonicalBasenamesAreRejected() {
        val backup = tmp.newFile("duplicate.noopbak")
        ZipOutputStream(backup.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("noop-backup.sqlite"))
            zip.write(sqliteMagic)
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("nested/noop-backup.sqlite"))
            zip.write(sqliteMagic)
            zip.closeEntry()
        }

        val stagedDb = tmp.newFile()
        assertEquals(
            DataBackup.StageResult.DUPLICATE_ENTRY,
            DataBackup.stageBackupSqlite(
                backup.inputStream(),
                DataBackup.peekHeader(backup),
                stagedDb,
            ),
        )
    }
}
