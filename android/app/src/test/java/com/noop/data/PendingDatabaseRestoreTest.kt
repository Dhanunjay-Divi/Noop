package com.noop.data

import org.junit.Assert.assertEquals
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
}
