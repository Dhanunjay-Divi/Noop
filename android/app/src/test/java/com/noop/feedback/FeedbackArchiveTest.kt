package com.noop.feedback

import com.noop.AppDiagnosticsRecorder
import com.noop.testcentre.DisplayScreenshot
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FeedbackArchiveTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun reviewBoundaryExcludesRawAnrButRejectsEveryOtherUnknownEntry() {
        val prepared = FeedbackArchive.prepareForReview(
            baseEntries() + listOf(
                AppDiagnosticsRecorder.EXIT_HISTORY_ENTRY to
                    """{"reason":"anr","importance":"foreground"}""".toByteArray(),
                AppDiagnosticsRecorder.LAST_ANR_ENTRY to
                    "unreviewed Android trace".toByteArray(),
            ),
        )

        assertEquals(1, prepared.excludedUnsafeEntryCount)
        assertTrue(
            prepared.entries.any { it.first == AppDiagnosticsRecorder.EXIT_HISTORY_ENTRY },
        )
        assertFalse(
            prepared.entries.any { it.first == AppDiagnosticsRecorder.LAST_ANR_ENTRY },
        )

        assertRejected(FeedbackArchiveException.Reason.UNKNOWN_ENTRY) {
            FeedbackArchive.prepareForReview(
                baseEntries() + ("future-debug.txt" to "unknown".toByteArray()),
            )
        }
    }

    @Test
    fun rejectsTraversalDuplicatesAndRawHealthOrDatabaseNames() {
        assertRejected(FeedbackArchiveException.Reason.UNSAFE_ENTRY_NAME) {
            FeedbackArchive.prepareForReview(
                baseEntries() + ("../meta.json" to "{}".toByteArray()),
            )
        }
        assertRejected(FeedbackArchiveException.Reason.DUPLICATE_ENTRY) {
            FeedbackArchive.prepareForReview(
                baseEntries() + ("REPORT.TXT" to "duplicate".toByteArray()),
            )
        }
        listOf(
            "wearable.sqlite",
            "health.db",
            "raw-capture.jsonl",
            "sensor-history.txt",
        ).forEach { name ->
            assertRejected(FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE) {
                FeedbackArchive.prepareForReview(
                    baseEntries() + (name to "private".toByteArray()),
                )
            }
        }
    }

    @Test
    fun rejectsDatabaseContentEvenWhenRenamedAsReviewedText() {
        assertRejected(FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE) {
            FeedbackArchive.prepareForReview(
                listOf(
                    "report.txt" to
                        "SQLite format 3\u0000private rows".toByteArray(Charsets.US_ASCII),
                    "meta.json" to "{\"schema\":1}".toByteArray(),
                ),
            )
        }
    }

    @Test
    fun sealedArchiveFreezesConsentAndSourceBytes() {
        val note = "User-provided context (optional)\n\nScrolling stalled\n".toByteArray()
        val screenshot = validPng()
        val entries = baseEntries() + listOf(
            "user-note.txt" to note,
            DisplayScreenshot.BUNDLE_NAME to screenshot,
        )
        val destination = File(temporary.newFolder("outbox"), "archive.zip")
        val descriptor = FeedbackArchive.writeImmutable(
            destination = destination,
            entries = entries,
            includesUserNote = true,
            includesScreenshot = true,
        )
        val originalDigest = descriptor.sha256

        note.fill('x'.code.toByte())
        screenshot.fill(0)

        FeedbackArchive.validate(
            archive = destination,
            expectedBytes = descriptor.bytes,
            expectedSha256 = originalDigest,
            includesUserNote = true,
            includesScreenshot = true,
        )
        assertEquals(originalDigest, FeedbackArchive.sha256(destination))
        assertRejected(FeedbackArchiveException.Reason.CONSENT_MISMATCH) {
            FeedbackArchive.validate(
                archive = destination,
                expectedBytes = descriptor.bytes,
                expectedSha256 = originalDigest,
                includesUserNote = false,
                includesScreenshot = true,
            )
        }
    }

    @Test
    fun reviewBoundaryStripsScreenshotMetadataBeforeShowingAttachment() {
        val prepared = FeedbackArchive.prepareForReview(
            baseEntries() + (
                DisplayScreenshot.BUNDLE_NAME to
                    FeedbackScreenshotFixture.rawMetadataBearing
                ),
        )

        assertArrayEquals(
            FeedbackScreenshotFixture.sanitized,
            prepared.entries.single {
                it.first == DisplayScreenshot.BUNDLE_NAME
            }.second,
        )
    }

    @Test
    fun archiveValidationRejectsCaseFoldedDuplicateZipEntries() {
        val archive = File(temporary.newFolder("malicious"), "archive.zip")
        ZipOutputStream(FileOutputStream(archive)).use { zip ->
            listOf(
                "report.txt" to "report",
                "REPORT.TXT" to "duplicate",
                "meta.json" to "{}",
            ).forEach { (name, value) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(value.toByteArray())
                zip.closeEntry()
            }
        }

        assertRejected(FeedbackArchiveException.Reason.DUPLICATE_ENTRY) {
            FeedbackArchive.validate(
                archive = archive,
                expectedBytes = archive.length(),
                expectedSha256 = null,
                includesUserNote = false,
                includesScreenshot = false,
            )
        }
    }

    @Test
    fun digestChangeFailsClosedBeforeUpload() {
        val destination = File(temporary.newFolder("digest"), "archive.zip")
        val descriptor = FeedbackArchive.writeImmutable(
            destination = destination,
            entries = baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        destination.setWritable(true)
        destination.appendBytes(byteArrayOf(0))

        assertRejected(FeedbackArchiveException.Reason.ARCHIVE_TOO_LARGE) {
            FeedbackArchive.validate(
                archive = destination,
                expectedBytes = descriptor.bytes,
                expectedSha256 = descriptor.sha256,
                includesUserNote = false,
                includesScreenshot = false,
            )
        }
    }

    private fun baseEntries(): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP app runtime report\n".toByteArray(),
        "meta.json" to "{\"schema\":1}".toByteArray(),
    )

    private fun validPng(): ByteArray =
        FeedbackScreenshotFixture.sanitized.copyOf()

    private fun assertRejected(
        expected: FeedbackArchiveException.Reason,
        block: () -> Unit,
    ) {
        try {
            block()
            fail("Expected archive rejection: ${expected.wireValue}")
        } catch (error: FeedbackArchiveException) {
            assertEquals(expected, error.reason)
        }
    }
}
