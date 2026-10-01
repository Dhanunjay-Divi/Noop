package com.noop.ui

import com.noop.R
import com.noop.ownership.OwnershipPhase

internal const val REQUIRED_ACCOUNT_ONBOARDING_VERSION = 1
internal const val REQUIRED_ACCOUNT_ONBOARDING_VERSION_KEY =
    "noop.requiredAccountOnboardingVersion"

internal fun requiresRequiredAccountOnboarding(
    onboarded: Boolean,
    completedVersion: Int,
): Boolean =
    !onboarded || completedVersion < REQUIRED_ACCOUNT_ONBOARDING_VERSION

/** Pure first-run routing rules shared by restoration, navigation, and tests. */
internal fun onboardingPages(
    @Suppress("UNUSED_PARAMETER") ownershipConfigured: Boolean,
): List<OnboardingPage> = listOf(
    OnboardingPage.Welcome,
    OnboardingPage.Bluetooth,
    OnboardingPage.Connect,
    OnboardingPage.Account,
    OnboardingPage.Ownership,
    OnboardingPage.Profile,
    OnboardingPage.Plan,
    OnboardingPage.Done,
)

internal data class OnboardingAccountCopy(
    val dataBoundaryTitle: Int,
    val dataBoundaryBody: Int,
    val bluetoothBoundaryBody: Int,
)

internal fun onboardingAccountCopy(): OnboardingAccountCopy =
    OnboardingAccountCopy(
        dataBoundaryTitle =
            R.string.onboarding_data_boundary_configured_title,
        dataBoundaryBody =
            R.string.onboarding_data_boundary_configured_body,
        bluetoothBoundaryBody =
            R.string.appwide_onboarding_bluetooth_account_boundary_body,
    )

internal fun accountStepCanContinue(
    ownershipConfigured: Boolean,
    reconciliationComplete: Boolean,
    phase: OwnershipPhase,
): Boolean {
    if (!ownershipConfigured || !reconciliationComplete) return false
    return phase == OwnershipPhase.ACCOUNT_READY ||
        phase == OwnershipPhase.POSSESSION_UNAVAILABLE ||
        phase == OwnershipPhase.CLAIMING ||
        phase == OwnershipPhase.CLAIMED ||
        phase == OwnershipPhase.COMPLETE ||
        phase == OwnershipPhase.REPLACEMENT_REQUIRED ||
        phase == OwnershipPhase.AUTHORIZING_REPLACEMENT
}

internal fun claimStepCanContinue(
    supplierClaimRequired: Boolean,
    claimed: Boolean,
    reconciliationComplete: Boolean,
): Boolean = !supplierClaimRequired || (claimed && reconciliationComplete)

internal fun resolvedOnboardingDestination(
    requested: OnboardingPage,
    ownershipConfigured: Boolean,
    reconciliationComplete: Boolean,
    phase: OwnershipPhase,
    deviceSetupComplete: Boolean,
    supplierClaimRequired: Boolean,
): OnboardingPage? {
    if (
        requested == OnboardingPage.Welcome ||
        requested == OnboardingPage.Bluetooth ||
        requested == OnboardingPage.Connect
    ) {
        return requested
    }
    if (!deviceSetupComplete) return OnboardingPage.Connect
    if (requested == OnboardingPage.Account) return OnboardingPage.Account
    if (!ownershipConfigured) return OnboardingPage.Account
    if (!reconciliationComplete) return null
    if (!accountStepCanContinue(
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = reconciliationComplete,
            phase = phase,
        )
    ) {
        return OnboardingPage.Account
    }
    val requiresClaim = requested == OnboardingPage.Profile ||
        requested == OnboardingPage.Plan ||
        requested == OnboardingPage.Done
    if (
        requiresClaim &&
        !claimStepCanContinue(
            supplierClaimRequired = supplierClaimRequired,
            claimed = phase == OwnershipPhase.CLAIMED ||
                phase == OwnershipPhase.COMPLETE,
            reconciliationComplete = reconciliationComplete,
        )
    ) {
        return OnboardingPage.Ownership
    }
    return requested
}

internal fun restoredOnboardingPageIndex(
    storedPage: String?,
    pages: List<OnboardingPage>,
    requiredAccountMigration: Boolean = false,
): Int {
    val firstPageIndex = pages
        .indexOf(OnboardingPage.Welcome)
        .coerceAtLeast(0)
    val prefix = "$ONBOARDING_PROGRESS_SCHEMA:"
    if (requiredAccountMigration) {
        return pages.indexOf(OnboardingPage.Account)
            .takeIf { it >= 0 }
            ?: firstPageIndex
    }
    if (storedPage?.startsWith(prefix) != true) return firstPageIndex

    val storedValue = storedPage.removePrefix(prefix)
    val restoredPage = OnboardingPage.entries.firstOrNull {
        it.storageValue == storedValue
    } ?: return firstPageIndex
    return pages.indexOf(restoredPage).takeIf { it >= 0 } ?: firstPageIndex
}

internal enum class OnboardingPage(val cta: String) {
    Welcome("Get Started"),
    Account("Continue"),
    WhatItDoes("Continue"),
    Expectations("I understand"),
    Bluetooth("Continue"),
    Wear("I'm wearing it"),
    Connect("Continue"),
    Bonded("Continue"),
    Ownership("Continue"),
    Profile("Save & Continue"),
    Import("Continue"),
    Notifications("Continue"),
    SafetyContacts("Finish later"),
    Appearance("Continue"),
    DailyRhythm("Continue"),
    Plan("Continue"),
    Done("Enter NOOP");

    val progressTitleRes: Int
        get() = when (this) {
            Welcome -> R.string.app_name
            Account -> R.string.appwide_onboarding_account_unconfigured_title
            WhatItDoes ->
                R.string.l10n_onboarding_screen_what_noop_does_b25b362d
            Expectations ->
                R.string.l10n_onboarding_screen_what_to_expect_ed98f851
            Bluetooth ->
                R.string
                    .l10n_onboarding_screen_a_quick_word_before_you_connect_5a29015a
            Wear ->
                R.string.l10n_onboarding_screen_put_your_strap_on_031d4807
            Connect -> R.string.appwide_onboarding_device_setup_title
            Bonded ->
                R.string.l10n_onboarding_screen_you_re_connected_7e06aee0
            Ownership -> R.string.ownership_screen_title
            Profile ->
                R.string.l10n_onboarding_screen_about_you_5c4698b6
            Import ->
                R.string.l10n_onboarding_screen_bring_your_history_5b8775c9
            Notifications ->
                R.string
                    .l10n_notifications_settings_screen_notifications_753a22b2
            SafetyContacts -> R.string.safety_setup_title
            Appearance -> R.string.l10n_settings_screen_appearance_41def7a0
            DailyRhythm -> R.string.onboarding_rhythm_title
            Plan -> R.string.ownership_plan_title
            Done -> R.string.appwide_onboarding_device_wizard_idle
        }

    val storageValue: String
        get() = when (this) {
            Welcome -> "welcome"
            Account -> "account"
            WhatItDoes -> "what"
            Expectations -> "expectations"
            Bluetooth -> "bluetooth"
            Wear -> "wear"
            Connect -> "scan"
            Bonded -> "bonded"
            Ownership -> "ownership"
            Profile -> "profile"
            Import -> "import"
            Notifications -> "notifications"
            SafetyContacts -> "safety_contacts"
            Appearance -> "appearance"
            DailyRhythm -> "daily_rhythm"
            Plan -> "plan"
            Done -> "done"
        }
}

internal const val ONBOARDING_PROGRESS_SCHEMA = 2

internal fun encodedOnboardingProgress(page: OnboardingPage): String =
    "$ONBOARDING_PROGRESS_SCHEMA:${page.storageValue}"
