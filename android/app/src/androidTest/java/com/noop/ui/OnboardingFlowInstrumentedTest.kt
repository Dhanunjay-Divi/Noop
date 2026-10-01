package com.noop.ui

import android.Manifest
import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.R
import com.noop.ownership.OwnershipConfiguration
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

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
