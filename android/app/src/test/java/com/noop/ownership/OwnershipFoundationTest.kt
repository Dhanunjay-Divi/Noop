package com.noop.ownership

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runTest
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class OwnershipFoundationTest {
    private val configuration = OwnershipConfiguration(
        baseUrl = "https://ownership.noop.example".toHttpUrl(),
        termsHost = "terms.noop.example",
        projectId = "noop-test-project",
        apiKey = "test-api-key",
        googleAppId = "1:123456789:android:abcdef12",
        gcmSenderId = "123456789",
    )
    private val installation = OwnershipInstallationCredential(
        id = "android-installation",
        token = "noopo_" + "A".repeat(43),
    )
    private val authorization = OwnershipAuthorization(
        identityToken = "identity-token",
        appCheckToken = "app-check-token",
        installation = installation,
    )

    @Test
    fun ownershipStateCoordinatorAdmitsOnlyOneConcurrentOperation() {
        val coordinator = OwnershipStateCoordinator(
            OwnershipState(phase = OwnershipPhase.ACCOUNT_READY),
        )
        val workers = 32
        val start = CountDownLatch(1)
        val done = CountDownLatch(workers)
        val admitted = AtomicInteger()
        val executor = Executors.newFixedThreadPool(workers)

        repeat(workers) {
            executor.execute {
                try {
                    start.await()
                    if (coordinator.tryBeginBusy()) {
                        admitted.incrementAndGet()
                    }
                } finally {
                    done.countDown()
                }
            }
        }
        start.countDown()

        assertTrue(done.await(2, TimeUnit.SECONDS))
        executor.shutdownNow()
        assertEquals(1, admitted.get())
        assertTrue(coordinator.state.value.busy)
    }

    @Test
    fun ownershipStateCoordinatorDoesNotLoseConcurrentUpdates() {
        val coordinator = OwnershipStateCoordinator(
            OwnershipState(phase = OwnershipPhase.ACCOUNT_READY),
        )
        val workers = 64
        val start = CountDownLatch(1)
        val done = CountDownLatch(workers)
        val executor = Executors.newFixedThreadPool(workers)

        repeat(workers) {
            executor.execute {
                try {
                    start.await()
                    coordinator.update { current ->
                        current.copy(status = current.status + "x")
                    }
                } finally {
                    done.countDown()
                }
            }
        }
        start.countDown()

        assertTrue(done.await(2, TimeUnit.SECONDS))
        executor.shutdownNow()
        assertEquals(workers, coordinator.state.value.status.length)
    }

    @Test
    fun interruptedReconciliationLeavesProgressForActionableScreen() {
        assertEquals(
            OwnershipPhase.TERMS_REVIEW,
            ownershipReconciliationRecoveryPhase(
                OwnershipPhase.REGISTERING,
            ),
        )
        assertEquals(
            OwnershipPhase.REPLACEMENT_REQUIRED,
            ownershipReconciliationRecoveryPhase(
                OwnershipPhase.AUTHORIZING_REPLACEMENT,
            ),
        )
        OwnershipPhase.entries
            .filterNot {
                it == OwnershipPhase.REGISTERING ||
                    it == OwnershipPhase.AUTHORIZING_REPLACEMENT
            }
            .forEach { phase ->
                assertEquals(
                    phase,
                    ownershipReconciliationRecoveryPhase(phase),
                )
            }
    }

    @Test
    fun changedTermsAlwaysReturnToTermsReview() {
        OwnershipPhase.entries.forEach { phase ->
            assertEquals(
                OwnershipPhase.TERMS_REVIEW,
                ownershipFailureRecoveryPhase(
                    phase = phase,
                    termsChanged = true,
                ),
            )
            assertEquals(
                ownershipReconciliationRecoveryPhase(phase),
                ownershipFailureRecoveryPhase(
                    phase = phase,
                    termsChanged = false,
                ),
            )
        }
    }

    @Test
    fun secureStorageFailureRequiresExplicitLocalRecovery() {
        OwnershipPhase.entries.forEach { phase ->
            assertEquals(
                OwnershipPhase.LOCAL_RECOVERY_REQUIRED,
                ownershipFailureRecoveryPhase(
                    phase = phase,
                    termsChanged = false,
                    secureStorageFailed = true,
                ),
            )
        }
    }

    @Test
    fun cancellationReturnsProgressToAnActionablePhase() {
        assertEquals(
            OwnershipPhase.TERMS_REVIEW,
            ownershipCancellationRecoveryPhase(
                OwnershipPhase.REGISTERING,
                possessionAvailable = false,
            ),
        )
        assertEquals(
            OwnershipPhase.ACCOUNT_READY,
            ownershipCancellationRecoveryPhase(
                OwnershipPhase.CLAIMING,
                possessionAvailable = true,
            ),
        )
        assertEquals(
            OwnershipPhase.POSSESSION_UNAVAILABLE,
            ownershipCancellationRecoveryPhase(
                OwnershipPhase.CLAIMING,
                possessionAvailable = false,
            ),
        )
        assertEquals(
            OwnershipPhase.REPLACEMENT_REQUIRED,
            ownershipCancellationRecoveryPhase(
                OwnershipPhase.AUTHORIZING_REPLACEMENT,
                possessionAvailable = true,
            ),
        )
    }

    @Test
    fun everyPostClaimOnboardingPageRequiresCurrentClaimWhenEnabled() {
        OwnershipPhase.entries.forEach { phase ->
            assertEquals(
                phase == OwnershipPhase.CLAIMED ||
                    phase == OwnershipPhase.COMPLETE,
                ownershipCanAccessPostClaimOnboarding(
                    isAvailable = true,
                    phase = phase,
                ),
            )
        }
        assertTrue(
            ownershipCanAccessPostClaimOnboarding(
                isAvailable = false,
                phase = OwnershipPhase.SIGNED_OUT,
            ),
        )
    }

    @Test
    fun ownershipAccountScopeSeparatesFirebaseProjectsAndSubjects() {
        val baseline = ownershipAccountScope(
            projectId = "noop-staging",
            subject = "same-subject",
        )

        assertNotEquals(
            baseline,
            ownershipAccountScope(
                projectId = "noop-production",
                subject = "same-subject",
            ),
        )
        assertNotEquals(
            baseline,
            ownershipAccountScope(
                projectId = "noop-staging",
                subject = "different-subject",
            ),
        )
        assertNotEquals(
            ownershipAccountScope(projectId = "a", subject = "bc"),
            ownershipAccountScope(projectId = "ab", subject = "c"),
        )
        assertTrue(baseline.matches(Regex("^[0-9a-f]{64}$")))
    }

    @Test
    fun cancellationIsHandledBeforeOwnershipFailureStateMutation() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val bootstrapCatch = source
            .substringAfter("bootstrapJob = serviceScope.launch {")
            .substringBefore("    suspend fun createAccount(")
        val cancellation = bootstrapCatch.indexOf(
            "catch (error: CancellationException)",
        )
        val failure = bootstrapCatch.indexOf("catch (error: Throwable)")
        val mutation = bootstrapCatch.indexOf(
            "val reportedError = reconcileChangedTerms(error)",
        )

        assertTrue(cancellation >= 0)
        assertTrue(failure > cancellation)
        assertTrue(mutation > failure)
        assertFalse(
            bootstrapCatch
                .substring(cancellation, failure)
                .contains("replaceState"),
        )
    }

    @Test
    fun onlyCurrentBackgroundReconciliationCanMutateState() {
        assertTrue(
            ownershipReconciliationMayUpdateState(
                expectedGeneration = null,
                currentGeneration = 8L,
            ),
        )
        assertTrue(
            ownershipReconciliationMayUpdateState(
                expectedGeneration = 8L,
                currentGeneration = 8L,
            ),
        )
        assertFalse(
            ownershipReconciliationMayUpdateState(
                expectedGeneration = 7L,
                currentGeneration = 8L,
            ),
        )

        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        assertTrue(
            source.contains(
                "if (state.value.busy && bootstrapBusyGeneration == null) return",
            ),
        )
        assertTrue(source.contains("bootstrapBusyGeneration = generation"))
        assertTrue(source.contains("checkReconciliation(generation)"))
        assertTrue(source.contains("stale_reconciliation"))
        assertTrue(source.contains("invalidateBootstrapReconciliation()"))
    }

    @Test
    fun bootstrapRestoresEncryptedCheckpointBeforeNetworkReconciliation() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val bootstrap = source
            .substringAfter("bootstrapJob = serviceScope.launch {")
            .substringBefore("    suspend fun createAccount(")
        val checkpoint = bootstrap.indexOf("val checkpoint = checkpoint(user)")
        val localReconciliation = bootstrap.indexOf(
            "reconcileLocal(user, checkpoint)",
        )
        val networkReload = bootstrap.indexOf("user.reload().awaitManaged()")
        val remoteReconciliation = bootstrap.indexOf(
            "reconcileRemote(user, checkpoint, generation)",
        )

        assertTrue(checkpoint >= 0)
        assertTrue(localReconciliation > checkpoint)
        assertTrue(networkReload > localReconciliation)
        assertTrue(remoteReconciliation > networkReload)
    }

    @Test
    fun automaticPhoneVerificationLinksOnlyInTheRequestingCoroutine() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val send = source
            .substringAfter("    suspend fun sendPhoneCode(")
            .substringBefore("    suspend fun linkPhone(")
        val callback = source
            .substringAfter("    private suspend fun requestPhoneVerification(")
            .substringBefore("    private suspend fun perform(")

        assertTrue(
            send.contains(
                "is PhoneVerificationResult.AutomaticallyVerified ->",
            ),
        )
        assertTrue(
            send.contains(
                "user.linkWithCredential(result.credential).awaitManaged()",
            ),
        )
        assertTrue(
            callback.contains(
                "PhoneVerificationResult.AutomaticallyVerified(",
            ),
        )
        assertFalse(callback.contains("serviceScope.launch"))
        assertFalse(callback.contains("linkWithCredential"))
    }

    @Test
    fun canceledOwnershipRequestCancelsOkHttpWithoutBecomingNetworkFailure() =
        runBlocking {
            val started = CountDownLatch(1)
            val canceled = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>()
            val http = OkHttpClient.Builder()
                .addInterceptor { chain ->
                    started.countDown()
                    while (!chain.call().isCanceled()) {
                        Thread.sleep(5)
                    }
                    canceled.countDown()
                    throw IOException("synthetic canceled call")
                }
                .build()
            val client = OwnershipClient(configuration, http)
            val job = launch {
                failure.set(
                    runCatching { client.currentTerms("en") }
                        .exceptionOrNull(),
                )
            }

            assertTrue(
                withContext(Dispatchers.IO) {
                    started.await(1, TimeUnit.SECONDS)
                },
            )
            job.cancel()
            withTimeout(2_000) { job.join() }

            assertTrue(job.isCancelled)
            assertTrue(failure.get() is CancellationException)
            assertTrue(
                withContext(Dispatchers.IO) {
                    canceled.await(1, TimeUnit.SECONDS)
                },
            )
        }

    @Test
    fun checkpointKeepsRetryIdsStableAndRotatesAtTerminalBoundaries() {
        val digest = "a".repeat(64)
        val initial = OwnershipCheckpoint(stage = OwnershipCheckpointStage.TERMS_REVIEW)
        val accepted = initial.acceptTerms("ownership-v1", digest, "en")
        val retried = accepted.acceptTerms("ownership-v1", digest, "en")
        assertEquals(accepted.registrationRequestId, retried.registrationRequestId)
        assertNotEquals(
            accepted.registrationRequestId,
            accepted.completeRegistration().registrationRequestId,
        )
        val invalidated = accepted.invalidateAcceptedTerms()
        assertEquals(OwnershipCheckpointStage.TERMS_REVIEW, invalidated.stage)
        assertNull(invalidated.acceptedPolicyVersion)
        assertNull(invalidated.acceptedPolicySha256)
        assertNull(invalidated.acceptedLocale)
        assertNotEquals(accepted.registrationRequestId, invalidated.registrationRequestId)

        val required = accepted.requireReplacementAuthorization()
        val pending = required.beginReplacementAttempt()
        assertNotEquals(required.replacementRequestId, pending.replacementRequestId)
        val retry = pending.reconcileReplacement(authorized = false)
        assertEquals(OwnershipCheckpointStage.REPLACEMENT_REQUIRED, retry.stage)
        assertNotEquals(pending.replacementRequestId, retry.replacementRequestId)
        assertEquals(
            OwnershipCheckpointStage.COMPLETE,
            retry.beginReplacementAttempt()
                .reconcileReplacement(authorized = true)
                .stage,
        )
    }

    @Test
    fun completedRegistrationReconcilesAnExistingClaimImmediately() {
        val checkpoint = OwnershipCheckpoint(
            stage = OwnershipCheckpointStage.ACCOUNT_REGISTRATION,
            acceptedPolicyVersion = "ownership-v1",
            acceptedPolicySha256 = "a".repeat(64),
            acceptedLocale = "en",
        )
        val unclaimed = accountOverview(bandState = "unclaimed")
        val claimed = accountOverview(bandState = "claimed")

        assertEquals(
            OwnershipCheckpointStage.ACCOUNT_READY,
            checkpoint.completeRegistration(unclaimed).stage,
        )
        assertEquals(
            OwnershipCheckpointStage.CLAIMED,
            checkpoint.completeRegistration(claimed).stage,
        )
    }

    @Test
    fun interruptedPlanSelectionCompletesOnlyForClaimedAccount() {
        val pending = OwnershipCheckpoint(
            stage = OwnershipCheckpointStage.CLAIMED,
        ).beginPlanSelection(NoopProductPlan.NOOP_PLUS)
        val pendingRequest = pending.planRequestId

        val completed = pending.completePlanSelection(bandClaimed = true)

        assertEquals(OwnershipCheckpointStage.COMPLETE, completed.stage)
        assertNull(completed.pendingPlanSelection)
        assertNotEquals(pendingRequest, completed.planRequestId)
        assertTrue(completed.isValid)
    }

    @Test
    fun interruptedPlanSelectionKeepsUnclaimedAccountReady() {
        val pending = OwnershipCheckpoint(
            stage = OwnershipCheckpointStage.ACCOUNT_READY,
        ).beginPlanSelection(NoopProductPlan.NOOP_PLUS)
        val pendingRequest = pending.planRequestId

        val reconciled = pending.completePlanSelection(bandClaimed = false)

        assertEquals(OwnershipCheckpointStage.ACCOUNT_READY, reconciled.stage)
        assertNull(reconciled.pendingPlanSelection)
        assertNotEquals(pendingRequest, reconciled.planRequestId)
        assertTrue(reconciled.isValid)
    }

    @Test
    fun authoritativeBandStateRepairsStaleCompletion() {
        val checkpoint = OwnershipCheckpoint(
            stage = OwnershipCheckpointStage.COMPLETE,
        )

        val unclaimed = checkpoint.reconcileBandState(claimed = false)

        assertEquals(OwnershipCheckpointStage.ACCOUNT_READY, unclaimed.stage)
        assertNotEquals(checkpoint.claimRequestId, unclaimed.claimRequestId)
        assertEquals(
            OwnershipCheckpointStage.CLAIMED,
            unclaimed.reconcileBandState(claimed = true).stage,
        )
    }

    @Test
    fun preAccountTermsRemainAcceptedThroughEmailVerification() {
        val original = OwnershipCheckpoint()
        val captured = original.captureAcceptedTerms(
            policyVersion = "ownership-v1",
            sha256 = "a".repeat(64),
            locale = "en",
        )

        assertEquals(
            OwnershipCheckpointStage.EMAIL_VERIFICATION,
            captured.stage,
        )
        assertTrue(captured.hasAcceptedTerms)
        assertNotEquals(
            original.registrationRequestId,
            captured.registrationRequestId,
        )
        assertTrue(
            captured.copy(
                stage = OwnershipCheckpointStage.ACCOUNT_REGISTRATION,
            ).isValid,
        )
    }

    @Test
    fun persistedInstallationCredentialFailsClosedWhenMalformed() {
        val valid = JSONObject()
            .put("id", "android-installation")
            .put("token", "noopo_" + "A".repeat(43))
            .toString()
        assertEquals(
            installation,
            OwnershipInstallationCredential.decodePersisted(valid),
        )

        listOf(
            "not-json",
            """{"id":"bad id","token":"noopo_123"}""",
            """{"id":"android-installation","token":"wrong"}""",
        ).forEach { persisted ->
            try {
                OwnershipInstallationCredential.decodePersisted(persisted)
                fail("Expected malformed persisted credential rejection")
            } catch (error: OwnershipException) {
                assertSame(OwnershipException.SecureStorage, error)
            }
        }
    }

    @Test
    fun transientCleanupCannotTurnACompletedIdentityOperationIntoFailure() {
        assertTrue(bestEffortOwnershipCleanup { true })
        assertFalse(bestEffortOwnershipCleanup { false })
        assertFalse(
            bestEffortOwnershipCleanup {
                throw IllegalStateException("synthetic secure-store failure")
            },
        )
    }

    @Test
    fun ownershipResetUsesAnIsolatedKeystoreAlias() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipSecureStore.kt"),
            File(
                root,
                "app/src/main/java/com/noop/ownership/OwnershipSecureStore.kt",
            ),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipSecureStore.kt",
            ),
        ).first(File::isFile).readText()

        assertTrue(source.contains("noop_ownership_master_key_v1"))
        assertTrue(
            source.contains(
                "MasterKey.Builder(context.applicationContext, MASTER_KEY_ALIAS)",
            ),
        )
        assertFalse(source.contains("MasterKey.DEFAULT_MASTER_KEY_ALIAS"))
    }

    @Test
    fun emailVerificationStatusFollowsReconciledDestination() {
        assertEquals(
            OwnershipEmailVerificationDestination.TERMS_REVIEW,
            ownershipEmailVerificationDestination(OwnershipPhase.TERMS_REVIEW),
        )
        listOf(
            OwnershipPhase.ACCOUNT_READY,
            OwnershipPhase.POSSESSION_UNAVAILABLE,
        ).forEach { phase ->
            assertEquals(
                OwnershipEmailVerificationDestination.BAND_ACTIVATION,
                ownershipEmailVerificationDestination(phase),
            )
        }
        listOf(
            OwnershipPhase.CLAIMED,
            OwnershipPhase.COMPLETE,
            OwnershipPhase.REPLACEMENT_REQUIRED,
        ).forEach { phase ->
            assertEquals(
                OwnershipEmailVerificationDestination.PRESERVE_RECONCILED_STATUS,
                ownershipEmailVerificationDestination(phase),
            )
        }
    }

    @Test
    fun checkpointParserAcceptsLegacyShapeAndRejectsPartialPolicy() {
        val legacy = JSONObject()
            .put("schema", 1)
            .put("stage", OwnershipCheckpointStage.ACCOUNT_READY.name)
            .put("registration_request_id", UUID.randomUUID().toString())
            .put("claim_request_id", UUID.randomUUID().toString())
            .put("plan_request_id", UUID.randomUUID().toString())
            .put("accepted_policy_version", JSONObject.NULL)
            .put("accepted_policy_sha256", JSONObject.NULL)
            .put("accepted_locale", JSONObject.NULL)
            .put("pending_plan_selection", JSONObject.NULL)
            .toString()
        val decoded = OwnershipCheckpoint.fromJson(legacy)
        assertTrue(decoded?.isValid == true)

        val partial = JSONObject(legacy)
            .put("accepted_policy_version", "ownership-v1")
            .toString()
        assertNull(OwnershipCheckpoint.fromJson(partial))
        assertNull(OwnershipCheckpoint.fromJson("""{"schema":2}"""))

        val unknownPlan = JSONObject(legacy)
            .put("pending_plan_selection", "unknown")
            .toString()
        assertNull(OwnershipCheckpoint.fromJson(unknownPlan))

        val invalidLocale = OwnershipCheckpoint(
            acceptedPolicyVersion = "ownership-v1",
            acceptedPolicySha256 = "a".repeat(64),
            acceptedLocale = "not_a_valid_locale_shape",
        )
        assertFalse(invalidLocale.isValid)
    }

    @Test
    fun checkpointRejectsStructurallyImpossiblePersistedStates() {
        val impossible = listOf(
            OwnershipCheckpoint(
                stage = OwnershipCheckpointStage.ACCOUNT_REGISTRATION,
            ),
            OwnershipCheckpoint(
                stage = OwnershipCheckpointStage.PLAN_SELECTION,
            ),
            OwnershipCheckpoint(
                stage = OwnershipCheckpointStage.COMPLETE,
                pendingPlanSelection = NoopProductPlan.NOOP_PLUS,
            ),
            OwnershipCheckpoint(
                stage = OwnershipCheckpointStage.TERMS_REVIEW,
                acceptedPolicyVersion = "ownership-v1",
                acceptedPolicySha256 = "a".repeat(64),
                acceptedLocale = "en",
            ),
        )

        impossible.forEach { checkpoint ->
            assertFalse(checkpoint.isValid)
            try {
                OwnershipCheckpoint.decodePersisted(checkpoint.toJson())
                fail("Expected malformed persisted checkpoint rejection")
            } catch (error: OwnershipException) {
                assertSame(OwnershipException.SecureStorage, error)
            }
        }
    }

    @Test
    fun changedTermsClearPendingPlanWithoutCorruptingCheckpoint() {
        val pending = OwnershipCheckpoint(
            stage = OwnershipCheckpointStage.TERMS_REVIEW,
        )
            .acceptTerms("ownership-v1", "a".repeat(64), "en")
            .completeRegistration()
            .reconcileClaim(claimed = true)
            .beginPlanSelection(NoopProductPlan.NOOP_PLUS)

        val reset = pending.invalidateAcceptedTerms()

        assertEquals(OwnershipCheckpointStage.TERMS_REVIEW, reset.stage)
        assertNull(reset.pendingPlanSelection)
        assertNotEquals(pending.planRequestId, reset.planRequestId)
        assertTrue(reset.isValid)
    }

    @Test
    fun unavailablePossessionProviderFailsClosed() = runTest {
        assertFalse(UnavailableOwnershipBandPossessionProvider.isAvailable)
        try {
            UnavailableOwnershipBandPossessionProvider.response("challenge")
            fail("Expected unavailable possession provider")
        } catch (error: OwnershipException) {
            assertSame(OwnershipException.PossessionUnavailable, error)
        }
    }

    @Test
    fun configurationRequiresRootHttpsEndpointAndBoundFirebaseValues() {
        OwnershipConfiguration(
            baseUrl = "https://ownership.noop.example/".toHttpUrl(),
            termsHost = "terms.noop.example",
            projectId = "noop-test-project",
            apiKey = "test-api-key",
            googleAppId = "1:123456789:android:abcdef12",
            gcmSenderId = "123456789",
        )
        listOf(
            "https://ownership.noop.example/api/".toHttpUrl(),
            "https://user@ownership.noop.example/".toHttpUrl(),
        ).forEach { endpoint ->
            try {
                OwnershipConfiguration(
                    baseUrl = endpoint,
                    termsHost = "terms.noop.example",
                    projectId = "noop-test-project",
                    apiKey = "test-api-key",
                    googleAppId = "1:123456789:android:abcdef12",
                    gcmSenderId = "123456789",
                )
                fail("Expected invalid ownership endpoint")
            } catch (_: IllegalArgumentException) {
                // Expected.
            }
        }
    }

    @Test
    fun termsDocumentRejectsNonstandardHttpsPort() = runTest {
        var requestCount = 0
        val client = OwnershipClient(
            configuration,
            client { request ->
                requestCount += 1
                response(
                    request,
                    200,
                    """
                    {
                      "policy_version":"ownership-v1",
                      "locale":"en",
                      "document_sha256":"${"a".repeat(64)}",
                      "document_uri":"https://terms.noop.example:8443/ownership-v1/en",
                      "effective_at":"2026-09-05T00:00:00Z"
                    }
                    """.trimIndent(),
                )
            },
        )

        try {
            client.currentTerms("en")
            fail("Expected nonstandard terms port rejection")
        } catch (error: OwnershipException) {
            assertSame(OwnershipException.InvalidResponse, error)
        }
        assertEquals(1, requestCount)
    }

    @Test
    fun bootstrapUsesIdentityAndAppCheckWithoutInstallationCredential() = runTest {
        var captured: Request? = null
        val client = OwnershipClient(
            configuration,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    """
                    {
                      "account_state":"active",
                      "band_state":"claimed",
                      "replacement_authorization_required":true,
                      "terms_acceptance_required":false
                    }
                    """.trimIndent(),
                )
            },
        )

        val status = client.bootstrap(authorization)

        assertEquals("active", status.accountState)
        assertTrue(status.replacementAuthorizationRequired)
        assertEquals("Bearer identity-token", captured!!.header("Authorization"))
        assertEquals("app-check-token", captured!!.header("X-Firebase-AppCheck"))
        assertNull(captured!!.header("X-Noop-Ownership-Installation-ID"))
        assertNull(captured!!.header("X-Noop-Ownership-Installation-Token"))
    }

    @Test
    fun registrationCarriesTheExistingNoopPlusPreference() = runTest {
        var captured: Request? = null
        val client = OwnershipClient(
            configuration,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    """
                    {
                      "account_state":"active",
                      "email_verified":true,
                      "phone_verified":false,
                      "band_state":"unclaimed",
                      "active_installations":1,
                      "plan_selection":"noop_plus",
                      "noop_plus_entitled":false
                    }
                    """.trimIndent(),
                )
            },
        )

        val overview = client.registerAccount(
            requestId = UUID.randomUUID(),
            installation = installation,
            policyVersion = "ownership-v1",
            policySha256 = "a".repeat(64),
            locale = "en",
            plan = NoopProductPlan.NOOP_PLUS,
            authorization = authorization,
        )

        val body = JSONObject(
            okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals("noop_plus", body.getString("plan_selection"))
        assertEquals(NoopProductPlan.NOOP_PLUS, overview.plan)
        assertFalse(overview.noopPlusEntitled)
    }

    @Test
    fun overviewRejectsUnexpectedNoopPlusEntitlement() = runTest {
        val client = OwnershipClient(
            configuration,
            client { request ->
                response(
                    request,
                    200,
                    """
                    {
                      "account_state":"active",
                      "email_verified":true,
                      "phone_verified":false,
                      "band_state":"claimed",
                      "active_installations":1,
                      "plan_selection":"noop_plus",
                      "noop_plus_entitled":true
                    }
                    """.trimIndent(),
                )
            },
        )

        try {
            client.overview(authorization)
            fail("Expected unapproved entitlement rejection")
        } catch (error: OwnershipException) {
            assertSame(OwnershipException.InvalidResponse, error)
        }
    }

    @Test
    fun replacementAuthorizationBindsNewCredentialAndPossession() = runTest {
        var captured: Request? = null
        val client = OwnershipClient(
            configuration,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    """
                    {
                      "installation_state":"active",
                      "installation_id":"android-installation"
                    }
                    """.trimIndent(),
                )
            },
        )
        val challenge = OwnershipChallenge(
            id = UUID.fromString("11111111-1111-4111-8111-111111111111"),
            challenge = "C".repeat(43),
        )

        client.authorizeInstallation(
            requestId = UUID.fromString("22222222-2222-4222-8222-222222222222"),
            challenge = challenge,
            possessionResponse = "signed-possession-response",
            authorization = authorization,
        )

        assertNull(captured!!.header("X-Noop-Ownership-Installation-ID"))
        val body = JSONObject(
            okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals(installation.id, body.getString("new_installation_id"))
        assertEquals(installation.token, body.getString("new_installation_token"))
        assertEquals("android", body.getString("new_platform"))
        assertEquals(challenge.challenge, body.getString("challenge"))
    }

    @Test
    fun challengeValidationAndResponseBoundAreFailClosed() = runTest {
        val malformed = OwnershipClient(
            configuration,
            client { request ->
                response(
                    request,
                    201,
                    """
                    {
                      "challenge_id":"11111111-1111-4111-8111-111111111111",
                      "challenge":"short"
                    }
                    """.trimIndent(),
                )
            },
        )
        try {
            malformed.createChallenge(UUID.randomUUID(), "app-check-token")
            fail("Expected malformed challenge rejection")
        } catch (error: OwnershipException) {
            assertSame(OwnershipException.InvalidResponse, error)
        }

        val oversized = OwnershipClient(
            configuration,
            client { request ->
                response(request, 200, "x".repeat(1024 * 1024 + 1))
            },
        )
        try {
            oversized.bootstrap(authorization)
            fail("Expected oversized response rejection")
        } catch (error: OwnershipException) {
            assertSame(OwnershipException.InvalidResponse, error)
        }
    }

    @Test
    fun registrationDistinguishesChangedTermsFromRequestConflict() = runTest {
        suspend fun failureFor(code: Int): OwnershipException {
            val client = OwnershipClient(
                configuration,
                client { request -> response(request, code, """{"detail":"redacted"}""") },
            )
            return try {
                client.registerAccount(
                    requestId = UUID.randomUUID(),
                    installation = installation,
                    policyVersion = "ownership-v1",
                    policySha256 = "a".repeat(64),
                    locale = "en",
                    plan = NoopProductPlan.NOOP,
                    authorization = authorization,
                )
                fail("Expected registration failure")
                OwnershipException.InvalidResponse
            } catch (error: OwnershipException) {
                error
            }
        }

        assertSame(OwnershipException.TermsChanged, failureFor(412))
        assertSame(OwnershipException.InvalidState, failureFor(409))
    }

    @Test
    fun possessionFailuresDoNotMasqueradeAsIdentityOrOwnershipFailures() = runTest {
        suspend fun claimFailureFor(code: Int): OwnershipException {
            val client = OwnershipClient(
                configuration,
                client { request ->
                    response(request, code, """{"detail":"redacted"}""")
                },
            )
            return try {
                client.claim(
                    requestId = UUID.randomUUID(),
                    challenge = OwnershipChallenge(
                        id = UUID.randomUUID(),
                        challenge = "C".repeat(43),
                    ),
                    possessionResponse = "signed-possession-response",
                    authorization = authorization,
                )
                fail("Expected claim failure")
                OwnershipException.InvalidResponse
            } catch (error: OwnershipException) {
                error
            }
        }

        assertSame(OwnershipException.ChallengeInactive, claimFailureFor(410))
        assertSame(OwnershipException.PossessionRejected, claimFailureFor(422))
        assertSame(OwnershipException.AlreadyClaimed, claimFailureFor(409))
        assertSame(OwnershipException.TermsChanged, claimFailureFor(412))
        assertSame(OwnershipException.Authentication, claimFailureFor(401))
    }

    @Test
    fun ownershipTermsAreSelectableAndDiagnosticsStayCategorical() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ui/OwnershipAccountScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/OwnershipAccountScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/OwnershipAccountScreen.kt"),
        ).first(File::isFile).readText()

        assertTrue(source.contains("SelectionContainer {"))
        assertFalse(source.contains("AppDiagnosticsRecorder"))
    }

    @Test
    fun accountCreationCheckpointPrecedesVerificationDelivery() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val createSource = source
            .substringAfter("    suspend fun createAccount(")
            .substringBefore("    suspend fun signIn(")
        val phase = createSource.indexOf(
            "phase = OwnershipPhase.EMAIL_VERIFICATION",
        )
        val checkpoint = createSource.indexOf(
            "checkpoint(user).captureAcceptedTerms(",
        )
        val delivery = createSource.indexOf(
            "user.sendEmailVerification().awaitManaged()",
        )

        assertTrue(phase >= 0)
        assertTrue(checkpoint > phase)
        assertTrue(delivery > checkpoint)
        assertTrue(createSource.contains("\"identity_created\""))
        assertTrue(source.contains("reportedError == OwnershipException.TermsChanged"))
        assertFalse(source.contains("error == OwnershipException.TermsChanged"))
        val performSource = source
            .substringAfter("    private suspend fun perform(")
            .substringBefore("    private fun reconcileChangedTerms(")
        assertTrue(
            performSource.contains(
                "val reportedError = reconcileChangedTerms(error)",
            ),
        )
        assertTrue(
            performSource.contains("ownershipFailureRecoveryPhase("),
        )
        assertTrue(
            performSource.contains(
                "reportedError == OwnershipException.TermsChanged",
            ),
        )
        assertTrue(performSource.contains("userMessage(reportedError)"))
        assertTrue(performSource.contains("diagnosticOutcome(reportedError)"))
        assertTrue(performSource.contains("diagnosticFailureKind(reportedError)"))
    }

    @Test
    fun interruptedRegistrationAndChangedTermsUseTheSharedRecoveryPath() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val reconcileRemote = source
            .substringAfter("    private suspend fun reconcileRemote(")
            .substringBefore("    private suspend fun reconcileIdentityEntry(")
        val registration = reconcileRemote
            .substringAfter("OwnershipCheckpointStage.ACCOUNT_REGISTRATION -> {")
            .substringBefore("OwnershipCheckpointStage.CLAIM_PENDING ->")
        assertTrue(registration.contains("completeTermsAcceptance("))
        assertFalse(registration.contains("client().registerAccount("))

        val completion = source
            .substringAfter("    private suspend fun completeTermsAcceptance(")
            .substringBefore("    suspend fun claimBand()")
        val accepted = completion.indexOf("!bootstrap.termsAcceptanceRequired")
        val overview = completion.indexOf("client().overview(", accepted)
        val register = completion.indexOf("client().registerAccount(", overview)
        assertTrue(accepted >= 0)
        assertTrue(overview > accepted)
        assertTrue(register > overview)
        assertTrue(completion.contains("\"registration_reconciled\""))

        val identityEntry = source
            .substringAfter("    private suspend fun reconcileIdentityEntry(")
            .substringBefore("    private suspend fun reconcilePendingClaim(")
        val terms = identityEntry.indexOf("bootstrap.termsAcceptanceRequired")
        val replacement = identityEntry.indexOf(
            "bootstrap.replacementAuthorizationRequired",
        )
        assertTrue(terms >= 0)
        assertTrue(replacement > terms)
        assertTrue(identityEntry.contains("checkpoint.invalidateAcceptedTerms()"))
        assertTrue(identityEntry.contains("terms = null"))
    }

    @Test
    fun planSelectionConfirmsRemoteOrDefersWithoutBlockingCore() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(root, "app/src/main/java/com/noop/ownership/OwnershipService.kt"),
            File(
                root,
                "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
            ),
        ).first(File::isFile).readText()
        val block = source
            .substringAfter(
                "    suspend fun selectPlan(plan: NoopProductPlan): Boolean",
            )
            .substringBefore("    suspend fun refreshOverview()")
        val busyAdmission = block.indexOf("if (!beginBusy()) return false")
        val remoteWrite = block.indexOf("client().selectPlan(")
        val readBack = block.indexOf("val overview = client().overview(")
        val persisted = block.indexOf("plan.persist(appContext)", busyAdmission)
        val completion = block.indexOf(
            "checkpoint.completePlanSelection(",
            readBack,
        )
        val deferred = block.indexOf("outcome = \"deferred\"", completion)

        assertTrue(block.contains("if (!isAvailable)"))
        assertTrue(block.contains("return true"))
        assertTrue(block.contains("R.string.ownership_plan_saved_locally"))
        assertTrue(busyAdmission >= 0)
        assertTrue(remoteWrite >= 0)
        assertTrue(persisted in (busyAdmission + 1) until remoteWrite)
        assertTrue(readBack > remoteWrite)
        assertTrue(completion > readBack)
        assertTrue(deferred > completion)
    }

    private fun client(block: (Request) -> Response): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(Interceptor { chain -> block(chain.request()) })
            .build()

    private fun accountOverview(bandState: String) = OwnershipAccountOverview(
        accountState = "active",
        emailVerified = true,
        phoneVerified = false,
        bandState = bandState,
        activeInstallations = 1,
        plan = NoopProductPlan.NOOP,
        noopPlusEntitled = false,
    )

    private fun response(request: Request, code: Int, body: String): Response =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message(if (code in 200..299) "OK" else "Error")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
}
