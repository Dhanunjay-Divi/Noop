package com.noop.sync

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RemoteFormulaReplayStateTest {
    private val revision = "noop-charge-v2+noop-rest-v2"

    @Test
    fun intentSurvivesRestartAndDoesNotRequestNetworkWorkBeforeMigration() {
        val preferences = FakeSharedPreferences()

        assertFalse(
            RemoteFormulaReplayState.prepare(
                preferences = preferences,
                currentRevision = revision,
                computedDerivedReady = false,
                replayInProgress = false,
            ),
        )
        assertEquals(revision, RemoteFormulaReplayState.requiredRevision(preferences))

        assertTrue(
            RemoteFormulaReplayState.prepare(
                preferences = preferences,
                currentRevision = revision,
                computedDerivedReady = true,
                replayInProgress = false,
            ),
        )
    }

    @Test
    fun activeReplayKeepsItsWindowAndCursorLifecycle() {
        val preferences = FakeSharedPreferences()

        assertFalse(
            RemoteFormulaReplayState.prepare(
                preferences = preferences,
                currentRevision = revision,
                computedDerivedReady = true,
                replayInProgress = true,
            ),
        )
        assertEquals(revision, RemoteFormulaReplayState.requiredRevision(preferences))
    }

    @Test
    fun successfulCompletionClearsOnlyTheMatchingRequiredRevision() {
        val preferences = FakeSharedPreferences()
        RemoteFormulaReplayState.prepare(
            preferences = preferences,
            currentRevision = revision,
            computedDerivedReady = true,
            replayInProgress = false,
        )

        RemoteFormulaReplayState.finishSuccessfulReplay(
            preferences,
            currentRevision = "older-revision",
        )
        assertEquals(revision, RemoteFormulaReplayState.requiredRevision(preferences))
        assertNull(RemoteFormulaReplayState.completedRevision(preferences))

        RemoteFormulaReplayState.finishSuccessfulReplay(preferences, revision)
        assertNull(RemoteFormulaReplayState.requiredRevision(preferences))
        assertEquals(revision, RemoteFormulaReplayState.completedRevision(preferences))
    }

    @Test
    fun completionPersistenceFailureRetainsRequirementForSafeDuplicateReplay() {
        val preferences = FakeSharedPreferences(commitResults = listOf(true, false))
        RemoteFormulaReplayState.prepare(
            preferences = preferences,
            currentRevision = revision,
            computedDerivedReady = true,
            replayInProgress = false,
        )

        try {
            RemoteFormulaReplayState.finishSuccessfulReplay(preferences, revision)
            fail("Expected a durable completion failure")
        } catch (_: IllegalStateException) {
            // The old marker remains, so the next process requests the idempotent replay again.
        }

        assertEquals(revision, RemoteFormulaReplayState.requiredRevision(preferences))
        assertNull(RemoteFormulaReplayState.completedRevision(preferences))
        assertTrue(
            RemoteFormulaReplayState.prepare(
                preferences = preferences,
                currentRevision = revision,
                computedDerivedReady = true,
                replayInProgress = false,
            ),
        )
    }
}
