package com.noop.managed

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedDocumentLifecycleContractTest {
    @Test
    fun encryptedRuntimeRequiresDurableRecoveryEnrollment() {
        val source = serviceSource()
        val runtime = source.section(
            "    private fun managedDocumentRuntime(",
            "    private fun completeLocalErasureState()",
        )

        val storage = runtime.indexOf("AndroidManagedDocumentKeyVaultStorage(appContext)")
        val persisted = runtime.indexOf("storage.load(accountScopeHash)")
        val durableGate = runtime.indexOf(
            "hasDurableManagedDocumentRecoveryEnrollment(persisted)",
        )
        val vault = runtime.indexOf("ManagedDocumentKeyVault(storage)")
        val recovery = runtime.indexOf(
            "vault.recoveryEnrollmentComplete(accountScopeHash)",
        )
        val recoveryGate = runtime.indexOf("if (!recoveryComplete)")
        val inbox = runtime.indexOf("ManagedDocumentCiphertextInbox(appContext)")
        val encryptedAdapter = runtime.indexOf("documentKeys = vault")

        assertTrue(storage >= 0)
        assertTrue(storage < persisted)
        assertTrue(persisted < durableGate)
        assertTrue(durableGate < vault)
        assertTrue(vault < recovery)
        assertTrue(recovery < recoveryGate)
        assertTrue(recoveryGate < inbox)
        assertTrue(inbox < encryptedAdapter)
        assertTrue(runtime.contains("\"mode\" to \"server_readable\""))
        assertTrue(runtime.contains("\"mode\" to \"client_encrypted\""))
        assertFalse(runtime.contains("managedDocumentKeyStateFile"))
        assertTrue(
            source.split("managedDocumentRuntime(").size - 1 >= 3,
        )
    }

    @Test
    fun confirmedAccountDeletionPurgesBeforeSignOutAndEnrollmentClear() {
        val source = serviceSource()
        val completed = source.section(
            "    private fun completeLocalErasureState()",
            "    private fun purgeManagedDocumentLocalState()",
        )

        val purge = completed.indexOf("purgeManagedDocumentLocalState()")
        val signOut = completed.indexOf("runtime().auth.signOut()")
        val clear = completed.indexOf("preferences.clearEnrollment()")
        assertTrue(purge >= 0)
        assertTrue(purge < signOut)
        assertTrue(signOut < clear)
        val purgeState = source.section(
            "    private fun purgeManagedDocumentLocalState()",
            "    private fun restoreAfterCanceledErasure()",
        )
        assertTrue(
            purgeState.contains(
                "val scopeHash = preferences.enrolledScopeHash",
            ),
        )
        assertFalse(purgeState.contains("accountScopeHash()"))
    }

    @Test
    fun deletionNeverPurgesFromLocalTimeOrVerificationFailure() {
        val source = serviceSource()
        val refresh = source.section(
            "    suspend fun refreshDeletionStatus()",
            "    suspend fun cancelAccountDeletion()",
        )

        assertFalse(source.contains("managedDeletionDeadlinePassed"))
        assertFalse(source.contains("completeLocalDeletionHandoff"))
        assertFalse(refresh.contains("ManagedStorageException.NotFound"))
        assertTrue(refresh.contains("client().erasureReceipt("))
        assertTrue(refresh.contains("erasureReceiptAuthorization()"))
        assertFalse(refresh.contains("authorization(forceRefresh = false)"))
        assertTrue(refresh.contains("\"completed\" -> completeLocalErasureState()"))
        assertTrue(refresh.contains("completeLocalErasureState()"))
        assertTrue(refresh.contains("ManagedCloudPhase.DELETION_SCHEDULED"))
        assertTrue(refresh.contains("\"outcome\" to \"pending_retry\""))
    }

    @Test
    fun disconnectClearsAccountBindingAndPreservesRecoverableDocumentKeys() {
        val disconnect = serviceSource().section(
            "    suspend fun disconnect()",
            "    suspend fun sendDeletionCode(",
        )

        assertFalse(disconnect.contains("purgeManagedDocumentLocalState"))
        val release = disconnect.indexOf("releaseManagedDocumentProfile()")
        val signOut = disconnect.indexOf("runtime().auth.signOut()")
        val clear = disconnect.indexOf("preferences.clearEnrollment()")
        val signedOut = disconnect.indexOf(
            "setPhase(ManagedCloudPhase.SIGNED_OUT)",
        )
        assertTrue(release >= 0)
        assertTrue(release < signOut)
        assertTrue(signOut < clear)
        assertTrue(clear < signedOut)
        assertFalse(disconnect.contains("preferences.disconnect()"))

        val clearEnrollment = preferencesSource().section(
            "    fun clearEnrollment()",
            "    private fun stableRequestId(",
        )
        listOf(
            "KEY_ENROLLED_SCOPE_HASH",
            "KEY_ENROLLED_IDENTITY_SCOPE_HASH",
            "KEY_ENROLLED_DATA_SCOPE_VERSION",
            "KEY_ENROLLED_BINDING_SCHEMA",
            "KEY_ENROLLED_POLICY",
        ).forEach { accountBindingKey ->
            assertTrue(clearEnrollment.contains(".remove($accountBindingKey)"))
        }
        assertFalse(clearEnrollment.contains("ManagedDocumentKeyVault"))
        assertFalse(clearEnrollment.contains("ManagedDocumentCiphertextInbox"))
        assertFalse(clearEnrollment.contains("purgeManagedDocumentLocalState"))
    }

    @Test
    fun lifecycleDiagnosticsAreCategoricalAndPayloadFree() {
        val source = serviceSource()
        val runtime = source.section(
            "    private fun managedDocumentRuntime(",
            "    private fun completeLocalErasureState()",
        )
        val purge = source.section(
            "    private fun purgeManagedDocumentLocalState()",
            "    private fun restoreAfterCanceledErasure()",
        )
        val diagnostics = runtime + purge

        assertTrue(diagnostics.contains("\"managed_documents.runtime\""))
        assertTrue(
            diagnostics.contains(
                "\"managed_documents.account_delete_purge\"",
            ),
        )
        listOf(
            "error.message",
            "stackTrace",
            "\"account_scope\"",
            "\"payload\"",
            "\"identifier\"",
        ).forEach { forbidden ->
            assertFalse(diagnostics.contains(forbidden))
        }
        val vault = purge.indexOf("ManagedDocumentKeyVault(storage)")
        val removeAccount = purge.indexOf(".removeAccount(scopeHash)", vault)
        assertTrue(vault >= 0)
        assertTrue(removeAccount > vault)
        assertFalse(purge.contains("deleteSharedPreferences"))
        assertFalse(purge.contains("deleteEntry"))
    }

    @Test
    fun enrollmentUsesProjectTenantBindingWithoutMovingLegacyData() {
        val source = serviceSource()
        val enrollment = source.section(
            "    suspend fun enroll()",
            "    suspend fun syncNow()",
        )
        val binding = source.section(
            "    private fun accountScopeBinding(",
            "    private suspend fun bindManagedDocumentProfile(",
        )

        assertTrue(enrollment.contains("accountScopeBinding("))
        assertTrue(enrollment.contains("preferences.completeEnrollment("))
        assertTrue(binding.contains("projectId = config.projectId"))
        assertTrue(binding.contains("tenantId = user.tenantId"))
        assertTrue(binding.contains("persistAccountScopeBinding(binding)"))
        assertTrue(binding.contains("preferences.enrolledScopeHash"))
        assertFalse(binding.contains("noop-managed-account-v1"))
    }

    private fun serviceSource(): String {
        val source = File(
            managedTestRepositoryRoot(),
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )
        check(source.isFile) { "ManagedCloudService.kt is missing." }
        return source.readText()
    }

    private fun preferencesSource(): String {
        val source = File(
            managedTestRepositoryRoot(),
            "android/app/src/main/java/com/noop/managed/ManagedCloudPreferences.kt",
        )
        check(source.isFile) { "ManagedCloudPreferences.kt is missing." }
        return source.readText()
    }

    private fun String.section(start: String, end: String): String {
        val startIndex = indexOf(start)
        val endIndex = indexOf(end, startIndex + start.length)
        check(startIndex >= 0 && endIndex > startIndex)
        return substring(startIndex, endIndex)
    }
}
