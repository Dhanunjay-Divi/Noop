package com.noop.feedback

import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipException
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
                "app_version",
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
                "clock_anomaly_observed_at_millis",
                "reservation_continuity_started_at_millis",
                "worker_generation",
                "retry_not_before_millis",
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
        assertTrue(json.isNull("clock_anomaly_observed_at_millis"))
        assertTrue(json.isNull("reservation_continuity_started_at_millis"))
        assertTrue(json.isNull("worker_generation"))
        assertTrue(json.isNull("retry_not_before_millis"))
        assertEquals("9.2.1", json.getString("app_version"))
        FeedbackArchive.validate(
            archive = outbox.archive(record),
            expectedBytes = record.archiveBytes,
            expectedSha256 = record.archiveSha256,
            includesUserNote = true,
            includesScreenshot = false,
        )
    }

    @Test
    fun stagedAppVersionSurvivesRecoveryForRetriesAfterAnUpgrade() {
        val filesDir = temporary.newFolder("app-version-recovery")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            entries = baseEntries(appVersion = "8.4.1"),
            includesUserNote = false,
            includesScreenshot = false,
        )

        val recovered = deterministicOutbox(filesDir).recover().single()

        assertEquals("8.4.1", staged.appVersion)
        assertEquals("8.4.1", recovered.appVersion)
        assertEquals(
            "8.4.1",
            JSONObject(stateFile(filesDir, staged.localId).readText())
                .getString("app_version"),
        )
    }

    @Test
    fun preFixStateHydratesOriginalAppVersionFromTheImmutableArchive() {
        val filesDir = temporary.newFolder("app-version-migration")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            entries = baseEntries(appVersion = "8.4.1"),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val state = stateFile(filesDir, staged.localId)
        state.writeText(
            JSONObject(state.readText())
                .apply {
                    remove("app_version")
                    remove("clock_anomaly_observed_at_millis")
                    remove("reservation_continuity_started_at_millis")
                    remove("worker_generation")
                    remove("retry_not_before_millis")
                }
                .toString(),
        )

        val recovered = deterministicOutbox(filesDir).recover().single()

        assertEquals("8.4.1", recovered.appVersion)
        val persisted = JSONObject(state.readText())
        assertEquals("8.4.1", persisted.getString("app_version"))
    }

    @Test
    fun previousSchemaAddsReservationContinuityFieldWithoutLosingState() {
        val filesDir = temporary.newFolder("reservation-continuity-migration")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            entries = baseEntries(appVersion = "8.4.1"),
            includesUserNote = false,
            includesScreenshot = false,
        )
        now += 60_000L
        outbox.bindIdentity(staged.localId, identitySubjectSha256)
        val state = stateFile(filesDir, staged.localId)
        state.writeText(
            JSONObject(state.readText())
                .apply {
                    remove("reservation_continuity_started_at_millis")
                    remove("worker_generation")
                    remove("retry_not_before_millis")
                }
                .toString(),
        )

        now += 60_000L
        val recovered = deterministicOutbox(filesDir) { now }.recover().single()

        assertEquals(staged.localId, recovered.localId)
        assertEquals("8.4.1", recovered.appVersion)
        assertEquals(staged.createdAtMillis, recovered.reservationContinuityStartedAtMillis)
        val persisted = JSONObject(state.readText())
        assertTrue(persisted.has("reservation_continuity_started_at_millis"))
        assertEquals(
            staged.createdAtMillis,
            persisted.getLong("reservation_continuity_started_at_millis"),
        )
    }

    @Test
    fun persistedAppVersionMustMatchTheImmutableArchive() {
        val filesDir = temporary.newFolder("app-version-integrity")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            entries = baseEntries(appVersion = "8.4.1"),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val state = stateFile(filesDir, staged.localId)
        state.writeText(
            JSONObject(state.readText())
                .put("app_version", "9.0.0")
                .toString(),
        )

        val recovered = outbox.recover()

        assertTrue(recovered.isEmpty())
        assertFalse(state.parentFile!!.exists())
    }

    @Test
    fun recoveryConvertsInterruptedUploadToDurableRetry() {
        val filesDir = temporary.newFolder("recovery")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        now += FeedbackReservationContinuityPolicy.activeWorkLeaseMillis

        val recovered = deterministicOutbox(filesDir) { now }.recover().single()

        assertEquals(FeedbackState.RETRY_SCHEDULED, recovered.state)
        assertEquals(FeedbackFailureCategory.INTERRUPTED, recovered.failureCategory)
        assertEquals(1, recovered.attempt)
        assertTrue(outbox.archive(recovered).isFile)
    }

    @Test
    fun continuityIdentityScanDoesNotInterruptLiveUpload() {
        val filesDir = temporary.newFolder("continuity-live-upload")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)

        assertEquals(
            setOf(identitySubjectSha256),
            outbox.reservationContinuityIdentitySubjectSha256s(),
        )
        assertEquals(
            FeedbackState.UPLOADING,
            outbox.load(staged.localId)?.state,
        )
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

        val recovered = deterministicOutbox(filesDir).recover().single()
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
        val expired = outbox.recover().single()
        assertEquals(FeedbackState.CANCEL_FAILED, expired.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            expired.failureCategory,
        )
        assertEquals(
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            expired.serverReportId,
        )
        assertEquals(reportToken, expired.serverReportToken)
        assertEquals(identitySubjectSha256, expired.identitySubjectSha256)
        assertTrue(expired.localArchiveRemoved)
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
        assertEquals(staged.localId, deterministicOutbox(filesDir).recover().single().localId)
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
        assertEquals(staged.localId, deterministicOutbox(filesDir).recover().single().localId)
    }

    @Test
    fun archiveReadFailureClassificationSeparatesCorruptionFromTransientIo() {
        assertEquals(
            FeedbackOutboxException.Reason.INVALID_RECORD,
            feedbackArchiveReadFailureReason(ZipException("synthetic corrupt zip")),
        )
        assertEquals(
            FeedbackOutboxException.Reason.STATE_UNAVAILABLE,
            feedbackArchiveReadFailureReason(IOException("synthetic transient read")),
        )
        assertFalse(
            feedbackArchiveValidationFailureIsRetryable(
                FeedbackArchiveException(
                    FeedbackArchiveException.Reason.DIGEST_MISMATCH,
                ),
            ),
        )
        assertTrue(
            feedbackArchiveValidationFailureIsRetryable(
                FeedbackArchiveException(
                    FeedbackArchiveException.Reason.WRITE_FAILED,
                ),
            ),
        )
        assertTrue(
            feedbackArchiveValidationFailureIsRetryable(
                IOException("synthetic transient validation read"),
            ),
        )
    }

    @Test
    fun transientArchiveValidationReadPreservesTheConsentedReportAndArchive() {
        val filesDir = temporary.newFolder("transient-archive-validation")
        var validationUnavailable = false
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            archiveValidator =
                { archive, expectedBytes, expectedSha256, includesUserNote,
                    includesScreenshot ->
                    if (validationUnavailable) {
                        throw IOException("synthetic validation read failure")
                    }
                    FeedbackArchive.validate(
                        archive = archive,
                        expectedBytes = expectedBytes,
                        expectedSha256 = expectedSha256,
                        includesUserNote = includesUserNote,
                        includesScreenshot = includesScreenshot,
                    )
                },
        )
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        validationUnavailable = true

        val deferred = outbox.recover().single()

        assertEquals(staged.localId, deferred.localId)
        assertEquals(FeedbackState.QUEUED, deferred.state)
        assertTrue(outbox.archive(deferred).isFile)
        validationUnavailable = false
        assertEquals(staged.localId, outbox.recover().single().localId)
    }

    @Test
    fun progressStateReadDoesNotRevalidateTheImmutableArchive() {
        val filesDir = temporary.newFolder("progress-state-read")
        var validationCount = 0
        var archiveMetadataReadCount = 0
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            archiveAppVersionReader = {
                archiveMetadataReadCount += 1
                "9.2.1"
            },
            archiveValidator =
                { archive, expectedBytes, expectedSha256, includesUserNote,
                    includesScreenshot ->
                    validationCount += 1
                    FeedbackArchive.validate(
                        archive = archive,
                        expectedBytes = expectedBytes,
                        expectedSha256 = expectedSha256,
                        includesUserNote = includesUserNote,
                        includesScreenshot = includesScreenshot,
                    )
                },
        )
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val generation = "11111111-2222-4333-8444-555555555555"
        outbox.prepareWorker(
            localId = staged.localId,
            replace = false,
            generation = generation,
        )
        validationCount = 0
        archiveMetadataReadCount = 0

        assertEquals(
            null,
            outbox.loadForProgress(
                localId = staged.localId,
                expectedWorkerGeneration = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            ),
        )
        assertEquals(
            staged.localId,
            outbox.loadForProgress(
                localId = staged.localId,
                expectedWorkerGeneration = generation,
            )?.localId,
        )
        assertEquals(0, validationCount)
        assertEquals(0, archiveMetadataReadCount)
        assertEquals(staged.localId, outbox.load(staged.localId)?.localId)
        assertTrue(validationCount > 0)
        assertTrue(archiveMetadataReadCount > 0)
    }

    @Test
    fun transientArchiveReadFailurePreservesTheConsentedReportForRecovery() {
        val filesDir = temporary.newFolder("transient-archive-read")
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
            archiveAppVersionReader = {
                throw FeedbackOutboxException(
                    FeedbackOutboxException.Reason.STATE_UNAVAILABLE,
                )
            },
        )

        try {
            unavailable.recover()
            fail("A transient archive read must be deferred, not treated as invalid")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.STATE_UNAVAILABLE, error.reason)
        }

        assertTrue(state.isFile)
        assertTrue(archive.isFile)
        assertEquals(staged.localId, deterministicOutbox(filesDir).recover().single().localId)
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

        val repeated = outbox.requestCancel(staged.localId)
        assertEquals(1, repeated.cancellationAttempt)
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
        legacy.remove("app_version")
        legacy.remove("identity_subject_sha256")
        legacy.remove("cancellation_attempt")
        legacy.remove("local_archive_removed")
        legacy.remove("clock_anomaly_observed_at_millis")
        legacy.remove("reservation_continuity_started_at_millis")
        legacy.remove("worker_generation")
        legacy.remove("retry_not_before_millis")
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
    fun coordinatorTracksReservationContinuityBindings() {
        val filesDir = temporary.newFolder("identity-coordinator")
        val outbox = deterministicOutbox(filesDir)
        val active = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val bound = outbox.bindIdentity(active.localId, identitySubjectSha256)
        assertFalse(
            FeedbackReservationContinuityPolicy
                .requiresIdentityLifetimeCheck(bound),
        )

        val terminalIdentity =
            feedbackIdentitySubjectSha256("terminal-feedback-owner")
        val terminal = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        assertTrue(
            FeedbackReservationContinuityPolicy
                .requiresIdentityLifetimeCheck(terminal),
        )
        outbox.bindIdentity(terminal.localId, terminalIdentity)
        outbox.saveReservation(
            localId = terminal.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            serverReportToken = reportToken,
        )
        outbox.beginUpload(terminal.localId, attempt = 1)
        commitSent(
            outbox = outbox,
            localId = terminal.localId,
            receipt = receipt,
            retainedUntil = "2026-10-12T00:00:00Z",
        )

        assertEquals(
            setOf(identitySubjectSha256),
            outbox.reservationContinuityIdentitySubjectSha256s(),
        )
    }

    @Test
    fun schedulerFailureClearsPreparedGenerationsAndRemainsRetryable() {
        val filesDir = temporary.newFolder("scheduler-failure")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val deliveryGeneration = "11111111-2222-4333-8444-555555555555"
        val prepared = outbox.prepareWorker(
            localId = staged.localId,
            replace = false,
            generation = deliveryGeneration,
        )

        val failed = outbox.markFailed(
            localId = prepared.localId,
            failure = FeedbackFailureCategory.UNKNOWN,
            expectedWorkerGeneration = deliveryGeneration,
        )
        assertEquals(FeedbackState.FAILED, failed.state)
        assertEquals(null, failed.workerGeneration)
        assertEquals(FeedbackFailureCategory.UNKNOWN, failed.failureCategory)

        val cancelGeneration = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val canceling = outbox.requestCancel(
            localId = failed.localId,
            replacementWorkerGeneration = cancelGeneration,
        )
        val cancelFailed = outbox.markCancelFailed(
            localId = canceling.localId,
            failure = FeedbackFailureCategory.UNKNOWN,
            expectedWorkerGeneration = cancelGeneration,
        )
        assertEquals(FeedbackState.CANCEL_FAILED, cancelFailed.state)
        assertEquals(null, cancelFailed.workerGeneration)
        assertEquals(
            FeedbackState.CANCEL_FAILED,
            outbox.recover().single().state,
        )
    }

    @Test
    fun reservationContinuityDeadlineIsBoundedAndUsesServerRetention() {
        val created = 1_789_000_000_000L
        val retainedUntilMillis = created + TimeUnit.DAYS.toMillis(2)
        val base = feedbackRecord(
            state = FeedbackState.UPLOADING,
            attempt = 1,
            createdAtMillis = created,
            retainedUntil = java.time.Instant.ofEpochMilli(retainedUntilMillis).toString(),
        )
        val serverBoundDeadline =
            retainedUntilMillis +
                FeedbackReservationContinuityPolicy.expirySafetyMarginMillis

        assertEquals(
            serverBoundDeadline,
            FeedbackReservationContinuityPolicy.continuityDeadlineMillis(base),
        )
        assertEquals(
            setOf(identitySubjectSha256),
            FeedbackReservationContinuityPolicy
                .identitySubjectSha256sRequiringContinuity(
                    records = listOf(base),
                    nowMillis = serverBoundDeadline - 1L,
                ),
        )
        assertEquals(
            setOf(identitySubjectSha256),
            FeedbackReservationContinuityPolicy
                .identitySubjectSha256sRequiringContinuity(
                    records = listOf(base),
                    nowMillis = serverBoundDeadline,
                ),
        )

        val lateServerBound = base.copy(
            retainedUntil = java.time.Instant.ofEpochMilli(
                created + TimeUnit.DAYS.toMillis(90),
            ).toString(),
        )
        assertEquals(
            FeedbackReservationContinuityPolicy
                .maximumServerRetainedUntilMillis(lateServerBound) +
                FeedbackReservationContinuityPolicy.expirySafetyMarginMillis,
            FeedbackReservationContinuityPolicy
                .continuityDeadlineMillis(lateServerBound),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                record = lateServerBound,
                retainedUntilMillis = java.time.Instant.parse(
                    requireNotNull(lateServerBound.retainedUntil),
                ).toEpochMilli(),
                nowMillis = created,
            ),
        )
        assertTrue(
            FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                record = base,
                retainedUntilMillis = retainedUntilMillis,
                nowMillis = created,
            ),
        )

        val ambiguous = base.copy(
            serverReportId = null,
            serverReportToken = null,
            retainedUntil = null,
        )
        assertEquals(
            created +
                FeedbackReservationContinuityPolicy
                    .maximumAmbiguousBindingLifetimeMillis,
            FeedbackReservationContinuityPolicy
                .continuityDeadlineMillis(ambiguous),
        )
        val reservationCutoff = created +
            FeedbackReservationContinuityPolicy
                .maximumLocalDelayBeforeCancellationMillis
        assertTrue(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                ambiguous,
                reservationCutoff - 1L,
            ),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                ambiguous,
                reservationCutoff,
            ),
        )
        val futureUpdated = ambiguous.copy(
            updatedAtMillis =
                created +
                    FeedbackReservationContinuityPolicy.maximumClockSkewMillis +
                    1L,
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                futureUpdated,
                created,
            ),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                futureUpdated,
                created,
            ),
        )
        assertTrue(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                futureUpdated,
                futureUpdated.updatedAtMillis -
                    FeedbackReservationContinuityPolicy.maximumClockSkewMillis,
            ),
        )
    }

    @Test
    fun futureClockAnomalyRequiresBoundedRemoteCancellation() {
        val filesDir = temporary.newFolder("future-clock-anomaly")
        val observedAt = 1_789_000_000_000L
        val future = observedAt + TimeUnit.DAYS.toMillis(365)
        var now = future
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)

        now = observedAt
        val cancelling = outbox.recover().single()
        assertEquals(FeedbackState.CANCELING, cancelling.state)
        assertEquals(observedAt, cancelling.clockAnomalyObservedAtMillis)
        assertEquals(observedAt, cancelling.updatedAtMillis)
        assertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                cancelling,
                observedAt,
            ),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                cancelling,
                observedAt,
            ),
        )
        val deadline =
            observedAt +
                FeedbackReservationContinuityPolicy
                    .maximumAmbiguousBindingLifetimeMillis
        assertEquals(
            deadline,
            FeedbackReservationContinuityPolicy
                .continuityDeadlineMillis(cancelling),
        )

        now = deadline
        val unconfirmed = outbox.recover().single()
        assertEquals(FeedbackState.CANCEL_FAILED, unconfirmed.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            unconfirmed.failureCategory,
        )
        assertEquals(identitySubjectSha256, unconfirmed.identitySubjectSha256)
        assertTrue(unconfirmed.localArchiveRemoved)
        assertEquals(observedAt, unconfirmed.clockAnomalyObservedAtMillis)
    }

    @Test
    fun futureClockAnomalyRemovesNeverAttemptedLocalReport() {
        val filesDir = temporary.newFolder("future-local-clock-anomaly")
        val observedAt = 1_789_000_000_000L
        var now = observedAt + TimeUnit.DAYS.toMillis(365)
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )

        now = observedAt
        assertTrue(outbox.recover().isEmpty())
        assertFalse(stateFile(filesDir, staged.localId).exists())
    }

    @Test
    fun secondMaterialClockRollbackPreservesRemoteDeletionContinuity() {
        val filesDir = temporary.newFolder("second-clock-rollback")
        val observedAt = 1_789_000_000_000L
        var now = observedAt + TimeUnit.DAYS.toMillis(365)
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)
        outbox.saveReservation(
            localId = staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            serverReportToken = reportToken,
        )

        now = observedAt
        val canceling = outbox.recover().single()
        assertEquals(FeedbackState.CANCELING, canceling.state)
        now =
            observedAt -
                FeedbackReservationContinuityPolicy.maximumClockSkewMillis -
                1L
        assertTrue(
            FeedbackReservationContinuityPolicy.hasSecondaryClockRollback(
                canceling,
                now,
            ),
        )

        val preserved = outbox.recover().single()
        assertEquals(FeedbackState.CANCELING, preserved.state)
        assertEquals(identitySubjectSha256, preserved.identitySubjectSha256)
        assertEquals(
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            preserved.serverReportId,
        )
        assertEquals(reportToken, preserved.serverReportToken)
        assertTrue(preserved.localArchiveRemoved)
        assertTrue(preserved.cancellationAttempt == 0)
        assertTrue(
            FeedbackReservationContinuityPolicy.requiresContinuity(
                preserved,
                now,
            ),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.hasExpired(
                preserved,
                now,
            ),
        )
        assertEquals(now, preserved.clockAnomalyObservedAtMillis)

        val recoveredForward =
            now + FeedbackReservationContinuityPolicy.maximumClockSkewMillis + 10L
        now = recoveredForward
        val scheduled = outbox.scheduleCancelRetry(
            staged.localId,
            FeedbackFailureCategory.DELETION_PENDING,
        )
        assertEquals(recoveredForward, scheduled.updatedAtMillis)
        val laterRollback =
            recoveredForward -
                FeedbackReservationContinuityPolicy.maximumClockSkewMillis -
                1L
        assertTrue(
            FeedbackReservationContinuityPolicy.hasSecondaryClockRollback(
                scheduled,
                laterRollback,
            ),
        )
        now = laterRollback
        val normalizedAgain = outbox.recover().single()
        assertEquals(laterRollback, normalizedAgain.clockAnomalyObservedAtMillis)
        assertEquals(laterRollback, normalizedAgain.updatedAtMillis)
    }

    @Test
    fun reservationContinuityWaitDoesNotConsumeAutomaticAttempts() {
        val filesDir = temporary.newFolder("identity-continuity-wait")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val blocker = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(blocker.localId, attempt = 1)
        outbox.bindIdentity(blocker.localId, identitySubjectSha256)
        val waiting = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )

        repeat(12) {
            now += 1_000L
            outbox.beginUpload(waiting.localId, attempt = 1)
            val schedule = outbox.scheduleContinuityRetry(
                waiting.localId,
                FeedbackReservationAttemptLane.DELIVERY,
            )

            assertEquals(FeedbackState.RETRY_SCHEDULED, schedule.record.state)
            assertEquals(FeedbackFailureCategory.IDENTITY, schedule.record.failureCategory)
            assertEquals(0, schedule.record.attempt)
            assertEquals(
                FeedbackReservationContinuityPolicy.maximumRetryDelayMillis,
                schedule.delayMillis,
            )
        }
    }

    @Test
    fun reservationDrainPersistsServerRetryDelayWithoutConsumingAttempt() {
        val filesDir = temporary.newFolder("reservation-drain-retry-delay")
        val now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)

        val schedule = outbox.scheduleContinuityRetry(
            localId = staged.localId,
            lane = FeedbackReservationAttemptLane.DELIVERY,
            failure = FeedbackFailureCategory.SERVER_RETRYABLE,
            allowBoundIdentity = true,
            retryAfterMillis = 300_000L,
        )

        assertEquals(300_000L, schedule.delayMillis)
        assertEquals(now + 300_000L, schedule.record.retryNotBeforeMillis)
        assertEquals(0, schedule.record.attempt)
    }

    @Test
    fun boundReservationPendingRefundsAttemptAndPersistsRetryDeadlineAcrossRestart() {
        val filesDir = temporary.newFolder("bound-delivery-continuity-restart")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val firstGeneration = "11111111-2222-4333-8444-555555555555"
        val nextGeneration = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        outbox.prepareWorker(
            localId = staged.localId,
            replace = false,
            generation = firstGeneration,
        )
        outbox.beginUpload(
            localId = staged.localId,
            attempt = 1,
            expectedWorkerGeneration = firstGeneration,
        )
        outbox.bindIdentity(
            localId = staged.localId,
            identitySubjectSha256 = identitySubjectSha256,
            expectedWorkerGeneration = firstGeneration,
        )
        outbox.saveReservation(
            localId = staged.localId,
            serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            serverReportToken = reportToken,
            expectedWorkerGeneration = firstGeneration,
        )

        now += 1_000L
        val schedule = outbox.scheduleContinuityRetry(
            localId = staged.localId,
            lane = FeedbackReservationAttemptLane.DELIVERY,
            failure = FeedbackFailureCategory.DELETION_PENDING,
            allowBoundIdentity = true,
            expectedWorkerGeneration = firstGeneration,
            nextWorkerGeneration = nextGeneration,
        )

        assertEquals(FeedbackState.RETRY_SCHEDULED, schedule.record.state)
        assertEquals(0, schedule.record.attempt)
        assertEquals(
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            schedule.record.serverReportId,
        )
        assertEquals(reportToken, schedule.record.serverReportToken)
        assertEquals(identitySubjectSha256, schedule.record.identitySubjectSha256)
        assertEquals(nextGeneration, schedule.record.workerGeneration)
        assertEquals(
            now + schedule.delayMillis,
            schedule.record.retryNotBeforeMillis,
        )

        now += 250L
        val recovered = FeedbackOutbox(
            filesDir = filesDir,
            nowMillis = { now },
        ).recover().single()
        assertEquals(nextGeneration, recovered.workerGeneration)
        assertEquals(schedule.record.retryNotBeforeMillis, recovered.retryNotBeforeMillis)
        assertEquals(
            schedule.delayMillis - 250L,
            FeedbackScheduler.remainingRetryDelayMillis(recovered, now),
        )
    }

    @Test
    fun supersededWorkerCannotOverwriteReplacementStateOrAttempt() {
        val filesDir = temporary.newFolder("worker-generation-cas")
        val outbox = deterministicOutbox(filesDir)
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val firstGeneration = "11111111-2222-4333-8444-555555555555"
        val replacementGeneration = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        outbox.prepareWorker(
            localId = staged.localId,
            replace = false,
            generation = firstGeneration,
        )
        outbox.beginUpload(
            localId = staged.localId,
            attempt = 1,
            expectedWorkerGeneration = firstGeneration,
        )
        outbox.scheduleRetry(
            localId = staged.localId,
            failure = FeedbackFailureCategory.NETWORK,
            expectedWorkerGeneration = firstGeneration,
        )
        val replacement = outbox.retry(
            localId = staged.localId,
            replacementWorkerGeneration = replacementGeneration,
        )

        try {
            outbox.beginUpload(
                localId = staged.localId,
                attempt = 2,
                expectedWorkerGeneration = firstGeneration,
            )
            fail("A superseded worker must not mutate the replacement record")
        } catch (_: FeedbackWorkerSupersededException) {
            // Expected.
        }

        val current = outbox.load(staged.localId)!!
        assertEquals(FeedbackState.QUEUED, current.state)
        assertEquals(0, current.attempt)
        assertEquals(replacementGeneration, current.workerGeneration)
        assertEquals(replacement, current)
    }

    @Test
    fun reservationContinuityWaitDoesNotConsumeCancellationAttempts() {
        val filesDir = temporary.newFolder("cancel-identity-continuity-wait")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.requestCancel(staged.localId)

        repeat(12) {
            now += 1_000L
            outbox.noteCancelAttempt(staged.localId, attempt = 1)
            val schedule = outbox.scheduleContinuityRetry(
                staged.localId,
                FeedbackReservationAttemptLane.CANCELLATION,
            )

            assertEquals(
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                schedule.record.state,
            )
            assertEquals(FeedbackFailureCategory.IDENTITY, schedule.record.failureCategory)
            assertEquals(1, schedule.record.attempt)
            assertEquals(0, schedule.record.cancellationAttempt)
            assertEquals(
                FeedbackReservationContinuityPolicy.minimumRetryDelayMillis,
                schedule.delayMillis,
            )
        }
    }

    @Test
    fun boundReservationPendingPreservesCancellationBudgetUntilExpiry() {
        val filesDir = temporary.newFolder("cancel-bound-reservation-continuity")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)
        outbox.requestCancel(staged.localId)

        repeat(FeedbackOutbox.MAX_ATTEMPTS + 4) {
            now += 1_000L
            outbox.noteCancelAttempt(staged.localId, attempt = 1)
            val schedule = outbox.scheduleContinuityRetry(
                localId = staged.localId,
                lane = FeedbackReservationAttemptLane.CANCELLATION,
                failure = FeedbackFailureCategory.DELETION_PENDING,
                allowBoundIdentity = true,
            )

            assertEquals(
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                schedule.record.state,
            )
            assertEquals(
                FeedbackFailureCategory.DELETION_PENDING,
                schedule.record.failureCategory,
            )
            assertEquals(1, schedule.record.attempt)
            assertEquals(0, schedule.record.cancellationAttempt)
            assertEquals(
                identitySubjectSha256,
                schedule.record.identitySubjectSha256,
            )
            assertTrue(schedule.record.localArchiveRemoved)
        }

        val waiting = outbox.load(staged.localId)!!
        val deadline = checkNotNull(
            FeedbackReservationContinuityPolicy.continuityDeadlineMillis(waiting),
        )
        now = deadline - 1L
        assertEquals(
            null,
            outbox.markUnconfirmedDeletionIfContinuityExpired(staged.localId),
        )

        now = deadline
        val expired =
            outbox.markUnconfirmedDeletionIfContinuityExpired(staged.localId)
        requireNotNull(expired)
        assertEquals(FeedbackState.CANCEL_FAILED, expired.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            expired.failureCategory,
        )
        assertEquals(identitySubjectSha256, expired.identitySubjectSha256)
        assertEquals(null, expired.serverReportId)
        assertEquals(null, expired.serverReportToken)
        assertTrue(expired.localArchiveRemoved)

        val retrying = outbox.retry(staged.localId)
        assertEquals(FeedbackState.CANCELING, retrying.state)
        val attempted = outbox.noteCancelAttempt(staged.localId, attempt = 1)
        assertEquals(FeedbackState.CANCELING, attempted.state)
        assertEquals(1, attempted.cancellationAttempt)
        assertEquals(identitySubjectSha256, attempted.identitySubjectSha256)
    }

    @Test
    fun deliveryContinuityWaitRefundsDeliveryAttemptWhenCancellationRaces() {
        val filesDir = temporary.newFolder("delivery-cancel-continuity-race")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        now += 1_000L
        outbox.requestCancel(staged.localId)

        val schedule = outbox.scheduleContinuityRetry(
            staged.localId,
            FeedbackReservationAttemptLane.DELIVERY,
        )

        assertEquals(FeedbackState.CANCEL_RETRY_SCHEDULED, schedule.record.state)
        assertEquals(0, schedule.record.attempt)
        assertEquals(0, schedule.record.cancellationAttempt)
        assertEquals(null, schedule.record.identitySubjectSha256)
        assertEquals(null, schedule.record.serverReportId)
        assertEquals(null, schedule.record.serverReportToken)
    }

    @Test
    fun expiredCancelFailurePreservesIdentityAndKeepsOutboxFailClosed() {
        val filesDir = temporary.newFolder("identity-continuity-expiry")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.bindIdentity(staged.localId, identitySubjectSha256)
        outbox.requestCancel(staged.localId)
        outbox.markCancelFailed(
            staged.localId,
            FeedbackFailureCategory.DELETION_PENDING,
        )
        now += FeedbackReservationContinuityPolicy
            .maximumAmbiguousBindingLifetimeMillis

        val expired = outbox.recover().single()
        assertEquals(FeedbackState.CANCEL_FAILED, expired.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            expired.failureCategory,
        )
        assertEquals(null, expired.serverReportId)
        assertEquals(null, expired.serverReportToken)
        assertEquals(identitySubjectSha256, expired.identitySubjectSha256)
        assertTrue(expired.localArchiveRemoved)
        assertEquals(
            setOf(identitySubjectSha256),
            outbox.reservationContinuityIdentitySubjectSha256s(),
        )

        repeat(FeedbackOutbox.MAX_RECORDS - 1) {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
        }
        assertEquals(
            FeedbackOutbox.MAX_RECORDS,
            outbox.recover().count { !it.state.terminal },
        )
        try {
            outbox.stage(
                baseEntries(),
                includesUserNote = false,
                includesScreenshot = false,
            )
            fail("Unconfirmed remote deletion must keep the outbox fail-closed")
        } catch (error: FeedbackOutboxException) {
            assertEquals(FeedbackOutboxException.Reason.FULL, error.reason)
        }
    }

    @Test
    fun expiredIdentityProtectionUsesBoundedRetryWithoutRecoveryWriteChurn() {
        val filesDir = temporary.newFolder("identity-continuity-expired-delay")
        var now = 1_789_000_000_000L
        val outbox = deterministicOutbox(filesDir) { now }
        val blocker = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(blocker.localId, attempt = 1)
        val bindingAt = now + 1_000L
        now = bindingAt
        outbox.bindIdentity(blocker.localId, identitySubjectSha256)
        outbox.requestCancel(blocker.localId)
        outbox.markCancelFailed(
            blocker.localId,
            FeedbackFailureCategory.DELETION_PENDING,
        )
        now = bindingAt +
            FeedbackReservationContinuityPolicy.maximumAmbiguousBindingLifetimeMillis

        val expired = outbox.recover().single()
        assertEquals(FeedbackFailureCategory.CAPABILITY_EXPIRED, expired.failureCategory)
        val expiredUpdatedAt = expired.updatedAtMillis

        val waiting = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(waiting.localId, attempt = 1)
        val schedule = outbox.scheduleContinuityRetry(
            waiting.localId,
            FeedbackReservationAttemptLane.DELIVERY,
        )
        assertEquals(
            FeedbackReservationContinuityPolicy.maximumRetryDelayMillis,
            schedule.delayMillis,
        )

        now += TimeUnit.MINUTES.toMillis(1)
        val recoveredAgain = outbox.recover()
            .single { it.localId == blocker.localId }
        assertEquals(expiredUpdatedAt, recoveredAgain.updatedAtMillis)
        assertEquals(
            setOf(identitySubjectSha256),
            outbox.reservationContinuityIdentitySubjectSha256s(),
        )
    }

    @Test
    fun activeReservationLeaseDefersExpiryButRetryStateDoesNot() {
        val filesDir = temporary.newFolder("continuity-active-lease")
        val created = 1_789_000_000_000L
        var now = created
        val outbox = deterministicOutbox(filesDir) { now }
        val staged = outbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        now = created + 1_000L
        outbox.beginUpload(staged.localId, attempt = 1)
        val bindingAt = created + 2_000L
        now = bindingAt
        outbox.bindIdentity(staged.localId, identitySubjectSha256)
        val deadline = bindingAt +
            FeedbackReservationContinuityPolicy.maximumAmbiguousBindingLifetimeMillis
        now = deadline - 1_000L
        outbox.beginUpload(staged.localId, attempt = 1)

        now = deadline
        val leased = outbox.load(staged.localId)
        requireNotNull(leased)
        assertEquals(FeedbackState.UPLOADING, leased.state)
        assertTrue(
            FeedbackReservationContinuityPolicy.requiresContinuity(
                leased,
                now,
            ),
        )
        assertFalse(
            FeedbackReservationContinuityPolicy.hasExpired(
                leased,
                now,
            ),
        )
        assertEquals(
            FeedbackReservationContinuityPolicy.activeWorkLeaseMillis - 1_000L,
            FeedbackReservationContinuityPolicy.retryDelayMillis(
                records = listOf(leased),
                nowMillis = now,
            ),
        )

        now = deadline + FeedbackReservationContinuityPolicy.activeWorkLeaseMillis
        val expired = outbox.recover().single()
        assertEquals(FeedbackState.CANCEL_FAILED, expired.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            expired.failureCategory,
        )
        assertEquals(identitySubjectSha256, expired.identitySubjectSha256)
        assertTrue(expired.localArchiveRemoved)

        val retryFilesDir = temporary.newFolder("continuity-retry-no-lease")
        now = created
        val retryOutbox = deterministicOutbox(retryFilesDir) { now }
        val retry = retryOutbox.stage(
            baseEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        now = created + 1_000L
        retryOutbox.beginUpload(retry.localId, attempt = 1)
        now = bindingAt
        retryOutbox.bindIdentity(retry.localId, identitySubjectSha256)
        now = deadline - 1_000L
        retryOutbox.scheduleRetry(
            retry.localId,
            FeedbackFailureCategory.NETWORK,
        )

        now = deadline
        val retryExpired = retryOutbox.recover().single()
        assertEquals(FeedbackState.CANCEL_FAILED, retryExpired.state)
        assertEquals(
            FeedbackFailureCategory.CAPABILITY_EXPIRED,
            retryExpired.failureCategory,
        )
        assertEquals(identitySubjectSha256, retryExpired.identitySubjectSha256)
        assertTrue(retryExpired.localArchiveRemoved)
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

    private fun baseEntries(
        appVersion: String = "9.2.1",
    ): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP app runtime report\n".toByteArray(),
        "meta.json" to
            """{"schema":1,"app_version":"$appVersion"}""".toByteArray(),
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

    private fun feedbackRecord(
        state: FeedbackState,
        attempt: Int,
        createdAtMillis: Long,
        retainedUntil: String?,
    ) = FeedbackRecord(
        localId = "11111111-1111-4111-8111-111111111111",
        requestId = "22222222-2222-4222-8222-222222222222",
        appVersion = "9.2.1",
        serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        serverReportToken = reportToken,
        identitySubjectSha256 = identitySubjectSha256,
        archiveSha256 = "a".repeat(64),
        archiveBytes = 1,
        includesUserNote = false,
        includesScreenshot = false,
        createdAtMillis = createdAtMillis,
        updatedAtMillis = createdAtMillis,
        state = state,
        attempt = attempt,
        cancellationAttempt = 0,
        failureCategory = FeedbackFailureCategory.NONE,
        retainedUntil = retainedUntil,
        receipt = null,
        localArchiveRemoved = false,
    )

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
