package com.noop.managed

import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ManagedDocumentKeyProviderTest {
    private val account = "c".repeat(64)

    @Test
    fun recoveryGateRotationAndRevocationKeepStableKeyContract() {
        val storage = MemoryKeyStorage()
        val vault = ManagedDocumentKeyVault(storage)
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            vault.activeDocumentKey(account)
        }
        val keyId = UUID.fromString("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        val initialMasterKey = ByteArray(32) { 1 }
        val initialReceipt = receipt(
            masterKey = initialMasterKey,
            keyId = UUID.randomUUID(),
            wrappingRevision = 1,
            wrappedKey = ByteArray(72) { 9 },
        )
        vault.completeRecoveryEnrollment(
            account,
            initialMasterKey,
            initialReceipt,
        )
        val created = vault.createDocumentKey(account, keyId)
        val before = vault.wrappedDocumentKeys(account).single()
        assertEquals(before, vault.wrappedDocumentKeys(account).single())
        val rotatedMasterKey = ByteArray(32) { 2 }
        val rotatedReceipt = receipt(
            masterKey = rotatedMasterKey,
            keyId = UUID.randomUUID(),
            wrappingRevision = 2,
            wrappedKey = ByteArray(72) { 8 },
        )
        val plan = vault.prepareAccountMasterKeyRotation(
            account,
            rotatedMasterKey,
            rotatedReceipt,
        )
        val after = plan.wrappedDocumentKeys.single()
        assertEquals(keyId, before.keyId)
        assertEquals(keyId, after.keyId)
        assertEquals(before.wrappingRevision + 1, after.wrappingRevision)
        assertEquals(plan, vault.pendingAccountMasterKeyRotation(account))
        vault.commitAccountMasterKeyRotation(
            account,
            plan.planId,
            plan.wrappedDocumentKeys,
        )
        assertEquals(null, vault.pendingAccountMasterKeyRotation(account))
        assertArrayEquals(created.keyData, vault.documentKey(account, keyId).keyData)
        assertEquals(after, vault.wrappedDocumentKeys(account).single())

        vault.revokeDocumentKey(account, keyId)
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            vault.documentKey(account, keyId)
        }
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            vault.recoverDocumentKey(
                account,
                after,
                ByteArray(32) { 2 },
                true,
            )
        }

        val unrelatedReceipt = receipt(
            masterKey = ByteArray(32) { 3 },
            keyId = UUID.randomUUID(),
            wrappingRevision = 1,
            wrappedKey = ByteArray(72) { 7 },
        )
        val freshVault = ManagedDocumentKeyVault(MemoryKeyStorage())
        assertThrows(IllegalArgumentException::class.java) {
            freshVault.completeRecoveryEnrollment(
                account,
                ByteArray(32) { 4 },
                unrelatedReceipt,
            )
        }
    }

    private fun receipt(
        masterKey: ByteArray,
        keyId: UUID,
        wrappingRevision: Int,
        wrappedKey: ByteArray,
        recoveryMethod: String = "recovery_key",
    ): ManagedAccountMasterKeyReceipt = ManagedAccountMasterKeyReceipt(
        keyId = keyId,
        wrappingRevision = wrappingRevision,
        wrappedKey = wrappedKey,
        masterKeyConfirmationHmacSha256 =
            ManagedAccountMasterKeyBinding.confirmationHmacSha256(
                masterKey = masterKey,
                accountScopeHash = account,
                keyId = keyId,
                wrappingRevision = wrappingRevision,
                wrappedKeySha256 = sha256(wrappedKey),
                recoveryMethod = recoveryMethod,
            ),
        recoveryMethod = recoveryMethod,
    )

    private class MemoryKeyStorage : ManagedDocumentKeyVaultStorage {
        private val values = mutableMapOf<String, String>()
        override fun load(accountScopeHash: String): String? = values[accountScopeHash]
        override fun save(accountScopeHash: String, value: String) {
            values[accountScopeHash] = value
        }
        override fun remove(accountScopeHash: String) {
            values.remove(accountScopeHash)
        }
    }
}
