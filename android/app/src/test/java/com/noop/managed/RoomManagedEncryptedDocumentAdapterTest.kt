package com.noop.managed

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoomManagedEncryptedDocumentAdapterTest {
    @Test
    fun adapterStagesBeforeKeyAccessAndAppliesBeforeInboxRemoval() {
        val source = source()
        val stage = source.indexOf("inbox.stageIncoming(accountScopeHash, document)")
        val key = source.indexOf("documentKeys?.documentKey(accountScopeHash, keyId)")
        val apply = source.indexOf("applyVerifiedDocument(document, payloadText, false)")
        val remove = source.indexOf("inbox.removeIncoming(accountScopeHash, document)")
        val verified = source.indexOf("private suspend fun applyVerifiedDocument")
        val disposition = source.indexOf("remoteApplyDisposition(", verified)
        val preferences = source.indexOf("applyPreferences(payload)", disposition)
        val applyMethod = source.substring(
            source.indexOf("override suspend fun apply("),
            source.indexOf("private fun pendingCandidates"),
        )
        assertTrue(stage >= 0 && key > stage)
        assertTrue(apply > key && remove > apply)
        assertTrue(disposition > verified && preferences > disposition)
        assertFalse(applyMethod.contains("applyPreferences("))
        assertTrue(source.contains("documentKeys?.recoveryEnrollmentComplete(accountScopeHash)"))
        assertFalse(source.contains("Log."))
        assertFalse(source.contains("println("))
    }

    private fun source(): String {
        val source = File(
            managedTestRepositoryRoot(),
            "android/app/src/main/java/com/noop/managed/RoomManagedDocumentAdapter.kt",
        )
        check(source.isFile) { "RoomManagedDocumentAdapter.kt is missing." }
        return source.readText()
    }
}
