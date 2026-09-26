package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.core.content.ContextCompat
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
    private var bluetoothScanWasGranted = false
    private var bluetoothConnectWasGranted = false

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
            bluetoothScanWasGranted = permissionGranted(Manifest.permission.BLUETOOTH_SCAN)
            bluetoothConnectWasGranted = permissionGranted(Manifest.permission.BLUETOOTH_CONNECT)
            if (!bluetoothScanWasGranted) {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.BLUETOOTH_SCAN,
                )
            }
            if (!bluetoothConnectWasGranted) {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            }
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

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
                if (!bluetoothScanWasGranted) {
                    automation.revokeRuntimePermission(
                        context.packageName,
                        Manifest.permission.BLUETOOTH_SCAN,
                    )
                }
                if (!bluetoothConnectWasGranted) {
                    automation.revokeRuntimePermission(
                        context.packageName,
                        Manifest.permission.BLUETOOTH_CONNECT,
                    )
                }
            }
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

    private fun permissionGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun waitForTag(tag: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun waitForTextDisplayed(text: String) {
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onNodeWithText(text).assertIsDisplayed()
            }.isSuccess
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
