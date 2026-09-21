package com.noop.managed

import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class ManagedDocumentCiphertextInboxTest {
    private val firstAccount = "a".repeat(64)
    private val secondAccount = "b".repeat(64)

    @Test
    fun outboundCiphertextSurvivesRestartAndIsStable() {
        val root = Files.createTempDirectory("managed-document-inbox").toFile()
        try {
            val account = firstAccount
            val key = ManagedDocumentKey(UUID.randomUUID(), ByteArray(32) { it.toByte() })
            val documentId = UUID.randomUUID()
            val plaintext = """{"schema_version":1}""".toByteArray()
            val first = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = account,
                clock = { 1 },
            )
            val envelope = first.outgoingEnvelope(
                account,
                "local-row",
                2,
                ManagedDocumentKind.JOURNAL,
                documentId,
                7,
                key,
                plaintext,
            )
            val restarted = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = account,
                clock = { 2 },
            )
            assertArrayEquals(
                envelope,
                restarted.outgoingEnvelope(
                    account,
                    "local-row",
                    2,
                    ManagedDocumentKind.JOURNAL,
                    documentId,
                    7,
                    key,
                    plaintext,
                ),
            )
            assertEquals(1, restarted.pendingOutgoingCount())
            assertThrows(ManagedStorageException.InvalidResponse::class.java) {
                restarted.outgoingEnvelope(
                    account,
                    "local-row",
                    2,
                    ManagedDocumentKind.JOURNAL,
                    documentId,
                    7,
                    key,
                    plaintext + byteArrayOf(0),
                )
            }
            restarted.removeOutgoing(account, "local-row", 2, 7)
            assertEquals(0, restarted.pendingOutgoingCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun outgoingReconciliationRemovesOnlySupersededGenerations() {
        val root = Files.createTempDirectory("managed-document-reconcile").toFile()
        try {
            val key = ManagedDocumentKey(UUID.randomUUID(), ByteArray(32) { 5 })
            val inbox = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                clock = { 1 },
            )
            inbox.outgoingEnvelope(
                firstAccount,
                "c".repeat(64),
                1,
                ManagedDocumentKind.JOURNAL,
                UUID.randomUUID(),
                1,
                key,
                "old".toByteArray(),
            )
            inbox.outgoingEnvelope(
                firstAccount,
                "d".repeat(64),
                2,
                ManagedDocumentKind.JOURNAL,
                UUID.randomUUID(),
                2,
                key,
                "current".toByteArray(),
            )

            assertEquals(
                1,
                inbox.reconcileOutgoing(
                    firstAccount,
                    listOf(
                        ManagedDocumentCiphertextInboxOutgoingReference(
                            localIdentifier = "d".repeat(64),
                            generation = 2,
                            revision = 2,
                        ),
                    ),
                ),
            )
            assertEquals(1, inbox.pendingOutgoingCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun accountsUseDistinctOpaqueDirectoriesAndCannotCrossBind() {
        val root = Files.createTempDirectory("managed-document-inbox").toFile()
        try {
            val key = ManagedDocumentKey(
                UUID.randomUUID(),
                ByteArray(32) { 7 },
            )
            val documentId = UUID.randomUUID()
            val first = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                clock = { 1 },
            )
            val second = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = secondAccount,
                clock = { 1 },
            )

            first.outgoingEnvelope(
                firstAccount,
                "same-row",
                1,
                ManagedDocumentKind.JOURNAL,
                documentId,
                1,
                key,
                "first".toByteArray(),
            )
            second.outgoingEnvelope(
                secondAccount,
                "same-row",
                1,
                ManagedDocumentKind.JOURNAL,
                documentId,
                1,
                key,
                "second".toByteArray(),
            )

            assertEquals(1, first.pendingOutgoingCount())
            assertEquals(1, second.pendingOutgoingCount())
            val accountDirectories =
                root.resolve("accounts").listFiles().orEmpty()
            assertEquals(2, accountDirectories.size)
            accountDirectories.forEach { directory ->
                assertFalse(directory.name.contains(firstAccount))
                assertFalse(directory.name.contains(secondAccount))
                assertEquals(64, directory.name.length)
            }
            assertThrows(ManagedStorageException.InvalidResponse::class.java) {
                first.outgoingEnvelope(
                    secondAccount,
                    "cross-account",
                    1,
                    ManagedDocumentKind.JOURNAL,
                    documentId,
                    1,
                    key,
                    "blocked".toByteArray(),
                )
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun purgingOneAccountPreservesAnotherAccountsCiphertext() {
        val root = Files.createTempDirectory("managed-document-inbox").toFile()
        try {
            val key = ManagedDocumentKey(
                UUID.randomUUID(),
                ByteArray(32) { 9 },
            )
            listOf(firstAccount, secondAccount).forEach { account ->
                ManagedDocumentCiphertextInbox(
                    root,
                    configuredAccountScopeHash = account,
                    clock = { 1 },
                ).outgoingEnvelope(
                    account,
                    "row",
                    1,
                    ManagedDocumentKind.JOURNAL,
                    UUID.randomUUID(),
                    1,
                    key,
                    account.take(1).toByteArray(),
                )
            }

            assertEquals(
                ManagedDocumentCiphertextInboxPurgeDisposition.REMOVED,
                ManagedDocumentCiphertextInbox(
                    root,
                    configuredAccountScopeHash = firstAccount,
                    clock = { 1 },
                ).purgeAccount(firstAccount),
            )
            assertEquals(
                0,
                ManagedDocumentCiphertextInbox(
                    root,
                    configuredAccountScopeHash = firstAccount,
                    clock = { 1 },
                ).pendingOutgoingCount(),
            )
            assertEquals(
                1,
                ManagedDocumentCiphertextInbox(
                    root,
                    configuredAccountScopeHash = secondAccount,
                    clock = { 1 },
                ).pendingOutgoingCount(),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun outgoingCiphertextIsNotAgeEvictedBeforeAcknowledgement() {
        val root = Files.createTempDirectory("managed-document-inbox").toFile()
        try {
            val key = ManagedDocumentKey(UUID.randomUUID(), ByteArray(32) { 3 })
            val documentId = UUID.randomUUID()
            ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                policy = ManagedDocumentCiphertextInboxPolicy(
                    maximumRecordCount = 1,
                    maximumTotalBytes = 64 * 1024,
                    maximumAgeMilliseconds = 1,
                ),
                clock = { 1 },
            ).outgoingEnvelope(
                firstAccount, "row", 1, ManagedDocumentKind.JOURNAL,
                documentId, 1, key, "pending".toByteArray(),
            )

            assertEquals(
                1,
                ManagedDocumentCiphertextInbox(
                    root,
                    configuredAccountScopeHash = firstAccount,
                    policy = ManagedDocumentCiphertextInboxPolicy(
                        maximumRecordCount = 1,
                        maximumTotalBytes = 64 * 1024,
                        maximumAgeMilliseconds = 1,
                    ),
                    clock = { 10 },
                ).pendingOutgoingCount(),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun outgoingCiphertextSurvivesWallClockRollback() {
        val root = Files.createTempDirectory("managed-document-clock-rollback").toFile()
        try {
            val key = ManagedDocumentKey(UUID.randomUUID(), ByteArray(32) { 4 })
            val documentId = UUID.randomUUID()
            val first = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                clock = { 10_000 },
            )
            val ciphertext = first.outgoingEnvelope(
                firstAccount,
                "clock-protected",
                1,
                ManagedDocumentKind.JOURNAL,
                documentId,
                1,
                key,
                "pending after clock correction".toByteArray(),
            )

            val restarted = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                clock = { 1_000 },
            )
            assertEquals(1, restarted.pendingOutgoingCount())
            assertArrayEquals(
                ciphertext,
                restarted.outgoingEnvelope(
                    firstAccount,
                    "clock-protected",
                    1,
                    ManagedDocumentKind.JOURNAL,
                    documentId,
                    1,
                    key,
                    "pending after clock correction".toByteArray(),
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun outgoingCiphertextIsNotQuotaEvictedBeforeAcknowledgement() {
        val root = Files.createTempDirectory("managed-document-inbox").toFile()
        try {
            val key = ManagedDocumentKey(UUID.randomUUID(), ByteArray(32) { 4 })
            val first = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                policy = ManagedDocumentCiphertextInboxPolicy(
                    maximumRecordCount = 2,
                    maximumTotalBytes = 64 * 1024,
                ),
                clock = { 1 },
            )
            first.outgoingEnvelope(
                firstAccount,
                "first-row",
                1,
                ManagedDocumentKind.JOURNAL,
                UUID.randomUUID(),
                1,
                key,
                "pending".toByteArray(),
            )
            val tightened = ManagedDocumentCiphertextInbox(
                root,
                configuredAccountScopeHash = firstAccount,
                policy = ManagedDocumentCiphertextInboxPolicy(
                    maximumRecordCount = 1,
                    maximumTotalBytes = 64 * 1024,
                ),
                clock = { 2 },
            )
            first.outgoingEnvelope(
                firstAccount,
                "second-existing-row",
                1,
                ManagedDocumentKind.JOURNAL,
                UUID.randomUUID(),
                1,
                key,
                "also pending".toByteArray(),
            )
            assertEquals(
                ManagedDocumentCiphertextInboxSweepDisposition.QUOTA_BLOCKED,
                tightened.startupMaintenance().sweepDisposition,
            )

            assertThrows(ManagedStorageException.QuotaExceeded::class.java) {
                first.outgoingEnvelope(
                    firstAccount,
                    "second-row",
                    1,
                    ManagedDocumentKind.JOURNAL,
                    UUID.randomUUID(),
                    1,
                    key,
                    "new".toByteArray(),
                )
            }
            assertEquals(2, first.pendingOutgoingCount())
        } finally {
            root.deleteRecursively()
        }
    }
}
