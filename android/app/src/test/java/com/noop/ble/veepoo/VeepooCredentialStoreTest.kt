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
        override fun contains(key: String): Boolean = key in values
        override fun readString(key: String): String? = values[key] as? String
        override fun writeString(key: String, value: String): Boolean {
            values[key] = value
            return true
        }
        override fun remove(key: String): Boolean {
            values.remove(key)
            return true
        }
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
