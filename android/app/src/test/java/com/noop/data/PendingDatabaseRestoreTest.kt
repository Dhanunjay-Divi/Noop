package com.noop.data

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class PendingDatabaseRestoreTest {
    @Test fun pendingRequiresCandidate() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.APPLY_CANDIDATE,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.PENDING, true, false, true),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.PENDING, false, false, true),
        )
    }

    @Test fun applyingResumesSwapOrAcceptsCompletedSwap() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ACCEPT_LIVE,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.APPLYING, false, true, true),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.APPLY_CANDIDATE,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.APPLYING, true, false, true),
        )
    }

    @Test fun missingCandidateRollsBackOnlyWhenSafeCopyExists() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ROLLBACK,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.APPLYING, false, false, true),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(PendingDatabaseRestore.Phase.APPLYING, false, false, false),
        )
    }

    @Test fun databaseOnlyRestoreClearsDerivedPlannerStateAfterConfirmedOpen() {
        val prefs = FakeSharedPreferences()
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .commit()
        var settingsApplied = false

        PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
            hasSettings = false,
            settingsExists = false,
            applySettings = { settingsApplied = true },
            clearDerivedPlannerState = {
                BackupSettingsBridge.clearDerivedPlannerState(prefs)
            },
        )

        assertFalse(settingsApplied)
        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun settingsRestoreClearsDerivedStateBeforeUnknownOnlyPayloadNoOp() {
        val prefs = FakeSharedPreferences()
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .commit()
        val decoded = BackupSettingsCodec.decode("""{"unknown.setting":true}""")
        var settingsApplied = false

        PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
            hasSettings = true,
            settingsExists = true,
            applySettings = {
                settingsApplied = true
                assertTrue(decoded.isEmpty())
                assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
            },
            clearDerivedPlannerState = {
                BackupSettingsBridge.clearDerivedPlannerState(prefs)
            },
        )

        assertTrue(settingsApplied)
        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun declaredSettingsRestoreFailsBeforeChangingPreferencesWhenPayloadIsMissing() {
        var clearedDerivedState = false
        var settingsApplied = false

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
                hasSettings = true,
                settingsExists = false,
                applySettings = { settingsApplied = true },
                clearDerivedPlannerState = { clearedDerivedState = true },
            )
        }

        assertFalse(clearedDerivedState)
        assertFalse(settingsApplied)
    }

    @Test fun derivedStateClearFailurePropagatesBeforeSettingsApply() {
        val expected = IllegalStateException("clear failed")
        var settingsApplied = false

        val thrown = assertThrows(IllegalStateException::class.java) {
            PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
                hasSettings = true,
                settingsExists = true,
                applySettings = { settingsApplied = true },
                clearDerivedPlannerState = { throw expected },
            )
        }

        assertSame(expected, thrown)
        assertFalse(settingsApplied)
    }

    @Test fun settingsApplyFailurePropagatesAfterDerivedStateClear() {
        val expected = IllegalStateException("apply failed")
        var clearedDerivedState = false

        val thrown = assertThrows(IllegalStateException::class.java) {
            PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
                hasSettings = true,
                settingsExists = true,
                applySettings = { throw expected },
                clearDerivedPlannerState = { clearedDerivedState = true },
            )
        }

        assertSame(expected, thrown)
        assertTrue(clearedDerivedState)
    }
}
