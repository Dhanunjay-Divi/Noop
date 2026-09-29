package com.noop.managed

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ManagedDocumentConflictContractTest {
    @Test
    fun documentConflictCarriesOnlyBoundedRecoveryContext() {
        val conflict = ManagedStorageException.Conflict(
            documentKind = ManagedDocumentKind.HYDRATION,
            remoteRevision = 7,
        )

        assertEquals(ManagedDocumentKind.HYDRATION, conflict.documentKind)
        assertEquals(7L, conflict.remoteRevision)
        assertEquals(
            "NOOP kept your current data. Review your latest changes, then tap Sync now to retry.",
            conflict.message,
        )
    }

    @Test
    fun genericServerConflictDoesNotInventDocumentContext() {
        val conflict = ManagedStorageException.Conflict()

        assertNull(conflict.documentKind)
        assertNull(conflict.remoteRevision)
        assertEquals("NOOP+ rejected conflicting sync state.", conflict.message)
    }
}
