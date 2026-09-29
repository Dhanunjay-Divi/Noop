package com.noop.ble.veepoo

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VeepooCredentialStoreTest {
    private class MemoryBackend : VeepooCredentialBackend {
        val values = mutableMapOf<String, Any>()
        var failReads = false
        var removeCalls = 0
        var removeResult = true
        var throwOnRemove = false
        override fun contains(key: String): Boolean = key in values
        override fun readString(key: String): String? {
            if (failReads) error("injected encrypted read failure")
            return values[key] as? String
        }
        override fun writeString(key: String, value: String): Boolean {
            values[key] = value
            return true
        }
        override fun remove(key: String): Boolean {
            removeCalls += 1
            if (throwOnRemove) error("injected encrypted removal failure")
            if (!removeResult) return false
            values.remove(key)
            return true
        }
    }

    private class MemoryCleanupBackend : VeepooCredentialCleanupBackend {
        val values = mutableMapOf<VeepooCredentialCleanupKind, Set<String>>()
        var readsAvailable = true
        var writesSucceed = true

        override fun read(kind: VeepooCredentialCleanupKind): VeepooCredentialCleanupRead =
            if (readsAvailable) {
                VeepooCredentialCleanupRead.Available(values[kind].orEmpty().toSet())
            } else {
                VeepooCredentialCleanupRead.Unavailable
            }

        override fun write(
            kind: VeepooCredentialCleanupKind,
            deviceIds: Set<String>,
        ): Boolean {
            if (!writesSucceed) return false
            values[kind] = deviceIds.toSet()
            return true
        }
    }

    @Test
    fun pendingCredentialCleanupSurvivesStoreRecreation() {
        val backend = MemoryCleanupBackend()
        val first = VeepooCredentialCleanupStore(backend)
        assertTrue(first.markPending("supplier-generated"))

        val restored = VeepooCredentialCleanupStore(backend)
        assertEquals(
            setOf("supplier-generated"),
            (restored.pendingDeviceIds() as VeepooCredentialCleanupRead.Available).deviceIds,
        )
        assertTrue(restored.clearPending("supplier-generated"))
        assertTrue(
            (first.pendingDeviceIds() as VeepooCredentialCleanupRead.Available)
                .deviceIds
                .isEmpty(),
        )
    }

    @Test
    fun unavailableCleanupLedgerFailsClosedWithoutDiscardingPendingIds() {
        val backend = MemoryCleanupBackend()
        val store = VeepooCredentialCleanupStore(backend)
        assertTrue(store.markPending("supplier-generated"))
        backend.readsAvailable = false

        assertFalse(store.clearPending("supplier-generated"))
        assertFalse(store.markPending("supplier-other"))
        assertEquals(
            setOf("supplier-generated"),
            backend.values[VeepooCredentialCleanupKind.ARCHIVE],
        )
    }

    @Test
    fun rejectedCleanupUsesADurableLedgerSeparateFromArchiveCleanup() {
        val backend = MemoryCleanupBackend()
        val first = VeepooCredentialCleanupStore(backend)
        assertTrue(first.markPending("supplier-archive"))
        assertTrue(first.markRejectedPending("supplier-rejected-a"))
        assertTrue(first.markRejectedPending("supplier-rejected-b"))

        val restored = VeepooCredentialCleanupStore(backend)
        assertEquals(
            setOf("supplier-archive"),
            (restored.pendingDeviceIds() as VeepooCredentialCleanupRead.Available).deviceIds,
        )
        assertEquals(
            setOf("supplier-rejected-a", "supplier-rejected-b"),
            (restored.rejectedPendingDeviceIds() as VeepooCredentialCleanupRead.Available)
                .deviceIds,
        )

        assertTrue(restored.clearRejectedPending("supplier-rejected-a"))
        assertEquals(
            setOf("supplier-rejected-b"),
            (first.rejectedPendingDeviceIds() as VeepooCredentialCleanupRead.Available)
                .deviceIds,
        )
        assertEquals(
            setOf("supplier-archive"),
            (first.pendingDeviceIds() as VeepooCredentialCleanupRead.Available).deviceIds,
        )
    }

    @Test
    fun encryptedStoreEncodingPreservesLeadingZeroes() {
        val backend = MemoryBackend()
        val store = VeepooCredentialStore(backend)
        val binding = requireNotNull(VeepooRevisionBinding.from("hw-1", "fw-1"))
        assertTrue(store.save("supplier-1", "0007".toCharArray(), binding))
        val loaded = requireNotNull(store.load("supplier-1"))
        assertArrayEquals("0007".toCharArray(), loaded.password)
        assertEquals(binding, loaded.revisionBinding)
        loaded.close()
        assertTrue(loaded.password.all { it == '\u0000' })
        assertTrue(store.clear("supplier-1"))
        assertNull(store.load("supplier-1"))
    }

    @Test
    fun invalidPasswordsAreRejected() {
        val store = VeepooCredentialStore(MemoryBackend())
        val binding = requireNotNull(VeepooRevisionBinding.from("hw-1", "fw-1"))
        assertFalse(store.save("supplier-1", "123".toCharArray(), binding))
        assertFalse(store.save("supplier-1", "12x4".toCharArray(), binding))
        assertFalse(store.save("", "1234".toCharArray(), binding))
    }

    @Test
    fun legacyPasswordWithoutRevisionBindingIsDeletedAndRejected() {
        val backend = MemoryBackend().apply {
            values["transport_password_supplier-1"] = 7
        }
        val store = VeepooCredentialStore(backend)

        assertNull(store.load("supplier-1"))
        assertFalse("legacy credential must be removed", backend.values.isNotEmpty())
    }

    @Test
    fun malformedRecordWithoutRevisionBindingIsDeletedAndRejected() {
        val backend = MemoryBackend().apply {
            values["transport_password_supplier-1"] = "v1|0007|"
        }
        val store = VeepooCredentialStore(backend)

        assertNull(store.load("supplier-1"))
        assertFalse("incomplete credential must be removed", backend.values.isNotEmpty())
    }

    @Test
    fun malformedRecordRemovalFailureReturnsUnavailableAndRetainsMaterial() {
        val key = "transport_password_supplier-1"
        val backend = MemoryBackend().apply {
            values[key] = "v1|0007|"
            removeResult = false
        }
        val store = VeepooCredentialStore(backend)

        assertEquals(
            VeepooCredentialRead.Unavailable,
            store.readForRetention("supplier-1"),
        )
        assertEquals("v1|0007|", backend.values[key])
        assertEquals(1, backend.removeCalls)
    }

    @Test
    fun malformedRecordRemovalExceptionReturnsUnavailableAndRetainsMaterial() {
        val key = "transport_password_supplier-1"
        val backend = MemoryBackend().apply {
            values[key] = "v1|0007|"
            throwOnRemove = true
        }
        val store = VeepooCredentialStore(backend)

        assertEquals(
            VeepooCredentialRead.Unavailable,
            store.readForRetention("supplier-1"),
        )
        assertEquals("v1|0007|", backend.values[key])
        assertEquals(1, backend.removeCalls)
    }

    @Test
    fun encryptedReadFailureDoesNotDeleteStoredCredential() {
        val backend = MemoryBackend()
        val store = VeepooCredentialStore(backend)
        val binding = requireNotNull(VeepooRevisionBinding.from("hw-1", "fw-1"))
        assertTrue(store.save("supplier-1", "0007".toCharArray(), binding))
        val encoded = backend.values.getValue("transport_password_supplier-1")
        backend.failReads = true

        assertEquals(
            VeepooCredentialRead.Unavailable,
            store.readForRetention("supplier-1"),
        )
        assertEquals(encoded, backend.values["transport_password_supplier-1"])
        assertEquals(0, backend.removeCalls)
    }

    @Test
    fun diagnosticsExposeOnlyFixedCategories() {
        val fields = VeepooDiagnosticEvent(
            category = VeepooDiagnosticCategory.AUTHENTICATION,
            outcome = VeepooDiagnosticOutcome.FAILED,
            failure = VeepooDiagnosticFailure.REJECTED,
        ).fields()
        assertEquals(setOf("category", "outcome", "failure"), fields.keys)
        assertTrue(fields.values.all { it.matches(Regex("[a-z_]+")) })
    }

    @Test
    fun supplierLifecycleDiagnosticsExposeOnlyFixedPrivacySafeCategories() {
        val event = VeepooSupplierLifecycleEvent(
            stage = VeepooSupplierLifecycleStage.RECONCILIATION,
            outcome = VeepooSupplierLifecycleOutcome.FAILED,
            trigger = VeepooSupplierLifecycleTrigger.AUTHENTICATION_REJECTED,
            failure = VeepooSupplierLifecycleFailure.FALLBACK_UNAVAILABLE,
        )
        val fields = event.fields()

        assertEquals(
            setOf("stage", "outcome", "trigger", "failure_kind"),
            fields.keys,
        )
        assertTrue(fields.values.all { it.matches(Regex("[a-z_]+")) })
        assertEquals("VeepooSupplierLifecycleEvent", event.toString())
        assertFalse(fields.keys.any { it.contains("device") || it.contains("credential") })
    }
}
