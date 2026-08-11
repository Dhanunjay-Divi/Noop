package com.noop.data

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupEnvelopeTest {
    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test fun pbkdf2VectorMatchesRfc6070Sha256Variant() {
        assertEquals(
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            BackupEnvelope.pbkdf2HmacSha256("password".toByteArray(), "salt".toByteArray(), 1).hex(),
        )
    }

    @Test fun deterministicEnvelopeMatchesAppleGolden() {
        val dir = Files.createTempDirectory("noop-envelope").toFile()
        val source = File(dir, "plain.zip")
        source.writeBytes(ByteArray(65_553) { ((it * 31 + 7) and 0xff).toByte() })
        val encrypted = File(dir, "golden.noopbak")
        BackupEnvelope.encrypt(
            source, encrypted, "golden backup phrase",
            BackupEnvelope.Parameters(
                iterations = 100_000,
                chunkBytes = 65_536,
                salt = ByteArray(16) { it.toByte() },
                noncePrefix = ByteArray(8) { (0xa0 + it).toByte() },
            ),
        )
        assertEquals(
            "4e4f4f5042414b0001010100000186a0000100000000000000010011000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7000000000000000000000000",
            encrypted.readBytes().copyOf(64).hex(),
        )
        assertEquals(
            "e84759fc93d512cc67596ae665e33ab32ef6ba7ebfc403aaa4eaaba2f6a455dc",
            MessageDigest.getInstance("SHA-256").digest(encrypted.readBytes()).hex(),
        )
        val restored = File(dir, "restored.zip")
        BackupEnvelope.decrypt(encrypted, restored, "golden backup phrase")
        assertArrayEquals(source.readBytes(), restored.readBytes())
    }

    @Test fun wrongPassphraseTamperAndTrailingDataFailWithoutPublishing() {
        val dir = Files.createTempDirectory("noop-envelope-errors").toFile()
        val source = File(dir, "plain.zip").apply { writeBytes(ByteArray(70_000) { it.toByte() }) }
        val encrypted = File(dir, "source.noopbak")
        BackupEnvelope.encrypt(source, encrypted, "a secure passphrase")

        val target = File(dir, "target.zip").apply { writeText("keep me") }
        assertTrue(runCatching { BackupEnvelope.decrypt(encrypted, target, "wrong passphrase") }.isFailure)
        assertEquals("keep me", target.readText())

        val tampered = File(dir, "tampered.noopbak").apply { writeBytes(encrypted.readBytes()) }
        val bytes = tampered.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); tampered.writeBytes(bytes)
        assertTrue(runCatching { BackupEnvelope.decrypt(tampered, target, "a secure passphrase") }.isFailure)
        assertEquals("keep me", target.readText())

        val truncated = File(dir, "truncated.noopbak").apply {
            writeBytes(encrypted.readBytes().dropLast(1).toByteArray())
        }
        assertTrue(runCatching { BackupEnvelope.decrypt(truncated, target, "a secure passphrase") }.isFailure)
        assertEquals("keep me", target.readText())

        val trailing = File(dir, "trailing.noopbak").apply { writeBytes(encrypted.readBytes() + 0x42.toByte()) }
        assertTrue(runCatching { BackupEnvelope.decrypt(trailing, target, "a secure passphrase") }.isFailure)
        assertEquals("keep me", target.readText())
        assertFalse(dir.listFiles().orEmpty().any { it.name.endsWith(".partial") })
    }

    @Test fun passphraseRequiresTwelveUnicodeCharacters() {
        assertTrue(BackupEnvelope.passphraseProblem("short") != null)
        assertEquals(null, BackupEnvelope.passphraseProblem("twelve chars!"))
    }

    @Test fun encryptedZipPayloadFeedsTheExistingValidatedStager() {
        val dir = Files.createTempDirectory("noop-envelope-container").toFile()
        val sqlite = File(dir, "source.sqlite").apply {
            writeBytes("SQLite format 3\u0000".toByteArray(Charsets.US_ASCII) + ByteArray(4096))
        }
        val zip = File(dir, "payload.zip")
        DataBackup.writeBackupZip(sqlite, zip, "{\"massKg\":72.5}")
        val envelope = File(dir, "backup.noopbak")
        BackupEnvelope.encrypt(zip, envelope, "portable passphrase")
        val decrypted = File(dir, "decrypted.zip")
        BackupEnvelope.decrypt(envelope, decrypted, "portable passphrase")
        val stagedDb = File(dir, "staged.sqlite")
        val stagedSettings = File(dir, "settings.json")
        assertEquals(
            DataBackup.StageResult.OK,
            DataBackup.stageBackupSqlite(
                decrypted.inputStream(), DataBackup.peekHeader(decrypted), stagedDb, stagedSettings,
            ),
        )
        assertArrayEquals(sqlite.readBytes(), stagedDb.readBytes())
        assertEquals("{\"massKg\":72.5}", stagedSettings.readText())
    }
}
