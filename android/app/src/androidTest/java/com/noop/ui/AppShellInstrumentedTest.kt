package com.noop.ui

import android.Manifest
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertTrue
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppShellInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private lateinit var scenario: ActivityScenario<MainActivity>
    private var originalAnimatorScale: String? = null
    private var acceptedTermsWasPresent = false
    private var originalAcceptedTermsVersion: String? = null
    private var onboardedWasPresent = false
    private var originalOnboarded = false
    private var changelogWasPresent = false
    private var originalLastSeenChangelog: String? = null

    @Before
    fun launchAcceptedApp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // A populated demo runs deliberate infinite liquid clocks. Compose correctly treats those as
        // continuously busy, so waitForIdle cannot inspect an otherwise-ready shell. Exercise the
        // production Reduce Motion path and restore the developer's previous setting in tearDown.
        originalAnimatorScale = Settings.Global.getString(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
        )
        runShellCommand(instrumentation, "settings put global animator_duration_scale 0")
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
        val prefs = NoopPrefs.of(context)
        acceptedTermsWasPresent = prefs.contains(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
        originalAcceptedTermsVersion =
            prefs.getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, null)
        onboardedWasPresent = prefs.contains(NoopPrefs.KEY_ONBOARDED)
        originalOnboarded = prefs.getBoolean(NoopPrefs.KEY_ONBOARDED, false)
        changelogWasPresent = prefs.contains(NoopPrefs.KEY_LAST_SEEN_CHANGELOG)
        originalLastSeenChangelog =
            prefs.getString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, null)
        prefs.edit()
            .putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, Terms.CURRENT_VERSION)
            .putBoolean(NoopPrefs.KEY_ONBOARDED, true)
            .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
            .commit()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onAllNodesWithTag("noop.today.list")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }.getOrDefault(false)
        }
        assertSelected("noop.tab.today")
    }

    @After
    fun closeActivity() {
        try {
            if (::scenario.isInitialized) scenario.close()
        } finally {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            restorePreferences(instrumentation.targetContext)
            val restore = originalAnimatorScale?.let {
                "settings put global animator_duration_scale $it"
            } ?: "settings delete global animator_duration_scale"
            runShellCommand(instrumentation, restore)
        }
    }

    @Test
    fun primaryTabsNavigateAndExposeSelection() {
        assertSelected("noop.tab.today")
        selectAndAssert("noop.tab.trends")
        selectAndAssert("noop.tab.workouts")
        selectAndAssert("noop.tab.sleep")
        selectAndAssert("noop.tab.more")
    }

    @Test
    fun floatingQuickActionsOpenProductionLauncher() {
        compose.onNodeWithTag("noop.quick-actions").fetchSemanticsNode()
        compose.onNodeWithTag("noop.quick-actions").performClick()
        compose.onNodeWithText("Workout").fetchSemanticsNode()
        compose.onNodeWithText("Strength").fetchSemanticsNode()
        compose.onNodeWithText("Meal").fetchSemanticsNode()
        compose.onNodeWithText("Live HR").fetchSemanticsNode()
    }

    @Test
    fun friendsIsReachableFromMore() {
        compose.onNodeWithTag("noop.tab.more").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("noop.more.friends").performScrollTo().performClick()
        compose.waitUntil(timeoutMillis = 10_000) {
            runCatching {
                compose.onAllNodesWithTag("noop.screen.friends")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }.getOrDefault(false)
        }
        compose.onNodeWithTag("noop.friends.source.managed").performClick()
        compose.onNodeWithTag("noop.friends.source.managed").assertIsSelected()
        compose.onNodeWithTag("noop.friends.source.selfHosted").performClick()
        compose.onNodeWithTag("noop.friends.source.selfHosted").assertIsSelected()
        compose.onNodeWithTag("noop.screen.friends").assertIsDisplayed()
    }

    @Test
    fun todayMetricDetailKeepsTodaySelectedAndReselectReturnsToRoot() {
        val metricTag = "noop.today.metric.hrv"
        compose.onNodeWithTag("noop.today.list")
            .performScrollToNode(hasTestTag(metricTag))
        compose.onNodeWithTag(metricTag).performClick()
        compose.waitUntil(timeoutMillis = 10_000) {
            compose.onAllNodesWithTag("noop.today.list").fetchSemanticsNodes().isEmpty()
        }
        assertSelected("noop.tab.today")

        compose.onNodeWithTag("noop.tab.today").performClick()
        compose.waitUntil(timeoutMillis = 10_000) {
            compose.onAllNodesWithTag("noop.today.list").fetchSemanticsNodes().isNotEmpty()
        }
    }

    @Test
    fun appReportKeepsContextOptionalAndReviewsExactDefaultAttachments() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            AppDiagnosticReportRequestBridge.request()
        }
        compose.waitUntil(timeoutMillis = 10_000) {
            compose.onAllNodesWithTag("noop.app-report.user-note")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }

        repeat(2) {
            compose.onNodeWithTag("noop.app-report.scroll")
                .performTouchInput { swipeUp(durationMillis = 400) }
        }
        compose.onNodeWithTag("noop.app-report.include-screenshot").assertIsDisplayed()
        compose.onNodeWithTag("noop.app-report.user-note")
            .performTextInput("Health scrolling paused after I opened a metric")
        compose.onNodeWithTag("noop.app-report.include-screenshot")
            .performScrollTo()
            .assertIsOff()
        compose.onNodeWithText("Build report")
            .performScrollTo()
            .performClick()

        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithText("Report ready")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithText("user-note.txt").performScrollTo().fetchSemanticsNode()
        compose.onNodeWithText("app-session-current.jsonl").performScrollTo().fetchSemanticsNode()
        compose.onNodeWithText("meta.json").performScrollTo().fetchSemanticsNode()
        assertTrue(
            "A screen snapshot must not attach unless the user explicitly opts in",
            compose.onAllNodesWithText("screenshot.png").fetchSemanticsNodes().isEmpty(),
        )
    }

    private fun selectAndAssert(tag: String) {
        compose.onNodeWithTag(tag).fetchSemanticsNode()
        compose.onNodeWithTag(tag).performClick()
        compose.waitForIdle()
        assertSelected(tag)
    }

    private fun assertSelected(tag: String) {
        val selected = compose.onNodeWithTag(tag)
            .fetchSemanticsNode()
            .config[SemanticsProperties.Selected]
        assertTrue("$tag is not selected", selected)
    }

    private fun restorePreferences(context: android.content.Context) {
        val editor = NoopPrefs.of(context).edit()
        if (acceptedTermsWasPresent) {
            editor.putString(
                NoopPrefs.KEY_ACCEPTED_TERMS_VERSION,
                originalAcceptedTermsVersion,
            )
        } else {
            editor.remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
        }
        if (onboardedWasPresent) {
            editor.putBoolean(NoopPrefs.KEY_ONBOARDED, originalOnboarded)
        } else {
            editor.remove(NoopPrefs.KEY_ONBOARDED)
        }
        if (changelogWasPresent) {
            editor.putString(
                NoopPrefs.KEY_LAST_SEEN_CHANGELOG,
                originalLastSeenChangelog,
            )
        } else {
            editor.remove(NoopPrefs.KEY_LAST_SEEN_CHANGELOG)
        }
        editor.commit()
    }

    private fun runShellCommand(
        instrumentation: android.app.Instrumentation,
        command: String,
    ) {
        ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }

}
