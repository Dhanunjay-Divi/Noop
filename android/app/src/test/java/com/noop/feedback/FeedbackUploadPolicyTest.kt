package com.noop.feedback

import java.io.File
import java.util.UUID
import kotlinx.coroutines.test.runTest
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FeedbackUploadPolicyTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun feedbackWorkNamesAreStableAndReportSpecific() {
        val first = "11111111-1111-4111-8111-111111111111"
        val second = "22222222-2222-4222-8222-222222222222"

        assertEquals(FeedbackScheduler.workName(first), FeedbackScheduler.workName(first))
        assertFalse(FeedbackScheduler.workName(first) == FeedbackScheduler.workName(second))
    }

    @Test
    fun retryClassificationIsBoundedAndCategorical() {
        assertDecision(
            FeedbackProtocolException.Network(),
            FeedbackFailureCategory.NETWORK,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Attestation(),
            FeedbackFailureCategory.ATTESTATION,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Identity(),
            FeedbackFailureCategory.IDENTITY,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(429),
            FeedbackFailureCategory.SERVER_RETRYABLE,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(403),
            FeedbackFailureCategory.SERVER_RETRYABLE,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(409),
            FeedbackFailureCategory.SERVER_RETRYABLE,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(412),
            FeedbackFailureCategory.SERVER_RETRYABLE,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(503),
            FeedbackFailureCategory.SERVER_RETRYABLE,
            retry = true,
        )
        assertDecision(
            FeedbackProtocolException.Http(422),
            FeedbackFailureCategory.SERVER_REJECTED,
            retry = false,
        )
        assertDecision(
            FeedbackProtocolException.InvalidResponse(),
            FeedbackFailureCategory.INVALID_RESPONSE,
            retry = false,
        )
        assertDecision(
            FeedbackProtocolException.Configuration(),
            FeedbackFailureCategory.CONFIGURATION,
            retry = false,
        )
    }

    @Test
    fun automaticRetryStopsAtMaximumAttempt() {
        val retryable = FeedbackRetryPolicy.classify(FeedbackProtocolException.Network())
        assertTrue(FeedbackRetryPolicy.shouldRetry(retryable, attempt = 1))
        assertTrue(
            FeedbackRetryPolicy.shouldRetry(
                retryable,
                attempt = FeedbackOutbox.MAX_ATTEMPTS - 1,
            ),
        )
        assertFalse(
            FeedbackRetryPolicy.shouldRetry(
                retryable,
                attempt = FeedbackOutbox.MAX_ATTEMPTS,
            ),
        )
        assertTrue(FeedbackRetryPolicy.shouldRetryCancellation(retryable, attempt = 1))
        assertFalse(
            FeedbackRetryPolicy.shouldRetryCancellation(
                retryable,
                attempt = FeedbackOutbox.MAX_ATTEMPTS,
            ),
        )
        assertFalse(
            FeedbackRetryPolicy.shouldRetryCancellation(
                FeedbackRetryPolicy.classify(FeedbackProtocolException.InvalidResponse()),
                attempt = 1,
            ),
        )
    }

    @Test
    fun cancellationAttemptBudgetUsesOnlyDurableCancellationState() {
        assertEquals(1, FeedbackRetryPolicy.nextCancellationAttempt(persistedAttempt = 0))
        assertEquals(
            FeedbackOutbox.MAX_ATTEMPTS,
            FeedbackRetryPolicy.nextCancellationAttempt(
                persistedAttempt = FeedbackOutbox.MAX_ATTEMPTS - 1,
            ),
        )
        assertEquals(
            FeedbackOutbox.MAX_ATTEMPTS + 1,
            FeedbackRetryPolicy.nextCancellationAttempt(
                persistedAttempt = FeedbackOutbox.MAX_ATTEMPTS,
            ),
        )
    }

    @Test
    fun stateReadDiagnosticsDistinguishDeferredExhaustedAndRejected() {
        val deferred = FeedbackWorkerStateReadPolicy.decide(
            reason = FeedbackOutboxException.Reason.STATE_UNAVAILABLE,
            runAttemptCount = 0,
        )
        val exhausted = FeedbackWorkerStateReadPolicy.decide(
            reason = FeedbackOutboxException.Reason.STATE_UNAVAILABLE,
            runAttemptCount = FeedbackOutbox.MAX_ATTEMPTS - 1,
        )
        val rejected = FeedbackWorkerStateReadPolicy.decide(
            reason = FeedbackOutboxException.Reason.INVALID_RECORD,
            runAttemptCount = 0,
        )

        assertEquals(FeedbackStateReadOutcome.DEFERRED, deferred.outcome)
        assertTrue(deferred.retry)
        assertEquals(FeedbackStateReadOutcome.EXHAUSTED, exhausted.outcome)
        assertFalse(exhausted.retry)
        assertEquals(FeedbackStateReadOutcome.REJECTED, rejected.outcome)
        assertFalse(rejected.retry)
    }

    @Test
    fun uploadProgressUsesStableTenToNinetyPercentWindow() {
        assertEquals(10, FeedbackRetryPolicy.uploadProgress(0, 1_000))
        assertEquals(50, FeedbackRetryPolicy.uploadProgress(500, 1_000))
        assertEquals(90, FeedbackRetryPolicy.uploadProgress(1_000, 1_000))
        assertEquals(90, FeedbackRetryPolicy.uploadProgress(2_000, 1_000))
        assertEquals(10, FeedbackRetryPolicy.uploadProgress(1, 0))
    }

    @Test
    fun stateMachineSeparatesUploadAndCancellationRetries() {
        assertTrue(
            FeedbackStateMachine.canTransition(
                FeedbackState.QUEUED,
                FeedbackState.UPLOADING,
            ),
        )
        assertTrue(
            FeedbackStateMachine.canTransition(
                FeedbackState.UPLOADING,
                FeedbackState.RETRY_SCHEDULED,
            ),
        )
        assertTrue(
            FeedbackStateMachine.canTransition(
                FeedbackState.CANCELING,
                FeedbackState.CANCEL_RETRY_SCHEDULED,
            ),
        )
        assertTrue(
            FeedbackStateMachine.canTransition(
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                FeedbackState.CANCELING,
            ),
        )
        assertFalse(
            FeedbackStateMachine.canTransition(
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                FeedbackState.UPLOADING,
            ),
        )
        assertFalse(
            FeedbackStateMachine.canTransition(
                FeedbackState.SENT,
                FeedbackState.QUEUED,
            ),
        )
    }

    @Test
    fun remoteRecoveryUsesOnlyTheServerStatusEnum() {
        assertEquals(
            FeedbackRemoteAction.CONTINUE_UPLOAD,
            FeedbackRemoteStatusPolicy.recoverUpload("reserved"),
        )
        assertEquals(
            FeedbackRemoteAction.MARK_SENT,
            FeedbackRemoteStatusPolicy.recoverUpload("sent"),
        )
        assertEquals(
            FeedbackRemoteAction.REJECT,
            FeedbackRemoteStatusPolicy.recoverUpload("rejected"),
        )
        assertEquals(
            FeedbackRemoteAction.REQUEST_DELETE,
            FeedbackRemoteStatusPolicy.recoverUpload("deleting"),
        )
        assertEquals(
            FeedbackRemoteAction.MARK_DELETED,
            FeedbackRemoteStatusPolicy.recoverUpload("deleted"),
        )
        listOf("reserved", "sent", "rejected").forEach { state ->
            assertEquals(
                FeedbackRemoteAction.REQUEST_DELETE,
                FeedbackRemoteStatusPolicy.recoverCancellation(state),
            )
        }
        assertEquals(
            FeedbackRemoteAction.WAIT_FOR_DELETE,
            FeedbackRemoteStatusPolicy.recoverCancellation("deleting"),
        )
        assertEquals(
            FeedbackRemoteAction.MARK_DELETED,
            FeedbackRemoteStatusPolicy.recoverCancellation("deleted"),
        )
        listOf("canceled", "failed").forEach { invalid ->
            assertInvalidRemoteStatus {
                FeedbackRemoteStatusPolicy.recoverUpload(invalid)
            }
            assertInvalidRemoteStatus {
                FeedbackRemoteStatusPolicy.recoverCancellation(invalid)
            }
        }
    }

    @Test
    fun apiAuthorizationRefreshesExactlyOncePerWorkerAttempt() = runTest {
        listOf(401, 403).forEach { statusCode ->
            val refreshes = mutableListOf<Boolean>()
            val session = FeedbackAuthorizedSession(
                provider = object : FeedbackAuthorizationProvider {
                    override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization {
                        refreshes += forceRefresh
                        return FeedbackAuthorization(
                            appCheckToken = if (forceRefresh) "fresh-app-check" else "cached-app-check",
                            identityToken = if (forceRefresh) "fresh-identity" else "cached-identity",
                            identitySubject = "stable-feedback-owner",
                        )
                    }
                },
            )
            var requests = 0

            val result = session.request { authorization ->
                requests += 1
                if (requests == 1) throw FeedbackProtocolException.Http(statusCode)
                authorization.identityToken
            }

            assertEquals("fresh-identity", result)
            assertEquals(2, requests)
            assertEquals(listOf(false, true), refreshes)

            try {
                session.request<String> {
                    throw FeedbackProtocolException.Http(statusCode)
                }
                fail("A second API rejection must not trigger another forced refresh")
            } catch (error: FeedbackProtocolException.Http) {
                assertEquals(statusCode, error.statusCode)
            }
            assertEquals(listOf(false, true), refreshes)
        }
    }

    @Test
    fun signedUpload403RefreshesCapabilityWithoutRefreshingIdentity() = runTest {
        val authorizationRequests = mutableListOf<Boolean>()
        val session = FeedbackAuthorizedSession(
            provider = object : FeedbackAuthorizationProvider {
                override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization {
                    authorizationRequests += forceRefresh
                    return FeedbackAuthorization(
                        appCheckToken = "app-check",
                        identityToken = "identity",
                        identitySubject = "stable-feedback-owner",
                    )
                }
            },
        )
        session.request { Unit }
        val initial = capability("initial")
        val refreshed = capability("refreshed")
        val uploaded = mutableListOf<FeedbackUploadCapability>()
        var capabilityRefreshes = 0

        val finalCapability = uploadWithSingleCapabilityRefresh(
            initialCapability = initial,
            upload = {
                uploaded += it
                if (uploaded.size == 1) throw FeedbackProtocolException.Http(403)
            },
            refreshCapability = {
                capabilityRefreshes += 1
                session.request { refreshed }
            },
        )

        assertEquals(refreshed, finalCapability)
        assertEquals(listOf(initial, refreshed), uploaded)
        assertEquals(1, capabilityRefreshes)
        assertEquals(listOf(false), authorizationRequests)
    }

    @Test
    fun signedUploadCapabilityRefreshIsAttemptedOnlyOnce() = runTest {
        var uploads = 0
        var refreshes = 0

        try {
            uploadWithSingleCapabilityRefresh(
                initialCapability = capability("initial"),
                upload = {
                    uploads += 1
                    throw FeedbackProtocolException.Http(403)
                },
                refreshCapability = {
                    refreshes += 1
                    capability("refreshed")
                },
            )
            fail("The second signed-upload rejection must be returned to WorkManager")
        } catch (error: FeedbackProtocolException.Http) {
            assertEquals(403, error.statusCode)
        }
        assertEquals(2, uploads)
        assertEquals(1, refreshes)
    }

    @Test
    fun forcedAuthorizationRefreshRejectsAnIdentitySubjectChange() = runTest {
        val session = FeedbackAuthorizedSession(
            provider = object : FeedbackAuthorizationProvider {
                override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization =
                    FeedbackAuthorization(
                        appCheckToken = if (forceRefresh) "fresh-app-check" else "cached-app-check",
                        identityToken = if (forceRefresh) "fresh-token" else "cached-token",
                        identitySubject =
                            if (forceRefresh) "replacement-owner" else "original-owner",
                    )
            },
        )
        var requests = 0

        try {
            session.request<Unit> {
                requests += 1
                throw FeedbackProtocolException.Http(401)
            }
            fail("A refreshed token from a different anonymous owner must be rejected")
        } catch (_: FeedbackProtocolException.Identity) {
            // Expected: a UID mismatch must never reach status/cancel as a deletion-looking 404.
        }

        assertEquals(1, requests)
    }

    @Test
    fun recreatedWorkerRejectsAnIdentityDifferentFromThePersistedBinding() = runTest {
        val session = FeedbackAuthorizedSession(
            provider = object : FeedbackAuthorizationProvider {
                override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization =
                    FeedbackAuthorization(
                        appCheckToken = "app-check",
                        identityToken = "identity",
                        identitySubject = "replacement-owner",
                    )
            },
            expectedIdentitySubjectSha256 =
                feedbackIdentitySubjectSha256("original-owner"),
        )

        try {
            session.request { Unit }
            fail("A recreated worker must not rotate the owner of an existing report")
        } catch (_: FeedbackProtocolException.Identity) {
            // Expected.
        }
    }

    @Test
    fun cancellationReconcilesOnlyAReservationThatMayHaveReachedTheServer() {
        assertFalse(
            FeedbackCancellationPolicy.requiresReservationReconciliation(
                feedbackRecord(state = FeedbackState.CANCELING, attempt = 0),
            ),
        )
        assertTrue(
            FeedbackCancellationPolicy.requiresReservationReconciliation(
                feedbackRecord(state = FeedbackState.CANCELING, attempt = 1),
            ),
        )
        assertFalse(
            FeedbackCancellationPolicy.requiresReservationReconciliation(
                feedbackRecord(
                    state = FeedbackState.CANCELING,
                    attempt = 1,
                    serverReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                ),
            ),
        )
    }

    @Test
    fun cancellationReplaysAnAmbiguousReservationBeforeRemoteDeletion() = runTest {
        val filesDir = temporary.newFolder("ambiguous-reservation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to "{\"schema\":1}".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)

        val remoteReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val remoteReportToken = "v2." + "a".repeat(43)
        var reservationReplays = 0
        var deletionRequests = 0
        val client = FeedbackAttemptClient(
            provider = stableAuthorizationProvider(),
            transport = object : FeedbackTransport {
                override suspend fun reserve(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                    request: FeedbackReservationRequest,
                ): FeedbackReservation {
                    reservationReplays += 1
                    assertEquals(UUID.fromString(staged.requestId), idempotencyKey)
                    return FeedbackReservation(
                        reportId = remoteReportId,
                        reportToken = remoteReportToken,
                        status = "reserved",
                        upload = null,
                        retainedUntil = "2026-10-12T00:00:00Z",
                    )
                }

                override suspend fun upload(
                    archive: File,
                    expectedBytes: Long,
                    expectedSha256: String,
                    capability: FeedbackUploadCapability,
                    progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
                ) = Unit

                override suspend fun complete(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ) = FeedbackRemoteStatus("sent", receipt = null, retainedUntil = null)

                override suspend fun status(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ) = FeedbackRemoteStatus("reserved", receipt = null, retainedUntil = null)

                override suspend fun cancel(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ): FeedbackRemoteStatus {
                    deletionRequests += 1
                    assertEquals(remoteReportId, reportId)
                    assertEquals(remoteReportToken, reportToken)
                    return FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
                }
            },
        )

        // The first remote reservation succeeded, but the process stopped before state.json was updated.
        val canceling = outbox.requestCancel(staged.localId)
        val reconciled = FeedbackCancellationReconciler.reconcile(
            outbox = outbox,
            record = canceling,
            client = client,
            appVersion = "1.0.0",
        )
        val deletion = client.cancel(
            reportId = reconciled.serverReportId!!,
            reportToken = reconciled.serverReportToken!!,
        )

        assertEquals(1, reservationReplays)
        assertEquals(remoteReportId, reconciled.serverReportId)
        assertEquals("deleted", deletion.status)
        assertEquals(1, deletionRequests)
    }

    @Test
    fun cancellationStateRejectsLateUploadProgressFromAnOlderSnapshot() {
        val uploading = feedbackRecord(
            state = FeedbackState.UPLOADING,
            updatedAtMillis = 1_000L,
        )
        val canceling = feedbackRecord(
            state = FeedbackState.CANCELING,
            updatedAtMillis = 2_000L,
        )

        assertTrue(FeedbackRuntimeStatusPolicy.shouldPublish(uploading, canceling))
        assertFalse(FeedbackRuntimeStatusPolicy.shouldPublish(canceling, uploading))
    }

    @Test
    fun cancellationStateWinsEvenWhenTheWallClockMovedBackward() {
        val uploading = feedbackRecord(
            state = FeedbackState.UPLOADING,
            updatedAtMillis = 2_000L,
        )
        val canceling = feedbackRecord(
            state = FeedbackState.CANCELING,
            updatedAtMillis = 1_000L,
        )

        assertTrue(FeedbackRuntimeStatusPolicy.shouldPublish(uploading, canceling))
        assertFalse(FeedbackRuntimeStatusPolicy.shouldPublish(canceling, uploading))
    }

    @Test
    fun uploadProgressIsThrottledByPercentOrTimeWithoutBlocking() {
        var now = 1_000L
        val throttler = FeedbackProgressThrottler(
            minimumPercentDelta = 5,
            minimumIntervalMillis = 1_000L,
            nowMillis = { now },
        )

        assertTrue(throttler.shouldPublish(10))
        assertFalse(throttler.shouldPublish(11))
        assertFalse(throttler.shouldPublish(14))
        assertTrue(throttler.shouldPublish(15))
        now += 1_000L
        assertTrue(throttler.shouldPublish(16))
        assertFalse(throttler.shouldPublish(16))
        assertTrue(throttler.shouldPublish(90))
        assertFalse(throttler.shouldPublish(90))
        assertTrue(throttler.shouldPublish(100))
    }

    private fun assertDecision(
        error: Throwable,
        category: FeedbackFailureCategory,
        retry: Boolean,
    ) {
        val decision = FeedbackRetryPolicy.classify(error)
        assertEquals(category, decision.category)
        assertEquals(retry, decision.retryAutomatically)
    }

    private fun assertInvalidRemoteStatus(block: () -> Unit) {
        try {
            block()
            throw AssertionError("Expected invalid remote feedback status")
        } catch (_: FeedbackProtocolException.InvalidResponse) {
            // Expected.
        }
    }

    private fun capability(name: String) = FeedbackUploadCapability(
        method = "PUT",
        url = "https://storage.googleapis.com/noop-feedback/$name.zip".toHttpUrl(),
        headers = Headers.Builder().build(),
        expiresAt = "2026-09-12T23:59:59Z",
    )

    private fun stableAuthorizationProvider() = object : FeedbackAuthorizationProvider {
        override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization =
            FeedbackAuthorization(
                appCheckToken = "app-check",
                identityToken = "identity",
                identitySubject = "stable-feedback-owner",
            )
    }

    private fun feedbackRecord(
        state: FeedbackState,
        attempt: Int = 0,
        serverReportId: String? = null,
        updatedAtMillis: Long = 1_000L,
    ) = FeedbackRecord(
        localId = "11111111-1111-4111-8111-111111111111",
        requestId = "22222222-2222-4222-8222-222222222222",
        serverReportId = serverReportId,
        serverReportToken = serverReportId?.let { "v2." + "a".repeat(43) },
        identitySubjectSha256 = feedbackIdentitySubjectSha256("stable-feedback-owner"),
        archiveSha256 = "a".repeat(64),
        archiveBytes = 1,
        includesUserNote = false,
        includesScreenshot = false,
        createdAtMillis = 1_000L,
        updatedAtMillis = updatedAtMillis,
        state = state,
        attempt = attempt,
        cancellationAttempt = 0,
        failureCategory = FeedbackFailureCategory.NONE,
        retainedUntil = null,
        receipt = null,
        localArchiveRemoved = state.isCancellationStateForTest(),
    )

    private fun FeedbackState.isCancellationStateForTest(): Boolean =
        this == FeedbackState.CANCELING ||
            this == FeedbackState.CANCEL_RETRY_SCHEDULED ||
            this == FeedbackState.CANCEL_FAILED
}
