package com.noop.ui

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.FirebaseAppCheck
import com.noop.BuildConfig
import com.noop.NoopApplication
import com.noop.managed.ManagedCloudPhase
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PrivateNativePilotInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private var originalAnimatorScale: String? = null
    private var animatorScaleChanged = false

    @After
    fun closeActivity() {
        scenario?.close()
        if (animatorScaleChanged) {
            originalAnimatorScale?.let {
                runShellCommand("settings put global animator_duration_scale $it")
            } ?: runShellCommand("settings delete global animator_duration_scale")
        }
    }

    @Test
    fun emitTemporaryAppCheckAssertionForRegistration() {
        requireMode(MODE_DISCOVER)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val service = (context.applicationContext as NoopApplication).managedCloud
        assertTrue("Private managed configuration is unavailable.", service.isAvailable)

        service.bootstrap()
        val firebase = FirebaseApp.getApps(context)
            .firstOrNull { it.name == MANAGED_FIREBASE_APP_NAME }
        assertNotNull("Managed Firebase did not initialize.", firebase)

        val completed = CountDownLatch(1)
        FirebaseAppCheck.getInstance(requireNotNull(firebase))
            .getAppCheckToken(true)
            .addOnCompleteListener { completed.countDown() }
        assertTrue(
            "App Check assertion generation did not complete.",
            completed.await(30, TimeUnit.SECONDS),
        )
    }

    @Test
    fun privatePilotEnrollmentAndIdempotentSync() {
        requireMode(MODE_EXECUTE)
        val code = InstrumentationRegistry.getArguments().getString(ARG_CODE)
        assertTrue(
            "Private synthetic verification code is unavailable.",
            code != null && code.matches(Regex("^[0-9]{6}$")),
        )
        assertTrue(
            "Private synthetic phone configuration is unavailable.",
            BuildConfig.MANAGED_TEST_PHONE.matches(Regex("^\\+[1-9][0-9]{7,14}$")),
        )

        launchPilot()
        waitForTag(TAG_SETUP, 30_000)
        compose.onNodeWithTag(TAG_SETUP).performClick()

        waitForTag(TAG_PHONE, 10_000)
        compose.onNodeWithTag(TAG_PHONE).performTextInput(BuildConfig.MANAGED_TEST_PHONE)
        compose.onNodeWithTag(TAG_SEND_CODE).assertIsEnabled().performClick()

        waitForTag(TAG_CODE, 30_000)
        compose.onNodeWithTag(TAG_CODE).performTextInput(requireNotNull(code))
        compose.onNodeWithTag(TAG_VERIFY_CODE)
            .performScrollTo()
            .assertIsEnabled()
            .performClick()

        waitForTag(TAG_CONSENT, 30_000)
        compose.onNodeWithTag(TAG_ENROLL)
            .performScrollTo()
            .assertIsNotEnabled()
        compose.onNodeWithTag(TAG_CONSENT)
            .performScrollTo()
            .performClick()
            .assertIsOn()
        compose.onNodeWithTag(TAG_ENROLL)
            .performScrollTo()
            .assertIsEnabled()
            .performClick()

        waitForTag(TAG_ENROLLED, 60_000)
        compose.onNodeWithTag(TAG_ENROLLED).assertIsDisplayed()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val service = (context.applicationContext as NoopApplication).managedCloud
        compose.waitUntil(timeoutMillis = 90_000) {
            val state = service.state.value
            state.phase == ManagedCloudPhase.ENROLLED &&
                !state.busy &&
                state.lastSuccessMs > 0L
        }

        repeat(2) {
            val previousSuccess = service.state.value.lastSuccessMs
            compose.onNodeWithTag(TAG_SYNC)
                .performScrollTo()
                .assertIsEnabled()
                .performClick()
            compose.waitUntil(timeoutMillis = 90_000) {
                val state = service.state.value
                state.phase == ManagedCloudPhase.ENROLLED &&
                    !state.busy &&
                    state.lastSuccessMs > previousSuccess
            }
        }
    }

    private fun launchPilot() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        originalAnimatorScale = Settings.Global.getString(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
        )
        runShellCommand("settings put global animator_duration_scale 0")
        animatorScaleChanged = true
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        }
        NoopPrefs.of(context).edit()
            .putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, Terms.CURRENT_VERSION)
            .putBoolean(NoopPrefs.KEY_ONBOARDED, true)
            .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
            .commit()

        val intent = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_DEMO_ROUTE, "noop_plus")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        scenario = ActivityScenario.launch(intent)
    }

    private fun requireMode(expected: String) {
        val mode = InstrumentationRegistry.getArguments().getString(ARG_MODE)
        assumeTrue("Private synthetic pilot is opt-in.", mode == expected)
    }

    private fun waitForTag(tag: String, timeoutMillis: Long) {
        compose.waitUntil(timeoutMillis = timeoutMillis) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun runShellCommand(command: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }

    private companion object {
        const val ARG_MODE = "noopPrivateNativePilot"
        const val ARG_CODE = "noopPrivateNativePilotCode"
        const val MODE_DISCOVER = "discover"
        const val MODE_EXECUTE = "execute"
        const val MANAGED_FIREBASE_APP_NAME = "noop-managed"
        const val TAG_SETUP = "noop.noop-plus.setup"
        const val TAG_PHONE = "noop.noop-plus.phone"
        const val TAG_SEND_CODE = "noop.noop-plus.send-code"
        const val TAG_CODE = "noop.noop-plus.code"
        const val TAG_VERIFY_CODE = "noop.noop-plus.verify-code"
        const val TAG_CONSENT = "noop.noop-plus.consent"
        const val TAG_ENROLL = "noop.noop-plus.enroll"
        const val TAG_ENROLLED = "noop.noop-plus.enrolled"
        const val TAG_SYNC = "noop.noop-plus.sync"
    }
}
