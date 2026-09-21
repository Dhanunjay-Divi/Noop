package com.noop.managed

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedCloudDeletionTerminalStateTest {
    @Test
    fun localDeadlineNeverAuthorizesKeyPurge() {
        val source = File(
            managedTestRepositoryRoot(),
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        ).readText()

        assertFalse(source.contains("managedDeletionDeadlinePassed"))
        assertFalse(source.contains("completeLocalDeletionHandoff"))
        assertTrue(source.contains("\"completed\" -> completeLocalErasureState()"))
        assertFalse(
            source.contains(
                "catch (error: ManagedStorageException.NotFound)",
            ),
        )
    }
}
