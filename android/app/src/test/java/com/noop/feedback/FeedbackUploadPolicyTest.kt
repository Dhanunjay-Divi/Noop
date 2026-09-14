package com.noop.feedback

import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
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
    @Test
    fun missingIdentityCannotBeCreatedWhenReplacementIsForbidden() {
        assertFalse(
            FeedbackIdentityCreationPolicy.permitsCreation(
                allowIdentityReplacement = false,
            ),
        )
        assertTrue(
            FeedbackIdentityCreationPolicy.permitsCreation(
                allowIdentityReplacement = true,
            ),
        )
    }

    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun feedbackWorkNamesAreStableAndReportSpecific() {
        val first = "11111111-1111-4111-8111-111111111111"
        val second = "22222222-2222-4222-8222-222222222222"

        assertEquals(FeedbackScheduler.workName(first), FeedbackScheduler.workName(first))
        assertFalse(FeedbackScheduler.workName(first) == FeedbackScheduler.workName(second))
        assertEquals(
            FeedbackScheduler.generationTag(first),
            FeedbackScheduler.generationTag(first),
        )
        assertFalse(
            FeedbackScheduler.generationTag(first) ==
                FeedbackScheduler.generationTag(second),
        )
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
        val continuityWait = FeedbackRetryPolicy.classify(
            FeedbackProtocolException.ReservationContinuityPending(),
        )
        assertEquals(FeedbackFailureCategory.IDENTITY, continuityWait.category)
        assertTrue(continuityWait.retryAutomatically)
        assertTrue(continuityWait.preservesAttemptBudget)
        assertFalse(continuityWait.allowsBoundIdentityContinuity)
        val reservationWait = FeedbackRetryPolicy.classify(
            FeedbackProtocolException.ReservationPending(),
        )
        assertEquals(FeedbackFailureCategory.DELETION_PENDING, reservationWait.category)
        assertTrue(reservationWait.retryAutomatically)
        assertTrue(reservationWait.preservesAttemptBudget)
        assertTrue(reservationWait.allowsBoundIdentityContinuity)
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
    fun workerRetriesTransientArchiveIoWithoutCallingTheArchiveInvalid() {
        assertDecision(
            FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED),
            FeedbackFailureCategory.INTERRUPTED,
            retry = true,
        )
        assertDecision(
            IOException("synthetic transient archive read"),
            FeedbackFailureCategory.INTERRUPTED,
            retry = true,
        )
        assertDecision(
            FeedbackOutboxException(FeedbackOutboxException.Reason.STATE_UNAVAILABLE),
            FeedbackFailureCategory.INTERRUPTED,
            retry = true,
        )
        assertDecision(
            FeedbackOutboxException(FeedbackOutboxException.Reason.WRITE_FAILED),
            FeedbackFailureCategory.INTERRUPTED,
            retry = true,
        )
        assertDecision(
            FeedbackArchiveException(FeedbackArchiveException.Reason.DIGEST_MISMATCH),
            FeedbackFailureCategory.ARCHIVE_INVALID,
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
        val reservationPending = FeedbackRetryPolicy.classify(
            FeedbackProtocolException.ReservationPending(),
        )
        assertEquals(
            FeedbackFailureCategory.DELETION_PENDING,
            reservationPending.category,
        )
        assertTrue(
            FeedbackRetryPolicy.shouldRetryCancellation(
                reservationPending,
                attempt = 1,
            ),
        )
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
    fun serverRetentionResponseIsBoundedAndCategorical() {
        val created = 1_789_000_000_000L
        val now = created + TimeUnit.HOURS.toMillis(1)
        val record = FeedbackRecord(
            localId = "11111111-1111-4111-8111-111111111111",
            requestId = "22222222-2222-4222-8222-222222222222",
            appVersion = "9.2.1",
            serverReportId = null,
            serverReportToken = null,
            identitySubjectSha256 = feedbackIdentitySubjectSha256("retention-owner"),
            archiveSha256 = "a".repeat(64),
            archiveBytes = 1024,
            includesUserNote = false,
            includesScreenshot = false,
            createdAtMillis = created,
            updatedAtMillis = now,
            state = FeedbackState.UPLOADING,
            attempt = 1,
            cancellationAttempt = 0,
            failureCategory = FeedbackFailureCategory.NONE,
            retainedUntil = null,
            receipt = null,
            localArchiveRemoved = false,
            reservationContinuityStartedAtMillis = now,
        )
        val validUntil = now + TimeUnit.DAYS.toMillis(28)
        val valid = FeedbackServerRetentionResponsePolicy.evaluate(
            record = record,
            retainedUntil = Instant.ofEpochMilli(validUntil).toString(),
            nowMillis = now,
        )
        assertTrue(valid.accepted)
        assertEquals(Instant.ofEpochMilli(validUntil).toString(), valid.retainedUntil)

        val acceptedMaximum =
            now +
                FeedbackReservationContinuityPolicy.maximumRemoteRetentionMillis +
                FeedbackReservationContinuityPolicy.maximumClockSkewMillis
        val skewBoundary = FeedbackServerRetentionResponsePolicy.evaluate(
            record = record,
            retainedUntil = Instant.ofEpochMilli(acceptedMaximum).toString(),
            nowMillis = now,
        )
        assertTrue(skewBoundary.accepted)
        assertEquals(
            Instant.ofEpochMilli(acceptedMaximum).toString(),
            skewBoundary.retainedUntil,
        )

        val excessiveUntil = acceptedMaximum + 1L
        val excessive = FeedbackServerRetentionResponsePolicy.evaluate(
            record = record,
            retainedUntil = Instant.ofEpochMilli(excessiveUntil).toString(),
            nowMillis = now,
        )
        assertFalse(excessive.accepted)
        assertEquals(
            Instant.ofEpochMilli(acceptedMaximum).toString(),
            excessive.retainedUntil,
        )

        val legacyRecord = record.copy(
            reservationContinuityStartedAtMillis = null,
        )
        val legacyMaximum =
            FeedbackReservationContinuityPolicy
                .maximumServerRetainedUntilMillis(legacyRecord)
        val legacyCreationBound = FeedbackServerRetentionResponsePolicy.evaluate(
            record = legacyRecord,
            retainedUntil = Instant.ofEpochMilli(validUntil).toString(),
            nowMillis = now,
        )
        assertFalse(legacyCreationBound.accepted)
        assertEquals(
            Instant.ofEpochMilli(legacyMaximum).toString(),
            legacyCreationBound.retainedUntil,
        )
    }

    @Test
    fun reportAttemptBudgetsUseOnlyDurableOutboxState() {
        assertEquals(1, FeedbackRetryPolicy.nextDeliveryAttempt(persistedAttempt = 0))
        assertEquals(
            FeedbackOutbox.MAX_ATTEMPTS,
            FeedbackRetryPolicy.nextDeliveryAttempt(
                persistedAttempt = FeedbackOutbox.MAX_ATTEMPTS - 1,
            ),
        )
        assertEquals(
            FeedbackOutbox.MAX_ATTEMPTS + 1,
            FeedbackRetryPolicy.nextDeliveryAttempt(
                persistedAttempt = FeedbackOutbox.MAX_ATTEMPTS,
            ),
        )
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
    fun anonymousIdentityLifetimePolicyRequiresFullRetentionCoverage() {
        val now = 1_789_000_000_000L
        val maximumAge =
            FeedbackAnonymousIdentityLifetimePolicy.maximumExistingIdentityAgeMillis

        assertEquals(
            FeedbackReservationIdentityAction.REUSE,
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAtMillis = now - maximumAge,
                nowMillis = now,
                hasActiveBoundReports = true,
            ),
        )
        assertEquals(
            FeedbackReservationIdentityAction.REPLACE,
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAtMillis = now - maximumAge - 1L,
                nowMillis = now,
                hasActiveBoundReports = false,
            ),
        )
        assertEquals(
            FeedbackReservationIdentityAction.DEFER,
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAtMillis = now - maximumAge - 1L,
                nowMillis = now,
                hasActiveBoundReports = true,
            ),
        )
        assertEquals(
            FeedbackReservationIdentityAction.REPLACE,
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAtMillis = null,
                nowMillis = now,
                hasActiveBoundReports = false,
            ),
        )
        assertEquals(
            TimeUnit.HOURS.toMillis(22) + TimeUnit.MINUTES.toMillis(55),
            maximumAge,
        )
    }

    @Test
    fun providerPolicyPreservesAmbiguousBindingAndDefersNewReport() {
        val now = 1_789_000_000_000L
        val currentIdentity =
            feedbackIdentitySubjectSha256("stable-feedback-owner")
        val unrelatedIdentity =
            feedbackIdentitySubjectSha256("unrelated-feedback-owner")
        val oldCreation =
            now -
                FeedbackAnonymousIdentityLifetimePolicy.maximumExistingIdentityAgeMillis -
                1L

        assertEquals(
            FeedbackReservationIdentityAction.REUSE,
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime = false,
                identityCreatedAtMillis = oldCreation,
                nowMillis = now,
                identitySubjectSha256 = currentIdentity,
                reservationContinuityIdentitySubjectSha256s =
                    setOf(currentIdentity),
            ),
        )
        assertEquals(
            FeedbackReservationIdentityAction.DEFER,
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime = true,
                identityCreatedAtMillis = oldCreation,
                nowMillis = now,
                identitySubjectSha256 = currentIdentity,
                reservationContinuityIdentitySubjectSha256s =
                    setOf(currentIdentity),
            ),
        )
        assertFalse(
            FeedbackAnonymousIdentityProviderPolicy
                .permitsStaleIdentityReplacement(
                    identitySubjectSha256 = currentIdentity,
                    reservationContinuityIdentitySubjectSha256s =
                        setOf(currentIdentity),
                ),
        )
        assertEquals(
            FeedbackReservationIdentityAction.REPLACE,
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime = true,
                identityCreatedAtMillis = oldCreation,
                nowMillis = now,
                identitySubjectSha256 = currentIdentity,
                reservationContinuityIdentitySubjectSha256s =
                    setOf(unrelatedIdentity),
            ),
        )
        assertTrue(
            FeedbackAnonymousIdentityProviderPolicy
                .permitsStaleIdentityReplacement(
                    identitySubjectSha256 = currentIdentity,
                    reservationContinuityIdentitySubjectSha256s =
                        setOf(unrelatedIdentity),
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
    fun boundCancellationDeletesWhenStatusIsTemporarilyAbsent() = runTest {
        var statusReads = 0
        var deletionRequests = 0
        val client = FeedbackAttemptClient(
            provider = stableAuthorizationProvider(),
            transport = object : FeedbackTransport {
                override suspend fun reserve(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                    request: FeedbackReservationRequest,
                ): FeedbackReservation =
                    throw AssertionError("Bound cancellation must not reserve")

                override suspend fun recoverReservation(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                ): FeedbackReservation? =
                    throw AssertionError("Bound cancellation must not recover by idempotency")

                override suspend fun upload(
                    archive: File,
                    expectedBytes: Long,
                    expectedSha256: String,
                    capability: FeedbackUploadCapability,
                    progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
                ) = throw AssertionError("Bound cancellation must not upload")

                override suspend fun complete(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ): FeedbackRemoteStatus =
                    throw AssertionError("Bound cancellation must not complete")

                override suspend fun status(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ): FeedbackRemoteStatus {
                    statusReads += 1
                    throw FeedbackProtocolException.ReservationPending()
                }

                override suspend fun cancel(
                    authorization: FeedbackAuthorization,
                    reportId: String,
                    reportToken: String,
                ): FeedbackRemoteStatus {
                    deletionRequests += 1
                    return FeedbackRemoteStatus(
                        status = "deleted",
                        receipt = null,
                        retainedUntil = null,
                    )
                }
            },
        )

        val remote = FeedbackBoundCancellationReconciler.reconcile(
            client = client,
            reportId = "11111111-1111-4111-8111-111111111111",
            reportToken = "v2." + "a".repeat(43),
        )

        assertEquals("deleted", remote.status)
        assertEquals(1, statusReads)
        assertEquals(1, deletionRequests)
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
    fun identityAuthorizationGateRemainsHeldThroughDurableOutboxBinding() = runTest {
        val filesDir = temporary.newFolder("identity-binding-gate")
        val outbox = FeedbackOutbox(filesDir)
        val firstRecord = outbox.stage(
            entries = feedbackEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val secondRecord = outbox.stage(
            entries = feedbackEntries(),
            includesUserNote = false,
            includesScreenshot = false,
        )
        val gate = Mutex()
        val authorization = FeedbackAuthorization(
            appCheckToken = "app-check",
            identityToken = "identity",
            identitySubject = "stable-feedback-owner",
        )
        val provider = object : FeedbackAuthorizationProvider {
            override suspend fun authorization(
                forceRefresh: Boolean,
            ): FeedbackAuthorization = authorization

            override suspend fun <T> authorizationAndBind(
                forceRefresh: Boolean,
                bind: suspend (FeedbackAuthorization) -> T,
            ): T = gate.withLock {
                bind(authorization)
            }
        }
        val firstSession = FeedbackAuthorizedSession(provider)
        val secondSession = FeedbackAuthorizedSession(provider)
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondEntered = CompletableDeferred<Unit>()

        val first = async {
            firstSession.bindIdentity { identitySubjectSha256 ->
                firstEntered.complete(Unit)
                releaseFirst.await()
                outbox.bindIdentity(firstRecord.localId, identitySubjectSha256)
            }
        }
        firstEntered.await()
        val second = async {
            secondSession.bindIdentity { identitySubjectSha256 ->
                secondEntered.complete(Unit)
                outbox.bindIdentity(secondRecord.localId, identitySubjectSha256)
            }
        }
        yield()
        assertFalse(secondEntered.isCompleted)

        releaseFirst.complete(Unit)
        first.await()
        second.await()

        val expected = feedbackIdentitySubjectSha256("stable-feedback-owner")
        assertEquals(expected, outbox.load(firstRecord.localId)?.identitySubjectSha256)
        assertEquals(expected, outbox.load(secondRecord.localId)?.identitySubjectSha256)
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
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        val restartedOutbox = FeedbackOutbox(
            filesDir = filesDir,
            nowMillis = { 1_789_000_000_000L },
        )

        val remoteReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val remoteReportToken = "v2." + "a".repeat(43)
        var reservationReplays = 0
        var reservationRecoveries = 0
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
                    assertEquals("1.0.0", request.appVersion)
                    return FeedbackReservation(
                        reportId = remoteReportId,
                        reportToken = remoteReportToken,
                        status = "reserved",
                        upload = null,
                        retainedUntil = "2026-10-12T00:00:00Z",
                    )
                }

                override suspend fun recoverReservation(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                ): FeedbackReservation {
                    reservationRecoveries += 1
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
        val canceling = restartedOutbox.requestCancel(staged.localId)
        val reconciled = FeedbackCancellationReconciler.reconcile(
            outbox = restartedOutbox,
            record = canceling,
            client = client,
        )
        val deletion = client.cancel(
            reportId = reconciled.serverReportId!!,
            reportToken = reconciled.serverReportToken!!,
        )

        assertEquals(0, reservationReplays)
        assertEquals(1, reservationRecoveries)
        assertEquals(remoteReportId, reconciled.serverReportId)
        assertEquals("deleted", deletion.status)
        assertEquals(1, deletionRequests)
    }

    @Test
    fun cancellationKeepsAmbiguousReservationPendingWhenRecoveryReturnsMissing() = runTest {
        val filesDir = temporary.newFolder("missing-ambiguous-reservation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        val canceling = outbox.requestCancel(staged.localId)
        val client = FeedbackAttemptClient(
            provider = stableAuthorizationProvider(),
            transport = object : FeedbackTransport {
                override suspend fun reserve(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                    request: FeedbackReservationRequest,
                ): FeedbackReservation =
                    throw AssertionError("Cancellation must not replay a payload")

                override suspend fun recoverReservation(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                ): FeedbackReservation? = null

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
                ) = FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
            },
        )

        try {
            FeedbackCancellationReconciler.reconcile(
                outbox = outbox,
                record = canceling,
                client = client,
            )
            fail("An ambiguous reservation must remain retryable")
        } catch (_: FeedbackProtocolException.ReservationPending) {
            // Expected: a late reservation may still commit after the missing recovery response.
        }

        val retained = outbox.load(staged.localId)!!
        assertEquals(FeedbackState.CANCELING, retained.state)
        assertEquals(null, retained.serverReportId)
        assertEquals(null, retained.serverReportToken)
        assertTrue(retained.localArchiveRemoved)
    }

    @Test
    fun cancellationFinishesWhenRecoveryProvesReservationWasRetired() = runTest {
        val filesDir = temporary.newFolder("retired-reservation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        val canceling = outbox.requestCancel(staged.localId)
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
                    throw AssertionError("Cancellation must not replay a retired key")
                }

                override suspend fun recoverReservation(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                ): FeedbackReservation? =
                    throw FeedbackProtocolException.ReservationGone()

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
                    return FeedbackRemoteStatus(
                        "deleted",
                        receipt = null,
                        retainedUntil = null,
                    )
                }
            },
        )

        val reconciled = FeedbackCancellationReconciler.reconcile(
            outbox = outbox,
            record = canceling,
            client = client,
        )

        assertEquals(FeedbackState.CANCELED, reconciled.state)
        assertEquals(0, reservationReplays)
        assertEquals(0, deletionRequests)
        assertEquals(null, reconciled.serverReportId)
        assertEquals(null, reconciled.serverReportToken)
        assertTrue(reconciled.localArchiveRemoved)
    }

    @Test
    fun deliveryRecoveryRetiresGoneReservationWithoutFalseFailure() = runTest {
        val filesDir = temporary.newFolder("retired-delivery-reservation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        val bound = outbox.bindIdentity(
            staged.localId,
            feedbackIdentitySubjectSha256("stable-feedback-owner"),
        )

        val recovery = FeedbackDeliveryReservationReconciler.reconcile(
            outbox = outbox,
            record = bound,
            client = reservationRecoveryClient {
                throw FeedbackProtocolException.ReservationGone()
            },
            idempotencyKey = UUID.fromString(bound.requestId),
        )

        assertTrue(recovery is FeedbackDeliveryReservationRecovery.Retired)
        val retired = (recovery as FeedbackDeliveryReservationRecovery.Retired).record
        assertEquals(FeedbackState.CANCELED, retired.state)
        assertEquals(FeedbackFailureCategory.NONE, retired.failureCategory)
        assertTrue(retired.localArchiveRemoved)
        assertEquals(FeedbackState.CANCELED, outbox.load(retired.localId)?.state)
    }

    @Test
    fun deliveryRecoveryKeepsMissingReservationPending() = runTest {
        val filesDir = temporary.newFolder("pending-delivery-reservation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        val bound = outbox.bindIdentity(
            staged.localId,
            feedbackIdentitySubjectSha256("stable-feedback-owner"),
        )

        try {
            FeedbackDeliveryReservationReconciler.reconcile(
                outbox = outbox,
                record = bound,
                client = reservationRecoveryClient { null },
                idempotencyKey = UUID.fromString(bound.requestId),
            )
            fail("A missing reservation remains ambiguous until the continuity deadline")
        } catch (_: FeedbackProtocolException.ReservationPending) {
            // Expected.
        }

        val pending = outbox.load(bound.localId)!!
        assertEquals(FeedbackState.UPLOADING, pending.state)
        assertEquals(1, pending.attempt)
        assertEquals(bound.identitySubjectSha256, pending.identitySubjectSha256)
        assertFalse(pending.localArchiveRemoved)
    }

    @Test
    fun archiveFreeLegacyCancellationRecoversByIdempotencyWithoutAppVersion() = runTest {
        val filesDir = temporary.newFolder("legacy-archive-free-cancellation")
        var next = 1L
        val outbox = FeedbackOutbox(
            filesDir = filesDir,
            idFactory = { UUID(0L, next++) },
            nowMillis = { 1_789_000_000_000L },
        )
        val staged = outbox.stage(
            entries = listOf(
                "report.txt" to "NOOP app runtime report\n".toByteArray(),
                "meta.json" to
                    """{"schema":1,"app_version":"1.0.0"}""".toByteArray(),
            ),
            includesUserNote = false,
            includesScreenshot = false,
        )
        outbox.beginUpload(staged.localId, attempt = 1)
        outbox.requestCancel(staged.localId)
        val stateFile = File(
            filesDir,
            "feedback/outbox/${staged.localId}/state.json",
        )
        val legacyState = org.json.JSONObject(stateFile.readText())
            .apply {
                remove("app_version")
                remove("clock_anomaly_observed_at_millis")
                remove("reservation_continuity_started_at_millis")
                remove("worker_generation")
                remove("retry_not_before_millis")
            }
        stateFile.writeText(legacyState.toString())
        val restarted = FeedbackOutbox(
            filesDir = filesDir,
            nowMillis = { 1_789_000_000_000L },
        )
        val canceling = restarted.load(staged.localId)!!
        assertEquals(null, canceling.appVersion)
        assertTrue(canceling.localArchiveRemoved)

        val remoteReportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val remoteReportToken = "v2." + "a".repeat(43)
        val client = FeedbackAttemptClient(
            provider = stableAuthorizationProvider(),
            transport = object : FeedbackTransport {
                override suspend fun reserve(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                    request: FeedbackReservationRequest,
                ): FeedbackReservation =
                    throw AssertionError("Cancellation must not replay a payload")

                override suspend fun recoverReservation(
                    authorization: FeedbackAuthorization,
                    idempotencyKey: UUID,
                ) = FeedbackReservation(
                    reportId = remoteReportId,
                    reportToken = remoteReportToken,
                    status = "reserved",
                    upload = null,
                    retainedUntil = "2026-10-12T00:00:00Z",
                )

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
                ) = FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
            },
        )

        val recovered = FeedbackCancellationReconciler.reconcile(
            outbox = restarted,
            record = canceling,
            client = client,
        )

        assertEquals(remoteReportId, recovered.serverReportId)
        assertEquals(remoteReportToken, recovered.serverReportToken)
        assertEquals(null, recovered.appVersion)
    }

    @Test
    fun reservationRequestUsesTheStagedVersionInsteadOfTheInstalledVersion() {
        val request = FeedbackReservationRequestFactory.from(
            feedbackRecord(
                state = FeedbackState.UPLOADING,
                appVersion = "8.4.1",
            ),
        )

        assertEquals("8.4.1", request.appVersion)
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
        assertFalse(decision.preservesAttemptBudget)
        assertFalse(decision.allowsBoundIdentityContinuity)
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

    private fun feedbackEntries(): List<Pair<String, ByteArray>> = listOf(
        "report.txt" to "NOOP app runtime report\n".toByteArray(),
        "meta.json" to """{"schema":1,"app_version":"9.2.1"}""".toByteArray(),
    )

    private fun stableAuthorizationProvider() = object : FeedbackAuthorizationProvider {
        override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization =
            FeedbackAuthorization(
                appCheckToken = "app-check",
                identityToken = "identity",
                identitySubject = "stable-feedback-owner",
            )
    }

    private fun reservationRecoveryClient(
        recover: suspend (UUID) -> FeedbackReservation?,
    ) = FeedbackAttemptClient(
        provider = stableAuthorizationProvider(),
        transport = object : FeedbackTransport {
            override suspend fun reserve(
                authorization: FeedbackAuthorization,
                idempotencyKey: UUID,
                request: FeedbackReservationRequest,
            ): FeedbackReservation =
                throw AssertionError("Delivery recovery must not create a new reservation")

            override suspend fun recoverReservation(
                authorization: FeedbackAuthorization,
                idempotencyKey: UUID,
            ): FeedbackReservation? = recover(idempotencyKey)

            override suspend fun upload(
                archive: File,
                expectedBytes: Long,
                expectedSha256: String,
                capability: FeedbackUploadCapability,
                progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
            ) = throw AssertionError("Delivery recovery must not upload")

            override suspend fun complete(
                authorization: FeedbackAuthorization,
                reportId: String,
                reportToken: String,
            ): FeedbackRemoteStatus =
                throw AssertionError("Delivery recovery must not complete")

            override suspend fun status(
                authorization: FeedbackAuthorization,
                reportId: String,
                reportToken: String,
            ): FeedbackRemoteStatus =
                throw AssertionError("Delivery recovery must not read status")

            override suspend fun cancel(
                authorization: FeedbackAuthorization,
                reportId: String,
                reportToken: String,
            ): FeedbackRemoteStatus =
                throw AssertionError("Delivery recovery must not cancel by report ID")
        },
    )

    private fun feedbackRecord(
        state: FeedbackState,
        attempt: Int = 0,
        serverReportId: String? = null,
        updatedAtMillis: Long = 1_000L,
        appVersion: String? = "1.0.0",
    ) = FeedbackRecord(
        localId = "11111111-1111-4111-8111-111111111111",
        requestId = "22222222-2222-4222-8222-222222222222",
        appVersion = appVersion,
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
