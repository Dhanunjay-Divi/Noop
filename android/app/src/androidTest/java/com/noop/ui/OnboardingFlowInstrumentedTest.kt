package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.R
import com.noop.ownership.NoopProductPlan
import com.noop.ownership.OwnershipConfiguration
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private object HermeticConfiguredProviderOnboardingHarness :
    OnboardingInstrumentationHarness {
    @Composable
    override fun AccountStep(
        accountReady: Boolean,
        onSyntheticSuccess: () -> Unit,
    ) {
        var createMode by rememberSaveable { mutableStateOf(true) }
        var email by rememberSaveable { mutableStateOf("") }
        var password by rememberSaveable { mutableStateOf("") }
        var confirmation by rememberSaveable { mutableStateOf("") }
        var acceptedTerms by rememberSaveable { mutableStateOf(false) }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(vertical = 8.dp)
                .testTag("noop.onboarding.account-configured-test"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OwnershipAuthenticationCard(
                createMode = createMode,
                onCreateModeChange = { createMode = it },
                terms =
                    "Synthetic ownership policy for automated UI validation only.",
                acceptedTerms = acceptedTerms,
                onAcceptedTermsChange = { acceptedTerms = it },
                email = email,
                onEmailChange = { email = it.take(254) },
                password = password,
                onPasswordChange = { password = it.take(128) },
                confirmation = confirmation,
                onConfirmationChange = { confirmation = it.take(128) },
                emailError = null,
                passwordError = null,
                busy = accountReady,
                onAuthenticate = {
                    if (
                        hermeticOwnershipSubmissionReady(
                            createMode = createMode,
                            email = email,
                            password = password,
                            confirmation = confirmation,
                            acceptedTerms = acceptedTerms,
                        )
                    ) {
                        password = ""
                        confirmation = ""
                        onSyntheticSuccess()
                    }
                },
                onPasswordReset = {},
                onLoadTerms = {},
            )
            if (accountReady) {
                Text(
                    text = "Synthetic account authenticated",
                    style = NoopType.caption,
                    color = Palette.statusPositive,
                    modifier = Modifier.testTag(
                        "noop.ui-test.account.success",
                    ),
                )
            }
        }
    }

    @Composable
    override fun SupportedBandPicker(
        onSelectSimulatedBand: () -> Unit,
        onClose: () -> Unit,
    ) {
        Dialog(
            onDismissRequest = onClose,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .testTag("noop.ui-test.band-picker"),
                shape = RoundedCornerShape(8.dp),
                color = Palette.surfaceRaised,
            ) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Text(
                        text = "Choose a supported simulated band",
                        style = NoopType.title2,
                        color = Palette.textPrimary,
                    )
                    Text(
                        text =
                            "Instrumentation only. No Bluetooth scan, firmware, identifier, or credential is used.",
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                    NoopButton(
                        text = "Simulated NOOP Band",
                        leadingIcon = Icons.Filled.Watch,
                        fullWidth = true,
                        modifier = Modifier.testTag(
                            "noop.device-wizard.type.supplier-band",
                        ),
                        onClick = onSelectSimulatedBand,
                    )
                    NoopButton(
                        text = "Close",
                        leadingIcon = Icons.Filled.Close,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        onClick = onClose,
                    )
                }
            }
        }
    }

    @Composable
    override fun OwnershipStep(
        claimed: Boolean,
        onSyntheticClaim: () -> Unit,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            NoopCard(padding = 20.dp) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Text(
                        text = "Confirm simulated band ownership",
                        style = NoopType.title2,
                        color = Palette.textPrimary,
                    )
                    Text(
                        text =
                            "This in-memory confirmation exercises the ownership gate without Bluetooth or a provider request.",
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                    NoopButton(
                        text = if (claimed) {
                            "Ownership confirmed"
                        } else {
                            "Confirm simulated band"
                        },
                        leadingIcon = if (claimed) {
                            Icons.Filled.CheckCircle
                        } else {
                            Icons.Filled.Vibration
                        },
                        fullWidth = true,
                        enabled = !claimed,
                        modifier = Modifier.testTag(
                            "noop.ui-test.ownership.claim",
                        ),
                        onClick = onSyntheticClaim,
                    )
                    if (claimed) {
                        Text(
                            text = "Synthetic ownership success",
                            style = NoopType.caption,
                            color = Palette.statusPositive,
                            modifier = Modifier.testTag(
                                "noop.ui-test.ownership.success",
                            ),
                        )
                    }
                }
            }
        }
    }

    @Composable
    override fun OperationalShellBoundary() {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .testTag("noop.ui-test.operational-shell-boundary"),
            color = Palette.surfaceBase,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(24.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    text = "Synthetic setup completed",
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            }
        }
    }
}

@RunWith(AndroidJUnit4::class)
class OnboardingFlowInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var context: Context
    private var originalAnimatorScale: String? = null
    private var originalAcceptedTerms: String? = null
    private var acceptedTermsWasPresent = false
    private var originalOnboarded = false
    private var onboardedWasPresent = false
    private var originalProgressV2: String? = null
    private var originalProgressV1: String? = null

    @Before
    fun launchFreshInstall() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        context = instrumentation.targetContext
        assumeTrue(
            "The deterministic exploration flow requires an unconfigured account service.",
            OwnershipConfiguration.load() == null,
        )
        originalAnimatorScale = Settings.Global.getString(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
        )
        instrumentation.uiAutomation.executeShellCommand(
            "settings put global animator_duration_scale 0",
        ).close()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.BLUETOOTH_SCAN,
            )
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        }

        // Terms acceptance is a separate contract. This test starts immediately after that boundary so
        // it can deterministically exercise the unconfigured account and supported-device path.
        val prefs = NoopPrefs.of(context)
        acceptedTermsWasPresent = prefs.contains(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
        originalAcceptedTerms = prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, null)
        onboardedWasPresent = prefs.contains(NoopPrefs.KEY_ONBOARDED)
        originalOnboarded = prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false)
        originalProgressV2 = prefs.getString(PROGRESS_V2, null)
        originalProgressV1 = prefs.getString(PROGRESS_V1, null)
        prefs.edit()
            .putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, Terms.CURRENT_VERSION)
            .putBoolean(NoopPrefs.KEY_ONBOARDED, false)
            .remove(PROGRESS_V2)
            .remove(PROGRESS_V1)
            .commit()

        scenario = ActivityScenario.launch(MainActivity::class.java)
        waitForTag("noop.onboarding.page.welcome")
    }

    @After
    fun restoreState() {
        if (::scenario.isInitialized) scenario.close()
        if (::context.isInitialized) {
            val editor = NoopPrefs.of(context).edit()
            if (acceptedTermsWasPresent) {
                editor.putString(
                    NoopPrefs.KEY_ACCEPTED_TERMS_VERSION,
                    originalAcceptedTerms,
                )
            } else {
                editor.remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
            }
            if (onboardedWasPresent) {
                editor.putBoolean(NoopPrefs.KEY_ONBOARDED, originalOnboarded)
            } else {
                editor.remove(NoopPrefs.KEY_ONBOARDED)
            }
            restoreString(editor, PROGRESS_V2, originalProgressV2)
            restoreString(editor, PROGRESS_V1, originalProgressV1)
            editor.commit()

            val restoreAnimator = originalAnimatorScale?.let {
                "settings put global animator_duration_scale $it"
            } ?: "settings delete global animator_duration_scale"
            InstrumentationRegistry.getInstrumentation()
                .uiAutomation
                .executeShellCommand(restoreAnimator)
                .close()
        }
    }

    @Test
    fun postTermsUnconfiguredAccountFlowReachesSupportedBandPicker() {
        compose.onNodeWithTag("noop.onboarding.root").assertIsDisplayed()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Get Started")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.account")
        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_account_unconfigured_title),
        )
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Continue")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.bluetooth")
        waitForTextDisplayed(
            context.getString(
                R.string.l10n_onboarding_screen_a_quick_word_before_you_connect_5a29015a,
            ),
        )
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.scan")
        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_device_setup_title),
        )
        compose.onNodeWithTag("noop.onboarding.choose-device")
            .assertIsDisplayed()
            .performClick()

        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_device_wizard_compatible_5_title),
        )
        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_device_wizard_compatible_4_title),
        )
        compose.onNodeWithText("Heart-rate strap").assertDoesNotExist()
        compose.onNodeWithText("Gym equipment").assertDoesNotExist()
        compose.onNodeWithText("Oura Ring").assertDoesNotExist()
    }

    private fun waitForTag(tag: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onNodeWithTag(tag).assertIsDisplayed()
            }.isSuccess
        }
    }

    private fun waitForTextDisplayed(text: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun restoreString(
        editor: android.content.SharedPreferences.Editor,
        key: String,
        value: String?,
    ) {
        if (value == null) editor.remove(key) else editor.putString(key, value)
    }

    private companion object {
        const val PROGRESS_V2 = "noop.onboarding.progress.v2"
        const val PROGRESS_V1 = "noop.onboarding.progress.v1"
    }
}

@RunWith(AndroidJUnit4::class)
class FreshInstallOnboardingOrderInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var context: Context
    private var originalAcceptedTerms: String? = null
    private var acceptedTermsWasPresent = false
    private var originalAcceptedTermsAt: String? = null
    private var acceptedTermsAtWasPresent = false
    private var originalOnboarded = false
    private var onboardedWasPresent = false
    private var originalFirstInstallWelcomePending = false
    private var firstInstallWelcomePendingWasPresent = false
    private var originalCompletedFirstInstallWelcome = false
    private var completedFirstInstallWelcomeWasPresent = false
    private var originalLastSeenChangelog: String? = null
    private var lastSeenChangelogWasPresent = false
    private var originalProgressV2: String? = null
    private var originalProgressV1: String? = null

    @Before
    fun launchFromTerms() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        context = instrumentation.targetContext
        assumeTrue(
            "The deterministic exploration flow requires an unconfigured account service.",
            OwnershipConfiguration.load() == null,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.BLUETOOTH_SCAN,
            )
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        }

        val prefs = NoopPrefs.of(context)
        acceptedTermsWasPresent = prefs.contains(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
        originalAcceptedTerms = prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, null)
        acceptedTermsAtWasPresent = prefs.contains(NoopPrefs.KEY_ACCEPTED_TERMS_AT)
        originalAcceptedTermsAt = prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_AT, null)
        onboardedWasPresent = prefs.contains(NoopPrefs.KEY_ONBOARDED)
        originalOnboarded = prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false)
        firstInstallWelcomePendingWasPresent =
            prefs.contains(NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING)
        originalFirstInstallWelcomePending =
            prefs.getBoolean(NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING, false)
        completedFirstInstallWelcomeWasPresent =
            prefs.contains(NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME)
        originalCompletedFirstInstallWelcome =
            prefs.getBoolean(NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME, false)
        lastSeenChangelogWasPresent = prefs.contains(NoopPrefs.KEY_LAST_SEEN_CHANGELOG)
        originalLastSeenChangelog = prefs.getString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, null)
        originalProgressV2 = prefs.getString(PROGRESS_V2, null)
        originalProgressV1 = prefs.getString(PROGRESS_V1, null)
        prefs.edit()
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_AT)
            .putBoolean(NoopPrefs.KEY_ONBOARDED, false)
            .remove(NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING)
            .remove(NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME)
            .remove(NoopPrefs.KEY_LAST_SEEN_CHANGELOG)
            .remove(PROGRESS_V2)
            .remove(PROGRESS_V1)
            .commit()

        scenario = ActivityScenario.launch(MainActivity::class.java)
        waitForTag("noop.terms.title")
    }

    @After
    fun restoreState() {
        if (::scenario.isInitialized) scenario.close()
        if (!::context.isInitialized) return
        val editor = NoopPrefs.of(context).edit()
        if (acceptedTermsWasPresent) {
            editor.putString(
                NoopPrefs.KEY_ACCEPTED_TERMS_VERSION,
                originalAcceptedTerms,
            )
        } else {
            editor.remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
        }
        restoreString(
            editor,
            NoopPrefs.KEY_ACCEPTED_TERMS_AT,
            originalAcceptedTermsAt,
            acceptedTermsAtWasPresent,
        )
        if (onboardedWasPresent) {
            editor.putBoolean(NoopPrefs.KEY_ONBOARDED, originalOnboarded)
        } else {
            editor.remove(NoopPrefs.KEY_ONBOARDED)
        }
        restoreBoolean(
            editor,
            NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING,
            originalFirstInstallWelcomePending,
            firstInstallWelcomePendingWasPresent,
        )
        restoreBoolean(
            editor,
            NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME,
            originalCompletedFirstInstallWelcome,
            completedFirstInstallWelcomeWasPresent,
        )
        restoreString(
            editor,
            NoopPrefs.KEY_LAST_SEEN_CHANGELOG,
            originalLastSeenChangelog,
            lastSeenChangelogWasPresent,
        )
        restoreString(editor, PROGRESS_V2, originalProgressV2)
        restoreString(editor, PROGRESS_V1, originalProgressV1)
        editor.commit()
    }

    @Test
    fun freshInstallOrdersTermsAccountBluetoothAndBandSetup() {
        compose.onNodeWithTag("noop.onboarding.root").assertDoesNotExist()
        compose.onNodeWithTag("noop.tab.today").assertDoesNotExist()

        Terms.attestations.indices.forEach { index ->
            compose.onNodeWithTag("noop.terms.attestation.$index")
                .performScrollTo()
                .assertIsDisplayed()
                .performClick()
        }
        compose.onNodeWithTag("noop.terms.accept")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.welcome")
        compose.onNodeWithTag("noop.tab.today").assertDoesNotExist()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Get Started")
            .performClick()

        waitForTag("noop.onboarding.page.account")
        compose.onNodeWithTag("noop.tab.today").assertDoesNotExist()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Continue")
            .performClick()

        waitForTag("noop.onboarding.page.bluetooth")
        compose.onNodeWithTag("noop.tab.today").assertDoesNotExist()
        compose.onNodeWithTag("noop.onboarding.primary").performClick()

        waitForTag("noop.onboarding.page.scan")
        compose.onNodeWithTag("noop.tab.today").assertDoesNotExist()
        compose.onNodeWithTag("noop.onboarding.choose-device")
            .assertIsDisplayed()
            .performClick()

        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_device_wizard_compatible_5_title),
        )
        waitForTextDisplayed(
            context.getString(R.string.appwide_onboarding_device_wizard_compatible_4_title),
        )
        compose.onNodeWithText("Heart-rate strap").assertDoesNotExist()
        compose.onNodeWithText("Gym equipment").assertDoesNotExist()
        compose.onNodeWithText("Oura Ring").assertDoesNotExist()
    }

    private fun waitForTag(tag: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onNodeWithTag(tag).assertIsDisplayed()
            }.isSuccess
        }
    }

    private fun waitForTextDisplayed(text: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun restoreString(
        editor: android.content.SharedPreferences.Editor,
        key: String,
        value: String?,
        wasPresent: Boolean = value != null,
    ) {
        if (wasPresent) editor.putString(key, value) else editor.remove(key)
    }

    private fun restoreBoolean(
        editor: android.content.SharedPreferences.Editor,
        key: String,
        value: Boolean,
        wasPresent: Boolean,
    ) {
        if (wasPresent) editor.putBoolean(key, value) else editor.remove(key)
    }

    private companion object {
        const val PROGRESS_V2 = "noop.onboarding.progress.v2"
        const val PROGRESS_V1 = "noop.onboarding.progress.v1"
    }
}

@RunWith(AndroidJUnit4::class)
class ConfiguredProviderFullOnboardingInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private data class StoredPreference(
        val present: Boolean,
        val value: Any?,
    )

    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var context: Context
    private lateinit var harnessRegistration: AutoCloseable
    private lateinit var originalPlan: NoopProductPlan
    private var originalAnimatorScale: String? = null
    private val originalPreferences = linkedMapOf<String, StoredPreference>()

    @Before
    fun launchHermeticConfiguredProviderFlow() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        context = instrumentation.targetContext
        OnboardingInstrumentationHarnessRegistry.clearForInstrumentation()
        harnessRegistration =
            OnboardingInstrumentationHarnessRegistry.installForInstrumentation(
                HermeticConfiguredProviderOnboardingHarness,
            )
        originalAnimatorScale = Settings.Global.getString(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
        )
        instrumentation.uiAutomation.executeShellCommand(
            "settings put global animator_duration_scale 0",
        ).close()

        val prefs = NoopPrefs.of(context)
        preferenceKeys.forEach { key ->
            originalPreferences[key] = StoredPreference(
                present = prefs.contains(key),
                value = prefs.all[key],
            )
        }
        originalPlan = NoopProductPlan.stored(context)
        prefs.edit()
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_AT)
            .putBoolean(NoopPrefs.KEY_ONBOARDED, false)
            .putBoolean(NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING, false)
            .putBoolean(NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME, true)
            .putString(
                NoopPrefs.KEY_LAST_SEEN_CHANGELOG,
                AppChangelog.CURRENT_VERSION,
            )
            .remove(PROGRESS_V2)
            .remove(PROGRESS_V1)
            .commit()

        scenario = ActivityScenario.launch(MainActivity::class.java)
        waitForTag("noop.terms.title")
    }

    @After
    fun restoreState() {
        if (::scenario.isInitialized) scenario.close()
        if (::context.isInitialized) {
            val editor = NoopPrefs.of(context).edit()
            originalPreferences.forEach { (key, stored) ->
                restorePreference(editor, key, stored)
            }
            editor.commit()

            val restoreAnimator = originalAnimatorScale?.let {
                "settings put global animator_duration_scale $it"
            } ?: "settings delete global animator_duration_scale"
            InstrumentationRegistry.getInstrumentation()
                .uiAutomation
                .executeShellCommand(restoreAnimator)
                .close()
        }
        if (::harnessRegistration.isInitialized) {
            harnessRegistration.close()
        }
        OnboardingInstrumentationHarnessRegistry.clearForInstrumentation()
    }

    @Test
    fun configuredProviderAndSimulatedBandCompleteFullOnboarding() {
        assertTabsUnavailable()
        Terms.attestations.indices.forEach { index ->
            compose.onNodeWithTag("noop.terms.attestation.$index")
                .performScrollTo()
                .assertIsDisplayed()
                .performClick()
        }
        compose.onNodeWithTag("noop.terms.accept")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.welcome")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Get Started")
            .performClick()

        waitForTag("noop.onboarding.account-configured-test")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsNotEnabled()
        compose.onNodeWithTag("noop.ownership.mode.create")
            .assertIsDisplayed()
        compose.onNodeWithTag("noop.ownership.mode.sign-in")
            .assertIsDisplayed()
            .performClick()
        compose.onNodeWithTag("noop.ownership.password_confirmation")
            .assertDoesNotExist()
        compose.onNodeWithTag("noop.ownership.mode.create")
            .performClick()
        compose.onNodeWithTag("noop.ownership.password_confirmation")
            .assertIsDisplayed()

        compose.onNodeWithTag("noop.ownership.email")
            .performScrollTo()
            .performTextInput("configured-ui-test@example.invalid")
        compose.onNodeWithTag("noop.ownership.password")
            .performScrollTo()
            .performTextInput("synthetic-passphrase")
        compose.onNodeWithTag("noop.ownership.password_confirmation")
            .performScrollTo()
            .performTextInput("synthetic-passphrase")
        compose.onNodeWithTag("noop.ownership.pre-account-terms-agree")
            .performScrollTo()
            .performClick()
        compose.onNodeWithTag("noop.ownership.authenticate")
            .performScrollTo()
            .assertIsEnabled()
            .performClick()

        waitForNode("noop.ui-test.account.success")
        compose.onNodeWithTag("noop.ui-test.account.success")
            .performScrollTo()
            .assertIsDisplayed()
        waitForEnabled("noop.onboarding.primary")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary").performClick()

        waitForTag("noop.onboarding.page.bluetooth")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.scan")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsNotEnabled()
        compose.onNodeWithTag("noop.onboarding.choose-device")
            .assertIsDisplayed()
            .performClick()

        waitForTag("noop.ui-test.band-picker")
        compose.onNodeWithTag("noop.device-wizard.type.supplier-band")
            .assertIsDisplayed()
            .performClick()

        waitForTag("noop.onboarding.page.ownership")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsNotEnabled()
        compose.onNodeWithTag("noop.ui-test.ownership.claim")
            .assertIsDisplayed()
            .performClick()
        waitForTag("noop.ui-test.ownership.success")
        waitForEnabled("noop.onboarding.primary")
        compose.onNodeWithTag("noop.onboarding.primary").performClick()

        waitForTag("noop.onboarding.page.profile")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Save & Continue")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.plan")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.onboarding.page.done")
        assertTabsUnavailable()
        compose.onNodeWithTag("noop.onboarding.primary")
            .assertTextEquals("Enter NOOP")
            .assertIsEnabled()
            .performClick()

        waitForTag("noop.ui-test.operational-shell-boundary")
        compose.onNodeWithTag("noop.onboarding.page.done")
            .assertDoesNotExist()
        assertEquals(
            "The hermetic plan step must not persist a product choice.",
            originalPlan,
            NoopProductPlan.stored(context),
        )
    }

    private fun assertTabsUnavailable() {
        primaryTabTags.forEach { tag ->
            compose.onNodeWithTag(tag).assertDoesNotExist()
        }
    }

    private fun waitForTag(tag: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onNodeWithTag(tag).assertIsDisplayed()
            }.isSuccess
        }
    }

    private fun waitForNode(tag: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun waitForEnabled(tag: String) {
        compose.waitUntil(timeoutMillis = 10_000) {
            runCatching {
                compose.onNodeWithTag(tag).assertIsEnabled()
            }.isSuccess
        }
    }

    private fun restorePreference(
        editor: SharedPreferences.Editor,
        key: String,
        stored: StoredPreference,
    ) {
        if (!stored.present) {
            editor.remove(key)
            return
        }
        when (val value = stored.value) {
            is String -> editor.putString(key, value)
            is Boolean -> editor.putBoolean(key, value)
            is Int -> editor.putInt(key, value)
            is Long -> editor.putLong(key, value)
            is Float -> editor.putFloat(key, value)
            is Set<*> -> editor.putStringSet(
                key,
                value.filterIsInstance<String>().toSet(),
            )
            else -> error("Unsupported preference type for $key")
        }
    }

    private companion object {
        const val PROGRESS_V2 = "noop.onboarding.progress.v2"
        const val PROGRESS_V1 = "noop.onboarding.progress.v1"

        val primaryTabTags = listOf(
            "noop.tab.today",
            "noop.tab.trends",
            "noop.tab.workouts",
            "noop.tab.sleep",
            "noop.tab.more",
        )

        val preferenceKeys = listOf(
            NoopPrefs.KEY_ACCEPTED_TERMS_VERSION,
            NoopPrefs.KEY_ACCEPTED_TERMS_AT,
            NoopPrefs.KEY_ONBOARDED,
            NoopPrefs.KEY_FIRST_INSTALL_WELCOME_PENDING,
            NoopPrefs.KEY_COMPLETED_FIRST_INSTALL_WELCOME,
            NoopPrefs.KEY_LAST_SEEN_CHANGELOG,
            PROGRESS_V2,
            PROGRESS_V1,
        )
    }
}
