package com.noop.ui

import android.Manifest
import android.os.Build
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
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

    @Before
    fun launchAcceptedApp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
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
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.waitUntil(timeoutMillis = 20_000) {
            runCatching {
                compose.onAllNodesWithTag("noop.tab.today")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }.getOrDefault(false)
        }
    }

    @After
    fun closeActivity() {
        scenario.close()
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
}
