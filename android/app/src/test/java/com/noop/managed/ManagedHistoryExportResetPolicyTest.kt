package com.noop.managed

import java.io.File
import java.io.IOException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedHistoryExportResetPolicyTest {
    @Test
    fun unusableCheckpointErrorsClearExportState() {
        val errors = listOf(
            ManagedHistoryExportStateException(
                IOException("synthetic staged-state failure"),
            ),
            ManagedStorageException.InvalidResponse(),
            ManagedStorageException.CursorExpired(null),
            ManagedStorageException.NotFound(),
            ManagedStorageException.Conflict(),
            ManagedStorageException.DigestMismatch(),
        )

        errors.forEach { error ->
            assertTrue(managedHistoryExportNeedsReset(error))
        }
    }

    @Test
    fun retryableAndAuthorizationErrorsPreserveExportState() {
        val errors = listOf(
            ManagedStorageException.Network(),
            ManagedStorageException.Authentication(),
            ManagedStorageException.Forbidden(),
            ManagedStorageException.PolicyChanged(),
            ManagedStorageException.QuotaExceeded(),
            ManagedStorageException.Server(503),
        )

        errors.forEach { error ->
            assertFalse(managedHistoryExportNeedsReset(error))
        }
    }

    @Test
    fun serviceBoundaryClearsCorruptStateAndPreservesOutputFailure() {
        var retryState: String? = "checkpoint-and-staged-entries"
        val stagedError = ManagedHistoryExportStateException(
            IOException("synthetic staged-state failure"),
        )

        val reset = applyManagedHistoryExportRecovery(
            error = stagedError,
            boundary = ManagedHistoryExportFailureBoundary.STAGED_STATE,
            clearExport = { retryState = null },
        )

        assertTrue(reset)
        assertNull(retryState)

        retryState = "checkpoint-and-staged-entries"
        val preserved = applyManagedHistoryExportRecovery(
            error = IOException("synthetic local output failure"),
            boundary = ManagedHistoryExportFailureBoundary.LOCAL_ARCHIVE_OUTPUT,
            clearExport = { retryState = null },
        )

        assertFalse(preserved)
        assertNotNull(retryState)
    }

    @Test
    fun localOutputBoundaryPreservesEvenArchiveLikeFailures() {
        val errors = listOf(
            ManagedHistoryExportStateException(
                IOException("synthetic local archive failure"),
            ),
            ManagedStorageException.InvalidResponse(),
            IOException("synthetic local filesystem failure"),
        )

        errors.forEach { error ->
            assertFalse(
                managedHistoryExportNeedsReset(
                    error,
                    ManagedHistoryExportFailureBoundary.LOCAL_ARCHIVE_OUTPUT,
                ),
            )
        }
    }

    @Test
    fun servicePublishesValidatedBytesWithoutAValidateThenWriteGap() {
        val service = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        val writer = source(
            "src/main/java/com/noop/managed/ManagedHistoryArchiveWriter.kt",
            "app/src/main/java/com/noop/managed/ManagedHistoryArchiveWriter.kt",
            "android/app/src/main/java/com/noop/managed/ManagedHistoryArchiveWriter.kt",
        )

        assertNotNull(service)
        assertNotNull(writer)
        assertFalse(service!!.contains("transfer.validateExport(manifest)"))
        assertTrue(service.contains("transfer.publishExport(destination, manifest)"))
        assertTrue(service.contains("catch (error: ManagedHistoryExportStateException)"))
        assertTrue(writer!!.contains("ManagedDigest.sha256(data) != chunk.sha256"))
        assertTrue(writer.contains("ManagedDigest.sha256(data) != document.archiveSha256"))
        assertTrue(writer.contains("writer.add("))
    }

    private fun source(vararg candidates: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return candidates
            .map { File(root, it) }
            .firstOrNull(File::isFile)
            ?.readText()
    }
}
