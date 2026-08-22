package com.noop.data

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupManifestTest {
    @Test fun roundTripAndPayloadValidation() {
        val dir = Files.createTempDirectory("noop-manifest").toFile()
        val database = File(dir, "noop-backup.sqlite").apply {
            writeBytes("SQLite format 3\u0000rows".toByteArray())
        }
        val settingsBytes =
            """{"settings.schemaVersion":2,"profile.age":34}""".toByteArray()
        val settings = File(dir, "settings.json").apply { writeBytes(settingsBytes) }
        val manifest = BackupManifest.create(
            databaseFile = database,
            databaseEntryName = "noop-backup.sqlite",
            settingsBytes = settingsBytes,
            settingsEntryName = "settings.json",
            createdAtEpochMs = 1_787_376_000_000,
            sourcePlatform = BackupManifest.PLATFORM_ANDROID,
            databaseEngine = BackupManifest.ENGINE_ROOM,
            databaseSchemaVersion = 31,
            settingsSchemaVersion = 2,
            appVersion = "9.2.0",
        )
        val decoded = requireNotNull(BackupManifest.decode(manifest.encode()))

        assertEquals(manifest, decoded)
        assertNull(
            decoded.validationProblem(
                databaseFile = database,
                settingsFile = settings,
                expectedDatabaseEntryName = "noop-backup.sqlite",
                expectedSettingsEntryName = "settings.json",
                currentPlatform = BackupManifest.PLATFORM_ANDROID,
                currentDatabaseEngine = BackupManifest.ENGINE_ROOM,
                currentDatabaseSchemaVersion = 31,
            ),
        )
    }

    @Test fun tamperWrongPlatformAndFutureSchemaFail() {
        val dir = Files.createTempDirectory("noop-manifest-errors").toFile()
        val database = File(dir, "noop-backup.sqlite").apply { writeText("original") }
        val android = BackupManifest.create(
            database,
            "noop-backup.sqlite",
            null,
            "settings.json",
            1,
            BackupManifest.PLATFORM_ANDROID,
            BackupManifest.ENGINE_ROOM,
            31,
            null,
            null,
        )
        database.writeText("tampered")
        assertTrue(
            android.validationProblem(
                database,
                null,
                "noop-backup.sqlite",
                "settings.json",
                BackupManifest.PLATFORM_ANDROID,
                BackupManifest.ENGINE_ROOM,
                31,
            )?.contains("hash") == true,
        )

        database.writeText("original")
        val apple = BackupManifest.create(
            database,
            "noop-backup.sqlite",
            null,
            "settings.json",
            1,
            BackupManifest.PLATFORM_APPLE,
            BackupManifest.ENGINE_GRDB,
            41,
            null,
            null,
        )
        assertTrue(
            apple.validationProblem(
                database,
                null,
                "noop-backup.sqlite",
                "settings.json",
                BackupManifest.PLATFORM_ANDROID,
                BackupManifest.ENGINE_ROOM,
                31,
            )?.contains("Apple") == true,
        )

        val future = android.copy(databaseSchemaVersion = 32)
        assertTrue(
            future.validationProblem(
                database,
                null,
                "noop-backup.sqlite",
                "settings.json",
                BackupManifest.PLATFORM_ANDROID,
                BackupManifest.ENGINE_ROOM,
                31,
            )?.contains("newer") == true,
        )
    }

    @Test fun appleShapedJsonDecodesWithTheSharedWireKeys() {
        val json = """{"appVersion":"9.2.0","createdAtEpochMs":1787376000000,"databaseEngine":"grdb","databaseSchemaVersion":41,"format":"noop-backup","payloads":{"database":{"bytes":123,"path":"noop-backup.sqlite","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"settings":{"bytes":45,"path":"settings.json","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},"settingsSchemaVersion":2,"sourcePlatform":"apple","version":1}"""
        val manifest = requireNotNull(BackupManifest.decode(json))

        assertEquals(BackupManifest.PLATFORM_APPLE, manifest.sourcePlatform)
        assertEquals(BackupManifest.ENGINE_GRDB, manifest.databaseEngine)
        assertEquals(41, manifest.databaseSchemaVersion)
        assertEquals(2, manifest.settingsSchemaVersion)
        assertEquals("noop-backup.sqlite", manifest.payloads.database.path)
        assertEquals("settings.json", manifest.payloads.settings?.path)
    }
}
