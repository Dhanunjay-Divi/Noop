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
        override fun readInt(key: String): Int? = values[key] as? Int
        override fun writeInt(key: String, value: Int): Boolean {
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
        val store = VeepooCredentialStore(MemoryBackend())
        assertTrue(store.save("supplier-1", "0007".toCharArray()))
        assertArrayEquals("0007".toCharArray(), store.load("supplier-1"))
        assertTrue(store.clear("supplier-1"))
        assertNull(store.load("supplier-1"))
    }

    @Test
    fun invalidPasswordsAreRejected() {
        val store = VeepooCredentialStore(MemoryBackend())
        assertFalse(store.save("supplier-1", "123".toCharArray()))
        assertFalse(store.save("supplier-1", "12x4".toCharArray()))
        assertFalse(store.save("", "1234".toCharArray()))
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
