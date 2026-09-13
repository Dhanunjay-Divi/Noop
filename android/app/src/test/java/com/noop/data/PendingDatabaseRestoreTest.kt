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
    private fun restoreTargets(
        profile: FakeSharedPreferences = FakeSharedPreferences(),
        noop: FakeSharedPreferences = FakeSharedPreferences(),
        notifications: FakeSharedPreferences = FakeSharedPreferences(),
        inactivity: FakeSharedPreferences = FakeSharedPreferences(),
        hydrationReminders: FakeSharedPreferences = FakeSharedPreferences(),
        windDown: FakeSharedPreferences = FakeSharedPreferences(),
    ) = BackupSettingsBridge.RestorePreferenceTargets(
        profile = profile,
        noop = noop,
        notifications = notifications,
        inactivity = inactivity,
        hydrationReminders = hydrationReminders,
        windDown = windDown,
    )

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
        val prefs = FakeSharedPreferences(commitResults = listOf(true, false))
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .apply()

        BackupSettingsBridge.applyRestoreValuesDurably(
            restoreTargets(windDown = prefs),
            emptyMap(),
        )

        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun settingsRestoreClearsDerivedStateBeforeUnknownOnlyPayloadNoOp() {
        val prefs = FakeSharedPreferences(commitResults = listOf(true, false))
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .apply()
        val decoded = BackupSettingsCodec.decode("""{"unknown.setting":true}""")

        BackupSettingsBridge.applyRestoreValuesDurably(
            restoreTargets(windDown = prefs),
            decoded,
        )

        assertTrue(decoded.isEmpty())
        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun declaredSettingsRestoreFailsBeforeChangingPreferencesWhenPayloadIsMissing() {
        val events = mutableListOf<String>()

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = false,
                persistPreferences = { events += "persist" },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                cleanup = { events += "cleanup" },
            )
        }

        assertTrue(events.isEmpty())
    }

    @Test fun failedCommitAbortsAcrossProcessBoundaryAndPreservesRollbackCleanup() {
        val noop = FakeSharedPreferences(
            commitResult = false,
            applyFailedCommitsToMemory = true,
        )
        val events = mutableListOf<String>()

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistPreferences = {
                    events += "persist"
                    BackupSettingsBridge.applyRestoreValuesDurably(
                        restoreTargets(noop = noop),
                        mapOf("units.system" to "metric"),
                    )
                },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                cleanup = { events += "cleanup" },
            )
        }

        // A failed SharedPreferences commit may already be visible in this process. It is still not
        // durable, so the restore must fail and leave the database rollback/staging files untouched.
        assertEquals("metric", noop.getString("units.system", null))
        assertEquals(listOf("persist"), events)
    }

    @Test fun successfulRestoreCleansUpOnlyAfterDurabilityAndReconciliation() {
        val events = mutableListOf<String>()

        PendingDatabaseRestore.completeConfirmedRestore(
            hasSettings = true,
            settingsExists = true,
            persistPreferences = { events += "persist" },
            reconcile = {
                assertEquals(listOf("persist"), events)
                events += "reconcile"
            },
            persistCompletion = {
                assertEquals(listOf("persist", "reconcile"), events)
                events += "completion"
            },
            cleanup = {
                assertEquals(listOf("persist", "reconcile", "completion"), events)
                events += "cleanup"
            },
        )

        assertEquals(
            listOf("persist", "reconcile", "completion", "cleanup"),
            events,
        )
    }

    @Test fun reconciliationFailurePropagatesBeforeCompletionOrCleanup() {
        val expected = IllegalStateException("reconcile failed")
        val events = mutableListOf<String>()

        val thrown = assertThrows(IllegalStateException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistPreferences = { events += "persist" },
                reconcile = {
                    events += "reconcile"
                    throw expected
                },
                persistCompletion = { events += "completion" },
                cleanup = { events += "cleanup" },
            )
        }

        assertSame(expected, thrown)
        assertEquals(listOf("persist", "reconcile"), events)
    }
}
