package com.noop.feedback

import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FeedbackOutboxTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun automaticAttemptLimitMatchesApple() {
        assertEquals(8, FeedbackOutbox.MAX_ATTEMPTS)
    }

    @Test
    fun metadataContainsOnlyBoundedProtocolStateAndFrozenConsent() {
        val filesDir = temporary.newFolder("files")
        val outbox = deterministicOutbox(filesDir)
        val note = "User-provided context (optional)\n\nUI stalled\n".toByteArray()
        val record = outbox.stage(
            entries = baseEntries() + ("user-note.txt" to note),
            includesUserNote = true,
            includesScreenshot = false,
        )
        note.fill('x'.code.toByte())

        assertTrue(record.includesUserNote)
        assertFalse(record.includesScreenshot)
        val stateFile = stateFile(filesDir, record.localId)
        val json = JSONObject(stateFile.readText())
        assertEquals(
            setOf(
                "local_id",
                "request_id",
                "server_report_id",
                "server_report_token",
                "identity_subject_sha256",
                "archive_sha256",
                "archive_bytes",
                "includes_user_note",
                "includes_screenshot",
                "created_at_millis",
                "updated_at_millis",
                "state",
                "attempt",
                "cancellation_attempt",
                "failure_category",
                "retained_until",
                "receipt",
                "local_archive_removed",
            ),
            json.keys().asSequence().toSet(),
        )
        val persisted = stateFile.readText()
        listOf(
            "UI stalled",
            "archive.zip",
            "signed_url",
            "response",
            "health_value",
        ).forEach { forbidden ->
            assertFalse("metadata leaked $forbidden", persisted.contains(forbidden))
        }
        assertTrue(json.isNull("receipt"))
        assertTrue(json.isNull("retained_until"))
        FeedbackArchive.validate(
            archive = outbox.archive(record),
            expectedBytes = record.archiveBytes,
            expectedSha256 = record.archiveSha256,
            includesUserNote = true,
            includesScreenshot = false,
        )
    }

    @Test
    fun recoveryConvertsInterruptedUploadToDurableRetry() {
        val filesDir = temporary.newFolder("recovery")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)

        val recovered = FeedbackOutbox(filesDir).recover().single()

        assertEquals(FeedbackState.RETRY_SCHEDULED, recovered.state)
        assertEquals(FeedbackFailureCategory.INTERRUPTED, recovered.failureCategory)
        assertEquals(1, recovered.attempt)
        assertTrue(outbox.archive(recovered).isFile)
    }

    @Test
    fun outboxRejectsFourthActiveReportAndRemainsBounded() {
        val filesDir = temporary.newFolder("bounded")
        val outbox = deterministicOutbox(filesDir)
        repeat(FeedbackOutbox.MAX_RECORDS) {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
        }

        try {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
            fail("Expected bounded outbox rejection")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.FULL, error.reason)
        }
        assertEquals(FeedbackOutbox.MAX_RECORDS, outbox.recover().size)
    }

    @Test
    fun recoveryPreservesExistingConsentedReportsWhenAlreadyOverCapacity() {
        val filesDir = temporary.newFolder("over-capacity-recovery")
        val outbox = deterministicOutbox(filesDir)
        val existing = List(FeedbackOutbox.MAX_RECORDS) {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
        }
        val sourceDirectory = stateFile(filesDir, existing.first().localId).parentFile!!
        val extraId = UUID(0L, 100L).toString()
        val extraRequestId = UUID(0L, 101L).toString()
        val extraDirectory = File(sourceDirectory.parentFile, extraId)
        assertTrue(sourceDirectory.copyRecursively(extraDirectory))
        val extraState = File(extraDirectory, "state.json")
        extraState.writeText(
            JSONObject(extraState.readText())
                .put("local_id", extraId)
                .put("request_id", extraRequestId)
                .toString(),
        )

        val recovered = outbox.recover()

        assertEquals(FeedbackOutbox.MAX_RECORDS + 1, recovered.size)
        recovered.forEach { record ->
            assertEquals(FeedbackState.QUEUED, record.state)
            assertTrue(outbox.archive(record).isFile)
        }
        try {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
            fail("Recovery must preserve old consent and reject only the new report")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.FULL, error.reason)
        }
    }

    @Test
    fun sentTransitionDeletesArchiveAndPersistsBoundedReceipt() {
        val filesDir = temporary.newFolder("sent")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        val retainedUntil = "2026-10-12T00:00:00Z"
        val sent = commitSent(
            outbox = outbox,
            localId = staged.localId,
            receipt = receipt,
            retainedUntil = retainedUntil,
        )

        assertEquals(FeedbackState.SENT, sent.state)
        assertEquals(receipt, sent.receipt)
        assertEquals(retainedUntil, sent.retainedUntil)
        assertEquals(null, sent.serverReportToken)
        assertFalse(outbox.archive(sent).exists())
        now += 23L * 60L * 60L * 1_000L
        val recovered = deterministicOutbox(filesDir) { now }.recover().single()
        assertEquals(receipt, recovered.receipt)
        assertEquals(retainedUntil, recovered.retainedUntil)
        assertNotNull(outbox.load(sent.localId))
        assertTrue(stateFile(filesDir, sent.localId).readText().contains(receipt))

        now += 60L * 60L * 1_000L
        assertTrue(deterministicOutbox(filesDir) { now }.recover().isEmpty())
        assertFalse(stateFile(filesDir, sent.localId).exists())
    }

    @Test
    fun cancellationPersistedWhileCompletionResponseWaitsWinsAtomicCommit() {
        val filesDir = temporary.newFolder("completion-cancel-race")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        val completionResponseReady = CountDownLatch(1)
        val allowLocalCommit = CountDownLatch(1)
        val committed = AtomicReference<FeedbackCompletionCommit?>(null)
        val completionThread = thread(name = "feedback-completion-race") {
            completionResponseReady.countDown()
            if (allowLocalCommit.await(5, TimeUnit.SECONDS)) {
                committed.set(
                    outbox.commitCompletion(
                        localId = staged.localId,
                        receipt = receipt,
                        retainedUntil = "2026-10-12T00:00:00Z",
                    ),
                )
            }
        }

        assertTrue(completionResponseReady.await(5, TimeUnit.SECONDS))
        val canceling = outbox.requestCancel(staged.localId)
        allowLocalCommit.countDown()
        completionThread.join(5_000L)

        assertFalse(completionThread.isAlive)
        assertEquals(FeedbackState.CANCELING, canceling.state)
        val result = committed.get()
        assertTrue(result is FeedbackCompletionCommit.CancellationRequired)
        val preserved = requireNotNull(result).record
        assertEquals(FeedbackState.CANCELING, preserved.state)
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", preserved.serverReportId)
        assertEquals(reportToken, preserved.serverReportToken)
        assertEquals(null, preserved.receipt)
        assertEquals(null, preserved.retainedUntil)
        assertFalse(outbox.archive(preserved).exists())
    }

    @Test
    fun immutableFieldsAndInvalidStateTransitionsFailClosed() {
        val filesDir = temporary.newFolder("state")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.requestCancel(staged.localId)
        val canceled = outbox.markCanceled(staged.localId)
        assertEquals(FeedbackState.CANCELED, canceled.state)

        try {
            outbox.retry(staged.localId)
            fail("Terminal reports must not be retried")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.INVALID_TRANSITION, error.reason)
        }
    }

    @Test
    fun cancellationGetsFreshAttemptsAndSurvivesADeletedArchive() {
        val filesDir = temporary.newFolder("cancel-recovery")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = FeedbackOutbox.MAX_ATTEMPTS)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        val canceling = outbox.requestCancel(staged.localId)
        assertEquals(FeedbackState.CANCELING, canceling.state)
        assertEquals(FeedbackOutbox.MAX_ATTEMPTS, canceling.attempt)
        assertEquals(0, canceling.cancellationAttempt)
        assertFalse(outbox.archive(canceling).exists())

        val recovered = FeedbackOutbox(filesDir).recover().single()
        assertEquals(FeedbackState.CANCELING, recovered.state)
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", recovered.serverReportId)
        assertEquals(reportToken, recovered.serverReportToken)
        assertFalse(outbox.archive(recovered).exists())
    }

    @Test
    fun cancellationPendingServerDeletionOutlivesOrdinaryActiveRetention() {
        val filesDir = temporary.newFolder("cancel-retention")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )
        outbox.requestCancel(staged.localId)
        val pending = outbox.scheduleCancelRetry(
            staged.localId,
            FeedbackFailureCategory.DELETION_PENDING,
        )
        assertFalse(outbox.archive(pending).exists())

        now += 15L * 24L * 60L * 60L * 1_000L
        val recovered = outbox.recover().single()

        assertEquals(FeedbackState.CANCEL_RETRY_SCHEDULED, recovered.state)
        assertEquals(FeedbackFailureCategory.DELETION_PENDING, recovered.failureCategory)
        assertEquals(reportToken, recovered.serverReportToken)
        assertFalse(outbox.archive(recovered).exists())
    }

    @Test
    fun latestVisibleIgnoresTerminalReceiptAndAllowsANewReport() {
        val filesDir = temporary.newFolder("latest-actionable")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )
        commitSent(
            outbox = outbox,
            localId = staged.localId,
            receipt = receipt,
            retainedUntil = "2026-10-12T00:00:00Z",
        )

        assertEquals(null, outbox.latestVisible())
        val next = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        assertEquals(next.localId, outbox.latestVisible()?.localId)
    }

    @Test
    fun activeRecordsExpireAfterFourteenDays() {
        val filesDir = temporary.newFolder("active-retention")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        assertNotNull(outbox.load(staged.localId))

        now += 14L * 24L * 60L * 60L * 1_000L

        assertTrue(outbox.recover().isEmpty())
        assertFalse(stateFile(filesDir, staged.localId).exists())
    }

    @Test
    fun expiredServerBoundRecordBecomesDurableCancellation() {
        val filesDir = temporary.newFolder("server-bound-active-retention")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        now += 14L * 24L * 60L * 60L * 1_000L
        val recovered = outbox.recover().single()

        assertEquals(FeedbackState.CANCELING, recovered.state)
        assertEquals(1, recovered.attempt)
        assertEquals(0, recovered.cancellationAttempt)
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", recovered.serverReportId)
        assertEquals(reportToken, recovered.serverReportToken)
        assertFalse(outbox.archive(recovered).exists())

        now += 30L * 24L * 60L * 60L * 1_000L
        val stillPending = outbox.recover().single()
        assertEquals(FeedbackState.CANCELING, stillPending.state)
        assertEquals(reportToken, stillPending.serverReportToken)
    }

    @Test
    fun terminalHistoryKeepsOnlyTwoNewestRecordsForTwentyFourHours() {
        val filesDir = temporary.newFolder("terminal-history")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val receipts = listOf(
            "NF-ABCDEFGHIJKLMNOP",
            "NF-BCDEFGHIJKLMNOPQ",
            "NF-CDEFGHIJKLMNOPQR",
        )
        val records = receipts.mapIndexed { index, terminalReceipt ->
            now += 1_000L
            val staged = outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
            outbox.beginUpload(staged.localId, attempt = 1)
            saveTestReservation(
                outbox,
                staged.localId,
                serverReportId = UUID(0L, 1_000L + index).toString(),
            )
            commitSent(
                outbox = outbox,
                localId = staged.localId,
                receipt = terminalReceipt,
                retainedUntil = "2026-10-12T00:00:00Z",
            )
        }

        val recovered = outbox.recover()

        assertEquals(2, recovered.size)
        assertEquals(receipts.takeLast(2).toSet(), recovered.mapNotNull { it.receipt }.toSet())
        assertFalse(stateFile(filesDir, records.first().localId).exists())
        recovered.forEach { assertEquals(FeedbackState.SENT, it.state) }
    }

    @Test
    fun newlyTerminalRecordKeepsItsFullTwentyFourHourReceiptWindow() {
        val filesDir = temporary.newFolder("terminal-age-precedence")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )
        now += 14L * 24L * 60L * 60L * 1_000L
        commitSent(
            outbox = outbox,
            localId = staged.localId,
            receipt = receipt,
            retainedUntil = "2026-10-12T00:00:00Z",
        )

        now += 23L * 60L * 60L * 1_000L
        assertEquals(receipt, outbox.recover().single().receipt)

        now += 60L * 60L * 1_000L
        assertTrue(outbox.recover().isEmpty())
    }

    @Test
    fun transientStateReadFailurePreservesTheConsentedReportForRecovery() {
        val filesDir = temporary.newFolder("transient-state-read")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val state = stateFile(filesDir, staged.localId)
        val archive = outbox.archive(staged)
        val unavailable = FeedbackOutbox(
            filesDir = filesDir,
            stateReader = {
                if (it == state) throw IOException("synthetic read failure")
                it.readText()
            },
        )

        try {
            unavailable.recover()
            fail("A transient state read must be deferred, not treated as invalid")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.STATE_UNAVAILABLE, error.reason)
        }

        assertTrue(state.isFile)
        assertTrue(archive.isFile)
        assertEquals(staged.localId, FeedbackOutbox(filesDir).recover().single().localId)
    }

    @Test
    fun transientStateMetadataFailurePreservesTheConsentedReportForRecovery() {
        val filesDir = temporary.newFolder("transient-state-metadata")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val state = stateFile(filesDir, staged.localId)
        val archive = outbox.archive(staged)
        val unavailable = FeedbackOutbox(
            filesDir = filesDir,
            stateMetadataReader = {
                if (it == state) throw IOException("synthetic metadata failure")
                FeedbackStateFileMetadata(isRegularFile = it.isFile, size = it.length())
            },
        )

        try {
            unavailable.recover()
            fail("A transient metadata failure must be deferred, not treated as missing")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.STATE_UNAVAILABLE, error.reason)
        }

        assertTrue(state.isFile)
        assertTrue(archive.isFile)
        assertEquals(staged.localId, FeedbackOutbox(filesDir).recover().single().localId)
    }

    @Test
    fun terminalArchiveCleanupFailureIsPersistedAndRetried() {
        val filesDir = temporary.newFolder("terminal-cleanup-retry")
        var allowDeletion = false
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
            archiveDeleter = { archive -> allowDeletion && archive.delete() },
        )
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        val sent = commitSent(
            outbox = outbox,
            localId = staged.localId,
            receipt = receipt,
            retainedUntil = "2026-10-12T00:00:00Z",
        )

        assertFalse(sent.localArchiveRemoved)
        assertTrue(outbox.archive(sent).isFile)
        allowDeletion = true

        val recovered = outbox.recover().single()
        assertTrue(recovered.localArchiveRemoved)
        assertFalse(outbox.archive(recovered).exists())
    }

    @Test
    fun cancellationPreservesUploadAmbiguityAndUsesAnIndependentRetryBudget() {
        val filesDir = temporary.newFolder("cancel-ambiguity")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)

        val canceling = outbox.requestCancel(staged.localId)

        assertEquals(1, canceling.attempt)
        assertEquals(0, canceling.cancellationAttempt)
        assertTrue(FeedbackCancellationPolicy.requiresReservationReconciliation(canceling))

        val attempted = outbox.noteCancelAttempt(canceling.localId, attempt = 1)
        assertEquals(1, attempted.attempt)
        assertEquals(1, attempted.cancellationAttempt)
    }

    @Test
    fun stateTimestampsStayMonotonicWhenTheWallClockMovesBackward() {
        val filesDir = temporary.newFolder("clock-rollback")
        var now = 2_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        now = 3_000L
        val uploading = outbox.beginUpload(staged.localId, attempt = 1)
        now = 2_500L

        val canceling = outbox.requestCancel(staged.localId)

        assertEquals(3_000L, uploading.updatedAtMillis)
        assertEquals(uploading.updatedAtMillis, canceling.updatedAtMillis)
        assertTrue(FeedbackRuntimeStatusPolicy.shouldPublish(uploading, canceling))
    }

    @Test
    fun legacyServerReservationWithoutOwnerHashFailsClosedBeforeRemoteContact() {
        val filesDir = temporary.newFolder("legacy-owner-continuity")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        saveTestReservation(
            outbox,
            staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )
        val state = stateFile(filesDir, staged.localId)
        val legacy = JSONObject(state.readText())
        legacy.remove("identity_subject_sha256")
        legacy.remove("cancellation_attempt")
        legacy.remove("local_archive_removed")
        state.writeText(legacy.toString())

        val recovered = outbox.load(staged.localId)!!

        assertEquals(null, recovered.identitySubjectSha256)
        assertFalse(FeedbackIdentityContinuityPolicy.canContactRemote(recovered))
        assertTrue(outbox.archive(recovered).isFile)
    }

    @Test
    fun persistedIdentityBindingCannotRotateAcrossWorkerAttempts() {
        val filesDir = temporary.newFolder("identity-binding")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.bindIdentity(staged.localId, identitySubjectSha256)

        try {
            outbox.bindIdentity(
                staged.localId,
                feedbackIdentitySubjectSha256("replacement-feedback-owner"),
            )
            fail("A staged report must remain bound to one anonymous identity")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.INVALID_RECORD, error.reason)
        }
    }

    @Test
    fun persistedServerCredentialsFailClosedToExactProtocolGrammar() {
        val filesDir = temporary.newFolder("credential-validation")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val state = stateFile(filesDir, staged.localId)
        val json = JSONObject(state.readText())
            .put("server_report_id", "not-a-uuid")
            .put("server_report_token", "a".repeat(39))
        state.writeText(json.toString())

        assertTrue(outbox.recover().isEmpty())
        assertFalse(state.parentFile?.exists() == true)
    }

    private fun deterministicOutbox(
        filesDir: File,
        nowMillis: () -> Long = { 1_789_000_000_000L },
    ): FeedbackOutbox {
        var next = 1L
        return FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = nowMillis,
        )
    }

    private fun baseEntries(): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP app runtime report\n".toByteArray(),
        "meta.json" to "{\"schema\":1}".toByteArray(),
    )

    private fun stateFile(filesDir: File, localId: String): File =
        File(filesDir, "feedback/outbox/$localId/state.json")

    private fun saveTestReservation(
        outbox: FeedbackOutbox,
        localId: String,
        serverReportId: String,
    ) {
        outbox.bindIdentity(localId, identitySubjectSha256)
        outbox.saveReservation(
            localId = localId,
            serverReportId = serverReportId,
            serverReportToken = reportToken,
        )
    }

    private fun commitSent(
        outbox: FeedbackOutbox,
        localId: String,
        receipt: String,
        retainedUntil: String,
    ): FeedbackRecord {
        val commit = outbox.commitCompletion(
            localId = localId,
            receipt = receipt,
            retainedUntil = retainedUntil,
        )
        assertTrue(commit is FeedbackCompletionCommit.Sent)
        return (commit as FeedbackCompletionCommit.Sent).record
    }

    private companion object {
        val reportToken = "v2." + "a".repeat(43)
        val identitySubjectSha256 = feedbackIdentitySubjectSha256("stable-feedback-owner")
        const val receipt = "NF-ABCDEFGHIJKLMNOP"
    }
}
