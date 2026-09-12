package com.noop.data

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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

        val restored = PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
            hasSettings = false,
            settingsExists = false,
            applySettings = { settingsApplied = true },
            clearDerivedPlannerState = {
                BackupSettingsBridge.clearDerivedPlannerState(prefs)
            },
        )

        assertTrue(restored)
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

        val restored = PendingDatabaseRestore.restorePreferencesAfterConfirmedOpen(
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

        assertTrue(restored)
        assertTrue(settingsApplied)
        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }
}
