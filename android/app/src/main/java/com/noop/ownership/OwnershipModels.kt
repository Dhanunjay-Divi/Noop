package com.noop.ownership

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.util.UUID

enum class NoopProductPlan(val storedValue: String) {
    NOOP("noop"),
    NOOP_PLUS("noop_plus");

    fun persist(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(STORAGE_KEY, storedValue)
            .apply()
    }

    companion object {
        const val STORAGE_KEY = "noop.productPlanSelection"
        private const val PREFERENCES_NAME = "noop_prefs"

        fun fromStoredValue(value: String?): NoopProductPlan =
            entries.firstOrNull { it.storedValue == value } ?: NOOP

        fun fromExactStoredValue(value: String): NoopProductPlan? =
            entries.firstOrNull { it.storedValue == value }

        fun stored(context: Context): NoopProductPlan =
            fromStoredValue(
                context.applicationContext
                    .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                    .getString(STORAGE_KEY, null),
            )
    }
}

enum class OwnershipPhase {
    UNAVAILABLE,
    LOCAL_RECOVERY_REQUIRED,
    SIGNED_OUT,
    EMAIL_VERIFICATION,
    TERMS_REVIEW,
    REGISTERING,
    ACCOUNT_READY,
    POSSESSION_UNAVAILABLE,
    CLAIMING,
    CLAIMED,
    COMPLETE,
    REPLACEMENT_REQUIRED,
    AUTHORIZING_REPLACEMENT,
}

internal fun ownershipReconciliationRecoveryPhase(
    phase: OwnershipPhase,
): OwnershipPhase = when (phase) {
    OwnershipPhase.REGISTERING -> OwnershipPhase.TERMS_REVIEW
    OwnershipPhase.AUTHORIZING_REPLACEMENT ->
        OwnershipPhase.REPLACEMENT_REQUIRED
    else -> phase
}

internal fun ownershipFailureRecoveryPhase(
    phase: OwnershipPhase,
    termsChanged: Boolean,
    secureStorageFailed: Boolean = false,
): OwnershipPhase = when {
    secureStorageFailed -> OwnershipPhase.LOCAL_RECOVERY_REQUIRED
    termsChanged -> OwnershipPhase.TERMS_REVIEW
    else -> ownershipReconciliationRecoveryPhase(phase)
}

internal fun ownershipCancellationRecoveryPhase(
    phase: OwnershipPhase,
    possessionAvailable: Boolean,
): OwnershipPhase = when (phase) {
    OwnershipPhase.REGISTERING -> OwnershipPhase.TERMS_REVIEW
    OwnershipPhase.CLAIMING -> if (possessionAvailable) {
        OwnershipPhase.ACCOUNT_READY
    } else {
        OwnershipPhase.POSSESSION_UNAVAILABLE
    }
    OwnershipPhase.AUTHORIZING_REPLACEMENT ->
        OwnershipPhase.REPLACEMENT_REQUIRED
    else -> phase
}

internal fun ownershipCanAccessPostClaimOnboarding(
    isAvailable: Boolean,
    phase: OwnershipPhase,
): Boolean = !isAvailable ||
    phase == OwnershipPhase.CLAIMED ||
    phase == OwnershipPhase.COMPLETE

internal fun ownershipReconciliationMayUpdateState(
    expectedGeneration: Long?,
    currentGeneration: Long,
): Boolean = expectedGeneration == null ||
    expectedGeneration == currentGeneration

internal enum class OwnershipEmailVerificationDestination {
    TERMS_REVIEW,
    BAND_ACTIVATION,
    PRESERVE_RECONCILED_STATUS,
}

internal fun ownershipEmailVerificationDestination(
    phase: OwnershipPhase,
): OwnershipEmailVerificationDestination = when (phase) {
    OwnershipPhase.TERMS_REVIEW ->
        OwnershipEmailVerificationDestination.TERMS_REVIEW
    OwnershipPhase.ACCOUNT_READY,
    OwnershipPhase.POSSESSION_UNAVAILABLE,
    -> OwnershipEmailVerificationDestination.BAND_ACTIVATION
    else -> OwnershipEmailVerificationDestination.PRESERVE_RECONCILED_STATUS
}

enum class OwnershipCheckpointStage {
    SIGNED_OUT,
    EMAIL_VERIFICATION,
    TERMS_REVIEW,
    ACCOUNT_REGISTRATION,
    ACCOUNT_READY,
    CLAIM_PENDING,
    CLAIMED,
    PLAN_SELECTION,
    COMPLETE,
    REPLACEMENT_REQUIRED,
    REPLACEMENT_PENDING,
}

data class OwnershipTermsDocument(
    val policyVersion: String,
    val locale: String,
    val sha256: String,
    val text: String,
)

data class OwnershipAccountOverview(
    val accountState: String,
    val emailVerified: Boolean,
    val phoneVerified: Boolean,
    val bandState: String,
    val activeInstallations: Int,
    val plan: NoopProductPlan,
    val noopPlusEntitled: Boolean,
)

internal fun OwnershipCheckpoint.completeRegistration(
    overview: OwnershipAccountOverview,
): OwnershipCheckpoint {
    val completed = completeRegistration()
    return if (overview.bandState == "claimed") {
        completed.reconcileClaim(claimed = true)
    } else {
        completed
    }
}

data class OwnershipBootstrapStatus(
    val accountState: String,
    val bandState: String,
    val replacementAuthorizationRequired: Boolean,
    val termsAcceptanceRequired: Boolean,
)

data class OwnershipInstallation(
    val id: String,
    val platform: String,
    val status: String,
    val current: Boolean,
    val registeredAt: String,
    val lastSeenAt: String,
)

data class OwnershipState(
    val phase: OwnershipPhase,
    val busy: Boolean = false,
    val status: String = "",
    val terms: OwnershipTermsDocument? = null,
    val overview: OwnershipAccountOverview? = null,
    val installations: List<OwnershipInstallation> = emptyList(),
    val maskedEmail: String = "",
)

internal class OwnershipStateCoordinator(initial: OwnershipState) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(initial)

    val state: StateFlow<OwnershipState> = mutableState.asStateFlow()

    fun tryBeginBusy(): Boolean = synchronized(lock) {
        if (mutableState.value.busy) return@synchronized false
        mutableState.value = mutableState.value.copy(busy = true)
        true
    }

    fun update(transform: (OwnershipState) -> OwnershipState) {
        synchronized(lock) {
            mutableState.value = transform(mutableState.value)
        }
    }
}

data class OwnershipCheckpoint(
    val schema: Int = SCHEMA_VERSION,
    val stage: OwnershipCheckpointStage = OwnershipCheckpointStage.SIGNED_OUT,
    val registrationRequestId: UUID = UUID.randomUUID(),
    val claimRequestId: UUID = UUID.randomUUID(),
    val planRequestId: UUID = UUID.randomUUID(),
    val replacementRequestId: UUID = UUID.randomUUID(),
    val acceptedPolicyVersion: String? = null,
    val acceptedPolicySha256: String? = null,
    val acceptedLocale: String? = null,
    val pendingPlanSelection: NoopProductPlan? = null,
) {
    val isValid: Boolean
        get() {
            val policyValues = listOf(
                acceptedPolicyVersion,
                acceptedPolicySha256,
                acceptedLocale,
            )
            val hasNoPolicy = policyValues.all { it == null }
            val hasCompletePolicy = policyValues.all { it != null }
            val registrationHasTerms =
                stage != OwnershipCheckpointStage.ACCOUNT_REGISTRATION ||
                    hasAcceptedTerms
            val pendingPlanMatchesStage =
                (stage == OwnershipCheckpointStage.PLAN_SELECTION) ==
                    (pendingPlanSelection != null)
            val reviewHasNoStaleAcceptance =
                stage != OwnershipCheckpointStage.TERMS_REVIEW ||
                    !hasAcceptedTerms
            return schema == SCHEMA_VERSION &&
                (hasNoPolicy || hasCompletePolicy) &&
                acceptedPolicyVersion.validPolicyComponent(64) &&
                acceptedPolicySha256.validDigest() &&
                acceptedLocale.validLocale() &&
                registrationHasTerms &&
                pendingPlanMatchesStage &&
                reviewHasNoStaleAcceptance
        }

    val hasAcceptedTerms: Boolean
        get() = acceptedPolicyVersion != null &&
            acceptedPolicySha256 != null &&
            acceptedLocale != null

    fun captureAcceptedTerms(
        policyVersion: String,
        sha256: String,
        locale: String,
    ): OwnershipCheckpoint = withAcceptedTerms(
        policyVersion = policyVersion,
        sha256 = sha256,
        locale = locale,
        stage = OwnershipCheckpointStage.EMAIL_VERIFICATION,
    )

    fun acceptTerms(
        policyVersion: String,
        sha256: String,
        locale: String,
    ): OwnershipCheckpoint = withAcceptedTerms(
        policyVersion = policyVersion,
        sha256 = sha256,
        locale = locale,
        stage = OwnershipCheckpointStage.ACCOUNT_REGISTRATION,
    )

    private fun withAcceptedTerms(
        policyVersion: String,
        sha256: String,
        locale: String,
        stage: OwnershipCheckpointStage,
    ): OwnershipCheckpoint {
        require(policyVersion.validPolicyComponent(64))
        require(sha256.matches(SHA256))
        require(locale.validLocale())
        val changed = acceptedPolicyVersion != policyVersion ||
            acceptedPolicySha256 != sha256 ||
            acceptedLocale != locale
        return copy(
            stage = stage,
            registrationRequestId = if (changed) UUID.randomUUID() else registrationRequestId,
            acceptedPolicyVersion = policyVersion,
            acceptedPolicySha256 = sha256,
            acceptedLocale = locale,
        )
    }

    fun completeRegistration(): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.ACCOUNT_READY,
        registrationRequestId = UUID.randomUUID(),
    )

    fun invalidateAcceptedTerms(): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.TERMS_REVIEW,
        registrationRequestId = UUID.randomUUID(),
        planRequestId = UUID.randomUUID(),
        acceptedPolicyVersion = null,
        acceptedPolicySha256 = null,
        acceptedLocale = null,
        pendingPlanSelection = null,
    )

    fun beginClaimAttempt(): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.CLAIM_PENDING,
        claimRequestId = UUID.randomUUID(),
    )

    fun reconcileClaim(claimed: Boolean): OwnershipCheckpoint = copy(
        stage = if (claimed) {
            OwnershipCheckpointStage.CLAIMED
        } else {
            OwnershipCheckpointStage.ACCOUNT_READY
        },
        claimRequestId = UUID.randomUUID(),
    )

    fun reconcileBandState(claimed: Boolean): OwnershipCheckpoint = when {
        claimed && stage in setOf(
            OwnershipCheckpointStage.ACCOUNT_READY,
            OwnershipCheckpointStage.CLAIM_PENDING,
        ) -> reconcileClaim(claimed = true)
        !claimed && stage in setOf(
            OwnershipCheckpointStage.CLAIMED,
            OwnershipCheckpointStage.COMPLETE,
        ) -> reconcileClaim(claimed = false)
        else -> this
    }

    fun beginPlanSelection(selection: NoopProductPlan): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.PLAN_SELECTION,
        planRequestId = if (pendingPlanSelection == selection) {
            planRequestId
        } else {
            UUID.randomUUID()
        },
        pendingPlanSelection = selection,
    )

    fun completePlanSelection(bandClaimed: Boolean): OwnershipCheckpoint = copy(
        stage = if (bandClaimed) {
            OwnershipCheckpointStage.COMPLETE
        } else {
            OwnershipCheckpointStage.ACCOUNT_READY
        },
        planRequestId = UUID.randomUUID(),
        pendingPlanSelection = null,
    )

    fun requireReplacementAuthorization(): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.REPLACEMENT_REQUIRED,
        replacementRequestId = UUID.randomUUID(),
    )

    fun beginReplacementAttempt(): OwnershipCheckpoint = copy(
        stage = OwnershipCheckpointStage.REPLACEMENT_PENDING,
        replacementRequestId = UUID.randomUUID(),
    )

    fun reconcileReplacement(authorized: Boolean): OwnershipCheckpoint = copy(
        stage = if (authorized) {
            OwnershipCheckpointStage.COMPLETE
        } else {
            OwnershipCheckpointStage.REPLACEMENT_REQUIRED
        },
        replacementRequestId = UUID.randomUUID(),
    )

    fun toJson(): String = JSONObject()
        .put("schema", schema)
        .put("stage", stage.name)
        .put("registration_request_id", registrationRequestId.toString())
        .put("claim_request_id", claimRequestId.toString())
        .put("plan_request_id", planRequestId.toString())
        .put("replacement_request_id", replacementRequestId.toString())
        .putNullable("accepted_policy_version", acceptedPolicyVersion)
        .putNullable("accepted_policy_sha256", acceptedPolicySha256)
        .putNullable("accepted_locale", acceptedLocale)
        .putNullable("pending_plan_selection", pendingPlanSelection?.storedValue)
        .toString()

    companion object {
        const val SCHEMA_VERSION = 1
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val POLICY_COMPONENT = Regex("^[A-Za-z0-9][A-Za-z0-9._-]*$")

        fun fromJson(raw: String): OwnershipCheckpoint? = runCatching {
            val value = JSONObject(raw)
            OwnershipCheckpoint(
                schema = value.getInt("schema"),
                stage = OwnershipCheckpointStage.valueOf(value.getString("stage")),
                registrationRequestId = UUID.fromString(
                    value.getString("registration_request_id"),
                ),
                claimRequestId = UUID.fromString(value.getString("claim_request_id")),
                planRequestId = UUID.fromString(value.getString("plan_request_id")),
                replacementRequestId = value.optionalString(
                    "replacement_request_id",
                )?.let(UUID::fromString) ?: UUID.randomUUID(),
                acceptedPolicyVersion = value.optionalString(
                    "accepted_policy_version",
                ),
                acceptedPolicySha256 = value.optionalString(
                    "accepted_policy_sha256",
                ),
                acceptedLocale = value.optionalString("accepted_locale"),
                pendingPlanSelection = value.optionalString(
                    "pending_plan_selection",
                )?.let { stored ->
                    NoopProductPlan.fromExactStoredValue(stored)
                        ?: error("Unknown plan selection")
                },
            )
        }.getOrNull()?.takeIf(OwnershipCheckpoint::isValid)

        fun decodePersisted(raw: String): OwnershipCheckpoint =
            fromJson(raw) ?: throw OwnershipException.SecureStorage

        private fun String?.validDigest(): Boolean =
            this == null || matches(SHA256)

        private fun String?.validPolicyComponent(maximum: Int): Boolean =
            this == null ||
                (length in 1..maximum && matches(POLICY_COMPONENT))

        private fun String?.validLocale(): Boolean =
            this == null || matches(LOCALE)

        private val LOCALE =
            Regex("^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$")
    }
}

interface OwnershipBandPossessionProvider {
    val isAvailable: Boolean
    suspend fun response(challenge: String): String
}

object UnavailableOwnershipBandPossessionProvider : OwnershipBandPossessionProvider {
    override val isAvailable = false

    override suspend fun response(challenge: String): String {
        challenge.length
        throw OwnershipException.PossessionUnavailable
    }
}

sealed class OwnershipException(message: String) : Exception(message) {
    data object Unavailable : OwnershipException("Ownership is unavailable")
    data object InvalidConfiguration : OwnershipException("Invalid configuration")
    data object InvalidCredentials : OwnershipException("Invalid credentials")
    data object InvalidPassword : OwnershipException("Invalid password")
    data object EmailVerificationRequired : OwnershipException("Email verification required")
    data object TermsRequired : OwnershipException("Terms are required")
    data object TermsChanged : OwnershipException("Terms changed")
    data object InvalidPhone : OwnershipException("Invalid phone")
    data object InvalidCode : OwnershipException("Invalid code")
    data object PhoneCodeRequired : OwnershipException("Phone code required")
    data object NotSignedIn : OwnershipException("Not signed in")
    data object Authentication : OwnershipException("Authentication failed")
    data object ChallengeInactive : OwnershipException("Confirmation is no longer active")
    data object PossessionRejected : OwnershipException("Possession proof rejected")
    data object AlreadyClaimed : OwnershipException("Band unavailable")
    data object PossessionUnavailable : OwnershipException("Possession unavailable")
    data object Network : OwnershipException("Network unavailable")
    data object ServiceUnavailable : OwnershipException("Service unavailable")
    data object InvalidResponse : OwnershipException("Invalid response")
    data object InvalidState : OwnershipException("Invalid state")
    data object SecureStorage : OwnershipException("Secure storage unavailable")
}

private fun JSONObject.putNullable(key: String, value: String?): JSONObject =
    if (value == null) put(key, JSONObject.NULL) else put(key, value)

private fun JSONObject.optionalString(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)
