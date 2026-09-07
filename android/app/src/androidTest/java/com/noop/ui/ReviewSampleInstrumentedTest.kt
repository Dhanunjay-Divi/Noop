package com.noop.ui

import android.content.Intent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkManager
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReviewSampleInstrumentedTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun closeActivity() {
        scenario?.close()
    }

    @Test
    fun reviewSampleIsVisibleNavigableAndExitableWithoutHardware() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertFalse(WorkManager.isInitialized())
        NoopPrefs.of(context)
            .edit()
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION)
            .remove(NoopPrefs.KEY_ACCEPTED_TERMS_AT)
            .commit()
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_DEMO_ROUTE, DEMO_REVIEW_SAMPLE_ROUTE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        scenario = ActivityScenario.launch(intent)

        compose.onNodeWithTag("noop.review.entry.explore").assertIsDisplayed().performClick()
        compose.onNodeWithTag("noop.review.disclosure.enter").assertIsDisplayed().performClick()
        compose.onNodeWithTag("noop.review.root").assertIsDisplayed()
        compose.onNodeWithTag("noop.review.metric.recovery").assertIsDisplayed().performClick()
        compose.onNodeWithTag("noop.review.exit").assertIsDisplayed().performClick()
        assertTrue(compose.onAllNodesWithTag("noop.review.root").fetchSemanticsNodes().isEmpty())
        compose.onNodeWithTag("noop.terms.title").assertIsDisplayed()
        assertFalse(WorkManager.isInitialized())
    }
}
