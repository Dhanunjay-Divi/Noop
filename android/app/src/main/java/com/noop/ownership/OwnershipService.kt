package com.noop.ownership

import android.app.Activity
import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseException
import com.google.firebase.FirebaseOptions
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthException
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.PhoneAuthCredential
import com.google.firebase.auth.PhoneAuthOptions
import com.google.firebase.auth.PhoneAuthProvider
import com.google.firebase.auth.PhoneAuthProvider.ForceResendingToken
import com.noop.AppDiagnosticsRecorder
import com.noop.R
import com.noop.managed.ManagedAppCheckProvider
import com.noop.managed.awaitManaged
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class OwnershipService private constructor(
    context: Context,
    private val possessionProvider: OwnershipBandPossessionProvider =
        UnavailableOwnershipBandPossessionProvider,
) {
    private data class FirebaseRuntime(
        val auth: FirebaseAuth,
        val appCheck: FirebaseAppCheck,
    )

    private sealed class PhoneVerificationResult {
        data class CodeSent(val verificationId: String) :
            PhoneVerificationResult()

        data class AutomaticallyVerified(
            val credential: PhoneAuthCredential,
        ) : PhoneVerificationResult()
    }

    private val appContext = context.applicationContext
    private val configuration = OwnershipConfiguration.load()
    @Volatile
    private var secureStoreInstance: OwnershipSecureStore? = null
    private val ownershipClient by lazy {
        configuration?.let(::OwnershipClient)
    }
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val stateCoordinator = OwnershipStateCoordinator(
        OwnershipState(
            phase = if (configuration == null) {
                OwnershipPhase.UNAVAILABLE
            } else {
                OwnershipPhase.SIGNED_OUT
            },
            busy = configuration != null,
        ),
    )
    val state: StateFlow<OwnershipState> = stateCoordinator.state

    private val firebaseLock = Any()
    @Volatile
    private var firebaseRuntime: FirebaseRuntime? = null
    private var bootstrapJob: Job? = null
    private var bootstrapGeneration = 0L
    private var bootstrapBusyGeneration: Long? =
        if (configuration == null) null else bootstrapGeneration

    val isAvailable: Boolean get() = configuration != null
    val possessionAvailable: Boolean get() = possessionProvider.isAvailable

    fun bootstrap() {
        serviceScope.launch {
            startBootstrapReconciliation()
        }
    }

    private fun startBootstrapReconciliation() {
        if (configuration == null) {
            replaceState {
                it.copy(
                    phase = OwnershipPhase.UNAVAILABLE,
                    busy = false,
                    status = text(R.string.ownership_unavailable_status),
                )
            }
            return
        }
        if (state.value.busy && bootstrapBusyGeneration == null) return
        val generation = invalidateBootstrapReconciliation()
        bootstrapBusyGeneration = generation
        replaceState { it.copy(busy = true) }
        bootstrapJob = serviceScope.launch {
            val operation = AppDiagnosticsRecorder.beginOperation(
                "ownership.account.reconcile",
            )
            try {
                checkReconciliation(generation)
                val user = runtime().auth.currentUser
                if (user == null) {
                    replaceState {
                        it.copy(
                            phase = OwnershipPhase.SIGNED_OUT,
                            maskedEmail = "",
                        )
                    }
                    AppDiagnosticsRecorder.endOperation(operation)
                    return@launch
                }
                val checkpoint = checkpoint(user)
                checkReconciliation(generation)
                reconcileLocal(user, checkpoint)
                user.reload().awaitManaged()
                checkReconciliation(generation)
                reconcileRemote(user, checkpoint, generation)
                checkReconciliation(generation)
                AppDiagnosticsRecorder.endOperation(operation)
            } catch (error: CancellationException) {
                AppDiagnosticsRecorder.endOperation(
                    operation,
                    outcome = "canceled",
                    fields = mapOf("failure_kind" to "canceled"),
                )
                throw error
            } catch (error: Throwable) {
                if (!reconciliationMayUpdateState(generation)) {
                    AppDiagnosticsRecorder.endOperation(
                        operation,
                        outcome = "canceled",
                        fields = mapOf(
                            "failure_kind" to "stale_reconciliation",
                        ),
                    )
                    return@launch
                }
                val reportedError = reconcileChangedTerms(error)
                replaceState {
                    it.copy(
                        phase = ownershipFailureRecoveryPhase(
                            phase = it.phase,
                            termsChanged =
                                reportedError == OwnershipException.TermsChanged,
                            secureStorageFailed =
                                reportedError == OwnershipException.SecureStorage,
                        ),
                        busy = false,
                        status = userMessage(reportedError),
                        terms = if (
                            reportedError == OwnershipException.TermsChanged ||
                            reportedError == OwnershipException.SecureStorage
                        ) {
                            null
                        } else {
                            it.terms
                        },
                    )
                }
                AppDiagnosticsRecorder.endOperation(
                    operation,
                    outcome = diagnosticOutcome(reportedError),
                    fields = mapOf(
                        "failure_kind" to diagnosticFailureKind(reportedError),
                    ),
                )
            } finally {
                if (
                    reconciliationMayUpdateState(generation) &&
                    bootstrapBusyGeneration == generation
                ) {
                    bootstrapBusyGeneration = null
                    bootstrapJob = null
                    replaceState { it.copy(busy = false) }
                }
            }
        }
    }

    suspend fun createAccount(
        rawEmail: String,
        password: String,
        confirmation: String,
        acceptedTerms: Boolean,
    ) {
        var accountCreated = false
        perform(
            operationName = "ownership.identity.create",
            failureProgress = {
                if (accountCreated) "identity_created" else "not_created"
            },
        ) {
            val terms = state.value.terms
                ?.takeIf { acceptedTerms }
                ?: throw OwnershipException.TermsRequired
            val email = normalizedEmail(rawEmail)
            validatePassword(password, confirmation)
            val result = runtime().auth
                .createUserWithEmailAndPassword(email, password)
                .awaitManaged()
            val user = result.user ?: throw OwnershipException.InvalidResponse
            accountCreated = true
            replaceState {
                it.copy(
                    phase = OwnershipPhase.EMAIL_VERIFICATION,
                    maskedEmail = maskEmail(user.email),
                )
            }
            save(
                user,
                checkpoint(user).captureAcceptedTerms(
                    policyVersion = terms.policyVersion,
                    sha256 = terms.sha256,
                    locale = terms.locale,
                ),
            )
            user.sendEmailVerification().awaitManaged()
            replaceState {
                it.copy(
                    status = text(R.string.ownership_email_verification_sent),
                )
            }
        }
    }

    suspend fun signIn(rawEmail: String, password: String) =
        perform("ownership.identity.sign_in") {
            val email = normalizedEmail(rawEmail)
            if (password.isEmpty() || password.length > 128) {
                throw OwnershipException.InvalidCredentials
            }
            val result = runtime().auth
                .signInWithEmailAndPassword(email, password)
                .awaitManaged()
            val user = result.user ?: throw OwnershipException.InvalidResponse
            user.reload().awaitManaged()
            val checkpoint = checkpoint(user)
            reconcileLocal(user, checkpoint)
            reconcileRemote(user, checkpoint)
            replaceState {
                it.copy(
                    status = if (!user.isEmailVerified) {
                        text(R.string.ownership_email_verification_required)
                    } else if (it.status.isBlank()) {
                        text(R.string.ownership_signed_in)
                    } else {
                        it.status
                    },
                    maskedEmail = maskEmail(user.email),
                )
            }
        }

    suspend fun resendEmailVerification() =
        perform("ownership.identity.resend_verification") {
            currentUser().sendEmailVerification().awaitManaged()
            replaceState {
                it.copy(
                    phase = OwnershipPhase.EMAIL_VERIFICATION,
                    status = text(R.string.ownership_email_verification_resent),
                )
            }
        }

    suspend fun checkEmailVerification() =
        perform("ownership.identity.refresh_verification") {
            val user = currentUser()
            user.reload().awaitManaged()
            if (!user.isEmailVerified) {
                replaceState {
                    it.copy(
                        phase = OwnershipPhase.EMAIL_VERIFICATION,
                        status = text(R.string.ownership_email_verification_pending),
                    )
                }
                return@perform
            }
            var checkpoint = checkpoint(user)
            checkpoint = checkpoint.copy(
                stage = if (checkpoint.hasAcceptedTerms) {
                    OwnershipCheckpointStage.ACCOUNT_REGISTRATION
                } else {
                    OwnershipCheckpointStage.TERMS_REVIEW
                },
            )
            if (checkpoint.hasAcceptedTerms) {
                reconcileRemote(user, checkpoint)
                when (
                    ownershipEmailVerificationDestination(state.value.phase)
                ) {
                    OwnershipEmailVerificationDestination.BAND_ACTIVATION ->
                        replaceState {
                            it.copy(
                                status = text(
                                    R.string
                                        .ownership_email_verified_activation,
                                ),
                            )
                        }
                    OwnershipEmailVerificationDestination.TERMS_REVIEW ->
                        replaceState {
                            it.copy(
                                status = text(
                                    R.string.ownership_email_verified,
                                ),
                            )
                        }
                    OwnershipEmailVerificationDestination
                        .PRESERVE_RECONCILED_STATUS -> Unit
                }
            } else {
                save(user, checkpoint)
                replaceState {
                    it.copy(
                        phase = OwnershipPhase.TERMS_REVIEW,
                        status = text(R.string.ownership_email_verified),
                    )
                }
            }
        }

    suspend fun sendPasswordReset(rawEmail: String) {
        if (!beginBusy()) return
        val operation = AppDiagnosticsRecorder.beginOperation(
            "ownership.identity.password_reset",
        )
        try {
            val email = normalizedEmail(rawEmail)
            runtime().auth.sendPasswordResetEmail(email).awaitManaged()
            replaceState {
                it.copy(status = text(R.string.ownership_password_reset_generic))
            }
            AppDiagnosticsRecorder.endOperation(operation)
        } catch (error: CancellationException) {
            replaceState {
                it.copy(
                    phase = ownershipCancellationRecoveryPhase(
                        phase = it.phase,
                        possessionAvailable = possessionProvider.isAvailable,
                    ),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            replaceState {
                it.copy(status = text(R.string.ownership_password_reset_generic))
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = diagnosticOutcome(error),
                fields = mapOf("failure_kind" to diagnosticFailureKind(error)),
            )
        } finally {
            endBusy()
        }
    }

    suspend fun loadTerms(forAccountCreation: Boolean = false) =
        perform("ownership.terms.fetch") {
            val terms = client().currentTerms(preferredLocale())
            replaceState {
                it.copy(
                    phase = if (forAccountCreation) {
                        OwnershipPhase.SIGNED_OUT
                    } else {
                        OwnershipPhase.TERMS_REVIEW
                    },
                    terms = terms,
                    status = text(R.string.ownership_terms_loaded),
                )
            }
        }

    suspend fun acceptTermsAndRegister() =
        perform("ownership.account.register") {
            val terms = state.value.terms ?: throw OwnershipException.TermsRequired
            val user = currentUser()
            user.reload().awaitManaged()
            if (!user.isEmailVerified) {
                throw OwnershipException.EmailVerificationRequired
            }
            var checkpoint = checkpoint(user).acceptTerms(
                terms.policyVersion,
                terms.sha256,
                terms.locale,
            )
            save(user, checkpoint)
            checkpoint = completeTermsAcceptance(
                user = user,
                checkpoint = checkpoint,
                policyVersion = terms.policyVersion,
                policySha256 = terms.sha256,
                locale = terms.locale,
            )
        }

    private suspend fun completeTermsAcceptance(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
        policyVersion: String,
        policySha256: String,
        locale: String,
        generation: Long? = null,
    ): OwnershipCheckpoint {
        checkReconciliation(generation)
        val authorization = authorization(forceRefresh = true)
        val bootstrap = client().bootstrap(authorization)
        checkReconciliation(generation)
        if (
            bootstrap.accountState == "active" &&
            !bootstrap.termsAcceptanceRequired
        ) {
            try {
                val overview = client().overview(authorization)
                val installations = client().installations(authorization)
                checkReconciliation(generation)
                val completed = checkpoint.completeRegistration(overview)
                save(user, completed)
                overview.plan.persist(appContext)
                replaceState {
                    it.copy(
                        phase = phaseForOverview(overview, completed),
                        terms = null,
                        overview = overview,
                        installations = installations,
                        status = when {
                            overview.bandState == "claimed" -> text(
                                R.string.ownership_current_terms_accepted,
                            )
                            possessionProvider.isAvailable -> text(
                                R.string.ownership_account_ready,
                            )
                            else -> text(
                                R.string.ownership_possession_sdk_pending,
                            )
                        },
                    )
                }
                AppDiagnosticsRecorder.record(
                    "ownership.lifecycle",
                    mapOf(
                        "phase" to "terms_recovery",
                        "outcome" to "registration_reconciled",
                    ),
                )
                return completed
            } catch (error: OwnershipException) {
                checkReconciliation(generation)
                if (
                    error != OwnershipException.Authentication &&
                    error != OwnershipException.InvalidState
                ) {
                    throw error
                }
                if (bootstrap.bandState == "claimed") {
                    val replacement = checkpoint.requireReplacementAuthorization()
                    save(user, replacement)
                    replaceState {
                        it.copy(
                            phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                            terms = null,
                            overview = null,
                            installations = emptyList(),
                            status = text(
                                R.string.ownership_terms_accepted_replacement,
                            ),
                        )
                    }
                    AppDiagnosticsRecorder.record(
                        "ownership.lifecycle",
                        mapOf(
                            "phase" to "terms_recovery",
                            "outcome" to "replacement_required",
                        ),
                    )
                    return replacement
                }
            }
        }
        if (
            bootstrap.accountState == "active" &&
            bootstrap.bandState == "claimed"
        ) {
            client().acceptTerms(
                requestId = checkpoint.registrationRequestId,
                policyVersion = policyVersion,
                policySha256 = policySha256,
                locale = locale,
                authorization = authorization,
            )
            checkReconciliation(generation)
            return try {
                val overview = client().overview(authorization)
                val installations = client().installations(authorization)
                checkReconciliation(generation)
                if (overview.bandState != "claimed") {
                    throw OwnershipException.InvalidResponse
                }
                val completed = checkpoint.completeRegistration(overview)
                save(user, completed)
                overview.plan.persist(appContext)
                replaceState {
                    it.copy(
                        phase = OwnershipPhase.CLAIMED,
                        terms = null,
                        overview = overview,
                        installations = installations,
                        status = text(
                            R.string.ownership_current_terms_accepted,
                        ),
                    )
                }
                AppDiagnosticsRecorder.record(
                    "ownership.lifecycle",
                    mapOf(
                        "phase" to "terms_recovery",
                        "outcome" to "installation_restored",
                    ),
                )
                completed
            } catch (error: OwnershipException) {
                checkReconciliation(generation)
                if (
                    error != OwnershipException.Authentication &&
                    error != OwnershipException.InvalidState
                ) {
                    throw error
                }
                val replacement = checkpoint.requireReplacementAuthorization()
                save(user, replacement)
                replaceState {
                    it.copy(
                        phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                        terms = null,
                        overview = null,
                        installations = emptyList(),
                        status = text(
                            R.string.ownership_terms_accepted_replacement,
                        ),
                    )
                }
                AppDiagnosticsRecorder.record(
                    "ownership.lifecycle",
                    mapOf(
                        "phase" to "terms_recovery",
                        "outcome" to "replacement_required",
                    ),
                )
                replacement
            }
        }

        val account = client().registerAccount(
            requestId = checkpoint.registrationRequestId,
            installation = authorization.installation,
            policyVersion = policyVersion,
            policySha256 = policySha256,
            locale = locale,
            plan = NoopProductPlan.stored(appContext),
            authorization = authorization,
        )
        checkReconciliation(generation)
        val completed = checkpoint.completeRegistration(account)
        save(user, completed)
        replaceState {
            it.copy(
                phase = phaseForOverview(account, completed),
                terms = null,
                overview = account,
                status = if (possessionProvider.isAvailable) {
                    text(R.string.ownership_account_ready)
                } else {
                    text(R.string.ownership_possession_sdk_pending)
                },
            )
        }
        AppDiagnosticsRecorder.record(
            "ownership.lifecycle",
            mapOf(
                "phase" to "terms_recovery",
                "outcome" to if (account.bandState == "claimed") {
                    "account_restored"
                } else {
                    "account_registered"
                },
            ),
        )
        return completed
    }

    suspend fun claimBand() {
        if (!possessionProvider.isAvailable) {
            replaceState {
                it.copy(
                    phase = OwnershipPhase.POSSESSION_UNAVAILABLE,
                    status = text(R.string.ownership_possession_sdk_pending),
                )
            }
            AppDiagnosticsRecorder.record(
                "ownership.lifecycle",
                mapOf("phase" to "claim", "outcome" to "provider_unavailable"),
            )
            return
        }
        perform("ownership.band.claim") {
            val user = currentUser()
            var checkpoint = checkpoint(user)
            if (checkpoint.stage == OwnershipCheckpointStage.CLAIM_PENDING) {
                val claimed = reconcilePendingClaim(user, checkpoint)
                checkpoint = checkpoint(user)
                if (claimed) return@perform
            }
            checkpoint = checkpoint.beginClaimAttempt()
            save(user, checkpoint)
            replaceState { it.copy(phase = OwnershipPhase.CLAIMING) }
            val authorization = authorization(forceRefresh = true)
            val challenge = client().createChallenge(
                requestId = UUID.randomUUID(),
                appCheckToken = authorization.appCheckToken,
            )
            val response = possessionProvider.response(challenge.challenge)
            client().claim(
                requestId = checkpoint.claimRequestId,
                challenge = challenge,
                possessionResponse = response,
                authorization = authorization,
            )
            val overview = client().overview(authorization)
            checkpoint = checkpoint.reconcileClaim(claimed = true)
            save(user, checkpoint)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.CLAIMED,
                    overview = overview,
                    status = text(R.string.ownership_band_claimed),
                )
            }
        }
    }

    suspend fun authorizeReplacementPhone() {
        if (!possessionProvider.isAvailable) {
            replaceState {
                it.copy(
                    phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                    status = text(R.string.ownership_replacement_sdk_pending),
                )
            }
            AppDiagnosticsRecorder.record(
                "ownership.lifecycle",
                mapOf(
                    "phase" to "installation_authorize",
                    "outcome" to "provider_unavailable",
                ),
            )
            return
        }
        perform("ownership.installation.authorize") {
            val user = currentUser()
            var checkpoint = checkpoint(user)
            if (checkpoint.stage == OwnershipCheckpointStage.REPLACEMENT_PENDING) {
                if (reconcilePendingReplacement(user, checkpoint)) {
                    return@perform
                }
                checkpoint = checkpoint(user)
            }
            if (checkpoint.stage != OwnershipCheckpointStage.REPLACEMENT_REQUIRED) {
                checkpoint = checkpoint.requireReplacementAuthorization()
            }
            checkpoint = checkpoint.beginReplacementAttempt()
            save(user, checkpoint)
            replaceState {
                it.copy(phase = OwnershipPhase.AUTHORIZING_REPLACEMENT)
            }
            val authorization = authorization(forceRefresh = true)
            val challenge = client().createChallenge(
                requestId = UUID.randomUUID(),
                appCheckToken = authorization.appCheckToken,
            )
            val response = possessionProvider.response(challenge.challenge)
            client().authorizeInstallation(
                requestId = checkpoint.replacementRequestId,
                challenge = challenge,
                possessionResponse = response,
                authorization = authorization,
            )
            val overview = client().overview(authorization)
            if (overview.bandState != "claimed") {
                throw OwnershipException.InvalidResponse
            }
            checkpoint = checkpoint.reconcileReplacement(authorized = true)
            save(user, checkpoint)
            overview.plan.persist(appContext)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.COMPLETE,
                    overview = overview,
                    status = text(R.string.ownership_replacement_authorized),
                )
            }
            refreshOverviewData(forceRefresh = false)
        }
    }

    suspend fun selectPlan(plan: NoopProductPlan): Boolean {
        if (!isAvailable) {
            plan.persist(appContext)
            replaceState {
                it.copy(status = planStatus(plan))
            }
            AppDiagnosticsRecorder.record(
                "ownership.plan_local",
                mapOf("selection" to plan.storedValue),
            )
            return true
        }
        if (!beginBusy()) return false
        plan.persist(appContext)
        val operation = AppDiagnosticsRecorder.beginOperation(
            "ownership.plan.select",
        )
        return try {
            val user = currentUser()
            var checkpoint = checkpoint(user).beginPlanSelection(plan)
            save(user, checkpoint)
            val authorization = authorization(forceRefresh = false)
            client().selectPlan(
                plan = plan,
                requestId = checkpoint.planRequestId,
                authorization = authorization,
            )
            val overview = client().overview(authorization)
            if (overview.plan != plan) {
                throw OwnershipException.InvalidResponse
            }
            checkpoint = checkpoint.completePlanSelection(
                bandClaimed = overview.bandState == "claimed",
            )
            save(user, checkpoint)
            replaceState {
                it.copy(
                    phase = phaseForOverview(overview, checkpoint),
                    overview = overview,
                    status = planStatus(plan),
                )
            }
            recordPlanSelectionResolution(
                bandClaimed = overview.bandState == "claimed",
            )
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = plan.storedValue,
            )
            true
        } catch (error: CancellationException) {
            replaceState {
                it.copy(
                    phase = ownershipCancellationRecoveryPhase(
                        phase = it.phase,
                        possessionAvailable = possessionProvider.isAvailable,
                    ),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            val reportedError = reconcileChangedTerms(error)
            replaceState { current ->
                current.copy(
                    phase = ownershipFailureRecoveryPhase(
                        phase = current.phase,
                        termsChanged =
                            reportedError == OwnershipException.TermsChanged,
                        secureStorageFailed =
                            reportedError == OwnershipException.SecureStorage,
                    ),
                    status = text(R.string.ownership_plan_saved_locally),
                    terms = if (
                        reportedError == OwnershipException.TermsChanged ||
                        reportedError == OwnershipException.SecureStorage
                    ) {
                        null
                    } else {
                        current.terms
                    },
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = "deferred",
                fields = mapOf(
                    "failure_kind" to diagnosticFailureKind(reportedError),
                    "local_state" to "saved",
                ),
            )
            true
        } finally {
            endBusy()
        }
    }

    suspend fun refreshOverview() =
        perform("ownership.account.refresh") {
            refreshOverviewData(forceRefresh = false)
            val user = currentUser()
            val checkpoint = checkpoint(user)
            if (checkpoint.stage == OwnershipCheckpointStage.PLAN_SELECTION) {
                val (resolved, overview) = reconcilePendingPlanSelection(
                    user = user,
                    checkpoint = checkpoint,
                    initialOverview = state.value.overview,
                )
                replaceState {
                    it.copy(
                        phase = phaseForOverview(overview, resolved),
                        overview = overview,
                    )
                }
            }
        }

    suspend fun sendPhoneCode(activity: Activity, rawPhone: String) =
        perform("ownership.identity.phone_send") {
            val phone = normalizedPhone(rawPhone)
            val user = currentUser()
            if (!user.isEmailVerified) {
                throw OwnershipException.EmailVerificationRequired
            }
            when (
                val result = requestPhoneVerification(activity, phone)
            ) {
                is PhoneVerificationResult.AutomaticallyVerified -> {
                    user.linkWithCredential(result.credential).awaitManaged()
                    val cleanupCompleted = secureStore().clearPhoneVerificationId(
                        accountScope(user),
                    )
                    if (!cleanupCompleted) {
                        AppDiagnosticsRecorder.record(
                            "ownership.lifecycle",
                            mapOf(
                                "phase" to "phone_verification_cleanup",
                                "outcome" to "deferred",
                            ),
                        )
                    }
                    refreshOverviewData(forceRefresh = true)
                    replaceState {
                        it.copy(
                            status = text(R.string.ownership_phone_verified),
                        )
                    }
                }
                is PhoneVerificationResult.CodeSent -> {
                    secureStore().writePhoneVerificationId(
                        accountScope(user),
                        result.verificationId,
                    )
                    replaceState {
                        it.copy(
                            status = text(R.string.ownership_phone_code_sent),
                        )
                    }
                }
            }
        }

    suspend fun linkPhone(rawCode: String) =
        perform("ownership.identity.phone_link") {
            val code = normalizedCode(rawCode)
            val user = currentUser()
            val scope = accountScope(user)
            val verificationId = secureStore().phoneVerificationId(scope)
                ?: throw OwnershipException.PhoneCodeRequired
            val credential = PhoneAuthProvider.getCredential(
                verificationId,
                code,
            )
            user.linkWithCredential(credential).awaitManaged()
            val cleanupCompleted = secureStore().clearPhoneVerificationId(scope)
            if (!cleanupCompleted) {
                AppDiagnosticsRecorder.record(
                    "ownership.lifecycle",
                    mapOf(
                        "phase" to "phone_verification_cleanup",
                        "outcome" to "deferred",
                    ),
                )
            }
            refreshOverviewData(forceRefresh = true)
            replaceState {
                it.copy(status = text(R.string.ownership_phone_verified))
            }
        }

    suspend fun revokeInstallation(installation: OwnershipInstallation) {
        if (installation.current) return
        perform("ownership.installation.revoke") {
            client().revokeInstallation(
                installation.id,
                authorization(forceRefresh = true),
            )
            replaceState {
                it.copy(
                    installations = it.installations.filterNot { row ->
                        row.id == installation.id
                    },
                    status = text(R.string.ownership_installation_revoked),
                )
            }
        }
    }

    fun signOut() {
        if (!beginBusy()) return
        val operation = AppDiagnosticsRecorder.beginOperation(
            "ownership.identity.sign_out",
        )
        try {
            val runtime = runtime()
            val scope = runtime.auth.currentUser?.let(::accountScope)
            invalidateBootstrapReconciliation()
            runtime.auth.signOut()
            replaceState {
                OwnershipState(
                    phase = OwnershipPhase.SIGNED_OUT,
                    status = text(R.string.ownership_signed_out),
                )
            }
            val cleanupOutcome = if (scope == null) {
                "not_needed"
            } else if (secureStore().clearPhoneVerificationId(scope)) {
                "completed"
            } else {
                "deferred"
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                fields = mapOf("cleanup_outcome" to cleanupOutcome),
            )
        } catch (error: Throwable) {
            replaceState {
                it.copy(
                    phase = if (error == OwnershipException.SecureStorage) {
                        OwnershipPhase.LOCAL_RECOVERY_REQUIRED
                    } else {
                        it.phase
                    },
                    status = userMessage(error),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = diagnosticOutcome(error),
                fields = mapOf("failure_kind" to diagnosticFailureKind(error)),
            )
        } finally {
            endBusy()
        }
    }

    fun resetLocalOwnershipSetup() {
        if (
            state.value.phase != OwnershipPhase.LOCAL_RECOVERY_REQUIRED ||
            !beginBusy()
        ) {
            return
        }
        val operation = AppDiagnosticsRecorder.beginOperation(
            "ownership.local_security.reset",
        )
        try {
            invalidateBootstrapReconciliation()
            if (!OwnershipSecureStore.resetAll(appContext)) {
                throw OwnershipException.SecureStorage
            }
            secureStoreInstance = null
            runtime().auth.signOut()
            replaceState {
                OwnershipState(
                    phase = OwnershipPhase.SIGNED_OUT,
                    busy = true,
                    status = text(R.string.ownership_local_reset_complete),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = "completed",
            )
        } catch (error: Throwable) {
            replaceState {
                it.copy(
                    phase = if (error == OwnershipException.SecureStorage) {
                        OwnershipPhase.LOCAL_RECOVERY_REQUIRED
                    } else {
                        OwnershipPhase.UNAVAILABLE
                    },
                    status = userMessage(error),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = diagnosticOutcome(error),
                fields = mapOf("failure_kind" to diagnosticFailureKind(error)),
            )
        } finally {
            endBusy()
        }
    }

    private suspend fun reconcileRemote(
        user: FirebaseUser,
        initialCheckpoint: OwnershipCheckpoint,
        generation: Long? = null,
    ) {
        checkReconciliation(generation)
        if (!user.isEmailVerified) return
        var checkpoint = initialCheckpoint
        if (
            checkpoint.stage == OwnershipCheckpointStage.EMAIL_VERIFICATION &&
            checkpoint.hasAcceptedTerms
        ) {
            checkpoint = checkpoint.copy(
                stage = OwnershipCheckpointStage.ACCOUNT_REGISTRATION,
            )
            save(user, checkpoint)
        }
        when (checkpoint.stage) {
            OwnershipCheckpointStage.ACCOUNT_REGISTRATION -> {
                val policyVersion = checkpoint.acceptedPolicyVersion
                    ?: throw OwnershipException.InvalidState
                val policySha256 = checkpoint.acceptedPolicySha256
                    ?: throw OwnershipException.InvalidState
                val locale = checkpoint.acceptedLocale
                    ?: throw OwnershipException.InvalidState
                replaceState { it.copy(phase = OwnershipPhase.REGISTERING) }
                checkpoint = completeTermsAcceptance(
                    user = user,
                    checkpoint = checkpoint,
                    policyVersion = policyVersion,
                    policySha256 = policySha256,
                    locale = locale,
                    generation = generation,
                )
            }
            OwnershipCheckpointStage.CLAIM_PENDING -> {
                reconcilePendingClaim(user, checkpoint, generation)
            }
            OwnershipCheckpointStage.ACCOUNT_READY,
            OwnershipCheckpointStage.CLAIMED,
            OwnershipCheckpointStage.PLAN_SELECTION,
            OwnershipCheckpointStage.COMPLETE,
            -> {
                refreshOverviewData(
                    forceRefresh = false,
                    generation = generation,
                )
                var overview = state.value.overview
                    ?: throw OwnershipException.InvalidResponse
                checkpoint = checkpoint(user)
                if (checkpoint.stage == OwnershipCheckpointStage.PLAN_SELECTION) {
                    val reconciled = reconcilePendingPlanSelection(
                        user = user,
                        checkpoint = checkpoint,
                        initialOverview = overview,
                        generation = generation,
                    )
                    checkpoint = reconciled.first
                    overview = reconciled.second
                }
                replaceState {
                    it.copy(phase = phaseForOverview(overview, checkpoint))
                }
            }
            OwnershipCheckpointStage.REPLACEMENT_REQUIRED -> {
                replaceState {
                    it.copy(
                        phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                        status = text(R.string.ownership_replacement_required),
                    )
                }
            }
            OwnershipCheckpointStage.REPLACEMENT_PENDING -> {
                reconcilePendingReplacement(user, checkpoint, generation)
            }
            OwnershipCheckpointStage.SIGNED_OUT,
            OwnershipCheckpointStage.EMAIL_VERIFICATION,
            OwnershipCheckpointStage.TERMS_REVIEW,
            -> reconcileIdentityEntry(user, checkpoint, generation)
        }
        checkReconciliation(generation)
    }

    private suspend fun reconcileIdentityEntry(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
        generation: Long? = null,
    ) {
        checkReconciliation(generation)
        val authorization = authorization(forceRefresh = true)
        try {
            val overview = client().overview(authorization)
            checkReconciliation(generation)
            var restored = checkpoint.reconcileBandState(
                claimed = overview.bandState == "claimed",
            )
            if (
                overview.bandState != "claimed" &&
                restored.stage != OwnershipCheckpointStage.ACCOUNT_READY
            ) {
                restored = restored.copy(
                    stage = OwnershipCheckpointStage.ACCOUNT_READY,
                )
            }
            save(user, restored)
            overview.plan.persist(appContext)
            replaceState {
                it.copy(
                    phase = phaseForOverview(overview, restored),
                    overview = overview,
                    status = text(R.string.ownership_existing_phone_restored),
                )
            }
            refreshOverviewData(
                forceRefresh = false,
                generation = generation,
            )
            return
        } catch (error: OwnershipException) {
            checkReconciliation(generation)
            if (
                error != OwnershipException.Authentication &&
                error != OwnershipException.InvalidState
            ) {
                throw error
            }
        }

        val bootstrap = client().bootstrap(authorization)
        checkReconciliation(generation)
        if (bootstrap.termsAcceptanceRequired) {
            val review = if (
                checkpoint.stage == OwnershipCheckpointStage.TERMS_REVIEW &&
                !checkpoint.hasAcceptedTerms
            ) {
                checkpoint
            } else {
                checkpoint.invalidateAcceptedTerms()
            }
            save(user, review)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.TERMS_REVIEW,
                    terms = null,
                    overview = null,
                    installations = emptyList(),
                    status = text(R.string.ownership_terms_reload),
                )
            }
        } else if (bootstrap.replacementAuthorizationRequired) {
            val replacement = checkpoint.requireReplacementAuthorization()
            save(user, replacement)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                    status = text(R.string.ownership_replacement_required),
                )
            }
        } else {
            replaceState {
                it.copy(
                    phase = OwnershipPhase.TERMS_REVIEW,
                    status = text(R.string.ownership_signed_in),
                )
            }
        }
    }

    private suspend fun reconcilePendingClaim(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
        generation: Long? = null,
    ): Boolean {
        checkReconciliation(generation)
        val authorization = authorization(forceRefresh = true)
        val overview = client().overview(authorization)
        checkReconciliation(generation)
        val claimed = overview.bandState == "claimed"
        val reconciled = checkpoint.reconcileClaim(claimed)
        save(user, reconciled)
        replaceState {
            it.copy(
                phase = phaseForOverview(overview, reconciled),
                overview = overview,
                status = if (claimed) {
                    text(R.string.ownership_band_claimed)
                } else {
                    text(R.string.ownership_claim_not_found)
                },
            )
        }
        return claimed
    }

    private suspend fun reconcilePendingPlanSelection(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
        initialOverview: OwnershipAccountOverview?,
        generation: Long? = null,
    ): Pair<OwnershipCheckpoint, OwnershipAccountOverview> {
        checkReconciliation(generation)
        val pending = checkpoint.pendingPlanSelection
            ?.takeIf {
                checkpoint.stage == OwnershipCheckpointStage.PLAN_SELECTION
            }
            ?: throw OwnershipException.InvalidState
        val authorization = authorization(forceRefresh = false)
        var overview = initialOverview ?: client().overview(authorization)
        checkReconciliation(generation)
        if (overview.plan != pending) {
            client().selectPlan(
                plan = pending,
                requestId = checkpoint.planRequestId,
                authorization = authorization,
            )
            checkReconciliation(generation)
            overview = client().overview(authorization)
            checkReconciliation(generation)
        }
        if (overview.plan != pending) {
            throw OwnershipException.InvalidResponse
        }
        pending.persist(appContext)
        val completed = checkpoint.completePlanSelection(
            bandClaimed = overview.bandState == "claimed",
        )
        save(user, completed)
        recordPlanSelectionResolution(
            bandClaimed = overview.bandState == "claimed",
        )
        return completed to overview
    }

    private suspend fun reconcilePendingReplacement(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
        generation: Long? = null,
    ): Boolean {
        checkReconciliation(generation)
        val authorization = authorization(forceRefresh = true)
        return try {
            val overview = client().overview(authorization)
            if (overview.bandState != "claimed") {
                throw OwnershipException.InvalidResponse
            }
            val installations = client().installations(authorization)
            checkReconciliation(generation)
            val reconciled = checkpoint.reconcileReplacement(authorized = true)
            save(user, reconciled)
            overview.plan.persist(appContext)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.COMPLETE,
                    overview = overview,
                    installations = installations,
                    status = text(R.string.ownership_replacement_authorized),
                )
            }
            true
        } catch (error: OwnershipException) {
            checkReconciliation(generation)
            if (
                error != OwnershipException.Authentication &&
                error != OwnershipException.InvalidState
            ) {
                throw error
            }
            val reconciled = checkpoint.reconcileReplacement(authorized = false)
            save(user, reconciled)
            replaceState {
                it.copy(
                    phase = OwnershipPhase.REPLACEMENT_REQUIRED,
                    status = text(R.string.ownership_replacement_required),
                )
            }
            false
        }
    }

    private suspend fun refreshOverviewData(
        forceRefresh: Boolean,
        generation: Long? = null,
    ) = coroutineScope {
        checkReconciliation(generation)
        val authorization = authorization(forceRefresh)
        val account = async { client().overview(authorization) }
        val devices = async { client().installations(authorization) }
        val overview = account.await()
        val installations = devices.await()
        checkReconciliation(generation)
        val user = currentUser()
        var checkpoint = checkpoint(user)
        val reconciled = checkpoint.reconcileBandState(
            claimed = overview.bandState == "claimed",
        )
        if (reconciled != checkpoint) {
            checkpoint = reconciled
            save(user, checkpoint)
        }
        replaceState {
            it.copy(
                phase = phaseForOverview(overview, checkpoint),
                overview = overview,
                installations = installations,
            )
        }
    }

    private fun reconcileLocal(
        user: FirebaseUser,
        checkpoint: OwnershipCheckpoint,
    ) {
        val phase = if (!user.isEmailVerified) {
            OwnershipPhase.EMAIL_VERIFICATION
        } else {
            when (checkpoint.stage) {
                OwnershipCheckpointStage.SIGNED_OUT,
                OwnershipCheckpointStage.EMAIL_VERIFICATION,
                OwnershipCheckpointStage.TERMS_REVIEW,
                -> OwnershipPhase.TERMS_REVIEW
                OwnershipCheckpointStage.ACCOUNT_REGISTRATION ->
                    OwnershipPhase.REGISTERING
                OwnershipCheckpointStage.ACCOUNT_READY ->
                    if (possessionProvider.isAvailable) {
                        OwnershipPhase.ACCOUNT_READY
                    } else {
                        OwnershipPhase.POSSESSION_UNAVAILABLE
                    }
                OwnershipCheckpointStage.CLAIM_PENDING ->
                    if (possessionProvider.isAvailable) {
                        OwnershipPhase.ACCOUNT_READY
                    } else {
                        OwnershipPhase.POSSESSION_UNAVAILABLE
                    }
                OwnershipCheckpointStage.CLAIMED -> OwnershipPhase.CLAIMED
                OwnershipCheckpointStage.PLAN_SELECTION ->
                    if (possessionProvider.isAvailable) {
                        OwnershipPhase.ACCOUNT_READY
                    } else {
                        OwnershipPhase.POSSESSION_UNAVAILABLE
                    }
                OwnershipCheckpointStage.COMPLETE -> OwnershipPhase.COMPLETE
                OwnershipCheckpointStage.REPLACEMENT_REQUIRED ->
                    OwnershipPhase.REPLACEMENT_REQUIRED
                OwnershipCheckpointStage.REPLACEMENT_PENDING ->
                    OwnershipPhase.AUTHORIZING_REPLACEMENT
            }
        }
        replaceState {
            it.copy(
                phase = phase,
                maskedEmail = maskEmail(user.email),
            )
        }
    }

    private fun phaseForOverview(
        overview: OwnershipAccountOverview,
        checkpoint: OwnershipCheckpoint,
    ): OwnershipPhase = when {
        checkpoint.stage == OwnershipCheckpointStage.REPLACEMENT_REQUIRED ->
            OwnershipPhase.REPLACEMENT_REQUIRED
        checkpoint.stage == OwnershipCheckpointStage.REPLACEMENT_PENDING ->
            OwnershipPhase.AUTHORIZING_REPLACEMENT
        overview.bandState != "claimed" && possessionProvider.isAvailable ->
            OwnershipPhase.ACCOUNT_READY
        overview.bandState != "claimed" ->
            OwnershipPhase.POSSESSION_UNAVAILABLE
        checkpoint.stage == OwnershipCheckpointStage.COMPLETE ->
            OwnershipPhase.COMPLETE
        else -> OwnershipPhase.CLAIMED
    }

    private fun checkpoint(user: FirebaseUser): OwnershipCheckpoint {
        val scope = accountScope(user)
        secureStore().checkpoint(scope)?.let { return it }
        val created = OwnershipCheckpoint(
            stage = if (user.isEmailVerified) {
                OwnershipCheckpointStage.TERMS_REVIEW
            } else {
                OwnershipCheckpointStage.EMAIL_VERIFICATION
            },
        )
        secureStore().writeCheckpoint(scope, created)
        return created
    }

    private fun save(user: FirebaseUser, checkpoint: OwnershipCheckpoint) {
        secureStore().writeCheckpoint(accountScope(user), checkpoint)
    }

    private suspend fun authorization(forceRefresh: Boolean): OwnershipAuthorization =
        coroutineScope {
            val runtime = runtime()
            val user = runtime.auth.currentUser ?: throw OwnershipException.NotSignedIn
            val identity = async {
                user.getIdToken(forceRefresh).awaitManaged().token
                    ?.takeIf(String::isNotEmpty)
                    ?: throw OwnershipException.Authentication
            }
            val appCheck = async {
                runtime.appCheck.getAppCheckToken(forceRefresh)
                    .awaitManaged()
                    .token
                    .takeIf(String::isNotEmpty)
                    ?: throw OwnershipException.Authentication
            }
            OwnershipAuthorization(
                identityToken = identity.await(),
                appCheckToken = appCheck.await(),
                installation = secureStore().installationCredential(
                    accountScope(user),
                ),
            )
        }

    private fun secureStore(): OwnershipSecureStore {
        secureStoreInstance?.let { return it }
        return synchronized(this) {
            secureStoreInstance ?: try {
                OwnershipSecureStore(appContext).also {
                    secureStoreInstance = it
                }
            } catch (_: Exception) {
                throw OwnershipException.SecureStorage
            }
        }
    }

    private fun runtime(): FirebaseRuntime {
        firebaseRuntime?.let { return it }
        return synchronized(firebaseLock) {
            firebaseRuntime?.let { return@synchronized it }
            val config = configuration ?: throw OwnershipException.Unavailable
            val firebase = runCatching {
                FirebaseApp.getInstance(FIREBASE_APP_NAME)
            }.getOrNull()
                ?: FirebaseApp.initializeApp(
                    appContext,
                    FirebaseOptions.Builder()
                        .setProjectId(config.projectId)
                        .setApiKey(config.apiKey)
                        .setApplicationId(config.googleAppId)
                        .setGcmSenderId(config.gcmSenderId)
                        .build(),
                    FIREBASE_APP_NAME,
                )
                ?: throw OwnershipException.Unavailable
            if (
                firebase.options.projectId != config.projectId ||
                firebase.options.applicationId != config.googleAppId
            ) {
                throw OwnershipException.InvalidConfiguration
            }
            ManagedAppCheckProvider.install(firebase)
            FirebaseRuntime(
                auth = FirebaseAuth.getInstance(firebase),
                appCheck = FirebaseAppCheck.getInstance(firebase),
            ).also { firebaseRuntime = it }
        }
    }

    private fun currentUser(): FirebaseUser =
        runtime().auth.currentUser ?: throw OwnershipException.NotSignedIn

    private fun client(): OwnershipClient =
        ownershipClient ?: throw OwnershipException.Unavailable

    private suspend fun requestPhoneVerification(
        activity: Activity,
        phone: String,
    ): PhoneVerificationResult =
        suspendCancellableCoroutine { continuation ->
            val auth = runtime().auth
            val callbacks =
                object : PhoneAuthProvider.OnVerificationStateChangedCallbacks() {
                    override fun onVerificationCompleted(
                        credential: PhoneAuthCredential,
                    ) {
                        if (continuation.isActive) {
                            continuation.resume(
                                PhoneVerificationResult.AutomaticallyVerified(
                                    credential,
                                ),
                            )
                        }
                    }

                    override fun onVerificationFailed(
                        error: FirebaseException,
                    ) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(error)
                        }
                    }

                    override fun onCodeSent(
                        verificationId: String,
                        token: ForceResendingToken,
                    ) {
                        token.hashCode()
                        if (continuation.isActive) {
                            continuation.resume(
                                PhoneVerificationResult.CodeSent(
                                    verificationId,
                                ),
                            )
                        }
                    }
                }
            PhoneAuthProvider.verifyPhoneNumber(
                PhoneAuthOptions.newBuilder(auth)
                    .setPhoneNumber(phone)
                    .setTimeout(60L, TimeUnit.SECONDS)
                    .setActivity(activity)
                    .setCallbacks(callbacks)
                    .build(),
            )
        }

    private suspend fun perform(
        operationName: String,
        failureProgress: (() -> String?)? = null,
        block: suspend () -> Unit,
    ) {
        performForResult(operationName, failureProgress, block)
    }

    private suspend fun performForResult(
        operationName: String,
        failureProgress: (() -> String?)? = null,
        block: suspend () -> Unit,
    ): Boolean {
        if (!beginBusy()) return false
        val operation = AppDiagnosticsRecorder.beginOperation(operationName)
        try {
            block()
            AppDiagnosticsRecorder.endOperation(operation)
            return true
        } catch (error: CancellationException) {
            replaceState {
                it.copy(
                    phase = ownershipCancellationRecoveryPhase(
                        phase = it.phase,
                        possessionAvailable = possessionProvider.isAvailable,
                    ),
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = "canceled",
                fields = mapOf("failure_kind" to "canceled"),
            )
            throw error
        } catch (error: Throwable) {
            val reportedError = reconcileChangedTerms(error)
            val progress = failureProgress?.invoke()
            replaceState { current ->
                val fallbackPhase = if (
                    current.phase == OwnershipPhase.CLAIMING
                ) {
                    if (possessionProvider.isAvailable) {
                        OwnershipPhase.ACCOUNT_READY
                    } else {
                        OwnershipPhase.POSSESSION_UNAVAILABLE
                    }
                } else {
                    ownershipReconciliationRecoveryPhase(current.phase)
                }
                current.copy(
                    phase = ownershipFailureRecoveryPhase(
                        phase = fallbackPhase,
                        termsChanged =
                            reportedError == OwnershipException.TermsChanged,
                        secureStorageFailed =
                            reportedError == OwnershipException.SecureStorage,
                    ),
                    status = userMessage(reportedError),
                    terms = if (
                        reportedError == OwnershipException.TermsChanged ||
                        reportedError == OwnershipException.SecureStorage
                    ) {
                        null
                    } else {
                        current.terms
                    },
                )
            }
            AppDiagnosticsRecorder.endOperation(
                operation,
                outcome = if (progress == "identity_created") {
                    "partial"
                } else {
                    diagnosticOutcome(reportedError)
                },
                fields = buildMap {
                    put(
                        "failure_kind",
                        diagnosticFailureKind(reportedError),
                    )
                    if (progress != null) put("progress", progress)
                },
            )
            return false
        } finally {
            endBusy()
        }
    }

    private fun reconcileChangedTerms(originalError: Throwable): Throwable {
        if (originalError != OwnershipException.TermsChanged) {
            return originalError
        }
        return try {
            val user = currentUser()
            save(user, checkpoint(user).invalidateAcceptedTerms())
            originalError
        } catch (resetError: Throwable) {
            resetError
        }
    }

    private fun invalidateBootstrapReconciliation(): Long {
        bootstrapGeneration += 1L
        bootstrapJob?.cancel()
        bootstrapJob = null
        if (bootstrapBusyGeneration != null) {
            bootstrapBusyGeneration = null
            replaceState { it.copy(busy = false) }
        }
        return bootstrapGeneration
    }

    private fun reconciliationMayUpdateState(generation: Long?): Boolean =
        ownershipReconciliationMayUpdateState(
            expectedGeneration = generation,
            currentGeneration = bootstrapGeneration,
        )

    private suspend fun checkReconciliation(generation: Long?) {
        currentCoroutineContext().ensureActive()
        if (!reconciliationMayUpdateState(generation)) {
            throw CancellationException("stale ownership reconciliation")
        }
    }

    private fun beginBusy(): Boolean = stateCoordinator.tryBeginBusy()

    private fun endBusy() {
        replaceState { it.copy(busy = false) }
    }

    private fun replaceState(transform: (OwnershipState) -> OwnershipState) {
        stateCoordinator.update(transform)
    }

    private fun accountScope(user: FirebaseUser): String =
        ownershipAccountScope(
            projectId = configuration?.projectId
                ?: throw OwnershipException.InvalidConfiguration,
            subject = user.uid,
        )

    private fun normalizedEmail(raw: String): String {
        val value = raw.trim()
        if (value.length !in 3..254 || !value.matches(EMAIL)) {
            throw OwnershipException.InvalidCredentials
        }
        return value
    }

    private fun validatePassword(password: String, confirmation: String) {
        if (
            password != confirmation ||
            password.length !in 12..128
        ) {
            throw OwnershipException.InvalidPassword
        }
    }

    private fun normalizedPhone(raw: String): String {
        val value = raw.filterNot { it.isWhitespace() || it in "-()" }
        if (!value.matches(PHONE)) throw OwnershipException.InvalidPhone
        return value
    }

    private fun normalizedCode(raw: String): String {
        val value = raw.trim()
        if (!value.matches(CODE)) throw OwnershipException.InvalidCode
        return value
    }

    private fun preferredLocale(): String {
        val candidate = Locale.getDefault().toLanguageTag()
            .replace('-', '_')
        return candidate.takeIf { it.matches(LOCALE) } ?: "en"
    }

    private fun planStatus(plan: NoopProductPlan): String =
        if (plan == NoopProductPlan.NOOP) {
            text(R.string.ownership_plan_noop_saved)
        } else {
            text(R.string.ownership_plan_plus_saved)
        }

    private fun recordPlanSelectionResolution(bandClaimed: Boolean) {
        AppDiagnosticsRecorder.record(
            "ownership.lifecycle",
            mapOf(
                "phase" to "plan_selection",
                "outcome" to if (bandClaimed) {
                    "flow_completed"
                } else {
                    "preference_saved"
                },
            ),
        )
    }

    private fun userMessage(error: Throwable): String = when (error) {
        OwnershipException.Unavailable,
        OwnershipException.InvalidConfiguration,
        -> text(R.string.ownership_unavailable_status)
        OwnershipException.InvalidCredentials ->
            text(R.string.ownership_invalid_credentials)
        OwnershipException.InvalidPassword ->
            text(R.string.ownership_invalid_password)
        OwnershipException.EmailVerificationRequired ->
            text(R.string.ownership_email_verification_required)
        OwnershipException.TermsRequired,
        OwnershipException.TermsChanged,
        -> text(R.string.ownership_terms_reload)
        OwnershipException.InvalidPhone ->
            text(R.string.ownership_invalid_phone)
        OwnershipException.InvalidCode,
        OwnershipException.PhoneCodeRequired,
        -> text(R.string.ownership_invalid_code)
        OwnershipException.NotSignedIn,
        OwnershipException.Authentication,
        -> text(R.string.ownership_sign_in_again)
        OwnershipException.ChallengeInactive ->
            text(R.string.ownership_confirmation_inactive)
        OwnershipException.PossessionRejected ->
            text(R.string.ownership_confirmation_rejected)
        OwnershipException.AlreadyClaimed ->
            text(R.string.ownership_band_unavailable)
        OwnershipException.PossessionUnavailable ->
            text(R.string.ownership_possession_sdk_pending)
        OwnershipException.Network ->
            text(R.string.ownership_network_unavailable)
        OwnershipException.ServiceUnavailable ->
            text(R.string.ownership_service_unavailable)
        OwnershipException.InvalidResponse,
        OwnershipException.InvalidState,
        OwnershipException.SecureStorage,
        -> text(R.string.ownership_cannot_continue)
        else -> text(R.string.ownership_action_failed)
    }

    private fun diagnosticOutcome(error: Throwable): String = when (error) {
        OwnershipException.InvalidCredentials,
        OwnershipException.InvalidPassword,
        OwnershipException.EmailVerificationRequired,
        OwnershipException.TermsRequired,
        OwnershipException.TermsChanged,
        OwnershipException.InvalidPhone,
        OwnershipException.InvalidCode,
        OwnershipException.PhoneCodeRequired,
        OwnershipException.NotSignedIn,
        OwnershipException.Authentication,
        OwnershipException.ChallengeInactive,
        OwnershipException.PossessionRejected,
        OwnershipException.AlreadyClaimed,
        OwnershipException.InvalidState,
        -> "rejected"
        OwnershipException.Unavailable,
        OwnershipException.ServiceUnavailable,
        OwnershipException.PossessionUnavailable,
        -> "unavailable"
        else -> "failed"
    }

    private fun diagnosticFailureKind(error: Throwable): String = when (error) {
        OwnershipException.Unavailable,
        OwnershipException.InvalidConfiguration,
        -> "configuration"
        OwnershipException.InvalidCredentials -> "credentials"
        OwnershipException.InvalidPassword -> "password_policy"
        OwnershipException.EmailVerificationRequired -> "email_unverified"
        OwnershipException.TermsRequired -> "terms_missing"
        OwnershipException.TermsChanged -> "terms_changed"
        OwnershipException.InvalidPhone -> "phone_format"
        OwnershipException.InvalidCode -> "code_format"
        OwnershipException.PhoneCodeRequired -> "verification_state"
        OwnershipException.NotSignedIn -> "identity_missing"
        OwnershipException.Authentication -> "authentication"
        OwnershipException.ChallengeInactive -> "challenge_inactive"
        OwnershipException.PossessionRejected -> "possession_rejected"
        OwnershipException.AlreadyClaimed -> "ownership_conflict"
        OwnershipException.PossessionUnavailable -> "possession_provider"
        OwnershipException.Network -> "network"
        OwnershipException.ServiceUnavailable -> "service"
        OwnershipException.InvalidResponse -> "response_contract"
        OwnershipException.InvalidState -> "state"
        OwnershipException.SecureStorage -> "secure_storage"
        is FirebaseAuthException -> when (error.errorCode) {
            "ERROR_NETWORK_REQUEST_FAILED" -> "network"
            "ERROR_TOO_MANY_REQUESTS" -> "rate_limit"
            "ERROR_USER_DISABLED" -> "identity_disabled"
            "ERROR_REQUIRES_RECENT_LOGIN" -> "reauthentication"
            "ERROR_EMAIL_ALREADY_IN_USE",
            "ERROR_CREDENTIAL_ALREADY_IN_USE",
            -> "identity_conflict"
            "ERROR_INVALID_EMAIL",
            "ERROR_WRONG_PASSWORD",
            "ERROR_USER_NOT_FOUND",
            "ERROR_INVALID_CREDENTIAL",
            -> "credentials"
            else -> "identity_provider"
        }
        else -> "unknown"
    }

    private fun text(resource: Int): String = appContext.getString(resource)

    companion object {
        private const val FIREBASE_APP_NAME = "noop-ownership"
        private val EMAIL = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")
        private val PHONE = Regex("^\\+[1-9][0-9]{7,14}$")
        private val CODE = Regex("^[0-9]{6}$")
        private val LOCALE = Regex("^[A-Za-z]{2,3}(_[A-Za-z0-9]{2,8}){0,2}$")

        @Volatile
        private var instance: OwnershipService? = null

        fun get(context: Context): OwnershipService =
            instance ?: synchronized(this) {
                instance ?: OwnershipService(context).also { instance = it }
            }

        internal fun maskEmail(raw: String?): String {
            val value = raw?.trim().orEmpty()
            val at = value.indexOf('@')
            if (at <= 0) return ""
            return "${value.first()}***${value.substring(at)}"
        }

    }
}

internal fun ownershipAccountScope(
    projectId: String,
    subject: String,
): String =
    MessageDigest.getInstance("SHA-256")
        .digest(
            "noop-ownership-account-v2\u0000$projectId\u0000$subject"
                .toByteArray(StandardCharsets.UTF_8),
        )
        .joinToString("") { byte -> "%02x".format(byte) }
